-- The wheel widget: slices sized by stake, a pointer at the top, spin animation.
-- WoW has no pie shapes, so the disc is drawn from thin rotated "spokes" clipped by a circle mask;
-- each spoke takes the color of the player whose slice it lies in.
local ADDON, ns = ...
local T = ns.Theme
local C, hex = T.C, T.hex

local Wheel = {}
ns.Wheel = Wheel

local SPOKES = 180
local STEP = 360 / SPOKES

Wheel.COLORS = {
	hex("ff3fa4"), hex("ffd84d"), hex("33e1ff"), hex("4dff9a"), hex("ff9a3c"), hex("b07bff"),
	hex("34e3c4"), hex("ff5c5c"), hex("5c8dff"), hex("c6ff4d"), hex("ffb38a"), hex("e879f9"),
	-- 13-20 (the derby has up to 20 runners)
	hex("ffe9a8"), hex("8af0ff"), hex("ff8ad8"), hex("a8ff8a"), hex("d18cff"), hex("ffcf5c"),
	hex("5cffd8"), hex("ff9e9e"),
}

function Wheel.ColorFor(index)
	return Wheel.COLORS[(index - 1) % #Wheel.COLORS + 1]
end

-- Spokes per slice: proportional to the stake, at least one each, SPOKES in total.
local function Allocate(amounts, total)
	local counts, rest, used = {}, {}, 0
	for i, a in ipairs(amounts) do
		local exact = a / total * SPOKES
		counts[i] = math.max(1, math.floor(exact))
		rest[i] = exact - math.floor(exact)
		used = used + counts[i]
	end
	while used < SPOKES do
		local best = 1
		for i = 2, #counts do
			if rest[i] > rest[best] then best = i end
		end
		counts[best] = counts[best] + 1
		rest[best] = -1
		used = used + 1
	end
	while used > SPOKES do
		local big = 1
		for i = 2, #counts do
			if counts[i] > counts[big] then big = i end
		end
		counts[big] = counts[big] - 1
		used = used - 1
	end
	return counts
end

local function EaseOutQuart(t) return 1 - (1 - t) ^ 4 end

function Wheel.Create(parent, radius)
	local w = CreateFrame("Frame", nil, parent)
	local outer = radius * 2 + 28
	w:SetSize(outer, outer)
	w.radius = radius
	w.angle = 0          -- clockwise rotation of the wheel, degrees
	w.slices = {}

	-- rim
	local halo = T.Circle(w, outer, "BACKGROUND", 0)
	halo:SetPoint("CENTER")
	halo:SetColorTexture(T.Unpack(C.goldDark, 0.18))
	halo:SetBlendMode("ADD")
	local rim = T.Circle(w, radius * 2 + 18, "BACKGROUND", 1)
	rim:SetPoint("CENTER")
	rim:SetColorTexture(T.Unpack(C.gold))
	local rimInner = T.Circle(w, radius * 2 + 12, "BACKGROUND", 2)
	rimInner:SetPoint("CENTER")
	rimInner:SetColorTexture(T.Unpack(C.goldShadow))
	local seat = T.Circle(w, radius * 2 + 4, "BACKGROUND", 3)
	seat:SetPoint("CENTER")
	seat:SetColorTexture(T.Unpack(C.bgDeep))
	local empty = T.Circle(w, radius * 2, "BORDER")
	empty:SetPoint("CENTER")
	empty:SetColorTexture(T.Unpack(C.bgLight))

	-- spokes and slice separators, all clipped to the disc
	local mask = w:CreateMaskTexture()
	mask:SetTexture(T.CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
	mask:SetSize(radius * 2, radius * 2)
	mask:SetPoint("CENTER")
	local spokeWidth = 2 * math.pi * radius / SPOKES * 1.8
	w.spokes = {}
	for k = 1, SPOKES do
		local s = w:CreateTexture(nil, "ARTWORK", nil, 0)
		s:SetSize(spokeWidth, radius)
		s:AddMaskTexture(mask)
		s:Hide()
		w.spokes[k] = s
	end
	w.separators = {}
	local function Separator(i)
		local s = w.separators[i]
		if not s then
			s = w:CreateTexture(nil, "ARTWORK", nil, 3)
			s:SetSize(2, radius)
			s:SetColorTexture(T.Unpack(C.bgDeep, 0.85))
			s:AddMaskTexture(mask)
			w.separators[i] = s
		end
		return s
	end

	-- hub
	local hub = T.Circle(w, 40, "OVERLAY", 0)
	hub:SetPoint("CENTER")
	hub:SetColorTexture(T.Unpack(C.gold))
	local hubInner = T.Circle(w, 32, "OVERLAY", 1)
	hubInner:SetPoint("CENTER")
	hubInner:SetColorTexture(T.Unpack(C.bgDeep))
	local hubText = T.Text(w, T.FONT_DISPLAY, 14, C.gold, "OVERLAY")
	hubText:SetJustifyH("CENTER")
	hubText:SetDrawLayer("OVERLAY", 7)
	hubText:SetPoint("CENTER", 1, 0)
	hubText:SetText("G")

	-- rim bulbs
	w.bulbs = {}
	local BULBS = 24
	for i = 1, BULBS do
		local a = math.rad(90 - (i - 1) * 360 / BULBS)
		local b = T.Circle(w, 5, "OVERLAY", 2)
		b:SetPoint("CENTER", w, "CENTER", math.cos(a) * (radius + 6), math.sin(a) * (radius + 6))
		b:SetColorTexture(T.Unpack(C.bulbOn))
		b.parity = i % 2
		w.bulbs[i] = b
	end

	-- pointer (a gold diamond on the rim at 12 o'clock)
	local pointer = CreateFrame("Frame", nil, w)
	pointer:SetSize(30, 30)
	pointer:SetPoint("CENTER", w, "CENTER", 0, radius + 4)
	pointer:SetFrameLevel(w:GetFrameLevel() + 5)
	local p1 = pointer:CreateTexture(nil, "ARTWORK", nil, 0)
	p1:SetSize(22, 22)
	p1:SetPoint("CENTER")
	p1:SetColorTexture(T.Unpack(C.goldShadow))
	p1:SetRotation(math.rad(45))
	local p2 = pointer:CreateTexture(nil, "ARTWORK", nil, 1)
	p2:SetSize(17, 17)
	p2:SetPoint("CENTER")
	p2:SetColorTexture(T.Unpack(C.gold))
	p2:SetRotation(math.rad(45))
	local p3 = pointer:CreateTexture(nil, "ARTWORK", nil, 2)
	p3:SetSize(6, 6)
	p3:SetPoint("CENTER")
	p3:SetColorTexture(T.Unpack(C.bgDeep))
	p3:SetRotation(math.rad(45))

	local function Place(tex, deg, dist)
		local a = math.rad(deg)
		tex:SetPoint("CENTER", w, "CENTER", math.cos(a) * dist, math.sin(a) * dist)
		tex:SetRotation(a - math.pi / 2)
	end

	-- Draw at the current angle.
	function w:Render()
		local theta = self.angle
		for k = 1, SPOKES do
			local s = self.spokes[k]
			if s:IsShown() then Place(s, 90 - (k - 0.5) * STEP - theta, radius / 2) end
		end
		for i, slice in ipairs(self.slices) do
			local sep = self.separators[i]
			if sep and sep:IsShown() then Place(sep, 90 - slice.startK * STEP - theta, radius / 2) end
		end
	end

	-- slices: list of { name, amount } in wheel order; colors follow the order.
	function w:SetSlices(list)
		self.spin = nil -- a spin left over from a round shown while the window was closed
		self.slices = {}
		local total = 0
		for _, item in ipairs(list) do total = total + item.amount end
		for _, s in ipairs(self.spokes) do s:Hide() end
		for _, s in ipairs(self.separators) do s:Hide() end
		self.byName = {}
		if total <= 0 then return end
		local amounts = {}
		for i, item in ipairs(list) do amounts[i] = item.amount end
		local counts = Allocate(amounts, total)
		local k, gold = 0, 0
		for i, item in ipairs(list) do
			local slice = {
				name = item.name, amount = item.amount, color = Wheel.ColorFor(i),
				startK = k, count = counts[i], goldStart = gold,
			}
			self.slices[i] = slice
			self.byName[item.name] = slice
			for j = k + 1, k + counts[i] do
				local s = self.spokes[j]
				s:SetColorTexture(T.Unpack(slice.color))
				s:SetAlpha(1)
				s:Show()
			end
			if #list > 1 then Separator(i):Show() end
			k, gold = k + counts[i], gold + item.amount
		end
		self:Render()
	end

	-- Name of the slice under the pointer.
	function w:UnderPointer()
		local phi = (360 - self.angle % 360) % 360
		local k = math.floor(phi / STEP)
		for _, slice in ipairs(self.slices) do
			if k >= slice.startK and k < slice.startK + slice.count then return slice.name end
		end
	end

	-- Dim every slice except the winner's (nil = all bright).
	function w:Highlight(name)
		for _, slice in ipairs(self.slices) do
			local a = (not name or slice.name == name) and 1 or 0.28
			for j = slice.startK + 1, slice.startK + slice.count do self.spokes[j]:SetAlpha(a) end
		end
	end

	-- Spin so that the pointer stops on gold position `r` of the winner's slice.
	-- startTime lets a window opened in the middle of a spin join at the right moment.
	function w:Spin(winner, r, turns, startTime, duration, onDone)
		local slice = self.byName[winner]
		if not slice then return end
		local frac = (r - slice.goldStart + 0.5) / slice.amount
		local phi = (slice.startK + frac * slice.count) * STEP -- clockwise from the top, on the wheel
		local from = self.angle
		local target = (360 - phi) % 360
		local delta = (target - from % 360) % 360
		self.spin = {
			from = from, to = from + 360 * turns + delta,
			start = startTime or GetTime(), duration = duration, onDone = onDone,
		}
		self.idle = false
		self:Highlight(nil)
	end

	function w:SetIdle(on)
		self.idle = on
	end

	local bulbClock, bulbPhase, lastSlice, lastTick = 0, 0, nil, 0
	w:SetScript("OnUpdate", function(self, dt)
		local now = GetTime()
		local spin = self.spin
		if spin then
			local t = (now - spin.start) / spin.duration
			if t >= 1 then
				self.angle = spin.to
				self.spin = nil
				self:Render()
				if spin.onDone then spin.onDone() end
			else
				self.angle = spin.from + (spin.to - spin.from) * EaseOutQuart(math.max(t, 0))
				self:Render()
			end
			-- a click each time a new slice passes the pointer
			local under = self:UnderPointer()
			if under ~= lastSlice then
				lastSlice = under
				if self.onPointer then self.onPointer(under) end
				if now - lastTick > 0.045 and SOUNDKIT and SOUNDKIT.U_CHAT_SCROLL_BUTTON then
					PlaySound(SOUNDKIT.U_CHAT_SCROLL_BUTTON)
					lastTick = now
				end
			end
		elseif self.idle and #self.slices > 0 then
			self.angle = self.angle + dt * 8
			self:Render()
		end
		-- bulbs blink, faster while spinning
		bulbClock = bulbClock + dt
		if bulbClock >= (spin and 0.12 or 0.5) then
			bulbClock = 0
			bulbPhase = 1 - bulbPhase
			for _, b in ipairs(self.bulbs) do b:SetAlpha(b.parity == bulbPhase and 1 or 0.3) end
		end
	end)

	return w
end
