--!strict
-- Coin counter and the lobby shop screen. Draws whatever the server's
-- Profile says and sends requests; the server checks every price.
--
-- Open with the SHOP button or M. Buying only works between games; the
-- buttons say so during a round. Equipping works anytime.

local Players = game:GetService("Players")
local MarketplaceService = game:GetService("MarketplaceService")
local ContextActionService = game:GetService("ContextActionService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Types = require(ReplicatedStorage.Shared.Types)
local ShopCatalog = require(ReplicatedStorage.Shared.ShopCatalog)
local Net = require(script.Parent.Parent.Net)

local ShopController = {}

type Tab = "Trails" | "Upgrades" | "Coins"

local localPlayer = Players.LocalPlayer

local FONT_BOLD = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)
local FONT_HEAVY = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Heavy)
local PANEL_COLOR = Color3.fromRGB(24, 26, 36)
local CARD_COLOR = Color3.fromRGB(38, 41, 56)
local TEXT_COLOR = Color3.fromRGB(245, 245, 245)
local MUTED_COLOR = Color3.fromRGB(170, 175, 190)
local COIN_COLOR = Color3.fromRGB(255, 206, 70)
local BUY_COLOR = Color3.fromRGB(70, 190, 110)
local EQUIP_COLOR = Color3.fromRGB(60, 140, 230)
local OFF_COLOR = Color3.fromRGB(80, 84, 100)
local ERROR_COLOR = Color3.fromRGB(255, 110, 110)
local TOAST_TWEEN = TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

local REASON_TEXT: { [Types.CoinReason]: string } = {
	Delivery = "Delivery",
	Tackle = "Tackle",
	Win = "Win",
	Played = "Round played",
	Purchase = "Purchase",
}

local profile: Types.ProfileView = {
	coins = 0,
	ownedTrails = {},
	equippedTrail = "",
	perks = {},
	loaded = false,
	saving = true,
}
local phase: Types.Phase = "Waiting"
local currentTab: Tab = "Trails"

type Refs = {
	gui: ScreenGui,
	coinLabel: TextLabel,
	toastHolder: Frame,
	panel: Frame,
	panelCoins: TextLabel,
	content: ScrollingFrame,
	message: TextLabel,
	notice: TextLabel,
	tabButtons: { [Tab]: TextButton },
}
local refs: Refs

local function corner(parent: Instance, scale: number)
	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = UDim.new(scale, 0)
	uiCorner.Parent = parent
end

local function label(parent: Instance, name: string, size: UDim2, maxTextSize: number): TextLabel
	local text = Instance.new("TextLabel")
	text.Name = name
	text.Size = size
	text.BackgroundTransparency = 1
	text.TextColor3 = TEXT_COLOR
	text.FontFace = FONT_BOLD
	text.TextScaled = true
	text.Text = ""
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = maxTextSize
	constraint.Parent = text
	text.Parent = parent
	return text
end

local function button(parent: Instance, name: string, text: string, color: Color3): TextButton
	local btn = Instance.new("TextButton")
	btn.Name = name
	btn.BackgroundColor3 = color
	btn.AutoButtonColor = true
	btn.TextColor3 = TEXT_COLOR
	btn.FontFace = FONT_HEAVY
	btn.TextScaled = true
	btn.Text = text
	corner(btn, 0.25)
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = 20
	constraint.Parent = btn
	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0.18, 0)
	padding.PaddingBottom = UDim.new(0.18, 0)
	padding.PaddingLeft = UDim.new(0.06, 0)
	padding.PaddingRight = UDim.new(0.06, 0)
	padding.Parent = btn
	btn.Parent = parent
	return btn
end

local function formatCoins(amount: number): string
	local text = tostring(math.floor(amount))
	-- 12345 → 12,345
	local formatted = text:reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (formatted:gsub("^,", ""))
end

local function canBuy(): boolean
	return phase ~= "Playing" and profile.loaded
end

local function setMessage(text: string, isError: boolean)
	refs.message.Text = text
	refs.message.TextColor3 = if isError then ERROR_COLOR else BUY_COLOR
end

local function send(kind: "BuyTrail" | "BuyPerk" | "Equip" | "Refresh", id: string)
	local request: Types.ShopRequest = { kind = kind, id = id }
	Net.fire("Shop", request)
end

local function card(order: number): Frame
	local frame = Instance.new("Frame")
	frame.Name = "Card" .. order
	frame.LayoutOrder = order
	frame.BackgroundColor3 = CARD_COLOR
	corner(frame, 0.08)
	frame.Parent = refs.content
	return frame
end

local function trailCard(trail: ShopCatalog.Trail, order: number)
	local frame = card(order)
	local swatch = Instance.new("Frame")
	swatch.Name = "Swatch"
	swatch.Position = UDim2.fromScale(0.08, 0.07)
	swatch.Size = UDim2.fromScale(0.84, 0.36)
	swatch.BackgroundColor3 = Color3.new(1, 1, 1)
	corner(swatch, 0.2)
	local gradient = Instance.new("UIGradient")
	gradient.Color = ColorSequence.new(trail.colorA, trail.colorB)
	gradient.Parent = swatch
	swatch.Parent = frame

	local name = label(frame, "Name", UDim2.fromScale(0.84, 0.16), 22)
	name.Position = UDim2.fromScale(0.08, 0.47)
	name.Text = trail.name

	local owned = table.find(profile.ownedTrails, trail.id) ~= nil
	local equipped = profile.equippedTrail == trail.id
	local text: string
	local color: Color3
	if equipped then
		text, color = "EQUIPPED", OFF_COLOR
	elseif owned then
		text, color = "EQUIP", EQUIP_COLOR
	elseif canBuy() then
		text, color = `BUY {formatCoins(trail.price)}`, BUY_COLOR
	else
		text, color = `{formatCoins(trail.price)} (lobby)`, OFF_COLOR
	end
	local action = button(frame, "Action", text, color)
	action.Position = UDim2.fromScale(0.08, 0.7)
	action.Size = UDim2.fromScale(0.84, 0.22)
	action.Activated:Connect(function()
		if equipped then
			send("Equip", "") -- take it off
		elseif owned then
			send("Equip", trail.id)
		elseif canBuy() then
			send("BuyTrail", trail.id)
		else
			setMessage("The shop opens in the lobby between games.", true)
		end
	end)
end

local function perkCard(perk: ShopCatalog.Perk, order: number)
	local frame = card(order)
	local level = profile.perks[perk.id] or 0
	local maxLevel = #perk.prices

	local name = label(frame, "Name", UDim2.fromScale(0.84, 0.18), 22)
	name.Position = UDim2.fromScale(0.08, 0.07)
	name.Text = perk.name
	local description = label(frame, "Description", UDim2.fromScale(0.84, 0.2), 16)
	description.Position = UDim2.fromScale(0.08, 0.27)
	description.TextColor3 = MUTED_COLOR
	description.FontFace = FONT_BOLD
	description.Text = perk.description
	local levelLabel = label(frame, "Level", UDim2.fromScale(0.84, 0.14), 18)
	levelLabel.Position = UDim2.fromScale(0.08, 0.5)
	levelLabel.TextColor3 = COIN_COLOR
	levelLabel.Text = `Level {level} / {maxLevel}`

	local price = ShopCatalog.nextPerkPrice(perk, level)
	local text: string
	local color: Color3
	if not price then
		text, color = "MAXED", OFF_COLOR
	elseif canBuy() then
		text, color = `UPGRADE {formatCoins(price)}`, BUY_COLOR
	else
		text, color = `{formatCoins(price)} (lobby)`, OFF_COLOR
	end
	local action = button(frame, "Action", text, color)
	action.Position = UDim2.fromScale(0.08, 0.7)
	action.Size = UDim2.fromScale(0.84, 0.22)
	action.Activated:Connect(function()
		if not price then
			return
		elseif canBuy() then
			send("BuyPerk", perk.id)
		else
			setMessage("The shop opens in the lobby between games.", true)
		end
	end)
end

local function coinPackCard(pack: ShopCatalog.CoinPack, order: number)
	local frame = card(order)
	local amount = label(frame, "Amount", UDim2.fromScale(0.84, 0.3), 30)
	amount.Position = UDim2.fromScale(0.08, 0.15)
	amount.TextColor3 = COIN_COLOR
	amount.FontFace = FONT_HEAVY
	amount.Text = pack.label
	local action = button(frame, "Action", "BUY WITH ROBUX", BUY_COLOR)
	action.Position = UDim2.fromScale(0.08, 0.7)
	action.Size = UDim2.fromScale(0.84, 0.22)
	action.Activated:Connect(function()
		MarketplaceService:PromptProductPurchase(localPlayer, pack.productId)
	end)
end

local function render()
	refs.coinLabel.Text = if profile.loaded then formatCoins(profile.coins) else "..."
	refs.panelCoins.Text = `COINS  {formatCoins(profile.coins)}`
	for tab, tabButton in refs.tabButtons do
		tabButton.BackgroundColor3 = if tab == currentTab then EQUIP_COLOR else CARD_COLOR
	end
	if not refs.panel.Visible then
		return
	end

	for _, child in refs.content:GetChildren() do
		if child:IsA("Frame") then
			child:Destroy()
		end
	end
	if not profile.loaded then
		refs.notice.Text = "Loading your coins..."
		return
	end
	if currentTab == "Trails" then
		for index, trail in ShopCatalog.TRAILS do
			trailCard(trail, index)
		end
	elseif currentTab == "Upgrades" then
		for index, perk in ShopCatalog.PERKS do
			perkCard(perk, index)
		end
	else
		local shown = 0
		for index, pack in ShopCatalog.COIN_PACKS do
			if pack.productId ~= 0 then
				coinPackCard(pack, index)
				shown += 1
			end
		end
		if shown == 0 then
			refs.notice.Text = "Coin packs are coming soon. Earn coins by playing!"
			return
		end
	end
	refs.notice.Text = if profile.saving
		then ""
		else "Studio test: coins won't be saved this session."
end

local function setOpen(open: boolean)
	refs.panel.Visible = open
	if open then
		refs.message.Text = ""
	end
	render()
end

local function toast(text: string)
	-- Stacked by the holder's UIListLayout so simultaneous toasts don't overlap.
	local item = label(refs.toastHolder, "Toast", UDim2.fromScale(1, 0.3), 20)
	item.TextColor3 = COIN_COLOR
	item.FontFace = FONT_HEAVY
	item.TextXAlignment = Enum.TextXAlignment.Left
	item.TextStrokeTransparency = 0.4
	item.Text = text
	local tween = TweenService:Create(item, TOAST_TWEEN, {
		TextTransparency = 1,
		TextStrokeTransparency = 1,
	})
	task.delay(1.4, function()
		tween:Play()
	end)
	tween.Completed:Once(function()
		item:Destroy()
	end)
end

local function buildGui(): Refs
	local gui = Instance.new("ScreenGui")
	gui.Name = "CourierClashShop"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 5

	-- Coin chip + SHOP button, top-left under the Roblox menu buttons.
	local chip = Instance.new("Frame")
	chip.Name = "Coins"
	chip.Position = UDim2.fromScale(0.015, 0.1)
	chip.Size = UDim2.fromScale(0.13, 0.05)
	chip.BackgroundColor3 = PANEL_COLOR
	chip.BackgroundTransparency = 0.15
	corner(chip, 0.3)
	local chipAspect = Instance.new("UIAspectRatioConstraint")
	chipAspect.AspectRatio = 3.6
	chipAspect.Parent = chip
	local coinIcon = Instance.new("Frame")
	coinIcon.Name = "Icon"
	coinIcon.AnchorPoint = Vector2.new(0, 0.5)
	coinIcon.Position = UDim2.fromScale(0.06, 0.5)
	coinIcon.Size = UDim2.fromScale(0.6, 0.6)
	coinIcon.SizeConstraint = Enum.SizeConstraint.RelativeYY
	coinIcon.BackgroundColor3 = COIN_COLOR
	corner(coinIcon, 0.5)
	coinIcon.Parent = chip
	local coinLabel = label(chip, "Amount", UDim2.fromScale(0.68, 0.7), 24)
	coinLabel.AnchorPoint = Vector2.new(0, 0.5)
	coinLabel.Position = UDim2.fromScale(0.28, 0.5)
	coinLabel.TextXAlignment = Enum.TextXAlignment.Left
	coinLabel.FontFace = FONT_HEAVY
	chip.Parent = gui

	local shopButton = button(gui, "ShopButton", "SHOP [M]", BUY_COLOR)
	shopButton.Position = UDim2.fromScale(0.015, 0.16)
	shopButton.Size = UDim2.fromScale(0.13, 0.05)
	local shopAspect = Instance.new("UIAspectRatioConstraint")
	shopAspect.AspectRatio = 3.6
	shopAspect.Parent = shopButton

	local toastHolder = Instance.new("Frame")
	toastHolder.Name = "Toasts"
	toastHolder.BackgroundTransparency = 1
	toastHolder.Position = UDim2.fromScale(0.15, 0.1)
	toastHolder.Size = UDim2.fromScale(0.25, 0.12)
	local toastLayout = Instance.new("UIListLayout")
	toastLayout.SortOrder = Enum.SortOrder.LayoutOrder
	toastLayout.Parent = toastHolder
	toastHolder.Parent = gui

	-- The shop panel.
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.52)
	panel.Size = UDim2.fromScale(0.62, 0.72)
	panel.BackgroundColor3 = PANEL_COLOR
	panel.Visible = false
	corner(panel, 0.04)
	local panelAspect = Instance.new("UIAspectRatioConstraint")
	panelAspect.AspectRatio = 1.5
	panelAspect.Parent = panel
	panel.Parent = gui

	local title = label(panel, "Title", UDim2.fromScale(0.3, 0.09), 36)
	title.Position = UDim2.fromScale(0.04, 0.03)
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.FontFace = FONT_HEAVY
	title.Text = "SHOP"

	local panelCoins = label(panel, "Coins", UDim2.fromScale(0.35, 0.07), 26)
	panelCoins.Position = UDim2.fromScale(0.45, 0.04)
	panelCoins.TextXAlignment = Enum.TextXAlignment.Right
	panelCoins.TextColor3 = COIN_COLOR
	panelCoins.FontFace = FONT_HEAVY

	local close = button(panel, "Close", "X", ERROR_COLOR)
	close.AnchorPoint = Vector2.new(1, 0)
	close.Position = UDim2.fromScale(0.97, 0.03)
	close.Size = UDim2.fromScale(0.07, 0.09)
	close.Activated:Connect(function()
		setOpen(false)
	end)

	local tabs = Instance.new("Frame")
	tabs.Name = "Tabs"
	tabs.BackgroundTransparency = 1
	tabs.Position = UDim2.fromScale(0.04, 0.15)
	tabs.Size = UDim2.fromScale(0.92, 0.08)
	local tabLayout = Instance.new("UIListLayout")
	tabLayout.FillDirection = Enum.FillDirection.Horizontal
	tabLayout.Padding = UDim.new(0.02, 0)
	tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	tabLayout.Parent = tabs
	tabs.Parent = panel
	local tabButtons: { [Tab]: TextButton } = {}
	local tabOrder: { Tab } = { "Trails", "Upgrades", "Coins" }
	for index, tab in tabOrder do
		local tabButton = button(tabs, tab, string.upper(tab), CARD_COLOR)
		tabButton.LayoutOrder = index
		tabButton.Size = UDim2.fromScale(0.25, 1)
		tabButton.Activated:Connect(function()
			currentTab = tab
			refs.message.Text = ""
			render()
		end)
		tabButtons[tab] = tabButton
	end

	local content = Instance.new("ScrollingFrame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.BorderSizePixel = 0
	content.Position = UDim2.fromScale(0.04, 0.26)
	content.Size = UDim2.fromScale(0.92, 0.62)
	content.ScrollBarThickness = 6
	content.AutomaticCanvasSize = Enum.AutomaticSize.Y
	content.CanvasSize = UDim2.new()
	local grid = Instance.new("UIGridLayout")
	grid.CellSize = UDim2.fromScale(0.31, 0.46)
	grid.CellPadding = UDim2.fromScale(0.02, 0.04)
	grid.SortOrder = Enum.SortOrder.LayoutOrder
	grid.Parent = content
	content.Parent = panel

	local message = label(panel, "Message", UDim2.fromScale(0.92, 0.05), 20)
	message.Position = UDim2.fromScale(0.04, 0.885)
	-- Standing notes (loading, Studio not saving) live apart from replies.
	local notice = label(panel, "Notice", UDim2.fromScale(0.92, 0.04), 16)
	notice.Position = UDim2.fromScale(0.04, 0.94)
	notice.TextColor3 = MUTED_COLOR

	shopButton.Activated:Connect(function()
		setOpen(not panel.Visible)
	end)

	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	return {
		gui = gui,
		coinLabel = coinLabel,
		toastHolder = toastHolder,
		panel = panel,
		panelCoins = panelCoins,
		content = content,
		message = message,
		notice = notice,
		tabButtons = tabButtons,
	}
end

local function onProfile(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	profile = payload :: Types.ProfileView
	render()
end

local function onCoinsEarned(amount: unknown, reason: unknown)
	if typeof(amount) ~= "number" or typeof(reason) ~= "string" then
		return
	end
	local text = REASON_TEXT[reason :: Types.CoinReason] or reason
	toast(`+{formatCoins(amount)} coins  {text}`)
end

local function onShopResult(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local result = payload :: Types.ShopResult
	if typeof(result.message) == "string" then
		setMessage(result.message, not result.ok)
	end
end

local function onState(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local newPhase = (payload :: Types.MatchState).phase
	if newPhase ~= phase then
		phase = newPhase
		render()
	end
end

function ShopController.init()
	refs = buildGui()
	Net.on("Profile", onProfile)
	Net.on("CoinsEarned", onCoinsEarned)
	Net.on("ShopResult", onShopResult)
	Net.on("State", onState)
	ContextActionService:BindAction("CourierClashShop", function(_, state)
		if state == Enum.UserInputState.Begin then
			setOpen(not refs.panel.Visible)
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.KeyCode.M)
	render()
	-- The server's first Profile may have arrived before we were listening.
	send("Refresh", "")
end

return ShopController
