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

local ticker
local function Pump()
	if #queue == 0 then
		if ticker then ticker:Cancel(); ticker = nil end
		return
	end
	if Comm.Restricted() then return end -- try again on the next tick
	local channel = Comm.Channel()
	if not channel then wipe(queue); return end
	local msg = table.remove(queue, 1)
	local ok, res = pcall(C_ChatInfo.SendAddonMessage, PREFIX, msg, channel)
	-- the server said "too fast": keep the message and try again on the next tick
	local R = Enum.SendAddonMessageResult
	if ok and R and (res == R.AddonMessageThrottle or res == R.ChannelThrottle) then
		table.insert(queue, 1, msg)
	end
end

-- Send fields joined with "^" to the whole group ("|" starts WoW's escape codes, so not that).
-- Long messages go out in parts: "=" whole message, "<" first part, "~" middle part, ">" last part.
-- The first part starts with the full length ("<412:..."), so a message missing a part is dropped
-- instead of being read wrong.
function Comm.Send(...)
	local text = table.concat({ ... }, "^")
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
		if not ok then geterrorhandler()(err) end
	end
end

local GROUP_CHANNELS = { PARTY = true, RAID = true, INSTANCE_CHAT = true }

local function OnAddonMessage(prefix, text, channel, sender)
	if prefix ~= PREFIX then return end
	if not GROUP_CHANNELS[channel] then return end -- never from whispers or other channels
	if ns.Rolls and ns.Rolls.debug and ns.Debug then
		ns.Debug("addon msg from %s -> %s: %s", tostring(sender), tostring(U.Canonical(sender)), (text:gsub("|", "||")))
	end
	sender = U.Canonical(sender)
	if not sender or sender == U.Me() then return end -- our own messages are applied locally
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
