--!strict
-- Tracks every courier in the match, human or bot, as an Agent. Other
-- systems (Parcel, Match, Bots) work on Agents so bots and players share the
-- exact same rules. Owns team assignment and walk speed.

local Players = game:GetService("Players")
local Teams = game:GetService("Teams")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local MatchLogic = require(ReplicatedStorage.Shared.Util.MatchLogic)

type TeamId = Types.TeamId

export type Agent = {
	name: string,
	team: TeamId,
	player: Player?, -- nil for bots
	character: Model?,
	carrying: boolean,
	stunnedUntil: number, -- os.clock()
	tackleReadyAt: number, -- os.clock()
	immuneUntil: number, -- os.clock(); can't pick the parcel up before this
	-- Sprint/slide state, owned by the Sprint system
	sprintWanted: boolean,
	sprinting: boolean,
	exhausted: boolean, -- ran dry; must regen to SPRINT_MIN_STAMINA first
	stamina: number,
	staminaRegenAt: number, -- os.clock()
	slidingUntil: number, -- os.clock(); tackles miss while sliding
	slideReadyAt: number, -- os.clock()
	boostUntil: number, -- os.clock(); pickup speed burst
	diveLungeUntil: number, -- os.clock(); tackle dive, lunging forward
	divingUntil: number, -- os.clock(); tackle dive, down and locked out
}

local Agents = {}

-- Fired when an agent's character dies or is removed, and when the agent
-- leaves the match. Parcel drops the parcel if that agent was carrying it.
local characterLost: Signal.Signal<Agent> = Signal.new()
Agents.CharacterLost = characterLost
local removed: Signal.Signal<Agent> = Signal.new()
Agents.Removed = removed
-- Fired after the server moves an agent (kickoff), so movement checks
-- don't count the jump as a teleport hack.
local teleported: Signal.Signal<{ agent: Agent, position: Vector3 }> = Signal.new()
Agents.Teleported = teleported
-- Fired with the new human count whenever a player joins, leaves or swaps team.
local humansChanged: Signal.Signal<number> = Signal.new()
Agents.HumansChanged = humansChanged

local byPlayer: { [Player]: Agent } = {}
local bots: { Agent } = {}
local teamObjects: { [TeamId]: Team } = {}
local characterConnections: { [Agent]: { RBXScriptConnection } } = {}

local function newAgent(name: string, team: TeamId, player: Player?): Agent
	return {
		name = name,
		team = team,
		player = player,
		character = nil,
		carrying = false,
		stunnedUntil = 0,
		tackleReadyAt = 0,
		immuneUntil = 0,
		sprintWanted = false,
		sprinting = false,
		exhausted = false,
		stamina = Config.STAMINA_MAX,
		staminaRegenAt = 0,
		slidingUntil = 0,
		slideReadyAt = 0,
		boostUntil = 0,
		diveLungeUntil = 0,
		divingUntil = 0,
	}
end

function Agents.all(): { Agent }
	local list = table.clone(bots)
	for _, agent in byPlayer do
		table.insert(list, agent)
	end
	return list
end

function Agents.bots(): { Agent }
	return table.clone(bots)
end

function Agents.fromPlayer(player: Player): Agent?
	return byPlayer[player]
end

function Agents.humanCounts(): Types.TeamScores
	local counts: Types.TeamScores = { Ember = 0, Tide = 0 }
	for _, agent in byPlayer do
		MatchLogic.addTo(counts, agent.team, 1)
	end
	return counts
end

function Agents.humanCount(): number
	local counts = Agents.humanCounts()
	return counts.Ember + counts.Tide
end

function Agents.root(agent: Agent): BasePart?
	local character = agent.character
	if not character or not character.Parent then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

-- The agent's Humanoid, only while alive.
function Agents.humanoid(agent: Agent): Humanoid?
	local character = agent.character
	if not character then
		return nil
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

function Agents.isStunned(agent: Agent): boolean
	return os.clock() < agent.stunnedUntil
end

-- The server sets walk speed (stunned < carrying < running). Players
-- simulate their own characters, so for them this is only advice; the
-- Movement system is what enforces it.
function Agents.isSliding(agent: Agent): boolean
	return os.clock() < agent.slidingUntil
end

function Agents.isDiving(agent: Agent): boolean
	return os.clock() < agent.divingUntil
end

function Agents.isBoosted(agent: Agent): boolean
	return os.clock() < agent.boostUntil
end

-- Top speed the agent is allowed right now. Movement enforces this for
-- players; refreshSpeed applies it to the Humanoid.
function Agents.speedLimit(agent: Agent): number
	local now = os.clock()
	if Agents.isStunned(agent) then
		return 0
	elseif Agents.isDiving(agent) then
		return if now < agent.diveLungeUntil then Config.DIVE_SPEED else 0
	elseif Agents.isSliding(agent) then
		return Config.SLIDE_SPEED
	elseif Agents.isBoosted(agent) then
		return Config.PICKUP_BOOST_SPEED
	elseif agent.sprinting then
		return if agent.carrying then Config.CARRIER_SPRINT_SPEED else Config.SPRINT_SPEED
	end
	return if agent.carrying then Config.CARRIER_SPEED else Config.RUN_SPEED
end

-- Pushes state to the character: WalkSpeed, plus attributes the local
-- MovementController reads to predict its own speed without waiting on
-- the server (Carrying, Stunned).
function Agents.refreshSpeed(agent: Agent)
	local humanoid = Agents.humanoid(agent)
	local character = agent.character
	if not humanoid or not character then
		return
	end
	if not agent.player then
		-- Players' WalkSpeed is set by their own MovementController from the
		-- attributes below; writing it here too would fight it for a frame.
		humanoid.WalkSpeed = Agents.speedLimit(agent) * Config.BOT_SPEED_FACTOR
	end
	character:SetAttribute("Carrying", agent.carrying)
	character:SetAttribute("Stunned", Agents.isStunned(agent))
	character:SetAttribute("Sliding", Agents.isSliding(agent))
	character:SetAttribute("Diving", Agents.isDiving(agent))
	character:SetAttribute("Boosted", Agents.isBoosted(agent))
end

-- Re-apply speed and attributes once a timed state has run out. task.delay
-- and os.clock() can disagree by a frame, so wait a hair past the deadline
-- and re-arm if it still hasn't passed; otherwise an attribute like Diving
-- could be republished as true with nothing left to clear it.
local REFRESH_MARGIN = 0.03

function Agents.refreshAt(agent: Agent, deadline: number)
	task.delay(math.max(0, deadline - os.clock()) + REFRESH_MARGIN, function()
		if os.clock() < deadline then
			Agents.refreshAt(agent, deadline)
		else
			Agents.refreshSpeed(agent)
		end
	end)
end

function Agents.boost(agent: Agent, seconds: number)
	agent.boostUntil = os.clock() + seconds
	Agents.refreshSpeed(agent)
	Agents.refreshAt(agent, agent.boostUntil)
end

-- Tackle dive: lunge, then lie on the ground unable to act.
function Agents.dive(agent: Agent)
	local now = os.clock()
	agent.diveLungeUntil = now + Config.DIVE_LUNGE_SECONDS
	agent.divingUntil = now + Config.DIVE_SECONDS
	agent.sprinting = false
	Agents.refreshSpeed(agent)
	Agents.refreshAt(agent, agent.diveLungeUntil)
	Agents.refreshAt(agent, agent.divingUntil)
end

-- Move an agent's character (kickoff). Clears timed states so everyone
-- starts the play fresh.
function Agents.teleport(agent: Agent, cframe: CFrame)
	local character = agent.character
	local root = Agents.root(agent)
	if not character or not root then
		return
	end
	agent.stunnedUntil = 0
	agent.slidingUntil = 0
	agent.boostUntil = 0
	agent.diveLungeUntil = 0
	agent.divingUntil = 0
	character:PivotTo(cframe)
	root.AssemblyLinearVelocity = Vector3.zero
	Agents.refreshSpeed(agent)
	teleported.fire({ agent = agent, position = cframe.Position })
end

function Agents.stun(agent: Agent, seconds: number)
	agent.stunnedUntil = os.clock() + seconds
	Agents.refreshSpeed(agent)
	Agents.refreshAt(agent, agent.stunnedUntil)
end

local function clearCharacterConnections(agent: Agent)
	local connections = characterConnections[agent]
	if connections then
		for _, connection in connections do
			connection:Disconnect()
		end
		characterConnections[agent] = nil
	end
end

-- Point an agent at a (new) character model, or nil when it goes away.
function Agents.setCharacter(agent: Agent, character: Model?)
	clearCharacterConnections(agent)
	if agent.character and agent.character ~= character then
		Agents.CharacterLost.fire(agent)
	end
	agent.character = character
	agent.stunnedUntil = 0
	if not character then
		return
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
		or character:WaitForChild("Humanoid", 5) :: Humanoid?
	if not humanoid or agent.character ~= character then
		return
	end
	characterConnections[agent] = {
		humanoid.Died:Connect(function()
			if agent.character == character then
				Agents.CharacterLost.fire(agent)
			end
		end),
	}
	Agents.refreshSpeed(agent)
end

function Agents.addBot(name: string, team: TeamId): Agent
	local agent = newAgent(name, team, nil)
	table.insert(bots, agent)
	return agent
end

function Agents.removeBot(agent: Agent)
	local index = table.find(bots, agent)
	if not index then
		return
	end
	table.remove(bots, index)
	local character = agent.character
	Agents.setCharacter(agent, nil)
	Agents.Removed.fire(agent)
	if character then
		character:Destroy()
	end
end

local function setTeam(agent: Agent, team: TeamId)
	agent.team = team
	local player = agent.player
	if player then
		player.Team = teamObjects[team]
	end
end

-- Even out human teams (called between rounds, before respawning).
function Agents.balanceHumans()
	local from, count = MatchLogic.balanceMove(Agents.humanCounts())
	if not from or count == 0 then
		return
	end
	local to = MatchLogic.otherTeam(from)
	for _, agent in byPlayer do
		if count == 0 then
			break
		end
		if agent.team == from then
			setTeam(agent, to)
			count -= 1
		end
	end
	Agents.HumansChanged.fire(Agents.humanCount())
end

function Agents.respawnPlayers()
	for player in byPlayer do
		task.spawn(function()
			if player.Parent then
				player:LoadCharacter()
			end
		end)
	end
end

local function onPlayerAdded(player: Player)
	if byPlayer[player] then
		return
	end
	local team = MatchLogic.pickTeamForJoin(Agents.humanCounts())
	local agent = newAgent(player.DisplayName, team, player)
	byPlayer[player] = agent
	setTeam(agent, team)
	-- Shift is the sprint key, so turn off Shift Lock for this player.
	player.DevEnableMouseLock = false

	player.CharacterAdded:Connect(function(character)
		Agents.setCharacter(agent, character)
	end)
	player.CharacterRemoving:Connect(function(character)
		if agent.character == character then
			Agents.setCharacter(agent, nil)
		end
	end)
	if player.Character then
		task.spawn(Agents.setCharacter, agent, player.Character)
	end

	Agents.HumansChanged.fire(Agents.humanCount())
end

local function onPlayerRemoving(player: Player)
	local agent = byPlayer[player]
	if not agent then
		return
	end
	byPlayer[player] = nil
	Agents.setCharacter(agent, nil)
	Agents.Removed.fire(agent)
	Agents.HumansChanged.fire(Agents.humanCount())
end

function Agents.teamObject(team: TeamId): Team
	return teamObjects[team]
end

function Agents.init()
	for _, team in Config.TEAM_IDS do
		local teamObject = Instance.new("Team")
		teamObject.Name = team
		teamObject.TeamColor = BrickColor.new(Config.TEAM_COLORS[team])
		teamObject.AutoAssignable = false
		teamObject.Parent = Teams
		teamObjects[team] = teamObject
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
end

function Agents.start()
	-- Players who joined before init connected (common in Studio Play Solo)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return Agents
