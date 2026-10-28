--!strict
-- Studio-only QA keys (hold Shift + 1..4). The server ignores the Cheat
-- remote outside Studio.

local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local Net = require(script.Parent.Parent.Net)

local DevKeys = {}

local BINDINGS: { [Enum.KeyCode]: Types.CheatCommand } = {
	[Enum.KeyCode.One] = "ScoreEmber",
	[Enum.KeyCode.Two] = "ScoreTide",
	[Enum.KeyCode.Three] = "EndRound",
	[Enum.KeyCode.Four] = "GiveParcel",
}

function DevKeys.init()
	if not RunService:IsStudio() then
		return
	end
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or not UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) then
			return
		end
		local command = BINDINGS[input.KeyCode]
		if command then
			Net.fire("Cheat", command)
		end
	end)
end

return DevKeys
