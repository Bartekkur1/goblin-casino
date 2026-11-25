-- History screen: past rounds on the left, standings (who is up or down overall) on the right.
-- Clicking a round shows who paid whom in it.
local ADDON, ns = ...
local T, U, J, W = ns.Theme, ns.Util, ns.Jackpot, ns.Widgets
local C, hex = T.C, T.hex

local View = {}
ns.HistoryView = View

local RED, DIM = hex("ff6b6b"), hex("9d8fbf")
local LEFT_W = 452
local GAME_COLOR = { wheel = C.lilac, derby = C.teal, sapper = C.orange or hex("ff9a3c"), onyxia = hex("ff5c5c") }

StaticPopupDialogs["GOBLINCASINO_CLEAR_HISTORY"] = {
	text = "Clear the whole Goblin Casino history? This can't be undone.",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		wipe(ns.db.history)
		if View.frame and View.frame:IsShown() then View.frame:Refresh() end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

local function Signed(n)
	if n > 0 then return "|cff4dff9a+" .. U.Thousands(n) .. "g|r" end
	if n < 0 then return "|cffff6b6b-" .. U.Thousands(-n) .. "g|r" end
	return "|cff9d8fbf0g|r"
end

-- What a player won (+) or lost (-) in one round.
local function NetFor(entry, name)
	local n = 0
	for _, t in ipairs(entry.transfers or {}) do
		if t.to == name then n = n + t.amount elseif t.from == name then n = n - t.amount end
	end
	return n
end

local function Played(entry, name)
	if entry.winner == name or entry.loser == name then return true end
	for _, t in ipairs(entry.transfers or {}) do
		if t.from == name or t.to == name then return true end
	end
	return false
end

local function Gain(entry)
	local n = 0
	for _, t in ipairs(entry.transfers or {}) do n = n + t.amount end
	return n
end

local function When(t)
	if date("%Y%m%d", t) == date("%Y%m%d") then return date("%H:%M", t) end
	return date("%d.%m %H:%M", t)
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
	title:SetText("HISTORY")
	local summary = T.Text(v, T.FONT_BOLD, 12, C.text)
	summary:SetPoint("LEFT", title, "RIGHT", 14, -1)
	local clearBtn = T.DarkButton(v, "CLEAR", 70, 28)
	clearBtn:SetPoint("TOPRIGHT")
	clearBtn:SetScript("OnClick", function() StaticPopup_Show("GOBLINCASINO_CLEAR_HISTORY") end)
	local practiceBtn = T.DarkButton(v, "", 150, 28)
	practiceBtn:SetPoint("RIGHT", clearBtn, "LEFT", -8, 0)
	practiceBtn:SetScript("OnClick", function()
		ns.db.historyHidePractice = not ns.db.historyHidePractice
		v:Refresh()
	end)

	local function Panel(x, w)
		local p = CreateFrame("Frame", nil, v)
		p:SetPoint("TOPLEFT", x, -40)
		p:SetSize(w, height - 40)
		T.Solid(p, hex("0d0520", 0.9)):SetAllPoints()
		T.Border(p, hex("4a2a80"), 1)
		p.head = T.Text(p, T.FONT_BOLD, 10, C.textDim)
		p.head:SetPoint("TOPLEFT", 14, -12)
		p.meta = T.Text(p, T.FONT_BODY, 10, DIM)
		p.meta:SetJustifyH("RIGHT")
		p.meta:SetPoint("TOPRIGHT", -14, -12)
		return p
	end

	-- left: rounds
	local left = Panel(0, LEFT_W)
	left.head:SetText("ROUNDS  ·  click one for details")
	local rounds = W.List(left, LEFT_W - 28, 13, 26, { midW = 150, rightW = 64, clickable = true })
	rounds:SetPoint("TOPLEFT", 14, -30)
	local empty = T.Text(left, T.FONT_BODY, 12, C.textDim)
	empty:SetJustifyH("CENTER")
	empty:SetPoint("CENTER")
	empty:SetWidth(LEFT_W - 60)
	empty:SetText("No rounds yet. Play a round of Ogre's Wheel or Murloc Derby and it shows up here.")
	local legend = T.Text(left, T.FONT_BODY, 10, DIM)
	legend:SetPoint("BOTTOMLEFT", 14, 10)
	legend:SetText("Greyed out = practice round with bots.")

	-- right: standings or one round's payments
	local rightX = LEFT_W + 16
	local right = Panel(rightX, width - rightX)
	local side = W.List(right, width - rightX - 28, 11, 26, { midW = 70, rightW = 64 })
	side:SetPoint("TOPLEFT", 14, -30)
	local sideNote = T.Text(right, T.FONT_BODY, 10, DIM)
	sideNote:SetPoint("BOTTOMLEFT", 14, 10)
	sideNote:SetWidth(width - rightX - 28)
	local backToStandings = T.DarkButton(right, "STANDINGS", 90, 22, 10)
	backToStandings:SetPoint("TOPRIGHT", -8, -6)

	local selected -- the round shown on the right (nil = standings)
	rounds.onClick = function(item)
		selected = (selected ~= item.entry) and item.entry or nil
		v:Refresh()
	end
	backToStandings:SetScript("OnClick", function()
		selected = nil
		v:Refresh()
	end)

	function v:Refresh()
		local all = ns.db.history or {}
		local hidePractice = ns.db.historyHidePractice
		practiceBtn:SetLabel(hidePractice and "PRACTICE: HIDDEN" or "PRACTICE: SHOWN")
		local me = U.Me()

		-- rounds, newest first
		local entries = {}
		for i = #all, 1, -1 do
			local e = all[i]
			if not (hidePractice and e.practice) then entries[#entries + 1] = e end
		end
		local data, myTotal, myRounds = {}, 0, 0
		local standings, playedCount = {}, {}
		local selectedShown = false
		for _, e in ipairs(entries) do
			if e == selected then selectedShown = true end
			local who = e.me or me
			local mine = Played(e, who)
			local net = NetFor(e, who)
			-- practice rounds move no gold: they never count toward the totals
			if mine and not e.practice then
				myTotal, myRounds = myTotal + net, myRounds + 1
			end
			local game = J.games[e.game or "wheel"]
			local headline
			if e.loser then
				headline = U.Short(e.loser) .. " -" .. U.Thousands(Gain(e)) .. "g"
			else
				headline = U.Short(e.winner) .. (e.note and (" (" .. e.note .. ")") or "") .. " +" .. U.Thousands(Gain(e)) .. "g"
			end
			data[#data + 1] = {
				color = e.practice and DIM or (GAME_COLOR[e.game] or C.gold),
				left = When(e.time) .. "  " .. (game and game.title or "?"),
				leftColor = e.practice and DIM or C.text,
				mid = headline,
				right = mine and Signed(net) or "|cff9d8fbf-|r",
				mine = e == selected,
				entry = e,
			}
			-- standings: everyone's total over the shown rounds
			local seen = {}
			local function Add(name)
				if seen[name] then return end
				seen[name] = true
				standings[name] = (standings[name] or 0) + NetFor(e, name)
				playedCount[name] = (playedCount[name] or 0) + 1
			end
			if not e.practice then
				if e.winner then Add(e.winner) end
				if e.loser then Add(e.loser) end
				for _, t in ipairs(e.transfers or {}) do Add(t.from); Add(t.to) end
			end
		end
		if not selectedShown then selected = nil end -- cleared, or hidden by the practice filter
		rounds:SetData(data)
		empty:SetShown(#data == 0)
		left.meta:SetText(#data .. (#data == 1 and " round" or " rounds"))
		summary:SetText(myRounds > 0 and ("You: " .. Signed(myTotal) .. " in " .. myRounds
			.. (myRounds == 1 and " round" or " rounds")) or "")

		if selected then
			-- one round: who paid whom
			local game = J.games[selected.game or "wheel"]
			right.head:SetText("ROUND  ·  " .. When(selected.time))
			right.meta:SetText("")
			backToStandings:Show()
			local rows = {}
			local who = selected.me or me -- the character that played it (maybe not this one)
			for _, t in ipairs(selected.transfers or {}) do
				rows[#rows + 1] = {
					color = GAME_COLOR[selected.game] or C.gold,
					left = U.Short(t.from), mid = "pays " .. U.Short(t.to), right = U.Gold(t.amount),
					mine = t.from == who or t.to == who,
					leftColor = t.from == who and C.gold or C.text,
				}
			end
			side:SetData(rows)
			sideNote:SetText((game and game.title or "?") .. "  ·  host " .. U.Short(selected.host)
				.. "  ·  pot " .. U.Gold(selected.pool or 0)
				.. (selected.practice and "  ·  |cffffb347practice|r" or ""))
		else
			right.head:SetText("STANDINGS")
			right.meta:SetText("")
			backToStandings:Hide()
			local names = {}
			for name in pairs(standings) do names[#names + 1] = name end
			table.sort(names, function(a, b)
				if standings[a] ~= standings[b] then return standings[a] > standings[b] end
				return U.ByteLess(a, b)
			end)
			local rows = {}
			for _, name in ipairs(names) do
				local net = standings[name]
				rows[#rows + 1] = {
					color = net > 0 and C.green or (net < 0 and RED or DIM),
					left = U.Short(name),
					mid = playedCount[name] .. (playedCount[name] == 1 and " round" or " rounds"),
					right = Signed(net),
					mine = name == me,
					leftColor = name == me and C.gold or C.text,
				}
			end
			side:SetData(rows)
			sideNote:SetText(#names > 0 and "Gold won or lost by each player in the real rounds on the left (practice doesn't count)."
				or (#data > 0 and "Practice rounds don't count here." or ""))
		end
	end

	v:SetScript("OnShow", function(self) self:Refresh() end)
	J.OnChange(function()
		if v:IsVisible() then v:Refresh() end
	end)
	return v
end
