-- Goblin Casino's own log: what the engine did, every addon message sent and received, rolls read
-- from chat and errors. Always on (debug mode only adds chat output), kept in memory and in
-- SavedVariables (GoblinCasinoDB.log, written on /reload or logout), so a problem can be looked
-- at afterwards: the bug button in the window shows it ready to copy.
local ADDON, ns = ...

local Log = {}
ns.Log = Log

Log.MAX = 1500          -- lines kept (this session plus the end of the previous ones)
Log.KEEP_PREVIOUS = 500 -- lines of earlier sessions kept at login

local lines = {}        -- this table is GoblinCasinoDB.log once the saved variables are loaded

-- Server time (the same clock for every player, so two players' logs line up to about a second),
-- with milliseconds from the game's own timer: the offset is taken once, so stamps never go back.
local offset
local function Stamp()
	local t = GetTime and GetTime() or 0
	if not offset then offset = (GetServerTime and GetServerTime() or time()) - t end
	local now = offset + t
	return date("%H:%M:%S", math.floor(now)) .. string.format(".%03d", math.floor((now % 1) * 1000))
end

local function Text(v)
	if type(issecretvalue) == "function" then
		local ok, secret = pcall(issecretvalue, v)
		if not ok or secret then return "<secret>" end
	end
	return tostring(v)
end

local function Trim()
	local extra = #lines - Log.MAX
	if extra > 0 then
		for _ = 1, extra do table.remove(lines, 1) end
	end
end

-- Log.Add("comm", "sent %s to %s", kind, channel). Arguments are made safe for format: nil,
-- tables and "secret" values never break logging.
function Log.Add(category, fmt, ...)
	local n = select("#", ...)
	local args = {}
	for i = 1, n do
		local v = select(i, ...)
		args[i] = type(v) == "number" and v or Text(v)
	end
	local ok, msg = pcall(string.format, tostring(fmt), unpack(args, 1, n))
	if not ok then
		msg = tostring(fmt)
		for i = 1, n do msg = msg .. " " .. tostring(args[i]) end
	end
	lines[#lines + 1] = Stamp() .. " [" .. category .. "] " .. msg:gsub("|", "||")
	Trim()
end

function Log.Error(where, err)
	Log.Add("ERROR", "%s: %s", where, err)
end

-- After ADDON_LOADED: continue the saved log (its last lines) and mark the new session.
function Log.Init(db)
	local early = lines
	local old = type(db.log) == "table" and db.log or {}
	lines = {}
	for i = math.max(1, #old - Log.KEEP_PREVIOUS + 1), #old do
		if type(old[i]) == "string" then lines[#lines + 1] = old[i] end
	end
	local build, _, _, interface = GetBuildInfo()
	lines[#lines + 1] = ""
	lines[#lines + 1] = string.format("===== %s  Goblin Casino %s  client %s (%s) %s  player %s =====",
		date("%Y-%m-%d %H:%M:%S", GetServerTime()), Log.Version(), tostring(build), tostring(interface),
		tostring(GetLocale()), tostring(UnitName("player")))
	for _, l in ipairs(early) do lines[#lines + 1] = l end
	db.log = lines
	Trim()
end

function Log.Clear()
	wipe(lines)
	Log.Add("log", "cleared")
end

-- The log as text (only the newest maxLines lines when given).
function Log.Text(maxLines)
	local first = maxLines and math.max(1, #lines - maxLines + 1) or 1
	return table.concat(lines, "\n", first, #lines)
end

function Log.Count()
	return #lines
end

function Log.Version()
	local get = C_AddOns and C_AddOns.GetAddOnMetadata or GetAddOnMetadata
	return get and get(ADDON, "Version") or "?"
end

-- Group members as the client names them: raw (as WoW gives it) and the key the engine uses.
local function RosterText()
	local U = ns.Util
	local parts = {}
	local raid = IsInRaid()
	for i = 1, GetNumGroupMembers() do
		local unit = raid and ("raid" .. i) or ("party" .. i)
		if UnitExists(unit) then
			local raw = GetUnitName(unit, true)
			local key = U and U.Canonical(raw) or "?"
			local online = UnitIsConnected(unit) and "" or " offline"
			parts[#parts + 1] = (raw == key) and (Text(raw) .. online) or (Text(raw) .. " -> " .. Text(key) .. online)
		end
	end
	return #parts > 0 and table.concat(parts, ", ") or "not in a group"
end

-- A snapshot of the current state, put at the top of the copied log.
function Log.Context()
	local U, J, Comm = ns.Util, ns.Jackpot, ns.Comm
	local out = {}
	local function add(fmt, ...)
		local ok, s = pcall(string.format, fmt, ...)
		out[#out + 1] = ok and s or fmt
	end
	local build, _, _, interface = GetBuildInfo()
	add("Goblin Casino %s  client %s (%s) %s  copied %s (server time)", Log.Version(), tostring(build),
		tostring(interface), tostring(GetLocale()), date("%Y-%m-%d %H:%M:%S", GetServerTime()))
	add("me: %s (key %s)  realm '%s'  practice %s  roll debug %s", Text(UnitName("player")),
		Text(U and U.Me()), Text(GetRealmName()), tostring(ns.practice), tostring(ns.Rolls and ns.Rolls.debug))
	add("group (%s): %s", Comm and tostring(Comm.Channel()) or "?", RosterText())
	add("messages: queued %s  blocked %s", Comm and tostring(Comm.Pending()) or "?",
		Comm and tostring(Comm.Restricted()) or "?")
	add("roll format: %s", Text(RANDOM_ROLL_RESULT))
	add("round: %s", J and J.Describe and J.Describe(J.round) or "?")
	return table.concat(out, "\n")
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_ACTION_BLOCKED")
events:RegisterEvent("ADDON_ACTION_FORBIDDEN")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PLAYER_LOGIN")
local lastRoster
events:SetScript("OnEvent", function(_, event, addon, func)
	if event == "GROUP_ROSTER_UPDATE" or event == "PLAYER_LOGIN" then
		-- the group as the client sees it, each time it changes
		local ok, text = pcall(RosterText)
		text = ok and text or ("error: " .. tostring(text))
		if text ~= lastRoster then
			lastRoster = text
			Log.Add("group", "%s", text)
		end
		if event == "PLAYER_LOGIN" then Log.HookErrors() end
	elseif addon == ADDON then
		-- blocked actions caused by this addon (taint)
		Log.Add("ERROR", "%s: %s", event, func)
	end
end)

-- Lua errors from this addon's code (button clicks, animations...) go to the log too. The handler
-- that was there before (Blizzard's or BugSack's) still gets every error.
function Log.HookErrors()
	if Log.hooked or not geterrorhandler or not seterrorhandler then return end
	Log.hooked = true
	local previous = geterrorhandler()
	seterrorhandler(function(msg, ...)
		pcall(function()
			local text = tostring(msg)
			local stack = debugstack and debugstack(2, 12, 0) or ""
			-- this handler is always on the stack itself, so its own lines don't count
			local ours = {}
			for line in stack:gmatch("[^\n]+") do
				if line:find(ADDON, 1, true) and not line:find("Core[/\\]Log%.lua") then ours[#ours + 1] = line end
			end
			if text:find(ADDON, 1, true) or #ours > 0 then
				Log.Add("ERROR", "%s", text)
				for _, line in ipairs(ours) do Log.Add("ERROR", "  at %s", line) end
			end
		end)
		return previous(msg, ...)
	end)
end
