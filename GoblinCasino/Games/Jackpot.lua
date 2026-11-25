-- The round engine shared by all games, plus Ogre's Wheel itself.
--
-- Ogre's Wheel: a jackpot round. Everyone stakes gold, each stake is a slice of the wheel as big as
-- the stake, the wheel picks one winner, and every other player pays the winner their own stake.
-- Expected value is 0 for every player; nobody acts as a bank.
-- Other games (Murloc Derby) register with J.RegisterGame and reuse the same flow and messages;
-- only how the winner is drawn and shown differs.
--
-- Round flow:      SETUP -> BETTING -> ROLLING -> SPINNING -> DONE        (or CANCELLED)
--                  SETUP is local to the host: the stake limit / entry fee is chosen before anyone
--                  else hears about the round, and it can't change once bets are open.
-- Messages:        O^id^limit^game           host opens a round (game: "wheel", "derby")
--                  B^id^amount               a player sets their stake (0 = withdraw)
--                  L^id^name=amt,...         host locks the bets (the final list)
--                  R^id^name=roll[*],...     host publishes the rolls (* = substitute roll by host)
--                  C^id                      host cancels
--                  Q                         "I just logged in or reloaded: what's going on?"
--                  Y^id^game^limit^phase^bets^rolls^for^secondsLeft
--                                            the host's answer to Q, for one player (`for`)
-- The winner comes from a seed made of everyone's /roll after the bets are locked, so nobody can
-- know it in advance. Each client computes it alone and checks the host's roll list against the
-- rolls it saw in chat.
local ADDON, ns = ...
local U, Comm, Rolls = ns.Util, ns.Comm, ns.Rolls

local J = {}
ns.Jackpot = J

J.DEFAULT_LIMIT = 100
J.ROLL_SECONDS = 30
J.SPIN_SECONDS = 8
J.MAX_HISTORY = 200

J.round = nil
J.session = { rounds = 0, pool = 0 }

-- One line describing the round, for the log.
local function Describe(r)
	if not r then return "no round" end
	local parts = {}
	for _, name in ipairs(U.SortedKeys(r.bets or {})) do parts[#parts + 1] = name .. "=" .. tostring(r.bets[name]) end
	return string.format("%s %s host=%s phase=%s%s limit=%s bets={%s}%s%s", tostring(r.id), tostring(r.game),
		tostring(r.host), tostring(r.phase), r.practice and " practice" or "", tostring(r.limit),
		table.concat(parts, ","), r.warning and (" warning=" .. r.warning) or "", r.error and (" error=" .. r.error) or "")
end

J.Describe = Describe

local listeners = {}
local lastLogged
function J.OnChange(fn) listeners[#listeners + 1] = fn end
local function Changed()
	-- every change of the round's state goes to the log (once)
	local state = Describe(J.round)
	if state ~= lastLogged then
		lastLogged = state
		ns.Log.Add("round", "%s", state)
	end
	for _, fn in ipairs(listeners) do
		local ok, err = pcall(fn, J.round)
		if not ok then
			ns.Log.Error("UI update", err)
			geterrorhandler()(err)
		end
	end
end
J.Changed = Changed

local function Active()
	local r = J.round
	return r and r.phase ~= "DONE" and r.phase ~= "CANCELLED" and r or nil
end
J.Active = Active

function J.IsHost(r)
	r = r or J.round
	return r and r.host == U.Me()
end

---------------------------------------------------------------------------
-- Encoding
---------------------------------------------------------------------------
local function EncodeMap(map, marks)
	local parts = {}
	for _, name in ipairs(U.SortedKeys(map)) do
		parts[#parts + 1] = name .. "=" .. map[name] .. ((marks and marks[name]) and "*" or "")
	end
	return table.concat(parts, ",")
end

local function DecodeMap(text)
	local map, marks = {}, {}
	for name, value, mark in (text or ""):gmatch("([^,=]+)=(%d+)(%*?)") do
		map[name] = tonumber(value)
		if mark == "*" then marks[name] = true end
	end
	return map, marks
end

---------------------------------------------------------------------------
-- Outcome: same inputs give the same winner on every client
---------------------------------------------------------------------------
function J.Compute(bets, rolls)
	local names = U.SortedKeys(bets)
	local parts, total = {}, 0
	for _, name in ipairs(names) do
		parts[#parts + 1] = name .. ":" .. bets[name] .. ":" .. (rolls[name] or 0) .. ";"
		total = total + bets[name]
	end
	local seed = U.FNV1a(table.concat(parts))
	local rng = U.NewRNG(seed)
	local r = rng:Int(total)
	local winner, start, acc = nil, 0, 0
	for _, name in ipairs(names) do
		if r < acc + bets[name] then winner, start = name, acc; break end
		acc = acc + bets[name]
	end
	local transfers = {}
	for _, name in ipairs(names) do
		if name ~= winner then
			transfers[#transfers + 1] = { from = name, to = winner, amount = bets[name] }
		end
	end
	table.sort(transfers, function(a, b)
		if a.amount ~= b.amount then return a.amount > b.amount end
		return U.ByteLess(a.from, b.from)
	end)
	return {
		seed = seed,
		names = names,
		total = total,
		r = r,
		winner = winner,
		winnerStart = start,          -- where the winner's slice starts, in gold
		turns = 5 + rng:Int(3),       -- full turns of the wheel before it stops
		transfers = transfers,
		gain = total - bets[winner],
	}
end

---------------------------------------------------------------------------
-- Games
--   title         shown in chat and on screens
--   Compute       function(bets, rolls, round) -> result with names, total, transfers and either
--                 winner + gain (one player collects) or loser + gain (one player pays every
--                 other player `gain`)
--   loseVerb      for loser games: what happened to the loser ("blew up")
--   duration      seconds the result is animated before the round is DONE (or function(round))
--   limitKey      saved setting holding the host's stake limit (or entry fee)
--   defaultLimit  value used when the setting is empty
--   fixed         true: everyone pays the same entry (the limit); false: any stake up to the limit
--   maxPlayers    optional cap on entries
--   bots          { min, max } practice bots
---------------------------------------------------------------------------
J.games = {}

function J.RegisterGame(key, def)
	def.key = key
	J.games[key] = def
end

function J.Game(round)
	round = round or J.round
	return J.games[(round and round.game) or "wheel"]
end

J.RegisterGame("wheel", {
	title = "Ogre's Wheel",
	Compute = J.Compute,
	duration = J.SPIN_SECONDS,
	limitKey = "stakeLimit",
	defaultLimit = 100,
	bots = { 3, 5 },
})

local function Count(t)
	local n = 0
	for _ in pairs(t) do n = n + 1 end
	return n
end

---------------------------------------------------------------------------
-- History (SavedVariables)
---------------------------------------------------------------------------
-- Every finished round is kept (practice ones too, marked), newest last. When the list is full,
-- the oldest practice round goes first, so real rounds are kept the longest.
local function Record(round)
	local res = round.result
	local def = J.Game(round)
	local history = ns.db.history
	-- the same round can finish twice on this client when it was picked up again after a /reload
	for i = #history, math.max(1, #history - 5), -1 do
		if history[i].id == round.id and history[i].me == U.Me() then return end
	end
	J.session.rounds = J.session.rounds + 1
	J.session.pool = J.session.pool + res.total
	history[#history + 1] = {
		time = time(), game = round.game, id = round.id, host = round.host,
		practice = round.practice or nil,
		me = U.Me(),                         -- whose point of view ("you") this entry has
		players = Count(round.bets),
		pool = res.total, winner = res.winner, loser = res.loser, transfers = res.transfers,
		note = def.Describe and def.Describe(round) or nil, -- e.g. the winning murloc's name
	}
	while #history > J.MAX_HISTORY do
		local oldestPractice
		for i, e in ipairs(history) do
			if e.practice then oldestPractice = i; break end
		end
		table.remove(history, oldestPractice or 1)
	end
end

---------------------------------------------------------------------------
-- Practice bots (practice rounds only: no messages, rolls made up locally)
---------------------------------------------------------------------------
local BOT_NAMES = { "Kezzik", "Boomfizz", "Snagglebolt", "Zixxa", "Pockets", "Grimtooth", "Fizzlecrank" }

local function Bot(name) return name .. "-Bot" end

function J.IsBot(name) return name and name:match("%-Bot$") ~= nil end

local function StartBots(round)
	local def = J.Game(round)
	local pool = {}
	for _, n in ipairs(BOT_NAMES) do pool[#pool + 1] = n end
	local count = math.random(def.bots[1], math.min(def.bots[2], #pool))
	for _ = 1, count do
		local name = Bot(table.remove(pool, math.random(#pool)))
		C_Timer.After(0.8 + math.random() * 6, function()
			if J.round ~= round or round.phase ~= "BETTING" then return end
			round.bets[name] = def.fixed and round.limit or math.random(math.min(5, round.limit), round.limit)
			Changed()
		end)
	end
end

local function BotsRoll(round)
	for name in pairs(round.bets) do
		if J.IsBot(name) then
			C_Timer.After(0.6 + math.random() * 3, function()
				if J.round ~= round or round.phase ~= "ROLLING" then return end
				J.OnRoll(name, math.random(Rolls.MIN, Rolls.MAX))
			end)
		end
	end
end

---------------------------------------------------------------------------
-- Host actions
---------------------------------------------------------------------------
function J.Open(practice, game)
	game = game or "wheel"
	local def = J.games[game]
	if not def then return false, "Unknown game." end
	if Active() then return false, "A round is already running." end
	if not practice and not Comm.Channel() then return false, "Join a party or raid first, or start a practice round." end
	-- SETUP: only the host sees the round while choosing the stake limit / entry fee
	local round = {
		id = tostring(GetServerTime()) .. math.random(100, 999),
		game = game,
		host = U.Me(),
		practice = practice and true or false,
		limit = ns.db[def.limitKey] or def.defaultLimit,
		phase = "SETUP",
		bets = {},
	}
	J.round = round
	Changed()
	return true
end

-- Host sets the stake limit (or entry fee) during SETUP. It is also kept for the next rounds.
-- Once bets are open the limit can't change, so nobody stakes under different terms.
-- gameKey: whose saved limit to change (default: the running round's game, else the wheel).
function J.SetLimit(limit, gameKey)
	limit = math.floor(tonumber(limit) or 0)
	if limit < 1 or limit > 999999 then return false, "The limit has to be between 1 and 999,999 gold." end
	local round = Active()
	local def = J.games[gameKey or ""] or (round and J.Game(round)) or J.games.wheel
	ns.db[def.limitKey] = limit
	if round and J.IsHost(round) and round.phase == "SETUP" and J.Game(round) == def then
		round.limit = limit
		Changed()
	end
	return true
end

-- Host opens the round to the group (or to the bots) with the chosen limit.
function J.OpenBets()
	local round = Active()
	if not round or not J.IsHost(round) or round.phase ~= "SETUP" then return false end
	if not round.practice and not Comm.Channel() then return false, "Join a party or raid first." end
	if not round.practice and Comm.Restricted() then
		return false, "The game is blocking addon messages right now (boss fight?). Try again in a moment."
	end
	round.phase = "BETTING"
	if round.practice then
		StartBots(round)
	else
		Comm.Send("O", round.id, round.limit, round.game)
	end
	Changed()
	return true
end

local function StartRolling(round)
	round.phase = "ROLLING"
	round.lockedAt = GetTime()
	round.deadline = GetTime() + J.ROLL_SECONDS
	round.seen, round.hostExtra, round.subs = {}, {}, {}
end

function J.Lock()
	local round = Active()
	if not round or not J.IsHost(round) or round.phase ~= "BETTING" then return false end
	if not round.practice then
		-- bettors who left the group are dropped now; while a name is still loading we can't tell
		local roster, incomplete = U.GroupRoster()
		if incomplete then return false, "Someone in the group is still loading. Try again in a moment." end
		for name in pairs(round.bets) do
			if not roster[name] then round.bets[name] = nil end
		end
	end
	local n = 0
	for _ in pairs(round.bets) do n = n + 1 end
	if n < 2 then return false, "At least two players have to place a bet." end
	if not round.practice and Comm.Restricted() then
		return false, "The game is blocking addon messages right now (boss fight?). Try again in a moment."
	end
	StartRolling(round)
	if round.practice then
		BotsRoll(round)
		C_Timer.After(J.ROLL_SECONDS, function() J.HostDeadline(round) end)
	else
		Comm.Send("L", round.id, EncodeMap(round.bets))
		-- the players' time starts when the list has actually gone out (it can wait in the queue)
		Comm.Flushed(function()
			if J.round ~= round or round.phase ~= "ROLLING" then return end
			round.deadline = GetTime() + J.ROLL_SECONDS
			C_Timer.After(J.ROLL_SECONDS, function() J.HostDeadline(round) end)
			Changed()
		end)
	end
	Changed()
	return true
end

function J.Cancel()
	local round = Active()
	if not round or not J.IsHost(round) then return end
	if round.phase == "SETUP" then -- nobody else knows about it yet
		J.round = nil
		Changed()
		return
	end
	round.phase = "CANCELLED"
	if not round.practice then Comm.Send("C", round.id) end
	Changed()
end

-- Leave a round run by someone else (for example when the host disappeared).
function J.Abandon()
	local round = J.round
	if not round then return end
	if Active() and J.IsHost(round) then return J.Cancel() end
	if round.phase == "BETTING" and round.bets[U.Me()] and not round.practice then
		Comm.Send("B", round.id, 0)
	end
	J.round = nil
	Changed()
end

-- Clear a finished round so a new one can start.
function J.Dismiss()
	if J.round and not Active() then
		J.round = nil
		Changed()
	end
end

---------------------------------------------------------------------------
-- Player actions
---------------------------------------------------------------------------
function J.Bet(amount)
	local round = Active()
	if round and round.phase == "SETUP" then return false, "Open the round first." end
	if not round or round.phase ~= "BETTING" then return false, "Bets are closed." end
	amount = math.floor(tonumber(amount) or 0)
	if amount < 0 then amount = 0 end
	local def, me = J.Game(round), U.Me()
	if def.fixed and amount > 0 and amount ~= round.limit then return false, "The entry is " .. round.limit .. " gold." end
	if amount > round.limit then return false, "The stake limit is " .. round.limit .. " gold." end
	if not round.practice and amount > U.PlayerGold() then return false, "You don't have that much gold." end
	if amount > 0 and not round.bets[me] and def.maxPlayers and Count(round.bets) >= def.maxPlayers then
		return false, "This round is full (" .. def.maxPlayers .. " players)."
	end
	round.bets[me] = amount > 0 and amount or nil
	round.myIntent = amount
	if not round.practice then Comm.Send("B", round.id, amount) end
	Changed()
	return true
end

function J.MyBet()
	local round = J.round
	return round and round.bets[U.Me()]
end

function J.HasRolled(name)
	local round = J.round
	return round and round.seen and round.seen[name or U.Me()] ~= nil
end

function J.RollNow()
	local round = Active()
	if not round or round.phase ~= "ROLLING" or not round.bets[U.Me()] or J.HasRolled() then return end
	Rolls.Roll()
end

---------------------------------------------------------------------------
-- Rolls
---------------------------------------------------------------------------
local function Finish(round, rolls, subs)
	local def = J.Game(round)
	round.rolls, round.subs = rolls, subs or {}
	round.result = def.Compute(round.bets, rolls, round)
	local res = round.result
	ns.Log.Add("round", "%s result: %s %s gain %s seed %s rolls {%s}", round.id, res.loser and "loser" or "winner",
		res.loser or res.winner, res.gain, res.seed,
		EncodeMap(rolls, subs))
	for _, t in ipairs(res.transfers or {}) do
		ns.Log.Add("round", "  %s pays %s %sg", t.from, t.to, t.amount)
	end
	round.phase = "SPINNING"
	round.spinStart = GetTime()
	local recorded, err = pcall(Record, round)
	if not recorded then ns.Log.Error("history", err) end
	Changed()
	local duration = type(def.duration) == "function" and def.duration(round) or def.duration
	round.duration = duration
	C_Timer.After(duration + 0.3, function()
		if J.round ~= round or round.phase ~= "SPINNING" then return end
		round.phase = "DONE"
		local res = round.result
		local me = U.Me()
		local tag = round.practice and " |cff9d9d9d(practice)|r" or ""
		if res.loser then
			-- one player pays everyone else
			local others = #res.transfers
			ns.Print(U.Short(res.loser) .. " " .. (def.loseVerb or "lost") .. " in " .. def.title .. " and pays "
				.. others .. (others == 1 and " player " or " players ") .. U.Gold(res.gain) .. (others == 1 and "!" or " each!") .. tag)
			if not round.practice and round.bets[me] then
				if res.loser == me then
					ns.Print("You owe " .. U.Gold(res.gain) .. " to each of " .. others .. (others == 1 and " player" or " players")
						.. " (" .. U.Gold(res.gain * others) .. " in total). Open a trade with each to pay.")
				else
					ns.Print(U.Short(res.loser) .. " owes you " .. U.Gold(res.gain) .. ".")
				end
			end
		else
			ns.Print(U.Short(res.winner) .. " wins " .. U.Gold(res.gain) .. " in " .. def.title .. "!" .. tag)
			if not round.practice and round.bets[me] and res.winner ~= me then
				ns.Print("You owe " .. U.Short(res.winner) .. " " .. U.Gold(round.bets[me]) .. ". Open a trade to pay.")
			end
		end
		Changed()
	end)
end

local function HostFinish(round)
	if round.phase ~= "ROLLING" or round.finishing then return end
	round.finishing = true
	local rolls = {}
	for name in pairs(round.bets) do rolls[name] = round.seen[name] end
	for name, roll in pairs(round.subRolls or {}) do rolls[name] = roll end
	if not round.practice then
		Comm.Send("R", round.id, EncodeMap(rolls, round.subRolls))
	end
	Finish(round, rolls, round.subRolls)
end

local function AllRolled(round)
	for name in pairs(round.bets) do
		if not round.seen[name] and not (round.subRolls and round.subRolls[name]) then return false end
	end
	return true
end

-- Substitute rolls: the host rolls once for every player who didn't roll in time, in name order.
local function AssignSubs(round)
	if not round.subbing then return end
	local fresh = #round.hostExtra - round.subStart
	if fresh < #round.subbing then return end
	round.subRolls = {}
	for i, name in ipairs(round.subbing) do
		round.subRolls[name] = round.hostExtra[round.subStart + i]
	end
	round.subbing = nil
	HostFinish(round)
end

function J.HostDeadline(round)
	if J.round ~= round or round.phase ~= "ROLLING" or not J.IsHost(round) or round.subbing then return end
	local me = U.Me()
	local missing, selfMissing = {}, false
	for _, name in ipairs(U.SortedKeys(round.bets)) do
		if not round.seen[name] then
			if name == me then selfMissing = true else missing[#missing + 1] = name end
		end
	end
	if #missing == 0 and not selfMissing then return HostFinish(round) end
	ns.Log.Add("round", "deadline: no roll from %s%s, host rolls for them", table.concat(missing, ","),
		selfMissing and " (and the host)" or "")

	local calls
	if round.practice then
		-- bots never miss; only the player can, and their roll is made for them
		calls = 1
		Rolls.Roll()
	else
		round.subbing = missing
		round.subStart = #round.hostExtra
		calls = #missing + (selfMissing and 1 or 0)
		for i = 1, calls do
			C_Timer.After((i - 1) * 0.6, function()
				if J.round == round and round.subbing then Rolls.Roll() end
			end)
		end
	end
	Changed()
	-- safety net: if the rolls never show up in chat, the round can't be decided fairly
	C_Timer.After(calls * 0.6 + 8, function()
		if J.round == round and round.phase == "ROLLING" then
			round.phase = "CANCELLED"
			round.error = "Rolls couldn't be read from chat, so the round was cancelled and nobody pays. "
				.. "Type /casino debug, try again and send the [debug] lines."
			if not round.practice then Comm.Send("C", round.id) end
			Changed()
		end
	end)
end

-- Every /roll 1-1000000 seen in chat (and the made-up rolls of practice bots).
function J.OnRoll(name, roll)
	local round = J.round
	local debug = ns.Debug or function() end
	if round and round.phase == "BETTING" then
		-- the host may have locked already and this client just hasn't heard yet: keep the roll so
		-- the host's final roll list can be checked against it
		round.early = round.early or {}
		local list = round.early[name] or {}
		list[#list + 1] = roll
		round.early[name] = list
		debug("roll %s by %s seen before the lock reached this client", roll, name)
		return
	end
	if not round or round.phase ~= "ROLLING" then
		debug("roll %s by %s ignored: no round waiting for rolls (phase %s)", roll, name, round and round.phase or "none")
		return
	end
	if round.bets[name] and round.seen[name] == nil then
		round.seen[name] = roll
		debug("roll %s counted for %s", roll, name)
	elseif name == round.host then
		round.hostExtra[#round.hostExtra + 1] = roll
		debug("roll %s by host %s kept as an extra host roll", roll, name)
	else
		debug("roll %s by %s ignored: not a bettor (you are %s)", roll, name, U.Me())
		return
	end
	if J.IsHost(round) then
		if round.subbing then
			AssignSubs(round)
		elseif AllRolled(round) then
			HostFinish(round)
		end
	end
	Changed()
end
Rolls.Listen(J.OnRoll)

---------------------------------------------------------------------------
-- Messages from other players
---------------------------------------------------------------------------
-- A new round from someone else replaces the one this client has when:
--   - ours is still in SETUP (nobody else knows about it) or is a practice round,
--   - it comes from the same host (they started over: /reload, or NEW ROUND while we still watch
--     the last animation),
--   - both are still taking bets and the new one is older (two hosts opened at the same moment:
--     the lower id wins everywhere, and a host whose round loses cancels it).
local function ReplaceFor(mine, id, sender)
	if mine.practice then return true, "Your practice round was stopped: " .. U.Short(sender) .. " opened a real round." end
	if mine.phase == "SETUP" then return true, U.Short(sender) .. " opened a round first, so yours was dropped." end
	if mine.host == sender then return true end
	if mine.phase == "BETTING" and (tonumber(id) or math.huge) < (tonumber(mine.id) or 0) then
		if J.IsHost(mine) then
			Comm.Send("C", mine.id)
			return true, U.Short(sender) .. " opened a round at the same moment; theirs goes ahead and yours was cancelled."
		end
		return true, U.Short(sender) .. " and " .. U.Short(mine.host) .. " opened rounds at the same moment; "
			.. U.Short(sender) .. "'s goes ahead. Place your bet again."
	end
	return false
end

Comm.On("O", function(f, sender)
	local id, limit, game = f[2], tonumber(f[3]), f[4] or "wheel"
	local mine = Active()
	if mine then
		if mine.id == id then return end
		local replace, why = ReplaceFor(mine, id, sender)
		if not replace then
			ns.Log.Add("round", "ignored new round %s from %s: busy with round %s (%s)", id, sender, mine.id, mine.phase)
			return
		end
		if why then ns.Print(why) end
	end
	local def = J.games[game]
	if not def then
		ns.Print(U.Short(sender) .. " opened a game this version doesn't know. Update Goblin Casino to join.")
		return
	end
	J.round = { id = id, game = game, host = sender, practice = false, limit = limit or def.defaultLimit, phase = "BETTING", bets = {} }
	ns.Print(U.Short(sender) .. " opened |cffe879f9" .. def.title .. "|r! Type |cffffd100/casino|r to join.")
	if ns.Main and ns.Main.OnRoundOpened then ns.Main:OnRoundOpened() end
	Changed()
end)

Comm.On("B", function(f, sender)
	local round = Active()
	if not round or round.id ~= f[2] or round.phase ~= "BETTING" then return end
	local amount = math.floor(tonumber(f[3]) or 0)
	local def = J.Game(round)
	local valid = amount > 0 and amount <= round.limit and (not def.fixed or amount == round.limit)
	if valid and not round.bets[sender] and def.maxPlayers and Count(round.bets) >= def.maxPlayers then
		valid = false
	end
	round.bets[sender] = valid and amount or nil
	Changed()
end)

Comm.On("L", function(f, sender)
	local round = Active()
	if not round or round.id ~= f[2] or sender ~= round.host or round.phase ~= "BETTING" then return end
	local intent = round.myIntent -- what this player last asked for (0 = withdrew), nil = never bet
	round.bets = DecodeMap(f[3])
	local got = round.bets[U.Me()]
	if intent ~= nil and (got or 0) ~= intent then
		if not got then
			round.warning = "Your bet of " .. intent .. "g didn't reach the host in time, so you're not in this round."
		elseif intent == 0 then
			round.warning = "Your withdrawal didn't reach the host in time: you're in with " .. got .. "g. Roll, or talk to the host."
		else
			round.warning = "The host's final list has you at " .. got .. "g, not " .. intent .. "g."
		end
	end
	StartRolling(round)
	Changed()
end)

-- Did this client see `name` roll `roll` (during the rolls, or just before the lock reached it)?
local function SawRoll(round, name, roll)
	if round.seen[name] == roll then return true end
	for _, v in ipairs(round.early and round.early[name] or {}) do
		if v == roll then return true end
	end
	return false
end

Comm.On("R", function(f, sender)
	local round = Active()
	if not round or round.id ~= f[2] or sender ~= round.host or round.phase ~= "ROLLING" then return end
	local rolls, subs = DecodeMap(f[3])
	-- check the host's list against the rolls this client saw in chat
	local extra, problems = {}, 0
	for _, v in ipairs(round.hostExtra or {}) do extra[v] = true end
	for name in pairs(round.bets) do
		local roll = rolls[name]
		if not roll then
			ns.Log.Add("round", "check: %s has no roll in the host's list", name)
			problems = problems + 1
		elseif subs[name] then
			if not extra[roll] and not SawRoll(round, round.host, roll) then
				ns.Log.Add("round", "check: substitute roll %s for %s was never seen from the host", roll, name)
				problems = problems + 1
			end
		elseif round.seen[name] and round.seen[name] ~= roll and not SawRoll(round, name, roll) then
			ns.Log.Add("round", "check: host says %s rolled %s, this client saw %s", name, roll, round.seen[name])
			problems = problems + 1
		end
	end
	if problems > 0 then
		round.warning = "The host's roll list doesn't match the rolls you saw in chat (" .. problems .. ")."
	end
	Finish(round, rolls, subs)
end)

-- Once the rolls are in, the result is final: a round that is already being shown can't be
-- cancelled any more (everyone else already sees who pays whom).
local function Cancellable(round)
	return round and (round.phase == "BETTING" or round.phase == "ROLLING")
end

Comm.On("C", function(f, sender)
	local round = Active()
	if not round or round.id ~= f[2] or sender ~= round.host or not Cancellable(round) then return end
	round.phase = "CANCELLED"
	round.error = round.error or (U.Short(sender) .. " cancelled the round. Nobody pays.")
	Changed()
end)

---------------------------------------------------------------------------
-- Group changes: the host left (the round can't go on), or a bettor left (their bet is dropped
-- while bets are still open)
---------------------------------------------------------------------------
local hostCheckPending = false

local function CancelLocal(round, why)
	round.phase = "CANCELLED"
	round.error = why
	Changed()
end

local function CheckRoster()
	local round = Active()
	if not round or round.practice or not Cancellable(round) then return end
	if not Comm.Channel() then
		return CancelLocal(round, "You left the group. Round cancelled.")
	end
	local roster, incomplete = U.GroupRoster()
	if incomplete then return end -- some names aren't known yet (loading); look again next time
	if not J.IsHost(round) and not (roster[round.host] and U.IsOnline(round.host)) then
		-- names can be briefly missing while someone zones; make sure before cancelling
		if hostCheckPending then return end
		hostCheckPending = true
		C_Timer.After(3, function()
			hostCheckPending = false
			if J.round ~= round or not Cancellable(round) then return end
			local again, unsure = U.GroupRoster()
			if unsure or (again[round.host] and U.IsOnline(round.host)) then return end
			CancelLocal(round, U.Short(round.host) .. " (host) left the group or went offline. Round cancelled, nobody pays.")
		end)
		return
	end
	if round.phase == "BETTING" then
		local dropped = false
		for name in pairs(round.bets) do
			if not roster[name] then
				round.bets[name] = nil
				dropped = true
			end
		end
		if dropped then Changed() end
	end
end

---------------------------------------------------------------------------
-- Back after /reload or a relog: this client forgot the round, but the host still counts this
-- player's bet. It asks (Q) and the host answers with the round as it stands (Y, meant for that
-- one player; everyone else ignores it). A Q from our round's host means the host forgot it.
---------------------------------------------------------------------------
local syncAsked = 0

function J.AskSync()
	if not Comm.Channel() or Active() then return end
	syncAsked = GetTime()
	Comm.Send("Q")
end

Comm.On("Q", function(_, sender)
	local round = J.round
	if not round or round.practice then return end
	if J.IsHost(round) then
		local phase = round.phase
		local recent = (phase == "SPINNING" or phase == "DONE") and round.spinStart and GetTime() - round.spinStart < 120
		if not (Cancellable(round) or recent) then return end
		-- once the bets are locked, only players in the round need it
		if phase ~= "BETTING" and not round.bets[sender] then return end
		local rolls, marks = round.seen or {}, nil
		if round.rolls then rolls, marks = round.rolls, round.subs end
		local left = round.deadline and math.max(0, math.floor(round.deadline - GetTime())) or 0
		Comm.Send("Y", round.id, round.game, round.limit, phase, EncodeMap(round.bets), EncodeMap(rolls, marks), sender, left)
	elseif sender == round.host and Cancellable(round) then
		CancelLocal(round, U.Short(sender) .. " (host) reloaded the game, so the round is gone. Nobody pays.")
	end
end)

Comm.On("Y", function(f, sender)
	if f[8] ~= U.Me() or syncAsked == 0 or GetTime() - syncAsked > 30 or Active() then return end
	local id, game, limit, phase = f[2], f[3], tonumber(f[4]), f[5]
	local def = J.games[game or ""]
	if not def then return end
	syncAsked = 0
	local bets = DecodeMap(f[6])
	local rolls, marks = DecodeMap(f[7])
	local me = U.Me()
	local round = { id = id, game = game, host = sender, practice = false, limit = limit or def.defaultLimit,
		phase = "BETTING", bets = bets, myIntent = bets[me] }
	J.round = round
	ns.Log.Add("round", "picked up round %s from %s after a reload (phase %s)", id, sender, tostring(phase))
	if bets[me] then
		ns.Print("You're back in " .. U.Short(sender) .. "'s " .. def.title .. " round.")
	else
		ns.Print(U.Short(sender) .. " has " .. def.title .. " open. Type |cffffd100/casino|r to join.")
	end
	if phase ~= "BETTING" then
		StartRolling(round)
		round.deadline = GetTime() + (tonumber(f[9]) or 0)
		if phase == "ROLLING" then
			for name, roll in pairs(rolls) do round.seen[name] = roll end
		else
			Finish(round, rolls, marks)
		end
	end
	if ns.Main and ns.Main.OnRoundOpened then ns.Main:OnRoundOpened() end
	Changed()
end)

local events = CreateFrame("Frame")
events:RegisterEvent("GROUP_ROSTER_UPDATE")
events:RegisterEvent("UNIT_CONNECTION")
events:RegisterEvent("PLAYER_ENTERING_WORLD")
events:SetScript("OnEvent", function(_, event, isLogin, isReload)
	if event == "PLAYER_ENTERING_WORLD" then
		if isLogin or isReload then C_Timer.After(4, J.AskSync) end
		return
	end
	local ok, err = pcall(CheckRoster)
	if not ok then ns.Log.Error("roster check", err) end
end)

---------------------------------------------------------------------------
-- Log every player/host action with its arguments and outcome ("Bets are closed." and the like),
-- so the log shows what was clicked and why it did nothing.
---------------------------------------------------------------------------
for _, fname in ipairs({ "Open", "SetLimit", "OpenBets", "Lock", "Cancel", "Abandon", "Bet", "RollNow" }) do
	local original = J[fname]
	J[fname] = function(...)
		local n = select("#", ...)
		local args = {}
		for i = 1, n do args[i] = tostring((select(i, ...))) end
		local results = { original(...) }
		local out = {}
		for i = 1, 2 do
			if results[i] ~= nil then out[#out + 1] = tostring(results[i]) end
		end
		ns.Log.Add("action", "%s(%s)%s", fname, table.concat(args, ", "),
			#out > 0 and (" -> " .. table.concat(out, ", ")) or "")
		return unpack(results, 1, 2)
	end
end
