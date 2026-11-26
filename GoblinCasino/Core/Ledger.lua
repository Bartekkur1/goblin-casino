-- The ledger: one tab per character of who owes whom, in copper.
-- Balance(who) > 0 means `who` owes me; < 0 means I owe `who`.
-- Saved per character in ns.db.ledger[me]. Tables are created lazily, never at file load.
--
-- Messages between the two addons of a pair (everything else stays local):
--   G^to^id^kind^copper   I confirm a payment (kind "received") or forgive a debt ("forgive");
--                         kept in book.outbox and sent again until the payer answers
--   A^to^id               the payer's answer: the notice arrived (applied once, by its id)
--   K^to^balance^reply    my balance with `to`, so their addon can compare; reply "1" asks for theirs
local ADDON, ns = ...
local U = ns.Util
local Comm = ns.Comm

local L = {}
ns.Ledger = L

L.COPPER = 10000
L.MAX_ENTRIES = 100 -- per person; older ones fold into one "carry" entry
local MAX_COPPER = 2 ^ 31 -- amounts at or above this are refused

-- Session only (not saved): what the partner's addon says they owe / are owed, from my point of view.
L.reported = {}
L.mismatch = {}

local listeners = {}
function L.OnChange(fn) listeners[#listeners + 1] = fn end
local function Changed()
	for _, fn in ipairs(listeners) do
		local ok, err = pcall(fn)
		if not ok then
			ns.Log.Error("UI update", err)
			geterrorhandler()(err)
		end
	end
end
L.Changed = Changed

function L.Book()
	if type(ns.db.ledger) ~= "table" then ns.db.ledger = {} end
	local me = U.Me()
	local b = ns.db.ledger[me]
	if type(b) ~= "table" then
		b = {}
		ns.db.ledger[me] = b
	end
	if type(b.entries) ~= "table" then b.entries = {} end
	if type(b.rounds) ~= "table" then b.rounds = {} end
	if type(b.outbox) ~= "table" then b.outbox = {} end
	if type(b.seen) ~= "table" then b.seen = {} end
	return b
end

-- Getters answer "nobody" (no entries, 0, false) for a name that isn't a player name.
function L.Entries(who)
	who = U.Canonical(who)
	if not who then return {} end
	return L.Book().entries[who] or {}
end

function L.Balance(who)
	local sum = 0
	for _, e in ipairs(L.Entries(who)) do sum = sum + e.amount end
	return sum
end

function L.Known(who)
	who = U.Canonical(who)
	if not who then return false end
	local list = L.Book().entries[who]
	return list ~= nil and #list > 0
end

-- Everyone known: I owe first, then owes me, then zero; ties by name.
function L.People()
	local entries = L.Book().entries
	local bal, names = {}, {}
	for who, list in pairs(entries) do
		if #list > 0 then
			names[#names + 1] = who
			bal[who] = L.Balance(who)
		end
	end
	local function group(b) return b < 0 and 1 or (b > 0 and 2 or 3) end
	table.sort(names, function(a, b)
		local ga, gb = group(bal[a]), group(bal[b])
		if ga ~= gb then return ga < gb end
		return U.ByteLess(a, b)
	end)
	return names
end

-- Gold text for an amount of copper (sign ignored): whole gold stays "5g", otherwise "5g 20s 3c".
function L.FormatCopper(copper)
	copper = math.abs(copper or 0)
	local gold = math.floor(copper / L.COPPER)
	local rest = copper - gold * L.COPPER
	local silver = math.floor(rest / 100)
	local cop = rest - silver * 100
	local text = U.Gold(gold)
	if silver > 0 then text = text .. " " .. silver .. "s" end
	if cop > 0 then text = text .. " " .. cop .. "c" end
	return text
end

-- A whole number of copper, 1 .. 2^31-1 (NaN and infinity fail the range checks).
local function Valid(copper)
	return type(copper) == "number" and copper >= 1 and copper < MAX_COPPER and copper == math.floor(copper)
end

-- Appends an entry; when the person has more than MAX_ENTRIES, the oldest fold into one carry entry.
local function Add(who, entry)
	local book = L.Book()
	local list = book.entries[who]
	if not list then
		list = {}
		book.entries[who] = list
	end
	entry.t = GetServerTime()
	list[#list + 1] = entry
	local n = #list
	if n > L.MAX_ENTRIES then
		local fold = n - L.MAX_ENTRIES + 1
		local sum = 0
		for i = 1, fold do sum = sum + list[i].amount end
		local carry = { kind = "carry", amount = sum, t = list[1].t }
		local trimmed = { carry }
		for i = fold + 1, n do trimmed[#trimmed + 1] = list[i] end
		book.entries[who] = trimmed
	end
end

-- My tab or theirs as words, from my point of view.
local function View(who, copper)
	if copper < 0 then return "you owe " .. L.FormatCopper(copper) end
	if copper > 0 then return U.Short(who) .. " owes you " .. L.FormatCopper(copper) end
	return "you're even"
end

-- A notice moved both tabs: keep what their addon said in step, and drop a mismatch it settled.
local function Track(who, reported)
	L.reported[who] = reported
	if L.mismatch[who] then
		local mine = L.Balance(who)
		L.mismatch[who] = mine ~= reported and { mine = mine, theirs = reported } or nil
	end
end

-- A round or trade moved my tab with `who`, and their addon records the same one: what it last
-- reported moves with it, so a known mismatch keeps its gap instead of going stale.
local function Shift(who, copper)
	if L.reported[who] then L.reported[who] = L.reported[who] + copper end
	local m = L.mismatch[who]
	if m then m.mine, m.theirs = m.mine + copper, m.theirs + copper end
end

-- Round ids start with the server time; a round can't finish again days later, so old ids go
-- (once a session) to keep the saved list small.
L.ROUND_KEEP = 30 * 86400
local pruned = false
local function PruneRounds(book)
	if pruned then return end
	pruned = true
	local cutoff = GetServerTime() - L.ROUND_KEEP
	for id in pairs(book.rounds) do
		local t = tonumber(tostring(id):sub(1, -4))
		if t and t < cutoff then book.rounds[id] = nil end
	end
end

-- How much of `copper` a forgive takes off a debt of `debt` (never past zero).
local function Forgiven(copper, debt)
	return math.min(copper, math.max(0, debt))
end

---------------------------------------------------------------------------
-- Notices (received / forgive): saved in the outbox until the payer's addon answers
---------------------------------------------------------------------------
local noticeCount = 0 -- this session; keeps two ids made in the same second apart

local function SendNotice(item)
	Comm.Send("G", item.to, item.id, item.kind, item.amount)
end

local function Notice(who, kind, copper)
	noticeCount = noticeCount + 1
	local item = {
		id = U.Me() .. GetServerTime() .. math.random(1000, 9999) .. "." .. noticeCount,
		to = who, kind = kind, amount = copper,
	}
	local book = L.Book()
	book.outbox[#book.outbox + 1] = item
	if Comm.Channel() and U.InGroup(who) then SendNotice(item) end
end

-- Sends every waiting notice whose payer is in my group; returns how many went out.
function L.ResendOutbox()
	if not ns.db or not Comm.Channel() then return 0 end
	local roster = U.GroupRoster()
	local n = 0
	for _, item in ipairs(L.Book().outbox) do
		if type(item) == "table" and item.id and roster[item.to] then
			SendNotice(item)
			n = n + 1
		end
	end
	return n
end

---------------------------------------------------------------------------
-- Changes to the tab
---------------------------------------------------------------------------
-- A finished round: what I owe / am owed from its transfers (amounts are whole gold).
function L.AddRound(round)
	if not round or round.practice then return nil end
	local transfers = round.result and round.result.transfers
	if not transfers then return nil end
	local book = L.Book()
	PruneRounds(book)
	if round.id and book.rounds[round.id] then return nil end
	local me = U.Me()
	local changes = {}
	for _, t in ipairs(transfers) do
		local from, to = U.Canonical(t.from), U.Canonical(t.to)
		if from and to then
			if to == me and from ~= me then
				changes[#changes + 1] = { who = from, amount = t.amount * L.COPPER }
			elseif from == me and to ~= me then
				changes[#changes + 1] = { who = to, amount = -t.amount * L.COPPER }
			end
		end
	end
	if #changes == 0 then return nil end
	if round.id then book.rounds[round.id] = true end
	for _, ch in ipairs(changes) do
		Add(ch.who, { kind = "round", amount = ch.amount, id = round.id, game = round.game })
		Shift(ch.who, ch.amount)
	end
	Changed()
	return changes
end

-- A completed trade: I gave `gave` copper and got `got` copper.
function L.AddTrade(who, gave, got)
	who = U.Canonical(who)
	if not who then return false, "Unknown player." end
	gave, got = gave or 0, got or 0
	if gave == got then return end
	Add(who, { kind = "trade", amount = gave - got, gave = gave, got = got })
	Shift(who, gave - got)
	Changed()
	return true
end

-- I confirm that `who` paid me `copper` of what they owed.
function L.Received(who, copper)
	who = U.Canonical(who)
	if not who then return false, "Unknown player." end
	if not Valid(copper) then return false, "Enter an amount." end
	if L.Balance(who) <= 0 then return false, "They don't owe you anything." end
	Add(who, { kind = "received", amount = -copper })
	-- their addon adds the same payment
	if L.reported[who] then Track(who, L.reported[who] - copper) end
	Notice(who, "received", copper)
	Changed()
	return true
end

-- I forgive what `who` owes me (also when only their addon reports the debt).
function L.Forgive(who, copper)
	who = U.Canonical(who)
	if not who then return false, "Unknown player." end
	if not Valid(copper) then return false, "Enter an amount." end
	local bal = L.Balance(who)
	if bal <= 0 and (L.reported[who] or 0) <= 0 then return false, "They don't owe you anything." end
	local own = Forgiven(copper, bal)
	if own > 0 then Add(who, { kind = "forgive", amount = -own }) end
	-- their addon takes it off their debt, never past zero
	local r = L.reported[who]
	if r then Track(who, r - Forgiven(copper, r)) end
	Notice(who, "forgive", copper)
	Changed()
	return true
end

-- The debtor's own correction: I owe `who` another `copper`.
function L.AddDebt(who, copper)
	who = U.Canonical(who)
	if not who then return false, "Unknown player." end
	if not Valid(copper) then return false, "Enter an amount." end
	Add(who, { kind = "adjust", amount = -copper })
	-- the added debt closes (part of) the gap their addon reported; their figure stays as it was
	local m = L.mismatch[who]
	if m then
		m.mine = m.mine - copper
		if m.mine == m.theirs then L.mismatch[who] = nil end
	end
	Changed()
	return true
end

---------------------------------------------------------------------------
-- Comparing tabs: their addon tells me its balance with me, I check it against mine
---------------------------------------------------------------------------
-- Sends my balance with `who` to their addon (and asks for theirs). Needs a group and a tab with them.
function L.Compare(who)
	who = U.Canonical(who)
	if not who then return false, "Unknown player." end
	if not (Comm.Channel() and U.InGroup(who) and L.Known(who)) then return false end
	Comm.Send("K", who, L.Balance(who), "1")
	return true
end

local function ForMe(to)
	return U.Canonical(to) == U.Me()
end

-- A number from a message: finite and whole, else nil.
local function Copper(field)
	local n = tonumber(field)
	if not n or n ~= n or n == math.huge or n == -math.huge or n ~= math.floor(n) then return nil end
	return n
end

Comm.On("K", function(f, sender)
	if not ns.db or not ForMe(f[2]) then return end
	local balance = Copper(f[3])
	if not balance then return end
	local theirs = 0 - balance -- their balance with me, turned to my point of view (0 - x: never -0)
	local mine = L.Balance(sender)
	L.reported[sender] = theirs
	if theirs ~= mine then
		L.mismatch[sender] = { mine = mine, theirs = theirs }
		ns.Print(U.Short(sender) .. "'s addon says " .. View(sender, theirs) .. ", yours says " .. View(sender, mine)
			.. ". Check the rounds on your tab.")
	else
		L.mismatch[sender] = nil
	end
	if f[4] == "1" then Comm.Send("K", sender, mine, "0") end
	Changed()
end)

Comm.On("G", function(f, sender)
	if not ns.db or not ForMe(f[2]) then return end
	local id, kind, copper = f[3], f[4], Copper(f[5])
	if not id or id == "" then return end
	local book = L.Book()
	if not book.seen[id] and (kind == "received" or kind == "forgive") and Valid(copper) then
		book.seen[id] = true
		local r = L.reported[sender] -- their balance with me, from my point of view
		if kind == "received" then
			Add(sender, { kind = "received", amount = copper })
			if r then Track(sender, r + copper) end
			ns.Print(U.Short(sender) .. " confirmed your payment of " .. L.FormatCopper(copper) .. ".")
		else
			-- a forgive takes the debt down to zero at most, as on their side
			local own = Forgiven(copper, -L.Balance(sender))
			if own > 0 then Add(sender, { kind = "forgive", amount = own }) end
			if r then Track(sender, r + Forgiven(copper, -r)) end
			ns.Print(U.Short(sender) .. " forgave you " .. L.FormatCopper(copper) .. ".")
		end
		Changed()
	end
	-- answered every time, also for a notice seen before (our first answer may have been lost)
	Comm.Send("A", sender, id)
end)

Comm.On("A", function(f, sender)
	if not ns.db or not ForMe(f[2]) then return end
	local id = f[3]
	local outbox = L.Book().outbox
	local removed = false
	for i = #outbox, 1, -1 do
		local item = outbox[i]
		if type(item) == "table" and item.id == id and item.to == sender then
			table.remove(outbox, i)
			removed = true
		end
	end
	if removed then Changed() end
end)

-- Waiting notices go out again when the group changes or after a loading screen. Roster updates
-- come in bursts, so one resend a second after the first of a burst.
local resendSoon = false
local function ResendSoon()
	if resendSoon then return end
	resendSoon = true
	C_Timer.After(1, function()
		resendSoon = false
		local ok, err = pcall(L.ResendOutbox)
		if not ok then ns.Log.Error("ledger resend", err) end
	end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", ResendSoon)
