-- Reads /roll results from system chat. Only real server rolls appear there, so a roll typed into
-- normal chat can't fake one. The pattern is built from the client's own RANDOM_ROLL_RESULT
-- string, so it works in every client language.
--
-- Forever decorates system lines (see ForeverDungeonJournal's "rollfix"): names can come as player
-- links or in color, numbers can carry thousands separators, and a tag can stand before the line.
-- All of that is stripped or allowed for here.
local ADDON, ns = ...
local U = ns.Util

local Rolls = {}
ns.Rolls = Rolls

Rolls.MIN, Rolls.MAX = 1, 1000000
Rolls.debug = false

local listeners = {}
function Rolls.Listen(fn)
	listeners[#listeners + 1] = fn
end

-- "%s rolls %d (%d-%d)" -> Lua pattern with captures in argument order (some locales use %2$s).
local function MakePattern(fmt)
	local out, order, i = {}, {}, 1
	while i <= #fmt do
		local c = fmt:sub(i, i)
		if c == "%" then
			local pos, conv = fmt:match("^%%(%d)%$([sd])", i)
			local skip = 4
			if not conv then conv = fmt:match("^%%([sd])", i); skip = 2 end
			if conv then
				order[#order + 1] = tonumber(pos) or (#order + 1)
				out[#out + 1] = conv == "d" and "([%d%.,]+)" or "(.-)"
				i = i + skip
			else
				out[#out + 1] = "%%"
				i = i + (fmt:sub(i + 1, i + 1) == "%" and 2 or 1)
			end
		elseif c:find("[%(%)%.%+%-%*%?%[%]%^%$]") then
			out[#out + 1] = "%" .. c
			i = i + 1
		else
			out[#out + 1] = c
			i = i + 1
		end
	end
	return { pattern = table.concat(out), order = order }
end

local pattern
local function Pattern()
	pattern = pattern or MakePattern(RANDOM_ROLL_RESULT or "%s rolls %d (%d-%d)")
	return pattern
end

-- Player links -> plain name, colors and icons off, other links -> their text.
local function Clean(text)
	return (text
		:gsub("|T.-|t", "")
		:gsub("|Hplayer:[^|]*|h%[?([^%]|]*)%]?|h", "%1")
		:gsub("|H[^|]*|h(.-)|h", "%1")
		:gsub("|c%x%x%x%x%x%x%x%x", "")
		:gsub("|r", ""))
end

local function Number(s)
	return tonumber((tostring(s or ""):gsub("[^%d]", "")))
end

-- Returns name, roll, min, max for a roll message, else nil.
function Rolls.Parse(msg)
	if type(msg) ~= "string" then return nil end
	local p = Pattern()
	local text = Clean(msg)
	local caps = { text:match("^" .. p.pattern .. "$") }
	if #caps == 0 then caps = { text:match(p.pattern) } end -- a tag before the line
	if #caps < 4 then return nil end
	local args = {}
	for k, index in ipairs(p.order) do args[index] = caps[k] end
	local raw = args[1] or ""
	-- a tag before the name ("[Tag] Bika Selfbane"): the name is what follows the last "] "
	raw = raw:match("%]%s+([^%]]+)$") or raw
	local name = strtrim((raw:gsub("^%[", ""):gsub("%]$", "")))
	-- Forever writes the full name ("Bika Selfbane"); character names have no spaces, so the
	-- first word is the character.
	name = name:match("^(%S+)")
	if not name then return nil end
	return U.Canonical(name), Number(args[2]), Number(args[3]), Number(args[4])
end

function Rolls.Roll()
	if ns.Debug then ns.Debug("calling RandomRoll(%d, %d)", Rolls.MIN, Rolls.MAX) end
	RandomRoll(Rolls.MIN, Rolls.MAX)
end

local function IsSecret(v)
	if type(issecretvalue) ~= "function" then return false end
	local ok, s = pcall(issecretvalue, v)
	return not ok or s
end

local function Debug(msg, ...)
	if not Rolls.debug then return end
	ns.Print("|cff9d8fbf[debug]|r " .. msg:format(...))
end
ns.Debug = Debug

-- Debug sniffer: listens to every event and reports any that carries a roll-looking value,
-- so we can see which event (if not CHAT_MSG_SYSTEM) brings /roll results on this client.
local sniffer = CreateFrame("Frame")
sniffer:SetScript("OnEvent", function(_, event, ...)
	if event == "CHAT_MSG_SYSTEM" then return end -- reported by the real handler below
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		if type(v) == "string" and not IsSecret(v)
			and (v:find("1000000", 1, true) or v:find("1,000,000", 1, true) or v:lower():find("roll", 1, true)) then
			Debug("event %s arg %d: %s", event, i, (v:gsub("|", "||")))
		end
	end
end)

function Rolls.SetDebug(on)
	Rolls.debug = on and true or false
	if ns.db then ns.db.debug = Rolls.debug end
	if Rolls.debug then
		if not pcall(sniffer.RegisterAllEvents, sniffer) then Debug("can't listen to all events on this client") end
	else
		sniffer:UnregisterAllEvents()
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("CHAT_MSG_SYSTEM")
events:SetScript("OnEvent", function(_, _, msg)
	-- inside instances the text may be a "secret" value; reading it must not break anything
	if IsSecret(msg) then
		Debug("system line is a secret value (can't be read here)")
		return
	end
	local ok, name, roll, low, high = pcall(Rolls.Parse, msg)
	if Rolls.debug and type(msg) == "string" and msg:find("%d") then
		Debug("raw: %s", (msg:gsub("|", "||")))
		Debug("parsed: %s", ok and name and (name .. " " .. tostring(roll) .. " (" .. tostring(low) .. "-" .. tostring(high) .. ")") or ("no match, pattern " .. Pattern().pattern:gsub("|", "||")))
	end
	if not ok or not name or not roll then return end
	if low ~= Rolls.MIN or high ~= Rolls.MAX then
		Debug("roll ignored: range %s-%s is not %d-%d", tostring(low), tostring(high), Rolls.MIN, Rolls.MAX)
		return
	end
	Debug("roll %d by %s goes to %d listener(s)", roll, name, #listeners)
	for _, fn in ipairs(listeners) do
		local ok2, err = pcall(fn, name, roll)
		if not ok2 then
			Debug("|cffff6b6blistener error:|r %s", tostring(err))
			geterrorhandler()(err)
		end
	end
end)
