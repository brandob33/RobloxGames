--!strict
-- Every remote in the game, in one list. The server creates them at startup
-- (server/Net.luau); clients only wait for them (client/Net.luau).
--
--   State          S→C  MatchState snapshot
--   Notice         S→C  Notice (feed/banner events)
--   TackleCooldown S→C  seconds until the player's tackle is ready again
--   Tackle         C→S  no arguments; the server picks the target
--   Shove          C→S  no arguments; the server picks the target
--   ShoveCooldown  S→C  seconds until the player's shove is ready again
--   Shoved         S→C  Vector3: flat unit direction you were shoved
--   RequestState   C→S  no arguments; asks for a fresh snapshot (late join)
--   Sprint         C→S  boolean: sprint key held or released
--   Slide          C→S  no arguments; the server checks sprint/stamina/cooldown
--   SlideResult    S→C  boolean: whether the server accepted the last slide
--   Profile        S→C  ProfileView: coins, owned items, perk levels
--   CoinsEarned    S→C  amount: number, reason: CoinReason
--   Shop           C→S  ShopRequest; validated against ShopCatalog
--   ShopResult     S→C  ShopResult: whether it worked and why not
--   Cheat          C→S  CheatCommand; ignored outside Studio

export type RemoteName =
	"State"
	| "Notice"
	| "TackleCooldown"
	| "Tackle"
	| "Shove"
	| "ShoveCooldown"
	| "Shoved"
	| "RequestState"
	| "Sprint"
	| "Slide"
	| "SlideResult"
	| "Profile"
	| "CoinsEarned"
	| "Shop"
	| "ShopResult"
	| "Cheat"

local NAMES: { RemoteName } = {
	"State",
	"Notice",
	"TackleCooldown",
	"Tackle",
	"Shove",
	"ShoveCooldown",
	"Shoved",
	"RequestState",
	"Sprint",
	"Slide",
	"SlideResult",
	"Profile",
	"CoinsEarned",
	"Shop",
	"ShopResult",
	"Cheat",
}

return table.freeze({
	FOLDER_NAME = "CourierClashRemotes",
	NAMES = NAMES,
})
