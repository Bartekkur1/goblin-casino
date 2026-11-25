-- Onyxia's Deep Breath: the raid stands on Onyxia's platform, she breathes fire in waves, and the
-- last raider alive takes the pot. Any stake up to the host's limit: your chance to survive is your
-- share of the pot (the "Onyxia Scale Cloak" shown under each raider), and every other player pays
-- the survivor their own stake, as in Ogre's Wheel. Expected value is 0 for everyone:
--   p = stake / pot,  p * (pot - stake) - (1 - p) * stake = 0
-- Fairness and show are kept apart:
--   1. the survivor is drawn from the seed of everyone's /roll, weighted by stake;
--   2. the order in which the others burn is a seeded shuffle, and the waves (how many burn in each
--      breath, false alarms, the final 1 vs 1) are a script for that order. Only (1) decides money.
local ADDON, ns = ...
local U, J = ns.Util, ns.Jackpot

local O = {}
ns.Onyxia = O

O.MAX_PLAYERS = 20
O.START_DELAY = 3
O.INTRO = 4.5       -- she lands and taunts
O.WAVE = 5.4        -- one deep breath: warnings, breath, aftermath
O.FINAL = 7.5       -- the last breath, 1 vs 1
O.BREATH = 2.4      -- seconds into a wave when the fire comes
O.FINAL_BREATH = 4.6
O.SWEEP = 1.1       -- the fire crosses the raid in this many seconds
O.WIN = 4.5         -- the survivor celebrates before the settlement
-- Onyxia's model (creature display IDs, the first one that loads is used; check with /casino models)
O.DISPLAYS = { 8570, 11380 }

---------------------------------------------------------------------------
-- Result: the survivor (weighted by stake) and the order the others burn in
---------------------------------------------------------------------------
local function Compute(bets, rolls)
	local names = U.SortedKeys(bets)
	local parts, total = {}, 0
	for _, name in ipairs(names) do
		parts[#parts + 1] = name .. ":" .. bets[name] .. ":" .. (rolls[name] or 0) .. ";"
		total = total + bets[name]
	end
	local seed = U.FNV1a("onyxia;" .. table.concat(parts))
	local rng = U.NewRNG(seed)
	local r = rng:Int(total)
	local winner, acc = names[#names], 0
	for _, name in ipairs(names) do
		if r < acc + bets[name] then winner = name; break end
		acc = acc + bets[name]
	end
	local transfers, others = {}, {}
	for _, name in ipairs(names) do
		if name ~= winner then
			transfers[#transfers + 1] = { from = name, to = winner, amount = bets[name] }
			others[#others + 1] = name
		end
	end
	table.sort(transfers, function(a, b)
		if a.amount ~= b.amount then return a.amount > b.amount end
		return U.ByteLess(a.from, b.from)
	end)
	-- burn order: first in the list burns first
	for i = #others, 2, -1 do
		local j = rng:Int(i) + 1
		others[i], others[j] = others[j], others[i]
	end
	return {
		seed = seed,
		names = names,
		total = total,
		winner = winner,
		transfers = transfers,
		gain = total - bets[winner],
		burn = others,
		scriptSeed = rng:Next(),
	}
end

---------------------------------------------------------------------------
-- The show (same on every client, cached per round)
--   waves[i] = { start, breathAt, victims = {names}, warnings = { {t, name}, ... }, final }
--   events   = commentary { t, text, kind }
--   winAt    = when the survivor is alone
---------------------------------------------------------------------------
local cache = {}

local TAUNTS = {
	"How fortuitous. Usually, I must leave my lair in order to feed.",
	"Learn your place, mortals!",
	"I'll incinerate you from above!",
}

function O.Script(round)
	local res = round.result
	local key = round.id .. ":" .. res.seed
	if cache[key] then return cache[key] end
	local rng = U.NewRNG(res.scriptSeed or res.seed)
	local burn = res.burn
	local alive = {}
	for _, name in ipairs(res.names) do alive[name] = true end
	local function AliveList()
		local list = {}
		for _, name in ipairs(res.names) do
			if alive[name] then list[#list + 1] = name end
		end
		return list
	end

	local events = {
		{ t = 0, text = "Onyxia lands on the platform...", kind = "intro" },
		{ t = 1.8, text = '"' .. TAUNTS[rng:Int(#TAUNTS) + 1] .. '"', kind = "taunt" },
	}
	local waves = {}
	local t = O.INTRO
	local idx = 1
	local left = #res.names
	while left > 2 do
		local k = math.max(1, math.floor(left / 3))
		if left - k < 2 then k = left - 2 end
		local victims = {}
		for i = idx, idx + k - 1 do victims[#victims + 1] = burn[i] end
		idx = idx + k
		local wave = { start = t, breathAt = t + O.BREATH, victims = victims, warnings = {} }
		-- false alarms: the red marker jumps over the raid before the fire comes
		local list = AliveList()
		local wt = t + 0.35
		while wt < wave.breathAt - 0.2 do
			wave.warnings[#wave.warnings + 1] = { t = wt, name = list[rng:Int(#list) + 1] }
			wt = wt + 0.32 + rng:Int(100) / 100 * 0.12
		end
		for _, v in ipairs(victims) do alive[v] = false end
		left = left - k
		waves[#waves + 1] = wave
		events[#events + 1] = { t = wave.start, text = "Onyxia takes in a deep breath...", kind = "inhale" }
		events[#events + 1] = { t = wave.breathAt, text = "DEEP BREATH!", kind = "breath" }
		local shown = {}
		for i = 1, math.min(3, #victims) do shown[i] = U.Short(victims[i]) end
		local text = table.concat(shown, ", ") .. (#victims > 3 and (" and " .. (#victims - 3) .. " more") or "")
			.. (#victims == 1 and " was" or " were") .. " roasted! -50 DKP"
		events[#events + 1] = { t = wave.breathAt + O.SWEEP + 0.2, text = text, kind = "roasted" }
		t = t + O.WAVE
	end
	if #waves >= 3 then
		local w = waves[math.floor(#waves / 2) + 1]
		events[#events + 1] = { t = w.start - 0.01, text = "MANY WHELPS! HANDLE IT!", kind = "whelps" }
	end

	-- the last breath: two left, the marker swings between them
	if #res.names >= 2 then
		local last = burn[#burn]
		local duo = { res.winner, last }
		if rng:Int(2) == 0 then duo = { last, res.winner } end
		local wave = { start = t, breathAt = t + O.FINAL_BREATH, victims = { last }, warnings = {}, final = true }
		local wt, i = t + 0.5, 0
		while wt < wave.breathAt - 0.15 do
			i = i + 1
			wave.warnings[#wave.warnings + 1] = { t = wt, name = duo[(i % 2) + 1] }
			wt = wt + math.max(0.18, 0.62 - i * 0.05)
		end
		waves[#waves + 1] = wave
		events[#events + 1] = { t = wave.start, text = "Only " .. U.Short(duo[1]) .. " and " .. U.Short(duo[2]) .. " are left...", kind = "final" }
		events[#events + 1] = { t = wave.breathAt, text = "DEEP BREATH!", kind = "breath" }
		t = t + O.FINAL
	end
	events[#events + 1] = { t = t - 1.6, text = U.Short(res.winner) .. " survives and loots the pot!", kind = "win" }
	table.sort(events, function(a, b)
		if a.t ~= b.t then return a.t < b.t end
		return a.text < b.text
	end)

	local diesAt = {} -- name -> the breath that burns them
	for _, wave in ipairs(waves) do
		for _, v in ipairs(wave.victims) do diesAt[v] = wave end
	end
	local script = { waves = waves, events = events, winAt = t - 1.6, endAt = t, diesAt = diesAt, winner = res.winner }
	cache[key] = script
	return script
end

J.RegisterGame("onyxia", {
	title = "Onyxia's Deep Breath",
	Compute = Compute,
	duration = function(round) return O.START_DELAY + O.Script(round).endAt + O.WIN end,
	limitKey = "onyxiaLimit",
	defaultLimit = 100,
	maxPlayers = O.MAX_PLAYERS,
	bots = { 4, 7 },
})
