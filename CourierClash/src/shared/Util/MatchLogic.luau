--!strict
-- Pure match rules shared by server and tests. No Instances, no services:
-- the server's results are authoritative, the client never calls these to
-- decide anything.

local Types = require(script.Parent.Parent.Types)

type TeamId = Types.TeamId
type TeamScores = Types.TeamScores

local MatchLogic = {}

function MatchLogic.scoreOf(scores: TeamScores, team: TeamId): number
	return if team == "Ember" then scores.Ember else scores.Tide
end

function MatchLogic.addTo(scores: TeamScores, team: TeamId, amount: number)
	if team == "Ember" then
		scores.Ember += amount
	else
		scores.Tide += amount
	end
end

function MatchLogic.otherTeam(team: TeamId): TeamId
	return if team == "Ember" then "Tide" else "Ember"
end

-- New humans join the smaller team; ties go to Ember.
function MatchLogic.pickTeamForJoin(humans: TeamScores): TeamId
	if humans.Tide < humans.Ember then
		return "Tide"
	end
	return "Ember"
end

-- How many bots each team needs so both teams field the same number of
-- couriers (at least teamSize). No humans means no bots.
function MatchLogic.botsForTeams(humans: TeamScores, teamSize: number): TeamScores
	if humans.Ember + humans.Tide == 0 then
		return { Ember = 0, Tide = 0 }
	end
	local target = math.max(teamSize, humans.Ember, humans.Tide)
	return { Ember = target - humans.Ember, Tide = target - humans.Tide }
end

-- Which team should give up players, and how many, to even out human counts.
function MatchLogic.balanceMove(humans: TeamScores): (TeamId?, number)
	local diff = humans.Ember - humans.Tide
	if math.abs(diff) <= 1 then
		return nil, 0
	end
	local from: TeamId = if diff > 0 then "Ember" else "Tide"
	return from, math.floor(math.abs(diff) / 2)
end

function MatchLogic.isRoundOver(scores: TeamScores, scoreToWin: number, secondsLeft: number): boolean
	return secondsLeft <= 0 or scores.Ember >= scoreToWin or scores.Tide >= scoreToWin
end

function MatchLogic.winner(scores: TeamScores): Types.Winner
	if scores.Ember > scores.Tide then
		return "Ember"
	elseif scores.Tide > scores.Ember then
		return "Tide"
	end
	return "Draw"
end

return MatchLogic
