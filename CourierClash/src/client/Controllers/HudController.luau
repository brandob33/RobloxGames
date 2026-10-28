--!strict
-- HUD: score bar + timer, parcel status, event banner, team tag and the
-- tackle button. Renders server snapshots only; computes nothing that
-- matters. Layout is built in code with Scale sizes so it fits phones.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Types = require(ReplicatedStorage.Shared.Types)
local MatchLogic = require(ReplicatedStorage.Shared.Util.MatchLogic)
local Net = require(script.Parent.Parent.Net)
local TackleController = require(script.Parent.TackleController)

type TeamId = Types.TeamId

local HudController = {}

local localPlayer = Players.LocalPlayer

local FONT_BOLD = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Bold)
local FONT_HEAVY = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Heavy)
local PANEL_COLOR = Color3.fromRGB(24, 26, 36)
local TEXT_COLOR = Color3.fromRGB(245, 245, 245)
local PARCEL_COLOR = Color3.fromRGB(240, 196, 64)

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
}
local refs: Refs

local bannerToken = 0
local bannerFade: Tween? = nil
local cooldownTween: Tween? = nil

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

	-- Tackle button, sized for thumbs; keyboard F / gamepad R1 also work.
	local tackleButton = Instance.new("TextButton")
	tackleButton.Name = "TackleButton"
	tackleButton.AnchorPoint = Vector2.new(1, 1)
	tackleButton.Position = UDim2.fromScale(0.97, 0.7)
	tackleButton.Size = UDim2.fromScale(0.13, 0.13)
	tackleButton.BackgroundColor3 = PANEL_COLOR
	tackleButton.BackgroundTransparency = 0.15
	tackleButton.AutoButtonColor = true
	tackleButton.Text = ""
	tackleButton.ClipsDescendants = true
	corner(tackleButton, 0.5)
	local tackleAspect = Instance.new("UIAspectRatioConstraint")
	tackleAspect.AspectRatio = 1
	tackleAspect.Parent = tackleButton
	local tackleScale = Instance.new("UIScale")
	tackleScale.Parent = tackleButton
	local cooldownFill = Instance.new("Frame")
	cooldownFill.Name = "Cooldown"
	cooldownFill.AnchorPoint = Vector2.new(0, 1)
	cooldownFill.Position = UDim2.fromScale(0, 1)
	cooldownFill.Size = UDim2.fromScale(1, 0)
	cooldownFill.BackgroundColor3 = Color3.new(0, 0, 0)
	cooldownFill.BackgroundTransparency = 0.45
	cooldownFill.BorderSizePixel = 0
	cooldownFill.Parent = tackleButton
	local tackleLabel = textLabel(tackleButton, "Label", UDim2.fromScale(0.86, 0.5), 22)
	tackleLabel.AnchorPoint = Vector2.new(0.5, 0.5)
	tackleLabel.Position = UDim2.fromScale(0.5, 0.5)
	tackleLabel.Text = "TACKLE\n[F]"
	tackleLabel.FontFace = FONT_HEAVY
	tackleLabel.ZIndex = 2
	tackleButton.Parent = gui

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
		tackleButton = tackleButton,
		tackleScale = tackleScale,
		cooldownFill = cooldownFill,
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
		return actor .. " grabbed the parcel!"
	elseif notice.kind == "Delivered" then
		return actor
			.. " delivered for "
			.. (if notice.team then teamName(notice.team) else "?")
			.. "! +1"
	elseif notice.kind == "Tackled" then
		return actor .. " tackled " .. (notice.targetName or "the carrier") .. "!"
	elseif notice.kind == "Returned" then
		return "Parcel returned to center"
	elseif notice.kind == "RoundStart" then
		return "GO! First to " .. Config.SCORE_TO_WIN .. " deliveries"
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
	if current.phaseEndsAt > 0 then
		refs.timerLabel.Text = formatTime(current.phaseEndsAt - Workspace:GetServerTimeNow())
	else
		refs.timerLabel.Text = "--:--"
	end
end

local function statusText(current: Types.MatchState): string
	if current.phase == "Waiting" then
		return "Waiting for players..."
	elseif current.phase == "Intermission" then
		return "Next round starting soon"
	elseif current.phase == "Results" then
		return "Round over"
	end
	if current.parcelStatus == "Carried" then
		if current.carrierUserId == localPlayer.UserId then
			return "You have the parcel! Run it to your drop zone!"
		end
		local who = current.carrierName or "Someone"
		if current.carrierTeam and current.carrierTeam == myTeam() then
			return who .. " has the parcel. Protect them!"
		end
		return who .. " has the parcel. Tackle them!"
	elseif current.parcelStatus == "Loose" then
		return "The parcel is loose! Grab it!"
	end
	return "Grab the parcel at the center!"
end

local PHASE_TITLES: { [Types.Phase]: string } = {
	Waiting = "WAITING",
	Intermission = "NEXT ROUND",
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
	refs.statusLabel.TextColor3 = if current.parcelStatus == "Carried"
		then teamColor(current.carrierTeam)
		else PARCEL_COLOR
	renderTimer()
end

local function onState(payload: unknown)
	if typeof(payload) ~= "table" then
		return
	end
	state = payload :: Types.MatchState
	render()
end

local function onCooldown(seconds: number)
	if cooldownTween then
		cooldownTween:Cancel()
	end
	refs.cooldownFill.Size = UDim2.fromScale(1, if seconds > 0 then 1 else 0)
	if seconds > 0 then
		local tween = TweenService:Create(
			refs.cooldownFill,
			TweenInfo.new(seconds, Enum.EasingStyle.Linear),
			{ Size = UDim2.fromScale(1, 0) }
		)
		cooldownTween = tween
		tween:Play()
	end
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
	localPlayer:GetPropertyChangedSignal("Team"):Connect(renderTeamTag)
end

function HudController.start()
	renderTeamTag()
	-- Late join: ask for a full snapshot instead of waiting for the next change.
	Net.fire("RequestState")
	while true do
		renderTimer()
		task.wait(0.2)
	end
end

return HudController
