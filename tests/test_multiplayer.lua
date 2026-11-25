-- Whole rounds played by several clients in one group, through addon messages and /roll lines,
-- including the awkward moments: a /reload, someone leaving, the host going offline, a raid of 20.
-- Every client must end with the same result, and nobody may hit a Lua error.
local World = require("wow")

local NAMES = { "Bika", "Hymel", "Zork", "Anna", "Kix", "Morgana", "Tirion", "Garrosh", "Velen", "Jaina",
	"Thrall", "Sylvanas", "Varian", "Malfurion", "Tyrande", "Illidan", "Arthas", "Uther", "Rexxar", "Chen" }
local SURNAMES = { "Selfbane", "Jádwiga", "Ironfist", "Brightwater", "Fizzbolt" }
local GAMES = { "wheel", "derby", "sapper", "onyxia", "brewfest" }
local FIXED = { derby = true, sapper = true, brewfest = true }

-- A group of n players (the first one hosts); names can be made longer to force long messages.
local function Group(n, longNames)
	local w = World.new()
	local cs = {}
	for i = 1, n do
		local name = NAMES[i] .. (longNames and "thalasar" or "")
		cs[i] = w:AddClient(name, SURNAMES[(i - 1) % #SURNAMES + 1])
	end
	w:Start()
	return w, cs
end

local function NoErrors(w)
	local errors = w:Errors()
	eq(#errors, 0, "Lua errors:\n" .. table.concat(errors, "\n"))
end

local function Open(w, host, game, limit)
	local ok, err = host.J.Open(false, game)
	check(ok, "open: " .. tostring(err))
	ok, err = host.J.SetLimit(limit)
	check(ok, "limit: " .. tostring(err))
	ok, err = host.J.OpenBets()
	check(ok, "open bets: " .. tostring(err))
	w:Run(0.5)
end

local function Bet(w, c, amount)
	local ok, err = c.J.Bet(amount)
	check(ok, c.name .. " can't bet: " .. tostring(err))
	w:Run(0.3)
end

local function BetAll(w, cs, game, limit)
	for i, c in ipairs(cs) do
		Bet(w, c, FIXED[game] and limit or math.max(1, limit - i * 7))
	end
end

local function Lock(w, host)
	local ok, err = host.J.Lock()
	check(ok, "lock: " .. tostring(err))
	w:Run(0.5)
end

local function RollAll(w, cs, except)
	for _, c in ipairs(cs) do
		if c ~= except then
			check(c.J.round and c.J.round.phase == "ROLLING", c.name .. " isn't rolling (" ..
				tostring(c.J.round and c.J.round.phase) .. ")")
			c.J.RollNow()
		end
	end
	w:Run(1)
end

-- Runs the show to its end and checks every client in `cs` agrees on the finished round.
local function Finish(w, cs, seconds)
	w:Run(seconds or 120)
	local host = cs[1]
	local hr = host.J.round
	check(hr and hr.phase == "DONE", "the host's round isn't DONE (" .. tostring(hr and hr.phase) .. ")")
	local expected = serialize({ hr.result.winner, hr.result.loser, hr.result.transfers, hr.result.seed })
	for _, c in ipairs(cs) do
		local r = c.J.round
		check(r and r.id == hr.id, c.name .. " has another round")
		eq(r.phase, "DONE", c.name .. "'s phase")
		eq(serialize({ r.result.winner, r.result.loser, r.result.transfers, r.result.seed }), expected, c.name .. "'s result")
		eq(r.warning, nil, c.name .. "'s warning")
		local entries = 0
		for _, e in ipairs(c:History()) do
			if e.id == hr.id then entries = entries + 1 end
		end
		eq(entries, 1, c.name .. "'s history entries for the round")
	end
	NoErrors(w)
	return hr
end

---------------------------------------------------------------------------
for _, game in ipairs(GAMES) do
	test(game .. ": 3 players play a whole round and agree on the result", function()
		local w, cs = Group(3)
		Open(w, cs[1], game, 50)
		for _, c in ipairs(cs) do
			check(c.J.round and c.J.round.phase == "BETTING", c.name .. " doesn't see the open round")
		end
		BetAll(w, cs, game, 50)
		Lock(w, cs[1])
		RollAll(w, cs)
		local round = Finish(w, cs)
		-- whoever pays was told so in chat
		local res = round.result
		local payer = res.loser or (res.transfers[1] and res.transfers[1].from)
		for _, c in ipairs(cs) do
			if c.U.Me() == payer then check(c:Printed("You owe"), c.name .. " wasn't told to pay") end
		end
	end)

	test(game .. ": practice round with bots", function()
		local w = World.new()
		local c = w:AddClient("Solo")
		w:Start()
		check(c.J.Open(true, game), "open")
		check(c.J.OpenBets(), "open bets")
		w:Run(8) -- the bots join
		check(c.J.Bet(c.J.round.limit), "bet")
		check(c.J.Lock(), "lock")
		c.J.RollNow()
		w:Run(120)
		eq(c.J.round.phase, "DONE", "phase")
		local last = c:History()[#c:History()]
		check(last and last.practice, "practice round recorded as practice")
		NoErrors(w)
	end)
end

test("a player who doesn't roll gets a roll from the host", function()
	local w, cs = Group(3)
	Open(w, cs[1], "wheel", 100)
	BetAll(w, cs, "wheel", 100)
	Lock(w, cs[1])
	RollAll(w, cs, cs[3])
	w:Run(40) -- the 30 seconds pass, the host rolls for Zork
	local round = Finish(w, cs)
	check(round.subs[cs[3].U.Me()], "Zork's roll is marked as made by the host")
end)

test("reload while betting: the player is back in the round with their bet", function()
	local w, cs = Group(3)
	Open(w, cs[1], "wheel", 100)
	BetAll(w, cs, "wheel", 100)
	cs[2]:Reload()
	eq(cs[2].J.round, nil, "the round is gone right after the reload")
	w:Run(6)
	local r = cs[2].J.round
	check(r and r.phase == "BETTING", "the round came back")
	eq(r.bets[cs[2].U.Me()], cs[1].J.round.bets[cs[2].U.Me()], "with the bet the host has")
	Lock(w, cs[1])
	RollAll(w, cs)
	Finish(w, cs)
end)

test("reload while rolling: the player can still roll and sees the result", function()
	local w, cs = Group(3)
	Open(w, cs[1], "sapper", 20)
	BetAll(w, cs, "sapper", 20)
	Lock(w, cs[1])
	cs[2]:Reload()
	w:Run(6)
	check(cs[2].J.round and cs[2].J.round.phase == "ROLLING", "back in the rolls")
	RollAll(w, cs)
	Finish(w, cs)
end)

test("reload during the show: the result comes back and isn't recorded twice", function()
	local w, cs = Group(3)
	Open(w, cs[1], "derby", 20)
	BetAll(w, cs, "derby", 20)
	Lock(w, cs[1])
	RollAll(w, cs)
	check(cs[2].J.round.phase == "SPINNING", "the race is on")
	cs[2]:Reload()
	w:Run(6)
	check(cs[2].J.round and cs[2].J.round.phase == "SPINNING", "the race came back")
	Finish(w, cs)
end)

test("host reloads while betting: the players' round is cancelled", function()
	local w, cs = Group(3)
	Open(w, cs[1], "wheel", 100)
	BetAll(w, cs, "wheel", 100)
	cs[1]:Reload()
	w:Run(6)
	for i = 2, 3 do eq(cs[i].J.round.phase, "CANCELLED", cs[i].name .. "'s round") end
	NoErrors(w)
end)

test("a bettor who leaves the group is dropped from the round", function()
	local w, cs = Group(4)
	Open(w, cs[1], "onyxia", 100)
	BetAll(w, cs, "onyxia", 100)
	local gone = cs[4]
	gone.inGroup = false
	w:RosterChanged()
	w:Run(1)
	eq(cs[1].J.round.bets[gone.U.Me()], nil, "the host dropped the bet")
	eq(gone.J.round.phase, "CANCELLED", "the round of the player who left")
	Lock(w, cs[1])
	local stay = { cs[1], cs[2], cs[3] }
	for _, c in ipairs(stay) do eq(c.J.round.bets[gone.U.Me()], nil, c.name .. " still counts the bet") end
	RollAll(w, stay)
	Finish(w, stay)
end)

test("host goes offline: the players' round is cancelled", function()
	local w, cs = Group(3)
	Open(w, cs[1], "wheel", 100)
	BetAll(w, cs, "wheel", 100)
	cs[1].online = false
	w:RosterChanged()
	w:Run(4)
	for i = 2, 3 do eq(cs[i].J.round.phase, "CANCELLED", cs[i].name .. "'s round") end
	NoErrors(w)
end)

test("raid of 20 with long names: long messages arrive in parts", function()
	local w, cs = Group(20, true)
	Open(w, cs[1], "onyxia", 999999)
	BetAll(w, cs, "onyxia", 999999)
	Lock(w, cs[1])
	RollAll(w, cs)
	Finish(w, cs)
end)

test("messages wait while the game blocks them, and go out after", function()
	local w, cs = Group(2)
	local host = cs[1]
	host.restricted = true
	local sent = false
	host.Comm.Send("Z", "waiting")
	host.Comm.Flushed(function() sent = true end)
	w:Run(2)
	check(not sent, "sent while blocked")
	host.restricted = false
	w:Run(1)
	check(sent, "never sent after the block ended")
	NoErrors(w)
end)

test("players who join a round late can't bet once it's full", function()
	local w, cs = Group(13)
	Open(w, cs[1], "sapper", 10)
	for i = 1, 12 do Bet(w, cs[i], 10) end
	local ok = cs[13].J.Bet(10)
	check(not ok, "a 13th player joined Hot Sapper")
	NoErrors(w)
end)

---------------------------------------------------------------------------
-- Brewfest Brawl: every mug is a /roll 10-35, players stop when they like
---------------------------------------------------------------------------
local function Brew(c) return c.ns.Brewfest end

local function BrewRound(n)
	local w, cs = Group(n)
	Open(w, cs[1], "brewfest", 20)
	BetAll(w, cs, "brewfest", 20)
	Lock(w, cs[1])
	return w, cs
end

local function Drink(w, c, mugs)
	for i = 1, mugs do
		local ok, err = Brew(c).Drink()
		check(ok, c.name .. " can't drink mug " .. i .. ": " .. tostring(err))
		w:Run(0.5)
	end
end

test("brewfest: the drunkest one still standing wins, the same on every client", function()
	local w, cs = BrewRound(3)
	w.nextRoll = function() return 30 end
	Drink(w, cs[1], 3)                      -- Bika 90%
	check(Brew(cs[1]).Stop(), "Bika stops")
	Drink(w, cs[2], 4)                      -- Hymel 120%: under the table
	check(not Brew(cs[2]).Drink(), "Hymel drinks under the table")
	Drink(w, cs[3], 1)                      -- Zork 30%
	check(Brew(cs[3]).Stop(), "Zork stops")
	w:Run(1.5) -- everyone is done: the host closes the bar
	for _, c in ipairs(cs) do eq(c.J.round.phase, "SPINNING", c.name .. "'s phase") end
	local round = Finish(w, cs)
	eq(round.result.winner, cs[1].U.Me(), "winner")
	eq(round.result.sums[cs[2].U.Me()], 120, "Hymel's total")
	eq(#round.result.transfers, 2, "both others pay")
end)

test("brewfest: everyone under the table, the one who went over the least wins", function()
	local w, cs = BrewRound(3)
	w.nextRoll = function(c) return c == cs[2] and 34 or 35 end
	for _, c in ipairs(cs) do Drink(w, c, 3) end -- 105, 102, 105
	w:Run(1.5)
	local round = Finish(w, cs)
	eq(round.result.winner, cs[2].U.Me(), "winner")
	eq(round.result.standing, false, "nobody standing")
end)

test("brewfest: when time runs out, whoever is still drinking stops where they are", function()
	local w, cs = BrewRound(3)
	w.nextRoll = function() return 30 end
	Drink(w, cs[1], 2)                      -- 60%, never says enough
	Drink(w, cs[2], 1)                      -- 30%
	check(Brew(cs[2]).Stop(), "Hymel stops")
	w:Run(45)                               -- the taps close (40 s and the grace)
	local round = Finish(w, cs)
	eq(round.result.winner, cs[1].U.Me(), "winner")
	eq(round.result.sums[cs[3].U.Me()], 0, "Zork never drank")
end)

test("brewfest: a mug can't be drunk before the last one arrived, nor after stopping", function()
	local w, cs = BrewRound(2)
	check(Brew(cs[1]).Drink(), "first mug")
	check(not Brew(cs[1]).Drink(), "second mug while the first is on its way")
	w:Run(0.5)
	check(Brew(cs[1]).Stop(), "stop")
	check(not Brew(cs[1]).Drink(), "a mug after stopping")
	NoErrors(w)
end)
