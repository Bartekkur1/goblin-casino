-- Hot Sapper: a lit Goblin Sapper Charge goes round the circle of players; the one holding it when
-- it blows up pays every other player the entry fee. Everyone pays the same entry, everyone has the
-- same 1-in-n chance to be the loser, so the expected value is 0 for every player:
--   (n-1)/n * entry - 1/n * (n-1) * entry = 0
-- Fairness and show are kept apart, as in the derby:
--   1. the loser is drawn uniformly from the seed of everyone's /roll;
--   2. a script of passes is generated from the same seed that ends in the loser's hands: who gets
--      the charge when, faster and faster, with a "fizzle" or two. It never changes the loser.
local ADDON, ns = ...
local U, J = ns.Util, ns.Jackpot

local S = {}
ns.Sapper = S

S.MAX_PLAYERS = 12
S.START_DELAY = 3     -- "3, 2, 1" before the fuse is lit
S.LAST_HOLD = 2.2     -- the loser holds it this long before it blows
S.AFTER = 3.5         -- seconds of aftermath before the settlement
S.FIZZLE = 2.4        -- extra seconds a fizzle adds to a hold

---------------------------------------------------------------------------
-- Result: one loser, who pays everyone else the entry.
---------------------------------------------------------------------------
local function Compute(bets, rolls)
	local names = U.SortedKeys(bets)
	local parts = {}
	for _, name in ipairs(names) do
		parts[#parts + 1] = name .. ":" .. bets[name] .. ":" .. (rolls[name] or 0) .. ";"
	end
	local seed = U.FNV1a("sapper;" .. table.concat(parts))
	local rng = U.NewRNG(seed)
	local loser = names[rng:Int(#names) + 1]
	local entry = bets[loser]
	local transfers = {}
	for _, name in ipairs(names) do
		if name ~= loser then
			transfers[#transfers + 1] = { from = loser, to = name, amount = entry }
		end
	end
	return {
		seed = seed,
		names = names,
		total = entry * (#names - 1),       -- what changes hands (shown as the pot in history)
		loser = loser,
		gain = entry,                       -- what every other player gets
		transfers = transfers,
		scriptSeed = rng:Next(),
	}
end

---------------------------------------------------------------------------
-- The show: who holds the charge when. Same on every client (seeded), cached per round.
--   steps[k] = { who, from, depart, land, leave, fizzle }
--     the charge flies from `from` (depart -> land), then `who` holds it until `leave`
--   boom = when it blows up (in the loser's hands); times in seconds after the fuse is lit
---------------------------------------------------------------------------
local cache = {}

local function Rand(rng, a, b)
	return a + (b - a) * (rng:Int(10000) / 10000)
end

function S.Script(round)
	local res = round.result
	local key = round.id .. ":" .. res.seed
	if cache[key] then return cache[key] end
	local rng = U.NewRNG(res.scriptSeed or res.seed)
	local names = res.names
	local n = #names

	-- who holds it, backwards from the loser; never straight back to the same player
	local holds = n == 2 and (9 + rng:Int(4)) or (12 + rng:Int(7))
	local holders = {}
	holders[holds] = res.loser
	for k = holds - 1, 1, -1 do
		local pick
		repeat pick = names[rng:Int(n) + 1] until pick ~= holders[k + 1]
		holders[k] = pick
	end
	-- a fizzle or two in the middle, never in the last three holds
	local fizzle = {}
	local count = (holds >= 12 and rng:Int(2) == 0) and 2 or 1
	for _ = 1, count do
		local k = math.floor(holds * 0.3) + rng:Int(math.max(1, math.floor(holds * 0.4))) + 1
		if k < holds - 2 then fizzle[k] = true end
	end

	local steps, events = {}, { { t = 0, text = "The fuse is lit!", kind = "start" } }
	local t = 0
	for k = 1, holds do
		local p = (k - 1) / math.max(1, holds - 1)
		local flight = k == 1 and 0 or (0.46 - 0.2 * p)
		local hold = math.max(0.18, 1.15 - 0.95 * p ^ 0.75 + Rand(rng, -0.08, 0.08))
		if fizzle[k] then hold = hold + S.FIZZLE end
		if k == holds then hold = S.LAST_HOLD end
		local step = {
			who = holders[k], from = holders[k - 1] or holders[k],
			depart = t, land = t + flight, fizzle = fizzle[k],
		}
		step.leave = step.land + hold
		steps[k] = step
		if fizzle[k] then
			events[#events + 1] = { t = step.land + 0.35, text = "Fizzled on " .. U.Short(step.who) .. "... phew!", kind = "fizzle", who = step.who }
			events[#events + 1] = { t = step.land + S.FIZZLE - 0.2, text = "...NO WAIT, IT'S LIT AGAIN!", kind = "relit", who = step.who }
		end
		if k == math.floor(holds * 0.6) then
			events[#events + 1] = { t = step.land, text = "It's ticking faster!", kind = "faster" }
		end
		if k == holds then
			events[#events + 1] = { t = step.land, text = U.Short(step.who) .. " has it...", kind = "last", who = step.who }
		end
		t = step.leave
	end
	local script = { steps = steps, boom = t, events = events, loser = res.loser }
	events[#events + 1] = { t = t, text = "BOOM! " .. U.Short(res.loser) .. " blew up!", kind = "boom", who = res.loser }
	table.sort(events, function(a, b)
		if a.t ~= b.t then return a.t < b.t end
		return a.text < b.text
	end)
	cache[key] = script
	return script
end

-- Where the charge is at time t (seconds after the fuse is lit):
--   holder name, or from, to and the flight fraction; plus whether the fuse is out (fizzle)
function S.At(script, t)
	local steps = script.steps
	if t < 0 then return steps[1].who end
	for k, step in ipairs(steps) do
		if t < step.land then
			return nil, step.from, step.who, (t - step.depart) / math.max(0.01, step.land - step.depart), k
		elseif t < step.leave then
			local out = step.fizzle and t > step.land + 0.3 and t < step.land + S.FIZZLE - 0.2
			return step.who, nil, nil, nil, k, out
		end
	end
	return script.loser, nil, nil, nil, #steps
end

J.RegisterGame("sapper", {
	title = "Hot Sapper",
	Compute = Compute,
	duration = function(round) return S.START_DELAY + S.Script(round).boom + S.AFTER end,
	loseVerb = "blew up",
	limitKey = "sapperEntry",
	defaultLimit = 10,
	fixed = true,
	maxPlayers = S.MAX_PLAYERS,
	bots = { 3, 6 },
})
