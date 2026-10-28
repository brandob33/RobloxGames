--!strict
-- Shared type definitions. Types that cross the client/server boundary
-- (remote payloads, state snapshots) live here so both sides agree.

export type TeamId = "Ember" | "Tide"

-- Explicit fields (not an indexer) so `.Ember` type-checks under both
-- solvers; use MatchLogic.scoreOf / addTo for dynamic team access.
export type TeamScores = { Ember: number, Tide: number }

export type Phase = "Waiting" | "Lobby" | "Playing" | "Results"

-- Home: resting on its pedestal. Loose: dropped somewhere on the field.
export type ParcelStatus = "Home" | "Carried" | "Loose"

-- One package as the HUD sees it.
export type PackageView = {
	status: ParcelStatus,
	carrierName: string?,
	carrierTeam: TeamId?,
	-- UserId of a human carrier, nil for bots
	carrierUserId: number?,
}

export type Winner = TeamId | "Draw"

-- Full match snapshot, sent on every change and on request (late join).
export type MatchState = {
	phase: Phase,
	-- workspace:GetServerTimeNow() when the current phase ends; 0 = no timer
	phaseEndsAt: number,
	scores: TeamScores,
	scoreToWin: number,
	-- One entry per package, left to right.
	packages: { PackageView },
	winner: Winner?,
	-- workspace:GetServerTimeNow() when the kickoff lock ends; 0 = not locked
	lockedUntil: number,
}

export type NoticeKind =
	"Pickup"
	| "Delivered"
	| "Tackled"
	| "Dodged"
	| "Returned"
	| "RoundStart"
	| "RoundEnd"
	| "Go"

export type Notice = {
	kind: NoticeKind,
	team: TeamId?,
	actorName: string?,
	targetName: string?,
}

-- What the shop shows for the local player (S→C "Profile").
export type ProfileView = {
	coins: number,
	ownedTrails: { string },
	equippedTrail: string, -- "" = none
	perks: { [string]: number }, -- perk id → level
	-- false until saved data has loaded (shop shows "Loading...")
	loaded: boolean,
	-- false in Studio when DataStores are off: progress won't be kept
	saving: boolean,
}

export type CoinReason = "Delivery" | "Tackle" | "Win" | "Played" | "Purchase"

export type ShopRequest = {
	-- Refresh = resend my Profile (the client asks once its UI is ready)
	kind: "BuyTrail" | "BuyPerk" | "Equip" | "Refresh",
	id: string, -- trail or perk id; "" with Equip = take the trail off
}

export type ShopResult = {
	ok: boolean,
	message: string,
}

export type CheatCommand = "ScoreEmber" | "ScoreTide" | "EndRound" | "GiveParcel"

return nil
