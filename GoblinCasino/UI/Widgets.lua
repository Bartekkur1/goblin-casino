-- Widgets shared by the game screens: a scrolling list and a gold amount box.
local ADDON, ns = ...
local T = ns.Theme
local C, hex = T.C, T.hex

local Widgets = {}
ns.Widgets = Widgets

local DIM = hex("9d8fbf")

-- A list with a fixed number of rows; the mouse wheel scrolls it.
-- Items: { color, left, mid, right, mine, leftColor }
-- opts: midW, rightW (column widths, default 120 / 70); clickable = true makes rows react to the
-- mouse and call list.onClick(item).
function Widgets.List(parent, width, rows, rowH, opts)
	opts = opts or {}
	local midW, rightW = opts.midW or 120, opts.rightW or 70
	local list = CreateFrame("Frame", nil, parent)
	list:SetSize(width, rows * rowH)
	list.rows, list.data, list.offset = {}, {}, 0
	local function Scroll(_, delta)
		list.offset = math.max(0, list.offset - delta)
		list:Render()
	end
	for i = 1, rows do
		local row = CreateFrame("Frame", nil, list)
		row:SetSize(width, rowH)
		row:SetPoint("TOPLEFT", 0, -(i - 1) * rowH)
		row.bg = T.Solid(row, { 1, 1, 1, i % 2 == 0 and 0.03 or 0 })
		row.bg:SetAllPoints()
		row.mark = T.Solid(row, C.gold, "BORDER")
		row.mark:SetPoint("TOPLEFT")
		row.mark:SetPoint("BOTTOMLEFT")
		row.mark:SetWidth(2)
		row.swatch = T.Circle(row, 10, "ARTWORK")
		row.swatch:SetPoint("LEFT", 8, 0)
		row.left = T.Text(row, T.FONT_BOLD, 12, C.text)
		row.left:SetPoint("LEFT", 26, 0)
		row.left:SetWidth(width - 26 - midW - rightW - 16)
		row.left:SetWordWrap(false)
		row.mid = T.Text(row, T.FONT_BODY, 12, C.textDim)
		row.mid:SetJustifyH("RIGHT")
		row.mid:SetPoint("RIGHT", -(rightW + 8), 0)
		row.mid:SetWidth(midW)
		row.mid:SetWordWrap(false)
		row.right = T.Text(row, T.FONT_BOLD, 12, C.text)
		row.right:SetJustifyH("RIGHT")
		row.right:SetPoint("RIGHT", -8, 0)
		row.right:SetWidth(rightW)
		if opts.clickable then
			row.hl = T.Solid(row, { 1, 1, 1, 0.07 }, "BACKGROUND", 1)
			row.hl:SetAllPoints()
			row.hl:Hide()
			row:EnableMouse(true)
			row:EnableMouseWheel(true)
			row:SetScript("OnMouseWheel", Scroll)
			row:SetScript("OnEnter", function(self) self.hl:Show() end)
			row:SetScript("OnLeave", function(self) self.hl:Hide() end)
			row:SetScript("OnMouseUp", function(self)
				if list.onClick and self.item then list.onClick(self.item) end
			end)
		end
		list.rows[i] = row
	end
	list.more = T.Text(list, T.FONT_BODY, 10, DIM)
	list.more:SetJustifyH("RIGHT")
	list.more:SetPoint("TOPRIGHT", list, "BOTTOMRIGHT", -4, -2)

	function list:Render()
		local maxOffset = math.max(0, #self.data - rows)
		self.offset = math.min(self.offset, maxOffset)
		for i, row in ipairs(self.rows) do
			local item = self.data[i + self.offset]
			row.item = item
			if item then
				row.swatch:SetColorTexture(T.Unpack(item.color or DIM))
				row.left:SetText(item.left or "")
				row.mid:SetText(item.mid or "")
				row.right:SetText(item.right or "")
				row.left:SetTextColor(T.Unpack(item.leftColor or C.text))
				row.mark:SetShown(item.mine and true or false)
				row:Show()
			else
				row:Hide()
			end
		end
		local below = #self.data - rows - self.offset
		self.more:SetText(below > 0 and ("scroll for " .. below .. " more") or "")
	end

	function list:SetData(data)
		self.data = data
		self:Render()
	end

	list:EnableMouseWheel(true)
	list:SetScript("OnMouseWheel", Scroll)
	return list
end

-- Numeric box for an amount of gold.
function Widgets.AmountBox(parent, width, height, size)
	local box = CreateFrame("EditBox", nil, parent)
	box:SetSize(width or 96, height or 34)
	box:SetAutoFocus(false)
	box:SetNumeric(true)
	box:SetMaxLetters(6)
	box:SetFont(T.FONT_BOLD, size or 16, "")
	box:SetTextColor(T.Unpack(C.gold))
	box:SetJustifyH("CENTER")
	box:SetTextInsets(6, 6, 0, 0)
	T.Solid(box, C.bgDeep):SetAllPoints()
	local border = T.Border(box, C.violet, 1)
	box:SetScript("OnEditFocusGained", function() border:SetColor(C.gold) end)
	box:SetScript("OnEditFocusLost", function() border:SetColor(C.violet) end)
	box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
	return box
end

-- The group unit ("player", "party2", "raid7") of a player by their engine name, if any.
function Widgets.UnitFor(name)
	local U = ns.Util
	if not name then return nil end
	if name == U.Me() then return "player" end
	local raid = IsInRaid()
	for i = 1, GetNumGroupMembers() do
		local unit = raid and ("raid" .. i) or ("party" .. i)
		if UnitExists(unit) and U.Canonical(GetUnitName(unit, true)) == name then return unit end
	end
end

-- 3D avatar for a player: their own character when the client can show it (themselves, or a
-- group member close enough to be seen), otherwise the creature `skin` (a display ID).
-- Returns a key that changes when what is shown changes.
function Widgets.SetAvatar(model, name, skin)
	local unit = Widgets.UnitFor(name)
	if unit and UnitIsVisible(unit) then
		if pcall(model.SetUnit, model, unit) then return "unit:" .. name end
	end
	pcall(model.SetDisplayInfo, model, skin)
	return "skin:" .. tostring(skin)
end

-- "1st", "2nd", "3rd", "4th" ...
function Widgets.Ordinal(n)
	local tens = n % 100
	if tens >= 11 and tens <= 13 then return n .. "th" end
	local last = n % 10
	return n .. ((last == 1 and "st") or (last == 2 and "nd") or (last == 3 and "rd") or "th")
end
