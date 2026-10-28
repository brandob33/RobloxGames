--!strict
-- Tunable gameplay values. NOTE: replicated to clients — nothing secret here,
-- and the server never trusts a client-reported value from this file.

local Types = require(script.Parent.Types)

local TEAM_IDS: { Types.TeamId } = { "Ember", "Tide" }

local TEAM_COLORS: { [Types.TeamId]: Color3 } = {
	Ember = Color3.fromRGB(255, 122, 48),
	Tide = Color3.fromRGB(46, 180, 214),
}

return table.freeze({
	GAME_NAME = "Courier Clash",

	TEAM_IDS = TEAM_IDS,
	TEAM_COLORS = TEAM_COLORS,

	-- Teams are topped up with bots to this many couriers each.
	TEAM_SIZE = 10,
	-- false = no bots at all (teams are only real players)
	FILL_WITH_BOTS = true,
	MIN_HUMANS_TO_START = 1,

	-- Round flow (seconds)
	-- Time in the lobby between games. 20 for testing; set to 60 for release.
	LOBBY_SECONDS = 20,
	-- Kickoff: everyone is sent back to their spawn box and locked in this
	-- long at round start and after every delivery. The round clock pauses.
	KICKOFF_SECONDS = 8,
	ROUND_SECONDS = 180,
	RESULTS_SECONDS = 8,
	SCORE_TO_WIN = 3,

	-- Movement (studs/second)
	RUN_SPEED = 18,
	CARRIER_SPEED = 14,
	SPRINT_SPEED = 27,
	CARRIER_SPRINT_SPEED = 20,
	BOT_SPEED_FACTOR = 0.92,
	-- Burst of speed for whoever picks up the parcel
	PICKUP_BOOST_SPEED = 30,
	PICKUP_BOOST_SECONDS = 1,

	-- Stamina (sprint drains it while moving; slides cost a chunk)
	STAMINA_MAX = 100,
	SPRINT_DRAIN = 22, -- per second
	STAMINA_REGEN = 20, -- per second
	STAMINA_REGEN_DELAY = 0.8,
	SPRINT_MIN_STAMINA = 15, -- needed to start sprinting again after running dry

	-- Slide: sprint + C/Ctrl. A short burst that dodges tackles.
	SLIDE_SPEED = 42,
	SLIDE_SECONDS = 0.55,
	SLIDE_COOLDOWN = 1.6,
	SLIDE_STAMINA = 20,

	-- Parcel
	PICKUP_RADIUS = 5,
	DROP_IMMUNITY_SECONDS = 1.5,
	DELIVERY_RADIUS = 10,

	-- Tackle
	TACKLE_RANGE = 9,
	TACKLE_COOLDOWN = 2.5,
	STUN_SECONDS = 1.25,
	-- Tackling is a dive: a short lunge, then you're on the ground and can't
	-- move or act until DIVE_SECONDS after the press.
	DIVE_SPEED = 34,
	DIVE_LUNGE_SECONDS = 0.3,
	DIVE_SECONDS = 1.0,

	-- Arena footprint (studs)
	ARENA_LENGTH = 560,
	ARENA_WIDTH = 380,

	-- Spawn boxes (studs). Tall walls so nobody jumps out during kickoff.
	SPAWN_BOX_DEPTH = 30,
	SPAWN_BOX_WIDTH = 100,
	SPAWN_WALL_HEIGHT = 60,
})
