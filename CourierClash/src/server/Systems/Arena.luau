--!strict
-- Builds the arena in code (no place file needed) and answers geometry
-- questions: where each team's drop zone and spawn box are, and whether a
-- position is out of bounds. Ember's base is on -X, Tide's on +X.
--
-- Each team spawns in a walled box at its end of the field. The box's
-- front is a gate that Match closes during kickoff (setGatesOpen).

local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)

type TeamId = Types.TeamId

local Arena = {}

local HALF_X = Config.ARENA_LENGTH / 2
local HALF_Z = Config.ARENA_WIDTH / 2
local BOX_FRONT_X = HALF_X - Config.SPAWN_BOX_DEPTH
local BOX_HALF_Z = Config.SPAWN_BOX_WIDTH / 2
local ZONE_X = BOX_FRONT_X - 22
local WALL_HEIGHT = 40
local PARCEL_REST_Y = 1.5
local GATE_CLOSED_TRANSPARENCY = 0.6
-- Obstacle layout is authored for a 360x240 field and scaled to fit.
local LAYOUT_SCALE_X = HALF_X / 180
local LAYOUT_SCALE_Z = HALF_Z / 120

Arena.PARCEL_HOME = Vector3.new(0, 4, 0)

-- Lobby: a walled platform beside the field where players wait between
-- games (the shop will live here).
local LOBBY_CENTER = Vector3.new(0, 0, HALF_Z + 140)
local LOBBY_SIZE = 140
local LOBBY_WALL_HEIGHT = 30
local LOBBY_COLOR = Color3.fromRGB(64, 70, 92)
local random = Random.new()

local GROUND_COLOR = Color3.fromRGB(96, 168, 92)
local STRIPE_COLOR = Color3.fromRGB(235, 235, 220)
local CRATE_COLOR = Color3.fromRGB(176, 132, 84)
local WALL_COLOR = Color3.fromRGB(200, 220, 255)
local gates: { Part } = {}

local PILLAR_COLOR = Color3.fromRGB(150, 150, 160)
local BARRIER_COLOR = Color3.fromRGB(70, 128, 70)

type Obstacle = { kind: "Crate" | "Pillar" | "Barrier", x: number, z: number, size: Vector3 }

local CRATE = Vector3.new(7, 3, 7) -- jumpable
local PILLAR = Vector3.new(5, 10, 5) -- cover; go around it
local HEDGE_Z = Vector3.new(3, 2, 18) -- low hedge, jumpable
local HEDGE_X = Vector3.new(18, 2, 3)

-- Ember half (x < 0). Entries with z ~= 0 are mirrored across z, and the
-- whole list is mirrored onto the Tide half.
local OBSTACLES: { Obstacle } = {
	{ kind = "Crate", x = -30, z = 0, size = CRATE },
	{ kind = "Crate", x = -45, z = 40, size = CRATE },
	{ kind = "Crate", x = -70, z = 16, size = CRATE },
	{ kind = "Crate", x = -22, z = 70, size = CRATE },
	{ kind = "Crate", x = -95, z = 55, size = CRATE },
	{ kind = "Crate", x = -120, z = 25, size = CRATE },
	{ kind = "Crate", x = -60, z = 95, size = CRATE },
	{ kind = "Crate", x = -130, z = 85, size = CRATE },
	{ kind = "Pillar", x = -50, z = 0, size = PILLAR },
	{ kind = "Pillar", x = -110, z = 45, size = PILLAR },
	{ kind = "Pillar", x = -35, z = 100, size = PILLAR },
	{ kind = "Barrier", x = -80, z = 48, size = HEDGE_Z },
	{ kind = "Barrier", x = -130, z = 0, size = HEDGE_Z },
	{ kind = "Barrier", x = -40, z = 60, size = HEDGE_X },
	{ kind = "Crate", x = -15, z = 35, size = CRATE },
	{ kind = "Crate", x = -100, z = 110, size = CRATE },
	{ kind = "Pillar", x = -75, z = 75, size = PILLAR },
	{ kind = "Pillar", x = -140, z = 60, size = PILLAR },
	{ kind = "Pillar", x = -20, z = 40, size = PILLAR },
	{ kind = "Barrier", x = -105, z = 90, size = HEDGE_X },
}

local arenaFolder: Folder? = nil

local function side(team: TeamId): number
	return if team == "Ember" then -1 else 1
end

function Arena.dropZoneCenter(team: TeamId): Vector3
	return Vector3.new(side(team) * ZONE_X, 0, 0)
end

-- Spawn spot for the n-th courier of a team: two rows of ten inside the
-- spawn box, facing the field.
function Arena.spawnCFrame(team: TeamId, index: number): CFrame
	local column = (index - 1) % 10
	local row = math.floor((index - 1) / 10) % 2
	local x = side(team) * (HALF_X - 9 - row * 10)
	local position = Vector3.new(x, 4, (column - 4.5) * 9)
	return CFrame.lookAt(position, Vector3.new(0, position.Y, position.Z))
end

function Arena.isInSpawnBox(team: TeamId, position: Vector3): boolean
	local x = position.X * side(team)
	return x >= BOX_FRONT_X - 1 and x <= HALF_X + 1 and math.abs(position.Z) <= BOX_HALF_Z + 1
end

function Arena.isInLobby(position: Vector3): boolean
	local half = LOBBY_SIZE / 2
	return math.abs(position.X - LOBBY_CENTER.X) <= half
		and math.abs(position.Z - LOBBY_CENTER.Z) <= half
		and position.Y > -20
end

function Arena.lobbyCFrame(): CFrame
	local spread = LOBBY_SIZE / 2 - 15
	local position = LOBBY_CENTER
		+ Vector3.new(random:NextNumber(-spread, spread), 4, random:NextNumber(-spread, spread))
	return CFrame.lookAt(position, Vector3.new(0, position.Y, 0))
end

function Arena.setGatesOpen(open: boolean)
	for _, gate in gates do
		gate.CanCollide = not open
		gate.Transparency = if open then 1 else GATE_CLOSED_TRANSPARENCY
	end
end

-- Where a dropped parcel comes to rest: inside the walls, on the floor.
function Arena.restPosition(position: Vector3): Vector3
	local margin = 6
	return Vector3.new(
		math.clamp(position.X, -HALF_X + margin, HALF_X - margin),
		PARCEL_REST_Y,
		math.clamp(position.Z, -HALF_Z + margin, HALF_Z - margin)
	)
end

function Arena.isOutOfBounds(position: Vector3): boolean
	return position.Y < -25
		or math.abs(position.X) > HALF_X + 10
		or math.abs(position.Z) > HALF_Z + 10
end

local function makePart(
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	parent: Instance
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = Enum.Material.SmoothPlastic
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function makeLabel(adornee: BasePart, text: string, color: Color3)
	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromScale(14, 3)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 9, 0)
	billboard.MaxDistance = 220
	billboard.LightInfluence = 0
	billboard.Adornee = adornee
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextScaled = true
	label.TextColor3 = color
	label.TextStrokeTransparency = 0.3
	label.FontFace = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Heavy)
	label.Parent = billboard
	billboard.Parent = adornee
end

local function buildBase(team: TeamId, parent: Instance)
	local color = Config.TEAM_COLORS[team]
	local zone = Arena.dropZoneCenter(team)

	-- Drop zone: flat glowing disc. Visual only; delivery is checked by
	-- distance on the server, never by Touched.
	local disc = makePart(
		team .. "DropZone",
		Vector3.new(0.3, Config.DELIVERY_RADIUS * 2, Config.DELIVERY_RADIUS * 2),
		CFrame.new(zone + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		color,
		parent
	)
	disc.Shape = Enum.PartType.Cylinder
	disc.Material = Enum.Material.Neon
	disc.Transparency = 0.35
	disc.CanCollide = false
	disc.CanQuery = false
	disc.CanTouch = false

	local post = makePart(
		team .. "DropPost",
		Vector3.new(1, 8, 1),
		CFrame.new(zone + Vector3.new(0, 4, 0)),
		color,
		parent
	)
	post.CanCollide = false
	post.Transparency = 1
	makeLabel(post, string.upper(team) .. " DROP", color)

	-- Spawn box: tall see-through side and back walls, plus a gate in front.
	local boxCenterX = side(team) * (BOX_FRONT_X + HALF_X) / 2
	local wallHeight = Config.SPAWN_WALL_HEIGHT
	local depth = Config.SPAWN_BOX_DEPTH
	local boxWalls: { { name: string, size: Vector3, position: Vector3 } } = {
		{
			name = "BoxSideA",
			size = Vector3.new(depth, wallHeight, 2),
			position = Vector3.new(boxCenterX, wallHeight / 2, BOX_HALF_Z + 1),
		},
		{
			name = "BoxSideB",
			size = Vector3.new(depth, wallHeight, 2),
			position = Vector3.new(boxCenterX, wallHeight / 2, -BOX_HALF_Z - 1),
		},
		{
			name = "BoxBack",
			size = Vector3.new(2, wallHeight, Config.SPAWN_BOX_WIDTH + 4),
			position = Vector3.new(side(team) * (HALF_X - 1), wallHeight / 2, 0),
		},
	}
	for _, wall in boxWalls do
		local part =
			makePart(team .. wall.name, wall.size, CFrame.new(wall.position), color, parent)
		part.Transparency = 0.85
	end
	local gate = makePart(
		team .. "Gate",
		Vector3.new(2, wallHeight, Config.SPAWN_BOX_WIDTH + 4),
		CFrame.new(side(team) * (BOX_FRONT_X - 1), wallHeight / 2, 0),
		color,
		parent
	)
	gate.Material = Enum.Material.ForceField
	gate.Transparency = GATE_CLOSED_TRANSPARENCY
	table.insert(gates, gate)

	local spawn = Instance.new("SpawnLocation")
	spawn.Name = team .. "Spawn"
	spawn.Anchored = true
	spawn.Size = Vector3.new(depth - 6, 1, Config.SPAWN_BOX_WIDTH - 6)
	spawn.CFrame = CFrame.new(boxCenterX, 0.5, 0)
	spawn.Color = color
	spawn.Material = Enum.Material.SmoothPlastic
	spawn.TeamColor = BrickColor.new(color)
	spawn.Neutral = false
	spawn.AllowTeamChangeOnTouch = false
	spawn.Duration = 0
	spawn.Parent = parent
end

local function build()
	-- Remove the Baseplate template's floor and spawn so ours are the only ones.
	for _, name in { "Baseplate", "SpawnLocation" } do
		local existing = Workspace:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end

	local folder = Instance.new("Folder")
	folder.Name = "CourierClashArena"

	local ground = makePart(
		"Ground",
		Vector3.new(Config.ARENA_LENGTH, 2, Config.ARENA_WIDTH),
		CFrame.new(0, -1, 0),
		GROUND_COLOR,
		folder
	)
	ground.Material = Enum.Material.Grass

	local stripe = makePart(
		"CenterLine",
		Vector3.new(1, 0.1, Config.ARENA_WIDTH),
		CFrame.new(0, 0.05, 0),
		STRIPE_COLOR,
		folder
	)
	stripe.CanCollide = false

	makePart("Pedestal", Vector3.new(6, 1, 6), CFrame.new(0, 0.5, 0), STRIPE_COLOR, folder)

	-- Boundary walls
	local longWall = Vector3.new(Config.ARENA_LENGTH, WALL_HEIGHT, 2)
	local shortWall = Vector3.new(2, WALL_HEIGHT, Config.ARENA_WIDTH)
	local walls: { { size: Vector3, cframe: CFrame } } = {
		{ size = longWall, cframe = CFrame.new(0, WALL_HEIGHT / 2, -HALF_Z - 1) },
		{ size = longWall, cframe = CFrame.new(0, WALL_HEIGHT / 2, HALF_Z + 1) },
		{ size = shortWall, cframe = CFrame.new(-HALF_X - 1, WALL_HEIGHT / 2, 0) },
		{ size = shortWall, cframe = CFrame.new(HALF_X + 1, WALL_HEIGHT / 2, 0) },
	}
	for i, wall in walls do
		local part = makePart("Wall" .. i, wall.size, wall.cframe, WALL_COLOR, folder)
		part.Transparency = 0.7
	end

	for i, obstacle in OBSTACLES do
		local zs = if obstacle.z == 0 then { 0 } else { obstacle.z, -obstacle.z }
		for _, mirrorX in { 1, -1 } do
			for _, z in zs do
				local at = Vector3.new(
					obstacle.x * LAYOUT_SCALE_X * mirrorX,
					obstacle.size.Y / 2,
					z * LAYOUT_SCALE_Z
				)
				local color = if obstacle.kind == "Crate"
					then CRATE_COLOR
					elseif obstacle.kind == "Pillar" then PILLAR_COLOR
					else BARRIER_COLOR
				local part =
					makePart(obstacle.kind .. i, obstacle.size, CFrame.new(at), color, folder)
				part.Material = if obstacle.kind == "Crate"
					then Enum.Material.WoodPlanks
					elseif obstacle.kind == "Pillar" then Enum.Material.Concrete
					else Enum.Material.LeafyGrass
			end
		end
	end

	for _, team in Config.TEAM_IDS do
		buildBase(team, folder)
	end

	local lobby = makePart(
		"LobbyFloor",
		Vector3.new(LOBBY_SIZE, 2, LOBBY_SIZE),
		CFrame.new(LOBBY_CENTER - Vector3.new(0, 1, 0)),
		LOBBY_COLOR,
		folder
	)
	lobby.Material = Enum.Material.Slate
	local lobbyHalf = LOBBY_SIZE / 2
	local lobbyWalls: { { size: Vector3, offset: Vector3 } } = {
		{
			size = Vector3.new(LOBBY_SIZE, LOBBY_WALL_HEIGHT, 2),
			offset = Vector3.new(0, 0, lobbyHalf + 1),
		},
		{
			size = Vector3.new(LOBBY_SIZE, LOBBY_WALL_HEIGHT, 2),
			offset = Vector3.new(0, 0, -lobbyHalf - 1),
		},
		{
			size = Vector3.new(2, LOBBY_WALL_HEIGHT, LOBBY_SIZE),
			offset = Vector3.new(lobbyHalf + 1, 0, 0),
		},
		{
			size = Vector3.new(2, LOBBY_WALL_HEIGHT, LOBBY_SIZE),
			offset = Vector3.new(-lobbyHalf - 1, 0, 0),
		},
	}
	for i, wall in lobbyWalls do
		local part = makePart(
			"LobbyWall" .. i,
			wall.size,
			CFrame.new(LOBBY_CENTER + wall.offset + Vector3.new(0, LOBBY_WALL_HEIGHT / 2, 0)),
			WALL_COLOR,
			folder
		)
		part.Transparency = 0.7
	end
	local sign = makePart(
		"LobbySign",
		Vector3.new(1, 8, 1),
		CFrame.new(LOBBY_CENTER + Vector3.new(0, 4, 0)),
		LOBBY_COLOR,
		folder
	)
	sign.Transparency = 1
	sign.CanCollide = false
	makeLabel(sign, "LOBBY", STRIPE_COLOR)

	folder.Parent = Workspace
	arenaFolder = folder
	Arena.setGatesOpen(true)
end

function Arena.init()
	if not arenaFolder then
		build()
	end
end

return Arena
