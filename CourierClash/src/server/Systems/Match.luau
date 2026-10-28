--!strict
-- Round flow and scoring: Waiting → Lobby → Playing → Results → Lobby ...
-- Owns the scores and broadcasts a full MatchState snapshot whenever
-- anything the HUD shows changes.
--
-- Players wait in the lobby between games. A round starts with a kickoff:
-- everyone is placed in their team's spawn box, the gates close for
-- KICKOFF_SECONDS, then open. Every delivery triggers another kickoff, and
-- the round clock pauses while the gates are shut.

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
local Arena = require(script.Parent.Arena)
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
local lockedUntil = 0
local kickoffPending = false
-- Spawn-box slot per agent for the current kickoff.
local slots: { [Agents.Agent]: number } = {}

local ENFORCE_INTERVAL = 0.25

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
		lockedUntil = lockedUntil,
	}
end

function Match.isLocked(): boolean
	return lockedUntil > 0
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
	-- Freeze the parcel now rather than on the round loop's next poll; the
	-- loop either ends the round or runs the next kickoff.
	Parcel.setActive(false)
	kickoffPending = true
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

local function slotFor(agent: Agents.Agent, counters: Types.TeamScores): number
	local slot = slots[agent]
	if not slot then
		MatchLogic.addTo(counters, agent.team, 1)
		slot = MatchLogic.scoreOf(counters, agent.team)
		slots[agent] = slot
	end
	return slot
end

-- Highest slot taken per team, so new agents get the next free one.
local function usedCounters(): Types.TeamScores
	local counters: Types.TeamScores = { Ember = 0, Tide = 0 }
	for agent, slot in slots do
		if slot > MatchLogic.scoreOf(counters, agent.team) then
			MatchLogic.addTo(counters, agent.team, slot - MatchLogic.scoreOf(counters, agent.team))
		end
	end
	return counters
end

-- This agent's spawn-box slot, claiming a free one if it has none. Bots
-- respawn here too, so nobody lands on a teammate's spot.
function Match.claimSlot(agent: Agents.Agent): number
	return slotFor(agent, usedCounters())
end

-- Put couriers in their team's spawn boxes (players too, unless it's lobby
-- time and they belong in the lobby).
local function placeTeams(includePlayers: boolean)
	slots = {}
	local counters: Types.TeamScores = { Ember = 0, Tide = 0 }
	for _, agent in Agents.all() do
		if includePlayers or not agent.player then
			Agents.teleport(agent, Arena.spawnCFrame(agent.team, slotFor(agent, counters)))
		end
	end
end

-- Send anyone (including late joiners and respawns) back where they belong
-- for this phase: their spawn box during kickoff, the lobby otherwise.
local function enforcePlacement(inLobby: boolean)
	local counters = usedCounters()
	for _, agent in Agents.all() do
		local root = Agents.root(agent)
		if root then
			if inLobby and agent.player then
				if not Arena.isInLobby(root.Position) then
					Agents.teleport(agent, Arena.lobbyCFrame())
				end
			elseif not Arena.isInSpawnBox(agent.team, root.Position) then
				Agents.teleport(agent, Arena.spawnCFrame(agent.team, slotFor(agent, counters)))
			end
		end
	end
end

-- Lock everyone in their spawn boxes for KICKOFF_SECONDS, then release
-- with the given notice.
local function kickoff(releaseNotice: Types.Notice)
	kickoffPending = false
	Parcel.setActive(false)
	Parcel.reset()
	Arena.setGatesOpen(false)
	placeTeams(true)
	lockedUntil = serverNow() + Config.KICKOFF_SECONDS
	if phase == "Playing" and phaseEndsAt > 0 then
		-- Pause the round clock while the gates are shut.
		phaseEndsAt += Config.KICKOFF_SECONDS
	end
	Match.broadcast()

	while serverNow() < lockedUntil and not forceEnd do
		enforcePlacement(false)
		task.wait(math.clamp(lockedUntil - serverNow(), 0, ENFORCE_INTERVAL))
	end

	lockedUntil = 0
	if forceEnd then
		-- Round is over; Results takes it from here with the gates shut.
		Match.broadcast()
		return
	end
	Arena.setGatesOpen(true)
	Parcel.setActive(true)
	Net.fireAll("Notice", releaseNotice)
	Match.broadcast()
end

local function playRound()
	roundNumber += 1
	scores = { Ember = 0, Tide = 0 }
	winner = nil
	forceEnd = false

	Agents.balanceHumans()
	Parcel.reset()
	Match.RoundStarting.fire(roundNumber)

	phase = "Playing"
	phaseEndsAt = 0
	kickoff({ kind = "RoundStart" })
	phaseEndsAt = serverNow() + Config.ROUND_SECONDS
	Match.broadcast()

	-- Re-check right after a kickoff so a score made during one (QA cheat)
	-- ends the round before the parcel is live.
	while
		not forceEnd
		and Agents.humanCount() > 0
		and not MatchLogic.isRoundOver(scores, Config.SCORE_TO_WIN, secondsLeft())
	do
		if kickoffPending then
			kickoff({ kind = "Go" })
		else
			task.wait(0.2)
		end
	end
	kickoffPending = false

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
	Agents.Removed.connect(function(agent)
		slots[agent] = nil
	end)
end

-- Lobby time: players in the lobby, bots parked in their closed boxes.
local function lobbyUntil(condition: () -> boolean)
	Arena.setGatesOpen(false)
	placeTeams(false)
	enforcePlacement(true)
	while not condition() do
		enforcePlacement(true)
		task.wait(ENFORCE_INTERVAL)
	end
end

function Match.start()
	while true do
		if Agents.humanCount() < Config.MIN_HUMANS_TO_START then
			winner = nil
			setPhase("Waiting", 0)
			lobbyUntil(function()
				return Agents.humanCount() >= Config.MIN_HUMANS_TO_START
			end)
		end

		setPhase("Lobby", Config.LOBBY_SECONDS)
		lobbyUntil(function()
			return secondsLeft() <= 0
		end)

		if Agents.humanCount() >= Config.MIN_HUMANS_TO_START then
			playRound()
		end
	end
end

return Match
