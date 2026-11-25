-- Addon messages within the group: one prefix, a send queue (the server throttles), messages split
-- into parts when they are longer than one addon message, and a pause while the game blocks
-- addon messages (boss encounters and the like).
local ADDON, ns = ...
local U = ns.Util

local Comm = {}
ns.Comm = Comm

local PREFIX = "GoblinCasino"
local PART = 240        -- payload bytes per addon message (limit is 255)
local INTERVAL = 0.25   -- seconds between sends

local queue = {}
local handlers = {}     -- [type letter] = function(fields, sender)
local buffers = {}      -- [sender] = text of a message still arriving in parts

-- True while the game blocks addon messages (same checks as ForeverTCG).
function Comm.Restricted()
	if not (C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive and Enum.AddOnRestrictionType) then
		return false
	end
	-- each check on its own: one the client doesn't support must not block sending for good
	for _, key in ipairs({ "Chat", "Encounter", "ChallengeMode", "PvPMatch", "Combat" }) do
		local t = Enum.AddOnRestrictionType[key]
		if t ~= nil then
			local ok, active = pcall(C_RestrictedActions.IsAddOnRestrictionActive, t)
			if ok and active then return true end
		end
	end
	return false
end

function Comm.Channel()
	local instance = LE_PARTY_CATEGORY_INSTANCE
	if IsInRaid() then
		return (instance and IsInRaid(instance) and not IsInRaid(LE_PARTY_CATEGORY_HOME)) and "INSTANCE_CHAT" or "RAID"
	elseif IsInGroup() then
		return (instance and IsInGroup(instance) and not IsInGroup(LE_PARTY_CATEGORY_HOME)) and "INSTANCE_CHAT" or "PARTY"
	end
end

function Comm.Pending()
	return #queue
end

-- Functions waiting for everything queued so far to go out.
local flushed = {}
local function RunFlushed()
	local list = flushed
	flushed = {}
	for _, fn in ipairs(list) do
		local ok, err = pcall(fn)
		if not ok then ns.Log.Error("after send", err) end
	end
end

-- Call fn once every message queued until now has been sent (right away when nothing waits).
function Comm.Flushed(fn)
	if #queue == 0 then fn() else flushed[#flushed + 1] = fn end
end

local function ResultName(R, res)
	for k, v in pairs(R) do
		if v == res then return k end
	end
	return tostring(res)
end

local ticker
local function Pump()
	if #queue == 0 then
		if ticker then ticker:Cancel(); ticker = nil end
		RunFlushed()
		return
	end
	if Comm.Restricted() then return end -- try again on the next tick
	local channel = Comm.Channel()
	if not channel then
		ns.Log.Add("comm", "not in a group any more, %d message(s) dropped", #queue)
		wipe(queue)
		RunFlushed()
		return
	end
	local msg = table.remove(queue, 1)
	local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, channel)
	if not ok then ns.Log.Error("SendAddonMessage", res) end
	local R = Enum.SendAddonMessageResult
	if ok and R and res ~= nil and res ~= true and res ~= R.Success then
		local lockdown = R.AddOnMessageLockdown or R.AddonMessageLockdown
		if res == R.AddonMessageThrottle or res == R.ChannelThrottle or (lockdown and res == lockdown) then
			-- "too fast" or blocked for now: keep the message and try again on the next tick
			table.insert(queue, 1, msg)
			ns.Log.Add("comm", "not sent yet (%s), retrying", ResultName(R, res))
		else
			ns.Log.Add("ERROR", "message not sent (%s): %s", ResultName(R, res), msg)
		end
	end
	if #queue == 0 then RunFlushed() end
end

-- Send fields joined with "^" to the whole group ("|" starts WoW's escape codes, so not that).
-- Long messages go out in parts: "=" whole message, "<" first part, "~" middle part, ">" last part.
-- The first part starts with the full length ("<412:..."), so a message missing a part is dropped
-- instead of being read wrong.
function Comm.Send(...)
	local text = table.concat({ ... }, "^")
	ns.Log.Add("comm", "send %s (%d bytes)%s", text, #text, Comm.Restricted() and " - queued, messages blocked" or "")
	if #text <= PART then
		queue[#queue + 1] = "=" .. text
	else
		local pos, first = 1, true
		while pos <= #text do
			local chunk = text:sub(pos, pos + PART - 1)
			pos = pos + PART
			local mark = first and ("<" .. #text .. ":") or (pos > #text and ">" or "~")
			queue[#queue + 1] = mark .. chunk
			first = false
		end
	end
	if not ticker then
		ticker = C_Timer.NewTicker(INTERVAL, Pump)
		Pump()
	end
end

-- Register a handler for a message type (its first field).
function Comm.On(kind, fn)
	handlers[kind] = fn
end

local function Dispatch(text, sender)
	local fields = { strsplit("^", text) }
	local fn = handlers[fields[1]]
	if fn then
		local ok, err = pcall(fn, fields, sender)
		if not ok then
			ns.Log.Error("handler " .. tostring(fields[1]), err)
			geterrorhandler()(err)
		end
	end
end

local GROUP_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }

local function OnAddonMessage(prefix, text, channel, sender)
	if prefix ~= PREFIX then return end
	if not GROUP_CHANNELS[channel] then
		ns.Log.Add("comm", "ignored %s from %s on %s (not a group channel)", text, sender, channel)
		return
	end
	local key = U.Canonical(sender)
	if key and key == U.Me() then
		-- our own message coming back (already applied locally); logged with the raw sender name,
		-- which shows how the server names this player
		ns.Log.Add("comm", "echo %s (own message, sender %s)", text, sender)
		return
	end
	ns.Log.Add("comm", "recv %s from %s%s on %s", text, sender, key ~= sender and (" (as " .. tostring(key) .. ")") or "", channel)
	sender = key
	if not sender then return end
	local mark, body = text:sub(1, 1), text:sub(2)
	if mark == "=" then
		buffers[sender] = nil
		Dispatch(body, sender)
	elseif mark == "<" then
		local len, first = body:match("^(%d+):(.*)$")
		buffers[sender] = len and { len = tonumber(len), text = first } or nil
	elseif mark == "~" and buffers[sender] then
		buffers[sender].text = buffers[sender].text .. body
	elseif mark == ">" and buffers[sender] then
		local buf = buffers[sender]
		buffers[sender] = nil
		local whole = buf.text .. body
		if #whole == buf.len then
			Dispatch(whole, sender)
		elseif ns.Debug then
			ns.Debug("dropped a message from %s: a part went missing (%d of %d bytes)", sender, #whole, buf.len)
		end
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("PLAYER_LOGIN")
events:RegisterEvent("CHAT_MSG_ADDON")
events:SetScript("OnEvent", function(_, event, ...)
	if event == "PLAYER_LOGIN" then
		if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
			C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
		end
	else
		-- values can be "secret" inside instances; never let that break the handler
		local args = { ... }
		pcall(OnAddonMessage, args[1], args[2], args[3], args[4])
	end
end)
