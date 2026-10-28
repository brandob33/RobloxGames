--!strict
-- Slide and dive animations, drawn on every client for every courier
-- (players and bots). Purely visual: nothing here touches physics or
-- replicates.
--
-- Slide: feet-first, leaning back, one arm trailing for balance.
-- Dive:  a launch and belly-flop. The body tips forward to flat over the
--        lunge, arms stretched out ahead, head up, and lands on the ground,
--        then gets back up as the dive ends.
--
-- The whole body tilts by rotating the root joint's C0 (in root-part space,
-- so it works for R15 and R6), and on R15 the limbs are posed by overriding
-- each joint's animation Transform so the run cycle doesn't flail
-- underneath. Your own pose follows MovementController's prediction so it
-- starts on the key press; everyone else's follows the replicated
-- Sliding / Diving attributes.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local MovementController = require(script.Parent.MovementController)

local PoseController = {}

type PoseKind = "Slide" | "Dive"

type Entry = {
	root: Motor6D,
	baseC0: CFrame,
	isR15: boolean,
	motors: { Motor6D },
	alpha: number,
	kind: PoseKind?,
	startedAt: number, -- os.clock() when the current pose began
}

-- R15 joint Transforms (radians around each joint's X axis: + swings a limb
-- forward / tips the head back). Joints not listed are straightened.
local SLIDE_JOINTS: { [string]: CFrame } = {
	RightShoulder = CFrame.Angles(math.rad(-45), 0, math.rad(15)),
	LeftShoulder = CFrame.Angles(math.rad(35), 0, 0),
	LeftHip = CFrame.Angles(math.rad(10), 0, 0),
	RightHip = CFrame.Angles(math.rad(-6), 0, 0),
}
local DIVE_JOINTS: { [string]: CFrame } = {
	RightShoulder = CFrame.Angles(math.rad(170), 0, math.rad(-8)),
	LeftShoulder = CFrame.Angles(math.rad(170), 0, math.rad(8)),
	Neck = CFrame.Angles(math.rad(55), 0, 0),
	RightHip = CFrame.Angles(math.rad(-12), 0, 0),
	LeftHip = CFrame.Angles(math.rad(-12), 0, 0),
	RightKnee = CFrame.Angles(math.rad(-15), 0, 0),
	LeftKnee = CFrame.Angles(math.rad(-15), 0, 0),
}
local NO_JOINTS: { [string]: CFrame } = {}

local SLIDE_LEAN = math.rad(68) -- tip back
local SLIDE_DROP = 1.1
local DIVE_LEAN = math.rad(-90) -- flat, face down
local DIVE_LAUNCH_LEAN = math.rad(-35) -- leaning into the jump at the start
local DIVE_DROP = 2.3 -- root height above the ground, roughly: lie on it

local BLEND_IN = 22 -- higher = snappier
local BLEND_OUT = 10
local BOT_FOLDER_NAME = "CourierClashBots"

local localPlayer = Players.LocalPlayer
local entries: { [Model]: Entry } = {}
local seen: { [Model]: boolean } = {}

local function collectMotors(character: Model, root: Motor6D): { Motor6D }
	local motors = {}
	for _, descendant in character:GetDescendants() do
		if descendant:IsA("Motor6D") and descendant ~= root then
			table.insert(motors, descendant)
		end
	end
	return motors
end

local function findRootJoint(character: Model): (Motor6D?, boolean)
	local lowerTorso = character:FindFirstChild("LowerTorso")
	local r15 = lowerTorso and lowerTorso:FindFirstChild("Root")
	if r15 and r15:IsA("Motor6D") then
		return r15, true
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	local r6 = rootPart and rootPart:FindFirstChild("RootJoint")
	if r6 and r6:IsA("Motor6D") then
		return r6, false
	end
	return nil, false
end

local function getEntry(character: Model): Entry?
	local entry = entries[character]
	if entry and entry.root.Parent then
		return entry
	end
	local root, isR15 = findRootJoint(character)
	if not root then
		return nil
	end
	local newEntry: Entry = {
		root = root,
		baseC0 = root.C0,
		isR15 = isR15,
		motors = {},
		alpha = 0,
		kind = nil,
		startedAt = 0,
	}
	entries[character] = newEntry
	return newEntry
end

local function wantedPose(character: Model): PoseKind?
	if character == localPlayer.Character then
		if MovementController.isDiving() then
			return "Dive"
		elseif MovementController.isSliding() then
			return "Slide"
		end
		return nil
	end
	if character:GetAttribute("Diving") == true then
		return "Dive"
	elseif character:GetAttribute("Sliding") == true then
		return "Slide"
	end
	return nil
end

local function smoothstep(x: number): number
	local t = math.clamp(x, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Body tilt and drop for this moment of the pose.
local function bodyPose(entry: Entry, kind: PoseKind, isLocal: boolean, now: number): (number, number)
	if kind == "Slide" then
		-- Your own slide already sinks via HipHeight (MovementController).
		return SLIDE_LEAN, if isLocal then 0 else SLIDE_DROP
	end
	-- Dive: lean into the launch, tip to flat over the lunge, land.
	local progress = (now - entry.startedAt) / Config.DIVE_LUNGE_SECONDS
	local tip = smoothstep(progress)
	local lean = DIVE_LAUNCH_LEAN + (DIVE_LEAN - DIVE_LAUNCH_LEAN) * tip
	-- A small hop at the start, then down onto the belly.
	local hop = math.sin(math.clamp(progress, 0, 1) * math.pi) * 0.6
	local drop = DIVE_DROP * tip * tip - hop
	return lean, drop
end

local function update(character: Model, dt: number, now: number)
	seen[character] = true
	local wanted = wantedPose(character)
	local entry = entries[character]
	if not wanted and (not entry or entry.alpha <= 0) then
		return
	end
	entry = getEntry(character)
	if not entry then
		return
	end

	if wanted and wanted ~= entry.kind then
		if entry.alpha <= 0 then
			-- Fresh pose: pick up any joints added since we last looked.
			entry.motors = collectMotors(character, entry.root)
		end
		entry.kind = wanted
		entry.startedAt = now
	end
	local target = if wanted then 1 else 0
	local rate = if wanted then BLEND_IN else BLEND_OUT
	entry.alpha += (target - entry.alpha) * (1 - math.exp(-rate * dt))
	if not wanted and entry.alpha < 0.01 then
		entry.alpha = 0
		entry.kind = nil
		entry.root.C0 = entry.baseC0
		-- Joints no animation is driving would otherwise keep the pose.
		for _, motor in entry.motors do
			motor.Transform = CFrame.identity
		end
		return
	end

	local kind = entry.kind
	if not kind then
		return
	end
	local alpha = entry.alpha
	local lean, drop = bodyPose(entry, kind, character == localPlayer.Character, now)
	-- Rotate in root-part space (pre-multiply) so R15 and R6 tilt the same way.
	entry.root.C0 = CFrame.new(0, -drop * alpha, 0) * CFrame.Angles(lean * alpha, 0, 0) * entry.baseC0

	local joints = if not entry.isR15 then NO_JOINTS elseif kind == "Dive" then DIVE_JOINTS else SLIDE_JOINTS
	for _, motor in entry.motors do
		local jointTarget = joints[motor.Name] or CFrame.identity
		motor.Transform = motor.Transform:Lerp(jointTarget, alpha)
	end
end

local function step(dt: number)
	local now = os.clock()
	table.clear(seen)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			update(character, dt, now)
		end
	end
	local bots = Workspace:FindFirstChild(BOT_FOLDER_NAME)
	if bots then
		for _, child in bots:GetChildren() do
			if child:IsA("Model") then
				update(child, dt, now)
			end
		end
	end
	-- Forget characters that despawned.
	for character in entries do
		if not seen[character] then
			entries[character] = nil
		end
	end
end

function PoseController.start()
	-- PreSimulation runs right after the Animator writes this frame's joint
	-- Transforms, which is where Roblox documents overriding them.
	RunService.PreSimulation:Connect(step)
end

return PoseController
