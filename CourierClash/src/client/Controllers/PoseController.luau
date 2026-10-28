--!strict
-- Slide, dive and shove animations, drawn on every client for every
-- courier (players and bots). Purely visual: nothing here touches physics
-- or replicates.
--
-- Slide: fully flat on your back, feet-first. Lead leg stretched out, the
--        other tucked under, one hand trailing on the ground, the other up.
--        Wind streaks and a dust trail follow you while it lasts.
-- Dive:  a launch and belly-flop. The body tips forward to flat over the
--        lunge, arms stretched out ahead, head up, and lands on the ground,
--        then gets back up as the dive ends.
-- Shove: both arms punched straight out, leaning into it.
--
-- The whole body tilts by rotating the root joint's C0 (in root-part space,
-- so it works for R15 and R6), and on R15 the limbs are posed by overriding
-- each joint's animation Transform so the run cycle doesn't flail
-- underneath. Your own pose follows MovementController's prediction so it
-- starts on the key press; everyone else's follows the replicated
-- Sliding / Diving / Shoving attributes.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local MovementController = require(script.Parent.MovementController)
local ShoveController = require(script.Parent.ShoveController)

local PoseController = {}

type PoseKind = "Slide" | "Dive" | "Shove"

type Entry = {
	root: Motor6D,
	baseC0: CFrame,
	isR15: boolean,
	motors: { Motor6D },
	alpha: number,
	kind: PoseKind?,
	startedAt: number, -- os.clock() when the current pose began
	joints: { [string]: CFrame }, -- this frame's limb targets
	wind: { Attachment }?, -- slide wind and dust, while sliding
}

-- R15 joint Transforms (radians around each joint's X axis: + swings a limb
-- forward / tips the head back). Joints not listed are straightened.
local SLIDE_JOINTS: { [string]: CFrame } = {
	-- Lead leg: straight out ahead (it already points forward with the body
	-- tipped back), lifted a touch off the ground.
	RightHip = CFrame.Angles(math.rad(8), 0, 0),
	-- Trailing leg: thigh up, knee folded so the foot tucks under.
	LeftHip = CFrame.Angles(math.rad(50), 0, math.rad(-10)),
	LeftKnee = CFrame.Angles(math.rad(-100), 0, 0),
	-- Right hand trails on the ground behind, left arm up for balance.
	RightShoulder = CFrame.Angles(math.rad(-40), 0, math.rad(25)),
	LeftShoulder = CFrame.Angles(math.rad(70), 0, math.rad(-15)),
	-- Head tipped forward to look where you're going.
	Neck = CFrame.Angles(math.rad(-35), 0, 0),
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
local SHOVE_JOINTS: { [string]: CFrame } = {
	RightShoulder = CFrame.Angles(math.rad(95), 0, 0),
	LeftShoulder = CFrame.Angles(math.rad(95), 0, 0),
	RightElbow = CFrame.Angles(math.rad(5), 0, 0),
	LeftElbow = CFrame.Angles(math.rad(5), 0, 0),
}
local NO_JOINTS: { [string]: CFrame } = {}

local SLIDE_LEAN = math.rad(90) -- fully flat on your back
local SLIDE_DROP = 2.3 -- root height above the ground, roughly: lie on it
-- The slide itself is short; hold the pose a little longer so it reads.
local SLIDE_POSE_HOLD = 0.4
local SHOVE_LEAN = math.rad(-18) -- leaning into the push
local DIVE_LEAN = math.rad(-90) -- flat, face down
local DIVE_LAUNCH_LEAN = math.rad(-35) -- leaning into the jump at the start
local DIVE_DROP = 2.3 -- root height above the ground, roughly: lie on it

local BLEND_IN = 30 -- higher = snappier
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

-- Wind streaks are thin trails between attachment pairs (offsets in root
-- space; the body lies about SLIDE_DROP below the root while sliding).
local WIND_STREAKS: { Vector3 } = {
	Vector3.new(-1.7, -1.6, 0.5),
	Vector3.new(1.7, -1.6, 0.5),
	Vector3.new(-1.1, -0.9, -1.2),
	Vector3.new(1.1, -0.9, -1.2),
	Vector3.new(0, -0.6, 1.8),
}
local WIND_WIDTH = 0.12
local WIND_LIFETIME = 0.2
local DUST_TEXTURE = "rbxasset://textures/particles/smoke_main.dds"
local DUST_OFFSET = Vector3.new(0, -2.8, 0.8)
local WIND_CLEANUP_SECONDS = 0.6

local function startWind(entry: Entry, character: Model)
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if entry.wind or not rootPart or not rootPart:IsA("BasePart") then
		return
	end
	local parts: { Attachment } = {}
	for _, offset in WIND_STREAKS do
		local a0 = Instance.new("Attachment")
		a0.Name = "SlideWind"
		a0.Position = offset
		local a1 = Instance.new("Attachment")
		a1.Name = "SlideWind"
		a1.Position = offset + Vector3.new(0, WIND_WIDTH, 0)
		local trail = Instance.new("Trail")
		trail.Attachment0 = a0
		trail.Attachment1 = a1
		trail.Lifetime = WIND_LIFETIME
		trail.MinLength = 0
		trail.FaceCamera = true
		trail.LightEmission = 0.6
		trail.Color = ColorSequence.new(Color3.new(1, 1, 1))
		trail.Transparency = NumberSequence.new(0.25, 1)
		trail.WidthScale = NumberSequence.new(1, 0)
		trail.Parent = a0
		table.insert(parts, a0)
		table.insert(parts, a1)
	end
	local dustAttachment = Instance.new("Attachment")
	dustAttachment.Name = "SlideWind"
	dustAttachment.Position = DUST_OFFSET
	local dust = Instance.new("ParticleEmitter")
	dust.Texture = DUST_TEXTURE
	dust.Color = ColorSequence.new(Color3.fromRGB(214, 206, 186))
	dust.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(1, 2.4),
	})
	dust.Transparency = NumberSequence.new(0.35, 1)
	dust.Lifetime = NumberRange.new(0.3, 0.5)
	dust.Rate = 45
	dust.Speed = NumberRange.new(3, 6)
	dust.SpreadAngle = Vector2.new(35, 35)
	dust.EmissionDirection = Enum.NormalId.Back
	dust.Acceleration = Vector3.new(0, 3, 0)
	dust.Parent = dustAttachment
	table.insert(parts, dustAttachment)
	for _, part in parts do
		part.Parent = rootPart
	end
	dust:Emit(8)
	entry.wind = parts
end

local function stopWind(entry: Entry)
	local parts = entry.wind
	if not parts then
		return
	end
	entry.wind = nil
	for _, part in parts do
		for _, effect in part:GetChildren() do
			if effect:IsA("Trail") or effect:IsA("ParticleEmitter") then
				effect.Enabled = false
			end
		end
	end
	-- Let the last streaks and dust fade out before removing them.
	task.delay(WIND_CLEANUP_SECONDS, function()
		for _, part in parts do
			part:Destroy()
		end
	end)
end

local function getEntry(character: Model): Entry?
	local entry = entries[character]
	-- The rig can be rebuilt (avatar applied, respawn); then find the new
	-- root joint instead of posing a detached one.
	if entry and entry.root.Parent and entry.root:IsDescendantOf(character) then
		return entry
	end
	if entry then
		stopWind(entry)
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
		joints = NO_JOINTS,
		wind = nil,
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
		elseif ShoveController.isShoving() then
			return "Shove"
		end
		return nil
	end
	if character:GetAttribute("Diving") == true then
		return "Dive"
	elseif character:GetAttribute("Sliding") == true then
		return "Slide"
	elseif character:GetAttribute("Shoving") == true then
		return "Shove"
	end
	return nil
end

local function smoothstep(x: number): number
	local t = math.clamp(x, 0, 1)
	return t * t * (3 - 2 * t)
end

-- Body tilt and drop for this moment of the pose.
local function bodyPose(entry: Entry, kind: PoseKind, now: number): (number, number)
	if kind == "Slide" then
		return SLIDE_LEAN, SLIDE_DROP
	elseif kind == "Shove" then
		return SHOVE_LEAN, 0
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

-- Override the limbs' animation Transforms toward the pose.
local function applyJoints(entry: Entry)
	for _, motor in entry.motors do
		local jointTarget = entry.joints[motor.Name] or CFrame.identity
		motor.Transform = motor.Transform:Lerp(jointTarget, entry.alpha)
	end
end

local function update(character: Model, dt: number, now: number)
	seen[character] = true
	local wanted = wantedPose(character)
	local entry: Entry? = entries[character]
	if
		entry
		and entry.kind == "Slide"
		and (wanted == nil or wanted == "Shove")
		and now - entry.startedAt < SLIDE_POSE_HOLD
	then
		wanted = "Slide"
	end
	if not wanted and (not entry or entry.alpha <= 0) then
		return
	end
	entry = getEntry(character)
	if not entry then
		return
	end

	if wanted and wanted ~= entry.kind then
		if entry.alpha <= 0 then
			-- Fresh pose: pick up any joints added since we last looked, and
			-- the root joint's rest offset in case the rig was rebuilt.
			entry.motors = collectMotors(character, entry.root)
			entry.baseC0 = entry.root.C0
		end
		entry.kind = wanted
		entry.startedAt = now
	end
	if wanted == "Slide" then
		startWind(entry, character)
	elseif entry.wind then
		stopWind(entry)
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
	local lean, drop = bodyPose(entry, kind, now)
	-- Rotate in root-part space (pre-multiply) so R15 and R6 tilt the same way.
	entry.root.C0 = CFrame.new(0, -drop * alpha, 0)
		* CFrame.Angles(lean * alpha, 0, 0)
		* entry.baseC0

	entry.joints = if not entry.isR15
		then NO_JOINTS
		elseif kind == "Dive" then DIVE_JOINTS
		elseif kind == "Shove" then SHOVE_JOINTS
		else SLIDE_JOINTS
	applyJoints(entry)
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
	for character, entry in entries do
		if not seen[character] then
			stopWind(entry)
			entries[character] = nil
		end
	end
end

function PoseController.start()
	-- PreSimulation runs right after the Animator writes this frame's joint
	-- Transforms, which is where Roblox documents overriding them.
	RunService.PreSimulation:Connect(step)
	-- And again just before drawing, so the run cycle can't show through
	-- whichever order the Animator runs in.
	RunService:BindToRenderStep(
		"CourierClashPoses",
		Enum.RenderPriority.Character.Value + 1,
		function()
			for _, entry in entries do
				if entry.alpha > 0 and entry.kind then
					applyJoints(entry)
				end
			end
		end
	)
end

return PoseController
