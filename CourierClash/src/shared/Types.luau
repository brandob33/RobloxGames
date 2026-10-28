--!strict
-- Shared type definitions. Types that cross the client/server boundary
-- (remote payloads, state snapshots) live here so both sides agree.

export type TeamId = "Ember" | "Tide"

-- Explicit fields (not an indexer) so `.Ember` type-checks under both
-- solvers; use MatchLogic.scoreOf / addTo for dynamic team access.
export type TeamScores = { Ember: number, Tide: number }

export type Phase = "Waiting" | "Lobby" | "Playing" | "Results"

-- Home: resting at the center pedestal. Loose: dropped somewhere on the field.
export type ParcelStatus = "Home" | "Carried" | "Loose"

export type Winner = TeamId | "Draw"

-- Full match snapshot, sent on every change and on request (late join).
export type MatchState = {
	phase: Phase,
	-- workspace:GetServerTimeNow() when the current phase ends; 0 = no timer
	phaseEndsAt: number,
	scores: TeamScores,
	scoreToWin: number,
	parcelStatus: ParcelStatus,
	carrierName: string?,
	carrierTeam: TeamId?,
	-- UserId of a human carrier, nil for bots
	carrierUserId: number?,
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

export type CheatCommand = "ScoreEmber" | "ScoreTide" | "EndRound" | "GiveParcel"

return nil
