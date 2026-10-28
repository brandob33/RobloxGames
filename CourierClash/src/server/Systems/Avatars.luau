--!strict
-- Same body for everyone: the default blocky R15 body at standard scale,
-- with default animations. Players keep their own head, face, skin colour,
-- clothes and accessories. Equal bodies mean equal hitboxes for tackles,
-- and the slide/dive poses (PoseController) look right on every avatar.
--
-- The avatar type itself (R15) is a place setting: Game Settings → Avatar.

local Players = game:GetService("Players")

local Avatars = {}

local function standardize(description: HumanoidDescription)
	-- 0 = the default blocky part.
	description.Torso = 0
	description.LeftArm = 0
	description.RightArm = 0
	description.LeftLeg = 0
	description.RightLeg = 0
	description.HeightScale = 1
	description.WidthScale = 1
	description.DepthScale = 1
	description.HeadScale = 1
	description.BodyTypeScale = 0
	description.ProportionScale = 0
	-- Default animations, so nobody's run or idle looks different.
	description.ClimbAnimation = 0
	description.FallAnimation = 0
	description.IdleAnimation = 0
	description.JumpAnimation = 0
	description.RunAnimation = 0
	description.SwimAnimation = 0
	description.WalkAnimation = 0
	description.MoodAnimation = 0
end

local function onCharacterAppearanceLoaded(player: Player, character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.RigType ~= Enum.HumanoidRigType.R15 then
		return
	end
	local ok, err = pcall(function()
		local description = humanoid:GetAppliedDescription()
		standardize(description)
		humanoid:ApplyDescription(description)
	end)
	if not ok then
		warn(`[Avatars] couldn't standardize {player.Name}: {err}`)
	end
end

local function onPlayerAdded(player: Player)
	player.CharacterAppearanceLoaded:Connect(function(character)
		onCharacterAppearanceLoaded(player, character)
	end)
	local character = player.Character
	if character and player:HasAppearanceLoaded() then
		task.spawn(onCharacterAppearanceLoaded, player, character)
	end
end

function Avatars.init()
	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, player in Players:GetPlayers() do
		onPlayerAdded(player)
	end
end

return Avatars
