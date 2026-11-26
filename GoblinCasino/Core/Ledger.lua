-- The ledger: one tab per character of who owes whom, in copper.
-- Balance(who) > 0 means `who` owes me; < 0 means I owe `who`.
-- Saved per character in ns.db.ledger[me]. Tables are created lazily, never at file load.
local ADDON, ns = ...
local U = ns.Util

local L = {}
ns.Ledger = L

L.COPPER = 10000
L.MAX_ENTRIES = 100 -- per person; older ones fold into one "carry" entry

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

function L.Entries(who)
	return L.Book().entries[who] or {}
end

function L.Balance(who)
	local sum = 0
	for _, e in ipairs(L.Entries(who)) do sum = sum + e.amount end
	return sum
end

function L.Known(who)
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

local function Valid(copper)
	return type(copper) == "number" and copper >= 1 and copper == math.floor(copper)
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

local function Notice(who, kind, copper)
	local book = L.Book()
	book.outbox[#book.outbox + 1] = {
		id = U.Me() .. GetServerTime() .. math.random(1000, 9999),
		to = who, kind = kind, amount = copper,
	}
end

-- A finished round: what I owe / am owed from its transfers (amounts are whole gold).
function L.AddRound(round)
	if not round or round.practice then return nil end
	local transfers = round.result and round.result.transfers
	if not transfers then return nil end
	local book = L.Book()
	if round.id and book.rounds[round.id] then return nil end
	local me = U.Me()
	local changes = {}
	for _, t in ipairs(transfers) do
		if t.to == me and t.from ~= me then
			changes[#changes + 1] = { who = t.from, amount = t.amount * L.COPPER }
		elseif t.from == me and t.to ~= me then
			changes[#changes + 1] = { who = t.to, amount = -t.amount * L.COPPER }
		end
	end
	if #changes == 0 then return nil end
	if round.id then book.rounds[round.id] = true end
	for _, ch in ipairs(changes) do
		Add(ch.who, { kind = "round", amount = ch.amount, id = round.id, game = round.game })
	end
	Changed()
	return changes
end

-- A completed trade: I gave `gave` copper and got `got` copper.
function L.AddTrade(who, gave, got)
	gave, got = gave or 0, got or 0
	if gave == got then return end
	Add(who, { kind = "trade", amount = gave - got, gave = gave, got = got })
	Changed()
end

-- I confirm that `who` paid me `copper` of what they owed.
function L.Received(who, copper)
	if not Valid(copper) then return false, "Enter an amount." end
	if L.Balance(who) <= 0 then return false, "They don't owe you anything." end
	Add(who, { kind = "received", amount = -copper })
	Notice(who, "received", copper)
	Changed()
	return true
end

-- I forgive what `who` owes me (also when only their addon reports the debt).
function L.Forgive(who, copper)
	if not Valid(copper) then return false, "Enter an amount." end
	local bal = L.Balance(who)
	if bal <= 0 and (L.reported[who] or 0) <= 0 then return false, "They don't owe you anything." end
	local own = math.min(copper, math.max(0, bal))
	if own > 0 then Add(who, { kind = "forgive", amount = -own }) end
	Notice(who, "forgive", copper)
	Changed()
	return true
end

-- The debtor's own correction: I owe `who` another `copper`.
function L.AddDebt(who, copper)
	if not Valid(copper) then return false, "Enter an amount." end
	Add(who, { kind = "adjust", amount = -copper })
	Changed()
	return true
end
