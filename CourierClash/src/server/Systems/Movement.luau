--!strict
-- Server-side movement plausibility for human couriers. Players simulate
-- their own characters, so WalkSpeed and stuns are only advice to the
-- client; this check is what actually enforces them.
--
-- Every step we record (time, position, allowed speed) per player and
-- compare the newest sample against the one ~1 s old. The distance allowed
-- is the sum of each interval's speed limit, so stuns and carrier slowdown
-- are respected and a lag burst is judged against the whole window instead
-- of one short sample. A violation marks the agent "suspect" for a while:
-- suspects can't pick up or tackle, and a suspect carrier loses the parcel.

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Agents = require(script.Parent.Agents)

type Agent = Agents.Agent

type Sample = { time: number, position: Vector3, speed: number }
type Track = { character: Model, samples: { Sample } }

local Movement = {}

local STEP_INTERVAL = 0.1
local WINDOW = 1
local TOLERANCE = 1.2
-- Covers ping: a client keeps its old WalkSpeed until the new one arrives.
local SLACK = 4
local SUSPECT_SECONDS = 2

-- Fired with the agent and its last plausible position when a violation is found.
local flagged: Signal.Signal<{ agent: Agent, position: Vector3 }> = Signal.new()
Movement.Flagged = flagged

local tracks: { [Agent]: Track } = {}
local suspectUntil: { [Agent]: number } = {}

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function speedLimit(agent: Agent): number
	if Agents.isStunned(agent) then
		return 0
	end
	return if agent.carrying then Config.CARRIER_SPEED else Config.RUN_SPEED
end

function Movement.isSuspect(agent: Agent): boolean
	local untilTime = suspectUntil[agent]
	return untilTime ~= nil and os.clock() < untilTime
end

local function sample(agent: Agent, now: number)
	local character = agent.character
	local root = Agents.root(agent)
	if not character or not root or not Agents.humanoid(agent) then
		tracks[agent] = nil
		return
	end

	local track = tracks[agent]
	if not track or track.character ~= character then
		track = { character = character, samples = {} }
		tracks[agent] = track
	end
	local samples = track.samples
	table.insert(samples, { time = now, position = root.Position, speed = speedLimit(agent) })

	-- Keep exactly one sample older than the window as the reference point.
	while #samples > 2 and now - samples[2].time >= WINDOW do
		table.remove(samples, 1)
	end
	local oldest = samples[1]
	if now - oldest.time < WINDOW then
		return
	end

	local allowed = SLACK
	for i = 2, #samples do
		allowed += samples[i - 1].speed * (samples[i].time - samples[i - 1].time) * TOLERANCE
	end
	local moved = flat(root.Position - oldest.position).Magnitude
	if moved > allowed then
		suspectUntil[agent] = now + SUSPECT_SECONDS
		-- Restart the window so one violation isn't counted every step.
		track.samples = { { time = now, position = root.Position, speed = speedLimit(agent) } }
		flagged.fire({ agent = agent, position = oldest.position })
	end
end

-- Take a fresh sample now and report whether the agent's movement is
-- plausible. Parcel calls this right before a pickup, tackle or delivery so
-- a teleport can't land between two scheduled samples.
function Movement.verify(agent: Agent): boolean
	if not agent.player then
		return true
	end
	sample(agent, os.clock())
	return not Movement.isSuspect(agent)
end

function Movement.init()
	Agents.Removed.connect(function(agent)
		tracks[agent] = nil
		suspectUntil[agent] = nil
	end)
end

function Movement.start()
	local accumulated = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulated += dt
		if accumulated < STEP_INTERVAL then
			return
		end
		accumulated = 0
		local now = os.clock()
		for _, agent in Agents.all() do
			-- Bots are server-simulated; only players can lie about movement.
			if agent.player then
				sample(agent, now)
			end
		end
	end)
end

return Movement
