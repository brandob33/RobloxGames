--!strict
-- Bot couriers that top teams up to Config.TEAM_SIZE. Bots are Agents like
-- players and go through the same Parcel rules (pickup radius, tackle range
-- and cooldown); they just get their inputs from a simple brain here.

local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local MatchLogic = require(ReplicatedStorage.Shared.Util.MatchLogic)
local Agents = require(script.Parent.Agents)
local Arena = require(script.Parent.Arena)
local Match = require(script.Parent.Match)
local Parcel = require(script.Parent.Parcel)
local Shove = require(script.Parent.Shove)
local Sprint = require(script.Parent.Sprint)

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
	idleTrack: AnimationTrack?,
	runTrack: AnimationTrack?,
	-- Where the current dive is aimed (leads the carrier a little).
	diveTarget: Vector3,
}

local Bots = {}

local THINK_INTERVAL = 0.15
-- Chance per think tick to tackle an in-range enemy carrier, so bots are
-- beatable rather than frame-perfect.
local TACKLE_CHANCE = 0.45
local CHASERS_PER_TEAM = 3
local ESCORT_RADIUS = 35
local GUARD_SPACING = 25
-- Bots sprint when the thing they're after is this close.
local SPRINT_RANGE = 70
-- A carrying bot slides to dodge when a tackler gets this close.
local DODGE_RANGE = Config.TACKLE_RANGE + 4
local DODGE_CHANCE = 0.35
-- Chance per think tick to shove an opponent in range: high while
-- clearing a path for a teammate's carrier, low otherwise.
local SHOVE_ESCORT_CHANCE = 0.4
local SHOVE_CHANCE = 0.08

-- Roblox's default R15 animations. Bots are server-side NPCs, so the
-- character Animate script doesn't run for them; we drive idle/run here.
-- Without this they glide around in a T-pose, which reads as choppy.
local IDLE_ANIMATION = "rbxassetid://507766666"
local RUN_ANIMATION = "rbxassetid://507767714"
local RUN_ANIMATION_SPEED = 16

-- Bots don't collide with each other (no piling up or standing on heads).
local BOT_COLLISION_GROUP = "CourierClashBots"
-- Obstacles at most this tall are jumped; taller ones are walked around.
local JUMPABLE_HEIGHT = 4
local PROBE_DISTANCE = 5

local brains: { [Agent]: Brain } = {}
local obstacleParams = RaycastParams.new()
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

local function loadAnimations(brain: Brain, rig: Model)
	brain.idleTrack = nil
	brain.runTrack = nil
	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		local newAnimator = Instance.new("Animator")
		newAnimator.Parent = humanoid
		animator = newAnimator
	end
	local function load(id: string, priority: Enum.AnimationPriority): AnimationTrack?
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok, track = pcall(function()
			return (animator :: Animator):LoadAnimation(animation)
		end)
		if not ok or not track then
			return nil
		end
		track.Priority = priority
		track.Looped = true
		return track
	end
	brain.idleTrack = load(IDLE_ANIMATION, Enum.AnimationPriority.Idle)
	brain.runTrack = load(RUN_ANIMATION, Enum.AnimationPriority.Movement)
	if brain.idleTrack then
		brain.idleTrack:Play()
	end
end

-- Blend idle/run from the rig's actual speed.
local function animate(brain: Brain, root: BasePart)
	local run = brain.runTrack
	if not run then
		return
	end
	local velocity = root.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local agent = brain.agent
	if Agents.isSliding(agent) or Agents.isDiving(agent) then
		-- Hold the pose still; the slide/dive pose is drawn on clients.
		run:AdjustSpeed(0)
	elseif speed > 1.5 then
		if not run.IsPlaying then
			run:Play(0.15)
		end
		run:AdjustSpeed(speed / RUN_ANIMATION_SPEED)
	elseif run.IsPlaying then
		run:Stop(0.2)
	end
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
	-- Match hands out box spots, so a respawn never lands on a teammate.
	rig:PivotTo(Arena.spawnCFrame(agent.team, Match.claimSlot(agent)))
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.CollisionGroup = BOT_COLLISION_GROUP
		end
	end
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
	loadAnimations(brain, rig)

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
		idleTrack = nil,
		runTrack = nil,
		diveTarget = Vector3.zero,
	}
	brains[agent] = brain
	task.spawn(spawnBot, brain)
end

local function removeBot(agent: Agent)
	brains[agent] = nil
	Agents.removeBot(agent)
end

local function rebalance()
	local wanted = if Config.FILL_WITH_BOTS
		then MatchLogic.botsForTeams(Agents.humanCounts(), Config.TEAM_SIZE)
		else { Ember = 0, Tide = 0 }
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

local function near(a: Vector3, b: Vector3, range: number): boolean
	return flat(a - b).Magnitude <= range
end

-- The package this bot cares about: the nearest one still in play.
local function focusPackage(position: Vector3): number
	local best = 1
	local bestDistance = math.huge
	for index = 1, Parcel.count() do
		local distance = flat(Parcel.getPosition(index) - position).Magnitude
		if not Parcel.isDelivered(index) and distance < bestDistance then
			best, bestDistance = index, distance
		end
	end
	return best
end

-- Where to go, and whether it's worth sprinting there.
local function chooseTarget(brain: Brain, position: Vector3): (Vector3, boolean)
	local agent = brain.agent
	local ownZone = Arena.dropZoneCenter(agent.team)
	local lane = (brain.slot % 5) - 2 -- -2..2, spreads teammates out

	if agent.carrying then
		return ownZone, true
	end

	local index = focusPackage(position)
	local carrier = Parcel.getCarrier(index)
	if carrier then
		local carrierRoot = Agents.root(carrier)
		if carrierRoot then
			if carrier.team ~= agent.team then
				return carrierRoot.Position, near(position, carrierRoot.Position, SPRINT_RANGE)
			end
			-- Teammate has it: body-block the closest threat, else run alongside.
			local threat = nearestEnemy(carrierRoot.Position, agent.team, ESCORT_RADIUS)
			if threat then
				return threat, true
			end
			return carrierRoot.Position + Vector3.new(0, 0, lane * 8), false
		end
	end

	-- Package is free: the closest few chase it, the rest hold guard lanes.
	local parcelPosition = Parcel.getPosition(index)
	if rankByDistance(agent, parcelPosition, position) <= CHASERS_PER_TEAM then
		return parcelPosition, near(position, parcelPosition, SPRINT_RANGE)
	end
	local guard = parcelPosition:Lerp(ownZone, 0.55)
	return Vector3.new(guard.X, 0, lane * GUARD_SPACING), false
end

local function tryDodge(agent: Agent, position: Vector3)
	if not agent.carrying then
		return
	end
	if nearestEnemy(position, agent.team, DODGE_RANGE) and random:NextNumber() < DODGE_CHANCE then
		Sprint.trySlide(agent)
	end
end

local DIVE_LEAD_SECONDS = 0.2

-- The closest enemy carrier that can be tackled right now.
local function nearestEnemyCarrier(agent: Agent, position: Vector3): BasePart?
	local best: BasePart? = nil
	local bestDistance = math.huge
	for index = 1, Parcel.count() do
		local carrier = Parcel.getCarrier(index)
		local carrierRoot = carrier
			and carrier.team ~= agent.team
			and not Parcel.isProtected(index)
			and Agents.root(carrier)
		if carrierRoot then
			local distance = (carrierRoot.Position - position).Magnitude
			if distance < bestDistance then
				best, bestDistance = carrierRoot, distance
			end
		end
	end
	return best
end

local function tryTackle(brain: Brain, position: Vector3)
	local agent = brain.agent
	if agent.carrying then
		return
	end
	local carrierRoot = nearestEnemyCarrier(agent, position)
	if not carrierRoot then
		return
	end
	if (carrierRoot.Position - position).Magnitude <= Config.TACKLE_RANGE * 0.85 then
		if random:NextNumber() < TACKLE_CHANCE then
			-- Aim the dive where the carrier is heading; it has to connect.
			local velocity = carrierRoot.AssemblyLinearVelocity
			brain.diveTarget = carrierRoot.Position
				+ Vector3.new(velocity.X, 0, velocity.Z) * DIVE_LEAD_SECONDS
			Parcel.tackle(agent)
		end
	end
end

-- True if a teammate carrying a package is close by.
local function escorting(agent: Agent, position: Vector3): boolean
	for index = 1, Parcel.count() do
		local carrier = Parcel.getCarrier(index)
		local carrierRoot = carrier
			and carrier ~= agent
			and carrier.team == agent.team
			and Agents.root(carrier)
		if carrierRoot and near(position, carrierRoot.Position, ESCORT_RADIUS) then
			return true
		end
	end
	return false
end

local function tryShove(agent: Agent, position: Vector3)
	if agent.carrying or os.clock() < agent.shoveReadyAt then
		return
	end
	if not nearestEnemy(position, agent.team, Config.SHOVE_RANGE) then
		return
	end
	local chance = if escorting(agent, position) then SHOVE_ESCORT_CHANCE else SHOVE_CHANCE
	if random:NextNumber() < chance then
		Shove.tryShove(agent)
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

	-- Stuck: jump only if a low obstacle is in front, otherwise (a tall
	-- pillar, or another courier) step around it. Jumping on people is
	-- what made bots stack.
	if toTarget.Magnitude > 4 and moved < 0.5 and not Agents.isStunned(brain.agent) then
		brain.stuckTicks += 1
	else
		brain.stuckTicks = 0
	end
	if brain.stuckTicks >= 2 and toTarget.Magnitude > 0.01 then
		-- Probe at knee height so low hedges and crates are seen.
		local knee = Vector3.new(position.X, 1.2, position.Z)
		local hit = Workspace:Raycast(knee, toTarget.Unit * PROBE_DISTANCE, obstacleParams)
		local part = hit and hit.Instance
		if part and part:IsA("BasePart") and part.Size.Y <= JUMPABLE_HEIGHT then
			humanoid.Jump = true
		else
			brain.stuckTicks = 4
		end
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
	animate(brain, root)
	if Agents.isKnockedBack(agent) then
		-- Keep flying the way the shove sent us.
		humanoid:MoveTo(position + agent.knockbackDirection * Config.SHOVE_SPEED)
		return
	end
	if Agents.isDiving(agent) then
		-- Lunge forward, then lie still until the dive ends.
		local lunging = os.clock() < agent.diveLungeUntil
		local aim = flat(brain.diveTarget - position)
		local heading = if aim.Magnitude > 0.5 then aim.Unit else root.CFrame.LookVector
		humanoid:MoveTo(if lunging then position + heading * 12 else position)
		return
	end
	if
		Match.getPhase() ~= "Playing"
		or Match.isLocked()
		or not Parcel.isActive()
		or Agents.isStunned(agent)
	then
		Sprint.setWanted(agent, false)
		humanoid:MoveTo(position)
		return
	end
	tryTackle(brain, position)
	tryDodge(agent, position)
	tryShove(agent, position)
	local target, sprint = chooseTarget(brain, position)
	Sprint.setWanted(agent, sprint)
	steer(brain, humanoid, position, target, now)
end

function Bots.init()
	if not PhysicsService:IsCollisionGroupRegistered(BOT_COLLISION_GROUP) then
		PhysicsService:RegisterCollisionGroup(BOT_COLLISION_GROUP)
	end
	PhysicsService:CollisionGroupSetCollidable(BOT_COLLISION_GROUP, BOT_COLLISION_GROUP, false)
	botFolder = Instance.new("Folder")
	botFolder.Name = "CourierClashBots"
	botFolder.Parent = Workspace

	Agents.HumansChanged.connect(function()
		rebalance()
	end)
	-- Match's kickoff places everyone, so a new round only needs the counts.
	Match.RoundStarting.connect(function()
		rebalance()
	end)
end

function Bots.start()
	-- Arena is built in its init(), which has run by now.
	obstacleParams.FilterType = Enum.RaycastFilterType.Include
	local arena = Workspace:FindFirstChild("CourierClashArena")
	if arena then
		obstacleParams.FilterDescendantsInstances = { arena }
	end
	while true do
		task.wait(THINK_INTERVAL)
		local now = os.clock()
		for _, brain in brains do
			think(brain, now)
		end
	end
end

return Bots
