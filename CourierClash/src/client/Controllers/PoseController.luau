--!strict
-- Slide and dive poses, drawn on every client for every courier (players
-- and bots). Purely visual: nothing here touches physics or replicates.
--
-- Slide: feet-first, leaning back, one arm trailing for balance.
-- Dive:  body pitched forward, arms stretched out ahead.
--
-- We lean the whole body by changing the LowerTorso "Root" joint's C0 and
-- straighten the limbs by overriding each joint's animation Transform, so
-- the run cycle doesn't keep flailing underneath the pose. Your own pose
-- follows MovementController's prediction so it starts on the key press;
-- everyone else's follows the replicated Sliding / Diving attributes.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local MovementController = require(script.Parent.MovementController)

local PoseController = {}

type PoseKind = "Slide" | "Dive"

type Pose = {
	lean: number, -- radians around the hip X axis; + leans back
	drop: number, -- studs the body sinks (not applied to your own slide)
	joints: { [string]: CFrame }, -- per-joint Transform; missing = neutral
}

type Entry = {
	root: Motor6D,
	baseC0: CFrame,
	motors: { Motor6D },
	alpha: number,
	kind: PoseKind?,
}

local POSES: { [PoseKind]: Pose } = {
	Slide = {
		lean = math.rad(68),
		drop = 1.1,
		joints = {
			RightShoulder = CFrame.Angles(math.rad(-45), 0, math.rad(15)),
			LeftShoulder = CFrame.Angles(math.rad(35), 0, 0),
			LeftHip = CFrame.Angles(math.rad(10), 0, 0),
			RightHip = CFrame.Angles(math.rad(-6), 0, 0),
		},
	},
	Dive = {
		lean = math.rad(-75),
		drop = 1.2,
		joints = {
			RightShoulder = CFrame.Angles(math.rad(155), 0, 0),
			LeftShoulder = CFrame.Angles(math.rad(155), 0, 0),
		},
	},
}

local BLEND_IN = 22 -- higher = snappier
local BLEND_OUT = 12
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

local function getEntry(character: Model): Entry?
	local entry = entries[character]
	if entry and entry.root.Parent then
		return entry
	end
	local lowerTorso = character:FindFirstChild("LowerTorso")
	local root = lowerTorso and lowerTorso:FindFirstChild("Root")
	if not root or not root:IsA("Motor6D") then
		return nil
	end
	local newEntry: Entry = {
		root = root,
		baseC0 = root.C0,
		motors = {},
		alpha = 0,
		kind = nil,
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

local function update(character: Model, dt: number)
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
	local pose = POSES[kind]
	local alpha = entry.alpha
	-- Your own slide already sinks via HipHeight (MovementController).
	local drop = if kind == "Slide" and character == localPlayer.Character then 0 else pose.drop
	entry.root.C0 = entry.baseC0
		* CFrame.new(0, -drop * alpha, 0)
		* CFrame.Angles(pose.lean * alpha, 0, 0)
	for _, motor in entry.motors do
		local jointTarget = pose.joints[motor.Name] or CFrame.identity
		motor.Transform = motor.Transform:Lerp(jointTarget, alpha)
	end
end

local function onRenderStep(dt: number)
	table.clear(seen)
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			update(character, dt)
		end
	end
	local bots = Workspace:FindFirstChild(BOT_FOLDER_NAME)
	if bots then
		for _, child in bots:GetChildren() do
			if child:IsA("Model") then
				update(child, dt)
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
	-- After the Animator has written this frame's Transforms, before render.
	RunService:BindToRenderStep(
		"CourierClashPoses",
		Enum.RenderPriority.Character.Value + 1,
		onRenderStep
	)
end

return PoseController
