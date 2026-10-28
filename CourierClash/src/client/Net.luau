--!strict
-- Client side of the remote API. Waits for the server-created remotes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Remotes = require(ReplicatedStorage.Shared.Remotes)

type RemoteName = Remotes.RemoteName

local Net = {}

local folder = ReplicatedStorage:WaitForChild(Remotes.FOLDER_NAME)

local function remote(name: RemoteName): RemoteEvent
	return folder:WaitForChild(name) :: RemoteEvent
end

function Net.on(name: RemoteName, handler: (...any) -> ()): RBXScriptConnection
	return remote(name).OnClientEvent:Connect(handler)
end

function Net.fire(name: RemoteName, ...: any)
	remote(name):FireServer(...)
end

return Net
