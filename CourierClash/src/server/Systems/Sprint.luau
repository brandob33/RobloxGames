--!strict
-- Sprint and slide, server side. Stamina lives here, not on the client:
-- the client only says "sprint key held/released" and "slide now", and this
-- system decides whether that's allowed. Players predict the result locally
-- (MovementController) for instant feel; Movement enforces the speed limit.
--
-- Replicated for the HUD and client prediction (Player attributes):
--   Stamina   number, rounded
--   Sprinting boolean, the server's verdict

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ServerScriptService.Server.Net)
local RateLimit = require(ServerScriptService.Server.Util.RateLimit)
local Agents = require(script.Parent.Agents)

type Agent = Agents.Agent

local Sprint = {}

local STEP_INTERVAL = 0.1
-- Sprint only drains stamina while actually moving.
local MOVING_SPEED = 2
-- Extra immunity after the client's slide ends, to cover its ping.
local SLIDE_GRACE = 0.15
-- Clients start their cooldown at the key press and we start ours when the
-- remote arrives, so latency jitter can make an honest slide look early.
local COOLDOWN_TOLERANCE = 0.3

local function publish(agent: Agent)
	local player = agent.player
	if not player then
		return
	end
	local stamina = math.floor(agent.stamina + 0.5)
	if player:GetAttribute("Stamina") ~= stamina then
		player:SetAttribute("Stamina", stamina)
	end
	if player:GetAttribute("Sprinting") ~= agent.sprinting then
		player:SetAttribute("Sprinting", agent.sprinting)
	end
end

local function canSprint(agent: Agent): boolean
	return agent.sprintWanted
		and not agent.exhausted
		and agent.stamina > 0
		and not Agents.isStunned(agent)
		and not Agents.isDiving(agent)
		and Agents.humanoid(agent) ~= nil
end

local function setSprinting(agent: Agent, sprinting: boolean)
	if agent.sprinting == sprinting then
		return
	end
	agent.sprinting = sprinting
	Agents.refreshSpeed(agent)
	publish(agent)
end

-- Shared by the Sprint remote and bots.
function Sprint.setWanted(agent: Agent, wanted: boolean)
	agent.sprintWanted = wanted
	setSprinting(agent, canSprint(agent))
end

-- Shared by the Slide remote and bots. Returns true if the slide happens.
function Sprint.trySlide(agent: Agent): boolean
	local now = os.clock()
	-- Slides are free: only the cooldown limits them.
	if
		Agents.isSliding(agent)
		or Agents.isStunned(agent)
		or Agents.isDiving(agent)
		or now < agent.slideReadyAt - COOLDOWN_TOLERANCE
		or not Agents.humanoid(agent)
	then
		return false
	end
	local duration = Config.SLIDE_SECONDS + SLIDE_GRACE
	agent.slidingUntil = now + duration
	agent.slideReadyAt = now + Config.SLIDE_COOLDOWN
	Agents.refreshSpeed(agent)
	publish(agent)
	Agents.refreshAt(agent, agent.slidingUntil)
	return true
end

-- Last sampled position per agent. "Moving" comes from displacement, not
-- AssemblyLinearVelocity, which a player's client fully controls.
local lastPositions: { [Agent]: Vector3 } = {}

local function step(dt: number)
	local now = os.clock()
	for _, agent in Agents.all() do
		local root = Agents.root(agent)
		local moving = false
		if root then
			local last = lastPositions[agent]
			local delta = if last then root.Position - last else Vector3.zero
			moving = Vector3.new(delta.X, 0, delta.Z).Magnitude / dt > MOVING_SPEED
			lastPositions[agent] = root.Position
		else
			lastPositions[agent] = nil
		end

		if agent.sprinting and moving then
			agent.stamina = math.max(0, agent.stamina - Config.SPRINT_DRAIN * dt)
			agent.staminaRegenAt = now + Config.STAMINA_REGEN_DELAY
			if agent.stamina <= 0 then
				agent.exhausted = true
			end
		elseif now >= agent.staminaRegenAt then
			agent.stamina = math.min(Config.STAMINA_MAX, agent.stamina + Config.STAMINA_REGEN * dt)
		end
		if agent.exhausted and agent.stamina >= Config.SPRINT_MIN_STAMINA then
			agent.exhausted = false
		end

		setSprinting(agent, canSprint(agent))
		publish(agent)
	end
end

local function onSprint(player: Player, wanted: unknown)
	if typeof(wanted) ~= "boolean" then
		return
	end
	-- Releasing can't be abused and dropping it would leave sprint stuck on,
	-- so only presses are rate limited.
	if wanted and not RateLimit.allow(player, "Sprint", 10, 10) then
		return
	end
	local agent = Agents.fromPlayer(player)
	if agent then
		Sprint.setWanted(agent, wanted)
	end
end

local function onSlide(player: Player)
	if not RateLimit.allow(player, "Slide", 3, 2) then
		return
	end
	local agent = Agents.fromPlayer(player)
	if agent then
		-- The client already started sliding; tell it to stop if we said no.
		Net.fire(player, "SlideResult", Sprint.trySlide(agent))
	end
end

function Sprint.init()
	Net.on("Sprint", onSprint)
	Net.on("Slide", onSlide)
	-- Stamina carries over a respawn so resetting isn't a free refill.
	Agents.CharacterLost.connect(function(agent)
		agent.sprinting = false
		agent.slidingUntil = 0
		lastPositions[agent] = nil
		publish(agent)
	end)
	Agents.Removed.connect(function(agent)
		lastPositions[agent] = nil
	end)
end

function Sprint.start()
	local accumulated = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulated += dt
		if accumulated < STEP_INTERVAL then
			return
		end
		step(accumulated)
		accumulated = 0
	end)
end

return Sprint
