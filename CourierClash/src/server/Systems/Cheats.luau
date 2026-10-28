--!strict
-- QA shortcuts for Studio playtests (see client DevKeys). The handler is
-- only connected in Studio, so in a live server the Cheat remote does nothing.

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Net = require(ServerScriptService.Server.Net)
local RateLimit = require(ServerScriptService.Server.Util.RateLimit)
local Agents = require(script.Parent.Agents)
local Match = require(script.Parent.Match)
local Parcel = require(script.Parent.Parcel)

local Cheats = {}

local function onCheat(player: Player, command: unknown)
	if not RateLimit.allow(player, "Cheat", 2, 3) then
		return
	end
	if typeof(command) ~= "string" then
		return
	end
	if command == "ScoreEmber" then
		Match.addScore("Ember", 1)
	elseif command == "ScoreTide" then
		Match.addScore("Tide", 1)
	elseif command == "EndRound" then
		Match.endRound()
	elseif command == "GiveParcel" then
		local agent = Agents.fromPlayer(player)
		if agent then
			Parcel.forceGive(agent)
		end
	end
end

function Cheats.init()
	if not RunService:IsStudio() then
		return
	end
	Net.on("Cheat", onCheat)
	print(
		"[Steal the Package] Studio cheats on: Shift+1 Ember +1, Shift+2 Tide +1, Shift+3 end round, Shift+4 take package"
	)
end

return Cheats
