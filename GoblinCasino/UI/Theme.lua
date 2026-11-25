-- Shared palette, fonts and UI element factories ("neon goblin tavern" style).
local ADDON, ns = ...

local T = {}
ns.Theme = T

local MEDIA = "Interface\\AddOns\\" .. ADDON .. "\\Media\\"
T.FONT_DISPLAY = MEDIA .. "Fonts\\Bungee-Regular.ttf" -- caps only: headings, numbers, buttons
T.FONT_BODY = MEDIA .. "Fonts\\Rubik-Regular.ttf"
T.FONT_BOLD = MEDIA .. "Fonts\\Rubik-Bold.ttf"
T.CIRCLE_MASK = "Interface\\CHARACTERFRAME\\TempPortraitAlphaMask"

local function hex(h, a)
	h = h:gsub("#", "")
	return {
		tonumber(h:sub(1, 2), 16) / 255,
		tonumber(h:sub(3, 4), 16) / 255,
		tonumber(h:sub(5, 6), 16) / 255,
		a or 1,
	}
end
T.hex = hex

-- Blend of two colors: t = 0 gives a, t = 1 gives b.
function T.Mix(a, b, t)
	return {
		a[1] + (b[1] - a[1]) * t,
		a[2] + (b[2] - a[2]) * t,
		a[3] + (b[3] - a[3]) * t,
		1,
	}
end

T.C = {
	bgDeep = hex("120726"),
	bg = hex("1b0a36"),
	bgLight = hex("2a0f4a"),
	bgTop = hex("3b1470"),
	gold = hex("ffd84d"),
	goldDark = hex("ffc93c"),
	goldShadow = hex("b7791f"),
	goldHover = hex("ffe68a"),
	goldInk = hex("3d1d00"),
	pink = hex("ff3fa4"),
	pinkDark = hex("c2185b"),
	teal = hex("34e3c4"),
	cyan = hex("33e1ff"),
	green = hex("4dff9a"),
	orange = hex("ff9a3c"),
	violet = hex("6b3fb0"),
	lilac = hex("e879f9"),
	text = hex("f7ecff"),
	textDim = hex("cdb9ee"),
	bulbOn = hex("ffe7a0"),
}

function T.Unpack(c, alpha)
	return c[1], c[2], c[3], alpha or c[4]
end

function T.Solid(parent, color, layer, sublevel)
	local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel)
	t:SetColorTexture(T.Unpack(color))
	return t
end

-- orientation: "HORIZONTAL" (from = left, to = right) or "VERTICAL" (from = bottom, to = top)
function T.Gradient(parent, orientation, from, to, layer, sublevel)
	local t = parent:CreateTexture(nil, layer or "BACKGROUND", nil, sublevel)
	t:SetColorTexture(1, 1, 1, 1)
	t:SetGradient(orientation, CreateColor(T.Unpack(from)), CreateColor(T.Unpack(to)))
	return t
end

-- A border made of four textures; returns an object with :SetColor(color, alpha).
function T.Border(frame, color, size, layer)
	size = size or 1
	local edges = {}
	local function Edge()
		local t = frame:CreateTexture(nil, layer or "BORDER", nil, 7)
		t:SetColorTexture(T.Unpack(color))
		edges[#edges + 1] = t
		return t
	end
	local top = Edge()
	top:SetPoint("TOPLEFT")
	top:SetPoint("TOPRIGHT")
	top:SetHeight(size)
	local bottom = Edge()
	bottom:SetPoint("BOTTOMLEFT")
	bottom:SetPoint("BOTTOMRIGHT")
	bottom:SetHeight(size)
	local left = Edge()
	left:SetPoint("TOPLEFT", 0, -size)
	left:SetPoint("BOTTOMLEFT", 0, size)
	left:SetWidth(size)
	local right = Edge()
	right:SetPoint("TOPRIGHT", 0, -size)
	right:SetPoint("BOTTOMRIGHT", 0, size)
	right:SetWidth(size)
	function edges:SetColor(c, alpha)
		for i = 1, 4 do self[i]:SetColorTexture(T.Unpack(c, alpha)) end
	end
	return edges
end

-- Neon glow around a frame: a few additive layers, each a bit wider (idea from ForeverTCG).
-- It sits under the frame's own background (sublevels -8..), so it only shows outside the frame.
function T.Glow(frame, color, spread, strength, steps)
	steps, spread = steps or 6, spread or 10
	local g = { tex = {} }
	for i = 1, steps do
		local t = frame:CreateTexture(nil, "BACKGROUND", nil, -9 + i)
		local inset = spread * (1 - (i - 1) / steps)
		t:SetPoint("TOPLEFT", -inset, inset)
		t:SetPoint("BOTTOMRIGHT", inset, -inset)
		t:SetBlendMode("ADD")
		g.tex[i] = t
	end
	function g:SetColor(c, s)
		for _, t in ipairs(self.tex) do t:SetColorTexture(c[1], c[2], c[3], (s or 1) * 0.11) end
	end
	g:SetColor(color, strength)
	return g
end

function T.Text(parent, font, size, color, layer)
	local fs = parent:CreateFontString(nil, layer or "OVERLAY")
	fs:SetFont(font, size, "")
	fs:SetTextColor(T.Unpack(color or T.C.text))
	fs:SetJustifyH("LEFT")
	return fs
end

-- A round texture (circle mask). Color it with :SetColorTexture or fill it with :SetTexture.
function T.Circle(parent, size, layer, sublevel)
	local t = parent:CreateTexture(nil, layer or "ARTWORK", nil, sublevel)
	t:SetSize(size, size)
	local mask = parent:CreateMaskTexture()
	mask:SetTexture(T.CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	mask:SetAllPoints(t)
	t:AddMaskTexture(mask)
	return t
end

-- Gold call-to-action button with a darker "lip" underneath, as in the mockups.
function T.GoldButton(parent, label, width, height)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(width or 96, height or 36)
	local shadow = T.Solid(b, T.C.goldShadow, "BACKGROUND")
	shadow:SetPoint("TOPLEFT", 0, -3)
	shadow:SetPoint("BOTTOMRIGHT")
	local face = T.Solid(b, T.C.gold, "BORDER")
	local fs = T.Text(b, T.FONT_DISPLAY, 13, T.C.goldInk)
	fs:SetJustifyH("CENTER")
	fs:SetPoint("CENTER", face, "CENTER", 0, 0)
	fs:SetText(label)
	b.face, b.label, b.shadow = face, fs, shadow

	local function Place(pressed)
		face:ClearAllPoints()
		if pressed then
			face:SetPoint("TOPLEFT", 0, -2)
			face:SetPoint("BOTTOMRIGHT", 0, 1)
		else
			face:SetPoint("TOPLEFT")
			face:SetPoint("BOTTOMRIGHT", 0, 3)
		end
	end
	Place(false)

	b:SetScript("OnEnter", function(self)
		if self:IsEnabled() then face:SetColorTexture(T.Unpack(T.C.goldHover)) end
	end)
	b:SetScript("OnLeave", function(self)
		if self:IsEnabled() then face:SetColorTexture(T.Unpack(T.C.gold)) end
		Place(false)
	end)
	b:SetScript("OnMouseDown", function(self)
		if self:IsEnabled() then Place(true) end
	end)
	b:SetScript("OnMouseUp", function() Place(false) end)

	-- Greyed-out look when off ("coming later", "wait for your turn").
	function b:SetActive(on)
		self:SetEnabled(on)
		if on then
			face:SetColorTexture(T.Unpack(self:IsMouseOver() and T.C.goldHover or T.C.gold))
			shadow:SetColorTexture(T.Unpack(T.C.goldShadow))
			fs:SetTextColor(T.Unpack(T.C.goldInk))
		else
			face:SetColorTexture(1, 1, 1, 0.10)
			shadow:SetColorTexture(0, 0, 0, 0.25)
			fs:SetTextColor(1, 1, 1, 0.45)
		end
	end
	function b:SetUnavailable() self:SetActive(false) end
	function b:SetLabel(s) fs:SetText(s) end
	return b
end

-- Secondary button: dark face, violet edge, pink edge on hover.
function T.DarkButton(parent, label, width, height, size)
	local b = CreateFrame("Button", nil, parent)
	b:SetSize(width or 90, height or 30)
	T.Solid(b, T.C.bgDeep):SetAllPoints()
	local border = T.Border(b, T.C.violet, 1)
	local fs = T.Text(b, T.FONT_BOLD, size or 11, T.C.text)
	fs:SetJustifyH("CENTER")
	fs:SetPoint("CENTER")
	fs:SetText(label)
	b.label = fs
	b:SetScript("OnEnter", function(self) if self:IsEnabled() then border:SetColor(T.C.pink) end end)
	b:SetScript("OnLeave", function() border:SetColor(T.C.violet) end)
	function b:SetLabel(s) fs:SetText(s) end
	function b:SetActive(on)
		self:SetEnabled(on)
		fs:SetAlpha(on and 1 or 0.4)
	end
	return b
end

-- Status tag (e.g. "BETTING · 0:42"). The background hugs the text through anchors, so it is right
-- even when the font has not loaded yet and the text width is still unknown.
function T.Pill(parent, text, bg, fg)
	local f = CreateFrame("Frame", nil, parent)
	f:SetSize(1, 22)
	local fs = T.Text(f, T.FONT_BOLD, 10, fg)
	fs:SetPoint("LEFT", f, "LEFT", 10, 0)
	fs:SetText(text)
	local back = T.Solid(f, bg)
	back:SetPoint("TOPLEFT", fs, "TOPLEFT", -10, 6)
	back:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 10, -6)
	f.label, f.back = fs, back
	return f
end

local function Thousands(n)
	local s = tostring(n):reverse():gsub("(%d%d%d)", "%1,"):reverse()
	return (s:gsub("^,", ""))
end
T.Thousands = Thousands

-- 11882000 copper -> "1,188g 20s" with WoW's coin colors on the letters
function T.FormatMoney(copper)
	local gold = math.floor(copper / 10000)
	local silver = math.floor(copper / 100) % 100
	return Thousands(gold) .. "|cffffd700g|r  " .. silver .. "|cffc7c7cfs|r"
end
