--!strict
-- Every remote in the game, in one list. The server creates them at startup
-- (server/Net.luau); clients only wait for them (client/Net.luau).
--
--   State          S→C  MatchState snapshot
--   Notice         S→C  Notice (feed/banner events)
--   TackleCooldown S→C  seconds until the player's tackle is ready again
--   Tackle         C→S  no arguments; the server picks the target
--   RequestState   C→S  no arguments; asks for a fresh snapshot (late join)
--   Cheat          C→S  CheatCommand; ignored outside Studio

export type RemoteName = "State" | "Notice" | "TackleCooldown" | "Tackle" | "RequestState" | "Cheat"

local NAMES: { RemoteName } =
	{ "State", "Notice", "TackleCooldown", "Tackle", "RequestState", "Cheat" }

return table.freeze({
	FOLDER_NAME = "CourierClashRemotes",
	NAMES = NAMES,
})
