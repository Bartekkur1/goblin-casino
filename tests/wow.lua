-- A small fake World of Warcraft for the tests: a group of clients, each running the addon's engine
-- (the Core and Games files, in TOC order) in its own environment, on one virtual clock.
--   - addon messages go through the group with a small delay (and can be dropped),
--   - /roll results are system chat lines seen by the whole group,
--   - C_Timer runs on the virtual clock (World:Run moves it forward),
--   - /reload throws a client's state away and loads the addon again with its SavedVariables.
-- The UI files need a real client and are not loaded.
local World = {}
World.__index = World

local Client = {}
Client.__index = Client

local ADDON = "GoblinCasino"
local ADDON_DIR = "GoblinCasino/"

local function DeepCopy(v)
	if type(v) ~= "table" then return v end
	local out = {}
	for k, x in pairs(v) do out[DeepCopy(k)] = DeepCopy(x) end
	return out
end
World.DeepCopy = DeepCopy

-- The engine's files in load order (from the TOC).
local files
local function AddonFiles()
	if files then return files end
	files = {}
	for line in io.lines(ADDON_DIR .. ADDON .. ".toc") do
		line = line:gsub("\r", "")
		if line:match("^Core\\") or line:match("^Games\\") then
			files[#files + 1] = ADDON_DIR .. (line:gsub("\\", "/"))
		end
	end
	return files
end

---------------------------------------------------------------------------
-- WoW helpers that aren't standard Lua
---------------------------------------------------------------------------
local function strsplit(sep, s)
	local out, pos = {}, 1
	while true do
		local i = string.find(s, sep, pos, true)
		if not i then
			out[#out + 1] = s:sub(pos)
			break
		end
		out[#out + 1] = s:sub(pos, i - 1)
		pos = i + #sep
	end
	return unpack(out)
end

local function strtrim(s)
	return (s:match("^%s*(.-)%s*$"))
end

local function wipe(t)
	for k in pairs(t) do t[k] = nil end
	return t
end

---------------------------------------------------------------------------
-- World
---------------------------------------------------------------------------
function World.new()
	local w = setmetatable({}, World)
	w.now = 1000
	w.timers = {}
	w.seq = 0
	w.members = {}       -- every client, in join order
	w.random = 20240601  -- roll generator state
	w.msgDelay = 0.05
	w.rollDelay = 0.2
	w.drop = nil         -- function(from, to, msg) -> true drops that addon message
	return w
end

-- Deterministic numbers for /roll (Park-Miller, like the addon, but its own stream).
function World:Rand(lo, hi)
	self.random = (self.random * 48271) % 2147483647
	return lo + self.random % (hi - lo + 1)
end

function World:After(delay, fn)
	self.seq = self.seq + 1
	local timer = { at = self.now + math.max(0, delay or 0), seq = self.seq, fn = fn }
	self.timers[#self.timers + 1] = timer
	return timer
end

-- Moves the clock forward `seconds`, running every timer that comes due, in order.
function World:Run(seconds)
	local stop = self.now + (seconds or 0)
	while true do
		local best, index
		for i, t in ipairs(self.timers) do
			if t.at <= stop and (not best or t.at < best.at or (t.at == best.at and t.seq < best.seq)) then
				best, index = t, i
			end
		end
		if not best then break end
		table.remove(self.timers, index)
		if best.at > self.now then self.now = best.at end
		best.fn()
	end
	self.now = stop
end

-- Everyone in the group (offline members included, as in WoW).
function World:Group()
	local list = {}
	for _, m in ipairs(self.members) do
		if m.inGroup then list[#list + 1] = m end
	end
	return list
end

function World:AddClient(name, surname)
	local c = setmetatable({
		world = self, name = name, surname = surname or "Testsson",
		online = true, inGroup = true, restricted = false,
		errors = {}, prints = {}, saved = nil, generation = 0,
	}, Client)
	self.members[#self.members + 1] = c
	return c
end

-- Loads the addon on every client (a fresh login) and lets the login settle.
function World:Start()
	for _, c in ipairs(self.members) do c:Load(false) end
	self:Run(5)
end

function World:RosterChanged()
	for _, m in ipairs(self.members) do
		m:Fire("GROUP_ROSTER_UPDATE")
		m:Fire("UNIT_CONNECTION")
	end
end

function World:Broadcast(from, prefix, msg, channel)
	for _, to in ipairs(self:Group()) do
		if to.online and not (self.drop and self.drop(from, to, msg)) then
			local gen = to.generation
			self:After(self.msgDelay, function()
				if to.online and to.inGroup and to.generation == gen then
					to:Fire("CHAT_MSG_ADDON", prefix, msg, channel, from:FullName())
				end
			end)
		end
	end
end

function World:SystemMessage(text, delay)
	for _, to in ipairs(self:Group()) do
		local gen = to.generation
		self:After(delay or 0, function()
			if to.online and to.generation == gen then to:Fire("CHAT_MSG_SYSTEM", text) end
		end)
	end
end

-- Every Lua error any client hit.
function World:Errors()
	local out = {}
	for _, c in ipairs(self.members) do
		for _, e in ipairs(c.errors) do out[#out + 1] = c.name .. ": " .. tostring(e) end
	end
	return out
end

---------------------------------------------------------------------------
-- Client
---------------------------------------------------------------------------
-- How Forever writes this player in chat and as the sender of addon messages.
function Client:FullName()
	return self.name .. " " .. self.surname
end

-- The client behind a unit token ("player", "party2", "raid7"), as this client sees the group.
function Client:Unit(unit)
	if unit == "player" then return self end
	if not self.inGroup then return nil end
	local group = self.world:Group()
	local kind, i = tostring(unit):match("^(%a+)(%d+)$")
	i = tonumber(i)
	if not i then return nil end
	if kind == "raid" and #group > 5 then return group[i] end
	if kind == "party" and #group <= 5 then
		local n = 0
		for _, m in ipairs(group) do
			if m ~= self then
				n = n + 1
				if n == i then return m end
			end
		end
	end
	return nil
end

function Client:Call(fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then self.env.geterrorhandler()(err) end
end

function Client:Fire(event, ...)
	if not self.loaded then return end
	for _, f in ipairs(self.frames) do
		local fn = f.scripts.OnEvent
		if fn and (f.events[event] or f.all) then self:Call(fn, f, event, ...) end
	end
end

function Client:MakeEnv()
	local c, w = self, self.world
	local env = setmetatable({}, { __index = _G })
	env._G = env
	self.frames = {}

	local handler = function(err) c.errors[#c.errors + 1] = tostring(err) end
	env.geterrorhandler = function() return handler end
	env.seterrorhandler = function(fn) handler = fn end
	env.debugstack = function() return "" end

	env.CreateFrame = function()
		local f = { events = {}, scripts = {}, shown = true }
		function f:RegisterEvent(e) self.events[e] = true end
		function f:UnregisterEvent(e) self.events[e] = nil end
		function f:RegisterAllEvents() self.all = true end
		function f:UnregisterAllEvents() self.events = {}; self.all = nil end
		function f:SetScript(k, fn) self.scripts[k] = fn end
		function f:GetScript(k) return self.scripts[k] end
		function f:Show() self.shown = true end
		function f:Hide() self.shown = false end
		function f:IsShown() return self.shown end
		c.frames[#c.frames + 1] = f
		return f
	end

	-- timers die with the client's environment (as on /reload)
	env.C_Timer = {
		After = function(delay, fn)
			w:After(delay, function() if c.env == env then c:Call(fn) end end)
		end,
		NewTicker = function(interval, fn)
			local ticker = { cancelled = false }
			function ticker:Cancel() self.cancelled = true end
			local function Tick()
				if ticker.cancelled or c.env ~= env then return end
				c:Call(fn, ticker)
				if not ticker.cancelled then w:After(interval, Tick) end
			end
			w:After(interval, Tick)
			return ticker
		end,
	}

	env.Enum = {
		SendAddonMessageResult = { Success = 0, InvalidPrefix = 1, InvalidMessage = 2, AddonMessageThrottle = 3,
			InvalidChatType = 4, NotInGroup = 5, TargetRequired = 6, InvalidChannel = 7, ChannelThrottle = 8,
			GeneralError = 9 },
		AddOnRestrictionType = { Combat = 1, Encounter = 2 },
	}
	env.C_RestrictedActions = { IsAddOnRestrictionActive = function() return c.restricted end }
	env.C_ChatInfo = {
		RegisterAddonMessagePrefix = function(prefix) c.prefix = prefix; return true end,
		SendAddonMessage = function(prefix, msg, channel)
			assert(type(msg) == "string" and #msg <= 255, "addon message longer than 255 bytes")
			assert(prefix == c.prefix, "prefix not registered")
			c.sent = (c.sent or 0) + 1
			w:Broadcast(c, prefix, msg, channel)
			return 0
		end,
	}
	env.RandomRoll = function(lo, hi)
		local value = w.nextRoll and w.nextRoll(c) or w:Rand(lo, hi)
		w:SystemMessage(string.format("%s rolls %d (%d-%d)", c:FullName(), value, lo, hi), w.rollDelay)
	end

	env.UnitName = function(unit) local m = c:Unit(unit); return m and m.name end
	env.GetUnitName = function(unit) local m = c:Unit(unit); return m and m.name end
	env.UnitExists = function(unit) return c:Unit(unit) ~= nil end
	env.UnitIsConnected = function(unit) local m = c:Unit(unit); return m ~= nil and m.online end
	env.UnitIsVisible = function(unit) return c:Unit(unit) ~= nil end
	env.IsInRaid = function() return c.inGroup and #w:Group() > 5 end
	env.IsInGroup = function(category)
		if category == 2 then return false end -- no instance groups here
		return c.inGroup and #w:Group() > 1
	end
	env.GetNumGroupMembers = function()
		local n = #w:Group()
		return (c.inGroup and n > 1) and n or 0
	end
	env.LE_PARTY_CATEGORY_HOME, env.LE_PARTY_CATEGORY_INSTANCE = 1, 2

	env.GetRealmName = function() return "" end -- WoW Forever has no realm name
	env.GetNormalizedRealmName = function() return "" end
	env.GetTime = function() return w.now end
	env.GetServerTime = function() return 1700000000 + math.floor(w.now) end
	env.time = env.GetServerTime
	env.date = os.date
	env.GetMoney = function() return 1000000 * 10000 end
	env.GetBuildInfo = function() return "1.6.0", "1", "Jan 1 2026", 16001 end
	env.GetLocale = function() return "enUS" end
	env.C_AddOns = { GetAddOnMetadata = function() return "test" end }
	env.RANDOM_ROLL_RESULT = "%s rolls %d (%d-%d)"
	env.UNKNOWNOBJECT = "Unknown"
	env.SlashCmdList = {}
	env.UISpecialFrames = {}
	env.CopyTable = DeepCopy
	env.strsplit, env.strtrim, env.wipe, env.tinsert = strsplit, strtrim, wipe, table.insert
	env.print = function(...)
		local parts = {}
		for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
		c.prints[#c.prints + 1] = table.concat(parts, " ")
	end
	env.GoblinCasinoDB = DeepCopy(c.saved) -- SavedVariables (nil on the first login)
	return env
end

-- Loads the addon: a fresh login, or a /reload (isReload) that keeps the SavedVariables.
function Client:Load(isReload)
	self.generation = self.generation + 1
	self.loaded = false
	self.prefix = nil
	local env = self:MakeEnv()
	self.env = env
	local ns = { Minimap = { Init = function() end } } -- the minimap button is UI
	self.ns = ns
	for _, path in ipairs(AddonFiles()) do
		local chunk = assert(loadfile(path))
		setfenv(chunk, env)
		chunk(ADDON, ns)
	end
	self.loaded = true
	self.J, self.U, self.Comm, self.Rolls = ns.Jackpot, ns.Util, ns.Comm, ns.Rolls
	self:Fire("ADDON_LOADED", ADDON)
	self:Fire("PLAYER_LOGIN")
	self:Fire("PLAYER_ENTERING_WORLD", not isReload, isReload and true or false)
	self:Fire("GROUP_ROSTER_UPDATE")
end

-- /reload: WoW writes the SavedVariables, then the addon starts again from nothing.
function Client:Reload()
	self.saved = DeepCopy(self.env.GoblinCasinoDB)
	self:Load(true)
end

function Client:History()
	return self.env.GoblinCasinoDB and self.env.GoblinCasinoDB.history or {}
end

-- Did any chat line printed by the addon contain `text`?
function Client:Printed(text)
	for _, line in ipairs(self.prints) do
		if line:find(text, 1, true) then return true end
	end
	return false
end

return World
