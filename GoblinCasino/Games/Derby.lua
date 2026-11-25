-- Murloc Derby: every player enters their own murloc for the same entry fee; the winner takes the
-- whole pot and every other player pays the winner their entry. Expected value is 0 for everyone.
--
-- Fairness and show are kept apart:
--   1. the finish order is a shuffle (Fisher-Yates) driven by the seed of everyone's /roll, so each
--      murloc has exactly the same chance and there are no ties;
--   2. a race script is then generated from the same seed for that order: changes of lead, sprints,
--      stumbles and a close finish. The script never changes the order, it only tells the story.
-- Names and traits of the murlocs are cosmetic; a trait only changes how a murloc runs, not its odds
-- (the favorite names are drawn more often, but a name never changes who wins).
local ADDON, ns = ...
local U, J = ns.Util, ns.Jackpot

local D = {}
ns.Derby = D

D.MAX_PLAYERS = 20
D.START_DELAY = 3       -- "3, 2, 1, GO!" before the murlocs run
D.WINNER_TIME = 20      -- seconds the winner needs (plus up to 2 s)
D.SPREAD = 5            -- the last murloc arrives at most this many seconds after the winner
D.SEGMENTS = 8          -- speed changes per murloc
D.DURATION = D.START_DELAY + D.WINNER_TIME + 2 + D.SPREAD + 1.5

-- 3D models (checked in game with /casino models): creature display IDs of murlocs that load on
-- the Forever client, the facing that makes them run to the right, and animation IDs.
-- Murlocs come up most often; the guests from the test window join in now and then.
local MURLOCS = { 441, 478, 486 }                    -- green/red, grey, blue/yellow
local GUESTS = { 487, 524, 535, 545, 548, 616, 655 }  -- creatures that also run nicely
D.SKINS = {}
for _, id in ipairs(MURLOCS) do
	for _ = 1, 3 do D.SKINS[#D.SKINS + 1] = id end
end
for _, id in ipairs(GUESTS) do D.SKINS[#D.SKINS + 1] = id end
D.FACING = math.pi / 2
D.ANIM = { stand = 0, run = 5, stun = 14 }
-- The winner's celebration: the first of these the creature's model actually has
-- (cheer, roar, dance, battle roar, jump, spell cast). Creatures rarely have "cheer".
D.CELEBRATE = { 68, 74, 69, 55, 38, 51 }

local NAMES = {
	"Mrgglton", "Blurgle", "Gurgleflip", "Finnick", "Sir Splashalot", "Bubbles", "Glubbo", "Mudfin",
	"Rrrgl the Swift", "Sploosh", "Kelpo", "Grubbin", "Flipper", "Snorkel", "Gillbert", "Scalewag",
	"Puddles", "Mrrlin", "Glimmerfin", "Tadpole", "Bogsy", "Murkfoot", "Driplet", "Slosh",
	"Captain Gills", "Wobblefin", "Squelch", "Gurgles", "Fishstick", "Reedle", "Splatter", "Mrrgrr",
	"Lil' Chomp", "Blubber", "Sir Gloop", "Saltytoe", "Brineboy", "Clammy", "Marsh Rocket", "Pondo",
	"Gloopsie", "Mister Mrgl", "Wetsock", "Riptide", "Sudsy", "Fintastic", "Sharkbait", "Muckle",
	"Gilly", "Squidge", "Ploppo", "Barnacle", "Tidepool", "Old Grumblefin", "Swampy", "Gurgleton",
	"Fizzfin", "Shellby", "Murglemaw", "Duckweed", "Mrrrkus", "Glubglub", "Spawnzo", "Lord Mrrgl",
}

-- House favorites: drawn FAVORITE_WEIGHT times as often as any other name.
local FAVORITES = { "Erlaf", "Chambi", "Yarlik", "Eszik", "Archuj" }
D.FAVORITE_WEIGHT = 8

-- The draw list: every name once, each favorite FAVORITE_WEIGHT times.
local DRAW = {}
for _, n in ipairs(NAMES) do DRAW[#DRAW + 1] = n end
for _, n in ipairs(FAVORITES) do
	for _ = 1, D.FAVORITE_WEIGHT do DRAW[#DRAW + 1] = n end
end

D.TRAITS = {
	{ name = "Sprinter", text = "fast off the line" },
	{ name = "Late Bloomer", text = "saves it for the end" },
	{ name = "Clumsy", text = "trips over everything" },
	{ name = "Steady", text = "same pace all the way" },
	{ name = "Show-off", text = "loves a mid-race burst" },
	{ name = "Sleepy", text = "slow to wake up" },
}

---------------------------------------------------------------------------
-- Murloc names and traits for the players in a round (same on every client).
-- Each player draws from the weighted list with their own hash; a name already taken is drawn
-- again with a new hash (so favorites keep their odds), in player order, so no two murlocs share
-- a name.
---------------------------------------------------------------------------
function D.Assign(round)
	local players = U.SortedKeys(round.bets)
	local used, out = {}, {}
	for _, player in ipairs(players) do
		local key = player .. ":" .. round.id
		local name = DRAW[U.FNV1a(key) % #DRAW + 1]
		local tries = 0
		while used[name] and tries < 50 do
			tries = tries + 1
			name = DRAW[U.FNV1a(key .. ":" .. tries) % #DRAW + 1]
		end
		if used[name] then -- unlucky draws: the first free name in list order
			for _, n in ipairs(DRAW) do
				if not used[n] then name = n; break end
			end
		end
		if used[name] then name = name .. " II" end -- more players than names
		used[name] = true
		local trait = D.TRAITS[U.FNV1a(player .. ":" .. round.id .. ":trait") % #D.TRAITS + 1]
		local skin = D.SKINS[U.FNV1a(player .. ":" .. round.id .. ":skin") % #D.SKINS + 1]
		out[player] = { murloc = name, trait = trait, skin = skin }
	end
	return out
end

---------------------------------------------------------------------------
-- Result: seeded shuffle of the runners, winner takes all.
---------------------------------------------------------------------------
local function Compute(bets, rolls)
	local names = U.SortedKeys(bets)
	local parts, total = {}, 0
	for _, name in ipairs(names) do
		parts[#parts + 1] = name .. ":" .. bets[name] .. ":" .. (rolls[name] or 0) .. ";"
		total = total + bets[name]
	end
	local seed = U.FNV1a("derby;" .. table.concat(parts))
	local rng = U.NewRNG(seed)
	local order = {}
	for i, name in ipairs(names) do order[i] = name end
	for i = #order, 2, -1 do
		local j = rng:Int(i) + 1
		order[i], order[j] = order[j], order[i]
	end
	local winner = order[1]
	local transfers = {}
	for _, name in ipairs(names) do
		if name ~= winner then
			transfers[#transfers + 1] = { from = name, to = winner, amount = bets[name] }
		end
	end
	table.sort(transfers, function(a, b) return U.ByteLess(a.from, b.from) end)
	return {
		seed = seed,
		names = names,
		order = order,
		total = total,
		winner = winner,
		transfers = transfers,
		gain = total - bets[winner],
		scriptSeed = rng:Next(),
	}
end

---------------------------------------------------------------------------
-- Race script
-- Each murloc runs D.SEGMENTS equal stretches of time with its own speed; the positions are scaled
-- so it reaches the line exactly at its finish time. Finish times follow the finish order, so the
-- order can't change. Several scripts are tried and the first one with real drama is kept.
---------------------------------------------------------------------------
local function Rand(rng, lo, hi) -- uniform in [lo, hi)
	return lo + (hi - lo) * (rng:Int(100000) / 100000)
end

local function Curve(rng, finish, trait)
	local K = D.SEGMENTS
	local speed, stumbles = {}, {}
	for j = 1, K do speed[j] = Rand(rng, 0.6, 1.4) end
	local t = trait and trait.name
	if t == "Sprinter" then
		for j = 1, 3 do speed[j] = speed[j] * 1.5 end
	elseif t == "Late Bloomer" then
		speed[1] = speed[1] * 0.6
		for j = K - 2, K do speed[j] = speed[j] * 1.5 end
	elseif t == "Steady" then
		for j = 1, K do speed[j] = Rand(rng, 0.92, 1.08) end
	elseif t == "Show-off" then
		local j = 3 + rng:Int(3)
		speed[j] = speed[j] * 1.9
	elseif t == "Sleepy" then
		speed[1] = speed[1] * 0.35
	end
	-- stumbles: Clumsy murlocs always trip once, everyone else sometimes
	if t == "Clumsy" or rng:Int(100) < 25 then
		local j = 2 + rng:Int(K - 2)
		speed[j] = 0.06
		stumbles[#stumbles + 1] = (j - 1) / K * finish
	end
	local sum = 0
	for j = 1, K do sum = sum + speed[j] end
	local pos = { [0] = 0 }
	local acc = 0
	for j = 1, K do
		acc = acc + speed[j]
		pos[j] = acc / sum
	end
	pos[K] = 1
	return { finish = finish, pos = pos, stumbles = stumbles, stumbleLen = finish / K }
end

-- True while the murloc is lying on the ground after a stumble.
function D.Stumbling(curve, t)
	for _, st in ipairs(curve.stumbles) do
		if t >= st and t < st + curve.stumbleLen then return true end
	end
	return false
end

-- Position on the track, 0 (start) .. 1 (finish line), t = seconds since the start signal.
function D.Position(curve, t)
	if t <= 0 then return 0 end
	if t >= curve.finish then return 1 end
	local K = D.SEGMENTS
	local x = t / curve.finish * K
	local j = math.floor(x)
	local frac = x - j
	return curve.pos[j] + (curve.pos[j + 1] - curve.pos[j]) * frac
end

local function Leader(curves, order, t)
	local best, bestPos
	for _, name in ipairs(order) do
		local p = D.Position(curves[name], t)
		if not bestPos or p > bestPos + 1e-9 then best, bestPos = name, p end
	end
	return best
end

-- Drama score: changes of lead, and the winner only taking the lead late.
local function Drama(curves, order, winnerTime)
	local changes, last = 0, nil
	local samples = 60
	for s = 1, samples do
		local leader = Leader(curves, order, winnerTime * s / samples)
		if last and leader ~= last then changes = changes + 1 end
		last = leader
	end
	local lateLead = Leader(curves, order, winnerTime * 0.6) ~= order[1]
	return math.min(changes, 4) + (lateLead and 2 or 0)
end

-- Builds the whole race: curves per runner and a list of commentary events { t, text, kind }.
function D.Script(round)
	local res = round.result
	local info = D.Assign(round)
	local rng = U.NewRNG(res.scriptSeed or res.seed)
	local order = res.order
	local n = #order

	local finish = {}
	local winnerTime = D.WINNER_TIME + Rand(rng, 0, 2)
	local gapScale = n > 1 and math.min(1, D.SPREAD / ((n - 1) * 0.82)) or 1
	local t = winnerTime
	for rank, name in ipairs(order) do
		if rank > 1 then t = t + Rand(rng, 0.12, 0.82) * gapScale end
		finish[name] = t
	end

	local best, bestScore
	for _ = 1, 25 do
		local curves = {}
		for _, name in ipairs(order) do
			curves[name] = Curve(rng, finish[name], info[name] and info[name].trait)
		end
		local score = n > 1 and Drama(curves, order, winnerTime) or 99
		if not bestScore or score > bestScore then best, bestScore = curves, score end
		if score >= 4 then break end
	end

	-- commentary
	local events = { { t = 0, text = "And they're off!", kind = "start" } }
	local last
	local steps = 80
	for s = 1, steps - 1 do -- the last step is the finish itself ("WINS!")
		local at = winnerTime * s / steps
		local leader = Leader(best, order, at)
		if leader ~= last and at > 1.5 then
			events[#events + 1] = { t = at, text = info[leader].murloc .. " takes the lead!", kind = "lead", who = leader }
		end
		last = leader
	end
	for _, name in ipairs(order) do
		for _, st in ipairs(best[name].stumbles) do
			if st < winnerTime then
				events[#events + 1] = { t = st, text = info[name].murloc .. " slips on a fish!", kind = "stumble", who = name }
			end
		end
	end
	events[#events + 1] = { t = winnerTime, text = info[order[1]].murloc .. " WINS!", kind = "finish", who = order[1] }
	-- the finish always comes last, whatever else happens at the same moment
	table.sort(events, function(a, b)
		local fa, fb = a.kind == "finish", b.kind == "finish"
		if fa ~= fb then return fb end
		if a.t ~= b.t then return a.t < b.t end
		return a.text < b.text
	end)

	return {
		curves = best,
		info = info,
		order = order,
		finish = finish,
		winnerTime = winnerTime,
		lastTime = t,
		events = events,
	}
end

---------------------------------------------------------------------------
J.RegisterGame("derby", {
	title = "Murloc Derby",
	Compute = Compute,
	-- the settlement shows a moment after the last murloc crosses the line
	duration = function(round) return D.START_DELAY + D.Script(round).lastTime + 2.5 end,
	-- kept in the history: the winning murloc's name
	Describe = function(round)
		local a = D.Assign(round)[round.result.winner]
		return a and a.murloc
	end,
	limitKey = "derbyEntry",
	defaultLimit = 20,
	fixed = true,
	maxPlayers = D.MAX_PLAYERS,
	bots = { 4, 7 },
})
