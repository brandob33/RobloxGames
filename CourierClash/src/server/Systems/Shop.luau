--!strict
-- Coins and the lobby shop. Coins are earned from play (deliveries, landed
-- tackles, round wins, rounds played) and Robux coin packs, and are spent
-- on cosmetic trails and small, capped perks. All prices and effects come
-- from ShopCatalog on the server; the client only names what it wants.
--
-- Buying is lobby-only (any phase except Playing); equipping works anytime.

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local ShopCatalog = require(ReplicatedStorage.Shared.ShopCatalog)
local Net = require(ServerScriptService.Server.Net)
local RateLimit = require(ServerScriptService.Server.Util.RateLimit)
local Agents = require(script.Parent.Agents)
local Match = require(script.Parent.Match)
local Parcel = require(script.Parent.Parcel)
local PlayerData = require(script.Parent.PlayerData)

type Data = PlayerData.Data

local Shop = {}

local TRAIL_NAME = "CourierClashTrail"
local MAX_ID_LENGTH = 40
-- Round rewards only go to players who actually played: here when the round
-- started and moved at least this far during it (no AFK farming).
local MIN_ROUND_DISTANCE = 150
local ACTIVITY_SAMPLE_SECONDS = 1

-- Players with a Robux purchase being saved; their coins can't be spent
-- until it settles, so a failed save can be undone cleanly.
local purchasing: { [Player]: boolean } = {}
local characterConnections: { [Player]: RBXScriptConnection } = {}
-- Per round: distance each player has moved (present at round start only).
local roundDistance: { [Player]: number } = {}
local lastPositions: { [Player]: Vector3 } = {}

local function sendProfile(player: Player)
	local data = PlayerData.get(player)
	local view: Types.ProfileView
	if data then
		local owned = {}
		for id, isOwned in data.trails do
			if isOwned then
				table.insert(owned, id)
			end
		end
		view = {
			coins = data.coins,
			ownedTrails = owned,
			equippedTrail = data.equippedTrail,
			perks = table.clone(data.perks),
			loaded = true,
			saving = PlayerData.isPersistent(player),
		}
	else
		view = {
			coins = 0,
			ownedTrails = {},
			equippedTrail = "",
			perks = {},
			loaded = false,
			saving = true,
		}
	end
	Net.fire(player, "Profile", view)
end

local function setLeaderstat(player: Player, coins: number)
	local stats = player:FindFirstChild("leaderstats")
	if not stats then
		local folder = Instance.new("Folder")
		folder.Name = "leaderstats"
		folder.Parent = player
		stats = folder
	end
	local value = (stats :: Instance):FindFirstChild("Coins")
	if not value then
		local intValue = Instance.new("IntValue")
		intValue.Name = "Coins"
		intValue.Parent = stats
		value = intValue
	end
	if value and value:IsA("IntValue") then
		value.Value = coins
	end
end

local function perkLevel(data: Data, perkId: string): number
	local level = data.perks[perkId]
	return if typeof(level) == "number" then level else 0
end

-- Push perk levels onto the player's courier.
local function applyPerks(player: Player)
	local agent = Agents.fromPlayer(player)
	local data = PlayerData.get(player)
	if not agent or not data then
		return
	end
	agent.staminaMax = Config.STAMINA_MAX + perkLevel(data, "StaminaReserve") * ShopCatalog.STAMINA_PER_LEVEL
	agent.staminaRegen = Config.STAMINA_REGEN * (1 + perkLevel(data, "QuickBreath") * ShopCatalog.REGEN_PER_LEVEL)
end

local function applyTrail(player: Player)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local existing = root:FindFirstChild(TRAIL_NAME)
	if existing then
		existing:Destroy()
	end
	local data = PlayerData.get(player)
	local trail = data and ShopCatalog.trail(data.equippedTrail)
	if not trail then
		return
	end

	local holder = Instance.new("Folder")
	holder.Name = TRAIL_NAME
	local top = Instance.new("Attachment")
	top.Position = Vector3.new(0, 0.8, 0)
	top.Parent = root
	local bottom = Instance.new("Attachment")
	bottom.Position = Vector3.new(0, -0.8, 0)
	bottom.Parent = root
	local effect = Instance.new("Trail")
	effect.Attachment0 = top
	effect.Attachment1 = bottom
	effect.Lifetime = 0.45
	effect.MinLength = 0.1
	effect.LightEmission = 0.6
	effect.FaceCamera = true
	effect.Color = ColorSequence.new(trail.colorA, trail.colorB)
	effect.Transparency = NumberSequence.new(0.15, 1)
	effect.WidthScale = NumberSequence.new(1, 0.2)
	effect.Parent = holder
	-- Keep the attachments with the folder so one Destroy removes everything.
	top.Name = TRAIL_NAME .. "Top"
	bottom.Name = TRAIL_NAME .. "Bottom"
	holder.Destroying:Once(function()
		top:Destroy()
		bottom:Destroy()
	end)
	holder.Parent = root
end

local function award(player: Player, amount: number, reason: Types.CoinReason)
	local data = PlayerData.get(player)
	if not data or amount <= 0 then
		return
	end
	data.coins += amount
	setLeaderstat(player, data.coins)
	Net.fire(player, "CoinsEarned", amount, reason)
	sendProfile(player)
end

local function reply(player: Player, ok: boolean, message: string)
	local result: Types.ShopResult = { ok = ok, message = message }
	Net.fire(player, "ShopResult", result)
end

local function buyTrail(player: Player, data: Data, id: string)
	local trail = ShopCatalog.trail(id)
	if not trail then
		return
	end
	if data.trails[id] then
		reply(player, false, "You already own that trail.")
		return
	end
	if data.coins < trail.price then
		reply(player, false, "Not enough coins.")
		return
	end
	data.coins -= trail.price
	data.trails[id] = true
	data.equippedTrail = id
	applyTrail(player)
	reply(player, true, `Bought {trail.name}!`)
end

local function buyPerk(player: Player, data: Data, id: string)
	local perk = ShopCatalog.perk(id)
	if not perk then
		return
	end
	local level = perkLevel(data, id)
	local price = ShopCatalog.nextPerkPrice(perk, level)
	if not price then
		reply(player, false, "That upgrade is maxed out.")
		return
	end
	if data.coins < price then
		reply(player, false, "Not enough coins.")
		return
	end
	data.coins -= price
	data.perks[id] = level + 1
	applyPerks(player)
	reply(player, true, `{perk.name} is now level {level + 1}!`)
end

local function equip(player: Player, data: Data, id: string)
	if id ~= "" and not data.trails[id] then
		return
	end
	data.equippedTrail = id
	applyTrail(player)
end

local function onShopRequest(player: Player, request: unknown)
	if not RateLimit.allow(player, "Shop", 4, 6) then
		return
	end
	if typeof(request) ~= "table" then
		return
	end
	local kind = (request :: any).kind
	local id = (request :: any).id
	if typeof(kind) ~= "string" or typeof(id) ~= "string" or #id > MAX_ID_LENGTH then
		return
	end
	if kind == "Refresh" then
		sendProfile(player)
		return
	end
	local data = PlayerData.get(player)
	if not data then
		reply(player, false, "Still loading your coins, try again in a moment.")
		return
	end

	if kind == "Equip" then
		equip(player, data, id)
	elseif kind == "BuyTrail" or kind == "BuyPerk" then
		if purchasing[player] then
			reply(player, false, "Finishing your purchase, try again in a moment.")
			return
		end
		if Match.getPhase() == "Playing" then
			reply(player, false, "The shop opens in the lobby between games.")
			return
		end
		if kind == "BuyTrail" then
			buyTrail(player, data, id)
		else
			buyPerk(player, data, id)
		end
		setLeaderstat(player, data.coins)
	else
		return
	end
	sendProfile(player)
end

-- Robux coin packs. Roblox retries a receipt until we return
-- PurchaseGranted, so grant only once the coins are safely saved, and
-- remember receipt ids so a retry never grants twice.
local function processReceipt(receipt: any): Enum.ProductPurchaseDecision
	local player = Players:GetPlayerByUserId(receipt.PlayerId)
	local data = player and PlayerData.get(player)
	if not player or not data then
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	local receiptId = tostring(receipt.PurchaseId)
	if PlayerData.hasReceipt(data, receiptId) then
		return Enum.ProductPurchaseDecision.PurchaseGranted
	end
	local pack = ShopCatalog.coinPack(receipt.ProductId)
	if not pack or purchasing[player] then
		if not pack then
			warn(`[Shop] receipt for unknown product {receipt.ProductId}`)
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end

	purchasing[player] = true
	data.coins += pack.coins
	PlayerData.addReceipt(data, receiptId)
	local saved = PlayerData.save(player)
	purchasing[player] = nil
	if not saved then
		-- Undo and let Roblox retry later.
		data.coins -= pack.coins
		local index = table.find(data.receipts, receiptId)
		if index then
			table.remove(data.receipts, index)
		end
		return Enum.ProductPurchaseDecision.NotProcessedYet
	end
	setLeaderstat(player, data.coins)
	Net.fire(player, "CoinsEarned", pack.coins, "Purchase")
	sendProfile(player)
	return Enum.ProductPurchaseDecision.PurchaseGranted
end

local function onLoaded(player: Player)
	local data = PlayerData.get(player)
	if data then
		setLeaderstat(player, data.coins)
	end
	applyPerks(player)
	applyTrail(player)
	sendProfile(player)
end

local function onPlayerAdded(player: Player)
	sendProfile(player)
	characterConnections[player] = player.CharacterAdded:Connect(function(character)
		character:WaitForChild("HumanoidRootPart", 10)
		if player.Character == character then
			applyTrail(player)
			applyPerks(player)
		end
	end)
end

local function onPlayerRemoving(player: Player)
	local connection = characterConnections[player]
	if connection then
		connection:Disconnect()
		characterConnections[player] = nil
	end
	purchasing[player] = nil
	roundDistance[player] = nil
	lastPositions[player] = nil
end

local function sampleActivity()
	if Match.getPhase() ~= "Playing" then
		return
	end
	for player, distance in roundDistance do
		local agent = Agents.fromPlayer(player)
		local root = agent and Agents.root(agent)
		if root then
			local last = lastPositions[player]
			if last then
				local delta = root.Position - last
				roundDistance[player] = distance + Vector3.new(delta.X, 0, delta.Z).Magnitude
			end
			lastPositions[player] = root.Position
		end
	end
end

function Shop.init()
	Net.on("Shop", onShopRequest)
	MarketplaceService.ProcessReceipt = processReceipt

	PlayerData.Loaded.connect(onLoaded)

	Parcel.Delivered.connect(function(agent)
		local player = agent.player
		if player then
			award(player, Config.COINS_DELIVERY, "Delivery")
		end
	end)
	Parcel.TackleLanded.connect(function(agent)
		local player = agent.player
		if player then
			award(player, Config.COINS_TACKLE, "Tackle")
		end
	end)
	Match.RoundStarting.connect(function()
		table.clear(roundDistance)
		table.clear(lastPositions)
		for _, player in Players:GetPlayers() do
			roundDistance[player] = 0
		end
	end)
	Match.RoundEnded.connect(function(result)
		for player, distance in roundDistance do
			local agent = Agents.fromPlayer(player)
			if agent and distance >= MIN_ROUND_DISTANCE then
				award(player, Config.COINS_PLAYED, "Played")
				if agent.team == result then
					award(player, Config.COINS_WIN, "Win")
				end
			end
		end
		table.clear(roundDistance)
	end)
	-- Kickoff teleports aren't movement: forget the last position.
	Agents.Teleported.connect(function(teleport)
		local player = teleport.agent.player
		if player then
			lastPositions[player] = nil
		end
	end)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
end

function Shop.start()
	-- Anyone whose data loaded before we were listening, or before their
	-- courier existed.
	for _, player in Players:GetPlayers() do
		if PlayerData.get(player) then
			onLoaded(player)
		end
	end
	while true do
		task.wait(ACTIVITY_SAMPLE_SECONDS)
		sampleActivity()
	end
end

return Shop
