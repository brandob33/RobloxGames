--!strict
-- Tackle input (F key / gamepad R1 / the HUD button). Starts the cooldown
-- optimistically for feel; the server's TackleCooldown reply is the truth.

local ContextActionService = game:GetService("ContextActionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Net = require(script.Parent.Parent.Net)

local TackleController = {}

-- Fired with the seconds left on the cooldown whenever it (re)starts.
local cooldownChanged: Signal.Signal<number> = Signal.new()
TackleController.CooldownChanged = cooldownChanged

local readyAt = 0

local function setCooldown(seconds: number)
	readyAt = os.clock() + seconds
	TackleController.CooldownChanged.fire(seconds)
end

function TackleController.request()
	if os.clock() < readyAt then
		return
	end
	setCooldown(Config.TACKLE_COOLDOWN)
	Net.fire("Tackle")
end

function TackleController.init()
	Net.on("TackleCooldown", function(remaining: unknown)
		if typeof(remaining) == "number" and remaining == remaining then
			setCooldown(math.clamp(remaining, 0, Config.TACKLE_COOLDOWN))
		end
	end)

	ContextActionService:BindAction("CourierClashTackle", function(_, state)
		if state == Enum.UserInputState.Begin then
			TackleController.request()
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.F, Enum.KeyCode.ButtonR1)
end

return TackleController
