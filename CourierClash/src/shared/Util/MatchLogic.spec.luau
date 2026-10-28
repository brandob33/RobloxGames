--!nonstrict
-- TestEZ spec for MatchLogic. Run with a TestEZ runner in Studio
-- (see README "Tests").

local MatchLogic = require(script.Parent.MatchLogic)

return function()
	describe("otherTeam", function()
		it("swaps teams", function()
			expect(MatchLogic.otherTeam("Ember")).to.equal("Tide")
			expect(MatchLogic.otherTeam("Tide")).to.equal("Ember")
		end)
	end)

	describe("pickTeamForJoin", function()
		it("breaks ties toward Ember", function()
			expect(MatchLogic.pickTeamForJoin({ Ember = 0, Tide = 0 })).to.equal("Ember")
			expect(MatchLogic.pickTeamForJoin({ Ember = 2, Tide = 2 })).to.equal("Ember")
		end)

		it("fills the smaller team", function()
			expect(MatchLogic.pickTeamForJoin({ Ember = 1, Tide = 0 })).to.equal("Tide")
			expect(MatchLogic.pickTeamForJoin({ Ember = 0, Tide = 1 })).to.equal("Ember")
		end)
	end)

	describe("botsForTeams", function()
		it("adds no bots to an empty server", function()
			local bots = MatchLogic.botsForTeams({ Ember = 0, Tide = 0 }, 4)
			expect(bots.Ember).to.equal(0)
			expect(bots.Tide).to.equal(0)
		end)

		it("tops both teams up to team size", function()
			local bots = MatchLogic.botsForTeams({ Ember = 1, Tide = 0 }, 4)
			expect(bots.Ember).to.equal(3)
			expect(bots.Tide).to.equal(4)
		end)

		it("matches the larger team when it exceeds team size", function()
			local bots = MatchLogic.botsForTeams({ Ember = 6, Tide = 5 }, 4)
			expect(bots.Ember).to.equal(0)
			expect(bots.Tide).to.equal(1)
		end)
	end)

	describe("balanceMove", function()
		it("leaves teams within one alone", function()
			local from, count = MatchLogic.balanceMove({ Ember = 3, Tide = 2 })
			expect(from).to.equal(nil)
			expect(count).to.equal(0)
		end)

		it("moves half the difference from the bigger team", function()
			local from, count = MatchLogic.balanceMove({ Ember = 1, Tide = 5 })
			expect(from).to.equal("Tide")
			expect(count).to.equal(2)
		end)
	end)

	describe("isRoundOver", function()
		it("ends at the score limit", function()
			expect(MatchLogic.isRoundOver({ Ember = 3, Tide = 0 }, 3, 60)).to.equal(true)
			expect(MatchLogic.isRoundOver({ Ember = 2, Tide = 2 }, 3, 60)).to.equal(false)
		end)

		it("ends when time runs out", function()
			expect(MatchLogic.isRoundOver({ Ember = 0, Tide = 0 }, 3, 0)).to.equal(true)
			expect(MatchLogic.isRoundOver({ Ember = 0, Tide = 0 }, 3, -1)).to.equal(true)
		end)
	end)

	describe("winner", function()
		it("picks the higher score or a draw", function()
			expect(MatchLogic.winner({ Ember = 2, Tide = 1 })).to.equal("Ember")
			expect(MatchLogic.winner({ Ember = 0, Tide = 1 })).to.equal("Tide")
			expect(MatchLogic.winner({ Ember = 1, Tide = 1 })).to.equal("Draw")
		end)
	end)
end
