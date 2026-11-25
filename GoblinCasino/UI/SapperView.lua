-- Hot Sapper screen: the players stand in a circle (3D models), a lit sapper charge flies from one
-- to the next faster and faster, fizzles once or twice, and blows up in the loser's hands.
local ADDON, ns = ...
local T, U, J, S, D, W = ns.Theme, ns.Util, ns.Jackpot, ns.Sapper, ns.Derby, ns.Widgets
local C, hex, Mix = T.C, T.hex, T.Mix

local View = {}
ns.SapperView = View

local STAGE_H = 318
local CAM = 1.35
local RED, ORANGE, DIM = hex("ff6b6b"), hex("ffb347"), hex("9d8fbf")
local WHITE = hex("ffffff")
local FIRE = hex("ff7a1a")
local ANIM = { stand = 0, run = 5, death = 1, dead = 6 }

local PHASES = {
	SETUP = { "SETUP", C.gold },
	BETTING = { "ENTRIES OPEN", C.green },
	ROLLING = { "ROLL FOR THE SEED", C.cyan },
	SPINNING = { "FUSE LIT", FIRE },
	DONE = { "RESULT", C.gold },
	CANCELLED = { "CANCELLED", RED },
}

-- the charge: the first icon this client has
local CHARGE_ICONS = {
	"Interface\\Icons\\INV_Gizmo_SuperSapperCharge",
	"Interface\\Icons\\INV_Misc_Bomb_08",
	"Interface\\Icons\\INV_Misc_Bomb_05",
	"Interface\\Icons\\INV_Misc_Bomb_02",
	"Interface\\Icons\\INV_Misc_Bomb_01",
	"Interface\\Icons\\Spell_Fire_SelfDestruct",
}
local function ChargeIcon()
	if not GetFileIDFromPath then return CHARGE_ICONS[2] end
	for _, path in ipairs(CHARGE_ICONS) do
		if GetFileIDFromPath(path) then return path end
	end
	return CHARGE_ICONS[#CHARGE_ICONS]
end

local function PlaySoundSafe(...)
	if not SOUNDKIT then return end
	for i = 1, select("#", ...) do
		local id = SOUNDKIT[select(i, ...)]
		if id then
			pcall(PlaySound, id)
			return
		end
	end
end

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
	local title = T.Text(v, T.FONT_DISPLAY, 18, Mix(FIRE, WHITE, 0.45))
	title:SetPoint("LEFT", back, "RIGHT", 14, 0)
	title:SetText("HOT SAPPER")
	local phase = T.Pill(v, "", { 1, 1, 1, 0.08 }, C.green)
	phase:SetPoint("LEFT", title, "RIGHT", 12, 0)
	local practice = T.Pill(v, "PRACTICE · BOTS", { ORANGE[1], ORANGE[2], ORANGE[3], 0.16 }, ORANGE)
	practice:SetPoint("LEFT", phase.label, "RIGHT", 18, 0)
	local hostInfo = T.Text(v, T.FONT_BODY, 11, C.textDim)
	hostInfo:SetJustifyH("RIGHT")
	hostInfo:SetPoint("TOPRIGHT", 0, -8)

	-----------------------------------------------------------------------
	-- stage
	-----------------------------------------------------------------------
	local stage = CreateFrame("Frame", nil, v)
	stage:SetPoint("TOPLEFT", 0, -40)
	stage:SetSize(width, STAGE_H)
	stage:SetClipsChildren(true)
	T.Gradient(stage, "VERTICAL", hex("1a0a08"), hex("2e1208")):SetAllPoints()
	T.Border(stage, Mix(FIRE, C.bgDeep, 0.5), 1)
	local cx, cy = width / 2, STAGE_H / 2 + 4

	-- the circle on the floor
	local floor = T.Circle(stage, 200, "BACKGROUND", 2)
	floor:SetPoint("CENTER", stage, "TOPLEFT", cx, -cy - 30)
	floor:SetColorTexture(FIRE[1], FIRE[2], FIRE[3], 0.06)
	floor:SetSize(width - 120, STAGE_H - 70)

	local emptyText = T.Text(stage, T.FONT_BOLD, 13, C.textDim)
	emptyText:SetJustifyH("CENTER")
	emptyText:SetPoint("CENTER", stage, "TOPLEFT", cx, -cy)
	emptyText:SetText("Nobody in the circle yet. Join in!")

	-- names and +/- gold float above every model
	local labels = CreateFrame("Frame", nil, stage)
	labels:SetAllPoints()
	labels:SetFrameLevel(stage:GetFrameLevel() + 55)

	-- seats: one per player, around an ellipse
	local seats = {}
	local modelW, modelH = 96, 96
	local function Seat(i)
		if seats[i] then return seats[i] end
		local seat = CreateFrame("Frame", nil, stage)
		seat.ring = T.Circle(seat, 40, "BACKGROUND", 3)
		seat.ring:SetAlpha(0.6)
		seat.hot = T.Circle(seat, 40, "BACKGROUND", 4)
		seat.hot:SetBlendMode("ADD")
		seat.hot:SetColorTexture(FIRE[1], FIRE[2], FIRE[3], 0.5)
		seat.hot:Hide()
		seat.mine = T.Circle(seat, 40, "BACKGROUND", 2)
		seat.mine:SetColorTexture(C.gold[1], C.gold[2], C.gold[3], 0.35)
		local model = CreateFrame("PlayerModel", nil, seat)
		model:SetAllPoints()
		model:SetScript("OnModelLoaded", function(self)
			pcall(self.SetFacing, self, seat.facing or 0)
			pcall(self.SetCamDistanceScale, self, CAM)
			if seat.anim then pcall(self.SetAnimation, self, seat.anim) end
		end)
		seat.model = model
		seat.name = T.Text(labels, T.FONT_BOLD, 11, C.text)
		seat.name:SetJustifyH("CENTER")
		seat.name:SetPoint("TOP", seat, "BOTTOM", 0, 4)
		seat.money = T.Text(labels, T.FONT_DISPLAY, 14, C.green)
		seat.money:SetJustifyH("CENTER")
		seat.money:SetPoint("BOTTOM", seat, "TOP", 0, -6)
		seats[i] = seat
		return seat
	end

	local function SetAnim(seat, id)
		if seat.anim == id then return end
		seat.anim = id
		pcall(seat.model.SetAnimation, seat.model, id)
	end

	-- the player's own character when it can be shown, else a creature (bots, players far away)
	local function SetSkin(seat, name, skin, facing)
		local unit = W.UnitFor(name)
		local want = (unit and UnitIsVisible(unit)) and ("unit:" .. name) or ("skin:" .. tostring(skin))
		if seat.skin == want and seat.facing == facing then return end
		seat.facing = facing
		seat.anim, seat.celebrate, seat.celebrateTries = nil, nil, nil
		seat.skin = W.SetAvatar(seat.model, name, skin)
		pcall(seat.model.SetFacing, seat.model, facing)
		pcall(seat.model.SetCamDistanceScale, seat.model, CAM)
		SetAnim(seat, ANIM.stand)
	end

	-- the cheer this seat's creature can actually play (as in the derby)
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

	local order = {}     -- names in seat order
	local seatOf = {}    -- name -> seat
	local function Layout(names)
		local n = #names
		local size = n <= 4 and 104 or (n <= 6 and 92 or (n <= 9 and 78 or 66))
		modelW, modelH = size, size
		local rx = width / 2 - size / 2 - 40
		local ry = STAGE_H / 2 - size / 2 - 22
		-- the local player sits at the bottom, the others clockwise from there
		local me = U.Me()
		local start = 1
		for i, name in ipairs(names) do
			if name == me then start = i end
		end
		wipe(order)
		wipe(seatOf)
		for _, seat in ipairs(seats) do
			seat:Hide()
			seat.name:Hide()
			seat.money:Hide()
		end
		for k = 1, n do
			local name = names[(start + k - 2) % n + 1]
			local a = math.pi + (k - 1) * 2 * math.pi / n -- from the bottom, clockwise
			local x = cx + rx * math.sin(a)
			local y = cy - ry * math.cos(a)
			local seat = Seat(k)
			seat:ClearAllPoints()
			seat:SetSize(size, size)
			seat:SetPoint("CENTER", stage, "TOPLEFT", x, -y)
			seat:SetFrameLevel(stage:GetFrameLevel() + 2 + math.floor(y / 10)) -- nearer ones in front
			seat.x, seat.y, seat.facing0 = x, y, -math.sin(a) * 1.1
			local ringW = size * 0.62
			for _, r in ipairs({ seat.ring, seat.hot, seat.mine }) do
				r:ClearAllPoints()
				r:SetPoint("CENTER", seat, "BOTTOM", 0, size * 0.16)
				r:SetSize(ringW, ringW * 0.34)
			end
			seat.mine:SetSize(ringW + 10, (ringW + 10) * 0.36)
			seat.name:SetFont(T.FONT_BOLD, n > 9 and 10 or 11, "")
			seat:Show()
			seat.name:Show()
			order[k] = name
			seatOf[name] = seat
		end
		emptyText:SetShown(n == 0)
	end

	-- the charge
	local charge = CreateFrame("Frame", nil, stage)
	charge:SetSize(30, 30)
	charge:SetFrameLevel(stage:GetFrameLevel() + 60)
	local chargeGlow = T.Circle(charge, 54, "BACKGROUND", 0)
	chargeGlow:SetPoint("CENTER")
	chargeGlow:SetBlendMode("ADD")
	chargeGlow:SetColorTexture(FIRE[1], FIRE[2], FIRE[3], 0.35)
	local chargeIcon = charge:CreateTexture(nil, "ARTWORK")
	chargeIcon:SetAllPoints()
	chargeIcon:SetTexture(ChargeIcon())
	chargeIcon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	local spark = T.Circle(charge, 12, "OVERLAY", 1)
	spark:SetPoint("CENTER", charge, "TOPRIGHT", -2, -2)
	spark:SetBlendMode("ADD")
	spark:SetColorTexture(1, 0.9, 0.4, 1)
	local sparkHalo = T.Circle(charge, 24, "OVERLAY", 0)
	sparkHalo:SetPoint("CENTER", spark, "CENTER")
	sparkHalo:SetBlendMode("ADD")
	sparkHalo:SetColorTexture(1, 0.6, 0.15, 0.6)
	charge:Hide()

	-- the explosion: flash over the stage, blast rings and smoke at the loser
	local flash = stage:CreateTexture(nil, "OVERLAY", nil, 7)
	flash:SetAllPoints()
	flash:SetColorTexture(1, 0.85, 0.6, 1)
	flash:SetBlendMode("ADD")
	flash:SetAlpha(0)
	local fx = CreateFrame("Frame", nil, stage)
	fx:SetAllPoints()
	fx:SetFrameLevel(stage:GetFrameLevel() + 70)
	local blasts = {}
	for i, c in ipairs({ { 1, 0.95, 0.6 }, { 1, 0.55, 0.12 }, { 0.9, 0.2, 0.05 } }) do
		local b = T.Circle(fx, 10, "ARTWORK", i)
		b:SetBlendMode("ADD")
		b:SetColorTexture(c[1], c[2], c[3], 1)
		b:SetAlpha(0)
		blasts[i] = b
	end
	local smoke = T.Circle(fx, 10, "BORDER", 0)
	smoke:SetColorTexture(0.08, 0.06, 0.06, 1)
	smoke:SetAlpha(0)
	local debris = {}
	for i = 1, 12 do
		local d = fx:CreateTexture(nil, "ARTWORK", nil, 5)
		d:SetSize(5, 5)
		d:SetColorTexture(1, 0.6 + (i % 3) * 0.12, 0.2, 1)
		d:SetBlendMode("ADD")
		d:SetAlpha(0)
		debris[i] = d
	end

	local function HideFx()
		flash:SetAlpha(0)
		smoke:SetAlpha(0)
		for _, b in ipairs(blasts) do b:SetAlpha(0) end
		for _, d in ipairs(debris) do d:SetAlpha(0) end
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
	ovTitle:SetText("SETTLEMENT  ·  THE ONE WHO BLEW UP PAYS EVERYONE")
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
	local leaveBtn = T.DarkButton(actions, "LEAVE THE CIRCLE", 200, 34)
	leaveBtn:SetPoint("TOPRIGHT")
	leaveBtn:SetScript("OnClick", function() J.Bet(0) end)

	local lockBtn = T.GoldButton(actions, "LIGHT IT", 140, 34)
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

	local rollBtn = T.GoldButton(actions, "ROLL!", 170, 44)
	rollBtn:SetPoint("TOPRIGHT")
	rollBtn.label:SetFont(T.FONT_DISPLAY, 18, "")
	rollBtn:SetScript("OnClick", function() J.RollNow() end)

	local newBtn = T.GoldButton(actions, "NEW ROUND", 130, 34)
	newBtn:SetPoint("BOTTOMLEFT")
	newBtn:SetScript("OnClick", function()
		J.Dismiss()
		ns.Main:StartGame("sapper")
	end)
	local lobbyBtn = T.DarkButton(actions, "BACK TO LOBBY", 130, 34)
	lobbyBtn:SetScript("OnClick", function()
		J.Dismiss()
		ns.Main:ShowView("lobby")
	end)
	local replayBtn = T.DarkButton(actions, "VIEW CIRCLE", 130, 30)
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

	local allActions = { joinBtn, leaveBtn, lockBtn, cancelBtn, feeBox, openBtn, rollBtn,
		newBtn, lobbyBtn, replayBtn, info, quitBtn }
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
	local lastStep, lastTick, boomSeen = nil, 0, nil

	local function ShowTime(round)
		return GetTime() - (round.spinStart or 0) - S.START_DELAY
	end

	-- where the charge sits on a seat (over the head)
	local function ChargePoint(seat)
		return seat.x, seat.y - modelH * 0.42
	end

	local function Animate(round)
		if not script then return end
		local t = ShowTime(round)
		local now = GetTime()
		local boom = script.boom
		local exploded = t >= boom
		local holder, from, to, frac, step, out = S.At(script, t)

		-- players
		for name, seat in pairs(seatOf) do
			local isLoser = name == script.loser
			if exploded then
				if isLoser then
					SetAnim(seat, (t - boom) < 1.3 and ANIM.death or ANIM.dead)
				else
					SetAnim(seat, Celebration(seat))
				end
				seat.hot:SetShown(isLoser and (t - boom) < 2)
			elseif name == holder and t >= 0 and not out then
				SetAnim(seat, ANIM.run) -- panicking with the charge
				seat.hot:Show()
				seat.hot:SetAlpha(0.5 + 0.5 * math.abs(math.sin(now * (6 + 10 * Clamp(t / boom, 0, 1)))))
			else
				SetAnim(seat, ANIM.stand)
				seat.hot:Hide()
			end
			if exploded and (t - boom) > 0.8 then
				seat.money:Show()
				if isLoser then
					seat.money:SetText("-" .. U.Thousands(round.result.gain * #round.result.transfers) .. "g")
					seat.money:SetTextColor(T.Unpack(RED))
				else
					seat.money:SetText("+" .. U.Thousands(round.result.gain) .. "g")
					seat.money:SetTextColor(T.Unpack(C.green))
				end
			else
				seat.money:Hide()
			end
		end

		-- the charge
		if exploded then
			charge:Hide()
		else
			local x, y, rot = 0, 0, 0
			if holder then
				local seat = seatOf[holder]
				if seat then x, y = ChargePoint(seat) end
				-- shakes harder as the end nears
				local shake = t > 0 and (1.5 + 3 * Clamp(t / boom, 0, 1)) or 0
				x = x + math.sin(now * 37) * shake
				y = y + math.cos(now * 29) * shake * 0.6
			elseif from and to and seatOf[from] and seatOf[to] then
				local ax, ay = ChargePoint(seatOf[from])
				local bx, by = ChargePoint(seatOf[to])
				local e = frac * frac * (3 - 2 * frac)
				local dist = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
				x = ax + (bx - ax) * e
				y = ay + (by - ay) * e - math.sin(math.pi * frac) * (30 + dist * 0.25)
				rot = frac * math.pi * 2
			end
			charge:ClearAllPoints()
			charge:SetPoint("CENTER", stage, "TOPLEFT", x, -y)
			chargeIcon:SetRotation(rot)
			local nearEnd = Clamp((t - (boom - S.LAST_HOLD)) / S.LAST_HOLD, 0, 1)
			charge:SetScale(1 + 0.5 * nearEnd + (nearEnd > 0 and 0.08 * math.sin(now * 25) or 0))
			chargeIcon:SetVertexColor(1, 1 - 0.5 * nearEnd, 1 - 0.6 * nearEnd)
			local lit = t >= 0 and not out
			spark:SetShown(lit)
			sparkHalo:SetShown(lit)
			sparkHalo:SetAlpha(0.4 + 0.6 * math.abs(math.sin(now * 23)))
			chargeGlow:SetAlpha(lit and (0.5 + 0.5 * nearEnd) or 0.15)
			charge:Show()
		end

		-- explosion
		local e = t - boom
		local seat = seatOf[script.loser]
		if exploded and seat and e < 3 then
			flash:SetAlpha(Clamp(0.8 - e * 1.8, 0, 1))
			for i, b in ipairs(blasts) do
				local p = Clamp((e - (i - 1) * 0.06) / 0.65, 0, 1)
				local size = 20 + p * (300 - i * 50)
				b:ClearAllPoints()
				b:SetPoint("CENTER", stage, "TOPLEFT", seat.x, -(seat.y - modelH * 0.1))
				b:SetSize(size, size * 0.8)
				b:SetAlpha(p > 0 and (1 - p) or 0)
			end
			local sp = Clamp(e / 2.6, 0, 1)
			smoke:ClearAllPoints()
			smoke:SetPoint("CENTER", stage, "TOPLEFT", seat.x, -(seat.y - modelH * 0.2 - sp * 30))
			smoke:SetSize(40 + sp * 150, (40 + sp * 150) * 0.7)
			smoke:SetAlpha(e > 0.15 and 0.7 * (1 - sp) or 0)
			for i, d in ipairs(debris) do
				local a = i * (2 * math.pi / #debris) + 0.3
				local p = Clamp(e / 0.9, 0, 1)
				local r = p * (90 + (i % 4) * 25)
				d:ClearAllPoints()
				d:SetPoint("CENTER", stage, "TOPLEFT", seat.x + math.cos(a) * r,
					-(seat.y - modelH * 0.15 - math.sin(a) * r * 0.7 - p * p * 40))
				d:SetAlpha(1 - p)
			end
		else
			HideFx()
		end

		-- sounds, only while it plays live (not when the window opens long after)
		if round.phase == "SPINNING" and t >= 0 then
			if step and step ~= lastStep and not exploded then
				lastStep = step
				if holder then PlaySoundSafe("U_CHAT_SCROLL_BUTTON") end
			end
			if not exploded and now - lastTick > (0.55 - 0.42 * Clamp(t / boom, 0, 1)) and not out then
				lastTick = now
				PlaySoundSafe("IG_MINIMAP_ZOOM_IN")
			end
			if exploded and boomSeen ~= round.id and e < 1 then
				boomSeen = round.id
				PlaySoundSafe("RAID_WARNING", "READY_CHECK")
			end
		end

		-- commentary
		if round.phase == "SPINNING" then
			if t < 0 then
				headline:SetText(tostring(math.ceil(-t)))
				headline:SetTextColor(T.Unpack(C.gold))
			else
				local current
				for _, ev in ipairs(script.events) do
					if ev.t <= t then current = ev end
				end
				-- who has it right now, unless something just happened
				local text, color = holder and (U.Short(holder) .. " has it!") or (to and ("Over to " .. U.Short(to) .. "!")) or "", FIRE
				if current and (current.kind == "boom" or (current.kind == "fizzle" and out) or t - current.t < 1.2) then
					text = current.text
					color = current.kind == "boom" and RED or current.kind == "fizzle" and C.green or C.gold
				end
				headline:SetText(text)
				headline:SetTextColor(T.Unpack(color))
			end
		end
	end

	local function ResetShow()
		charge:Hide()
		HideFx()
		for name, seat in pairs(seatOf) do
			SetAnim(seat, ANIM.stand)
			seat.hot:Hide()
			seat.money:Hide()
		end
	end

	function v:Refresh()
		local round = J.round
		if not round or round.game ~= "sapper" then
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

		-- seats follow the entries
		local players = U.SortedKeys(round.bets)
		local signature = table.concat(players, ",")
		if signature ~= table.concat(names, ",") then
			names = players
			Layout(names)
		end
		for i, name in ipairs(names) do
			colors[name] = ns.Wheel.ColorFor(i)
			local seat = seatOf[name]
			if seat then
				seat.ring:SetColorTexture(T.Unpack(colors[name]))
				seat.mine:SetShown(name == me)
				seat.name:SetText(ColorCode(colors[name]) .. U.Short(name) .. "|r"
					.. (name == round.host and " |cff9d8fbf(host)|r" or ""))
				local skin = D.SKINS[U.FNV1a(name .. ":" .. round.id .. ":sapper") % #D.SKINS + 1]
				SetSkin(seat, name, skin, seat.facing0 or 0)
			end
		end

		if round.result and scriptRound ~= round.id then
			scriptRound = round.id
			script = S.Script(round)
			showGame = false
			lastStep = nil
		elseif not round.result then
			script = nil
			ResetShow()
		end
		Animate(round)

		local count = #names
		local entry = round.limit
		local inGame = round.bets[me] ~= nil
		local note, noteColor = round.warning or round.error, round.error and RED or ORANGE
		overlay:Hide()
		info:SetWidth(320)

		if round.phase == "SETUP" then
			headline:SetText("CHOOSE THE ENTRY FEE")
			headline:SetTextColor(T.Unpack(C.gold))
			message:SetText("Whoever holds the charge when it blows up pays every other player this much. "
				.. "It can't change once entries are open. "
				.. (round.practice and "Then open entries for the bots." or "Then open entries for your group."))
			message:SetTextColor(T.Unpack(C.textDim))
			ShowOnly(feeBox, presets[1], presets[2], presets[3], presets[4], openBtn, cancelBtn)
			if not feeBox:HasFocus() then feeBox:SetNumber(round.limit) end

		elseif round.phase == "BETTING" then
			headline:SetText(count .. (count == 1 and " PLAYER" or " PLAYERS") .. "  ·  ENTRY " .. U.Thousands(entry) .. "G")
			headline:SetTextColor(T.Unpack(C.gold))
			local others = math.max(1, count - (inGame and 1 or 0))
			local worst = "If it blows up on you, you pay each other player " .. U.Gold(entry) .. ": "
				.. U.Gold(entry * others) .. " with the circle as it is now, at most "
				.. U.Gold(entry * (S.MAX_PLAYERS - 1)) .. " with " .. S.MAX_PLAYERS .. " players. Otherwise you get " .. U.Gold(entry) .. "."
			local hint = (isHost and count < 2) and "You can light it once at least 2 players are in."
			message:SetText(note or hint or worst)
			message:SetTextColor(T.Unpack(note and noteColor or C.textDim))
			joinBtn:SetLabel("JOIN  ·  " .. U.Thousands(entry) .. "G")
			local entryBtn = inGame and leaveBtn or joinBtn
			if isHost then
				ShowOnly(entryBtn, lockBtn, cancelBtn)
				lockBtn:SetActive(count >= 2)
			else
				ShowOnly(entryBtn, info, quitBtn)
				info:SetWidth(240)
				info:SetText("Waiting for " .. U.Short(round.host) .. " to light it")
			end

		elseif round.phase == "ROLLING" then
			local rolled = 0
			for _, name in ipairs(names) do
				if round.seen and round.seen[name] then rolled = rolled + 1 end
			end
			headline:SetText("ROLL FOR THE FUSE  ·  " .. rolled .. "/" .. count .. " ROLLED")
			headline:SetTextColor(T.Unpack(C.cyan))
			message:SetText(note or "Everyone's /roll makes the seed. Only the seed decides who blows up, not who rolls higher.")
			message:SetTextColor(T.Unpack(note and noteColor or C.textDim))
			local left = math.max(0, math.ceil((round.deadline or 0) - GetTime()))
			if inGame and not J.HasRolled() then
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
			message:SetText(note or ("Whoever holds it when it blows pays everyone " .. U.Gold(entry) .. "."))
			message:SetTextColor(T.Unpack(note and noteColor or C.textDim))

		elseif round.phase == "DONE" then
			local res = round.result
			local others = #res.transfers
			headline:SetText(U.Short(res.loser):upper() .. " BLEW UP!")
			headline:SetTextColor(T.Unpack(RED))
			local summary = U.Short(res.loser) .. " pays " .. others .. (others == 1 and " player " or " players ")
				.. U.Gold(res.gain) .. (others == 1 and "." or " each.")
			if inGame and res.loser == me then
				summary = "You pay each player " .. U.Gold(res.gain) .. " (" .. U.Gold(res.gain * others) .. " in total). " .. summary
			elseif inGame then
				summary = "You get " .. U.Gold(res.gain) .. " from " .. U.Short(res.loser) .. ". " .. summary
			end
			if round.practice then summary = summary .. " |cff9d8fbf(practice: no gold moves)|r" end
			message:SetText(note and (note .. "\n" .. summary) or summary)
			message:SetTextColor(T.Unpack(note and noteColor or C.text))

			local rows = {}
			for _, tr in ipairs(res.transfers) do
				rows[#rows + 1] = {
					color = colors[tr.to], left = U.Short(tr.from), mid = "pays " .. U.Short(tr.to),
					right = U.Gold(tr.amount), mine = tr.from == me or tr.to == me,
					leftColor = tr.from == me and C.gold or C.text,
				}
			end
			ovList:SetData(rows)
			ovMeta:SetText(U.Short(res.loser) .. " pays " .. U.Gold(res.gain * others) .. " in total")
			overlay:SetShown(not showGame)
			replayBtn:SetLabel(showGame and "VIEW PAYMENTS" or "VIEW CIRCLE")

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
			ResetShow()
		end
	end

	-- the show runs every frame; countdowns tick a few times a second
	local clock = 0
	v:SetScript("OnUpdate", function(self, dt)
		local round = J.round
		if not round or round.game ~= "sapper" then return end
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
	end)
	J.OnChange(function()
		if v:IsVisible() then v:Refresh() end
	end)
	return v
end
