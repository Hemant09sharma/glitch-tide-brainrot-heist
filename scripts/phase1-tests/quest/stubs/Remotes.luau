-- Minimal Remotes stub for the quest tests. Mirrors the real
-- Remotes.luau surface QuestService touches: Names, GetRemote,
-- GetFunction. RemoteEvents record FireClient calls and capture
-- OnServerEvent handlers in the shared state module; RemoteFunctions
-- accept OnServerInvoke assignment.
local state = require("./state")

local remotesByName = {}

local function makeRemoteEvent(name)
	local remote = {}
	remote.Name = name
	function remote:IsA(className)
		return className == "RemoteEvent"
	end
	function remote:FireClient(player, payload)
		table.insert(state.fires, { remote = name, player = player, payload = payload })
	end
	remote.OnServerEvent = {
		Connect = function(_self, fn)
			state.handlers[name] = fn
			return {
				Disconnect = function() end,
			}
		end,
	}
	return remote
end

local function makeRemoteFunction(name)
	local fn = {}
	fn.Name = name
	function fn:IsA(className)
		return className == "RemoteFunction"
	end
	fn.OnServerInvoke = nil
	return fn
end

return {
	Names = {
		ClaimQuest = "ClaimQuest",
		QuestUpdate = "QuestUpdate",
		PlayerStats = "PlayerStats",
		RequestQuests = "RequestQuests",
		CollectIncome = "CollectIncome",
	},
	GetRemote = function(name)
		if remotesByName[name] == nil then
			remotesByName[name] = makeRemoteEvent(name)
		end
		return remotesByName[name]
	end,
	GetFunction = function(name)
		if remotesByName[name] == nil then
			remotesByName[name] = makeRemoteFunction(name)
		end
		return remotesByName[name]
	end,
}
