-- Sounds: the cues that tell you something needs you (a round opened, your turn to roll, your
-- result) and the sounds of the shows. Everything goes through Sound.Play, so /casino sound (or
-- the speaker button) silences the whole addon. Sounds play on the game's effects channel, so the
-- game's own volume settings apply. /casino sounds opens a window to listen to every cue.
local ADDON, ns = ...
local T, U, J = ns.Theme, ns.Util, ns.Jackpot
local C, hex = T.C, T.hex

local Sound = {}
ns.Sound = Sound

-- Each cue: sources tried in order until one plays.
--   "NAME"    a SOUNDKIT entry (interface sounds, always in the client)
--   number    a sound file ID from the game's data (classic creature sounds)
--   { ... }   one of these, at random (so repeats don't sound the same)
-- `gap`: the least seconds between two plays of the cue.
-- `alts`: other sound files to compare in /casino sounds (not played in the games).
Sound.CUES = {
	-- telling you something
	invite = { "IG_PLAYER_INVITE", "READY_CHECK", gap = 1, text = "Someone opened a round" },
	roll = { "READY_CHECK", gap = 1, text = "Your turn to /roll" },
	win = { "LOOT_WINDOW_COIN_SOUND", "IG_BACKPACK_COIN_SELECT", gap = 1, text = "You won" },
	lose = { "IG_QUEST_FAILED", gap = 1, text = "You pay" },
	open = { "IG_MAINMENU_OPEN", gap = 0.1, text = "Window opens" },
	close = { "IG_MAINMENU_CLOSE", gap = 0.1, text = "Window closes" },
	-- Ogre's Wheel
	tick = { "U_CHAT_SCROLL_BUTTON", gap = 0.035, text = "Wheel: a peg passes the pointer",
		alts = { 2138734, 2138725, 2138727 } },                         -- azerite armor ring clicks
	ding = { 1100031, "UI_IG_STORE_PURCHASE_DELIVERED_TOAST_01", gap = 1, text = "Wheel: it stops" }, -- Darkmoon Faire bell
	slap = { { 557659, 557663, 557654 }, gap = 1, text = "Wheel: the ogre whacks it" },        -- mOgreAttack1-3
	ogreRoar = { { 557656, 557661, 557651 }, gap = 1, text = "Wheel: the ogre roars at the result" }, -- mOgreAggro1-3
	-- Murloc Derby
	murlocStart = { 555998, gap = 1, text = "Derby: GO!" },                -- mMurlocPreAggroA
	murlocWin = { 556000, 555997, gap = 1, text = "Derby: the winner crosses the line" }, -- mMurlocAggroOld
	-- Hot Sapper
	pass = { "U_CHAT_SCROLL_BUTTON", gap = 0.05, text = "Sapper: the charge is caught" },
	fuse = { "IG_MINIMAP_ZOOM_IN", gap = 0.05, text = "Sapper: the fuse ticks" },
	boom = { "RAID_WARNING", gap = 1, text = "Sapper: BOOM" },
	-- Onyxia's Deep Breath
	breath = { "RAID_WARNING", gap = 1, text = "Onyxia: Deep Breath" },
	survive = { "READY_CHECK", gap = 1, text = "Onyxia: the survivor" },
}

-- The order in the test window.
Sound.ORDER = { "invite", "roll", "win", "lose", "tick", "ding", "slap", "ogreRoar", "murlocStart", "murlocWin",
	"pass", "fuse", "boom", "breath", "survive", "open", "close" }

function Sound.Enabled()
	return not (ns.db and ns.db.mute)
end

function Sound.SetEnabled(on)
	if ns.db then ns.db.mute = (not on) or nil end
	if Sound.onToggle then Sound.onToggle(on) end
end

-- One source: true when the game says it will play.
local function PlaySource(src)
	if type(src) == "table" then src = src[math.random(#src)] end
	local ok, willPlay
	if type(src) == "number" then
		ok, willPlay = pcall(PlaySoundFile, src, "SFX")
	elseif type(src) == "string" and SOUNDKIT and SOUNDKIT[src] then
		ok, willPlay = pcall(PlaySound, SOUNDKIT[src], "SFX")
	end
	-- PlaySound gives nothing back on some clients: count a call that didn't fail as played
	return ok and willPlay ~= false
end

local last = {}

-- Plays a cue (unless the addon is muted). force: also when muted (the test window).
function Sound.Play(name, force)
	if not force and not Sound.Enabled() then return end
	local cue = Sound.CUES[name]
	if not cue then return end
	local now = GetTime()
	if not force and last[name] and now - last[name] < (cue.gap or 0) then return end
	last[name] = now
	for _, src in ipairs(cue) do
		if PlaySource(src) then return true end
	end
end

-- For the shows: plays `name` once per round when the show's clock `t` reaches `at` (only live,
-- not when the window is opened long after). `tag` tells apart several moments at the same time.
local played = {}
function Sound.At(name, round, t, at, tag)
	if not round or t < at or t > at + 0.6 then return end
	local key = tostring(round.id) .. ":" .. name .. ":" .. tostring(tag or at)
	if played[key] then return end
	played[key] = true
	Sound.Play(name)
end

---------------------------------------------------------------------------
-- Cues for the player, from the round's changes
---------------------------------------------------------------------------
local seenId, seenPhase
J.OnChange(function(round)
	if not round then
		seenId, seenPhase = nil, nil
		return
	end
	local me = U.Me()
	local fresh = round.id ~= seenId
	local changed = fresh or round.phase ~= seenPhase
	seenId, seenPhase = round.id, round.phase
	if not changed then return end
	local mine = round.bets[me] ~= nil
	if fresh and round.phase == "BETTING" and not J.IsHost(round) and not round.practice then
		Sound.Play("invite")
	elseif round.phase == "ROLLING" and mine and not J.IsHost(round) and not J.HasRolled() then
		Sound.Play("roll")
	elseif round.phase == "DONE" and mine and round.result then
		local res = round.result
		local won = (res.winner and res.winner == me) or (res.loser and res.loser ~= me)
		Sound.Play(won and "win" or "lose")
	end
end)

---------------------------------------------------------------------------
-- /casino sounds: every cue with a button to hear it
---------------------------------------------------------------------------
local frame
local function CreateTest()
	local f = CreateFrame("Frame", "GoblinCasinoSoundTest", UIParent)
	local rows = #Sound.ORDER
	local cols = 2
	local perCol = math.ceil(rows / cols)
	f:SetSize(16 * 2 + cols * 300, 56 + perCol * 30 + 60)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	tinsert(UISpecialFrames, "GoblinCasinoSoundTest")
	T.Solid(f, hex("140a2b", 0.98)):SetAllPoints()
	T.Border(f, C.violet, 1)
	local title = T.Text(f, T.FONT_DISPLAY, 16, C.gold)
	title:SetPoint("TOPLEFT", 16, -14)
	title:SetText("SOUNDS")
	local close = T.DarkButton(f, "CLOSE", 70, 26)
	close:SetPoint("TOPRIGHT", -12, -10)
	close:SetScript("OnClick", function() f:Hide() end)

	for i, name in ipairs(Sound.ORDER) do
		local col, row = math.floor((i - 1) / perCol), (i - 1) % perCol
		local b = T.DarkButton(f, "PLAY", 54, 24)
		b:SetPoint("TOPLEFT", 16 + col * 300, -48 - row * 30)
		b:SetScript("OnClick", function() Sound.Play(name, true) end)
		local label = T.Text(f, T.FONT_BODY, 11, C.text)
		label:SetPoint("LEFT", b, "RIGHT", 8, 0)
		local alts = Sound.CUES[name].alts or {}
		label:SetWidth(230 - #alts * 26)
		label:SetWordWrap(false)
		label:SetText(Sound.CUES[name].text or name)
		-- other candidates: "2", "3" ... (tell which one sounds best)
		for k, id in ipairs(alts) do
			local alt = T.DarkButton(f, tostring(k + 1), 22, 24)
			alt:SetPoint("TOPLEFT", b, "TOPLEFT", 54 + 8 + 230 - (#alts - k + 1) * 26, 0)
			alt:SetScript("OnClick", function()
				local ok, willPlay = pcall(PlaySoundFile, id, "SFX")
				ns.Print(name .. " option " .. (k + 1) .. ": file " .. id .. ((ok and willPlay ~= false) and "" or " (doesn't play)"))
			end)
		end
	end

	-- any sound file ID (from wago.tools / wowhead) to try
	local box = ns.Widgets.AmountBox(f, 110, 26, 12)
	box:SetMaxLetters(9)
	box:SetPoint("BOTTOMLEFT", 16, 16)
	local try = T.DarkButton(f, "PLAY FILE ID", 110, 26)
	try:SetPoint("LEFT", box, "RIGHT", 8, 0)
	local result = T.Text(f, T.FONT_BODY, 11, C.textDim)
	result:SetPoint("LEFT", try, "RIGHT", 10, 0)
	try:SetScript("OnClick", function()
		local id = box:GetNumber()
		local ok, willPlay = pcall(PlaySoundFile, id, "SFX")
		result:SetText(id .. ": " .. ((ok and willPlay ~= false) and "|cff4dff9aplays|r" or "|cffff6b6bno sound|r"))
	end)
	return f
end

function Sound.ToggleTest()
	frame = frame or CreateTest()
	frame:SetShown(not frame:IsShown())
end
