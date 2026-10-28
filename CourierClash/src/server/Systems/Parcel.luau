--!strict
-- The packages: pickup, carrying, tackles and delivery. There are
-- Config.PACKAGE_COUNT of them (one left, one right), each with its own
-- carrier; a courier carries at most one. Everything here is decided on the
-- server from positions it can see — clients never report a pickup or a
-- delivery. The only client input is the Tackle remote, which carries no
-- arguments: the server picks the target and checks range.

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

type Package = {
	index: number,
	home: Vector3,
	part: Part,
	status: Types.ParcelStatus,
	carrier: Agent?,
	weld: WeldConstraint?,
	lastCarrierPosition: Vector3,
	-- os.clock() until which the current carrier can't be tackled.
	protectedUntil: number,
	shield: ForceField?,
}

local Parcel = {}

-- Fired with the package index whenever a status or carrier changes
-- (Match rebroadcasts state).
local changed: Signal.Signal<number> = Signal.new()
Parcel.Changed = changed
-- Fired when a carrier reaches their own drop zone.
local delivered: Signal.Signal<Agent> = Signal.new()
Parcel.Delivered = delivered
-- Fired with the tackler when a tackle knocks a package loose.
local tackleLanded: Signal.Signal<Agent> = Signal.new()
Parcel.TackleLanded = tackleLanded

local STEP_INTERVAL = 0.1
local CARRY_OFFSET = CFrame.new(0, 3.4, 0)
local PICKUP_MAX_HEIGHT = 6

local PARCEL_COLOR = Color3.fromRGB(240, 196, 64)
local RIBBON_COLOR = Color3.fromRGB(196, 40, 60)

local packages: { Package } = {}
local active = false

local function flat(vector: Vector3): Vector3
	return Vector3.new(vector.X, 0, vector.Z)
end

local function notify(notice: Types.Notice)
	Net.fireAll("Notice", notice)
end

local function buildPart(index: number, home: Vector3): Part
	local box = Instance.new("Part")
	box.Name = "Parcel" .. index
	box.Size = Vector3.new(2.6, 2.6, 2.6)
	box.Color = PARCEL_COLOR
	box.Material = Enum.Material.SmoothPlastic
	box.Anchored = true
	box.CanCollide = false
	box.CanTouch = false
	box.CanQuery = false
	box.Massless = true
	box.CFrame = CFrame.new(home)

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
	label.Text = "PACKAGE"
	label.TextScaled = true
	label.TextColor3 = PARCEL_COLOR
	label.TextStrokeTransparency = 0.2
	label.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Heavy)
	label.Parent = billboard
	billboard.Parent = box

	box.Parent = Workspace
	return box
end

local function setStatus(package: Package, newStatus: Types.ParcelStatus)
	if package.status == newStatus then
		return
	end
	package.status = newStatus
	changed.fire(package.index)
end

local function clearShield(package: Package)
	local shield = package.shield
	if shield then
		shield:Destroy()
		package.shield = nil
	end
end

-- The package this agent is carrying, if any.
local function carriedBy(agent: Agent): Package?
	for _, package in packages do
		if package.carrier == agent then
			return package
		end
	end
	return nil
end

-- Detach from whoever holds it, restoring their speed.
local function releaseCarrier(package: Package): Agent?
	local previous = package.carrier
	package.carrier = nil
	package.protectedUntil = 0
	clearShield(package)
	local weld = package.weld
	if weld then
		weld:Destroy()
		package.weld = nil
	end
	if previous then
		previous.carrying = carriedBy(previous) ~= nil
		Agents.refreshSpeed(previous)
	end
	return previous
end

local function placeAt(package: Package, position: Vector3)
	package.part.Anchored = true
	package.part.CFrame = CFrame.new(position)
end

local function attach(package: Package, agent: Agent, root: BasePart)
	releaseCarrier(package)
	local part = package.part
	part.Anchored = false
	part.CFrame = root.CFrame * CARRY_OFFSET
	local newWeld = Instance.new("WeldConstraint")
	newWeld.Part0 = root
	newWeld.Part1 = part
	newWeld.Parent = part
	package.weld = newWeld

	package.carrier = agent
	agent.carrying = true
	-- Steal protection, shown as a force-field bubble while it lasts.
	package.protectedUntil = os.clock() + Config.STEAL_PROTECTION_SECONDS
	local bubble = Instance.new("ForceField")
	bubble.Name = "StealProtection"
	bubble.Visible = true
	bubble.Parent = agent.character
	package.shield = bubble
	task.delay(Config.STEAL_PROTECTION_SECONDS, function()
		if package.shield == bubble then
			clearShield(package)
		end
	end)
	-- Burst of speed on pickup (also refreshes speed for carrying).
	Agents.boost(agent, Config.PICKUP_BOOST_SECONDS)
	package.lastCarrierPosition = root.Position

	setStatus(package, "Carried")
	notify({ kind = "Pickup", team = agent.team, actorName = agent.name })
end

-- Knock a package loose at a position. The previous carrier can't grab it
-- straight back.
local function dropAt(package: Package, position: Vector3)
	local previous = releaseCarrier(package)
	if previous then
		previous.immuneUntil = os.clock() + Config.DROP_IMMUNITY_SECONDS
	end
	placeAt(package, Arena.restPosition(position))
	setStatus(package, "Loose")
end

local function resetPackage(package: Package)
	releaseCarrier(package)
	placeAt(package, package.home)
	setStatus(package, "Home")
end

-- Put every package back on its pedestal.
function Parcel.reset()
	for _, package in packages do
		resetPackage(package)
	end
end

function Parcel.setActive(isActive: boolean)
	active = isActive
end

-- True while play is live (not during kickoff, lobby or right after a goal).
function Parcel.isActive(): boolean
	return active
end

function Parcel.count(): number
	return #packages
end

-- Per-package details, by index (1 = left).
function Parcel.getCarrier(index: number): Agent?
	local package = packages[index]
	return package and package.carrier
end

function Parcel.getPosition(index: number): Vector3
	return packages[index].part.Position
end

-- True while package `index`'s fresh carrier can't be tackled.
function Parcel.isProtected(index: number): boolean
	local package = packages[index]
	return package ~= nil and os.clock() < package.protectedUntil
end

-- The index of the package this agent carries, if any.
function Parcel.indexCarriedBy(agent: Agent): number?
	local package = carriedBy(agent)
	return package and package.index
end

-- True if the agent carries a package that's still under steal protection.
function Parcel.isAgentProtected(agent: Agent): boolean
	local package = carriedBy(agent)
	return package ~= nil and os.clock() < package.protectedUntil
end

function Parcel.views(): { Types.PackageView }
	local list: { Types.PackageView } = {}
	for _, package in packages do
		local carrier = package.carrier
		local carrierPlayer = carrier and carrier.player
		table.insert(list, {
			status = package.status,
			carrierName = carrier and carrier.name,
			carrierTeam = carrier and carrier.team,
			carrierUserId = carrierPlayer and carrierPlayer.UserId,
		})
	end
	return list
end

-- Hand a free package to an agent (QA cheats only).
function Parcel.forceGive(agent: Agent): boolean
	local root = Agents.root(agent)
	if not active or not root or not Agents.humanoid(agent) or carriedBy(agent) then
		return false
	end
	for _, package in packages do
		if not package.carrier then
			attach(package, agent, root)
			return true
		end
	end
	return false
end

-- Dives in progress: attacker → os.clock() when its hit window closes.
local dives: { [Agent]: number } = {}
-- Covers the attacker's ping: their lunge reaches us a little late.
local DIVE_HIT_GRACE = 0.15
local DIVE_HIT_HEIGHT = 5

-- The closest enemy carrier the diving attacker has reached, if any.
local function diveTarget(attacker: Agent, root: BasePart): (Package?, BasePart?, Vector3)
	local best: Package? = nil
	local bestRoot: BasePart? = nil
	local bestOffset = Vector3.zero
	local bestDistance = Config.TACKLE_HIT_RADIUS
	for _, package in packages do
		local target = package.carrier
		-- A carrier still under steal protection can't be hit, so don't let
		-- them use up a dive that could reach the other carrier.
		local targetRoot = target
			and target.team ~= attacker.team
			and os.clock() >= package.protectedUntil
			and Agents.root(target)
		if targetRoot then
			local offset = targetRoot.Position - root.Position
			local distance = flat(offset).Magnitude
			if distance <= bestDistance and math.abs(offset.Y) <= DIVE_HIT_HEIGHT then
				best, bestRoot, bestOffset, bestDistance = package, targetRoot, offset, distance
			end
		end
	end
	return best, bestRoot, bestOffset
end

-- See whether a diving attacker has reached an enemy carrier. Returns true
-- once the dive is resolved (hit, dodged or blocked by steal protection).
local function checkDive(attacker: Agent): boolean
	local root = Agents.root(attacker)
	if not root or Movement.isSuspect(attacker) then
		return false
	end
	local package, targetRoot, offset = diveTarget(attacker, root)
	local target = package and package.carrier
	if not package or not target or not targetRoot then
		return false
	end
	if Agents.isSliding(target) then
		-- Slid under it: the tackle whiffs.
		notify({
			kind = "Dodged",
			team = target.team,
			actorName = target.name,
			targetName = attacker.name,
		})
		return true
	end

	-- Package pops forward, away from the tackler.
	local push = flat(offset)
	local direction = if push.Magnitude > 0.01 then push.Unit else Vector3.xAxis
	dropAt(package, targetRoot.Position + direction * 5)
	Agents.stun(target, Config.STUN_SECONDS)
	notify({
		kind = "Tackled",
		team = attacker.team,
		actorName = attacker.name,
		targetName = target.name,
	})
	tackleLanded.fire(attacker)
	return true
end

-- Shared by the Tackle remote and bots. Every tackle is a committed dive:
-- it lands only if the diver's body reaches a carrier during the lunge,
-- so aim and timing matter. Starts the cooldown even on a miss. Returns
-- true if a dive started.
function Parcel.tackle(attacker: Agent): boolean
	local now = os.clock()
	if
		not active
		or now < attacker.tackleReadyAt
		or attacker.carrying
		or Agents.isStunned(attacker)
		or Agents.isDiving(attacker)
	then
		return false
	end
	if not Movement.verify(attacker) then
		return false
	end
	if not Agents.root(attacker) or not Agents.humanoid(attacker) then
		return false
	end
	attacker.tackleReadyAt = now + Config.TACKLE_COOLDOWN
	Agents.dive(attacker)
	if not checkDive(attacker) then
		dives[attacker] = now + Config.DIVE_LUNGE_SECONDS + DIVE_HIT_GRACE
	end
	return true
end

local function stepDives()
	if next(dives) == nil then
		return
	end
	local now = os.clock()
	for attacker, untilTime in dives do
		if not active or now > untilTime or checkDive(attacker) then
			dives[attacker] = nil
		end
	end
end

local function stepCarried(package: Package, agent: Agent)
	local root = Agents.root(agent)
	if not root or not Agents.humanoid(agent) then
		dropAt(package, package.lastCarrierPosition)
		return
	end

	local zone = Arena.dropZoneCenter(agent.team)
	local inZone = flat(root.Position - zone).Magnitude <= Config.DELIVERY_RADIUS
	-- A failed check fires Movement.Flagged, which knocks the package loose.
	if inZone and not Movement.verify(agent) then
		return
	end
	package.lastCarrierPosition = root.Position
	if inZone then
		-- Reset first so the state Match broadcasts on scoring is clean.
		resetPackage(package)
		delivered.fire(agent)
		notify({ kind = "Delivered", team = agent.team, actorName = agent.name })
	end
end

local function stepFree(package: Package, now: number)
	local parcelPosition = package.part.Position
	if Arena.isOutOfBounds(parcelPosition) then
		resetPackage(package)
		notify({ kind = "Returned" })
		return
	end

	local best: Agent? = nil
	local bestRoot: BasePart? = nil
	local bestDistance = Config.PICKUP_RADIUS
	for _, agent in Agents.all() do
		if
			not agent.carrying
			and now >= agent.immuneUntil
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
		attach(package, best, bestRoot)
	end
end

local function step()
	local now = os.clock()
	for _, package in packages do
		-- A delivery stops play (Match runs a kickoff), so stop there.
		if not active then
			return
		end
		local agent = package.carrier
		if package.status == "Carried" and agent then
			stepCarried(package, agent)
		else
			stepFree(package, now)
		end
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
	dives[agent] = nil
	local package = carriedBy(agent)
	if package then
		dropAt(package, package.lastCarrierPosition)
	end
end

function Parcel.init()
	for index = 1, Config.PACKAGE_COUNT do
		local home = Arena.packageHome(index)
		table.insert(packages, {
			index = index,
			home = home,
			part = buildPart(index, home),
			status = "Home",
			carrier = nil,
			weld = nil,
			lastCarrierPosition = home,
			protectedUntil = 0,
			shield = nil,
		})
	end
	Net.on("Tackle", onTackleRequest)
	Agents.CharacterLost.connect(onAgentLost)
	Agents.Removed.connect(onAgentLost)
	Movement.Flagged.connect(function(flag)
		local package = carriedBy(flag.agent)
		if package then
			dropAt(package, flag.position)
		end
	end)
end

function Parcel.start()
	local accumulated = 0
	RunService.Heartbeat:Connect(function(dt)
		-- Dives are short, so check them every frame.
		stepDives()
		accumulated += dt
		if accumulated < STEP_INTERVAL then
			return
		end
		accumulated = 0
		if active then
			step()
		end
	end)
end

return Parcel
