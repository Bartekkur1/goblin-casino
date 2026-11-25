-- Main casino window (lobby): header, session pool, game cards, live ticker.
local ADDON, ns = ...
local T, U, J = ns.Theme, ns.Util, ns.Jackpot
local C, hex, Mix = T.C, T.hex, T.Mix

local Main = {}
ns.Main = Main

local W, H = 820, 560
local OUTER, EDGE, PAD_X, PAD_Y, GAP = 8, 2, 20, 18, 12
local BODY_W = W - 2 * (OUTER + EDGE) - 2 * PAD_X
local BODY_H = H - 2 * (OUTER + EDGE) - 2 * PAD_Y
local HEADER_H, BANNER_H, TICKER_H = 46, 58, 30
-- game cards: the scrolling area between the banner and the ticker (see CreateGameList)
local CARD_H = BODY_H - HEADER_H - BANNER_H - TICKER_H - 3 * GAP
local WHITE = hex("ffffff")

local GAMES = {
	{
		key = "derby",
		title = "Murloc Derby",
		desc = "Everyone enters a murloc for the same fee. Sprints, stumbles, photo finish, and the winner takes the pot.",
		icon = "Interface\\Icons\\INV_Misc_Head_Murloc_01",
		accent = C.teal, status = "READY", statusColor = C.green,
		meta = "Same entry for everyone  ·  up to 20 runners",
		onPlay = function() Main:StartGame("derby") end,
	},
	{
		key = "sapper",
		title = "Hot Sapper",
		desc = "A lit sapper charge flies round the circle, faster and faster. Whoever holds it when it blows pays everyone.",
		icon = {
			"Interface\\Icons\\INV_Gizmo_SuperSapperCharge",
			"Interface\\Icons\\INV_Misc_Bomb_08",
			"Interface\\Icons\\INV_Misc_Bomb_05",
			"Interface\\Icons\\INV_Misc_Bomb_02",
			"Interface\\Icons\\Spell_Fire_SelfDestruct",
		},
		accent = C.orange, status = "READY", statusColor = C.green,
		meta = "Same entry  ·  one pays, everyone else wins",
		onPlay = function() Main:StartGame("sapper") end,
	},
	{
		key = "onyxia",
		title = "Onyxia's Deep Breath",
		desc = "The raid on Onyxia's platform. Wave after wave of fire, and the last raider standing loots the pot.",
		icon = {
			"Interface\\Icons\\Achievement_Boss_Onyxia",
			"Interface\\Icons\\INV_Misc_Head_Dragon_Black",
			"Interface\\Icons\\INV_Misc_Head_Dragon_01",
			"Interface\\Icons\\Spell_Fire_Fire",
		},
		accent = hex("ff5c5c"), status = "READY", statusColor = C.green,
		meta = "Any stake  ·  bigger stake, thicker cloak",
		onPlay = function() Main:StartGame("onyxia") end,
	},
	{
		key = "wheel",
		title = "Ogre's Wheel",
		desc = "Bigger stake, bigger slice of the wheel. One spin, and the winner takes the whole pool.",
		meta = "Any stake up to the host's limit",
		statusColor = C.green,
		onPlay = function() Main:StartGame("wheel") end,
		-- candidates in order of preference; the first one this client has is used
		icon = {
			"Interface\\Icons\\Achievement_Reputation_Ogre",      -- Ogri'la: the classic ogre face
			"Interface\\Icons\\Achievement_Boss_Gruul",
			"Interface\\Icons\\Achievement_Boss_HighKingMaulgar",
			"Interface\\Icons\\INV_Misc_Head_Ogre_01",
			"Interface\\Icons\\INV_Misc_OgrePinata",
			"Interface\\Icons\\INV_Misc_Dice_02",
		},
		accent = C.lilac, status = "READY",
	},
}

local function WithAlpha(c, a) return { c[1], c[2], c[3], a } end

---------------------------------------------------------------------------
-- Marquee bulbs around the window (blink in turns while the window is open)
---------------------------------------------------------------------------
local function CreateBulbs(f)
	local bulbs = {}
	local size, inset, spacing = 4, OUTER / 2, 16
	local function Add(x, y, parity)
		local b = T.Circle(f, size, "BORDER")
		b:SetColorTexture(T.Unpack(C.bulbOn))
		b:SetPoint("CENTER", f, "TOPLEFT", x, -y)
		b.parity = parity
		bulbs[#bulbs + 1] = b
	end
	local nx = math.floor((W - 2 * inset) / spacing)
	local stepX = (W - 2 * inset) / nx
	for i = 0, nx do
		Add(inset + i * stepX, inset, i % 2)
		Add(inset + i * stepX, H - inset, i % 2)
	end
	local ny = math.floor((H - 2 * inset) / spacing)
	local stepY = (H - 2 * inset) / ny
	for i = 1, ny - 1 do
		Add(inset, inset + i * stepY, i % 2)
		Add(W - inset, inset + i * stepY, i % 2)
	end

	local elapsed, phase = 0, 0
	local function Paint()
		for _, b in ipairs(bulbs) do
			b:SetAlpha(b.parity == phase and 1 or 0.3)
		end
	end
	Paint()
	f:HookScript("OnUpdate", function(_, dt)
		elapsed = elapsed + dt
		if elapsed >= 0.6 then
			elapsed = 0
			phase = 1 - phase
			Paint()
		end
	end)
end

---------------------------------------------------------------------------
-- Header: emblem, title, group status, gold, close button
---------------------------------------------------------------------------
local function CreateHeader(f, body)
	local emblem = CreateFrame("Frame", nil, body)
	emblem:SetSize(HEADER_H, HEADER_H)
	emblem:SetPoint("TOPLEFT")
	local rim = T.Circle(emblem, HEADER_H, "BACKGROUND")
	rim:SetPoint("CENTER")
	rim:SetColorTexture(T.Unpack(C.gold))
	local face = T.Circle(emblem, HEADER_H - 6, "BORDER")
	face:SetPoint("CENTER")
	face:SetColorTexture(T.Unpack(Mix(C.goldDark, C.goldShadow, 0.35)))
	-- a goblin's face in the gold ring (the first icon this client has; a "G" if none)
	local goblin
	for _, path in ipairs({
		"Interface\\Icons\\Achievement_Character_Goblin_Male",
		"Interface\\Icons\\Achievement_Goblinhead",
		"Interface\\Icons\\Achievement_Character_Goblin_Female",
	}) do
		if not GetFileIDFromPath or GetFileIDFromPath(path) then goblin = path; break end
	end
	if goblin then
		face:SetTexture(goblin)
		face:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- without the icon's own border
	else
		local letter = T.Text(emblem, T.FONT_DISPLAY, 22, C.goldInk)
		letter:SetJustifyH("CENTER")
		letter:SetPoint("CENTER", 1, 0)
		letter:SetText("G")
	end

	local title = T.Text(body, T.FONT_DISPLAY, 26, C.gold)
	title:SetPoint("TOPLEFT", emblem, "TOPRIGHT", 12, -1)
	title:SetText("GOBLIN CASINO")
	title:SetShadowColor(T.Unpack(hex("7a2a00")))
	title:SetShadowOffset(0, -2)

	local sub = T.Text(body, T.FONT_BOLD, 10, C.textDim)
	sub:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 1, -5)
	f.subtitle = sub

	-- Close button (X in the corner)
	local close = CreateFrame("Button", nil, body)
	close:SetSize(36, 36)
	close:SetPoint("TOPRIGHT", 0, -5)
	T.Solid(close, C.bgDeep):SetAllPoints()
	local border = T.Border(close, C.violet, 1)
	local strokes = {}
	for i, deg in ipairs({ 45, -45 }) do
		local s = close:CreateTexture(nil, "ARTWORK")
		s:SetColorTexture(T.Unpack(C.text))
		s:SetSize(16, 2)
		s:SetPoint("CENTER")
		s:SetRotation(math.rad(deg))
		strokes[i] = s
	end
	local function Tint(c)
		border:SetColor(c)
		for _, s in ipairs(strokes) do s:SetColorTexture(T.Unpack(c)) end
	end
	close:SetScript("OnEnter", function() Tint(C.pink) end)
	close:SetScript("OnLeave", function()
		border:SetColor(C.violet)
		for _, s in ipairs(strokes) do s:SetColorTexture(T.Unpack(C.text)) end
	end)
	close:SetScript("OnClick", function() f:Hide() end)

	-- Character gold (GetMoney); width follows the text in Main:UpdateMoney
	local money = CreateFrame("Frame", nil, body)
	money:SetSize(120, 36)
	money:SetPoint("RIGHT", close, "LEFT", -8, 0)
	T.Solid(money, C.bgDeep):SetAllPoints()
	T.Border(money, C.violet, 1)
	local coin = T.Circle(money, 12, "ARTWORK")
	coin:SetPoint("LEFT", 12, 0)
	coin:SetColorTexture(T.Unpack(C.goldDark))
	local moneyText = T.Text(money, T.FONT_BOLD, 13, C.text)
	moneyText:SetPoint("LEFT", coin, "RIGHT", 8, 0)
	f.money, f.moneyText = money, moneyText

	-- History
	local history = T.DarkButton(body, "HISTORY", 84, 36)
	history:SetPoint("RIGHT", money, "LEFT", -8, 0)
	history:SetScript("OnClick", function()
		Main:ShowView(Main.view == "history" and (J.round and J.round.game or "lobby") or "history")
	end)

	-- Debug log (bug icon): opens the log ready to copy
	local bug = T.DarkButton(body, "", 36, 36)
	bug:SetPoint("RIGHT", history, "LEFT", -8, 0)
	local icon = bug:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("CENTER")
	icon:SetSize(24, 24)
	local bugIcon = "Interface\\Icons\\Spell_Nature_InsectSwarm"
	for _, path in ipairs({ "Interface\\HelpFrame\\HelpIcon-Bug", bugIcon }) do
		if not GetFileIDFromPath or GetFileIDFromPath(path) then bugIcon = path; break end
	end
	icon:SetTexture(bugIcon)
	if bugIcon:find("Icons") then icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) end
	bug:HookScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
		GameTooltip:SetText("Debug log")
		GameTooltip:AddLine("Everything Goblin Casino did: rounds, messages, rolls, errors.\nClick, then Ctrl+C to copy it.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	bug:HookScript("OnLeave", function() GameTooltip:Hide() end)
	bug:SetScript("OnClick", function() ns.LogWindow:Toggle() end)
end

---------------------------------------------------------------------------
-- Session banner: pool on the left, stats on the right
---------------------------------------------------------------------------
local function Stat(parent, label, anchor)
	local block = CreateFrame("Frame", nil, parent)
	block:SetSize(92, BANNER_H)
	if anchor then
		block:SetPoint("RIGHT", anchor, "LEFT", 0, 0)
		local divider = T.Solid(block, WithAlpha(C.pink, 0.35), "ARTWORK")
		divider:SetSize(1, BANNER_H - 22)
		divider:SetPoint("RIGHT", block, "RIGHT", 0, 0)
	else
		block:SetPoint("RIGHT", parent, "RIGHT", -6, 0)
	end
	local value = T.Text(block, T.FONT_DISPLAY, 20, WHITE)
	value:SetJustifyH("CENTER")
	value:SetPoint("BOTTOM", block, "CENTER", 0, -4)
	local caption = T.Text(block, T.FONT_BOLD, 9, hex("ffc2e1"))
	caption:SetJustifyH("CENTER")
	caption:SetPoint("TOP", value, "BOTTOM", 0, -4)
	caption:SetText(label)
	block.value = value
	return block
end

local function CreateBanner(f, body)
	local banner = CreateFrame("Frame", nil, body)
	banner:SetSize(BODY_W, BANNER_H)
	banner:SetPoint("TOPLEFT", 0, -(HEADER_H + GAP))
	local edgeColor, midColor = Mix(C.pink, C.bgDeep, 0.55), Mix(C.pink, C.bgDeep, 0.25)
	local left = T.Gradient(banner, "HORIZONTAL", edgeColor, midColor)
	left:SetPoint("TOPLEFT")
	left:SetPoint("BOTTOMRIGHT", banner, "BOTTOM")
	local right = T.Gradient(banner, "HORIZONTAL", midColor, edgeColor)
	right:SetPoint("TOPLEFT", banner, "TOP")
	right:SetPoint("BOTTOMRIGHT")
	T.Border(banner, C.pink, 1)
	T.Glow(banner, C.pink, 8, 0.35)

	local label = T.Text(banner, T.FONT_BOLD, 10, hex("ffc2e1"))
	label:SetPoint("TOPLEFT", 16, -11)
	label:SetText("SESSION POOL")
	local pool = T.Text(banner, T.FONT_DISPLAY, 22, WHITE)
	pool:SetPoint("BOTTOMLEFT", 16, 9)
	pool:SetShadowColor(T.Unpack(hex("5a0630")))
	pool:SetShadowOffset(0, -2)
	pool:SetText("0")
	local unit = T.Text(banner, T.FONT_BOLD, 13, C.gold)
	unit:SetPoint("BOTTOMLEFT", pool, "BOTTOMRIGHT", 6, 2)
	unit:SetText("gold")

	local rounds = Stat(banner, "ROUNDS")
	rounds.value:SetText("0")
	local players = Stat(banner, "PLAYERS", rounds)
	f.pool, f.playersStat, f.roundsStat = pool, players, rounds
end

---------------------------------------------------------------------------
-- Game cards
---------------------------------------------------------------------------
-- An icon path, or a list of candidate paths: picks the first one that exists in this client.
local function PickIcon(icon)
	if type(icon) ~= "table" then return icon end
	if not GetFileIDFromPath then return icon[1] end
	for _, path in ipairs(icon) do
		if GetFileIDFromPath(path) then return path end
	end
	return icon[#icon]
end

-- One game card (icon on the left, text beside it, status and PLAY at the bottom right).
local function CreateCard(parent, game, w, h, x, y)
	local accent = game.accent
	local ICON, PAD = 76, 14

	local card = CreateFrame("Frame", nil, parent)
	card:SetSize(w, h)
	card:SetPoint("TOPLEFT", x, y)
	T.Gradient(card, "HORIZONTAL", Mix(accent, C.bgDeep, 0.62), Mix(accent, C.bgDeep, 0.84)):SetAllPoints()
	local border = T.Border(card, accent, 1)
	border:SetColor(accent, 0.7)
	local glow = T.Glow(card, accent, 4, 0.25)

	local box = CreateFrame("Frame", nil, card)
	box:SetSize(ICON, ICON)
	box:SetPoint("TOPLEFT", PAD, -PAD)
	T.Solid(box, Mix(accent, C.bgDeep, 0.85)):SetAllPoints()
	T.Border(box, accent, 1):SetColor(accent, 0.6)
	T.Glow(box, accent, 5, 0.35)
	local icon = box:CreateTexture(nil, "ARTWORK")
	icon:SetPoint("TOPLEFT", 3, -3)
	icon:SetPoint("BOTTOMRIGHT", -3, 3)
	icon:SetTexture(PickIcon(game.icon))
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	-- title, description, rules line beside the icon
	local textW = w - ICON - 3 * PAD
	local title = T.Text(card, T.FONT_DISPLAY, 17, Mix(accent, WHITE, 0.55))
	title:SetPoint("TOPLEFT", box, "TOPRIGHT", PAD, -1)
	title:SetWidth(textW)
	title:SetWordWrap(false)
	title:SetText(game.title:upper())
	local desc = T.Text(card, T.FONT_BODY, 12, Mix(accent, WHITE, 0.85))
	desc:SetAlpha(0.9)
	desc:SetJustifyV("TOP")
	desc:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -6)
	desc:SetWidth(textW)
	desc:SetSpacing(2)
	desc:SetMaxLines(3)
	desc:SetText(game.desc)
	local meta = T.Text(card, T.FONT_BOLD, 10, Mix(accent, WHITE, 0.35))
	meta:SetPoint("TOPLEFT", desc, "BOTTOMLEFT", 0, -6)
	meta:SetWidth(textW)
	meta:SetWordWrap(false)
	meta:SetText(game.meta or "")

	-- bottom right: status pill, then a big PLAY button
	local play = T.GoldButton(card, "PLAY", 120, 32)
	play:SetPoint("BOTTOMRIGHT", -PAD, PAD)
	play.label:SetFont(T.FONT_DISPLAY, 15, "")
	local statusColor = game.statusColor or accent
	local status = T.Pill(card, game.status, WithAlpha(statusColor, 0.16), statusColor)
	-- the pill's background hugs its label, so place the label
	status:SetPoint("BOTTOMLEFT")
	status.label:ClearAllPoints()
	status.label:SetPoint("RIGHT", play, "LEFT", -20, 1)
	game.statusPill, game.playButton, game.readyColor = status, play, statusColor

	if game.soon then
		play:SetUnavailable()
	else
		play:SetScript("OnClick", function()
			if game.onPlay then game.onPlay() end
		end)
	end

	-- hover: brighter border and glow. Clicks pass through so the window can still be dragged by a card.
	card:SetMouseMotionEnabled(true)
	card:SetMouseClickEnabled(false)
	local function Hover(on)
		border:SetColor(accent, on and 1 or 0.7)
		glow:SetColor(accent, on and 0.55 or 0.25)
	end
	local function Leave()
		if not card:IsMouseOver() then Hover(false) end
	end
	card:SetScript("OnEnter", function() Hover(true) end)
	card:SetScript("OnLeave", Leave)
	play:HookScript("OnEnter", function() Hover(true) end)
	play:HookScript("OnLeave", Leave)
	return card
end

-- The games: two columns, two rows in view, the mouse wheel scrolls to more rows (with a thin
-- scrollbar on the right once there are more games than fit).
local function CreateGameList(lobby)
	local INSET, BAR = 5, 12
	local top = HEADER_H + GAP + BANNER_H + GAP
	local viewH = CARD_H
	local viewW = BODY_W - BAR
	local cardW = (viewW - GAP - 2 * INSET) / 2
	local rowH = (viewH - GAP - 2 * INSET) / 2
	local rows = math.ceil(#GAMES / 2)
	local contentH = rows * rowH + (rows - 1) * GAP + 2 * INSET
	local maxScroll = math.max(0, contentH - viewH)

	local scroll = CreateFrame("ScrollFrame", nil, lobby)
	scroll:SetPoint("TOPLEFT", 0, -top)
	scroll:SetSize(viewW, viewH)
	local content = CreateFrame("Frame", nil, scroll)
	content:SetSize(viewW, contentH)
	scroll:SetScrollChild(content)
	for i, game in ipairs(GAMES) do
		local col, row = (i - 1) % 2, math.floor((i - 1) / 2)
		CreateCard(content, game, cardW, rowH, INSET + col * (cardW + GAP), -(INSET + row * (rowH + GAP)))
	end

	local trackH = viewH - 2 * INSET
	local track = T.Solid(lobby, WithAlpha(C.violet, 0.35), "ARTWORK")
	track:SetPoint("TOPRIGHT", lobby, "TOPRIGHT", -3, -(top + INSET))
	track:SetSize(4, trackH)
	local thumb = T.Solid(lobby, C.pink, "OVERLAY")
	thumb:SetWidth(4)
	local thumbH = math.max(28, trackH * viewH / contentH)
	thumb:SetHeight(thumbH)
	local function UpdateBar()
		local at = maxScroll > 0 and scroll:GetVerticalScroll() / maxScroll or 0
		thumb:ClearAllPoints()
		thumb:SetPoint("TOP", track, "TOP", 0, -(trackH - thumbH) * at)
	end
	track:SetShown(maxScroll > 0)
	thumb:SetShown(maxScroll > 0)
	UpdateBar()

	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local target = self:GetVerticalScroll() - delta * (rowH + GAP)
		self:SetVerticalScroll(math.max(0, math.min(maxScroll, target)))
		UpdateBar()
	end)
end

---------------------------------------------------------------------------
-- LIVE ticker
---------------------------------------------------------------------------
local function CreateTicker(f, body)
	local bar = CreateFrame("Frame", nil, body)
	bar:SetSize(BODY_W, TICKER_H)
	bar:SetPoint("BOTTOMLEFT")
	T.Solid(bar, hex("0d0520")):SetAllPoints()
	T.Border(bar, hex("4a2a80"), 1)

	local dot = T.Circle(bar, 8, "ARTWORK")
	dot:SetPoint("LEFT", 12, 0)
	dot:SetColorTexture(T.Unpack(C.green))
	local pulse = bar:CreateAnimationGroup()
	pulse:SetLooping("BOUNCE")
	local fade = pulse:CreateAnimation("Alpha")
	fade:SetTarget(dot)
	fade:SetFromAlpha(1)
	fade:SetToAlpha(0.25)
	fade:SetDuration(0.8)
	pulse:Play()

	local live = T.Text(bar, T.FONT_BOLD, 11, C.green)
	live:SetPoint("LEFT", dot, "RIGHT", 8, 0)
	live:SetText("LIVE")
	local msg = T.Text(bar, T.FONT_BODY, 12, hex("e6dcff"))
	msg:SetPoint("LEFT", live, "RIGHT", 12, 0)
	msg:SetText("The casino is open. The first round is waiting for a host.")
	f.tickerText = msg
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------
local ANCHORS = { TOPLEFT = true, TOP = true, TOPRIGHT = true, LEFT = true, CENTER = true, RIGHT = true,
	BOTTOMLEFT = true, BOTTOM = true, BOTTOMRIGHT = true }

local function RestorePosition(f)
	f:ClearAllPoints()
	local p = ns.db and ns.db.window
	if type(p) == "table" and ANCHORS[p.point] and tonumber(p.x) and tonumber(p.y) then
		f:SetPoint(p.point, UIParent, ANCHORS[p.relPoint] and p.relPoint or p.point, tonumber(p.x), tonumber(p.y))
	else
		f:SetPoint("CENTER")
	end
end

local function Create()
	local f = CreateFrame("Frame", "GoblinCasinoMainFrame", UIParent)
	f:SetSize(W, H)
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:SetDontSavePosition(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		local point, _, relPoint, x, y = self:GetPoint(1)
		ns.db.window = { point = point, relPoint = relPoint, x = x, y = y }
	end)
	f:Hide()
	tinsert(UISpecialFrames, "GoblinCasinoMainFrame") -- ESC closes the window

	-- outer marquee frame with bulbs
	T.Solid(f, C.bgLight):SetAllPoints()
	CreateBulbs(f)

	-- inside: gradient and a gold edge
	local inner = CreateFrame("Frame", nil, f)
	inner:SetPoint("TOPLEFT", OUTER, -OUTER)
	inner:SetPoint("BOTTOMRIGHT", -OUTER, OUTER)
	T.Gradient(inner, "VERTICAL", C.bgDeep, C.bgTop):SetAllPoints()
	T.Border(inner, C.goldDark, EDGE)

	local body = CreateFrame("Frame", nil, inner)
	body:SetPoint("TOPLEFT", EDGE + PAD_X, -(EDGE + PAD_Y))
	body:SetPoint("BOTTOMRIGHT", -(EDGE + PAD_X), EDGE + PAD_Y)

	CreateHeader(f, body)

	-- views below the header: the lobby and the Ogre's Wheel screen
	local lobby = CreateFrame("Frame", nil, body)
	lobby:SetAllPoints(body)
	CreateBanner(f, lobby)
	CreateGameList(lobby)
	CreateTicker(f, lobby)
	local wheel = ns.WheelView.Create(body, BODY_W, BODY_H - HEADER_H - GAP)
	wheel:SetPoint("TOPLEFT", 0, -(HEADER_H + GAP))
	local derby = ns.DerbyView.Create(body, BODY_W, BODY_H - HEADER_H - GAP)
	derby:SetPoint("TOPLEFT", 0, -(HEADER_H + GAP))
	local sapper = ns.SapperView.Create(body, BODY_W, BODY_H - HEADER_H - GAP)
	sapper:SetPoint("TOPLEFT", 0, -(HEADER_H + GAP))
	local onyxia = ns.OnyxiaView.Create(body, BODY_W, BODY_H - HEADER_H - GAP)
	onyxia:SetPoint("TOPLEFT", 0, -(HEADER_H + GAP))
	local history = ns.HistoryView.Create(body, BODY_W, BODY_H - HEADER_H - GAP)
	history:SetPoint("TOPLEFT", 0, -(HEADER_H + GAP))
	f.views = { lobby = lobby, wheel = wheel, derby = derby, sapper = sapper, onyxia = onyxia, history = history }
	J.OnChange(function() Main:UpdateLobby() end)

	f:RegisterEvent("PLAYER_MONEY")
	f:RegisterEvent("GROUP_ROSTER_UPDATE")
	f:SetScript("OnEvent", function(_, event)
		if not f:IsShown() then return end
		if event == "PLAYER_MONEY" then Main:UpdateMoney() else Main:UpdateGroup() end
	end)
	f:SetScript("OnShow", function()
		Main:UpdateMoney()
		Main:UpdateGroup()
		Main:UpdateLobby()
		Main:ShowView(J.round and J.round.game or "lobby")
		-- the custom font may load a frame late; measure the gold text again once it has
		C_Timer.After(0, function() Main:UpdateMoney() end)
		if SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPEN) end
	end)
	f:SetScript("OnHide", function()
		if SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_CLOSE) end
	end)

	RestorePosition(f)
	return f
end

function Main:Get()
	self.frame = self.frame or Create()
	return self.frame
end

function Main:Toggle()
	local f = self:Get()
	f:SetShown(not f:IsShown())
end

function Main:ShowView(name)
	local f = self:Get()
	for key, view in pairs(f.views) do
		view:SetShown(key == name)
	end
	self.view = name
end

-- PLAY on a game card: join the running round, or open a new one.
-- Bots only when practice mode is on (/casino practice).
function Main:StartGame(game)
	local f = self:Get()
	if J.round and not J.Active() then J.Dismiss() end
	if J.round then
		if J.round.game ~= game then
			ns.Print(J.Game().title .. " is running right now. Join it or wait until it ends.")
		end
		f:Show()
		self:ShowView(J.round.game)
		return
	end
	local practice = ns.practice
	if not practice and not ns.Comm.Channel() then
		ns.Print("Join a party or raid to play. To try a game with bots, type |cffffd100/casino practice|r.")
		return
	end
	local ok, err = J.Open(practice, game)
	if not ok then
		ns.Print(err)
		return
	end
	f:Show()
	self:ShowView(game)
end

-- Somebody else opened a round.
function Main:OnRoundOpened()
	-- don't pull the player away from the history screen
	if self.frame and self.frame:IsShown() and J.round and self.view ~= "history" then self:ShowView(J.round.game) end
end

function Main:UpdateLobby()
	local f = self.frame
	if not f then return end
	f.pool:SetText(U.Thousands(J.session.pool))
	f.roundsStat.value:SetText(J.session.rounds)
	local round = J.Active()
	local grouped = ns.Comm.Channel() ~= nil
	for _, game in ipairs(GAMES) do
		if game.key then
			local status
			if round and round.game == game.key then
				if round.phase == "SETUP" then
					status = "SETTING UP"
					game.playButton:SetLabel("OPEN")
				else
					status = round.phase == "BETTING" and (J.Game(round).fixed and "ENTRIES OPEN" or "BETS OPEN") or "IN PROGRESS"
					game.playButton:SetLabel((J.MyBet() or round.phase ~= "BETTING") and "OPEN" or "JOIN")
				end
			else
				if round then
					status = "AFTER THIS ROUND"
				elseif ns.practice then
					status = "PRACTICE MODE"
				else
					status = grouped and "READY" or "NEEDS A GROUP"
				end
				game.playButton:SetLabel("PLAY")
			end
			local color = (status == "READY" and game.readyColor)
				or ((status == "NEEDS A GROUP" or status == "AFTER THIS ROUND") and C.textDim)
				or (status == "PRACTICE MODE" and C.orange) or C.gold
			game.statusPill.label:SetText(status)
			game.statusPill.label:SetTextColor(T.Unpack(color))
			game.statusPill.back:SetColorTexture(color[1], color[2], color[3], 0.16)
		end
	end
	if round and round.phase == "SETUP" then
		f.tickerText:SetText("You're setting up " .. J.Game(round).title .. ". Choose the stake, then open it for everyone.")
	elseif round then
		f.tickerText:SetText(round.practice and (J.Game(round).title .. ": practice round with bots is running.")
			or (U.Short(round.host) .. " is hosting " .. J.Game(round).title .. ". Join in!"))
	elseif ns.practice then
		f.tickerText:SetText("Practice mode is on: PLAY starts a round with bots. Type /casino practice to turn it off.")
	else
		f.tickerText:SetText(grouped and "The casino is open. The first round is waiting for a host."
			or "Invite your friends to a party or raid to play. Practice with bots: /casino practice")
	end
	-- a game screen without a round goes back to the lobby (history stays open)
	if self.view ~= "lobby" and self.view ~= "history" and not J.round then self:ShowView("lobby") end
end

function Main:ResetPosition()
	ns.db.window = nil
	if self.frame then RestorePosition(self.frame) end
end

function Main:UpdateMoney()
	local f = self.frame
	f.moneyText:SetText(T.FormatMoney(GetMoney()))
	f.money:SetWidth(12 + 12 + 8 + f.moneyText:GetStringWidth() + 14)
end

function Main:UpdateGroup()
	local f = self.frame
	local n = GetNumGroupMembers()
	if IsInRaid() then
		f.subtitle:SetText("RAID · " .. n .. " PLAYERS")
	elseif n > 0 then
		f.subtitle:SetText("PARTY · " .. n .. " PLAYERS")
	else
		f.subtitle:SetText("SOLO · JOIN A PARTY OR RAID TO PLAY")
	end
	f.playersStat.value:SetText(math.max(n, 1))
	self:UpdateLobby()
end
