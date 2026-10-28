--!strict
-- Round flow and scoring: Waiting → Intermission → Playing → Results → ...
-- Owns the scores and broadcasts a full MatchState snapshot whenever
-- anything the HUD shows changes.

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local MatchLogic = require(ReplicatedStorage.Shared.Util.MatchLogic)
local Net = require(ServerScriptService.Server.Net)
local RateLimit = require(ServerScriptService.Server.Util.RateLimit)
local Agents = require(script.Parent.Agents)
local Parcel = require(script.Parent.Parcel)

type TeamId = Types.TeamId

local Match = {}

-- Fired with the round number just before players and bots respawn.
local roundStarting: Signal.Signal<number> = Signal.new()
Match.RoundStarting = roundStarting

local phase: Types.Phase = "Waiting"
local phaseEndsAt = 0
local scores: Types.TeamScores = { Ember = 0, Tide = 0 }
local winner: Types.Winner? = nil
local roundNumber = 0
local forceEnd = false

local function serverNow(): number
	return Workspace:GetServerTimeNow()
end

function Match.getPhase(): Types.Phase
	return phase
end

function Match.snapshot(): Types.MatchState
	local carrier = Parcel.getCarrier()
	local carrierPlayer = carrier and carrier.player
	return {
		phase = phase,
		phaseEndsAt = phaseEndsAt,
		scores = table.clone(scores),
		scoreToWin = Config.SCORE_TO_WIN,
		parcelStatus = Parcel.getStatus(),
		carrierName = carrier and carrier.name,
		carrierTeam = carrier and carrier.team,
		carrierUserId = carrierPlayer and carrierPlayer.UserId,
		winner = winner,
	}
end

function Match.broadcast()
	Net.fireAll("State", Match.snapshot())
end

local function setPhase(newPhase: Types.Phase, duration: number)
	phase = newPhase
	phaseEndsAt = if duration > 0 then serverNow() + duration else 0
	Match.broadcast()
end

local function secondsLeft(): number
	return phaseEndsAt - serverNow()
end

function Match.addScore(team: TeamId, amount: number)
	if phase ~= "Playing" then
		return
	end
	MatchLogic.addTo(scores, team, amount)
	if MatchLogic.isRoundOver(scores, Config.SCORE_TO_WIN, secondsLeft()) then
		-- Freeze the parcel now rather than on the round loop's next poll.
		Parcel.setActive(false)
	end
	Match.broadcast()
end

function Match.endRound()
	forceEnd = true
end

local function waitForPhaseEnd()
	while secondsLeft() > 0 do
		task.wait(0.25)
	end
end

local function playRound()
	roundNumber += 1
	scores = { Ember = 0, Tide = 0 }
	winner = nil
	forceEnd = false

	Agents.balanceHumans()
	Parcel.reset()
	Match.RoundStarting.fire(roundNumber)
	Agents.respawnPlayers()
	-- Short countdown so every character (and every bot rig, which loads
	-- asynchronously) is in place before the parcel goes live.
	setPhase("Intermission", Config.ROUND_COUNTDOWN_SECONDS)
	waitForPhaseEnd()

	setPhase("Playing", Config.ROUND_SECONDS)
	Parcel.setActive(true)
	Net.fireAll("Notice", { kind = "RoundStart" } :: Types.Notice)

	while
		not forceEnd
		and Agents.humanCount() > 0
		and not MatchLogic.isRoundOver(scores, Config.SCORE_TO_WIN, secondsLeft())
	do
		task.wait(0.2)
	end

	Parcel.setActive(false)
	Parcel.reset()
	local result = MatchLogic.winner(scores)
	winner = result
	setPhase("Results", Config.RESULTS_SECONDS)
	local notice: Types.Notice =
		{ kind = "RoundEnd", team = if result == "Draw" then nil else result }
	Net.fireAll("Notice", notice)
	waitForPhaseEnd()
end

local function onRequestState(player: Player)
	if not RateLimit.allow(player, "RequestState", 1, 3) then
		return
	end
	Net.fire(player, "State", Match.snapshot())
end

function Match.init()
	Net.on("RequestState", onRequestState)
	Parcel.Changed.connect(function()
		Match.broadcast()
	end)
	Parcel.Delivered.connect(function(agent)
		Match.addScore(agent.team, 1)
	end)
end

function Match.start()
	while true do
		if Agents.humanCount() < Config.MIN_HUMANS_TO_START then
			winner = nil
			setPhase("Waiting", 0)
			repeat
				task.wait(1)
			until Agents.humanCount() >= Config.MIN_HUMANS_TO_START
		end

		setPhase("Intermission", Config.INTERMISSION_SECONDS)
		waitForPhaseEnd()

		if Agents.humanCount() >= Config.MIN_HUMANS_TO_START then
			playRound()
		end
	end
end

return Match
