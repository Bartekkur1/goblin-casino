-- Helpers shared by the engine: player names, deterministic sort, hash, seeded PRNG.
-- Everything here must give the same result on every client, whatever its locale.
local ADDON, ns = ...

local U = {}
ns.Util = U

---------------------------------------------------------------------------
-- Player names
-- Every name inside the engine is "Name-Realm" (realm without spaces), so a player is one key
-- no matter whether the client shows them with or without a realm. When the client has no realm
-- name at all (WoW Forever gives an empty one), the key is just "Name".
---------------------------------------------------------------------------
local myRealm

local function MyRealm()
	if not myRealm or myRealm == "" then
		local r = GetNormalizedRealmName and GetNormalizedRealmName()
		if not r or r == "" then r = (GetRealmName() or ""):gsub("[%s']", "") end
		myRealm = r or ""
	end
	return myRealm
end

-- WoW Forever writes players in several forms: "Bika" (UnitName), "Bika Selfbane" (name plus the
-- Forever surname, in chat and addon message senders) and sometimes "Bika-Realm". Character names
-- never contain spaces or hyphens, so the character is always the first word before any space or
-- hyphen. Without a realm name (Forever) that alone is the key, whatever form the client used.
function U.Canonical(name)
	if type(name) ~= "string" then return nil end
	name = strtrim(name)
	local short = name:match("^([^%s%-]+)")
	if not short then return nil end
	local mine = MyRealm()
	if mine == "" then return short end
	local realm = (name:match("^[^%-]*%-(.*)$") or ""):gsub("[%s']", "")
	if realm == "" then realm = mine end
	return short .. "-" .. realm
end

function U.Me()
	return U.Canonical(UnitName("player"))
end

-- "Name-Realm" -> "Name" (for display)
function U.Short(name)
	return name and (name:match("^[^%-]+") or name) or "?"
end

-- Canonical names of everyone in the group (including the player). The second value is true when
-- some member's name isn't known yet ("Unknown" while loading), so the list may be incomplete.
function U.GroupRoster()
	local set = { [U.Me()] = true }
	local incomplete = false
	local n = GetNumGroupMembers()
	local raid = IsInRaid()
	for i = 1, n do
		local unit = raid and ("raid" .. i) or ("party" .. i)
		if UnitExists(unit) then
			local name = GetUnitName(unit, true)
			local key = type(name) == "string" and name ~= UNKNOWNOBJECT and U.Canonical(name)
			if key then set[key] = true else incomplete = true end
		end
	end
	return set, incomplete
end

function U.InGroup(name)
	return U.GroupRoster()[name] == true
end

---------------------------------------------------------------------------
-- Byte-wise string order. Lua's own < on strings follows the system locale, which can differ
-- between players; that would change the seed. This one never does.
---------------------------------------------------------------------------
function U.ByteLess(a, b)
	local la, lb = #a, #b
	for i = 1, math.min(la, lb) do
		local x, y = a:byte(i), b:byte(i)
		if x ~= y then return x < y end
	end
	return la < lb
end

function U.SortedKeys(t)
	local keys = {}
	for k in pairs(t) do keys[#keys + 1] = k end
	table.sort(keys, U.ByteLess)
	return keys
end

---------------------------------------------------------------------------
-- FNV-1a, 32 bit, in plain arithmetic (no bit library, no precision loss)
---------------------------------------------------------------------------
local function Xor8(a, b)
	local r, v = 0, 1
	for _ = 1, 8 do
		local x, y = a % 2, b % 2
		if x ~= y then r = r + v end
		a, b, v = (a - x) / 2, (b - y) / 2, v * 2
	end
	return r
end

function U.FNV1a(s)
	local h = 2166136261
	for i = 1, #s do
		local low = h % 256
		h = h - low + Xor8(low, s:byte(i))
		-- h * 16777619 mod 2^32, where 16777619 = 2^24 + 403
		h = (h * 403 + (h % 256) * 16777216) % 4294967296
	end
	return h
end

---------------------------------------------------------------------------
-- Seeded PRNG (Park-Miller, "minimal standard" with multiplier 48271).
-- math.random can't be seeded in WoW, and it would differ between clients anyway.
---------------------------------------------------------------------------
local MOD = 2147483647

function U.NewRNG(seed)
	local state = seed % (MOD - 1) + 1
	local rng = {}
	function rng:Next() -- 1 .. MOD-1
		state = (state * 48271) % MOD
		return state
	end
	-- uniform integer 0 .. n-1, without modulo bias
	function rng:Int(n)
		local range = MOD - 1
		local limit = range - range % n
		while true do
			local r = self:Next() - 1
			if r < limit then return r % n end
		end
	end
	return rng
end

---------------------------------------------------------------------------
-- Misc
---------------------------------------------------------------------------
function U.PlayerGold()
	return math.floor(GetMoney() / 10000)
end

function U.Thousands(n)
	local s = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (s:gsub("^,", ""))
end

function U.Gold(n)
	return U.Thousands(n) .. "|cffffd700g|r"
end
