-- Ogre's Wheel screen: the wheel on the left, players / settlement on the right, actions below.
local ADDON, ns = ...
local T, U, J, Wheel = ns.Theme, ns.Util, ns.Jackpot, ns.Wheel
local C, hex, Mix = T.C, T.hex, T.Mix

local View = {}
ns.WheelView = View

local ROWS, ROW_H = 9, 26
local RADIUS = 100
local LEFT_W = 320
local WHEEL_TOP = -40        -- without the ogre
local WHEEL_TOP_OGRE = -128  -- lower, so the ogre's head and shoulders show above it
local RED, ORANGE, DIM = hex("ff6b6b"), hex("ffb347"), hex("9d8fbf")

-- The ogre croupier stands behind the wheel: his head, shoulders and arms show around it. Creature
-- (NPC) IDs for SetCreature, the first one that loads is used; /casino models shows them all.
local OGRES = {
	5229,  -- Gordunni Ogre
	1178,  -- Mo'grosh Ogre
	2562,  -- Boulderfist Ogre
	11501, -- King Gordok
	18069, -- Mogor
}
local OGRE_W, OGRE_H, OGRE_TOP = 320, 340, -6 -- his frame; the feet are hidden behind the wheel
local OGRE_ANIMS = {             -- the first one the model has is played
	idle = { 0 },
	talk = { 60, 70, 0 },        -- talk, laugh
	ready = { 25, 26, 27, 0 },   -- ready stance: the rolls are coming in
	slap = { 16, 17, 18, 0 },    -- attack: he gives the wheel a whack to start it
	roar = { 74, 55, 68, 0 },    -- roar, battle roar, cheer: the result
}

local PHASES = {
	SETUP = { "SETUP", C.gold },
	BETTING = { "PLACE YOUR BETS", C.green },
	ROLLING = { "ROLL FOR THE SEED", C.cyan },
	SPINNING = { "SPINNING", C.pink },
	DONE = { "RESULT", C.gold },
	CANCELLED = { "CANCELLED", RED },
}

local function ColorCode(c)
	return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
end

local function CreateList(parent, width)
	return ns.Widgets.List(parent, width, ROWS, ROW_H)
end

local function CreateStakeBox(parent)
	return ns.Widgets.AmountBox(parent, 96, 34, 16)
end

-- The ogre (a model behind the wheel). ogre:Update(round) each frame plays what fits the moment;
-- onFail() is called when no ogre model loads on this client (the wheel then moves back up).
local function CreateOgre(v, onFail)
	local m = CreateFrame("PlayerModel", nil, v)
	m:SetSize(OGRE_W, OGRE_H)
	m:SetPoint("TOP", v, "TOPLEFT", LEFT_W / 2, OGRE_TOP)
	m:SetFrameLevel(v:GetFrameLevel()) -- under the wheel
	local state = { index = 0, cache = {} }

	local function Try(index)
		state.index, state.at, state.loaded, state.anim, state.cache = index, GetTime(), false, nil, {}
		pcall(m.SetCreature, m, OGRES[index])
		pcall(m.SetFacing, m, 0)
	end
	m:SetScript("OnModelLoaded", function(self)
		state.loaded, state.good = true, state.index
		pcall(self.SetFacing, self, 0)
		if state.anim then pcall(self.SetAnimation, self, state.anim) end
	end)

	local function Play(list)
		local key = table.concat(list, ",")
		local id = state.cache[key]
		if id == nil then
			for _, a in ipairs(list) do
				local ok, has = pcall(m.HasAnimation, m, a)
				if ok and has then id = a; break end
			end
			-- before the model has loaded HasAnimation knows nothing: ask again later
			if state.loaded then state.cache[key] = id or false end
		end
		id = id or list[#list]
		if state.anim ~= id then
			state.anim = id
			pcall(m.SetAnimation, m, id)
		end
	end

	local function Want(round, now)
		if not round then return OGRE_ANIMS.idle end
		local since = round.spinStart and (now - round.spinStart)
		if round.phase == "SPINNING" and since then
			if since < 1.2 then return OGRE_ANIMS.slap end
			if since < J.SPIN_SECONDS then return OGRE_ANIMS.idle end
			return OGRE_ANIMS.roar
		elseif round.phase == "DONE" and since and since < J.SPIN_SECONDS + 4 then
			return OGRE_ANIMS.roar
		elseif round.phase == "ROLLING" then
			return OGRE_ANIMS.ready
		end
		-- now and then he has something to say (3 seconds in every 10)
		return (now % 10) < 3 and OGRE_ANIMS.talk or OGRE_ANIMS.idle
	end

	local ogre = {}
	function ogre:Update(round)
		if state.failed then return end
		local now = GetTime()
		-- the model didn't load: the next ogre, or none at all
		if state.index > 0 and not state.loaded and not state.good and now - state.at > 4 then
			if state.index < #OGRES then
				Try(state.index + 1)
			else
				state.failed = true
				m:Hide()
				onFail()
				return
			end
		end
		Play(Want(round, now))
	end
	-- a model set while hidden may never load: set it again each time the screen opens
	function ogre:Show()
		if state.failed then return end
		if state.index == 0 then Try(state.good or 1) end
	end
	function ogre:Hide()
		state.index = 0
	end
	return ogre
end

---------------------------------------------------------------------------
-- The view
---------------------------------------------------------------------------
function View.Create(parent, width, height)
	local v = CreateFrame("Frame", nil, parent)
	v:SetSize(width, height)
	v:Hide()

	-- top bar
	local back = T.DarkButton(v, "LOBBY", 76, 28)
	back:SetPoint("TOPLEFT")
	back:SetScript("OnClick", function() ns.Main:ShowView("lobby") end)
	local title = T.Text(v, T.FONT_DISPLAY, 18, Mix(C.lilac, hex("ffffff"), 0.55))
	title:SetPoint("LEFT", back, "RIGHT", 14, 0)
	title:SetText("OGRE'S WHEEL")
	local phase = T.Pill(v, "", { 1, 1, 1, 0.08 }, C.green)
	phase:SetPoint("LEFT", title, "RIGHT", 12, 0)
	local practice = T.Pill(v, "PRACTICE · BOTS", { ORANGE[1], ORANGE[2], ORANGE[3], 0.16 }, ORANGE)
	practice:SetPoint("LEFT", phase.label, "RIGHT", 18, 0)
	local hostInfo = T.Text(v, T.FONT_BODY, 11, C.textDim)
	hostInfo:SetJustifyH("RIGHT")
	hostInfo:SetPoint("TOPRIGHT", 0, -8)

	-- left: the ogre behind the wheel, the pool under it
	local wheel
	local ogre = CreateOgre(v, function()
		wheel:ClearAllPoints()
		wheel:SetPoint("TOP", v, "TOPLEFT", LEFT_W / 2, WHEEL_TOP)
	end)
	wheel = Wheel.Create(v, RADIUS)
	wheel:SetPoint("TOP", v, "TOPLEFT", LEFT_W / 2, WHEEL_TOP_OGRE)
	local poolLabel = T.Text(v, T.FONT_BOLD, 10, C.textDim)
	poolLabel:SetJustifyH("CENTER")
	poolLabel:SetPoint("TOP", wheel, "BOTTOM", 0, -2)
	poolLabel:SetText("POOL")
	local pool = T.Text(v, T.FONT_DISPLAY, 24, C.gold)
	pool:SetJustifyH("CENTER")
	pool:SetPoint("TOP", poolLabel, "BOTTOM", 0, -4)
	local pointerName = T.Text(v, T.FONT_BOLD, 14, C.text)
	pointerName:SetJustifyH("CENTER")
	pointerName:SetPoint("TOP", pool, "BOTTOM", 0, -8)
	wheel.onPointer = function(name)
		local slice = name and wheel.byName[name]
		pointerName:SetText(slice and (ColorCode(slice.color) .. U.Short(name) .. "|r") or "")
	end

	-- right: panel
	local panel = CreateFrame("Frame", nil, v)
	panel:SetPoint("TOPLEFT", LEFT_W + 16, -40)
	panel:SetPoint("BOTTOMRIGHT")
	T.Solid(panel, hex("0d0520", 0.9)):SetAllPoints()
	T.Border(panel, hex("4a2a80"), 1)
	local innerW = width - LEFT_W - 16 - 28

	local section = T.Text(panel, T.FONT_BOLD, 10, C.textDim)
	section:SetPoint("TOPLEFT", 14, -12)
	local sectionMeta = T.Text(panel, T.FONT_BODY, 10, DIM)
	sectionMeta:SetJustifyH("RIGHT")
	sectionMeta:SetPoint("TOPRIGHT", -14, -12)
	local list = CreateList(panel, innerW)
	list:SetPoint("TOPLEFT", 14, -30)
	local message = T.Text(panel, T.FONT_BODY, 11, C.textDim)
	message:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -16)
	message:SetWidth(innerW)

	-- actions
	local actions = CreateFrame("Frame", nil, panel)
	actions:SetPoint("BOTTOMLEFT", 14, 14)
	actions:SetSize(innerW, 82)

	local stake = CreateStakeBox(actions)
	stake:SetPoint("TOPLEFT")
	local quick = {}
	for i, q in ipairs({ { "+10", 10 }, { "+50", 50 }, { "MAX" } }) do
		local b = T.DarkButton(actions, q[1], 46, 34)
		b:SetPoint("LEFT", stake, "RIGHT", 6 + (i - 1) * 52, 0)
		b:SetScript("OnClick", function()
			local round = J.round
			if not round then return end
			local cap = round.practice and round.limit or math.min(round.limit, U.PlayerGold())
			local value = q[2] and (stake:GetNumber() + q[2]) or cap
			stake:SetNumber(math.max(0, math.min(value, cap)))
		end)
		quick[i] = b
	end
	local betBtn = T.GoldButton(actions, "BET", 92, 34)
	betBtn:SetPoint("TOPRIGHT")
	local function PlaceBet()
		stake:ClearFocus()
		local ok, err = J.Bet(stake:GetNumber())
		if not ok and err then ns.Print(err) end
	end
	betBtn:SetScript("OnClick", PlaceBet)
	stake:SetScript("OnEnterPressed", PlaceBet)

	local lockBtn = T.GoldButton(actions, "CLOSE BETS", 140, 34)
	lockBtn:SetPoint("BOTTOMLEFT")
	lockBtn:SetScript("OnClick", function()
		local ok, err = J.Lock()
		if not ok and err then ns.Print(err) end
	end)
	local cancelBtn = T.DarkButton(actions, "CANCEL", 80, 34)
	cancelBtn:SetPoint("LEFT", lockBtn, "RIGHT", 10, 0)
	cancelBtn:SetScript("OnClick", function() J.Cancel() end)

	-- host setup: the stake limit is chosen before anyone can bet
	local limitBox = CreateStakeBox(actions)
	limitBox:SetPoint("TOPLEFT")
	local function ApplyLimit()
		limitBox:ClearFocus()
		local ok, err = J.SetLimit(limitBox:GetNumber())
		if not ok and err then ns.Print(err) end
		if J.round then limitBox:SetNumber(J.round.limit) end
		return ok
	end
	limitBox:SetScript("OnEnterPressed", ApplyLimit)
	local presets = {}
	for i, amount in ipairs({ 10, 50, 100, 500 }) do
		local b = T.DarkButton(actions, amount .. "g", 52, 34)
		b:SetPoint("LEFT", limitBox, "RIGHT", 6 + (i - 1) * 58, 0)
		b:SetScript("OnClick", function()
			limitBox:SetNumber(amount)
			ApplyLimit()
		end)
		presets[i] = b
	end
	local openBtn = T.GoldButton(actions, "OPEN BETS", 140, 34)
	openBtn:SetPoint("BOTTOMLEFT")
	openBtn:SetScript("OnClick", function()
		if not ApplyLimit() then return end
		local ok, err = J.OpenBets()
		if not ok and err then ns.Print(err) end
	end)

	local rollBtn = T.GoldButton(actions, "ROLL!", 170, 44)
	rollBtn:SetPoint("LEFT", actions, "LEFT", 0, 0)
	rollBtn.label:SetFont(T.FONT_DISPLAY, 18, "")
	rollBtn:SetScript("OnClick", function() J.RollNow() end)

	local headline = T.Text(actions, T.FONT_DISPLAY, 18, C.gold)
	headline:SetPoint("TOPLEFT", 0, 0)
	headline:SetWidth(innerW)

	local newBtn = T.GoldButton(actions, "NEW ROUND", 140, 34)
	newBtn:SetPoint("BOTTOMLEFT")
	newBtn:SetScript("OnClick", function()
		J.Dismiss()
		ns.Main:StartGame("wheel")
	end)
	local lobbyBtn = T.DarkButton(actions, "BACK TO LOBBY", 130, 34)
	lobbyBtn:SetScript("OnClick", function()
		J.Dismiss()
		ns.Main:ShowView("lobby")
	end)

	local info = T.Text(actions, T.FONT_BODY, 11, C.textDim)
	info:SetJustifyH("RIGHT")
	info:SetPoint("BOTTOMRIGHT", 0, 10)
	info:SetWidth(innerW - 130)

	-- players (not the host) can walk away from a round whose host is gone
	local function Quit()
		local round = J.round
		local wasRolling = round and round.phase == "ROLLING" and round.bets[U.Me()]
		J.Abandon()
		ns.Print(wasRolling and "You left the round. If the host still finishes it, you may owe gold: check with them."
			or "You left the round.")
		ns.Main:ShowView("lobby")
	end
	local quitBtn = T.DarkButton(actions, "LEAVE ROUND", 120, 30)
	quitBtn:SetPoint("BOTTOMLEFT")
	quitBtn:SetScript("OnClick", Quit)

	local allActions = { stake, betBtn, lockBtn, cancelBtn, rollBtn, headline, newBtn, lobbyBtn, info,
		limitBox, openBtn, quitBtn }
	for _, q in ipairs(quick) do allActions[#allActions + 1] = q end
	for _, p in ipairs(presets) do allActions[#allActions + 1] = p end
	local function ShowOnly(...)
		for _, w in ipairs(allActions) do w:Hide() end
		for i = 1, select("#", ...) do select(i, ...):Show() end
	end

	-----------------------------------------------------------------------
	-- Refresh from the round state
	-----------------------------------------------------------------------
	local lastSignature, spunRound

	local function PlayerRows(round, showRolls)
		local me = U.Me()
		local names = U.SortedKeys(round.bets)
		local total = 0
		for _, name in ipairs(names) do total = total + round.bets[name] end
		local data = {}
		for i, name in ipairs(names) do
			local bet = round.bets[name]
			local label = U.Short(name)
			if name == round.host then label = label .. "  |cff9d8fbfhost|r" end
			local right = string.format("%d%%", math.floor(bet / total * 100 + 0.5))
			local mid = U.Gold(bet)
			if showRolls then
				local roll = (round.rolls and round.rolls[name]) or (round.seen and round.seen[name])
				local sub = round.subs and round.subs[name]
				right = roll and (U.Thousands(roll) .. (sub and "*" or "")) or "|cff9d8fbf...|r"
			end
			data[i] = {
				color = Wheel.ColorFor(i), left = label, mid = mid, right = right,
				mine = name == me, leftColor = name == me and C.gold or C.text,
			}
		end
		return data, names, total
	end

	local function SettlementRows(round)
		local me = U.Me()
		local res = round.result
		local index = {}
		for i, name in ipairs(res.names) do index[name] = i end
		local data = {}
		for _, t in ipairs(res.transfers) do
			data[#data + 1] = {
				color = Wheel.ColorFor(index[t.from]),
				left = U.Short(t.from),
				mid = "pays " .. U.Short(t.to),
				right = U.Gold(t.amount),
				mine = t.from == me or t.to == me,
				leftColor = t.from == me and C.gold or C.text,
			}
		end
		return data
	end

	function v:Refresh()
		local round = J.round
		if not round or (round.game or "wheel") ~= "wheel" then
			ns.Main:ShowView(round and round.game or "lobby")
			return
		end
		local me = U.Me()
		local isHost = J.IsHost(round)
		local p = PHASES[round.phase] or PHASES.BETTING
		phase.label:SetText(p[1])
		phase.label:SetTextColor(T.Unpack(p[2]))
		practice:SetShown(round.practice)
		hostInfo:SetText((round.practice and "You host" or ("Host: " .. U.Short(round.host)))
			.. "  ·  limit " .. U.Gold(round.limit))

		-- wheel slices follow the bets (only rebuilt when they change)
		local data, names, total = PlayerRows(round, round.phase ~= "BETTING")
		local parts = {}
		for _, name in ipairs(names) do parts[#parts + 1] = name .. round.bets[name] end
		local signature = table.concat(parts, ",")
		if signature ~= lastSignature and round.phase ~= "SPINNING" and round.phase ~= "DONE" then
			lastSignature = signature
			local slices = {}
			for i, name in ipairs(names) do slices[i] = { name = name, amount = round.bets[name] } end
			wheel:SetSlices(slices)
			wheel:Highlight(nil)
		end
		pool:SetText(U.Thousands(total) .. " |cffcdb9eeg|r")
		wheel:SetIdle(round.phase == "SETUP" or round.phase == "BETTING" or round.phase == "ROLLING")

		-- start the spin once per round (also when the window opens mid-spin or later)
		local res = round.result
		if res and spunRound ~= round.id then
			spunRound = round.id
			local slices = {}
			for i, name in ipairs(res.names) do slices[i] = { name = name, amount = round.bets[name] } end
			wheel:SetSlices(slices)
			lastSignature = nil
			wheel:Spin(res.winner, res.r, res.turns, round.spinStart or 0, J.SPIN_SECONDS, function()
				wheel:Highlight(res.winner)
				if J.round == round then v:Refresh() end
			end)
		end
		if round.phase ~= "SPINNING" then pointerName:SetText("") end

		-- right panel
		local myBet = round.bets[me]
		local note, noteColor = round.warning or round.error, round.error and RED or ORANGE
		if round.phase == "SETUP" then
			section:SetText("SET UP THE ROUND")
			sectionMeta:SetText("only you can see this")
			list:SetData({})
			ShowOnly(limitBox, presets[1], presets[2], presets[3], presets[4], openBtn, cancelBtn)
			if not limitBox:HasFocus() then limitBox:SetNumber(round.limit) end
			message:SetText("Choose the stake limit: everyone can bet from 1g up to it. It can't change once bets are open. "
				.. (round.practice and "Then open bets for the bots." or "Then open bets for your group."))
			message:SetTextColor(T.Unpack(C.textDim))

		elseif round.phase == "BETTING" then
			section:SetText("PLAYERS")
			sectionMeta:SetText(#names .. " in the pool")
			list:SetData(data)
			local hint
			if isHost then
				ShowOnly(stake, betBtn, quick[1], quick[2], quick[3], lockBtn, cancelBtn)
				lockBtn:SetActive(#names >= 2)
				if #names < 2 then hint = "You can close bets once at least 2 players are in." end
			else
				ShowOnly(stake, betBtn, quick[1], quick[2], quick[3], info, quitBtn)
				info:SetText("Waiting for " .. U.Short(round.host) .. " to close bets")
			end
			betBtn:SetLabel(myBet and "CHANGE" or "BET")
			message:SetText(note or hint or (myBet and ("Your stake: " .. U.Gold(myBet) .. ". Enter 0 to withdraw.")
				or "Bigger stake, bigger slice. The winner takes the whole pool."))
			message:SetTextColor(T.Unpack(note and noteColor or C.textDim))

		elseif round.phase == "ROLLING" then
			section:SetText("PLAYERS")
			local rolled = 0
			for _, name in ipairs(names) do
				if round.seen and round.seen[name] then rolled = rolled + 1 end
			end
			sectionMeta:SetText(rolled .. "/" .. #names .. " rolled")
			list:SetData(data)
			local left = math.max(0, math.ceil((round.deadline or 0) - GetTime()))
			if myBet and not J.HasRolled() then
				ShowOnly(rollBtn, info)
				rollBtn:SetActive(left > 0)
				info:SetText(left > 0 and ("Roll within |cffffd84d" .. left .. "s|r") or "Too late, the host rolls for you")
			elseif not isHost and GetTime() > (round.deadline or 0) + 20 then
				-- the host should have finished long ago (offline, /reload, or messages blocked)
				ShowOnly(info, quitBtn)
				info:SetText("The host hasn't finished the round")
			else
				ShowOnly(info)
				info:SetText(left > 0 and ("Waiting for rolls  ·  " .. left .. "s") or "The host rolls for missing players...")
			end
			message:SetText(note or "Everyone's /roll makes the seed, so nobody can know the winner in advance.")
			message:SetTextColor(T.Unpack(note and noteColor or C.textDim))

		elseif round.phase == "SPINNING" then
			section:SetText("PLAYERS")
			sectionMeta:SetText("* = substitute roll by the host")
			list:SetData(data)
			ShowOnly(headline)
			headline:SetText("THE OGRE SPINS THE WHEEL...")
			headline:SetTextColor(T.Unpack(C.pink))
			message:SetText(note or "")
			message:SetTextColor(T.Unpack(noteColor))

		elseif round.phase == "DONE" then
			section:SetText("SETTLEMENT")
			sectionMeta:SetText("everyone pays the winner their stake")
			list:SetData(SettlementRows(round))
			local canRestart = isHost or round.practice
			ShowOnly(headline, lobbyBtn, canRestart and newBtn or lobbyBtn)
			lobbyBtn:ClearAllPoints()
			if canRestart then
				lobbyBtn:SetPoint("LEFT", newBtn, "RIGHT", 10, 0)
			else
				lobbyBtn:SetPoint("BOTTOMLEFT")
			end
			headline:SetText(U.Short(res.winner):upper() .. " WINS " .. U.Thousands(res.gain) .. " GOLD")
			headline:SetTextColor(T.Unpack(C.gold))
			local count = #res.transfers
			local summary = U.Short(res.winner) .. " receives " .. U.Gold(res.gain) .. " from "
				.. count .. (count == 1 and " player." or " players.")
			if myBet and res.winner ~= me then
				summary = "You pay " .. U.Short(res.winner) .. " " .. U.Gold(myBet) .. ". " .. summary
			elseif res.winner == me then
				summary = "You won! " .. summary
			end
			if round.practice then summary = summary .. " |cff9d8fbf(practice: no gold moves)|r" end
			message:SetText(note and (note .. "\n" .. summary) or summary)
			message:SetTextColor(T.Unpack(note and noteColor or C.text))

		else -- CANCELLED
			section:SetText("PLAYERS")
			sectionMeta:SetText("")
			list:SetData(data)
			ShowOnly(headline, lobbyBtn)
			lobbyBtn:ClearAllPoints()
			lobbyBtn:SetPoint("BOTTOMLEFT")
			headline:SetText("ROUND CANCELLED")
			headline:SetTextColor(T.Unpack(RED))
			message:SetText(round.error or "Nobody pays.")
			message:SetTextColor(T.Unpack(C.textDim))
		end
	end

	-- countdowns tick while the view is open; the ogre acts every frame
	local clock = 0
	v:SetScript("OnUpdate", function(self, dt)
		ogre:Update(J.round)
		clock = clock + dt
		if clock >= 0.25 then
			clock = 0
			if J.round and J.round.phase == "ROLLING" then self:Refresh() end
		end
	end)
	v:SetScript("OnShow", function(self)
		ogre:Show()
		self:Refresh()
	end)
	v:SetScript("OnHide", function() ogre:Hide() end)
	J.OnChange(function()
		if v:IsVisible() then v:Refresh() end
	end)
	return v
end
