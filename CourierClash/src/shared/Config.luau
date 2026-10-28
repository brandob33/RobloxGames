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
	MIN_HUMANS_TO_START = 1,

	-- Round flow (seconds)
	INTERMISSION_SECONDS = 12,
	ROUND_COUNTDOWN_SECONDS = 3,
	ROUND_SECONDS = 180,
	RESULTS_SECONDS = 8,
	SCORE_TO_WIN = 3,

	-- Movement (studs/second)
	RUN_SPEED = 18,
	CARRIER_SPEED = 14,
	SPRINT_SPEED = 27,
	CARRIER_SPRINT_SPEED = 20,
	BOT_SPEED_FACTOR = 0.92,

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

	-- Arena footprint (studs)
	ARENA_LENGTH = 360,
	ARENA_WIDTH = 240,
})
