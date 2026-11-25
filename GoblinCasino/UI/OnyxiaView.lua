-- Onyxia's Deep Breath screen: Onyxia (3D) on the right, the raid (players' own characters when
-- they can be shown, creatures otherwise) on the left. Red markers flicker over the raid, then a
-- wall of fire sweeps across it: the ones it burns fall, the others flash their cloak. Wave after
-- wave until one is left.
local ADDON, ns = ...
local T, U, J, O, D, W = ns.Theme, ns.Util, ns.Jackpot, ns.Onyxia, ns.Derby, ns.Widgets
local C, hex, Mix = T.C, T.hex, T.Mix

local View = {}
ns.OnyxiaView = View

local STAGE_H = 318
local RAID_X0, RAID_X1 = 20, 470
local CAM = 1.3
local ONY_CAM = 1.0
local RED, ORANGE, DIM = hex("ff6b6b"), hex("ffb347"), hex("9d8fbf")
local WHITE = hex("ffffff")
local FIRE = hex("ff7a1a")
local SHIELD = hex("6fb7ff")
local ANIM = { stand = 0, death = 1, dead = 6 }
-- Onyxia's animations: the first one her model has (roar, battle roar, spell cast, attack)
local ONY_ROAR = { 74, 55, 16 }
local ONY_BREATH = { 51, 52, 55, 74, 16 }

local PHASES = {
	SETUP = { "SETUP", C.gold },
	BETTING = { "BETS OPEN", C.green },
	ROLLING = { "ROLL FOR THE SEED", C.cyan },
	SPINNING = { "DEEP BREATH", FIRE },
	DONE = { "RESULT", C.gold },
	CANCELLED = { "CANCELLED", RED },
}

local function ColorCode(c)
	return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
end

local function Clamp(x, a, b) return math.max(a, math.min(b, x)) end

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
	local title = T.Text(v, T.FONT_DISPLAY, 18, Mix(RED, WHITE, 0.4))
	title:SetPoint("LEFT", back, "RIGHT", 14, 0)
	title:SetText("ONYXIA'S DEEP BREATH")
	local phase = T.Pill(v, "", { 1, 1, 1, 0.08 }, C.green)
	phase:SetPoint("LEFT", title, "RIGHT", 12, 0)
	local practice = T.Pill(v, "PRACTICE · BOTS", { ORANGE[1], ORANGE[2], ORANGE[3], 0.16 }, ORANGE)
	practice:SetPoint("LEFT", phase.label, "RIGHT", 18, 0)
	local hostInfo = T.Text(v, T.FONT_BODY, 11, C.textDim)
	hostInfo:SetJustifyH("RIGHT")
	hostInfo:SetPoint("TOPRIGHT", 0, -8)

	-----------------------------------------------------------------------
	-- stage: the lair
	-----------------------------------------------------------------------
	local stage = CreateFrame("Frame", nil, v)
	stage:SetPoint("TOPLEFT", 0, -40)
	stage:SetSize(width, STAGE_H)
	stage:SetClipsChildren(true)
	T.Gradient(stage, "HORIZONTAL", hex("160b12"), hex("2a0c0a")):SetAllPoints()
	T.Border(stage, Mix(RED, C.bgDeep, 0.5), 1)
	local heat = stage:CreateTexture(nil, "BORDER", nil, 1)
	heat:SetAllPoints()
	heat:SetColorTexture(1, 0.25, 0.05, 1)
	heat:SetBlendMode("ADD")
	heat:SetAlpha(0)

	-- Onyxia
	local onyFrame = CreateFrame("Frame", nil, stage)
	onyFrame:SetSize(width - RAID_X1 + 40, STAGE_H)
	onyFrame:SetPoint("TOPRIGHT", 30, 0)
	onyFrame:SetFrameLevel(stage:GetFrameLevel() + 2)
	local ony = CreateFrame("PlayerModel", nil, onyFrame)
	ony:SetAllPoints()
	local onyState = { index = 0, cache = {} }
	local function OnyTry(index)
		onyState.index, onyState.at, onyState.loaded, onyState.anim = index, GetTime(), false, nil
		onyState.cache = {}
		pcall(ony.SetDisplayInfo, ony, O.DISPLAYS[index])
		pcall(ony.SetFacing, ony, -1.15)
		pcall(ony.SetCamDistanceScale, ony, ONY_CAM)
	end
	ony:SetScript("OnModelLoaded", function(self)
		onyState.loaded = true
		onyState.good = onyState.index
		pcall(self.SetFacing, self, -1.15)
		pcall(self.SetCamDistanceScale, self, ONY_CAM)
		if onyState.anim then pcall(self.SetAnimation, self, onyState.anim) end
	end)
	local function OnyAnim(list)
		local id = 0
		if list then
			local key = table.concat(list, ",")
			if onyState.cache[key] == nil then
				local found
				for _, a in ipairs(list) do
					local ok, has = pcall(ony.HasAnimation, ony, a)
					if ok and has then found = a; break end
				end
				-- before the model has loaded HasAnimation knows nothing: ask again later
				if found or onyState.loaded then onyState.cache[key] = found or false end
				id = found or list[#list]
			else
				id = onyState.cache[key] or list[#list]
			end
		end
		if onyState.anim ~= id then
			onyState.anim = id
			pcall(ony.SetAnimation, ony, id)
		end
	end
	-- glow in her mouth while she breathes
	local MOUTH_X, MOUTH_Y = RAID_X1 + 20, STAGE_H * 0.42
	local mouth = T.Circle(stage, 60, "ARTWORK", 0)
	mouth:SetPoint("CENTER", stage, "TOPLEFT", MOUTH_X, -MOUTH_Y)
	mouth:SetBlendMode("ADD")
	mouth:SetColorTexture(1, 0.55, 0.1, 1)
	mouth:SetAlpha(0)

	-- names, cloaks and DKP float above every model
	local labels = CreateFrame("Frame", nil, stage)
	labels:SetAllPoints()
	labels:SetFrameLevel(stage:GetFrameLevel() + 55)
	local banner = T.Text(labels, T.FONT_DISPLAY, 26, C.gold)
	banner:SetJustifyH("CENTER")
	banner:SetPoint("CENTER", stage, "TOPLEFT", (RAID_X0 + RAID_X1) / 2, -STAGE_H / 2)
	banner:SetShadowColor(0, 0, 0, 1)
	banner:SetShadowOffset(2, -2)
	banner:Hide()
	local emptyText = T.Text(labels, T.FONT_BOLD, 13, C.textDim)
	emptyText:SetJustifyH("CENTER")
	emptyText:SetPoint("CENTER", stage, "TOPLEFT", (RAID_X0 + RAID_X1) / 2, -STAGE_H / 2)
	emptyText:SetText("Nobody on the platform yet. Place a bet!")

	-- the raid
	local seats = {}
	local function Seat(i)
		if seats[i] then return seats[i] end
		local seat = CreateFrame("Frame", nil, stage)
		seat.ring = T.Circle(seat, 40, "BACKGROUND", 3)
		seat.ring:SetAlpha(0.6)
		seat.warn = T.Circle(seat, 40, "BACKGROUND", 4)
		seat.warn:SetBlendMode("ADD")
		seat.warn:SetColorTexture(1, 0.1, 0.05, 0.9)
		seat.warn:SetAlpha(0)
		seat.mine = T.Circle(seat, 40, "BACKGROUND", 2)
		seat.mine:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.35)
		seat.over = CreateFrame("Frame", nil, seat) -- above the model (a seat texture is drawn under it)
		seat.over:SetAllPoints()
		seat.shield = T.Circle(seat.over, 40, "OVERLAY", 0)
		seat.shield:SetBlendMode("ADD")
		seat.shield:SetColorTexture(SHIELD[1], SHIELD[2], SHIELD[3], 0.55)
		seat.shield:SetAlpha(0)
		local model = CreateFrame("PlayerModel", nil, seat)
		model:SetAllPoints()
		model:SetScript("OnModelLoaded", function(self)
			pcall(self.SetFacing, self, 0.9)
			pcall(self.SetCamDistanceScale, self, CAM)
			if seat.anim then pcall(self.SetAnimation, self, seat.anim) end
		end)
		seat.model = model
		seat.name = T.Text(labels, T.FONT_BOLD, 11, C.text)
		seat.name:SetJustifyH("CENTER")
		seat.name:SetPoint("TOP", seat, "BOTTOM", 0, 6)
		seat.cloak = T.Text(labels, T.FONT_BODY, 9, SHIELD)
		seat.cloak:SetJustifyH("CENTER")
		seat.cloak:SetPoint("TOP", seat.name, "BOTTOM", 0, -1)
		seat.dkp = T.Text(labels, T.FONT_DISPLAY, 13, RED)
		seat.dkp:SetJustifyH("CENTER")
		seat.dkp:SetText("-50 DKP")
		seat.dkp:Hide()
		seats[i] = seat
		return seat
	end

	local function SetAnim(seat, id)
		if seat.anim == id then return end
		seat.anim = id
		pcall(seat.model.SetAnimation, seat.model, id)
	end

	local function SetSkin(seat, name, skin)
		local unit = W.UnitFor(name)
		local want = (unit and UnitIsVisible(unit)) and ("unit:" .. name) or ("skin:" .. tostring(skin))
		if seat.skin == want then return end
		seat.anim, seat.celebrate, seat.celebrateTries = nil, nil, nil
		seat.skin = want -- not SetAvatar's key: if SetUnit fails, that one never matches and reloads
		W.SetAvatar(seat.model, name, skin)
		pcall(seat.model.SetFacing, seat.model, 0.9)
		pcall(seat.model.SetCamDistanceScale, seat.model, CAM)
		SetAnim(seat, ANIM.stand)
	end

	local function Celebration(seat)
		if seat.celebrate then return seat.celebrate end
		for _, id in ipairs(D.CELEBRATE) do
			local ok, has = pcall(seat.model.HasAnimation, seat.model, id)
			if ok and has then
				seat.celebrate = id
				return id
			end
		end
		seat.celebrateTries = (seat.celebrateTries or 0) + 1
		if seat.celebrateTries > 40 then seat.celebrate = D.CELEBRATE[1] end
		return D.CELEBRATE[1]
	end

	local seatOf = {}
	local modelSize = 90
	local function Layout(names)
		local n = #names
		local rows = n <= 3 and math.max(n, 1) or (n <= 8 and 3 or (n <= 15 and 4 or 5))
		local cols = math.max(1, math.ceil(n / rows))
		local cellW = (RAID_X1 - RAID_X0) / cols
		local cellH = (STAGE_H - 46 - 24) / rows -- 24: the last row's name and stake below the models
		modelSize = math.floor(math.min(cellH * 1.5, cellW * 1.05, 120))
		wipe(seatOf)
		for _, seat in ipairs(seats) do
			seat:Hide()
			seat.name:Hide()
			seat.cloak:Hide()
			seat.dkp:Hide()
		end
		for i, name in ipairs(names) do
			local col, row = math.floor((i - 1) / rows), (i - 1) % rows
			local x = RAID_X0 + (col + 0.5) * cellW + (row % 2 == 1 and cellW * 0.18 or -cellW * 0.08)
			local y = 18 + (row + 0.5) * cellH
			local seat = Seat(i)
			seat:ClearAllPoints()
			seat:SetSize(modelSize, modelSize)
			seat:SetPoint("CENTER", stage, "TOPLEFT", x, -y)
			seat:SetFrameLevel(stage:GetFrameLevel() + 4 + row * 3)
			seat.model:SetFrameLevel(seat:GetFrameLevel() + 1)
			seat.over:SetFrameLevel(seat:GetFrameLevel() + 2)
			seat.x, seat.y = x, y
			local ringW = modelSize * 0.6
			for _, r in ipairs({ seat.ring, seat.warn, seat.mine }) do
				r:ClearAllPoints()
				r:SetPoint("CENTER", seat, "BOTTOM", 0, modelSize * 0.17)
				r:SetSize(ringW, ringW * 0.34)
			end
			seat.mine:SetSize(ringW + 10, (ringW + 10) * 0.36)
			seat.shield:ClearAllPoints()
			seat.shield:SetPoint("CENTER", seat, "CENTER", 0, -modelSize * 0.05)
			seat.shield:SetSize(modelSize * 0.62, modelSize * 0.82)
			seat.dkp:ClearAllPoints()
			seat.dkp:SetPoint("BOTTOM", seat, "TOP", 0, -modelSize * 0.15)
			seat.name:SetFont(T.FONT_BOLD, n > 12 and 9 or (n > 6 and 10 or 11), "")
			seat:Show()
			seat.name:Show()
			seat.cloak:Show()
			seatOf[name] = seat
		end
		emptyText:SetShown(n == 0)
	end

	-- the wall of fire
	local fire = CreateFrame("Frame", nil, stage)
	fire:SetSize(220, STAGE_H)
	fire:SetFrameLevel(stage:GetFrameLevel() + 40)
	local f1 = T.Gradient(fire, "HORIZONTAL", { 1, 0.3, 0.05, 0 }, { 1, 0.45, 0.08, 0.85 }, "ARTWORK", 1)
	f1:SetPoint("TOPLEFT")
	f1:SetPoint("BOTTOMRIGHT", fire, "BOTTOM", 0, 0)
	f1:SetBlendMode("ADD")
	local f2 = T.Gradient(fire, "HORIZONTAL", { 1, 0.75, 0.3, 0.95 }, { 1, 0.35, 0.05, 0.25 }, "ARTWORK", 2)
	f2:SetPoint("TOPLEFT", fire, "TOP", 0, 0)
	f2:SetPoint("BOTTOMRIGHT")
	f2:SetBlendMode("ADD")
	fire:Hide()

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
	ovTitle:SetText("SETTLEMENT  ·  EVERYONE PAYS THE SURVIVOR THEIR STAKE")
	local ovMeta = T.Text(overlay, T.FONT_BODY, 10, DIM)
	ovMeta:SetJustifyH("RIGHT")
	ovMeta:SetPoint("TOPRIGHT", -14, -10)
	local ovList = W.List(overlay, width - 28, 10, 26)
	ovList:SetPoint("TOPLEFT", 14, -28)
	overlay:Hide()
	local showGame = false

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
	local function SetHeadline(text)
		if headline.text == text then return end
		headline.text = text
		headline:SetFont(T.FONT_DISPLAY, 18, "")
		headline:SetWordWrap(false)
		headline:SetText(text)
		local w = headline.GetUnboundedStringWidth and headline:GetUnboundedStringWidth() or headline:GetStringWidth()
		if w > headline:GetWidth() then
			headline:SetFont(T.FONT_DISPLAY, 14, "")
			headline:SetWordWrap(true)
			pcall(headline.SetMaxLines, headline, 2)
		end
	end
	local message = T.Text(bottom, T.FONT_BODY, 11, C.textDim)
	message:SetPoint("TOPLEFT", headline, "BOTTOMLEFT", 0, -8)
	message:SetWidth(width - 340)
	message:SetSpacing(2)

	local actions = CreateFrame("Frame", nil, bottom)
	actions:SetPoint("BOTTOMRIGHT")
	actions:SetSize(320, 74)

	-- players: any stake up to the limit
	local stake = W.AmountBox(actions, 80, 34, 15)
	stake:SetPoint("TOPLEFT")
	local quick = {}
	for i, q in ipairs({ { "+10", 10 }, { "+50", 50 }, { "MAX" } }) do
		local b = T.DarkButton(actions, q[1], 44, 34)
		b:SetPoint("LEFT", stake, "RIGHT", 6 + (i - 1) * 48, 0)
		b:SetScript("OnClick", function()
			local round = J.round
			if not round then return end
			local cap = round.practice and round.limit or math.min(round.limit, U.PlayerGold())
			local value = q[2] and (stake:GetNumber() + q[2]) or cap
			stake:SetNumber(math.max(0, math.min(value, cap)))
		end)
		quick[i] = b
	end
	local betBtn = T.GoldButton(actions, "BET", 84, 34)
	betBtn:SetPoint("TOPRIGHT")
	local function PlaceBet()
		stake:ClearFocus()
		local ok, err = J.Bet(stake:GetNumber())
		if not ok and err then ns.Print(err) end
	end
	betBtn:SetScript("OnClick", PlaceBet)
	stake:SetScript("OnEnterPressed", PlaceBet)

	local lockBtn = T.GoldButton(actions, "SUMMON HER", 140, 34)
	lockBtn:SetPoint("BOTTOMLEFT")
	lockBtn:SetScript("OnClick", function()
		local ok, err = J.Lock()
		if not ok and err then ns.Print(err) end
	end)
	local cancelBtn = T.DarkButton(actions, "CANCEL", 64, 34)
	cancelBtn:SetPoint("LEFT", lockBtn, "RIGHT", 6, 0)
	cancelBtn:SetScript("OnClick", function() J.Cancel() end)

	-- host setup: the stake limit
	local limitBox = W.AmountBox(actions, 80, 34, 15)
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
		local b = T.DarkButton(actions, amount .. "g", 50, 34)
		b:SetPoint("LEFT", limitBox, "RIGHT", 6 + (i - 1) * 56, 0)
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
	rollBtn:SetPoint("TOPRIGHT")
	rollBtn.label:SetFont(T.FONT_DISPLAY, 18, "")
	rollBtn:SetScript("OnClick", function() J.RollNow() end)

	local newBtn = T.GoldButton(actions, "NEW ROUND", 130, 34)
	newBtn:SetPoint("BOTTOMLEFT")
	newBtn:SetScript("OnClick", function()
		J.Dismiss()
		ns.Main:StartGame("onyxia")
	end)
	local lobbyBtn = T.DarkButton(actions, "BACK TO LOBBY", 130, 34)
	lobbyBtn:SetScript("OnClick", function()
		J.Dismiss()
		ns.Main:ShowView("lobby")
	end)
	local replayBtn = T.DarkButton(actions, "VIEW LAIR", 130, 30)
	replayBtn:SetPoint("TOPRIGHT")
	replayBtn:SetScript("OnClick", function()
		showGame = not showGame
		v:Refresh()
	end)

	local info = T.Text(actions, T.FONT_BODY, 11, C.textDim)
	info:SetJustifyH("RIGHT")
	info:SetPoint("BOTTOMRIGHT", 0, 10)
	info:SetWidth(320)

	local function Quit()
		local round = J.round
		local wasRolling = round and round.phase == "ROLLING" and round.bets[U.Me()]
		J.Abandon()
		ns.Print(wasRolling and "You left the round. If the host still finishes it, you may owe gold: check with them."
			or "You left the round.")
		ns.Main:ShowView("lobby")
	end
	local quitBtn = T.DarkButton(actions, "QUIT", 64, 30)
	quitBtn:SetPoint("BOTTOMLEFT")
	quitBtn:SetScript("OnClick", Quit)

	local allActions = { stake, betBtn, lockBtn, cancelBtn, limitBox, openBtn, rollBtn,
		newBtn, lobbyBtn, replayBtn, info, quitBtn }
	for _, q in ipairs(quick) do allActions[#allActions + 1] = q end
	for _, p in ipairs(presets) do allActions[#allActions + 1] = p end
	local function ShowOnly(...)
		for _, w in ipairs(allActions) do w:Hide() end
		for i = 1, select("#", ...) do select(i, ...):Show() end
	end

	-----------------------------------------------------------------------
	-- the show
	-----------------------------------------------------------------------
	local names, colors = {}, {}
	local script, scriptRound
	local soundWave, winSound

	local function ShowTime(round)
		return GetTime() - (round.spinStart or 0) - O.START_DELAY
	end

	-- when the fire reaches a raider in a wave
	local function PassAt(wave, seat)
		return wave.breathAt + Clamp((MOUTH_X - seat.x) / (MOUTH_X + 200), 0, 1) * O.SWEEP
	end

	local function CurrentWave(t)
		local cur
		for _, w in ipairs(script.waves) do
			if t >= w.start then cur = w end
		end
		return cur
	end

	local function ResetShow()
		fire:Hide()
		heat:SetAlpha(0)
		mouth:SetAlpha(0)
		banner:Hide()
		for _, seat in pairs(seatOf) do
			SetAnim(seat, ANIM.stand)
			seat.warn:SetAlpha(0)
			seat.shield:SetAlpha(0)
			seat.dkp:Hide()
			seat.model:SetAlpha(1)
			seat.name:SetAlpha(1)
			seat.cloak:SetAlpha(1)
		end
		if onyState.loaded then OnyAnim(nil) end
	end

	local function Animate(round)
		if not script then return end
		local t = ShowTime(round)
		local now = GetTime()
		local wave = t >= 0 and CurrentWave(t) or nil
		local won = t >= script.winAt

		-- Onyxia
		if t < 0 then
			OnyAnim(nil)
		elseif t < 2.2 then
			OnyAnim(ONY_ROAR)
		elseif wave and t >= wave.breathAt - 1.2 and t < wave.breathAt + O.SWEEP then
			OnyAnim(ONY_BREATH)
		elseif won and t < script.winAt + 2 then
			OnyAnim(ONY_ROAR)
		else
			OnyAnim(nil)
		end

		-- fire, heat and the glow in her mouth
		local sweep = wave and (t - wave.breathAt) / O.SWEEP
		if sweep and sweep >= 0 and sweep <= 1.25 then
			local x = MOUTH_X - sweep * (MOUTH_X + 200)
			fire:ClearAllPoints()
			fire:SetPoint("CENTER", stage, "TOPLEFT", x, -STAGE_H / 2)
			fire:SetAlpha(Clamp(1.25 - sweep, 0, 1) + 0.1 * math.sin(now * 40))
			fire:Show()
			heat:SetAlpha(0.18 * Clamp(1.25 - sweep, 0, 1))
		else
			fire:Hide()
			heat:SetAlpha(0)
		end
		local inhale = wave and Clamp((t - (wave.breathAt - 1.4)) / 1.4, 0, 1) or 0
		if wave and t > wave.breathAt + 0.4 then inhale = 0 end
		mouth:SetAlpha(inhale * (0.6 + 0.4 * math.abs(math.sin(now * 18))))
		mouth:SetSize(40 + inhale * 60, 40 + inhale * 60)

		-- the raid
		for name, seat in pairs(seatOf) do
			local dies = script.diesAt[name]
			local deadAt = dies and PassAt(dies, seat)
			if deadAt and t >= deadAt then
				SetAnim(seat, (t - deadAt) < 1.3 and ANIM.death or ANIM.dead)
				seat.model:SetAlpha(Clamp(1 - (t - deadAt) / 2, 0.45, 1))
				seat.name:SetAlpha(0.45)
				seat.cloak:SetAlpha(0.45)
				local since = t - deadAt
				if since < 1.8 then
					seat.dkp:Show()
					seat.dkp:SetAlpha(1 - since / 1.8)
					seat.dkp:ClearAllPoints()
					seat.dkp:SetPoint("BOTTOM", seat, "TOP", 0, -modelSize * 0.15 + since * 22)
				else
					seat.dkp:Hide()
				end
				seat.shield:SetAlpha(0)
				seat.warn:SetAlpha(0)
			else
				seat.dkp:Hide()
				seat.model:SetAlpha(1)
				seat.name:SetAlpha(1)
				seat.cloak:SetAlpha(1)
				if won and name == script.winner then
					SetAnim(seat, Celebration(seat))
				else
					SetAnim(seat, ANIM.stand)
				end
				-- the cloak flashes when the fire passes and spares them
				local shield = 0
				if wave and t >= 0 then
					local pass = PassAt(wave, seat)
					if t >= pass then shield = Clamp(1 - (t - pass) / 0.7, 0, 1) end
				end
				seat.shield:SetAlpha(shield)
				-- red marker: false alarms jump over the raid before the breath
				local warn = 0
				if wave and t < wave.breathAt then
					for _, w in ipairs(wave.warnings) do
						if w.name == name and t >= w.t and t < w.t + 0.3 then warn = 1 end
					end
				end
				seat.warn:SetAlpha(warn)
			end
		end

		-- banner: "MANY WHELPS! HANDLE IT!" and the winner
		local current, whelps
		for _, ev in ipairs(script.events) do
			if ev.t <= t then current = ev end
			if ev.kind == "whelps" then whelps = ev end
		end
		if whelps and t >= whelps.t and t - whelps.t < 2.2 then
			banner:SetText("MANY WHELPS!\nHANDLE IT!")
			banner:SetTextColor(T.Unpack(C.gold))
			banner:Show()
		elseif won and t - script.winAt < 3 then
			banner:SetText("[Onyxia Hide Backpack]\nlooted!")
			banner:SetTextColor(T.Unpack(hex("a335ee")))
			banner:Show()
		else
			banner:Hide()
		end

		-- sounds, live only
		if round.phase == "SPINNING" and wave and t >= wave.breathAt and t < wave.breathAt + 0.5 and soundWave ~= wave then
			soundWave = wave
			ns.Sound.Play("breath")
		end
		if round.phase == "SPINNING" and won and winSound ~= round.id and t - script.winAt < 1 then
			winSound = round.id
			ns.Sound.Play("survive")
		end

		-- commentary
		if round.phase == "SPINNING" then
			if t < 0 then
				SetHeadline(tostring(math.ceil(-t)))
				headline:SetTextColor(T.Unpack(C.gold))
			elseif current then
				SetHeadline(current.text)
				headline:SetTextColor(T.Unpack((current.kind == "breath" or current.kind == "roasted") and FIRE
					or current.kind == "win" and C.gold or C.text))
			end
		end
	end

	function v:Refresh()
		local round = J.round
		if not round or round.game ~= "onyxia" then
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

		-- Onyxia's model (the next candidate if one doesn't load)
		if onyState.index == 0 then OnyTry(onyState.good or 1) end

		-- the raid follows the bets
		local players = U.SortedKeys(round.bets)
		if table.concat(players, ",") ~= table.concat(names, ",") then
			names = players
			Layout(names)
		end
		local total = 0
		for _, name in ipairs(names) do total = total + round.bets[name] end
		for i, name in ipairs(names) do
			colors[name] = ns.Wheel.ColorFor(i)
			local seat = seatOf[name]
			if seat then
				seat.ring:SetColorTexture(T.Unpack(colors[name]))
				seat.mine:SetShown(name == me)
				seat.name:SetText(ColorCode(colors[name]) .. U.Short(name) .. "|r")
				local share = total > 0 and round.bets[name] / total * 100 or 0
				seat.cloak:SetText(string.format("%s  ·  cloak %d%%", U.Gold(round.bets[name]), math.floor(share + 0.5)))
				local skin = D.SKINS[U.FNV1a(name .. ":" .. round.id .. ":onyxia") % #D.SKINS + 1]
				SetSkin(seat, name, skin)
			end
		end

		if round.result and scriptRound ~= round.id then
			scriptRound = round.id
			script = O.Script(round)
			showGame = false
		elseif not round.result then
			script = nil
			ResetShow()
		end
		Animate(round)

		local count = #names
		local myBet = round.bets[me]
		local note, noteColor = round.warning or round.error, round.error and RED or ORANGE
		overlay:Hide()
		info:SetWidth(320)

		if round.phase == "SETUP" then
			SetHeadline("CHOOSE THE STAKE LIMIT")
			headline:SetTextColor(T.Unpack(C.gold))
			message:SetText("Everyone bets from 1g up to this. A bigger stake is a thicker cloak: your chance to survive "
				.. "is your share of the pot. It can't change once bets are open. "
				.. (round.practice and "Then open bets for the bots." or "Then open bets for your group."))
			message:SetTextColor(T.Unpack(C.textDim))
			ShowOnly(limitBox, presets[1], presets[2], presets[3], presets[4], openBtn, cancelBtn)
			if not limitBox:HasFocus() then limitBox:SetNumber(round.limit) end

		elseif round.phase == "BETTING" then
			SetHeadline(count .. (count == 1 and " RAIDER" or " RAIDERS") .. "  ·  POT " .. U.Thousands(total) .. "G")
			headline:SetTextColor(T.Unpack(C.gold))
			local hint = (isHost and count < 2) and "You can summon her once at least 2 raiders are in."
			local mine = myBet and string.format("Your stake: %s, a %d%% chance to be the last one standing. Enter 0 to withdraw.",
				U.Gold(myBet), math.floor(myBet / math.max(1, total) * 100 + 0.5))
			message:SetText(note or hint or mine or "Bigger stake, thicker cloak. The last raider alive takes the whole pot.")
			message:SetTextColor(T.Unpack(note and noteColor or C.textDim))
			betBtn:SetLabel(myBet and "CHANGE" or "BET")
			if not stake:HasFocus() and stake:GetNumber() == 0 then stake:SetNumber(math.min(round.limit, 10)) end
			if isHost then
				ShowOnly(stake, quick[1], quick[2], quick[3], betBtn, lockBtn, cancelBtn)
				lockBtn:SetActive(count >= 2)
			else
				ShowOnly(stake, quick[1], quick[2], quick[3], betBtn, info, quitBtn)
				info:SetWidth(240)
				info:SetText("Waiting for " .. U.Short(round.host) .. " to summon Onyxia")
			end

		elseif round.phase == "ROLLING" then
			local rolled = 0
			for _, name in ipairs(names) do
				if round.seen and round.seen[name] then rolled = rolled + 1 end
			end
			SetHeadline("SHE STIRS...  ·  " .. rolled .. "/" .. count .. " ROLLED")
			headline:SetTextColor(T.Unpack(C.cyan))
			message:SetText(note or "Everyone's /roll makes the seed. Only the seed (and your stake) decides who survives.")
			message:SetTextColor(T.Unpack(note and noteColor or C.textDim))
			local left = math.max(0, math.ceil((round.deadline or 0) - GetTime()))
			if myBet and not J.HasRolled() then
				ShowOnly(rollBtn, info)
				rollBtn:SetActive(left > 0)
				info:SetText(left > 0 and ("Roll within |cffffd84d" .. left .. "s|r") or "Too late, the host rolls for you")
			elseif not isHost and GetTime() > (round.deadline or 0) + 20 then
				ShowOnly(info, quitBtn)
				info:SetWidth(240)
				info:SetText("The host hasn't finished the round")
			else
				ShowOnly(info)
				info:SetText(left > 0 and ("Waiting for rolls  ·  " .. left .. "s") or "The host rolls for missing players...")
			end

		elseif round.phase == "SPINNING" then
			ShowOnly()
			message:SetText(note or ("Pot " .. U.Gold(total) .. ". The last raider standing takes it."))
			message:SetTextColor(T.Unpack(note and noteColor or C.textDim))

		elseif round.phase == "DONE" then
			local res = round.result
			SetHeadline(U.Short(res.winner):upper() .. " SURVIVES!")
			headline:SetTextColor(T.Unpack(C.gold))
			local paying = #res.transfers
			local summary = U.Short(res.winner) .. " receives " .. U.Gold(res.gain) .. " from "
				.. paying .. (paying == 1 and " player." or " players.")
			if myBet and res.winner ~= me then
				summary = "You pay " .. U.Short(res.winner) .. " " .. U.Gold(myBet) .. ". " .. summary
			elseif res.winner == me then
				summary = "You survived! " .. summary
			end
			if round.practice then summary = summary .. " |cff9d8fbf(practice: no gold moves)|r" end
			message:SetText(note and (note .. "\n" .. summary) or summary)
			message:SetTextColor(T.Unpack(note and noteColor or C.text))

			local rows = {}
			for _, tr in ipairs(res.transfers) do
				rows[#rows + 1] = {
					color = colors[tr.from], left = U.Short(tr.from), mid = "pays " .. U.Short(tr.to),
					right = U.Gold(tr.amount), mine = tr.from == me or tr.to == me,
					leftColor = tr.from == me and C.gold or C.text,
				}
			end
			ovList:SetData(rows)
			ovMeta:SetText(U.Short(res.winner) .. " takes " .. U.Gold(res.total))
			overlay:SetShown(not showGame)
			replayBtn:SetLabel(showGame and "VIEW PAYMENTS" or "VIEW LAIR")

			local canRestart = isHost or round.practice
			ShowOnly(replayBtn, lobbyBtn, canRestart and newBtn or lobbyBtn)
			lobbyBtn:ClearAllPoints()
			if canRestart then
				lobbyBtn:SetPoint("LEFT", newBtn, "RIGHT", 10, 0)
			else
				lobbyBtn:SetPoint("BOTTOMLEFT")
			end

		else -- CANCELLED
			SetHeadline("ROUND CANCELLED")
			headline:SetTextColor(T.Unpack(RED))
			message:SetText(round.error or "Nobody pays.")
			message:SetTextColor(T.Unpack(C.textDim))
			ShowOnly(lobbyBtn)
			lobbyBtn:ClearAllPoints()
			lobbyBtn:SetPoint("BOTTOMLEFT")
			ResetShow()
		end
	end

	-- the show runs every frame; countdowns tick a few times a second
	local clock = 0
	v:SetScript("OnUpdate", function(self, dt)
		-- Onyxia's model didn't load: try the next one
		if onyState.index > 0 and not onyState.loaded and not onyState.good and GetTime() - onyState.at > 5
			and onyState.index < #O.DISPLAYS then
			OnyTry(onyState.index + 1)
		end
		local round = J.round
		if not round or round.game ~= "onyxia" then return end
		if round.phase == "SPINNING" then
			Animate(round)
		end
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
		onyState.index = 0
	end)
	J.OnChange(function()
		if v:IsVisible() then v:Refresh() end
	end)
	return v
end
