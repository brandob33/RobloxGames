--!strict
-- Shove input (E key / gamepad X / the HUD button). Starts the cooldown
-- optimistically for feel; the server's ShoveCooldown reply is the truth.
-- The server picks the target: the nearest opponent in front of you.

local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Net = require(script.Parent.Parent.Net)
local MovementController = require(script.Parent.MovementController)

local ShoveController = {}

-- Fired with the seconds left on the cooldown whenever it (re)starts.
local cooldownChanged: Signal.Signal<number> = Signal.new()
ShoveController.CooldownChanged = cooldownChanged

local localPlayer = Players.LocalPlayer
local readyAt = 0
local shovedAt = -math.huge
-- How long the arms-out pose shows (matches the server's Shoving flag).
local POSE_SECONDS = 0.25

local function setCooldown(seconds: number)
	readyAt = os.clock() + seconds
	cooldownChanged.fire(seconds)
end

-- Returns true if a shove was sent.
function ShoveController.request(): boolean
	if os.clock() < readyAt or MovementController.isDiving() then
		return false
	end
	local character = localPlayer.Character
	-- Same rules the server checks; carriers juke instead.
	if
		not character
		or character:GetAttribute("Carrying") == true
		or character:GetAttribute("Stunned") == true
	then
		return false
	end
	setCooldown(Config.SHOVE_COOLDOWN)
	shovedAt = os.clock()
	Net.fire("Shove")
	return true
end

-- Local prediction for the pose controller.
function ShoveController.isShoving(): boolean
	return os.clock() - shovedAt < POSE_SECONDS
end

function ShoveController.init()
	Net.on("ShoveCooldown", function(remaining: unknown)
		if typeof(remaining) == "number" and remaining == remaining then
			setCooldown(math.clamp(remaining, 0, Config.SHOVE_COOLDOWN))
		end
	end)

	ContextActionService:BindAction("CourierClashShove", function(_, state)
		if state == Enum.UserInputState.Begin and ShoveController.request() then
			return Enum.ContextActionResult.Sink
		end
		return Enum.ContextActionResult.Pass
	end, false, Enum.KeyCode.E, Enum.KeyCode.ButtonX)
end

return ShoveController
