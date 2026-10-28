--!strict
-- Local movement feel: sprint (hold Shift / L2 / the Sprint button), slide
-- (C or Ctrl / B / the Slide button while sprinting) and a camera FOV kick.
--
-- Everything here is prediction for instant response. The server's Sprint
-- system owns stamina and decides whether a sprint or slide is allowed, and
-- its Movement check enforces the speed limit; this controller mirrors the
-- same rules from replicated attributes so the two agree:
--   Player   Stamina, Sprinting   (Sprint system)
--   Character Carrying, Stunned   (Agents.refreshSpeed)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Net = require(script.Parent.Parent.Net)

local MovementController = {}

-- Fired with the new sprint key state (for the touch button highlight).
local sprintChanged: Signal.Signal<boolean> = Signal.new()
MovementController.SprintChanged = sprintChanged
-- Fired with the slide cooldown in seconds when a slide starts.
local slideStarted: Signal.Signal<number> = Signal.new()
MovementController.SlideStarted = slideStarted

local localPlayer = Players.LocalPlayer

-- Until the server's verdict replicates, assume a fresh sprint press is OK.
local SPRINT_PREDICT_SECONDS = 0.35
local FOV_BASE = 70
local FOV_SPRINT = 80
local FOV_SLIDE = 88
local FOV_RESPONSE = 10 -- higher = snappier FOV easing
local SLIDE_HIP_DROP = 1.1
local SLIDE_CAMERA_OFFSET = Vector3.new(0, -1.6, 0)
local CAMERA_TWEEN = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local MOVING_SPEED = 2
-- Stamina margins over the server's rules: the replicated Stamina value
-- lags the server's while sprint drains it, so ask only when clearly OK.
local SPRINT_PREDICT_MARGIN = 1
local SLIDE_STAMINA_MARGIN = 4

local wantSprint = false
local sprintPressedAt = 0
local slideStartedAt = 0
local slideEndsAt = 0
local slideReadyAt = 0
local slideDirection = Vector3.zero
local restoreHipHeight: number? = nil

local humanoid: Humanoid? = nil
local root: BasePart? = nil

local function stamina(): number
	local value = localPlayer:GetAttribute("Stamina")
	return if typeof(value) == "number" then value else Config.STAMINA_MAX
end

local function characterFlag(name: string): boolean
	local character = localPlayer.Character
	return character ~= nil and character:GetAttribute(name) == true
end

local function isSliding(now: number): boolean
	return now < slideEndsAt
end

local function sprintActive(now: number): boolean
	if not wantSprint then
		return false
	end
	if localPlayer:GetAttribute("Sprinting") == true then
		return true
	end
	return now - sprintPressedAt < SPRINT_PREDICT_SECONDS
		and stamina() >= Config.SPRINT_MIN_STAMINA + SPRINT_PREDICT_MARGIN
end

local function walkSpeed(now: number): number
	if characterFlag("Stunned") then
		return 0
	end
	local carrying = characterFlag("Carrying")
	if sprintActive(now) or isSliding(now) then
		return if carrying then Config.CARRIER_SPRINT_SPEED else Config.SPRINT_SPEED
	end
	return if carrying then Config.CARRIER_SPEED else Config.RUN_SPEED
end

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function endSlide()
	slideEndsAt = 0
	local currentHumanoid = humanoid
	if currentHumanoid then
		if restoreHipHeight then
			currentHumanoid.HipHeight = restoreHipHeight
		end
		TweenService:Create(currentHumanoid, CAMERA_TWEEN, { CameraOffset = Vector3.zero }):Play()
	end
	restoreHipHeight = nil
end

function MovementController.setSprint(wanted: boolean)
	if wanted == wantSprint then
		return
	end
	wantSprint = wanted
	if wanted then
		sprintPressedAt = os.clock()
	end
	Net.fire("Sprint", wanted)
	sprintChanged.fire(wanted)
end

function MovementController.isSprintHeld(): boolean
	return wantSprint
end

-- Returns true if a slide started.
function MovementController.slide(): boolean
	local now = os.clock()
	local currentHumanoid = humanoid
	local currentRoot = root
	if not currentHumanoid or not currentRoot or currentHumanoid.Health <= 0 then
		return false
	end
	-- Same rules the server checks in Sprint.trySlide.
	if
		isSliding(now)
		or now < slideReadyAt
		or not sprintActive(now)
		or characterFlag("Stunned")
		or stamina() < Config.SLIDE_STAMINA + SLIDE_STAMINA_MARGIN
		or currentHumanoid.FloorMaterial == Enum.Material.Air
	then
		return false
	end

	local direction = flat(currentHumanoid.MoveDirection)
	if direction.Magnitude < 0.1 then
		direction = flat(currentRoot.CFrame.LookVector)
	end
	if direction.Magnitude < 0.01 then
		return false
	end
	slideDirection = direction.Unit
	slideStartedAt = now
	slideEndsAt = now + Config.SLIDE_SECONDS
	slideReadyAt = now + Config.SLIDE_COOLDOWN

	restoreHipHeight = currentHumanoid.HipHeight
	currentHumanoid.HipHeight = math.max(0, currentHumanoid.HipHeight - SLIDE_HIP_DROP)
	TweenService:Create(currentHumanoid, CAMERA_TWEEN, { CameraOffset = SLIDE_CAMERA_OFFSET })
		:Play()

	Net.fire("Slide")
	slideStarted.fire(Config.SLIDE_COOLDOWN)
	return true
end

-- Runs before physics so the slide velocity isn't pulled back toward
-- WalkSpeed by the Humanoid within the same step.
local function onPreSimulation()
	local currentHumanoid = humanoid
	local currentRoot = root
	if not currentHumanoid or not currentRoot then
		return
	end
	local now = os.clock()

	if isSliding(now) then
		if characterFlag("Stunned") or currentHumanoid.Health <= 0 then
			endSlide()
		else
			-- Ease from slide speed down to sprint speed over the slide.
			local alpha = (now - slideStartedAt) / Config.SLIDE_SECONDS
			local exitSpeed = walkSpeed(now)
			local speed = Config.SLIDE_SPEED + (exitSpeed - Config.SLIDE_SPEED) * alpha * alpha
			local velocity = currentRoot.AssemblyLinearVelocity
			currentRoot.AssemblyLinearVelocity =
				Vector3.new(slideDirection.X * speed, velocity.Y, slideDirection.Z * speed)
		end
	elseif restoreHipHeight then
		endSlide()
	end

	local speed = walkSpeed(now)
	if currentHumanoid.WalkSpeed ~= speed then
		currentHumanoid.WalkSpeed = speed
	end
end

local function onRenderStep(dt: number)
	local camera = Workspace.CurrentCamera
	local currentRoot = root
	if not camera or not currentRoot then
		return
	end
	local now = os.clock()
	local moving = flat(currentRoot.AssemblyLinearVelocity).Magnitude > MOVING_SPEED
	local target = if isSliding(now)
		then FOV_SLIDE
		elseif sprintActive(now) and moving then FOV_SPRINT
		else FOV_BASE
	camera.FieldOfView += (target - camera.FieldOfView) * (1 - math.exp(-FOV_RESPONSE * dt))
end

local function onCharacterAdded(character: Model)
	slideEndsAt = 0
	restoreHipHeight = nil
	humanoid = nil
	root = nil
	local newHumanoid = character:WaitForChild("Humanoid", 10)
	local newRoot = character:WaitForChild("HumanoidRootPart", 10)
	if localPlayer.Character ~= character then
		return
	end
	if newHumanoid and newHumanoid:IsA("Humanoid") and newRoot and newRoot:IsA("BasePart") then
		humanoid = newHumanoid
		root = newRoot
	end
	-- The server resets sprint state on respawn; resync the key state.
	Net.fire("Sprint", wantSprint)
end

function MovementController.init()
	ContextActionService:BindAction("CourierClashSprint", function(_, state)
		if state == Enum.UserInputState.Begin then
			MovementController.setSprint(true)
		elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
			MovementController.setSprint(false)
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift, Enum.KeyCode.ButtonL2)

	ContextActionService:BindAction("CourierClashSlide", function(_, state)
		if state == Enum.UserInputState.Begin and MovementController.slide() then
			return Enum.ContextActionResult.Sink
		end
		-- Let B / C / Ctrl reach menus and other bindings when not sliding.
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.C, Enum.KeyCode.LeftControl, Enum.KeyCode.ButtonB)

	Net.on("SlideResult", function(accepted: unknown)
		-- Server refused (stamina/cooldown disagreed): stop the local slide so
		-- we don't outrun the server's speed limit.
		if accepted == false and isSliding(os.clock()) then
			endSlide()
		end
	end)

	localPlayer.CharacterAdded:Connect(onCharacterAdded)
	if localPlayer.Character then
		task.spawn(onCharacterAdded, localPlayer.Character)
	end
	RunService.PreSimulation:Connect(onPreSimulation)
	RunService.RenderStepped:Connect(onRenderStep)
end

return MovementController
