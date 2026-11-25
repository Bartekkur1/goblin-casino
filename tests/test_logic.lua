-- The engine's building blocks and every game's result: money adds up, the right player wins as
-- often as they should, and the same bets and rolls give the same result whatever order they came in.
local World = require("wow")

local w = World.new()
local c = w:AddClient("Bika", "Selfbane")
w:Start()
local U, J, Rolls, ns = c.U, c.J, c.Rolls, c.ns

---------------------------------------------------------------------------
-- Hash and random numbers (they decide who wins, so they must match the reference values)
---------------------------------------------------------------------------
test("FNV-1a matches the reference values", function()
	eq(U.FNV1a(""), 2166136261, "empty string")
	eq(U.FNV1a("a"), 3826002220, "'a'")
	eq(U.FNV1a("foobar"), 3214735720, "'foobar'")
end)

test("Park-Miller generator matches minstd_rand", function()
	local rng = U.NewRNG(0) -- state 1, like minstd_rand's default seed
	local v
	for _ = 1, 10000 do v = rng:Next() end
	eq(v, 399268537, "10000th number")
end)

test("rng:Int stays in range and reaches every value", function()
	local rng = U.NewRNG(12345)
	for _, n in ipairs({ 1, 2, 3, 7, 100, 999999 * 20 }) do
		local seen = {}
		for _ = 1, 400 do
			local r = rng:Int(n)
			check(r >= 0 and r < n and r == math.floor(r), "Int(" .. n .. ") gave " .. r)
			seen[r] = true
		end
		if n <= 7 then
			for i = 0, n - 1 do check(seen[i], "Int(" .. n .. ") never gave " .. i) end
		end
	end
end)

test("byte order sorting doesn't depend on the locale", function()
	local keys = U.SortedKeys({ b = 1, B = 1, a = 1, ["Ä"] = 1, A = 1, aa = 1 })
	eq(table.concat(keys, " "), "A B a aa b Ä", "order")
end)

---------------------------------------------------------------------------
-- Player names: one key per player, whatever form the client used
---------------------------------------------------------------------------
test("names: every form of a Forever name gives the same key", function()
	for _, form in ipairs({ "Bika", "Bika Selfbane", "Bika-Realm", "  Bika  ", "Bika-Some Realm" }) do
		eq(U.Canonical(form), "Bika", form)
	end
	eq(U.Canonical("Hymel Jádwiga"), "Hymel", "surname with accents")
	eq(U.Canonical(nil), nil, "nil")
	eq(U.Canonical(""), nil, "empty")
	eq(U.Me(), "Bika", "the player")
	eq(U.Short("Bika-Realm"), "Bika", "short name")
end)

---------------------------------------------------------------------------
-- /roll lines from system chat
---------------------------------------------------------------------------
test("roll lines are read in every form Forever writes them", function()
	local cases = {
		{ "Bika rolls 523 (1-1000000)", 523 },
		{ "Bika Selfbane rolls 1 (1-1000000)", 1 },
		{ "|Hplayer:Bika-Realm|h[Bika]|h rolls 5 (1-1,000,000)", 5 },
		{ "|cffffffffBika Selfbane|r rolls 1,234 (1-1,000,000)", 1234 },
		{ "[Raid] Bika Selfbane rolls 77 (1-1000000)", 77 },
		{ "|TInterface\\Icons\\INV_Misc_Dice_01:0|t Bika rolls 9 (1-1000000)", 9 },
		{ "Bika rolls 1.000.000 (1-1.000.000)", 1000000 },
	}
	for _, case in ipairs(cases) do
		local name, roll, lo, hi = Rolls.Parse(case[1])
		eq(name, "Bika", case[1])
		eq(roll, case[2], case[1])
		eq(lo, 1, case[1])
		eq(hi, 1000000, case[1])
	end
	eq(Rolls.Parse("Bika has gone offline."), nil, "not a roll")
	eq(Rolls.Parse(nil), nil, "nil")
end)

---------------------------------------------------------------------------
-- Results of every game
---------------------------------------------------------------------------
local NAMES = { "Bika", "Hymel", "Zork", "Anna", "Kix", "Morgana", "Tirion", "Garrosh", "Velen", "Jaina",
	"Thrall", "Sylvanas", "Varian", "Malfurion", "Tyrande", "Illidan", "Arthas", "Uther", "Rexxar", "Chen" }

local seq = 777
local function Random(lo, hi)
	seq = (seq * 48271) % 2147483647
	return lo + seq % (hi - lo + 1)
end

-- n players with stakes (all equal for fixed-entry games) and their rolls
local function Round(n, fixed)
	local bets, rolls = {}, {}
	local entry = Random(1, 500)
	for i = 1, n do
		local name = NAMES[i]
		bets[name] = fixed and entry or Random(1, 999999)
		rolls[name] = Random(1, 1000000)
	end
	return bets, rolls
end

local function Sum(transfers)
	local s = 0
	for _, t in ipairs(transfers) do s = s + t.amount end
	return s
end

local function IsPermutation(list, of)
	if #list ~= #of then return false end
	local count = {}
	for _, v in ipairs(of) do count[v] = (count[v] or 0) + 1 end
	for _, v in ipairs(list) do
		if not count[v] or count[v] == 0 then return false end
		count[v] = count[v] - 1
	end
	return true
end

-- winner games: everyone else pays the winner their own stake
local function CheckWinner(res, bets, what)
	local n = 0
	for _ in pairs(bets) do n = n + 1 end
	check(bets[res.winner], what .. ": the winner has a bet")
	eq(res.loser, nil, what .. ": no loser")
	eq(#res.transfers, n - 1, what .. ": transfers")
	local total = 0
	for _, b in pairs(bets) do total = total + b end
	eq(res.total, total, what .. ": pot")
	eq(res.gain, total - bets[res.winner], what .. ": winner's gain")
	eq(Sum(res.transfers), res.gain, what .. ": transfers add up to the gain")
	for _, t in ipairs(res.transfers) do
		eq(t.to, res.winner, what .. ": paid to the winner")
		check(t.from ~= res.winner, what .. ": the winner doesn't pay")
		eq(t.amount, bets[t.from], what .. ": each pays their own stake")
	end
end

test("Ogre's Wheel: money adds up for 2 to 20 players", function()
	local Compute = J.games.wheel.Compute
	for _ = 1, 150 do
		local bets, rolls = Round(Random(2, 20))
		CheckWinner(Compute(bets, rolls), bets, "wheel")
	end
end)

test("Murloc Derby: money adds up and the finish order is a real order", function()
	local Compute = J.games.derby.Compute
	for _ = 1, 150 do
		local bets, rolls = Round(Random(2, 20), true)
		local res = Compute(bets, rolls)
		CheckWinner(res, bets, "derby")
		eq(res.order[1], res.winner, "derby: the winner finishes first")
		check(IsPermutation(res.order, res.names), "derby: everyone runs once")
	end
end)

test("Murloc Derby: the race script keeps the finish order and murloc names are unique", function()
	local Compute, D = J.games.derby.Compute, ns.Derby
	for i = 1, 30 do
		local bets, rolls = Round(Random(2, 20), true)
		local round = { id = "derby" .. i, bets = bets, result = Compute(bets, rolls) }
		local script = D.Script(round)
		local res = round.result
		for rank = 2, #res.order do
			check(script.finish[res.order[rank]] > script.finish[res.order[rank - 1]], "finish times follow the order")
		end
		eq(script.events[#script.events].kind, "finish", "the finish is the last line")
		local used = {}
		for _, a in pairs(D.Assign(round)) do
			check(not used[a.murloc], "murloc name used twice: " .. a.murloc)
			used[a.murloc] = true
		end
	end
end)

test("Onyxia: money adds up, the survivor never burns, everyone else does", function()
	local Compute, O = J.games.onyxia.Compute, ns.Onyxia
	for i = 1, 150 do
		local bets, rolls = Round(Random(2, 20))
		local res = Compute(bets, rolls)
		CheckWinner(res, bets, "onyxia")
		local others = {}
		for _, name in ipairs(res.names) do
			if name ~= res.winner then others[#others + 1] = name end
		end
		check(IsPermutation(res.burn, others), "onyxia: everyone but the survivor burns once")
		local script = O.Script({ id = "ony" .. i, bets = bets, result = res })
		eq(script.diesAt[res.winner], nil, "onyxia: the survivor has no breath")
		for _, name in ipairs(res.burn) do check(script.diesAt[name], "onyxia: " .. name .. " never burns") end
		local final = script.waves[#script.waves]
		check(final.final, "onyxia: the last breath is the 1 vs 1")
		eq(final.victims[1], res.burn[#res.burn], "onyxia: the last to burn is in the final")
		for k = 2, #script.events do
			check(script.events[k].t >= script.events[k - 1].t, "onyxia: commentary in time order")
		end
		local whelps = false
		for _, ev in ipairs(script.events) do whelps = whelps or ev.kind == "whelps" end
		eq(whelps, #script.waves - 1 >= 3, "onyxia: whelps exactly when there are 3 or more breaths")
	end
end)

test("Hot Sapper: the loser pays everyone the entry", function()
	local Compute = J.games.sapper.Compute
	for _ = 1, 150 do
		local bets, rolls = Round(Random(2, 12), true)
		local res = Compute(bets, rolls)
		local entry = bets[res.loser]
		check(entry, "sapper: the loser has an entry")
		eq(res.winner, nil, "sapper: no winner")
		eq(#res.transfers, #res.names - 1, "sapper: one payment per other player")
		eq(res.gain, entry, "sapper: each gets the entry")
		eq(res.total, entry * (#res.names - 1), "sapper: what changes hands")
		eq(Sum(res.transfers), res.total, "sapper: payments add up")
		for _, t in ipairs(res.transfers) do
			eq(t.from, res.loser, "sapper: only the loser pays")
			check(t.to ~= res.loser, "sapper: the loser doesn't pay themselves")
			eq(t.amount, entry, "sapper: the entry")
		end
	end
end)

test("Hot Sapper: the charge ends in the loser's hands and never goes straight back", function()
	local Compute, S = J.games.sapper.Compute, ns.Sapper
	for i = 1, 60 do
		local bets, rolls = Round(Random(2, 12), true)
		local res = Compute(bets, rolls)
		local script = S.Script({ id = "sap" .. i, bets = bets, result = res })
		local steps = script.steps
		eq(steps[#steps].who, res.loser, "the last holder")
		for k, step in ipairs(steps) do
			if k > 1 then
				check(step.who ~= steps[k - 1].who, "the charge went straight back")
				eq(step.depart, steps[k - 1].leave, "flights follow each other")
			end
			check(step.depart <= step.land and step.land < step.leave, "step times in order")
			check(not (step.fizzle and k > #steps - 3), "a fizzle in the last three holds")
		end
		eq(S.At(script, script.boom - 0.01), res.loser, "who holds it just before the blast")
		eq(S.At(script, script.boom + 1), res.loser, "who holds it after the blast")
	end
end)

test("Brewfest Brawl: the drunkest one standing wins, else the one who went over the least", function()
	local Compute = J.games.brewfest.Compute
	for _ = 1, 150 do
		local n = Random(2, 12)
		local bets, drinks = {}, {}
		for i = 1, n do
			bets[NAMES[i]] = 25
			local list = {}
			for _ = 1, Random(0, 6) do list[#list + 1] = Random(10, 35) end
			drinks[NAMES[i]] = list
		end
		local res = Compute(bets, drinks)
		CheckWinner(res, bets, "brewfest")
		local best, standing = nil, false
		for _, s in pairs(res.sums) do standing = standing or s <= 100 end
		for _, s in pairs(res.sums) do
			if standing and s <= 100 and (not best or s > best) then best = s end
			if not standing and (not best or s < best) then best = s end
		end
		eq(res.sums[res.winner], best, "brewfest: the winner's total")
		eq(res.standing, standing, "brewfest: someone standing")
	end
end)

---------------------------------------------------------------------------
-- Fairness: chances follow the stakes (wheel, Onyxia) or are equal (derby, sapper)
---------------------------------------------------------------------------
local function Share(game, bets, who, trials)
	local Compute, hits = J.games[game].Compute, 0
	for _ = 1, trials do
		local rolls = {}
		for name in pairs(bets) do rolls[name] = Random(1, 1000000) end
		local res = Compute(bets, rolls)
		if (res.loser or res.winner) == who then hits = hits + 1 end
	end
	return hits / trials
end

test("fairness: a 3x stake wins 3x as often (wheel and Onyxia)", function()
	for _, game in ipairs({ "wheel", "onyxia" }) do
		local share = Share(game, { Anna = 100, Zork = 300 }, "Zork", 4000)
		check(share > 0.72 and share < 0.78, game .. ": the 300g player won " .. share .. " of rounds, expected 0.75")
	end
end)

test("fairness: equal chances in fixed-entry games (derby and sapper)", function()
	for _, game in ipairs({ "derby", "sapper" }) do
		local share = Share(game, { Anna = 10, Bika = 10, Kix = 10, Zork = 10 }, "Kix", 4000)
		check(share > 0.22 and share < 0.28, game .. ": one of 4 players was picked " .. share .. " of rounds, expected 0.25")
	end
end)

---------------------------------------------------------------------------
-- Every client computes the result alone: the order bets arrived in must not matter
---------------------------------------------------------------------------
test("same bets and rolls give the same result in any insertion order", function()
	for _, game in ipairs({ "wheel", "derby", "sapper", "onyxia" }) do
		local Compute = J.games[game].Compute
		for _ = 1, 20 do
			local bets, rolls = Round(Random(2, 12), game == "derby" or game == "sapper")
			local names = U.SortedKeys(bets)
			-- the same content built in reverse, with other keys added and removed on the way
			local bets2, rolls2 = {}, {}
			for i = #names, 1, -1 do
				bets2["tmp" .. i] = 1
				bets2[names[i]], rolls2[names[i]] = bets[names[i]], rolls[names[i]]
			end
			for i = 1, #names do bets2["tmp" .. i] = nil end
			eq(serialize(Compute(bets2, rolls2)), serialize(Compute(bets, rolls)), game .. " result")
		end
	end
end)

test("no Lua errors while loading", function()
	eq(#w:Errors(), 0, table.concat(w:Errors(), "\n"))
end)
