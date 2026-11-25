-- Debug log window (bug button in the header, or /casino log): the whole log in a text box,
-- already selected, so Ctrl+C copies it. WoW doesn't let addons write to the clipboard, so the
-- copy itself has to be Ctrl+C.
local ADDON, ns = ...
local T = ns.Theme
local C, hex = T.C, T.hex

local LogWindow = {}
ns.LogWindow = LogWindow

local SHOWN_LINES = 800 -- the newest lines (everything is in SavedVariables anyway)
local frame

local function Create()
	local f = CreateFrame("Frame", "GoblinCasinoLogWindow", UIParent)
	f:SetSize(760, 480)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetToplevel(true)
	f:SetClampedToScreen(true)
	f:EnableMouse(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:Hide()
	tinsert(UISpecialFrames, "GoblinCasinoLogWindow") -- Esc closes it
	T.Solid(f, hex("140a2b", 0.98)):SetAllPoints()
	T.Border(f, C.violet, 1)

	local title = T.Text(f, T.FONT_DISPLAY, 16, C.gold)
	title:SetPoint("TOPLEFT", 16, -14)
	title:SetText("DEBUG LOG")
	local count = T.Text(f, T.FONT_BODY, 11, C.textDim)
	count:SetPoint("LEFT", title, "RIGHT", 12, -1)

	local close = T.DarkButton(f, "CLOSE", 70, 26)
	close:SetPoint("TOPRIGHT", -12, -10)
	close:SetScript("OnClick", function() f:Hide() end)
	local clear = T.DarkButton(f, "CLEAR", 70, 26)
	clear:SetPoint("RIGHT", close, "LEFT", -8, 0)

	-- text area
	local back = CreateFrame("Frame", nil, f)
	back:SetPoint("TOPLEFT", 14, -46)
	back:SetPoint("BOTTOMRIGHT", -14, 56)
	T.Solid(back, hex("0a0418", 1)):SetAllPoints()
	T.Border(back, hex("4a2a80"), 1)

	local scroll = CreateFrame("ScrollFrame", nil, back)
	scroll:SetPoint("TOPLEFT", 8, -8)
	scroll:SetPoint("BOTTOMRIGHT", -8, 8)
	local box = CreateFrame("EditBox", nil, scroll)
	box:SetMultiLine(true)
	box:SetAutoFocus(false)
	box:SetMaxLetters(0)
	box:SetFont(T.FONT_BODY, 11, "")
	box:SetTextColor(T.Unpack(C.text))
	box:SetWidth(760 - 28 - 16)
	scroll:SetScrollChild(box)

	scroll:EnableMouseWheel(true)
	scroll:SetScript("OnMouseWheel", function(self, delta)
		local range = self:GetVerticalScrollRange()
		self:SetVerticalScroll(math.max(0, math.min(range, self:GetVerticalScroll() - delta * 60)))
	end)
	-- keep the cursor in view while moving through the text with the keyboard
	box:SetScript("OnCursorChanged", function(_, _, y, _, h)
		local top = scroll:GetVerticalScroll()
		local height = scroll:GetHeight()
		y = -y
		if y < top then
			scroll:SetVerticalScroll(y)
		elseif y + h > top + height then
			scroll:SetVerticalScroll(math.min(scroll:GetVerticalScrollRange(), y + h - height))
		end
	end)

	local current = ""
	local function SelectAll()
		box:SetFocus()
		box:HighlightText()
	end
	-- read-only: typing puts the log back
	box:SetScript("OnTextChanged", function(self, userInput)
		if userInput then
			self:SetText(current)
			self:HighlightText()
		end
	end)
	box:SetScript("OnEscapePressed", function() f:Hide() end)
	back:EnableMouse(true)
	back:SetScript("OnMouseDown", SelectAll)

	-- bottom bar
	local selectBtn = T.GoldButton(f, "SELECT ALL", 140, 34)
	selectBtn:SetPoint("BOTTOMLEFT", 14, 12)
	selectBtn:SetScript("OnClick", SelectAll)
	local hint = T.Text(f, T.FONT_BODY, 12, C.text)
	hint:SetPoint("LEFT", selectBtn, "RIGHT", 14, 2)
	hint:SetText("Selected: press |cffffd84dCtrl+C|r to copy, then paste it to Claude.")

	function f:Load()
		-- the state right now first, then the log
		local ok, context = pcall(ns.Log.Context)
		local text = "== STATE NOW ==\n" .. (ok and context or ("(state unavailable: " .. tostring(context) .. ")"))
			.. "\n\n== LOG ==\n" .. ns.Log.Text(SHOWN_LINES)
		current = text
		box:SetText(text)
		count:SetText(ns.Log.Count() .. " lines" .. (ns.Log.Count() > SHOWN_LINES and ("  ·  newest " .. SHOWN_LINES .. " shown") or ""))
		box:SetCursorPosition(#text)
		SelectAll()
		C_Timer.After(0, function() scroll:SetVerticalScroll(scroll:GetVerticalScrollRange()) end)
	end

	clear:SetScript("OnClick", function()
		ns.Log.Clear()
		f:Load()
	end)
	f:SetScript("OnShow", function(self) self:Load() end)
	f:SetScript("OnHide", function() box:ClearFocus() end)
	return f
end

function LogWindow:Toggle()
	frame = frame or Create()
	frame:SetShown(not frame:IsShown())
end
