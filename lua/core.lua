-- Lobby Recreate
-- Leaves the current lobby, hosts a new one with the same heist and settings,
-- then sends a lobby invite to everyone who was in the old one.
-- Works as host or as client (as client, you become the host of the new lobby).
-- Nobody else needs the mod; they just accept the invite.

LobbyRecreate = LobbyRecreate or {
	roster = {}, -- [user_id] = { user_id = ..., name = ..., lobby = lobby id string }, players seen per lobby
	state = nil -- nil | "leaving" | "creating" | "inviting"
}

local LR = LobbyRecreate
local TAG = "[Lobby Recreate] "
local LEAVE_DELAY = 1 -- lets the "recreating" chat message go out before we leave
local LEAVE_TIMEOUT = 8 -- a stuck peer can stop the old session from closing, force it after this
local CREATE_TIMEOUT = 20
local INVITE_DELAY = 1.5 -- lets Steam publish the new lobby before invites go out

function LR:log(msg)
	log(TAG .. tostring(msg))
end

function LR:say(msg)
	if managers.chat then
		managers.chat:feed_system_message(ChatManager.GAME, TAG .. msg)
	end
end

function LR:popup(msg)
	QuickMenu:new("Lobby Recreate", msg, {}, true)
end

function LR:_fail(msg)
	self:log("FAILED: " .. tostring(msg))
	self.state = nil
	DelayedCalls:Remove("LobbyRecreate_create_timeout")
	self:popup(msg)
end

function LR:_can_recreate()
	if self.state then
		return false, "Already recreating the lobby, hang on a sec."
	end

	if not game_state_machine or game_state_machine:current_state_name() ~= "menu_main" then
		return false, "This only works in the lobby before the heist starts (not in a heist or between days)."
	end

	local session = managers.network and managers.network:session()

	if not session or Global.game_settings.single_player then
		return false, "You need to be in an online lobby."
	end

	if not managers.network.matchmake.lobby_handler then
		return false, "Couldn't find the Steam lobby."
	end

	if managers.crime_spree and managers.crime_spree:is_active() then
		return false, "Crime Spree lobbies aren't supported."
	end

	if managers.skirmish and managers.skirmish:is_skirmish() then
		return false, "Holdout lobbies aren't supported."
	end

	return true
end

function LR:_current_lobby_id()
	local handler = managers.network and managers.network.matchmake and managers.network.matchmake.lobby_handler

	return handler and tostring(handler:id())
end

-- Everyone currently connected (the host included, when you're a client), plus
-- anyone who dropped from a connection problem while in this lobby.
-- Kicked players are left out.
function LR:_collect_invites()
	local session = managers.network:session()
	local my_id = session:local_peer() and tostring(session:local_peer():user_id())
	local lobby_id = self:_current_lobby_id()
	local list, seen = {}, {}

	local function add(user_id, name)
		if not user_id or user_id == "" then
			return
		end

		local key = tostring(user_id)

		if seen[key] or key == my_id or session:is_kicked(key) then
			return
		end

		seen[key] = true
		table.insert(list, { user_id = user_id, name = name or key })
	end

	for _, peer in pairs(session:peers()) do
		add(peer:user_id(), peer:name())
	end

	for _, entry in pairs(self.roster) do
		if entry.lobby == lobby_id then
			add(entry.user_id, entry.name)
		end
	end

	return list
end

-- As a client, Global.game_settings holds your own hosting preferences, not the
-- host's. The host's settings are published in the Steam lobby data.
function LR:_read_host_settings()
	local data = managers.network.matchmake:get_lobby_data()

	if not data then
		return nil
	end

	local permission = tweak_data:index_to_permission(tonumber(data.permission))

	return {
		permission = permission,
		drop_in_option = tonumber(data.drop_in),
		kick_option = tonumber(data.kick_option),
		job_plan = tonumber(data.job_plan)
	}
end

function LR:_apply_host_settings(settings)
	if not settings then
		return
	end

	for key, value in pairs(settings) do
		Global.game_settings[key] = value
	end
end

function LR:_host_name()
	local session = managers.network:session()
	local host = session and session:server_peer()

	return host and host:name() or "the host"
end

function LR:request()
	local ok, reason = self:_can_recreate()

	if not ok then
		self:popup(reason)

		return
	end

	local is_host = managers.network:session():is_host()
	local list = self:_collect_invites()
	local text

	if is_host then
		text = "Close this lobby and open a fresh one with the same heist and settings?"
	else
		text = "Leave " .. self:_host_name() .. "'s lobby and host a fresh one with the same heist and settings? You will be the host of the new lobby."
	end

	if #list > 0 then
		local names = {}

		for _, p in ipairs(list) do
			table.insert(names, "- " .. p.name)
		end

		text = text .. "\n\nThese players will get an invite:\n" .. table.concat(names, "\n")

		if is_host then
			text = text .. "\n\nThey'll see \"host left\" for a moment, then the invite shows up."
		else
			text = text .. "\n\nThey stay in the old lobby until they accept."
		end
	else
		text = text .. "\n\nNobody to invite right now."
	end

	QuickMenu:new("Recreate lobby?", text, {
		{
			text = "Recreate",
			callback = function()
				LR:_start(list)
			end
		},
		{
			text = "Cancel",
			is_cancel_button = true
		}
	}, true)
end

function LR:_start(list)
	local ok, reason = self:_can_recreate()

	if not ok then
		self:popup(reason)

		return
	end

	local is_host = managers.network:session():is_host()

	self.state = "leaving"
	self._invites = list
	-- Job, difficulty and One Down are synced to clients by the host, so these
	-- are correct in both roles
	self._job = {
		job_id = managers.job:current_job_id(),
		difficulty = Global.game_settings.difficulty,
		one_down = Global.game_settings.one_down
	}
	self._host_settings = not is_host and self:_read_host_settings() or nil

	self:log("Recreating lobby as " .. (is_host and "host" or "client") .. ", job=" .. tostring(self._job.job_id) .. ", invites=" .. #list)

	-- Plain chat message, so players without the mod know what's happening
	local announcement = is_host and "Recreating the lobby to fix connection issues, accept my invite in a few seconds!" or "Making a new lobby to fix connection issues, I'll host it. Accept my invite in a few seconds!"

	pcall(function()
		managers.chat:send_message(ChatManager.GAME, nil, announcement)
	end)

	DelayedCalls:Add("LobbyRecreate_leave", LEAVE_DELAY, function()
		LR:_leave()
	end)
end

function LR:_leave()
	if not game_state_machine or game_state_machine:current_state_name() ~= "menu_main" or not managers.network:session() then
		self.state = nil
		self:log("Lobby changed before we could leave, cancelled")

		return
	end

	local ok, err = pcall(function()
		MenuCallbackHandler:_dialog_leave_lobby_yes()
	end)

	if not ok then
		self:_fail("Couldn't leave the lobby: " .. tostring(err))

		return
	end

	self._t_leave = Application:time()
	self._forced_stop = false

	self:_wait_for_network_stop()
end

function LR:_wait_for_network_stop()
	if not managers.network:session() then
		DelayedCalls:Add("LobbyRecreate_create", 0.5, function()
			LR:_create()
		end)

		return
	end

	local waited = Application:time() - self._t_leave

	if waited > LEAVE_TIMEOUT and not self._forced_stop then
		self:log("Old session didn't close by itself, forcing it")

		self._forced_stop = true

		pcall(function()
			managers.network:stop_network(true)
		end)
	elseif waited > LEAVE_TIMEOUT * 2 then
		self:_fail("The old lobby wouldn't close. Restart the game if things look broken, then host again.")

		return
	end

	DelayedCalls:Add("LobbyRecreate_wait", 0.25, function()
		LR:_wait_for_network_stop()
	end)
end

function LR:_create()
	self.state = "creating"

	local job = self._job
	local ok, err = pcall(function()
		-- Coming from someone else's lobby: host with their settings, not yours
		self:_apply_host_settings(self._host_settings)

		if job.job_id then
			MenuCallbackHandler:start_job({
				job_id = job.job_id,
				difficulty = job.difficulty,
				one_down = job.one_down
			})
		else
			-- The old lobby had no contract (empty lobby mod), host an empty one again
			Global.game_settings.level_id = Global.game_settings.level_id or "family"

			MenuCallbackHandler:create_lobby()
		end
	end)

	if not ok then
		self:_fail("Couldn't create the new lobby: " .. tostring(err) .. "\n\nPick the heist from Crime.net again and invite people manually.")

		return
	end

	DelayedCalls:Add("LobbyRecreate_create_timeout", CREATE_TIMEOUT, function()
		if LR.state == "creating" then
			LR:_fail("The new lobby wasn't created in time. Pick the heist from Crime.net again and invite people manually.")
		end
	end)
end

function LR:_on_new_lobby()
	self.state = "inviting"

	DelayedCalls:Remove("LobbyRecreate_create_timeout")
	DelayedCalls:Add("LobbyRecreate_invite", INVITE_DELAY, function()
		LR:_send_invites()
	end)
end

-- Same lookup the game's Social Hub uses when you press "Invite"
function LR:_invite(user_id, lobby_id)
	local user

	if managers.socialhub and managers.socialhub:is_user_platform_friend(user_id) then
		user = Distribution:user_from_id(user_id)
	elseif DistributionMatchmaking and DistributionMatchmaking.user_from_id then
		user = DistributionMatchmaking:user_from_id(user_id)
	end

	user = user or Steam:user(user_id)

	if not user then
		error("unknown user")
	end

	user:invite(lobby_id)
end

function LR:_send_invites()
	local handler = managers.network.matchmake.lobby_handler
	local lobby_id = handler and handler:id()

	if not lobby_id then
		self:_fail("The new lobby is gone, couldn't send invites.")

		return
	end

	local sent, failed = {}, {}

	for _, p in ipairs(self._invites or {}) do
		local ok, err = pcall(function()
			LR:_invite(p.user_id, lobby_id)
		end)

		if ok then
			table.insert(sent, p.name)
		else
			self:log("Invite to " .. tostring(p.name) .. " failed: " .. tostring(err))
			table.insert(failed, p.name)
		end

		-- Keep them in the roster so pressing the key again re-invites them too
		self.roster[tostring(p.user_id)] = { user_id = p.user_id, name = p.name, lobby = tostring(lobby_id) }
	end

	self.state = nil
	self._invites = nil
	self._host_settings = nil

	if #sent > 0 then
		self:say("New lobby is up. Invited: " .. table.concat(sent, ", "))
	else
		self:say("New lobby is up.")
	end

	if #failed > 0 then
		self:say("Couldn't invite: " .. table.concat(failed, ", ") .. ". Opening the Steam invite window.")
		managers.network.matchmake:invite_friends_to_lobby()
	end
end

if RequiredScript == "lib/managers/menumanager" then
	Hooks:PostHook(MenuManager, "created_lobby", "LobbyRecreate_created_lobby", function(self)
		if LR.state == "creating" then
			LR:_on_new_lobby()
		else
			-- A lobby you hosted normally, start a fresh roster
			LR.roster = {}
		end
	end)
elseif RequiredScript == "lib/network/base/basenetworksession" then
	-- Roster is tracked as host and as client. Entries are tagged with the lobby
	-- they were seen in, so joining another lobby doesn't carry old players over.
	Hooks:PostHook(BaseNetworkSession, "add_peer", "LobbyRecreate_add_peer", function(self, name, rpc, in_lobby, loading, synched, id, character, user_id)
		local lobby_id = LR:_current_lobby_id()

		if LR.state or not user_id or not lobby_id then
			return
		end

		LR.roster[tostring(user_id)] = { user_id = user_id, name = name, lobby = lobby_id }
	end)

	Hooks:PostHook(BaseNetworkSession, "remove_peer", "LobbyRecreate_remove_peer", function(self, peer, peer_id, reason)
		-- "lost" (connection dropped) stays on the roster, a normal leave doesn't
		if LR.state or not peer or reason ~= "left" then
			return
		end

		LR.roster[tostring(peer:user_id())] = nil
	end)

	Hooks:PostHook(BaseNetworkSession, "on_peer_kicked", "LobbyRecreate_on_peer_kicked", function(self, peer)
		if peer then
			LR.roster[tostring(peer:user_id())] = nil
		end
	end)
end
