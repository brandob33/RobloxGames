--!strict
-- Shove: push the nearest opponent in front of you back a few studs and
-- stagger them. Lets the carrier's teammates clear tacklers out of the way
-- (and defenders peel escorts off). The Shove remote carries no arguments:
-- the server picks the target and checks range, facing and cooldown.
--
-- Carriers can't shove (they have the juke). A sliding target slips past
-- it, and a carrier still under steal protection can't be shoved.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Shared.Config)
local Net = require(ServerScriptService.Server.Net)
local RateLimit = require(ServerScriptService.Server.Util.RateLimit)
local Agents = require(script.Parent.Agents)
local Movement = require(script.Parent.Movement)
local Parcel = require(script.Parent.Parcel)

type Agent = Agents.Agent

local Shove = {}

local SHOVE_POSE_SECONDS = 0.25
local SHOVE_HEIGHT = 5
-- How far off your facing a target can be (dot product; 0.2 ≈ 78°).
local SHOVE_FACING = 0.2

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

-- The closest opponent in range in front of the shover.
local function findTarget(attacker: Agent, root: BasePart): (Agent?, Vector3)
	local facing = flat(root.CFrame.LookVector)
	facing = if facing.Magnitude > 0.01 then facing.Unit else Vector3.xAxis
	local best: Agent? = nil
	local bestDirection = facing
	local bestDistance = Config.SHOVE_RANGE
	for _, other in Agents.all() do
		if other.team ~= attacker.team and Agents.humanoid(other) then
			local otherRoot = Agents.root(other)
			if otherRoot then
				local offset = otherRoot.Position - root.Position
				local distance = flat(offset).Magnitude
				if distance <= bestDistance and math.abs(offset.Y) <= SHOVE_HEIGHT then
					local direction = if distance > 0.01 then flat(offset).Unit else facing
					if direction:Dot(facing) >= SHOVE_FACING then
						best, bestDirection, bestDistance = other, direction, distance
					end
				end
			end
		end
	end
	return best, bestDirection
end

-- Move the target's body. Players simulate their own characters, so their
-- client applies the knockback; bots are pushed here.
local function applyKnockback(target: Agent, direction: Vector3)
	Agents.knockback(target, direction)
	local player = target.player
	if player then
		Net.fire(player, "Shoved", direction)
		return
	end
	local root = Agents.root(target)
	local humanoid = Agents.humanoid(target)
	if root and humanoid then
		local velocity = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(
			direction.X * Config.SHOVE_SPEED,
			velocity.Y,
			direction.Z * Config.SHOVE_SPEED
		)
		humanoid:MoveTo(root.Position + direction * Config.SHOVE_SPEED)
	end
end

-- Shared by the Shove remote and bots. Starts the cooldown even on a miss.
-- Returns true if a shove went out.
function Shove.tryShove(attacker: Agent): boolean
	local now = os.clock()
	if
		not Parcel.isActive()
		or now < attacker.shoveReadyAt
		or attacker.carrying
		or Agents.isStunned(attacker)
		or Agents.isDiving(attacker)
		or Agents.isKnockedBack(attacker)
	then
		return false
	end
	local root = Agents.root(attacker)
	if not root or not Agents.humanoid(attacker) or not Movement.verify(attacker) then
		return false
	end
	attacker.shoveReadyAt = now + Config.SHOVE_COOLDOWN
	attacker.shovingUntil = now + SHOVE_POSE_SECONDS
	Agents.refreshSpeed(attacker)
	Agents.refreshAt(attacker, attacker.shovingUntil)

	local target, direction = findTarget(attacker, root)
	if
		target
		and not Agents.isSliding(target)
		and now >= target.shoveImmuneUntil
		and not Parcel.isAgentProtected(target)
	then
		applyKnockback(target, direction)
	end
	return true
end

local function onShoveRequest(player: Player)
	if not RateLimit.allow(player, "Shove", 4, 4) then
		return
	end
	local agent = Agents.fromPlayer(player)
	if not agent then
		return
	end
	Shove.tryShove(agent)
	-- Reconcile the client's optimistic cooldown with the server's truth.
	Net.fire(player, "ShoveCooldown", math.max(0, agent.shoveReadyAt - os.clock()))
end

function Shove.init()
	Net.on("Shove", onShoveRequest)
end

return Shove
