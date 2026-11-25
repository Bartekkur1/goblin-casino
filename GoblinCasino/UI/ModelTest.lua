-- /casino models: a test window that shows candidate murloc models side by side, running, so we can
-- see which display IDs / creature IDs work on this client before using them in the derby.
local ADDON, ns = ...
local T = ns.Theme
local C, hex = T.C, T.hex

local MT = {}
ns.ModelTest = MT

-- Candidates. "D" = creature display ID (SetDisplayInfo), "C" = creature/NPC ID (SetCreature).
-- From memory of classic murlocs; some may be wrong, that's what this window is for.
local CANDIDATES = {
	{ "D", 8570 }, { "D", 11380 }, -- Onyxia, Nefarian (for Onyxia's Deep Breath)
	{ "D", 441 }, { "D", 478 }, { "D", 486 }, { "D", 487 }, { "D", 506 }, { "D", 507 }, { "D", 524 },
	{ "D", 527 }, { "D", 535 }, { "D", 545 }, { "D", 548 }, { "D", 549 }, { "D", 616 }, { "D", 655 },
	{ "C", 46 }, { "C", 126 }, { "C", 127 }, { "C", 171 }, { "C", 456 }, { "C", 458 }, { "C", 513 },
	{ "C", 515 }, { "C", 517 }, { "C", 578 }, { "C", 732 }, { "C", 1767 },
}

local COLS, CELL_W, CELL_H = 7, 108, 118
local ANIMS = { { "STAND", 0 }, { "RUN", 5 }, { "STUN", 14 }, { "CHEER", 68 }, { "DEATH", 1 }, { "ROAR", 74 }, { "CAST", 51 } }

local frame
local cells = {}
local anim, facing = 5, -math.pi / 2

local function Apply(m)
	pcall(m.SetFacing, m, facing)
	pcall(m.SetAnimation, m, anim)
end

local function Load(cell, kind, id)
	local m = cell.model
	cell.kind, cell.id = kind, id
	pcall(m.ClearModel, m)
	m:SetScript("OnModelLoaded", function(self) Apply(self) end)
	if kind == "D" then
		pcall(m.SetDisplayInfo, m, id)
	else
		pcall(m.SetCreature, m, id)
	end
	Apply(m)
	cell.label:SetText(kind .. " " .. id)
	cell.status:SetText("loading...")
	-- after a moment: did a model actually load?
	C_Timer.After(1.5, function()
		if cell.kind ~= kind or cell.id ~= id then return end
		local ok, file = pcall(m.GetModelFileID, m)
		if ok and file and file ~= 0 then
			cell.status:SetText("|cff4dff9afile " .. file .. "|r")
		else
			cell.status:SetText("|cffff6b6bno model|r")
		end
		Apply(m)
	end)
end

local function Cell(parent, i)
	local col, row = (i - 1) % COLS, math.floor((i - 1) / COLS)
	local cell = CreateFrame("Frame", nil, parent)
	cell:SetSize(CELL_W - 6, CELL_H - 6)
	cell:SetPoint("TOPLEFT", 16 + col * CELL_W, -56 - row * CELL_H)
	T.Solid(cell, hex("0a2530")):SetAllPoints()
	T.Border(cell, hex("4a2a80"), 1)
	local m = CreateFrame("PlayerModel", nil, cell)
	m:SetPoint("TOPLEFT", 2, -2)
	m:SetPoint("BOTTOMRIGHT", -2, 24)
	cell.model = m
	cell.label = T.Text(cell, T.FONT_BOLD, 11, C.gold)
	cell.label:SetPoint("BOTTOMLEFT", 6, 12)
	cell.status = T.Text(cell, T.FONT_BODY, 9, C.textDim)
	cell.status:SetPoint("BOTTOMLEFT", 6, 2)
	return cell
end

local function ApplyAll()
	for _, cell in ipairs(cells) do Apply(cell.model) end
end

local function Create()
	local rows = math.ceil((#CANDIDATES + 1) / COLS)
	local f = CreateFrame("Frame", "GoblinCasinoModelTest", UIParent)
	f:SetSize(16 * 2 + COLS * CELL_W, 56 + rows * CELL_H + 70)
	f:SetPoint("CENTER")
	f:SetFrameStrata("HIGH")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	tinsert(UISpecialFrames, "GoblinCasinoModelTest")
	T.Gradient(f, "VERTICAL", C.bgDeep, C.bgTop):SetAllPoints()
	T.Border(f, C.goldDark, 2)

	local title = T.Text(f, T.FONT_DISPLAY, 18, C.gold)
	title:SetPoint("TOPLEFT", 16, -14)
	title:SetText("MURLOC MODEL TEST")
	local hint = T.Text(f, T.FONT_BODY, 11, C.textDim)
	hint:SetPoint("LEFT", title, "RIGHT", 14, -1)
	hint:SetText("D = display ID, C = creature ID. Take a screenshot and send it over.")

	local close = T.DarkButton(f, "CLOSE", 70, 26)
	close:SetPoint("TOPRIGHT", -12, -12)
	close:SetScript("OnClick", function() f:Hide() end)

	for i, cand in ipairs(CANDIDATES) do
		local cell = Cell(f, i)
		cells[i] = cell
		Load(cell, cand[1], cand[2])
	end
	-- the last cell: your own ID
	local custom = Cell(f, #CANDIDATES + 1)
	cells[#cells + 1] = custom
	custom.label:SetText("your ID")

	-- bottom bar: animation, turn, custom ID
	local bar = CreateFrame("Frame", nil, f)
	bar:SetPoint("BOTTOMLEFT", 16, 14)
	bar:SetPoint("BOTTOMRIGHT", -16, 14)
	bar:SetHeight(34)
	local x = 0
	for _, a in ipairs(ANIMS) do
		local b = T.DarkButton(bar, a[1], 52, 30, 10)
		b:SetPoint("LEFT", x, 0)
		b:SetScript("OnClick", function()
			anim = a[2]
			ApplyAll()
		end)
		x = x + 55
	end
	local turn = T.DarkButton(bar, "TURN 90°", 76, 30)
	turn:SetPoint("LEFT", x + 6, 0)
	local facingText = T.Text(bar, T.FONT_BODY, 10, C.textDim)
	facingText:SetPoint("BOTTOM", turn, "TOP", 0, 3)
	local function ShowFacing()
		facingText:SetText(string.format("facing %d°", math.floor(math.deg(facing) + 0.5) % 360))
	end
	ShowFacing()
	turn:SetScript("OnClick", function()
		facing = facing + math.pi / 2
		ShowFacing()
		ApplyAll()
	end)

	local box = ns.Widgets.AmountBox(bar, 90, 30, 13)
	box:SetMaxLetters(7)
	box:SetPoint("RIGHT", -150, 0)
	local asDisplay = T.DarkButton(bar, "AS DISPLAY", 72, 30)
	asDisplay:SetPoint("LEFT", box, "RIGHT", 4, 0)
	local asCreature = T.DarkButton(bar, "AS NPC", 66, 30)
	asCreature:SetPoint("LEFT", asDisplay, "RIGHT", 4, 0)
	asDisplay:SetScript("OnClick", function()
		box:ClearFocus()
		if box:GetNumber() > 0 then Load(custom, "D", box:GetNumber()) end
	end)
	asCreature:SetScript("OnClick", function()
		box:ClearFocus()
		if box:GetNumber() > 0 then Load(custom, "C", box:GetNumber()) end
	end)
	return f
end

function MT:Toggle()
	frame = frame or Create()
	frame:SetShown(not frame:IsShown())
	if frame:IsShown() then ApplyAll() end
end
