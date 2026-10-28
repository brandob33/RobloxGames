--!strict
-- Bot couriers that top teams up to Config.TEAM_SIZE. Bots are Agents like
-- players and go through the same Parcel rules (pickup radius, tackle range
-- and cooldown); they just get their inputs from a simple brain here.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local MatchLogic = require(ReplicatedStorage.Shared.Util.MatchLogic)
local Agents = require(script.Parent.Agents)
local Arena = require(script.Parent.Arena)
local Match = require(script.Parent.Match)
local Parcel = require(script.Parent.Parcel)

type Agent = Agents.Agent
type TeamId = Types.TeamId

type Brain = {
	agent: Agent,
	slot: number,
	lastPosition: Vector3,
	stuckTicks: number,
	sidestepUntil: number,
	sidestepSign: number,
	spawning: boolean,
}

local Bots = {}

local THINK_INTERVAL = 0.2
-- Chance per think tick to tackle an in-range enemy carrier, so bots are
-- beatable rather than frame-perfect.
local TACKLE_CHANCE = 0.45
local CHASERS_PER_TEAM = 2
local ESCORT_RADIUS = 35
local GUARD_SPREAD = 22

local brains: { [Agent]: Brain } = {}
local botFolder: Folder
local nextBotNumber = 0
local random = Random.new()

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function buildRig(agent: Agent): Model?
	local color = Config.TEAM_COLORS[agent.team]
	local description = Instance.new("HumanoidDescription")
	description.HeadColor = color
	description.TorsoColor = color
	description.LeftArmColor = color
	description.RightArmColor = color
	description.LeftLegColor = color
	description.RightLegColor = color

	local ok, rig = pcall(function()
		return Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	end)
	if not ok or not rig then
		warn("[Bots] failed to build rig:", rig)
		return nil
	end
	rig.Name = agent.name
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.DisplayName = agent.name
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	end
	return rig
end

local function spawnBot(brain: Brain)
	if brain.spawning then
		return
	end
	brain.spawning = true
	local agent = brain.agent
	local old = agent.character
	Agents.setCharacter(agent, nil)
	if old then
		old:Destroy()
	end

	local rig = buildRig(agent)
	if not rig or brains[agent] ~= brain then
		-- bot was removed while the rig was loading
		if rig then
			rig:Destroy()
		end
		brain.spawning = false
		return
	end
	local position = Arena.spawnPosition(agent.team, brain.slot)
	rig:PivotTo(CFrame.lookAt(position, Vector3.new(0, position.Y, 0)))
	rig.Parent = botFolder

	local root = rig:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		-- Server simulates bots, so their positions can't be spoofed.
		pcall(function()
			root:SetNetworkOwner(nil)
		end)
		brain.lastPosition = root.Position
	end
	brain.stuckTicks = 0
	brain.spawning = false
	Agents.setCharacter(agent, rig)

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Died:Connect(function()
			task.delay(Players.RespawnTime, function()
				if brains[agent] == brain and agent.character == rig then
					spawnBot(brain)
				end
			end)
		end)
	end
end

local function freeSlot(team: TeamId): number
	local used: { [number]: boolean } = {}
	for agent, brain in brains do
		if agent.team == team then
			used[brain.slot] = true
		end
	end
	local slot = 1
	while used[slot] do
		slot += 1
	end
	return slot
end

local function addBot(team: TeamId)
	nextBotNumber += 1
	local agent = Agents.addBot("Courier Bot " .. nextBotNumber, team)
	local brain: Brain = {
		agent = agent,
		slot = freeSlot(team),
		lastPosition = Vector3.zero,
		stuckTicks = 0,
		sidestepUntil = 0,
		sidestepSign = 1,
		spawning = false,
	}
	brains[agent] = brain
	task.spawn(spawnBot, brain)
end

local function removeBot(agent: Agent)
	brains[agent] = nil
	Agents.removeBot(agent)
end

local function rebalance()
	local wanted = MatchLogic.botsForTeams(Agents.humanCounts(), Config.TEAM_SIZE)
	for _, team in Config.TEAM_IDS do
		local current: { Agent } = {}
		for _, agent in Agents.bots() do
			if agent.team == team then
				table.insert(current, agent)
			end
		end
		local want = MatchLogic.scoreOf(wanted, team)
		for _ = #current + 1, want do
			addBot(team)
		end
		for i = #current, want + 1, -1 do
			removeBot(current[i])
		end
	end
end

local function nearestEnemy(position: Vector3, team: TeamId, maxDistance: number): Vector3?
	local best: Vector3? = nil
	local bestDistance = maxDistance
	for _, other in Agents.all() do
		if other.team ~= team then
			local root = Agents.root(other)
			if root then
				local distance = flat(root.Position - position).Magnitude
				if distance < bestDistance then
					best, bestDistance = root.Position, distance
				end
			end
		end
	end
	return best
end

-- Rank of this bot among its living teammates by distance to a point (1 = closest).
local function rankByDistance(agent: Agent, point: Vector3, myPosition: Vector3): number
	local myDistance = flat(myPosition - point).Magnitude
	local rank = 1
	for _, other in Agents.all() do
		if other ~= agent and other.team == agent.team then
			local root = Agents.root(other)
			if root and flat(root.Position - point).Magnitude < myDistance then
				rank += 1
			end
		end
	end
	return rank
end

local function chooseTarget(brain: Brain, position: Vector3): Vector3
	local agent = brain.agent
	local carrier = Parcel.getCarrier()
	local ownZone = Arena.dropZoneCenter(agent.team)

	if carrier == agent then
		return ownZone
	end

	if carrier then
		local carrierRoot = Agents.root(carrier)
		if carrierRoot then
			if carrier.team ~= agent.team then
				return carrierRoot.Position
			end
			-- Teammate has it: body-block the closest threat, else run alongside.
			local threat = nearestEnemy(carrierRoot.Position, agent.team, ESCORT_RADIUS)
			if threat then
				return threat
			end
			local side = if brain.slot % 2 == 0 then 1 else -1
			return carrierRoot.Position + Vector3.new(0, 0, side * 8)
		end
	end

	-- Parcel is free: the closest couple chase it, the rest guard midfield.
	local parcelPosition = Parcel.getPosition()
	if rankByDistance(agent, parcelPosition, position) <= CHASERS_PER_TEAM then
		return parcelPosition
	end
	local guard = parcelPosition:Lerp(ownZone, 0.55)
	local side = if brain.slot % 2 == 0 then 1 else -1
	return Vector3.new(guard.X, 0, side * GUARD_SPREAD)
end

local function tryTackle(agent: Agent, position: Vector3)
	local carrier = Parcel.getCarrier()
	if not carrier or carrier.team == agent.team then
		return
	end
	local carrierRoot = Agents.root(carrier)
	if not carrierRoot then
		return
	end
	if (carrierRoot.Position - position).Magnitude <= Config.TACKLE_RANGE * 0.85 then
		if random:NextNumber() < TACKLE_CHANCE then
			Parcel.tackle(agent)
		end
	end
end

local function steer(
	brain: Brain,
	humanoid: Humanoid,
	position: Vector3,
	target: Vector3,
	now: number
)
	local toTarget = flat(target - position)
	local moved = flat(position - brain.lastPosition).Magnitude
	brain.lastPosition = position

	-- Stuck on a crate or another courier: jump, then sidestep.
	if toTarget.Magnitude > 4 and moved < 0.5 and not Agents.isStunned(brain.agent) then
		brain.stuckTicks += 1
	else
		brain.stuckTicks = 0
	end
	if brain.stuckTicks >= 2 then
		humanoid.Jump = true
	end
	if brain.stuckTicks >= 4 then
		brain.sidestepUntil = now + 0.8
		brain.sidestepSign = if random:NextNumber() < 0.5 then 1 else -1
		brain.stuckTicks = 0
	end

	local goal = target
	if now < brain.sidestepUntil and toTarget.Magnitude > 0.01 then
		local forward = toTarget.Unit
		local perpendicular = Vector3.new(-forward.Z, 0, forward.X) * brain.sidestepSign
		goal = position + perpendicular * 10 + forward * 2
	end
	humanoid:MoveTo(goal)
end

local function think(brain: Brain, now: number)
	local agent = brain.agent
	local humanoid = Agents.humanoid(agent)
	local root = Agents.root(agent)
	if brain.spawning or not humanoid or not root then
		return
	end
	local position = root.Position
	if Arena.isOutOfBounds(position) then
		task.spawn(spawnBot, brain)
		return
	end
	if Match.getPhase() ~= "Playing" or Agents.isStunned(agent) then
		humanoid:MoveTo(position)
		return
	end
	tryTackle(agent, position)
	steer(brain, humanoid, position, chooseTarget(brain, position), now)
end

function Bots.init()
	botFolder = Instance.new("Folder")
	botFolder.Name = "CourierClashBots"
	botFolder.Parent = Workspace

	Agents.HumansChanged.connect(function()
		rebalance()
	end)
	Match.RoundStarting.connect(function()
		rebalance()
		for _, brain in brains do
			task.spawn(spawnBot, brain)
		end
	end)
end

function Bots.start()
	while true do
		task.wait(THINK_INTERVAL)
		local now = os.clock()
		for _, brain in brains do
			think(brain, now)
		end
	end
end

return Bots
