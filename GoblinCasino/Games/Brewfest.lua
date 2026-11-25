-- Brewfest Brawl: a drinking contest at the bar. Everyone pays the same entry. While the taps are
-- open, each player decides on their own: another mug (a /roll 10-35 adds that much to their drunk
-- meter) or enough. Over 100% and you're under the table. The drunkest player still standing takes
-- the pot (every other player pays them the entry); if everyone passed out, the one who went over
-- by the least. Ties go to the seed of everyone's mugs.
-- Every mug is a real server /roll the whole group sees, so nobody can know or fake the next one.
-- Messages, besides the shared O/B/L/C:
--   S^id^mugs                    a player stops after that many mugs
--   D^id^name=23.11.30,name2=    the host's final list of everyone's mugs (it decides the round)
local ADDON, ns = ...
local U, J, Comm, Rolls = ns.Util, ns.Jackpot, ns.Comm, ns.Rolls

local B = {}
ns.Brewfest = B

B.MAX_PLAYERS = 12
B.MUG_MIN, B.MUG_MAX = 10, 35  -- one mug adds this much (a /roll in this range)
B.LIMIT = 100                  -- over this, you're under the table
B.DRINK_SECONDS = 40           -- how long the taps are open
B.GRACE = 2.5                  -- the host waits this long for mugs still on their way
B.PENDING = 4                  -- a mug that never shows up frees the buttons after this long
B.SHOW = 6                     -- the result is shown this long before the settlement

---------------------------------------------------------------------------
-- Each player's drinking: round.brew[name] = { mugs, total, stopped, out, stopAt, pending }
---------------------------------------------------------------------------
function B.State(round, name)
	round.brew = round.brew or {}
	local s = round.brew[name]
	if not s then
		s = { mugs = {}, total = 0 }
		round.brew[name] = s
	end
	return s
end
local State = B.State

function B.Done(s)
	return s.out or s.stopped
end
local Done = B.Done

local function AddMug(round, name, roll)
	local s = State(round, name)
	if Done(s) then return false end
	s.mugs[#s.mugs + 1] = roll
	s.total = s.total + roll
	if name == U.Me() then s.pending = nil end
	if s.total > B.LIMIT then s.out = true end
	if s.stopAt and #s.mugs >= s.stopAt then s.stopped = true end
	return true
end

local function AllDone(round)
	for name in pairs(round.bets) do
		if not Done(State(round, name)) then return false end
	end
	return true
end

---------------------------------------------------------------------------
-- Messages
---------------------------------------------------------------------------
local function EncodeDrinks(drinks)
	local parts = {}
	for _, name in ipairs(U.SortedKeys(drinks)) do
		parts[#parts + 1] = name .. "=" .. table.concat(drinks[name], ".")
	end
	return table.concat(parts, ",")
end

local function DecodeDrinks(text)
	local out = {}
	for entry in (text or ""):gmatch("[^,]+") do
		local name, list = entry:match("^([^=]+)=(.*)$")
		if name then
			local mugs = {}
			for v in list:gmatch("%d+") do mugs[#mugs + 1] = tonumber(v) end
			out[name] = mugs
		end
	end
	return out
end

---------------------------------------------------------------------------
-- Closing the bar (host): the final list of mugs decides the round
---------------------------------------------------------------------------
local function HostClose(round)
	if J.round ~= round or round.phase ~= "ROLLING" or round.closed then return end
	round.closed = true
	local drinks = {}
	for name in pairs(round.bets) do
		local list = {}
		for i, v in ipairs(State(round, name).mugs) do list[i] = v end
		drinks[name] = list
	end
	if not round.practice then Comm.Send("D", round.id, EncodeDrinks(drinks)) end
	J.Finish(round, drinks)
end

-- Everyone stopped or passed out: the host closes the bar a moment later (a last mug may be coming).
local function CheckDone(round)
	if not J.IsHost(round) or round.closed or round.closing then return end
	if AllDone(round) then
		round.closing = true
		C_Timer.After(0.6, function() HostClose(round) end)
	end
end

---------------------------------------------------------------------------
-- Player actions
---------------------------------------------------------------------------
local function MyRound()
	local round = J.Active()
	if not round or round.game ~= "brewfest" or round.phase ~= "ROLLING" or round.closed then
		return nil, "The taps aren't open."
	end
	if not round.bets[U.Me()] then return nil, "You're not in this contest." end
	return round, State(round, U.Me())
end

-- The last mug hasn't shown up in chat yet.
function B.Pending(s)
	return s.pending and GetTime() - s.pending < B.PENDING
end

function B.Drink()
	local round, s = MyRound()
	if not round then return false, s end
	if Done(s) or B.Pending(s) then return false end
	if GetTime() > (round.deadline or 0) then return false, "Time's up." end
	s.pending = GetTime()
	Rolls.RollRange(B.MUG_MIN, B.MUG_MAX)
	J.Changed()
	return true
end

function B.Stop()
	local round, s = MyRound()
	if not round then return false, s end
	if Done(s) then return false end
	if B.Pending(s) then return false, "Wait for your mug first." end
	s.stopped = true
	if not round.practice then Comm.Send("S", round.id, #s.mugs) end
	J.Changed()
	CheckDone(round)
	return true
end

---------------------------------------------------------------------------
-- Rolls and messages from other players
---------------------------------------------------------------------------
local function OnRoll(round, name, roll, low, high)
	if low ~= B.MUG_MIN or high ~= B.MUG_MAX or not round.bets[name] or round.closed then return end
	if not AddMug(round, name, roll) then return end
	local s = State(round, name)
	ns.Log.Add("round", "%s drinks %d%% (now %d%%%s)", name, roll, s.total, s.out and ", under the table" or "")
	J.Changed()
	CheckDone(round)
end

Comm.On("S", function(f, sender)
	local round = J.Active()
	if not round or round.id ~= f[2] or round.game ~= "brewfest" or round.phase ~= "ROLLING" then return end
	if not round.bets[sender] or round.closed then return end
	local s = State(round, sender)
	local mugs = tonumber(f[3]) or 0
	-- their last mug may not have reached this client yet: stop once it has
	if #s.mugs >= mugs then s.stopped = true else s.stopAt = mugs end
	J.Changed()
	CheckDone(round)
end)

Comm.On("D", function(f, sender)
	local round = J.Active()
	if not round or round.id ~= f[2] or round.game ~= "brewfest" or sender ~= round.host then return end
	if round.phase ~= "ROLLING" then return end
	round.closed = true
	local drinks = DecodeDrinks(f[3])
	-- check the host's list against the mugs this client saw in chat
	local problems = 0
	for name in pairs(round.bets) do
		local seen = table.concat(State(round, name).mugs, ".")
		local listed = table.concat(drinks[name] or {}, ".")
		if seen ~= listed then
			problems = problems + 1
			ns.Log.Add("round", "check: host lists %s's mugs as {%s}, this client saw {%s}", name, listed, seen)
		end
	end
	if problems > 0 then
		round.warning = "The host's list of mugs differs from what you saw in chat (" .. problems .. ")."
	end
	J.Finish(round, drinks)
end)

---------------------------------------------------------------------------
-- Result: the drunkest one still standing
---------------------------------------------------------------------------
local function Compute(bets, drinks)
	local names = U.SortedKeys(bets)
	local parts, sums = {}, {}
	local standing = false
	for _, name in ipairs(names) do
		local list = drinks[name] or {}
		local sum = 0
		for _, v in ipairs(list) do sum = sum + v end
		sums[name] = sum
		if sum <= B.LIMIT then standing = true end
		parts[#parts + 1] = name .. ":" .. bets[name] .. ":" .. table.concat(list, ".") .. ";"
	end
	local seed = U.FNV1a("brewfest;" .. table.concat(parts))
	local rng = U.NewRNG(seed)
	-- the best total: the highest still standing, or (everyone passed out) the lowest over the limit
	local best
	for _, name in ipairs(names) do
		local sum = sums[name]
		if standing then
			if sum <= B.LIMIT and (not best or sum > best) then best = sum end
		elseif not best or sum < best then
			best = sum
		end
	end
	local tied = {}
	for _, name in ipairs(names) do
		if sums[name] == best and (not standing or best <= B.LIMIT) then tied[#tied + 1] = name end
	end
	local winner = tied[rng:Int(#tied) + 1]
	local transfers, total = {}, 0
	for _, name in ipairs(names) do
		total = total + bets[name]
		if name ~= winner then
			transfers[#transfers + 1] = { from = name, to = winner, amount = bets[name] }
		end
	end
	return {
		seed = seed,
		names = names,
		total = total,
		winner = winner,
		transfers = transfers,
		gain = total - bets[winner],
		sums = sums,
		standing = standing,   -- false: everyone passed out
		tied = #tied > 1,
	}
end

---------------------------------------------------------------------------
-- Practice bots: each drinks until a total it likes, then stops
---------------------------------------------------------------------------
local function BotsDrink(round)
	for name in pairs(round.bets) do
		if J.IsBot(name) then
			local target = math.random(55, 85)
			local function Next()
				if J.round ~= round or round.phase ~= "ROLLING" or round.closed then return end
				local s = State(round, name)
				if Done(s) then return end
				if s.total >= target then
					s.stopped = true
				else
					AddMug(round, name, math.random(B.MUG_MIN, B.MUG_MAX))
				end
				J.Changed()
				CheckDone(round)
				if not Done(s) then C_Timer.After(1.2 + math.random() * 2.5, Next) end
			end
			C_Timer.After(0.8 + math.random() * 2, Next)
		end
	end
end

J.RegisterGame("brewfest", {
	title = "Brewfest Brawl",
	Compute = Compute,
	duration = B.SHOW,
	limitKey = "brewEntry",
	defaultLimit = 10,
	fixed = true,
	maxPlayers = B.MAX_PLAYERS,
	bots = { 3, 6 },
	rollSeconds = B.DRINK_SECONDS,
	OnRoll = OnRoll,
	HostDeadline = function(round)
		-- mugs rolled just before the end may still be on their way
		C_Timer.After(B.GRACE, function() HostClose(round) end)
	end,
	BotsRoll = BotsDrink,
	noSync = true,
	-- kept in the history: how drunk the winner was
	Describe = function(round)
		local res = round.result
		return res and res.sums and res.winner and (res.sums[res.winner] .. "%") or nil
	end,
})
