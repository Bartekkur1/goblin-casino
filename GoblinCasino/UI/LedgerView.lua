-- TAB screen: everyone I have a tab with on the left (who owes whom), the chosen person's entries on
-- the right, and the ways to settle up: open a trade, confirm a payment, forgive, add a missing debt.
local ADDON, ns = ...
local T, U, J, W, L = ns.Theme, ns.Util, ns.Jackpot, ns.Widgets, ns.Ledger
local C, hex = T.C, T.hex

local View = {}
ns.LedgerView = View

local RED, DIM, ORANGE = hex("ff6b6b"), hex("9d8fbf"), hex("ff9a3c")
local LEFT_W = 330
local KIND_TEXT = {
	trade = "Trade", received = "Received", forgive = "Forgiven", adjust = "Added by you", carry = "Earlier",
}
local KIND_COLOR = { round = C.gold, trade = C.teal, received = C.green, forgive = C.cyan, adjust = ORANGE, carry = DIM }

-- One yes/no question before a change to the tab; data is the function that makes the change.
StaticPopupDialogs["GOBLINCASINO_LEDGER_CONFIRM"] = {
	text = "%s",
	button1 = YES,
	button2 = NO,
	OnAccept = function(_, data)
		if type(data) == "function" then data() end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

-- Copper as "1,234g 20s 3c" without color codes (so a row can color the whole text).
local function Plain(copper)
	copper = math.abs(copper or 0)
	local gold = math.floor(copper / L.COPPER)
	local rest = copper - gold * L.COPPER
	local silver = math.floor(rest / 100)
	local cop = rest - silver * 100
	local text = U.Thousands(gold) .. "g"
	if silver > 0 then text = text .. " " .. silver .. "s" end
	if cop > 0 then text = text .. " " .. cop .. "c" end
	return text
end

-- + = they owe me more (green), - = I owe more (red).
local function Signed(copper)
	if copper > 0 then return "|cff4dff9a+" .. Plain(copper) .. "|r" end
	if copper < 0 then return "|cffff6b6b-" .. Plain(copper) .. "|r" end
	return "|cff9d8fbf0g|r"
end

-- A balance as words, from my point of view.
local function Phrase(who, copper)
	if copper < 0 then return "you owe " .. Plain(copper) end
	if copper > 0 then return U.Short(who) .. " owes you " .. Plain(copper) end
	return "you're even"
end

local function When(t)
	if date("%Y%m%d", t) == date("%Y%m%d") then return date("%H:%M", t) end
	return date("%d.%m %H:%M", t)
end

local function KindText(e)
	if e.kind == "round" then
		local game = J.games[e.game or "wheel"]
		return game and game.title or "Round"
	end
	return KIND_TEXT[e.kind] or tostring(e.kind)
end

-- What I owe everyone and what everyone owes me, in copper (both >= 0).
function View.Totals()
	local owe, owed = 0, 0
	for _, who in ipairs(L.People()) do
		local bal = L.Balance(who)
		if bal < 0 then owe = owe - bal elseif bal > 0 then owed = owed + bal end
	end
	return owe, owed
end

-- The FORGIVE amount: what they owe me on my tab, or else what their addon says they owe.
local function ForgiveDefault(who)
	local bal = L.Balance(who)
	if bal > 0 then return bal end
	return math.max(0, L.reported[who] or 0)
end

-- ADD DEBT shows only when their addon says I owe more than mine does; the default is the difference.
local function MissingDebt(who)
	local m = L.mismatch[who]
	if m and m.theirs < m.mine then return m.mine - m.theirs end
	return nil
end

local function Report(ok, err)
	if not ok and err then ns.Print(err) end
end

local function Confirm(question, fn)
	StaticPopup_Show("GOBLINCASINO_LEDGER_CONFIRM", question, nil, fn)
end

function View.Create(parent, width, height)
	local v = CreateFrame("Frame", nil, parent)
	v:SetSize(width, height)
	v:Hide()
	View.frame = v

	-- top bar
	local back = T.DarkButton(v, "LOBBY", 76, 28)
	back:SetPoint("TOPLEFT")
	back:SetScript("OnClick", function() ns.Main:ShowView("lobby") end)
	local title = T.Text(v, T.FONT_DISPLAY, 18, C.gold)
	title:SetPoint("LEFT", back, "RIGHT", 14, 0)
	title:SetText("TAB")
	local summary = T.Text(v, T.FONT_BOLD, 12, C.text)
	summary:SetPoint("LEFT", title, "RIGHT", 14, -1)

	local function Panel(x, w)
		local p = CreateFrame("Frame", nil, v)
		p:SetPoint("TOPLEFT", x, -40)
		p:SetSize(w, height - 40)
		T.Solid(p, hex("0d0520", 0.9)):SetAllPoints()
		T.Border(p, hex("4a2a80"), 1)
		p.head = T.Text(p, T.FONT_BOLD, 10, C.textDim)
		p.head:SetPoint("TOPLEFT", 14, -12)
		p.meta = T.Text(p, T.FONT_BOLD, 10, DIM)
		p.meta:SetJustifyH("RIGHT")
		p.meta:SetPoint("TOPRIGHT", -14, -12)
		return p
	end

	-- left: people
	local left = Panel(0, LEFT_W)
	left.head:SetText("PEOPLE  ·  click one for details")
	local people = W.List(left, LEFT_W - 28, 13, 26, { midW = 64, rightW = 96, clickable = true })
	people:SetPoint("TOPLEFT", 14, -30)
	local empty = T.Text(left, T.FONT_BODY, 12, C.textDim)
	empty:SetJustifyH("CENTER")
	empty:SetPoint("CENTER")
	empty:SetWidth(LEFT_W - 60)
	empty:SetText("Nobody on your tab yet. Every real round you play adds who owes whom here, until it's paid.")
	local legend = T.Text(left, T.FONT_BODY, 10, DIM)
	legend:SetPoint("BOTTOMLEFT", 14, 10)
	legend:SetText("(!) = their addon says a different amount.")

	-- right: the chosen person's entries and the settle-up controls
	local rightX = LEFT_W + 16
	local rightW = width - rightX
	local right = Panel(rightX, rightW)
	local entries = W.List(right, rightW - 28, 8, 26, { midW = 80, rightW = 96 })
	entries:SetPoint("TOPLEFT", 14, -30)
	local noEntries = T.Text(right, T.FONT_BODY, 12, C.textDim)
	noEntries:SetJustifyH("CENTER")
	noEntries:SetPoint("CENTER")
	noEntries:SetWidth(rightW - 60)
	noEntries:SetText("Pick someone on the left.")

	local mismatch = T.Text(right, T.FONT_BODY, 11, ORANGE)
	mismatch:SetPoint("BOTTOMLEFT", 14, 90)
	mismatch:SetWidth(rightW - 28)
	mismatch:SetWordWrap(true)

	local box = W.AmountBox(right, 84, 28, 14)
	box:SetPoint("BOTTOMLEFT", 14, 52)
	local hint = T.Text(right, T.FONT_BODY, 11, DIM)
	hint:SetPoint("LEFT", box, "RIGHT", 10, 0)
	hint:SetWidth(rightW - 28 - 84 - 10)
	hint:SetWordWrap(false)

	local tradeBtn = T.GoldButton(right, "TRADE", 80, 32)
	local receivedBtn = T.DarkButton(right, "RECEIVED", 92, 30)
	local forgiveBtn = T.DarkButton(right, "FORGIVE", 84, 30)
	local addBtn = T.DarkButton(right, "ADD DEBT", 92, 30)
	local buttons = { tradeBtn, receivedBtn, forgiveBtn, addBtn }

	local selected   -- canonical name of the person shown on the right
	local shownKey   -- what the amount box was filled for; a new key refills it
	local whole = 0  -- the whole amount the box was filled with, in copper
	local edited = false -- the player typed in the box: the buttons use the typed gold

	local function UpdateHint()
		if not edited and whole > 0 then
			hint:SetText(whole % L.COPPER == 0 and "gold  ·  the whole amount" or ("gold  ·  exactly " .. Plain(whole)))
		else
			hint:SetText("gold")
		end
	end
	box:SetScript("OnTextChanged", function(_, userInput)
		if userInput then edited = true end
		UpdateHint()
	end)
	box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)

	-- The amount for a button: the typed gold, or the button's own default while the box is untouched.
	local function Amount(default)
		if not edited then return default end
		local gold = tonumber(box:GetText())
		return gold and gold * L.COPPER or nil
	end

	-- Shows the buttons that apply, side by side.
	local function LayoutButtons()
		local x = 14
		for _, b in ipairs(buttons) do
			if b:IsShown() then
				b:ClearAllPoints()
				b:SetPoint("BOTTOMLEFT", x, 12)
				x = x + b:GetWidth() + 8
			end
		end
	end

	people.onClick = function(item)
		selected = item.who
		v:Refresh()
	end

	tradeBtn:SetScript("OnClick", function()
		local who = selected
		if not who then return end
		-- a group member, or the player I have targeted (settling up often happens after the group is gone)
		local unit = W.UnitFor(who)
		if (not unit or unit == "player") and UnitIsPlayer("target") and U.Canonical(UnitName("target")) == who then
			unit = "target"
		end
		if not unit or unit == "player" or not UnitIsVisible(unit) then
			ns.Print("Target " .. U.Short(who) .. " or group up, and stand next to them to trade.")
			return
		end
		-- when I owe them, the trade watcher fills in the gold once the window opens
		local bal = L.Balance(who)
		local copper = bal < 0 and Amount(-bal) or nil
		if copper and copper >= 1 then
			ns.Trade.payWho, ns.Trade.payCopper = who, copper
		else
			ns.Trade.payWho, ns.Trade.payCopper = nil, nil
		end
		if not pcall(InitiateTrade, unit) then
			ns.Trade.payWho, ns.Trade.payCopper = nil, nil
			ns.Print("Couldn't open a trade with " .. U.Short(who) .. ".")
		end
	end)

	receivedBtn:SetScript("OnClick", function()
		local who = selected
		if not who then return end
		local copper = Amount(math.max(0, L.Balance(who)))
		if not copper or copper < 1 then return ns.Print("Enter an amount.") end
		Confirm("Confirm that " .. U.Short(who) .. " paid you " .. L.FormatCopper(copper) .. "?\nTheir addon is told too.",
			function() Report(L.Received(who, copper)) end)
	end)

	forgiveBtn:SetScript("OnClick", function()
		local who = selected
		if not who then return end
		local copper = Amount(ForgiveDefault(who))
		if not copper or copper < 1 then return ns.Print("Enter an amount.") end
		Confirm("Forgive " .. U.Short(who) .. " " .. L.FormatCopper(copper) .. "?\nTheir addon is told too.",
			function() Report(L.Forgive(who, copper)) end)
	end)

	addBtn:SetScript("OnClick", function()
		local who = selected
		if not who then return end
		local copper = Amount(MissingDebt(who) or 0)
		if not copper or copper < 1 then return ns.Print("Enter an amount.") end
		Confirm("Add " .. L.FormatCopper(copper) .. " to what you owe " .. U.Short(who) .. "?",
			function() Report(L.AddDebt(who, copper)) end)
	end)

	function v:Refresh()
		-- everyone with a tab, then anyone whose addon reported a tab mine doesn't have (to ADD DEBT)
		local names, listed = L.People(), {}
		for _, who in ipairs(names) do listed[who] = true end
		local extra = {}
		for who in pairs(L.mismatch) do
			if not listed[who] then extra[#extra + 1] = who end
		end
		table.sort(extra, U.ByteLess)
		for _, who in ipairs(extra) do names[#names + 1] = who end
		local found = false
		for _, who in ipairs(names) do
			if who == selected then found = true end
		end
		if not found then selected = names[1] end

		-- left: one row per person
		local rows, owe, owed = {}, 0, 0
		for _, who in ipairs(names) do
			local bal = L.Balance(who)
			if bal < 0 then owe = owe - bal elseif bal > 0 then owed = owed + bal end
			local color = bal < 0 and RED or (bal > 0 and C.green or DIM)
			rows[#rows + 1] = {
				color = color,
				left = U.Short(who) .. (L.mismatch[who] and " |cffff9a3c(!)|r" or ""),
				leftColor = who == selected and C.gold or C.text,
				mid = bal < 0 and "you owe" or (bal > 0 and "owes you" or "even"),
				right = bal == 0 and "|cff9d8fbf0g|r"
					or ((bal < 0 and "|cffff6b6b" or "|cff4dff9a") .. Plain(bal) .. "|r"),
				mine = who == selected,
				who = who,
			}
		end
		people:SetData(rows)
		empty:SetShown(#rows == 0)
		left.meta:SetText(#rows .. (#rows == 1 and " person" or " people"))
		local parts = {}
		if owe > 0 then parts[#parts + 1] = "You owe |cffff6b6b" .. Plain(owe) .. "|r" end
		if owed > 0 then parts[#parts + 1] = "owed |cff4dff9a" .. Plain(owed) .. "|r" end
		summary:SetText(table.concat(parts, "  ·  "))

		-- right: the chosen person
		local who = selected
		local controls = who ~= nil
		box:SetShown(controls)
		hint:SetShown(controls)
		noEntries:SetShown(not controls and #rows > 0)
		if not who then
			right.head:SetText("ENTRIES")
			right.meta:SetText("")
			entries:SetData({})
			mismatch:SetText("")
			for _, b in ipairs(buttons) do b:Hide() end
			shownKey = nil
			return
		end

		local bal = L.Balance(who)
		right.head:SetText("TAB WITH  " .. U.Short(who))
		right.meta:SetText(bal == 0 and "you're even"
			or ((bal < 0 and "|cffff6b6b" or "|cff4dff9a") .. Phrase(who, bal) .. "|r"))

		local list, data = L.Entries(who), {}
		for i = #list, 1, -1 do
			local e = list[i]
			data[#data + 1] = {
				color = KIND_COLOR[e.kind] or DIM,
				left = KindText(e),
				mid = e.t and When(e.t) or "",
				right = Signed(e.amount or 0),
			}
		end
		entries:SetData(data)

		local m = L.mismatch[who]
		local missing = MissingDebt(who)
		if m then
			local text = U.Short(who) .. "'s addon says " .. Phrase(who, m.theirs) .. ", yours says " .. Phrase(who, m.mine) .. "."
			if missing then
				text = text .. " ADD DEBT adds the missing " .. Plain(missing) .. " (or the gold you type)."
			else
				text = text .. " Check the rounds on this tab."
			end
			mismatch:SetText(text)
		else
			mismatch:SetText("")
		end

		tradeBtn:Show()
		receivedBtn:SetShown(bal > 0)
		forgiveBtn:SetShown(bal > 0 or (L.reported[who] or 0) > 0)
		addBtn:SetShown(missing ~= nil)
		LayoutButtons()

		-- the amount box: the whole debt (or what FORGIVE / ADD DEBT would take), refilled when it changes
		local default
		if bal ~= 0 then
			default = math.abs(bal)
		else
			default = ForgiveDefault(who)
			if default == 0 then default = missing or 0 end
		end
		local key = who .. ":" .. bal .. ":" .. tostring(L.reported[who]) .. ":" .. tostring(missing)
		if key ~= shownKey then
			shownKey = key
			whole = default
			edited = false
			box:SetText(default > 0 and tostring(math.floor(default / L.COPPER)) or "")
			box:ClearFocus()
		end
		UpdateHint()
	end

	v:SetScript("OnShow", function(self) self:Refresh() end)
	L.OnChange(function()
		if v:IsVisible() then v:Refresh() end
	end)
	return v
end
