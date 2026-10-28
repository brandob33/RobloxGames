--!strict
-- The parcel: pickup, carrying, tackles and delivery. Everything here is
-- decided on the server from positions it can see — clients never report a
-- pickup or a delivery. The only client input is the Tackle remote, which
-- carries no arguments: the server picks the target and checks range.

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local Signal = require(ReplicatedStorage.Shared.Util.Signal)
local Net = require(ServerScriptService.Server.Net)
local RateLimit = require(ServerScriptService.Server.Util.RateLimit)
local Agents = require(script.Parent.Agents)
local Arena = require(script.Parent.Arena)
local Movement = require(script.Parent.Movement)

type Agent = Agents.Agent

local Parcel = {}

-- Fired whenever status or carrier changes (Match rebroadcasts state).
local changed: Signal.Signal<Types.ParcelStatus> = Signal.new()
Parcel.Changed = changed
-- Fired when a carrier reaches their own drop zone.
local delivered: Signal.Signal<Agent> = Signal.new()
Parcel.Delivered = delivered

local STEP_INTERVAL = 0.1
local CARRY_OFFSET = CFrame.new(0, 3.4, 0)
local PICKUP_MAX_HEIGHT = 6

local PARCEL_COLOR = Color3.fromRGB(240, 196, 64)
local RIBBON_COLOR = Color3.fromRGB(196, 40, 60)

local status: Types.ParcelStatus = "Home"
local carrier: Agent? = nil
local active = false
local parcelPart: Part
local weld: WeldConstraint? = nil
local lastCarrierPosition = Arena.PARCEL_HOME

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function notify(notice: Types.Notice)
	Net.fireAll("Notice", notice)
end

local function buildParcel(): Part
	local box = Instance.new("Part")
	box.Name = "Parcel"
	box.Size = Vector3.new(2.6, 2.6, 2.6)
	box.Color = PARCEL_COLOR
	box.Material = Enum.Material.SmoothPlastic
	box.Anchored = true
	box.CanCollide = false
	box.CanTouch = false
	box.CanQuery = false
	box.Massless = true
	box.CFrame = CFrame.new(Arena.PARCEL_HOME)

	-- Two ribbon bands so it reads as a wrapped package.
	for _, size in { Vector3.new(2.7, 2.7, 0.5), Vector3.new(0.5, 2.7, 2.7) } do
		local ribbon = Instance.new("Part")
		ribbon.Name = "Ribbon"
		ribbon.Size = size
		ribbon.Color = RIBBON_COLOR
		ribbon.Material = Enum.Material.SmoothPlastic
		ribbon.CanCollide = false
		ribbon.CanTouch = false
		ribbon.CanQuery = false
		ribbon.Massless = true
		ribbon.CFrame = box.CFrame
		local ribbonWeld = Instance.new("WeldConstraint")
		ribbonWeld.Part0 = box
		ribbonWeld.Part1 = ribbon
		ribbonWeld.Parent = ribbon
		ribbon.Parent = box
	end

	local highlight = Instance.new("Highlight")
	highlight.FillTransparency = 1
	highlight.OutlineColor = Color3.new(1, 1, 1)
	highlight.Parent = box

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(110, 30)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 3, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "PARCEL"
	label.TextScaled = true
	label.TextColor3 = PARCEL_COLOR
	label.TextStrokeTransparency = 0.2
	label.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Heavy)
	label.Parent = billboard
	billboard.Parent = box

	box.Parent = Workspace
	return box
end

local function setStatus(newStatus: Types.ParcelStatus)
	status = newStatus
	Parcel.Changed.fire(newStatus)
end

-- Detach from whoever holds it, restoring their speed.
local function releaseCarrier(): Agent?
	local previous = carrier
	carrier = nil
	if weld then
		weld:Destroy()
		weld = nil
	end
	if previous then
		previous.carrying = false
		Agents.refreshSpeed(previous)
	end
	return previous
end

local function placeAt(position: Vector3)
	parcelPart.Anchored = true
	parcelPart.CFrame = CFrame.new(position)
end

local function attach(agent: Agent, root: BasePart)
	releaseCarrier()
	parcelPart.Anchored = false
	parcelPart.CFrame = root.CFrame * CARRY_OFFSET
	local newWeld = Instance.new("WeldConstraint")
	newWeld.Part0 = root
	newWeld.Part1 = parcelPart
	newWeld.Parent = parcelPart
	weld = newWeld

	carrier = agent
	agent.carrying = true
	-- Burst of speed on pickup (also refreshes speed for carrying).
	Agents.boost(agent, Config.PICKUP_BOOST_SECONDS)
	lastCarrierPosition = root.Position

	setStatus("Carried")
	notify({ kind = "Pickup", team = agent.team, actorName = agent.name })
end

-- Knock the parcel loose at a position. The previous carrier can't grab it
-- straight back.
local function dropAt(position: Vector3)
	local previous = releaseCarrier()
	if previous then
		previous.immuneUntil = os.clock() + Config.DROP_IMMUNITY_SECONDS
	end
	placeAt(Arena.restPosition(position))
	setStatus("Loose")
end

function Parcel.reset()
	releaseCarrier()
	placeAt(Arena.PARCEL_HOME)
	setStatus("Home")
end

function Parcel.setActive(isActive: boolean)
	active = isActive
end

function Parcel.getStatus(): Types.ParcelStatus
	return status
end

function Parcel.getCarrier(): Agent?
	return carrier
end

function Parcel.getPosition(): Vector3
	return parcelPart.Position
end

-- Hand the parcel to an agent (QA cheats only).
function Parcel.forceGive(agent: Agent): boolean
	local root = Agents.root(agent)
	if not active or not root or not Agents.humanoid(agent) then
		return false
	end
	attach(agent, root)
	return true
end

-- Shared by the Tackle remote and bots. Starts the cooldown even on a miss
-- so spamming the button gains nothing. Returns true if the carrier was hit.
function Parcel.tackle(attacker: Agent): boolean
	local now = os.clock()
	if
		not active
		or now < attacker.tackleReadyAt
		or Agents.isStunned(attacker)
		or Agents.isDiving(attacker)
	then
		return false
	end
	if not Movement.verify(attacker) then
		return false
	end
	local root = Agents.root(attacker)
	if not root or not Agents.humanoid(attacker) then
		return false
	end
	attacker.tackleReadyAt = now + Config.TACKLE_COOLDOWN
	-- Every tackle is a committed dive, hit or miss.
	Agents.dive(attacker)

	local target = carrier
	if not target or target == attacker or target.team == attacker.team then
		return false
	end
	local targetRoot = Agents.root(target)
	if not targetRoot then
		return false
	end
	local offset = targetRoot.Position - root.Position
	if offset.Magnitude > Config.TACKLE_RANGE then
		return false
	end
	if Agents.isSliding(target) then
		-- Slid under it: the tackle whiffs and the cooldown is spent.
		notify({
			kind = "Dodged",
			team = target.team,
			actorName = target.name,
			targetName = attacker.name,
		})
		return false
	end

	-- Parcel pops forward, away from the tackler.
	local push = flat(offset)
	local direction = if push.Magnitude > 0.01 then push.Unit else Vector3.xAxis
	dropAt(targetRoot.Position + direction * 5)
	Agents.stun(target, Config.STUN_SECONDS)
	notify({
		kind = "Tackled",
		team = attacker.team,
		actorName = attacker.name,
		targetName = target.name,
	})
	return true
end

local function stepCarried(agent: Agent)
	local root = Agents.root(agent)
	if not root or not Agents.humanoid(agent) then
		dropAt(lastCarrierPosition)
		return
	end

	local zone = Arena.dropZoneCenter(agent.team)
	local inZone = flat(root.Position - zone).Magnitude <= Config.DELIVERY_RADIUS
	-- A failed check fires Movement.Flagged, which knocks the parcel loose.
	if inZone and not Movement.verify(agent) then
		return
	end
	lastCarrierPosition = root.Position
	if inZone then
		releaseCarrier()
		Parcel.Delivered.fire(agent)
		notify({ kind = "Delivered", team = agent.team, actorName = agent.name })
		Parcel.reset()
	end
end

local function stepFree(now: number)
	local parcelPosition = parcelPart.Position
	if Arena.isOutOfBounds(parcelPosition) then
		Parcel.reset()
		notify({ kind = "Returned" })
		return
	end

	local best: Agent? = nil
	local bestRoot: BasePart? = nil
	local bestDistance = Config.PICKUP_RADIUS
	for _, agent in Agents.all() do
		if
			now >= agent.immuneUntil
			and not Agents.isStunned(agent)
			and not Agents.isDiving(agent)
			and not Movement.isSuspect(agent)
			and Agents.humanoid(agent)
		then
			local root = Agents.root(agent)
			if root and math.abs(root.Position.Y - parcelPosition.Y) <= PICKUP_MAX_HEIGHT then
				local distance = flat(root.Position - parcelPosition).Magnitude
				if distance <= bestDistance then
					best, bestRoot, bestDistance = agent, root, distance
				end
			end
		end
	end
	if best and bestRoot and Movement.verify(best) then
		attach(best, bestRoot)
	end
end

local function step()
	if not active then
		return
	end
	local now = os.clock()
	local agent = carrier
	if status == "Carried" and agent then
		stepCarried(agent)
	else
		stepFree(now)
	end
end

local function onTackleRequest(player: Player)
	if not RateLimit.allow(player, "Tackle", 4, 4) then
		return
	end
	local agent = Agents.fromPlayer(player)
	if not agent then
		return
	end
	Parcel.tackle(agent)
	-- Reconcile the client's optimistic cooldown with the server's truth.
	Net.fire(player, "TackleCooldown", math.max(0, agent.tackleReadyAt - os.clock()))
end

local function onAgentLost(agent: Agent)
	if carrier == agent then
		dropAt(lastCarrierPosition)
	end
end

function Parcel.init()
	parcelPart = buildParcel()
	Net.on("Tackle", onTackleRequest)
	Agents.CharacterLost.connect(onAgentLost)
	Agents.Removed.connect(onAgentLost)
	Movement.Flagged.connect(function(flag)
		if carrier == flag.agent then
			dropAt(flag.position)
		end
	end)
end

function Parcel.start()
	local accumulated = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulated += dt
		if accumulated < STEP_INTERVAL then
			return
		end
		accumulated = 0
		step()
	end)
end

return Parcel
