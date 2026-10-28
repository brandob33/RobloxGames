--!strict
-- Everything the lobby shop sells. Shared so the client can draw the shop;
-- the server looks every purchase up here and never trusts a client price.
--
-- Trails are cosmetic only. Perks are small, capped and earnable with coins
-- from playing; no perk can be bought with Robux.

export type Trail = {
	id: string,
	name: string,
	price: number,
	colorA: Color3,
	colorB: Color3,
}

export type Perk = {
	id: string,
	name: string,
	-- shown with the per-level bonus, e.g. "+5 max stamina per level"
	description: string,
	prices: { number }, -- price of level 1, 2, ... (length = max level)
}

-- Robux coin packs. Create a Developer Product per pack (Creator Dashboard →
-- your experience → Monetization → Developer Products) and paste its ID
-- here. Packs with productId 0 are hidden from the shop.
export type CoinPack = {
	productId: number,
	coins: number,
	label: string,
}

local TRAILS: { Trail } = {
	{
		id = "Sunset",
		name = "Sunset",
		price = 150,
		colorA = Color3.fromRGB(255, 170, 60),
		colorB = Color3.fromRGB(255, 70, 110),
	},
	{
		id = "Seafoam",
		name = "Seafoam",
		price = 150,
		colorA = Color3.fromRGB(90, 240, 200),
		colorB = Color3.fromRGB(40, 140, 255),
	},
	{
		id = "Lime",
		name = "Lime Rush",
		price = 250,
		colorA = Color3.fromRGB(190, 255, 70),
		colorB = Color3.fromRGB(40, 200, 90),
	},
	{
		id = "Violet",
		name = "Violet Haze",
		price = 350,
		colorA = Color3.fromRGB(200, 120, 255),
		colorB = Color3.fromRGB(90, 60, 230),
	},
	{
		id = "Gold",
		name = "Gold Rush",
		price = 750,
		colorA = Color3.fromRGB(255, 230, 120),
		colorB = Color3.fromRGB(230, 160, 30),
	},
	{
		id = "Ghost",
		name = "Ghost",
		price = 1200,
		colorA = Color3.fromRGB(255, 255, 255),
		colorB = Color3.fromRGB(150, 170, 200),
	},
}

local PERKS: { Perk } = {
	{
		id = "StaminaReserve",
		name = "Stamina Reserve",
		description = "+5 max stamina per level",
		prices = { 200, 450, 800 },
	},
	{
		id = "QuickBreath",
		name = "Quick Breath",
		description = "+8% stamina regen per level",
		prices = { 200, 450, 800 },
	},
}

local COIN_PACKS: { CoinPack } = {
	{ productId = 0, coins = 500, label = "500 coins" },
	{ productId = 0, coins = 1200, label = "1,200 coins" },
	{ productId = 0, coins = 3000, label = "3,000 coins" },
}

-- Perk effects per level.
local STAMINA_PER_LEVEL = 5
local REGEN_PER_LEVEL = 0.08

local trailsById: { [string]: Trail } = {}
for _, trail in TRAILS do
	trailsById[trail.id] = trail
end
local perksById: { [string]: Perk } = {}
for _, perk in PERKS do
	perksById[perk.id] = perk
end

local ShopCatalog = {
	TRAILS = TRAILS,
	PERKS = PERKS,
	COIN_PACKS = COIN_PACKS,
	STAMINA_PER_LEVEL = STAMINA_PER_LEVEL,
	REGEN_PER_LEVEL = REGEN_PER_LEVEL,
}

function ShopCatalog.trail(id: string): Trail?
	return trailsById[id]
end

function ShopCatalog.perk(id: string): Perk?
	return perksById[id]
end

function ShopCatalog.coinPack(productId: number): CoinPack?
	if productId == 0 then
		return nil
	end
	for _, pack in COIN_PACKS do
		if pack.productId == productId then
			return pack
		end
	end
	return nil
end

-- Price of the next level of a perk, or nil when it's maxed.
function ShopCatalog.nextPerkPrice(perk: Perk, level: number): number?
	return perk.prices[level + 1]
end

return ShopCatalog
