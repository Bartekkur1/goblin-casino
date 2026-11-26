-- Brewfest Brawl screen: the players stand at the bar (3D models, behind the counter), each with a
-- drunk meter over their head. They sway more the drunker they get, take a swig with every mug,
-- and drop under the table past 100%.
local ADDON, ns = ...
local T, U, J, B, D, W = ns.Theme, ns.Util, ns.Jackpot, ns.Brewfest, ns.Derby, ns.Widgets
local C, hex, Mix = T.C, T.hex, T.Mix

local View = {}
ns.BrewfestView = View

local STAGE_H = 318
local COUNTER_H = 62
local CAM = 1.3
local AMBER = hex("ffb347")
local RED, DIM = hex("ff6b6b"), hex("9d8fbf")
local WHITE = hex("ffffff")
local ANIM = { stand = 0, death = 1, dead = 6 }
local SWIG = { 61, 0 }      -- EmoteEat (a swig from the mug), else stand
-- who stands at the bar when a player's own character can't be shown (bots, players far away):
-- an ogre (creature display ID for SetDisplayInfo, the same one as Ogre's Wheel's croupier;
-- SetCreature is unreliable on Forever, SetDisplayInfo always works)
local STAND_IN = 655

local PHASES = {
	SETUP = { "SETUP", C.gold },
	BETTING = { "ENTRIES OPEN", C.green },
	ROLLING = { "TAPS OPEN", AMBER },
	SPINNING = { "LAST CALL", C.pink },
	DONE = { "RESULT", C.gold },
	CANCELLED = { "CANCELLED", RED },
}

local function ColorCode(c)
	return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
end

local function Clamp(x, a, b) return math.max(a, math.min(b, x)) end

-- green while sober, yellow when tipsy, red near the edge
local function MeterColor(total)
	if total > B.LIMIT then return DIM end
	if total >= 85 then return RED end
	if total >= 60 then return C.gold end
	return C.green
end

function View.Create(parent, width, height)
	local v = CreateFrame("Frame", nil, parent)
	v:SetSize(width, height)
	v:Hide()

	-----------------------------------------------------------------------
	-- top bar
	-----------------------------------------------------------------------
	local back = T.DarkButton(v, "LOBBY", 76, 28)
	back:SetPoint("TOPLEFT")
	back:SetScript("OnClick", function() ns.Main:ShowView("lobby") end)
	local title = T.Text(v, T.FONT_DISPLAY, 18, Mix(AMBER, WHITE, 0.35))
	title:SetPoint("LEFT", back, "RIGHT", 14, 0)
	title:SetText("BREWFEST BRAWL")
	local phase = T.Pill(v, "", { 1, 1, 1, 0.08 }, C.green)
	phase:SetPoint("LEFT", title, "RIGHT", 12, 0)
	local practice = T.Pill(v, "PRACTICE · BOTS", { 1, 0.6, 0.2, 0.16 }, hex("ffb347"))
	practice:SetPoint("LEFT", phase.label, "RIGHT", 18, 0)
	local hostInfo = T.Text(v, T.FONT_BODY, 11, C.textDim)
	hostInfo:SetJustifyH("RIGHT")
	hostInfo:SetPoint("TOPRIGHT", 0, -8)

	-----------------------------------------------------------------------
	-- stage: the tavern, the bar counter in front
	-----------------------------------------------------------------------
	local stage = CreateFrame("Frame", nil, v)
	stage:SetPoint("TOPLEFT", 0, -40)
	stage:SetSize(width, STAGE_H)
	stage:SetClipsChildren(true)
	T.Gradient(stage, "VERTICAL", hex("1c0f06"), hex("3a2110")):SetAllPoints()
	T.Border(stage, Mix(AMBER, C.bgDeep, 0.5), 1)
	local sign = T.Text(stage, T.FONT_DISPLAY, 46, AMBER)
	sign:SetPoint("TOP", 0, -10)
	sign:SetText("BREWFEST")
	sign:SetAlpha(0.08)

	local emptyText = T.Text(stage, T.FONT_BOLD, 13, C.textDim)
	emptyText:SetJustifyH("CENTER")
	emptyText:SetPoint("CENTER", 0, 10)
	emptyText:SetText("Nobody at the bar yet. Join in!")

	-- the counter hides the players' legs
	local counter = CreateFrame("Frame", nil, stage)
	counter:SetPoint("BOTTOMLEFT")
	counter:SetPoint("BOTTOMRIGHT")
	counter:SetHeight(COUNTER_H)
	counter:SetFrameLevel(stage:GetFrameLevel() + 40)
	T.Gradient(counter, "VERTICAL", hex("2a1407"), hex("6b3a16")):SetAllPoints()
	local edge = T.Solid(counter, hex("a8692c"), "ARTWORK")
	edge:SetPoint("TOPLEFT")
	edge:SetPoint("TOPRIGHT")
	edge:SetHeight(5)

	-- names, meters and gold over the models
	local labels = CreateFrame("Frame", nil, stage)
	labels:SetAllPoints()
	labels:SetFrameLevel(stage:GetFrameLevel() + 55)

	local seats = {}
	local function Seat(i)
		if seats[i] then return seats[i] end
		local seat = CreateFrame("Frame", nil, stage)
		seat.mine = T.Circle(seat, 40, "BACKGROUND", 2)
		seat.mine:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.16)
		local model = CreateFrame("PlayerModel", nil, seat)
		model:SetAllPoints()
		model:SetScript("OnModelLoaded", function(self)
			pcall(self.SetFacing, self, seat.facing or 0)
			pcall(self.SetCamDistanceScale, self, CAM)
			if seat.anim then pcall(self.SetAnimation, self, seat.anim) end
		end)
		seat.model = model
		-- over the head: name, then the meter with the percentage
		local m = CreateFrame("Frame", nil, labels)
		m:SetSize(76, 30)
		seat.meter = m
		seat.name = T.Text(m, T.FONT_BOLD, 11, C.text)
		seat.name:SetJustifyH("CENTER")
		seat.name:SetPoint("TOP")
		seat.name:SetWidth(120)
		seat.name:SetWordWrap(false)
		local bar = CreateFrame("Frame", nil, m)
		bar:SetSize(76, 9)
		bar:SetPoint("BOTTOM", 0, 2)
		T.Solid(bar, hex("000000", 0.6)):SetAllPoints()
		seat.fill = T.Solid(bar, C.green, "ARTWORK")
		seat.fill:SetPoint("TOPLEFT")
		seat.fill:SetPoint("BOTTOMLEFT")
		seat.fill:SetWidth(1)
		seat.pct = T.Text(m, T.FONT_BOLD, 10, C.text)
		seat.pct:SetPoint("LEFT", bar, "RIGHT", 4, 0)
		seat.tag = T.Text(m, T.FONT_DISPLAY, 12, C.cyan)
		seat.tag:SetJustifyH("CENTER")
		seat.tag:SetPoint("TOP", m, "BOTTOM", 0, -2)
		seat.money = T.Text(labels, T.FONT_DISPLAY, 14, C.green)
		seat.money:SetJustifyH("CENTER")
		seat.money:SetPoint("BOTTOM", m, "TOP", 0, 2)
		seats[i] = seat
		return seat
	end

	local function SetAnim(seat, id)
		if seat.anim == id then return end
		seat.anim = id
		pcall(seat.model.SetAnimation, seat.model, id)
	end

	-- the first animation of `list` this seat's model has (cached once the model knows)
	local function Pick(seat, key, list)
		seat.picks = seat.picks or {}
		if seat.picks[key] then return seat.picks[key] end
		for _, id in ipairs(list) do
			local ok, has = pcall(seat.model.HasAnimation, seat.model, id)
			if ok and has then
				seat.picks[key] = id
				return id
			end
		end
		return list[#list]
	end

	-- the player's own character when it can be shown, else the stand-in ogre
	local function SetSkin(seat, name)
		local unit = W.UnitFor(name)
		local visible = unit and UnitIsVisible(unit)
		local want = visible and ("unit:" .. name) or "stand-in"
		if seat.skin == want then return end
		seat.skin = want
		seat.anim, seat.picks = nil, nil
		if not (visible and pcall(seat.model.SetUnit, seat.model, unit)) then
			pcall(seat.model.SetDisplayInfo, seat.model, STAND_IN)
		end
		pcall(seat.model.SetFacing, seat.model, seat.facing or 0)
		pcall(seat.model.SetCamDistanceScale, seat.model, CAM)
		SetAnim(seat, ANIM.stand)
	end

	local seatOf = {}
	local function Layout(names)
		local n = #names
		wipe(seatOf)
		for _, seat in ipairs(seats) do
			seat:Hide()
			seat.meter:Hide()
			seat.money:Hide()
		end
		-- up to 6 in one row; more: a back row (smaller, higher) and a front row
		local rows
		if n <= 6 then
			rows = { { count = n, size = n <= 4 and 132 or 116 } }
		else
			local backCount = math.floor(n / 2)
			rows = {
				{ count = backCount, size = 92, back = true },
				{ count = n - backCount, size = 112 },
			}
		end
		local k = 0
		for r, row in ipairs(rows) do
			for j = 1, row.count do
				k = k + 1
				local name = names[k]
				local size = row.size
				local x = width * (j - 0.5) / row.count + (row.back and width / row.count * 0.25 or 0)
				-- the lowest 30% of the front row is behind the counter; the back row stands higher
				local y = STAGE_H - COUNTER_H - size / 2 + size * 0.3 - (row.back and 70 or 0)
				local seat = Seat(k)
				seat:SetSize(size, size)
				seat:SetFrameLevel(stage:GetFrameLevel() + (row.back and 4 or 14) + j)
				seat.model:SetFrameLevel(seat:GetFrameLevel() + 1)
				seat.x, seat.y, seat.size = x, y, size
				seat.facing = Clamp((width / 2 - x) / width * 0.9, -0.5, 0.5)
				-- your own seat: a soft gold glow behind you (the floor is behind the counter)
				seat.mine:ClearAllPoints()
				seat.mine:SetPoint("CENTER", seat, "CENTER", 0, size * 0.15)
				seat.mine:SetSize(size * 0.75, size * 0.75)
				seat.meter:ClearAllPoints()
				seat.meter:SetPoint("BOTTOM", stage, "TOPLEFT", x, -(y - size * 0.5 + 2))
				seat.name:SetFont(T.FONT_BOLD, n > 8 and 10 or 11, "")
				seat.sway = r * 1.3 + j * 2.1
				seat:Show()
				seat.meter:Show()
				seatOf[name] = seat
			end
		end
		emptyText:SetShown(n == 0)
	end

	-----------------------------------------------------------------------
	-- settlement overlay
	-----------------------------------------------------------------------
	local overlay = CreateFrame("Frame", nil, stage)
	overlay:SetAllPoints()
	overlay:SetFrameLevel(stage:GetFrameLevel() + 90)
	overlay:EnableMouse(true)
	T.Solid(overlay, hex("0d0520", 0.95)):SetAllPoints()
	local ovTitle = T.Text(overlay, T.FONT_BOLD, 10, C.textDim)
	ovTitle:SetPoint("TOPLEFT", 14, -10)
	ovTitle:SetText("SETTLEMENT  ·  EVERYONE PAYS THE WINNER THEIR ENTRY")
	local ovMeta = T.Text(overlay, T.FONT_BODY, 10, DIM)
	ovMeta:SetJustifyH("RIGHT")
	ovMeta:SetPoint("TOPRIGHT", -14, -10)
	local ovList = W.List(overlay, width - 28, 10, 26)
	ovList:SetPoint("TOPLEFT", 14, -28)
	overlay:Hide()
	local showBar = false

	-----------------------------------------------------------------------
	-- bottom: commentary on the left, actions on the right
	-----------------------------------------------------------------------
	local bottom = CreateFrame("Frame", nil, v)
	bottom:SetPoint("TOPLEFT", 0, -(40 + STAGE_H + 10))
	bottom:SetPoint("BOTTOMRIGHT")
	local headline = T.Text(bottom, T.FONT_DISPLAY, 18, C.gold)
	headline:SetPoint("TOPLEFT", 2, -4)
	headline:SetWidth(width - 340)
	headline:SetWordWrap(false)
	local message = T.Text(bottom, T.FONT_BODY, 11, C.textDim)
	message:SetPoint("TOPLEFT", headline, "BOTTOMLEFT", 0, -8)
	message:SetWidth(width - 340)
	message:SetSpacing(2)

	local actions = CreateFrame("Frame", nil, bottom)
	actions:SetPoint("BOTTOMRIGHT")
	actions:SetSize(320, 74)

	local joinBtn = T.GoldButton(actions, "JOIN", 200, 34)
	joinBtn:SetPoint("TOPRIGHT")
	joinBtn:SetScript("OnClick", function()
		local round = J.round
		if not round then return end
		local ok, err = J.Bet(round.limit)
		if not ok and err then ns.Print(err) end
	end)
	local leaveBtn = T.DarkButton(actions, "LEAVE THE BAR", 200, 34)
	leaveBtn:SetPoint("TOPRIGHT")
	leaveBtn:SetScript("OnClick", function() J.Bet(0) end)

	local lockBtn = T.GoldButton(actions, "OPEN THE TAPS", 150, 34)
	lockBtn:SetPoint("BOTTOMLEFT")
	lockBtn:SetScript("OnClick", function()
		local ok, err = J.Lock()
		if not ok and err then ns.Print(err) end
	end)
	local cancelBtn = T.DarkButton(actions, "CANCEL", 64, 34)
	cancelBtn:SetPoint("LEFT", lockBtn, "RIGHT", 6, 0)
	cancelBtn:SetScript("OnClick", function() J.Cancel() end)

	local feeBox = W.AmountBox(actions, 80, 34, 15)
	feeBox:SetPoint("TOPLEFT")
	local function ApplyFee()
		feeBox:ClearFocus()
		local ok, err = J.SetLimit(feeBox:GetNumber())
		if not ok and err then ns.Print(err) end
		if J.round then feeBox:SetNumber(J.round.limit) end
		return ok
	end
	feeBox:SetScript("OnEnterPressed", ApplyFee)
	local presets = {}
	for i, amount in ipairs({ 5, 10, 20, 50 }) do
		local b = T.DarkButton(actions, amount .. "g", 50, 34)
		b:SetPoint("LEFT", feeBox, "RIGHT", 6 + (i - 1) * 56, 0)
		b:SetScript("OnClick", function()
			feeBox:SetNumber(amount)
			ApplyFee()
		end)
		presets[i] = b
	end
	local openBtn = T.GoldButton(actions, "OPEN ENTRIES", 140, 34)
	openBtn:SetPoint("BOTTOMLEFT")
	openBtn:SetScript("OnClick", function()
		if not ApplyFee() then return end
		local ok, err = J.OpenBets()
		if not ok and err then ns.Print(err) end
	end)

	-- while the taps are open
	local drinkBtn = T.GoldButton(actions, "ANOTHER MUG!", 186, 44)
	drinkBtn:SetPoint("TOPRIGHT")
	drinkBtn.label:SetFont(T.FONT_DISPLAY, 17, "")
	drinkBtn:SetScript("OnClick", function()
		local ok, err = B.Drink()
		if not ok and err then ns.Print(err) end
	end)
	local stopBtn = T.DarkButton(actions, "ENOUGH", 120, 44)
	stopBtn:SetPoint("TOPLEFT")
	stopBtn:SetScript("OnClick", function()
		local ok, err = B.Stop()
		if not ok and err then ns.Print(err) end
	end)

	local newBtn = T.GoldButton(actions, "NEW ROUND", 130, 34)
	newBtn:SetPoint("BOTTOMLEFT")
	newBtn:SetScript("OnClick", function()
		J.Dismiss()
		ns.Main:StartGame("brewfest")
	end)
	local lobbyBtn = T.DarkButton(actions, "BACK TO LOBBY", 130, 34)
	lobbyBtn:SetScript("OnClick", function()
		J.Dismiss()
		ns.Main:ShowView("lobby")
	end)
	local replayBtn = T.DarkButton(actions, "VIEW BAR", 130, 30)
	replayBtn:SetPoint("TOPRIGHT")
	replayBtn:SetScript("OnClick", function()
		showBar = not showBar
		v:Refresh()
	end)

	local info = T.Text(actions, T.FONT_BODY, 11, C.textDim)
	info:SetJustifyH("RIGHT")
	info:SetPoint("BOTTOMRIGHT", 0, 6)
	info:SetWidth(320)

	local function Quit()
		local round = J.round
		local wasPlaying = round and round.phase == "ROLLING" and round.bets[U.Me()]
		J.Abandon()
		ns.Print(wasPlaying and "You left the round. If the host still finishes it, you may owe gold: check with them."
			or "You left the round.")
		ns.Main:ShowView("lobby")
	end
	local quitBtn = T.DarkButton(actions, "QUIT", 64, 30)
	quitBtn:SetPoint("BOTTOMLEFT")
	quitBtn:SetScript("OnClick", Quit)

	local allActions = { joinBtn, leaveBtn, lockBtn, cancelBtn, feeBox, openBtn, drinkBtn, stopBtn,
		newBtn, lobbyBtn, replayBtn, info, quitBtn }
	for _, p in ipairs(presets) do allActions[#allActions + 1] = p end
	local function ShowOnly(...)
		for _, w in ipairs(allActions) do w:Hide() end
		for i = 1, select("#", ...) do select(i, ...):Show() end
	end

	-----------------------------------------------------------------------
	-- the bar, every frame
	-----------------------------------------------------------------------
	local names, colors = {}, {}
	local news, newsAt = nil, 0   -- the latest thing that happened ("Hymel is under the table!")

	local function Animate(round)
		local now = GetTime()
		local res = round.result
		local live = round.phase == "ROLLING"
		for name, seat in pairs(seatOf) do
			local s = round.brew and round.brew[name]
			local total = s and s.total or 0
			local mugs = s and #s.mugs or 0
			-- a new mug: a swig (and a gulp); over the limit: down they go
			if mugs ~= (seat.mugs or 0) then
				if mugs > (seat.mugs or 0) then
					seat.swigUntil = now + 1.2
					if live then ns.Sound.Play("gulp") end
				end
				seat.mugs = mugs
			end
			local out = s and s.out
			if out and not seat.out then
				seat.outAt = now
				if live then
					ns.Sound.Play("passout")
					news, newsAt = U.Short(name) .. " is under the table! (" .. total .. "%)", now
				end
			elseif s and s.stopped and not seat.stopped and live then
				news, newsAt = U.Short(name) .. " has had enough at " .. total .. "%.", now
			end
			seat.out, seat.stopped = out, s and s.stopped

			-- sway: more the drunker they are
			local drunk = Clamp(total / B.LIMIT, 0, 1)
			local sway = out and 0 or math.sin(now * (1.2 + drunk) + seat.sway) * drunk
			seat:ClearAllPoints()
			seat:SetPoint("CENTER", stage, "TOPLEFT", seat.x + sway * 9, -seat.y)
			pcall(seat.model.SetFacing, seat.model, (seat.facing or 0) + sway * 0.5)

			local winner = res and res.winner == name and round.phase ~= "ROLLING"
			if out then
				SetAnim(seat, (now - (seat.outAt or 0)) < 1.3 and ANIM.death or ANIM.dead)
			elseif winner then
				SetAnim(seat, Pick(seat, "cheer", D.CELEBRATE))
			elseif seat.swigUntil and now < seat.swigUntil then
				SetAnim(seat, Pick(seat, "swig", SWIG))
			else
				SetAnim(seat, ANIM.stand)
			end

			-- meter
			local shown = math.min(total, B.LIMIT)
			seat.fill:SetWidth(math.max(1, 76 * shown / B.LIMIT))
			seat.fill:SetColorTexture(T.Unpack(MeterColor(total)))
			seat.pct:SetText(total .. "%")
			seat.pct:SetTextColor(T.Unpack(MeterColor(total)))
			if out then
				seat.tag:SetText("Zzz...")
				seat.tag:SetTextColor(T.Unpack(DIM))
			elseif s and s.stopped then
				seat.tag:SetText("ENOUGH!")
				seat.tag:SetTextColor(T.Unpack(C.cyan))
			elseif name == U.Me() and s and B.Pending(s) then
				seat.tag:SetText("*gulp*")
				seat.tag:SetTextColor(T.Unpack(AMBER))
			else
				seat.tag:SetText(mugs > 0 and (mugs .. (mugs == 1 and " mug" or " mugs")) or "")
				seat.tag:SetTextColor(T.Unpack(C.textDim))
			end

			-- gold once it's decided
			if res and round.phase ~= "ROLLING" then
				seat.money:Show()
				if winner then
					seat.money:SetText("+" .. U.Thousands(res.gain) .. "g")
					seat.money:SetTextColor(T.Unpack(C.green))
				else
					seat.money:SetText("-" .. U.Thousands(round.bets[name] or 0) .. "g")
					seat.money:SetTextColor(T.Unpack(RED))
				end
			else
				seat.money:Hide()
			end
		end
		-- the winner is announced once, live
		if round.phase == "SPINNING" and res then
			ns.Sound.At("cheers", round, now - (round.spinStart or now), 0.2)
		end
	end

	local function ResetBar()
		news = nil
		for _, seat in pairs(seatOf) do
			seat.mugs, seat.out, seat.stopped, seat.swigUntil = 0, nil, nil, nil
			SetAnim(seat, ANIM.stand)
			seat.money:Hide()
		end
	end

	local barRound
	function v:Refresh()
		local round = J.round
		if not round or round.game ~= "brewfest" then
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
			.. "  ·  entry " .. U.Gold(round.limit))

		if barRound ~= round.id then
			barRound = round.id
			showBar = false
			ResetBar()
		end

		-- the bar follows the entries
		local players = U.SortedKeys(round.bets)
		if table.concat(players, ",") ~= table.concat(names, ",") then
			names = players
			Layout(names)
		end
		for i, name in ipairs(names) do
			colors[name] = ns.Wheel.ColorFor(i)
			local seat = seatOf[name]
			if seat then
				seat.mine:SetShown(name == me)
				seat.name:SetText(ColorCode(colors[name]) .. U.Short(name) .. "|r")
				SetSkin(seat, name)
			end
		end
		Animate(round)

		local count = #names
		local entry = round.limit
		local inGame = round.bets[me] ~= nil
		local note, noteColor = round.warning or round.error, round.error and RED or AMBER
		overlay:Hide()
		info:SetWidth(320)

		if round.phase == "SETUP" then
			headline:SetText("CHOOSE THE ENTRY FEE")
			headline:SetTextColor(T.Unpack(C.gold))
			message:SetText("Everyone pays this to drink, and the winner takes it all. It can't change once entries are open. "
				.. (round.practice and "Then open entries for the bots." or "Then open entries for your group."))
			message:SetTextColor(T.Unpack(C.textDim))
			ShowOnly(feeBox, presets[1], presets[2], presets[3], presets[4], openBtn, cancelBtn)
			if not feeBox:HasFocus() then feeBox:SetNumber(round.limit) end

		elseif round.phase == "BETTING" then
			headline:SetText(count .. (count == 1 and " DRINKER" or " DRINKERS") .. "  ·  POT " .. U.Thousands(entry * count) .. "G")
			headline:SetTextColor(T.Unpack(C.gold))
			local full = count >= B.MAX_PLAYERS and not inGame
			local rules = "Each mug adds " .. B.MUG_MIN .. "-" .. B.MUG_MAX .. "%. Stop whenever you like; over "
				.. B.LIMIT .. "% and you're under the table. The drunkest one still standing takes the pot."
			local hint = (isHost and count < 2) and "You can open the taps once at least 2 players are in."
			if full then rules = "The bar is full (" .. B.MAX_PLAYERS .. " players)." end
			message:SetText(note or hint or rules)
			message:SetTextColor(T.Unpack(note and noteColor or C.textDim))
			joinBtn:SetLabel("JOIN  ·  " .. U.Thousands(entry) .. "G")
			joinBtn:SetActive(not full)
			local entryBtn = inGame and leaveBtn or joinBtn
			if isHost then
				ShowOnly(entryBtn, lockBtn, cancelBtn)
				lockBtn:SetActive(count >= 2)
			else
				ShowOnly(entryBtn, info, quitBtn)
				info:SetWidth(240)
				info:SetText("Waiting for " .. U.Short(round.host) .. " to open the taps")
			end

		elseif round.phase == "ROLLING" then
			local left = math.max(0, math.ceil((round.deadline or 0) - GetTime()))
			local drinking = 0
			for _, name in ipairs(names) do
				local s = round.brew and round.brew[name]
				if not (s and B.Done(s)) then drinking = drinking + 1 end
			end
			headline:SetText("DRINK!  ·  " .. left .. "s")
			headline:SetTextColor(T.Unpack(left <= 10 and RED or AMBER))
			local fresh = news and GetTime() - newsAt < 4
			message:SetText(note or (fresh and news) or ("Each mug adds " .. B.MUG_MIN .. "-" .. B.MUG_MAX
				.. "%. Over " .. B.LIMIT .. "% and you're out. " .. drinking .. " still drinking."))
			message:SetTextColor(T.Unpack(note and noteColor or (fresh and C.text) or C.textDim))
			local s = inGame and B.State(round, me)
			if s and not B.Done(s) and left > 0 then
				ShowOnly(drinkBtn, stopBtn, info)
				local pending = B.Pending(s)
				drinkBtn:SetActive(not pending)
				stopBtn:SetActive(not pending)
				info:SetText("You: |cffffd84d" .. s.total .. "%|r  ·  " .. #s.mugs .. (#s.mugs == 1 and " mug" or " mugs"))
			elseif not isHost and GetTime() > (round.deadline or 0) + 20 then
				ShowOnly(info, quitBtn)
				info:SetWidth(240)
				info:SetText("The host hasn't closed the bar")
			else
				ShowOnly(info)
				if s and s.out then
					info:SetText("You're under the table (" .. s.total .. "%)")
				elseif s then
					info:SetText("You stopped at " .. s.total .. "%  ·  " .. drinking .. " still drinking")
				else
					info:SetText(drinking .. " still drinking")
				end
			end

		elseif round.phase == "SPINNING" then
			local res = round.result
			ShowOnly()
			local total = res.sums[res.winner]
			if res.standing then
				headline:SetText(U.Short(res.winner):upper() .. " WINS AT " .. total .. "%!")
			else
				headline:SetText("EVERYONE'S DOWN! " .. U.Short(res.winner):upper() .. " FELL THE LEAST")
			end
			headline:SetTextColor(T.Unpack(C.gold))
			message:SetText(note or ((res.standing and "The drunkest one still standing takes the pot."
				or "Everyone went over " .. B.LIMIT .. "%, so the one who went over the least takes the pot.")
				.. (res.tied and " A tie: the dice of everyone's mugs broke it." or "")))
			message:SetTextColor(T.Unpack(note and noteColor or C.textDim))

		elseif round.phase == "DONE" then
			local res = round.result
			local paying = #res.transfers
			headline:SetText(U.Short(res.winner):upper() .. " WINS " .. U.Thousands(res.gain) .. " GOLD")
			headline:SetTextColor(T.Unpack(C.gold))
			local summary = U.Short(res.winner) .. " gets " .. U.Gold(entry) .. " from each of "
				.. paying .. (paying == 1 and " player." or " players.")
			if inGame and res.winner == me then
				summary = "You won! " .. summary
			elseif inGame then
				summary = "You pay " .. U.Short(res.winner) .. " " .. U.Gold(round.bets[me]) .. ". " .. summary
			end
			if round.practice then summary = summary .. " |cff9d8fbf(practice: no gold moves)|r" end
			message:SetText(note and (note .. "\n" .. summary) or summary)
			message:SetTextColor(T.Unpack(note and noteColor or C.text))

			local rows = {}
			for _, tr in ipairs(res.transfers) do
				rows[#rows + 1] = {
					color = colors[tr.from], left = U.Short(tr.from) .. "  |cff9d8fbf" .. (res.sums[tr.from] or 0) .. "%|r",
					mid = "pays " .. U.Short(tr.to), right = U.Gold(tr.amount),
					mine = tr.from == me or tr.to == me, leftColor = tr.from == me and C.gold or C.text,
				}
			end
			ovList:SetData(rows)
			ovMeta:SetText(U.Short(res.winner) .. " stood at " .. (res.sums[res.winner] or 0) .. "%")
			overlay:SetShown(not showBar)
			replayBtn:SetLabel(showBar and "VIEW PAYMENTS" or "VIEW BAR")

			local canRestart = isHost or round.practice
			ShowOnly(replayBtn, lobbyBtn, canRestart and newBtn or lobbyBtn)
			lobbyBtn:ClearAllPoints()
			if canRestart then
				lobbyBtn:SetPoint("LEFT", newBtn, "RIGHT", 10, 0)
			else
				lobbyBtn:SetPoint("BOTTOMLEFT")
			end

		else -- CANCELLED
			headline:SetText("ROUND CANCELLED")
			headline:SetTextColor(T.Unpack(RED))
			message:SetText(round.error or "Nobody pays.")
			message:SetTextColor(T.Unpack(C.textDim))
			ShowOnly(lobbyBtn)
			lobbyBtn:ClearAllPoints()
			lobbyBtn:SetPoint("BOTTOMLEFT")
		end
	end

	-- the bar moves every frame; the countdown and buttons a few times a second
	local clock = 0
	v:SetScript("OnUpdate", function(self, dt)
		local round = J.round
		if not round or round.game ~= "brewfest" then return end
		Animate(round)
		clock = clock + dt
		if clock >= 0.25 then
			clock = 0
			if round.phase == "ROLLING" then self:Refresh() end
		end
	end)
	v:SetScript("OnShow", function(self) self:Refresh() end)
	-- a model set while hidden may never load: set every model again the next time it is seen
	v:SetScript("OnHide", function()
		for _, seat in ipairs(seats) do
			seat.skin, seat.anim = nil, nil
		end
	end)
	J.OnChange(function()
		if v:IsVisible() then v:Refresh() end
	end)
	return v
end
