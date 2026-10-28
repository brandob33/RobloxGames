--!strict
-- Saved player data (coins, owned trails, perk levels). The only module that
-- touches DataStores; everything else reads and changes the in-memory table
-- from PlayerData.get().
--
-- Safety rules this follows:
--   * every call goes through UpdateAsync with retries, never SetAsync
--   * session lock: each load writes a fresh session id into the record, and
--     nobody else loads or overwrites it until that session releases it (on
--     leave) or the lock goes stale (server crashed). The id is per session,
--     not per server, so a quick rejoin to the same server waits for the
--     old session's release like any other server would
--   * if this session loses its lock it stops saving and kicks the player
--   * autosave every AUTOSAVE_SECONDS, final save on leave and on shutdown
--   * if a load fails the player is kicked rather than handed a blank
--     profile that would overwrite their real data on the next save
--
-- In Studio without "Enable Studio Access to API Services", DataStores
-- error; the player then gets a temporary profile that isn't saved.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Signal = require(ReplicatedStorage.Shared.Util.Signal)

local PlayerData = {}

export type Data = {
	version: number,
	coins: number,
	trails: { [string]: boolean }, -- owned trail ids
	equippedTrail: string, -- "" = none
	perks: { [string]: number }, -- perk id → level
	receipts: { string }, -- recent Robux purchase ids, newest last
}

type Record = {
	data: Data,
	lockServer: string, -- "" = not locked
	lockTime: number, -- os.time() of the lock holder's last write
}

type Profile = {
	data: Data,
	lockId: string, -- this session's id in the record's lockServer
	persistent: boolean, -- false = Studio fallback, never written
	lastSaved: number, -- os.clock()
	busy: boolean, -- a write is in flight
	released: boolean,
}

-- Studio uses its own store so test sessions never touch live data.
local STORE_NAME = if RunService:IsStudio()
	then "CourierClashPlayers_Studio"
	else "CourierClashPlayers"
local DATA_VERSION = 1
local AUTOSAVE_SECONDS = 60
-- A lock older than this belongs to a server that died without releasing.
local LOCK_STALE_SECONDS = AUTOSAVE_SECONDS * 3
local LOAD_ATTEMPTS = 5
-- How long to keep waiting for another session to release a player's lock
-- (usually a previous server finishing its final save) before giving up.
local LOCK_WAIT_SECONDS = 60
local LOCK_RETRY_SECONDS = 4
local SAVE_ATTEMPTS = 3
local RELEASE_ATTEMPTS = 5
local MAX_RECEIPTS = 50
local SHUTDOWN_WAIT_SECONDS = 25

-- Fired with the player once their data is ready.
local loaded: Signal.Signal<Player> = Signal.new()
PlayerData.Loaded = loaded

local isStudio = RunService:IsStudio()
local store: DataStore? = nil
local profiles: { [Player]: Profile } = {}
-- Loads in progress, so shutdown waits for them too.
local loadingCount = 0
local shuttingDown = false

local MIGRATIONS: { [number]: (any) -> any } = {
	-- [1] = function(data) ... return data end, when version 2 arrives
}

local function defaultData(): Data
	return {
		version = DATA_VERSION,
		coins = 0,
		trails = {},
		equippedTrail = "",
		perks = {},
		receipts = {},
	}
end

-- Bring stored data up to the current version and fill in anything missing
-- or malformed, so the rest of the game can trust the shape.
local function migrate(raw: any): Data
	local data = if typeof(raw) == "table" then raw else defaultData()
	if typeof(data.version) ~= "number" then
		data.version = DATA_VERSION
	end
	while data.version < DATA_VERSION do
		local step = MIGRATIONS[data.version]
		if not step then
			error(`no migration from version {data.version}`)
		end
		data = step(data)
		data.version += 1
	end
	if typeof(data.coins) ~= "number" or data.coins ~= data.coins or data.coins == math.huge then
		data.coins = 0
	end
	data.coins = math.max(0, math.floor(data.coins))
	if typeof(data.trails) ~= "table" then
		data.trails = {}
	end
	if typeof(data.equippedTrail) ~= "string" then
		data.equippedTrail = ""
	end
	if typeof(data.perks) ~= "table" then
		data.perks = {}
	end
	if typeof(data.receipts) ~= "table" then
		data.receipts = {}
	end
	return data :: Data
end

local function keyFor(player: Player): string
	return "u_" .. player.UserId
end

local function lockedByOther(record: any, lockId: string): boolean
	return typeof(record) == "table"
		and typeof(record.lockServer) == "string"
		and record.lockServer ~= ""
		and record.lockServer ~= lockId
		and typeof(record.lockTime) == "number"
		and os.time() - record.lockTime < LOCK_STALE_SECONDS
end

-- Claim the lock and read the data in one UpdateAsync. nil = failed.
local function loadData(player: Player, lockId: string): Data?
	local dataStore = store
	if not dataStore then
		return nil
	end
	local key = keyFor(player)
	local delaySeconds = 1
	local attempts = if isStudio then 1 else LOAD_ATTEMPTS
	local failures = 0
	local lockDeadline = os.clock() + LOCK_WAIT_SECONDS
	while true do
		local locked = false
		local ok, result = pcall(function()
			return dataStore:UpdateAsync(key, function(old: any): Record?
				locked = lockedByOther(old, lockId)
				if locked then
					return nil -- someone else's session; leave it alone
				end
				return {
					data = migrate(if typeof(old) == "table" then old.data else nil),
					lockServer = lockId,
					lockTime = os.time(),
				}
			end)
		end)
		if ok and not locked and typeof(result) == "table" then
			return migrate(result.data)
		end
		if player.Parent ~= Players then
			return nil
		end
		if ok and locked then
			-- Usually a previous server finishing its final save: wait it out.
			if isStudio or os.clock() >= lockDeadline then
				return nil
			end
			task.wait(LOCK_RETRY_SECONDS)
		else
			failures += 1
			warn(`[PlayerData] load {failures}/{attempts} for {player.Name} failed: {result}`)
			if failures >= attempts then
				return nil
			end
			task.wait(delaySeconds)
			delaySeconds = math.min(delaySeconds * 2, 16)
		end
	end
end

-- Write the profile (and refresh or release the lock). Returns success.
local function writeData(player: Player, profile: Profile, release: boolean): boolean
	local dataStore = store
	if not profile.persistent or not dataStore then
		return true
	end
	while profile.busy do
		task.wait(0.1)
	end
	if profile.released then
		return false
	end
	profile.busy = true
	local key = keyFor(player)
	local delaySeconds = 1
	local saved = false
	local lostLock = false
	local attempts = if release then RELEASE_ATTEMPTS else SAVE_ATTEMPTS
	for attempt = 1, attempts do
		local ok, err = pcall(function()
			dataStore:UpdateAsync(key, function(old: any): Record?
				-- Only ever write over our own session's lock.
				lostLock = typeof(old) == "table"
					and typeof(old.lockServer) == "string"
					and old.lockServer ~= profile.lockId
				if lostLock then
					return nil
				end
				return {
					data = profile.data,
					lockServer = if release then "" else profile.lockId,
					lockTime = os.time(),
				}
			end)
		end)
		if ok then
			saved = not lostLock
			break
		end
		warn(`[PlayerData] save {attempt}/{attempts} for {player.Name} failed: {err}`)
		if attempt < attempts then
			task.wait(delaySeconds)
			delaySeconds *= 2
		end
	end
	profile.lastSaved = os.clock()
	if release or lostLock then
		profile.released = true
	end
	profile.busy = false
	if lostLock and not release then
		-- Another session owns this data now; anything earned here would be
		-- lost, so stop the session instead of letting them keep playing.
		warn(`[PlayerData] {player.Name}'s data moved to another session`)
		task.defer(function()
			if player.Parent == Players then
				player:Kick("Your data was opened in another session. Please rejoin.")
			end
		end)
	end
	return saved
end

function PlayerData.get(player: Player): Data?
	local profile = profiles[player]
	return if profile and not profile.released then profile.data else nil
end

-- false when the profile is a Studio fallback that won't be kept.
function PlayerData.isPersistent(player: Player): boolean
	local profile = profiles[player]
	return profile ~= nil and profile.persistent
end

-- Save right now (Robux purchases). Yields. Returns success.
function PlayerData.save(player: Player): boolean
	local profile = profiles[player]
	if not profile then
		return false
	end
	return writeData(player, profile, false)
end

function PlayerData.hasReceipt(data: Data, receiptId: string): boolean
	return table.find(data.receipts, receiptId) ~= nil
end

function PlayerData.addReceipt(data: Data, receiptId: string)
	table.insert(data.receipts, receiptId)
	while #data.receipts > MAX_RECEIPTS do
		table.remove(data.receipts, 1)
	end
end

-- Wait until no earlier session of this user on this server is still
-- writing its final save.
local function waitForOldSession(player: Player)
	local deadline = os.clock() + LOCK_WAIT_SECONDS
	while os.clock() < deadline do
		local busy = false
		for other in profiles do
			if other ~= player and other.UserId == player.UserId then
				busy = true
			end
		end
		if not busy then
			return
		end
		task.wait(0.5)
	end
end

local function onPlayerAdded(player: Player)
	if shuttingDown then
		return
	end
	loadingCount += 1
	local lockId = HttpService:GenerateGUID(false)
	local data: Data? = nil
	local persistent = store ~= nil
	if store then
		waitForOldSession(player)
		data = loadData(player, lockId)
	end
	loadingCount -= 1
	if not data then
		if isStudio then
			warn("[PlayerData] DataStores unavailable in Studio; coins won't be saved this session")
			data = defaultData()
			persistent = false
		else
			if player.Parent == Players then
				player:Kick("Your saved data couldn't load. Please rejoin in a moment.")
			end
			return
		end
	end
	local loadedData = data :: Data

	local profile: Profile = {
		data = loadedData,
		lockId = lockId,
		persistent = persistent,
		lastSaved = os.clock(),
		busy = false,
		released = false,
	}
	if player.Parent ~= Players or shuttingDown then
		-- Left while loading (or the server is closing): hand the lock back.
		writeData(player, profile, true)
		return
	end
	profiles[player] = profile
	loaded.fire(player)
end

local function onPlayerRemoving(player: Player)
	local profile = profiles[player]
	if not profile then
		return
	end
	writeData(player, profile, true)
	profiles[player] = nil
end

function PlayerData.init()
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = result
	else
		warn(`[PlayerData] DataStore unavailable: {result}`)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	game:BindToClose(function()
		shuttingDown = true
		local pending = 0
		for player, profile in profiles do
			pending += 1
			task.spawn(function()
				writeData(player, profile, true)
				pending -= 1
			end)
		end
		local deadline = os.clock() + (if isStudio then 3 else SHUTDOWN_WAIT_SECONDS)
		-- Loads still in flight release their lock as soon as they finish.
		while (pending > 0 or loadingCount > 0) and os.clock() < deadline do
			task.wait(0.1)
		end
	end)
end

function PlayerData.start()
	-- Players already here (Studio Play Solo). Done in start so every
	-- system has connected to Loaded first.
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end
	-- Each profile saves AUTOSAVE_SECONDS after its last write, so saves are
	-- naturally staggered by join time.
	while true do
		task.wait(1)
		local now = os.clock()
		for player, profile in profiles do
			if
				profile.persistent
				and not profile.busy
				and not profile.released
				and now - profile.lastSaved >= AUTOSAVE_SECONDS
			then
				task.spawn(writeData, player, profile, false)
			end
		end
	end
end

return PlayerData
