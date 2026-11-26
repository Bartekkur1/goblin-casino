-- The ledger: who owes whom, from finished rounds, trades and manual corrections.
local World = require("wow")

local w = World.new()
local c = w:AddClient("Bika", "Selfbane")
w:Start()

local G = 10000 -- copper per gold
local L

-- Every test starts with an empty book.
local function fresh()
	c.env.GoblinCasinoDB.ledger = {}
	L = c.ns.Ledger
	L.reported = {}
end

local function round(id, from, to, gold)
	return { id = id, game = "wheel", result = { transfers = { { from = from, to = to, amount = gold } } } }
end

test("round: loser's tab shows the debt", function()
	fresh()
	L.AddRound(round("r1", "Bika", "Grom", 30))
	eq(L.Balance("Grom"), -30 * G, "balance")
end)

test("round: winner's tab shows what's owed", function()
	fresh()
	L.AddRound(round("r1", "Grom", "Bika", 30))
	eq(L.Balance("Grom"), 30 * G, "balance")
end)

test("round: sapper loser owes everyone", function()
	fresh()
	local r = { id = "r1", game = "sapper", result = { transfers = {
		{ from = "Bika", to = "Grom", amount = 10 },
		{ from = "Bika", to = "Zix", amount = 10 },
	} } }
	local changes = L.AddRound(r)
	eq(#changes, 2, "changes")
	eq(L.Balance("Grom"), -10 * G, "Grom")
	eq(L.Balance("Zix"), -10 * G, "Zix")
end)

test("practice rounds don't count", function()
	fresh()
	local r = round("r1", "Bika", "Grom", 30)
	r.practice = true
	eq(L.AddRound(r), nil, "result")
	eq(L.Known("Grom"), false, "known")
end)

test("the same round counts once", function()
	fresh()
	local r = round("r1", "Bika", "Grom", 30)
	check(L.AddRound(r), "first add")
	eq(L.AddRound(r), nil, "second add")
	eq(L.Balance("Grom"), -30 * G, "balance")
	c:Reload()
	L = c.ns.Ledger
	eq(L.AddRound(r), nil, "after reload")
	eq(L.Balance("Grom"), -30 * G, "balance after reload")
end)

test("old round ids are dropped, recent ones kept", function()
	fresh()
	local now = c.env.GetServerTime()
	local old = tostring(now - L.ROUND_KEEP - 60) .. "123"
	local recent = tostring(now - 60) .. "456"
	local rounds = L.Book().rounds
	rounds[old], rounds[recent], rounds.r9 = true, true, true
	c:Reload() -- pruning runs once a session
	L = c.ns.Ledger
	L.AddRound(round("r1", "Bika", "Grom", 5))
	rounds = L.Book().rounds
	eq(rounds[old], nil, "old id")
	check(rounds[recent], "recent id")
	check(rounds.r9, "id without a time")
	check(rounds.r1, "the new round")
end)

test("rounds and trades keep a known mismatch in step", function()
	fresh()
	L.mismatch = {}
	L.AddRound(round("r1", "Grom", "Bika", 30))
	L.reported.Grom = 20 * G
	L.mismatch.Grom = { mine = 30 * G, theirs = 20 * G }
	L.AddRound(round("r2", "Bika", "Grom", 5))
	eq(L.reported.Grom, 15 * G, "reported after the round")
	eq(L.mismatch.Grom.mine, 25 * G, "mine after the round")
	eq(L.mismatch.Grom.theirs, 15 * G, "theirs after the round")
	L.AddTrade("Grom", 0, 25 * G)
	eq(L.reported.Grom, -10 * G, "reported after the trade")
	eq(L.mismatch.Grom.mine, 0, "mine after the trade")
	eq(L.mismatch.Grom.theirs, -10 * G, "theirs after the trade")
	L.mismatch = {}
end)

test("rounds I didn't play don't count", function()
	fresh()
	eq(L.AddRound(round("r1", "Zix", "Grom", 30)), nil, "result")
	eq(L.Known("Grom"), false, "known")
end)

test("trade pays a debt, overpay flips it", function()
	fresh()
	L.AddRound(round("r1", "Bika", "Grom", 30))
	L.AddTrade("Grom", 20 * G, 0)
	eq(L.Balance("Grom"), -10 * G, "after first payment")
	L.AddTrade("Grom", 20 * G, 0)
	eq(L.Balance("Grom"), 10 * G, "after overpay")
end)

test("received only by the one who's owed", function()
	fresh()
	L.AddRound(round("r1", "Grom", "Bika", 30))
	check(L.Received("Grom", 30 * G), "received")
	eq(L.Balance("Grom"), 0, "balance")
	eq(#L.Book().outbox, 1, "notice queued")
	L.AddRound(round("r2", "Bika", "Grom", 5))
	eq(select(1, L.Received("Grom", 1)), false, "I owe Grom")
end)

test("forgive works on a reported debt", function()
	fresh()
	eq(select(1, L.Forgive("Grom", 30 * G)), false, "nothing reported")
	L.reported.Grom = 30 * G
	check(L.Forgive("Grom", 30 * G), "forgive")
	eq(L.Balance("Grom"), 0, "balance")
	eq(L.Known("Grom"), false, "no own entry")
end)

test("forgive on a real debt writes an entry", function()
	fresh()
	L.AddRound(round("r1", "Grom", "Bika", 30))
	check(L.Forgive("Grom", 10 * G), "forgive")
	eq(L.Balance("Grom"), 20 * G, "balance")
end)

test("add debt is against yourself", function()
	fresh()
	check(L.AddDebt("Grom", 5 * G), "add debt")
	eq(L.Balance("Grom"), -5 * G, "balance")
end)

test("add debt closes the gap their addon reported", function()
	fresh()
	L.mismatch = {}
	L.AddRound(round("r1", "Bika", "Grom", 20))
	L.mismatch.Grom = { mine = -20 * G, theirs = -30 * G }
	check(L.AddDebt("Grom", 4 * G), "part of the gap")
	eq(L.mismatch.Grom.mine, -24 * G, "gap left")
	check(L.AddDebt("Grom", 6 * G), "the rest")
	eq(L.mismatch.Grom, nil, "mismatch gone")
	eq(L.Balance("Grom"), -30 * G, "balance")
end)

test("people: I owe first, then owes me, then zero", function()
	fresh()
	L.AddRound(round("r1", "Grom", "Bika", 5))
	L.AddRound(round("r2", "Bika", "Zix", 5))
	L.AddRound(round("r3", "Bika", "Axe", 5))
	L.AddTrade("Mog", 1, 0)
	L.AddTrade("Mog", 0, 1)
	local p = L.People()
	eq(table.concat(p, ","), "Axe,Zix,Grom,Mog", "order")
end)

test("trimming keeps the balance", function()
	fresh()
	local expected = 0
	for i = 1, 250 do
		if i % 2 == 1 then
			local gold = i % 7 + 1
			L.AddRound(round("t" .. i, "Grom", "Bika", gold))
			expected = expected + gold * G
		else
			L.AddTrade("Grom", i, 3)
			expected = expected + i - 3
		end
	end
	eq(L.Balance("Grom"), expected, "balance")
	check(#L.Entries("Grom") <= L.MAX_ENTRIES + 1, "too many entries: " .. #L.Entries("Grom"))
	eq(L.Entries("Grom")[1].kind, "carry", "first entry")
end)

test("bad amounts are refused", function()
	fresh()
	L.AddRound(round("r1", "Grom", "Bika", 30))
	eq(select(1, L.Received("Grom", 0)), false, "zero")
	eq(select(1, L.Received("Grom", -5)), false, "negative")
	eq(select(1, L.Received("Grom", 1.5)), false, "fraction")
	eq(select(1, L.AddDebt("Grom", 0)), false, "debt zero")
	eq(L.Balance("Grom"), 30 * G, "unchanged")
end)

test("listeners hear every change", function()
	fresh()
	local n = 0
	L.OnChange(function() n = n + 1 end)
	L.AddDebt("Grom", 1)
	L.AddTrade("Grom", 5, 0)
	eq(n, 2, "calls")
end)

test("one tab per player, whatever form the name comes in", function()
	fresh()
	check(L.AddDebt("Grom-Realm", 5 * G), "name with a realm")
	check(L.AddDebt("Grom Ironfist", 5 * G), "name with a surname")
	eq(L.Balance("Grom"), -10 * G, "one tab")
	eq(#L.People(), 1, "one person")
	eq(select(1, L.AddDebt(nil, 5 * G)), false, "no name")
	eq(select(1, L.Received(nil, 5 * G)), false, "received from nobody")
	eq(L.Balance(nil), 0, "nobody's balance")
	eq(L.Known(nil), false, "nobody known")
end)

test("amounts that aren't real copper are refused", function()
	fresh()
	eq(select(1, L.AddDebt("Grom", math.huge)), false, "infinite")
	eq(select(1, L.AddDebt("Grom", 0 / 0)), false, "not a number")
	eq(select(1, L.AddDebt("Grom", 2 ^ 31)), false, "2^31")
	check(L.AddDebt("Grom", 2 ^ 31 - 1), "2^31 - 1")
	eq(L.Balance("Grom"), -(2 ^ 31 - 1), "balance")
end)

test("two notices in the same second get different ids", function()
	fresh()
	L.AddRound(round("r1", "Grom", "Bika", 30))
	check(L.Received("Grom", G), "first")
	check(L.Received("Grom", G), "second")
	local box = L.Book().outbox
	eq(#box, 2, "notices")
	check(box[1].id ~= box[2].id, "same id twice: " .. tostring(box[1].id))
end)
