--!strict
-- Server side of the remote API. Creates every remote from the shared list
-- when first required, so remotes exist before any system connects to them.
-- Handlers receive raw client arguments as `unknown`: validate before use.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

type RemoteName = Remotes.RemoteName

local Net = {}

local remotes: { [string]: RemoteEvent } = {}

local folder = Instance.new("Folder")
folder.Name = Remotes.FOLDER_NAME
for _, name in Remotes.NAMES do
	local remote = Instance.new("RemoteEvent")
	remote.Name = name
	remote.Parent = folder
	remotes[name] = remote
end
folder.Parent = ReplicatedStorage

function Net.on(name: RemoteName, handler: (player: Player, ...unknown) -> ()): RBXScriptConnection
	return remotes[name].OnServerEvent:Connect(handler)
end

function Net.fire(player: Player, name: RemoteName, ...: any)
	remotes[name]:FireClient(player, ...)
end

function Net.fireAll(name: RemoteName, ...: any)
	remotes[name]:FireAllClients(...)
end

return Net
