--!strict
-- HUD: score bar + timer, package status, event banner, team tag and the
-- tackle and shove buttons. Renders server snapshots only; computes nothing that
-- matters. Layout is built in code with Scale sizes so it fits phones.

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local MatchLogic = require(ReplicatedStorage.Shared.Util.MatchLogic)
local Net = require(script.Parent.Parent.Net)
local TackleController = require(script.Parent.TackleController)
local ShoveController = require(script.Parent.ShoveController)
local MovementController = require(script.Parent.MovementController)

type TeamId = Types.TeamId

local HudController = {}

local localPlayer = Players.LocalPlayer

local FONT_BOLD = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)
local FONT_HEAVY = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Heavy)
local PANEL_COLOR = Color3.fromRGB(24, 26, 36)
local TEXT_COLOR = Color3.fromRGB(245, 245, 245)
local PARCEL_COLOR = Color3.fromRGB(240, 196, 64)
local STAMINA_COLOR = Color3.fromRGB(120, 220, 255)
local STAMINA_LOW_COLOR = Color3.fromRGB(255, 90, 90)
local STAMINA_TWEEN = TweenInfo.new(0.15, Enum.EasingStyle.Linear)
local SLIDE_READY_COLOR = Color3.fromRGB(255, 214, 90)
local SLIDE_CHARGING_COLOR = Color3.fromRGB(140, 140, 150)

local POP = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local SETTLE = TweenInfo.new(0.18, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
local FADE = TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local BANNER_SECONDS = 2.6

local state: Types.MatchState? = nil

type Refs = {
	scoreLabels: { [TeamId]: TextLabel },
	scoreScales: { [TeamId]: UIScale },
	phaseLabel: TextLabel,
	timerLabel: TextLabel,
	statusLabel: TextLabel,
	banner: CanvasGroup,
	bannerLabel: TextLabel,
	bannerScale: UIScale,
	teamTag: TextLabel,
	tackleButton: TextButton,
	tackleScale: UIScale,
	cooldownFill: Frame,
	shoveButton: TextButton,
	shoveScale: UIScale,
	shoveFill: Frame,
	sprintButton: TextButton,
	slideButton: TextButton,
	slideScale: UIScale,
	slideFill: Frame,
	staminaFill: Frame,
	slideMeter: Frame,
}
local refs: Refs

local bannerToken = 0
local bannerFade: Tween? = nil
local cooldownTween: Tween? = nil
local shoveTween: Tween? = nil
local slideCooldownTween: Tween? = nil
local slideMeterTween: Tween? = nil
local staminaTween: Tween? = nil

local function teamName(team: TeamId): string
	return string.upper(team)
end

local function myTeam(): TeamId?
	local team = localPlayer.Team
	if team and (team.Name == "Ember" or team.Name == "Tide") then
		return team.Name :: TeamId
	end
	return nil
end

local function corner(parent: GuiObject, scale: number)
	local uiCorner = Instance.new("UICorner")
	uiCorner.CornerRadius = UDim.new(scale, 0)
	uiCorner.Parent = parent
end

local function textLabel(
	parent: Instance,
	name: string,
	size: UDim2,
	maxTextSize: number
): TextLabel
	local label = Instance.new("TextLabel")
	label.Name = name
	label.Size = size
	label.BackgroundTransparency = 1
	label.TextColor3 = TEXT_COLOR
	label.FontFace = FONT_BOLD
	label.TextScaled = true
	label.Text = ""
	local constraint = Instance.new("UITextSizeConstraint")
	constraint.MaxTextSize = maxTextSize
	constraint.Parent = label
	label.Parent = parent
	return label
end

local function pop(scale: UIScale)
	local up = TweenService:Create(scale, POP, { Scale = 1.12 })
	up.Completed:Once(function()
		TweenService:Create(scale, SETTLE, { Scale = 1 }):Play()
	end)
	up:Play()
end

type RoundButton = { button: TextButton, scale: UIScale, fill: Frame }

-- Circular touch button with a cooldown fill that drains top-down.
local function roundButton(
	parent: Instance,
	name: string,
	text: string,
	position: UDim2,
	size: number
): RoundButton
	local button = Instance.new("TextButton")
	button.Name = name
	button.AnchorPoint = Vector2.new(1, 1)
	button.Position = position
	button.Size = UDim2.fromScale(size, size)
	button.BackgroundColor3 = PANEL_COLOR
	button.BackgroundTransparency = 0.15
	button.AutoButtonColor = true
	button.Text = ""
	button.ClipsDescendants = true
	corner(button, 0.5)
	local aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = 1
	aspect.Parent = button
	local scale = Instance.new("UIScale")
	scale.Parent = button
	local fill = Instance.new("Frame")
	fill.Name = "Cooldown"
	fill.AnchorPoint = Vector2.new(0, 1)
	fill.Position = UDim2.fromScale(0, 1)
	fill.Size = UDim2.fromScale(1, 0)
	fill.BackgroundColor3 = Color3.new(0, 0, 0)
	fill.BackgroundTransparency = 0.45
	fill.BorderSizePixel = 0
	fill.Parent = button
	local label = textLabel(button, "Label", UDim2.fromScale(0.86, 0.5), 22)
	label.AnchorPoint = Vector2.new(0.5, 0.5)
	label.Position = UDim2.fromScale(0.5, 0.5)
	label.Text = text
	label.FontFace = FONT_HEAVY
	label.ZIndex = 2
	button.Parent = parent
	return { button = button, scale = scale, fill = fill }
end

local function buildGui(): Refs
	local gui = Instance.new("ScreenGui")
	gui.Name = "CourierClashHud"
	gui.ResetOnSpawn = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling

	-- Score bar: [EMBER n] [phase / timer] [n TIDE]
	local bar = Instance.new("Frame")
	bar.Name = "ScoreBar"
	bar.AnchorPoint = Vector2.new(0.5, 0)
	bar.Position = UDim2.fromScale(0.5, 0.02)
	bar.Size = UDim2.fromScale(0.46, 0.085)
	bar.BackgroundTransparency = 1
	local barAspect = Instance.new("UIAspectRatioConstraint")
	barAspect.AspectRatio = 5.2
	barAspect.Parent = bar
	local barLayout = Instance.new("UIListLayout")
	barLayout.FillDirection = Enum.FillDirection.Horizontal
	barLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	barLayout.VerticalAlignment = Enum.VerticalAlignment.Center
	barLayout.Padding = UDim.new(0.015, 0)
	barLayout.SortOrder = Enum.SortOrder.LayoutOrder
	barLayout.Parent = bar
	bar.Parent = gui

	local scoreLabels: { [TeamId]: TextLabel } = {}
	local scoreScales: { [TeamId]: UIScale } = {}
	for index, team in Config.TEAM_IDS do
		local card = Instance.new("Frame")
		card.Name = team .. "Card"
		card.Size = UDim2.fromScale(0.3, 1)
		card.BackgroundColor3 = Config.TEAM_COLORS[team]
		card.LayoutOrder = if index == 1 then 1 else 3
		corner(card, 0.25)
		local cardScale = Instance.new("UIScale")
		cardScale.Parent = card
		scoreScales[team] = cardScale
		local label = textLabel(card, "Score", UDim2.fromScale(1, 1), 40)
		label.FontFace = FONT_HEAVY
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1.5
		stroke.Transparency = 0.4
		stroke.Parent = label
		card.Parent = bar
		scoreLabels[team] = label
	end

	local center = Instance.new("Frame")
	center.Name = "Center"
	center.Size = UDim2.fromScale(0.36, 1)
	center.BackgroundColor3 = PANEL_COLOR
	center.BackgroundTransparency = 0.15
	center.LayoutOrder = 2
	corner(center, 0.25)
	local phaseLabel = textLabel(center, "Phase", UDim2.fromScale(1, 0.4), 18)
	phaseLabel.Position = UDim2.fromScale(0, 0.08)
	local timerLabel = textLabel(center, "Timer", UDim2.fromScale(1, 0.5), 34)
	timerLabel.Position = UDim2.fromScale(0, 0.46)
	timerLabel.FontFace = FONT_HEAVY
	center.Parent = bar

	local statusLabel = textLabel(gui, "ParcelStatus", UDim2.fromScale(0.6, 0.04), 24)
	statusLabel.AnchorPoint = Vector2.new(0.5, 0)
	statusLabel.Position = UDim2.fromScale(0.5, 0.115)
	statusLabel.TextStrokeTransparency = 0.4

	-- Event banner (pickups, tackles, deliveries). CanvasGroup so the whole
	-- thing fades with one GroupTransparency tween.
	local banner = Instance.new("CanvasGroup")
	banner.Name = "Banner"
	banner.AnchorPoint = Vector2.new(0.5, 0.5)
	banner.Position = UDim2.fromScale(0.5, 0.3)
	banner.Size = UDim2.fromScale(0.5, 0.075)
	banner.BackgroundColor3 = PANEL_COLOR
	banner.BackgroundTransparency = 0.2
	banner.GroupTransparency = 1
	corner(banner, 0.3)
	local bannerScale = Instance.new("UIScale")
	bannerScale.Parent = banner
	local bannerLabel = textLabel(banner, "Text", UDim2.fromScale(0.94, 0.8), 32)
	bannerLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	bannerLabel.Position = UDim2.fromScale(0.5, 0.5)
	bannerLabel.FontFace = FONT_HEAVY
	banner.Parent = gui

	local teamTag = textLabel(gui, "TeamTag", UDim2.fromScale(0.22, 0.045), 22)
	teamTag.AnchorPoint = Vector2.new(0, 1)
	teamTag.Position = UDim2.fromScale(0.02, 0.97)
	teamTag.TextXAlignment = Enum.TextXAlignment.Left
	teamTag.TextStrokeTransparency = 0.4

	-- Action buttons, sized for thumbs. Tackle is always shown (keyboard F /
	-- gamepad R1 also work); Sprint and Slide only on touch devices, since
	-- keyboard and gamepad players hold Shift/L2 and press C/Ctrl/B.
	local tackle = roundButton(gui, "TackleButton", "TACKLE\n[F]", UDim2.fromScale(0.97, 0.7), 0.13)
	local shove = roundButton(gui, "ShoveButton", "SHOVE\n[E]", UDim2.fromScale(0.82, 0.62), 0.1)
	local isTouch = UserInputService.TouchEnabled
	local sprint = roundButton(gui, "SprintButton", "SPRINT", UDim2.fromScale(0.83, 0.86), 0.11)
	sprint.button.Visible = isTouch
	local slide = roundButton(gui, "SlideButton", "SLIDE", UDim2.fromScale(0.97, 0.9), 0.11)
	slide.button.Visible = isTouch

	-- Stamina bar, bottom center.
	local staminaBack = Instance.new("Frame")
	staminaBack.Name = "Stamina"
	staminaBack.AnchorPoint = Vector2.new(0.5, 1)
	staminaBack.Position = UDim2.fromScale(0.5, 0.965)
	staminaBack.Size = UDim2.fromScale(0.28, 0.018)
	staminaBack.BackgroundColor3 = PANEL_COLOR
	staminaBack.BackgroundTransparency = 0.25
	corner(staminaBack, 0.5)
	local staminaFill = Instance.new("Frame")
	staminaFill.Name = "Fill"
	staminaFill.Size = UDim2.fromScale(1, 1)
	staminaFill.BackgroundColor3 = STAMINA_COLOR
	staminaFill.BorderSizePixel = 0
	corner(staminaFill, 0.5)
	staminaFill.Parent = staminaBack
	staminaBack.Parent = gui

	-- Slide cooldown meter, just above the stamina bar: fills back up as
	-- the slide recharges.
	local slideBack = Instance.new("Frame")
	slideBack.Name = "SlideMeter"
	slideBack.AnchorPoint = Vector2.new(0.5, 1)
	slideBack.Position = UDim2.fromScale(0.5, 0.94)
	slideBack.Size = UDim2.fromScale(0.12, 0.012)
	slideBack.BackgroundColor3 = PANEL_COLOR
	slideBack.BackgroundTransparency = 0.25
	corner(slideBack, 0.5)
	local slideMeter = Instance.new("Frame")
	slideMeter.Name = "Fill"
	slideMeter.Size = UDim2.fromScale(1, 1)
	slideMeter.BackgroundColor3 = SLIDE_READY_COLOR
	slideMeter.BorderSizePixel = 0
	corner(slideMeter, 0.5)
	slideMeter.Parent = slideBack
	local slideCaption = textLabel(slideBack, "Caption", UDim2.fromScale(1, 1.8), 14)
	slideCaption.AnchorPoint = Vector2.new(0.5, 1)
	slideCaption.Position = UDim2.fromScale(0.5, -0.2)
	slideCaption.Text = "SLIDE / JUKE [C]"
	slideCaption.TextStrokeTransparency = 0.4
	slideBack.Parent = gui

	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	return {
		scoreLabels = scoreLabels,
		scoreScales = scoreScales,
		phaseLabel = phaseLabel,
		timerLabel = timerLabel,
		statusLabel = statusLabel,
		banner = banner,
		bannerLabel = bannerLabel,
		bannerScale = bannerScale,
		teamTag = teamTag,
		tackleButton = tackle.button,
		tackleScale = tackle.scale,
		cooldownFill = tackle.fill,
		shoveButton = shove.button,
		shoveScale = shove.scale,
		shoveFill = shove.fill,
		sprintButton = sprint.button,
		slideButton = slide.button,
		slideScale = slide.scale,
		slideFill = slide.fill,
		staminaFill = staminaFill,
		slideMeter = slideMeter,
	}
end

local function showBanner(text: string, color: Color3)
	bannerToken += 1
	local token = bannerToken
	if bannerFade then
		bannerFade:Cancel()
		bannerFade = nil
	end
	refs.bannerLabel.Text = text
	refs.bannerLabel.TextColor3 = color
	refs.banner.GroupTransparency = 0
	refs.bannerScale.Scale = 0.85
	pop(refs.bannerScale)
	task.delay(BANNER_SECONDS, function()
		if token ~= bannerToken then
			return
		end
		local fade = TweenService:Create(refs.banner, FADE, { GroupTransparency = 1 })
		bannerFade = fade
		fade:Play()
	end)
end

local function teamColor(team: TeamId?): Color3
	return if team then Config.TEAM_COLORS[team] else TEXT_COLOR
end

local function noticeText(notice: Types.Notice): string?
	local actor = notice.actorName or "Someone"
	if notice.kind == "Pickup" then
		return actor .. " grabbed the package!"
	elseif notice.kind == "Delivered" then
		return actor
			.. " delivered for "
			.. (if notice.team then teamName(notice.team) else "?")
			.. "! +1"
	elseif notice.kind == "Tackled" then
		return actor .. " tackled " .. (notice.targetName or "the carrier") .. "!"
	elseif notice.kind == "Dodged" then
		return actor .. " slid past " .. (notice.targetName or "a tackle") .. "!"
	elseif notice.kind == "Returned" then
		return "Package returned to its spot"
	elseif notice.kind == "RoundStart" then
		return "GO! First to " .. Config.SCORE_TO_WIN .. " deliveries"
	elseif notice.kind == "Go" then
		return "GO!"
	elseif notice.kind == "RoundEnd" then
		return if notice.team then teamName(notice.team) .. " WINS!" else "It's a draw!"
	end
	return nil
end

local function onNotice(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	local notice = payload :: Types.Notice
	local text = noticeText(notice)
	if text then
		local color = if notice.kind == "Returned" then PARCEL_COLOR else teamColor(notice.team)
		showBanner(text, color)
	end
end

local function formatTime(seconds: number): string
	local whole = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", whole // 60, whole % 60)
end

local function renderTimer()
	local current = state
	if not current then
		return
	end
	local now = Workspace:GetServerTimeNow()
	if current.lockedUntil > now then
		-- Round clock is paused during kickoff; show the frozen value.
		refs.timerLabel.Text = if current.phaseEndsAt > 0
			then formatTime(current.phaseEndsAt - current.lockedUntil)
			else formatTime(Config.ROUND_SECONDS)
		refs.statusLabel.Text = "Get ready! GO in " .. math.ceil(current.lockedUntil - now)
	elseif current.phaseEndsAt > 0 then
		refs.timerLabel.Text = formatTime(current.phaseEndsAt - now)
	else
		refs.timerLabel.Text = "--:--"
	end
end

local function statusText(current: Types.MatchState): string
	if current.phase == "Waiting" then
		return "Waiting for players..."
	elseif current.phase == "Lobby" then
		return "In the lobby. Next game starting soon"
	elseif current.phase == "Results" then
		return "Round over"
	end
	-- Most urgent first: you carrying, an enemy carrying, a teammate
	-- carrying, a loose package, then both on their pedestals.
	local team = myTeam()
	local enemy: Types.PackageView? = nil
	local friend: Types.PackageView? = nil
	local loose = false
	for _, package in current.packages do
		if package.status == "Carried" then
			if package.carrierUserId == localPlayer.UserId then
				return "You have a package! Run it to your drop zone!"
			elseif team and package.carrierTeam == team then
				friend = friend or package
			else
				enemy = enemy or package
			end
		elseif package.status == "Loose" then
			loose = true
		end
	end
	if enemy then
		return (enemy.carrierName or "Someone") .. " has a package. Tackle them!"
	elseif friend then
		return (friend.carrierName or "Someone") .. " has a package. Shove defenders away!"
	elseif loose then
		return "A package is loose! Grab it!"
	end
	return "Grab a package! One on the left, one on the right"
end

-- Color for the status line: the team of whoever the line is about.
local function statusColor(current: Types.MatchState): Color3
	for _, package in current.packages do
		if package.status == "Carried" and package.carrierUserId == localPlayer.UserId then
			return teamColor(package.carrierTeam)
		end
	end
	local team = myTeam()
	local friendTeam: TeamId? = nil
	for _, package in current.packages do
		if package.status == "Carried" then
			if package.carrierTeam ~= team then
				return teamColor(package.carrierTeam)
			end
			friendTeam = package.carrierTeam
		end
	end
	return if friendTeam then teamColor(friendTeam) else PARCEL_COLOR
end

local PHASE_TITLES: { [Types.Phase]: string } = {
	Waiting = "WAITING",
	Lobby = "LOBBY",
	Playing = "DELIVER!",
	Results = "RESULTS",
}

local function renderTeamTag()
	local team = myTeam()
	if team then
		refs.teamTag.Text = "You're on " .. teamName(team)
		refs.teamTag.TextColor3 = Config.TEAM_COLORS[team]
	else
		refs.teamTag.Text = ""
	end
end

local function render()
	local current = state
	if not current then
		return
	end
	for team, label in refs.scoreLabels do
		local text = tostring(MatchLogic.scoreOf(current.scores, team))
		if label.Text ~= text then
			label.Text = text
			pop(refs.scoreScales[team])
		end
	end
	refs.phaseLabel.Text = PHASE_TITLES[current.phase]
	refs.statusLabel.Text = statusText(current)
	refs.statusLabel.TextColor3 = statusColor(current)
	renderTimer()
end

local function onState(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	state = payload :: Types.MatchState
	render()
end

-- Drain a button's cooldown fill over `seconds`; returns the live tween.
local function drainFill(fill: Frame, seconds: number, previous: Tween?): Tween?
	if previous then
		previous:Cancel()
	end
	fill.Size = UDim2.fromScale(1, if seconds > 0 then 1 else 0)
	if seconds <= 0 then
		return nil
	end
	local tween = TweenService:Create(
		fill,
		TweenInfo.new(seconds, Enum.EasingStyle.Linear),
		{ Size = UDim2.fromScale(1, 0) }
	)
	tween:Play()
	return tween
end

local function onCooldown(seconds: number)
	cooldownTween = drainFill(refs.cooldownFill, seconds, cooldownTween)
end

local function onShoveCooldown(seconds: number)
	shoveTween = drainFill(refs.shoveFill, seconds, shoveTween)
end

local function onSlideCooldown(seconds: number)
	pop(refs.slideScale)
	slideCooldownTween = drainFill(refs.slideFill, seconds, slideCooldownTween)
	if slideMeterTween then
		slideMeterTween:Cancel()
	end
	local meter = refs.slideMeter
	meter.Size = UDim2.fromScale(0, 1)
	meter.BackgroundColor3 = SLIDE_CHARGING_COLOR
	local tween = TweenService:Create(
		meter,
		TweenInfo.new(seconds, Enum.EasingStyle.Linear),
		{ Size = UDim2.fromScale(1, 1) }
	)
	tween.Completed:Once(function(playback)
		if playback == Enum.PlaybackState.Completed then
			meter.BackgroundColor3 = SLIDE_READY_COLOR
		end
	end)
	slideMeterTween = tween
	tween:Play()
end

local function renderStamina()
	local value = localPlayer:GetAttribute("Stamina")
	local maxValue = localPlayer:GetAttribute("StaminaMax")
	local maximum = if typeof(maxValue) == "number" and maxValue > 0
		then maxValue
		else Config.STAMINA_MAX
	local fraction = if typeof(value) == "number" then math.clamp(value / maximum, 0, 1) else 1
	if staminaTween then
		staminaTween:Cancel()
	end
	local tween = TweenService:Create(refs.staminaFill, STAMINA_TWEEN, {
		Size = UDim2.fromScale(fraction, 1),
		BackgroundColor3 = if fraction < 0.25 then STAMINA_LOW_COLOR else STAMINA_COLOR,
	})
	staminaTween = tween
	tween:Play()
end

local function renderSprintButton(held: boolean)
	refs.sprintButton.BackgroundColor3 = if held then STAMINA_COLOR else PANEL_COLOR
end

function HudController.init()
	refs = buildGui()
	Net.on("State", onState)
	Net.on("Notice", onNotice)
	TackleController.CooldownChanged.connect(onCooldown)
	refs.tackleButton.Activated:Connect(function()
		pop(refs.tackleScale)
		TackleController.request()
	end)
	ShoveController.CooldownChanged.connect(onShoveCooldown)
	refs.shoveButton.Activated:Connect(function()
		pop(refs.shoveScale)
		ShoveController.request()
	end)
	localPlayer:GetPropertyChangedSignal("Team"):Connect(renderTeamTag)

	MovementController.SlideStarted.connect(onSlideCooldown)
	MovementController.SprintChanged.connect(renderSprintButton)
	-- Touch: Sprint toggles (holding a button while steering is awkward).
	refs.sprintButton.Activated:Connect(function()
		MovementController.setSprint(not MovementController.isSprintHeld())
	end)
	refs.slideButton.Activated:Connect(function()
		MovementController.slide()
	end)
	localPlayer:GetAttributeChangedSignal("Stamina"):Connect(renderStamina)
	localPlayer:GetAttributeChangedSignal("StaminaMax"):Connect(renderStamina)
end

function HudController.start()
	renderTeamTag()
	renderStamina()
	-- Late join: ask for a full snapshot instead of waiting for the next change.
	Net.fire("RequestState")
	while true do
		renderTimer()
		task.wait(0.2)
	end
end

return HudController
