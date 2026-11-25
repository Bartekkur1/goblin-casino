-- Murloc Derby screen: one lane per player, the race, commentary, then the settlement.
local ADDON, ns = ...
local T, U, J, D, W = ns.Theme, ns.Util, ns.Jackpot, ns.Derby, ns.Widgets
local C, hex, Mix = T.C, T.hex, T.Mix

local View = {}
ns.DerbyView = View

local TRACK_H = 318
local CAM = 1.55 -- how far the camera steps back from a runner (see Layout); bigger = smaller runners
local LABEL_W = 180
local FINISH_PAD = 46
local RED, ORANGE, DIM = hex("ff6b6b"), hex("ffb347"), hex("9d8fbf")
local WHITE = hex("ffffff")

local PHASES = {
	SETUP = { "SETUP", C.gold },
	BETTING = { "ENTRIES OPEN", C.green },
	ROLLING = { "ROLL FOR THE SEED", C.cyan },
	SPINNING = { "RACING", C.pink },
	DONE = { "RESULT", C.gold },
	CANCELLED = { "CANCELLED", RED },
}

local function ColorCode(c)
	return string.format("|cff%02x%02x%02x", c[1] * 255, c[2] * 255, c[3] * 255)
end

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
	local title = T.Text(v, T.FONT_DISPLAY, 18, Mix(C.teal, WHITE, 0.55))
	title:SetPoint("LEFT", back, "RIGHT", 14, 0)
	title:SetText("MURLOC DERBY")
	local phase = T.Pill(v, "", { 1, 1, 1, 0.08 }, C.green)
	phase:SetPoint("LEFT", title, "RIGHT", 12, 0)
	local practice = T.Pill(v, "PRACTICE · BOTS", { ORANGE[1], ORANGE[2], ORANGE[3], 0.16 }, ORANGE)
	practice:SetPoint("LEFT", phase.label, "RIGHT", 18, 0)
	local hostInfo = T.Text(v, T.FONT_BODY, 11, C.textDim)
	hostInfo:SetJustifyH("RIGHT")
	hostInfo:SetPoint("TOPRIGHT", 0, -8)

	-----------------------------------------------------------------------
	-- track
	-----------------------------------------------------------------------
	local track = CreateFrame("Frame", nil, v)
	track:SetPoint("TOPLEFT", 0, -40)
	track:SetSize(width, TRACK_H)
	T.Gradient(track, "HORIZONTAL", hex("0a2530"), hex("071822")):SetAllPoints()
	T.Border(track, Mix(C.teal, C.bgDeep, 0.45), 1)
	local x0, x1 = LABEL_W, width - FINISH_PAD

	local startLine = T.Solid(track, { 1, 1, 1, 0.45 }, "BORDER")
	startLine:SetPoint("TOPLEFT", x0, -6)
	startLine:SetSize(2, TRACK_H - 12)
	-- checkered finish line
	local sq = 5
	for r = 0, math.floor((TRACK_H - 12) / sq) - 1 do
		for c = 0, 1 do
			local s = T.Solid(track, (r + c) % 2 == 0 and { 1, 1, 1, 0.85 } or { 0, 0, 0, 0.85 }, "BORDER")
			s:SetSize(sq, sq)
			s:SetPoint("TOPLEFT", x1 - sq + c * sq, -6 - r * sq)
		end
	end
	local emptyText = T.Text(track, T.FONT_BOLD, 13, C.textDim)
	emptyText:SetJustifyH("CENTER")
	emptyText:SetPoint("CENTER", (x0 + x1) / 2 - width / 2, 0)
	emptyText:SetText("No murlocs at the gate yet. Join the race!")

	local lanes = {}
	local function Lane(i)
		if lanes[i] then return lanes[i] end
		local lane = CreateFrame("Frame", nil, track)
		lane.bg = T.Solid(lane, { 1, 1, 1, i % 2 == 0 and 0.035 or 0 })
		lane.bg:SetAllPoints()
		lane.mine = T.Solid(lane, { C.gold[1], C.gold[2], C.gold[3], 0.08 }, "BACKGROUND", 1)
		lane.mine:SetAllPoints()
		lane.win = T.Gradient(lane, "HORIZONTAL", { C.gold[1], C.gold[2], C.gold[3], 0.05 },
			{ C.gold[1], C.gold[2], C.gold[3], 0.28 }, "BACKGROUND", 2)
		lane.win:SetAllPoints()
		lane.win:Hide()
		-- colored "shadow" under the murloc's feet in the player's color
		lane.ring = T.Circle(lane, 28, "ARTWORK", 0)
		lane.ring:SetAlpha(0.55)
		-- the 3D murloc
		local model = CreateFrame("PlayerModel", nil, lane)
		model:SetSize(48, 48)
		model:SetScript("OnModelLoaded", function(self)
			pcall(self.SetFacing, self, D.FACING)
			pcall(self.SetCamDistanceScale, self, CAM)
			if lane.anim then pcall(self.SetAnimation, self, lane.anim) end
		end)
		lane.model = model
		lane.name = T.Text(lane, T.FONT_BOLD, 12, C.text)
		lane.name:SetWordWrap(false)
		lane.name:SetWidth(LABEL_W - 56)
		lane.player = T.Text(lane, T.FONT_BODY, 10, DIM)
		lane.player:SetWordWrap(false)
		lane.player:SetWidth(LABEL_W - 56)
		-- finishing place, in the name column right before the start line (never under a model)
		lane.place = T.Text(lane, T.FONT_DISPLAY, 14, C.gold)
		lane.place:SetJustifyH("RIGHT")
		lane.place:SetPoint("RIGHT", lane, "LEFT", x0 - 8, 0)
		lanes[i] = lane
		return lane
	end

	-- A model is drawn only inside its frame, and the camera frames the creature as it stands; a
	-- leap while running (the tiger) goes past that and gets cut off. So the frame is bigger than
	-- the lane and the camera steps back (CAM): the creature looks about as tall as the lane, with
	-- room to spare around it. Its feet sit PAD above the frame's bottom, on the lane's bottom edge;
	-- heads may reach into the lane above, like runners seen in perspective.
	local laneH, iconSize, modelW, modelH, pad = 40, 28, 64, 40, 0
	local function Layout(n)
		laneH = math.max(12, math.min(52, (TRACK_H - 12) / math.max(n, 5)))
		iconSize = math.min(laneH - 4, 30)
		modelH = math.floor(laneH * 1.55)
		modelW = math.floor(modelH * 1.7)
		pad = modelH * (1 - 1 / CAM) / 2
		for i, lane in ipairs(lanes) do lane:Hide() end
		for i = 1, n do
			local lane = Lane(i)
			lane:ClearAllPoints()
			lane:SetPoint("TOPLEFT", 1, -(6 + (i - 1) * laneH))
			lane:SetSize(width - 2, laneH)
			lane.ring:SetSize(iconSize + 4, (iconSize + 4) * 0.35)
			lane.model:SetSize(modelW, modelH)
			local twoLines = laneH >= 30
			lane.name:ClearAllPoints()
			lane.player:ClearAllPoints()
			if twoLines then
				lane.name:SetPoint("BOTTOMLEFT", lane, "LEFT", 10, 1)
				lane.player:SetPoint("TOPLEFT", lane, "LEFT", 10, -1)
				lane.player:Show()
			else
				lane.name:SetPoint("LEFT", 10, 0)
				lane.player:Hide()
			end
			lane.name:SetFont(T.FONT_BOLD, laneH >= 20 and 12 or 10, "")
			lane.twoLines = twoLines
			lane:Show()
		end
		emptyText:SetShown(n == 0)
	end

	-- place a runner: pos 0 = the whole creature behind the start line, 1 = its nose on the finish
	-- line. The race script only fixes the order at pos 1, so the nose must reach the line exactly
	-- then (if it got there earlier, a runner-up could be seen crossing before the winner).
	-- lift: the runner hops off the ground (its shadow stays)
	local function PlaceRunner(lane, pos, lift)
		local half = modelW / CAM / 2 + 2 -- half of the creature as drawn, not of its frame
		local x = x0 + half + pos * (x1 - x0 - 2 * half)
		local ringH = (iconSize + 4) * 0.35
		lane.ring:SetPoint("CENTER", lane, "BOTTOMLEFT", x, ringH / 2 + 1)
		lane.model:SetPoint("BOTTOM", lane, "BOTTOMLEFT", x, 1 - pad + (lift or 0))
	end

	-- the celebration this lane's creature can actually play
	local function Celebration(lane)
		if lane.celebrate then return lane.celebrate end
		local m = lane.model
		for _, id in ipairs(D.CELEBRATE) do
			local ok, has = pcall(m.HasAnimation, m, id)
			if ok and has then
				lane.celebrate = id
				return id
			end
		end
		-- can't tell (yet, the model may still be loading): try cheer, and ask again for a while
		lane.celebrateTries = (lane.celebrateTries or 0) + 1
		if lane.celebrateTries > 40 then lane.celebrate = D.CELEBRATE[1] end
		return D.CELEBRATE[1]
	end

	-- switch a murloc's animation (only when it changes)
	local function SetAnim(lane, id)
		if lane.anim == id then return end
		lane.anim = id
		pcall(lane.model.SetAnimation, lane.model, id)
	end

	-- give a lane its murloc model
	local function SetSkin(lane, skin)
		if lane.skin == skin then return end
		lane.skin = skin
		lane.anim = nil
		lane.celebrate = nil
		lane.celebrateTries = nil
		pcall(lane.model.SetDisplayInfo, lane.model, skin)
		pcall(lane.model.SetFacing, lane.model, D.FACING)
		pcall(lane.model.SetCamDistanceScale, lane.model, CAM)
		SetAnim(lane, D.ANIM.stand)
	end

	-----------------------------------------------------------------------
	-- settlement overlay (after the race)
	-----------------------------------------------------------------------
	local overlay = CreateFrame("Frame", nil, track)
	overlay:SetAllPoints()
	overlay:SetFrameLevel(track:GetFrameLevel() + 20)
	overlay:EnableMouse(true)
	T.Solid(overlay, hex("0d0520", 0.95)):SetAllPoints()
	local ovTitle = T.Text(overlay, T.FONT_BOLD, 10, C.textDim)
	ovTitle:SetPoint("TOPLEFT", 14, -10)
	ovTitle:SetText("SETTLEMENT  ·  WINNER TAKES ALL")
	local ovMeta = T.Text(overlay, T.FONT_BODY, 10, DIM)
	ovMeta:SetJustifyH("RIGHT")
	ovMeta:SetPoint("TOPRIGHT", -14, -10)
	local ovList = W.List(overlay, width - 28, 10, 26)
	ovList:SetPoint("TOPLEFT", 14, -28)
	overlay:Hide()
	local showRace = false

	-----------------------------------------------------------------------
	-- bottom: commentary on the left, actions on the right
	-----------------------------------------------------------------------
	local bottom = CreateFrame("Frame", nil, v)
	bottom:SetPoint("TOPLEFT", 0, -(40 + TRACK_H + 10))
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
	local leaveBtn = T.DarkButton(actions, "LEAVE THE RACE", 200, 34)
	leaveBtn:SetPoint("TOPRIGHT")
	leaveBtn:SetScript("OnClick", function() J.Bet(0) end)

	local lockBtn = T.GoldButton(actions, "START", 140, 34)
	lockBtn:SetPoint("BOTTOMLEFT")
	lockBtn:SetScript("OnClick", function()
		local ok, err = J.Lock()
		if not ok and err then ns.Print(err) end
	end)
	local cancelBtn = T.DarkButton(actions, "CANCEL", 64, 34)
	cancelBtn:SetPoint("LEFT", lockBtn, "RIGHT", 6, 0)
	cancelBtn:SetScript("OnClick", function() J.Cancel() end)
	-- host setup: the entry fee is chosen before anyone can join
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
	for i, amount in ipairs({ 10, 20, 50, 100 }) do
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

	local newBtn = T.GoldButton(actions, "NEW RACE", 130, 34)
	newBtn:SetPoint("BOTTOMLEFT")
	newBtn:SetScript("OnClick", function()
		J.Dismiss()
		ns.Main:StartGame("derby")
	end)
	local lobbyBtn = T.DarkButton(actions, "BACK TO LOBBY", 130, 34)
	lobbyBtn:SetScript("OnClick", function()
		J.Dismiss()
		ns.Main:ShowView("lobby")
	end)
	local raceBtn = T.DarkButton(actions, "VIEW RACE", 130, 30)
	raceBtn:SetPoint("TOPRIGHT")
	raceBtn:SetScript("OnClick", function()
		showRace = not showRace
		v:Refresh()
	end)

	local info = T.Text(actions, T.FONT_BODY, 11, C.textDim)
	info:SetJustifyH("RIGHT")
	info:SetPoint("BOTTOMRIGHT", 0, 10)
	info:SetWidth(320)

	-- players (not the host) can walk away from a round whose host is gone
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
		newBtn, lobbyBtn, raceBtn, info, quitBtn }
	for _, p in ipairs(presets) do allActions[#allActions + 1] = p end
	local function ShowOnly(...)
		for _, w in ipairs(allActions) do w:Hide() end
		for i = 1, select("#", ...) do select(i, ...):Show() end
	end

	-----------------------------------------------------------------------
	-- state
	-----------------------------------------------------------------------
	local runners, assign, colors = {}, {}, {}
	local lastSignature
	local script, scriptRound

	local function RaceTime(round)
		return GetTime() - (round.spinStart or 0) - D.START_DELAY
	end

	-- positions and commentary while racing (and the final picture after it)
	local function Animate(round)
		if not script then return end
		local t = RaceTime(round)
		local now = GetTime()
		for i, name in ipairs(runners) do
			local lane = lanes[i]
			local curve = script.curves[name]
			if lane and curve then
				local rank
				if t >= curve.finish then
					for r, n in ipairs(script.order) do
						if n == name then rank = r end
					end
				end
				-- the winner hops for joy once over the line
				local lift = 0
				if rank == 1 and round.phase == "SPINNING" then
					lift = math.abs(math.sin((t - curve.finish) * 7)) * laneH * 0.3
				end
				PlaceRunner(lane, D.Position(curve, t), lift)
				if t <= 0 then
					SetAnim(lane, D.ANIM.stand)
				elseif rank then
					SetAnim(lane, rank == 1 and Celebration(lane) or D.ANIM.stand)
				elseif D.Stumbling(curve, t) then
					SetAnim(lane, D.ANIM.stun)
				else
					SetAnim(lane, D.ANIM.run)
				end
				lane.place:SetText(rank and W.Ordinal(rank) or "")
				lane.place:SetTextColor(T.Unpack(rank == 1 and C.gold or C.textDim))
				lane.win:SetShown(rank == 1)
			end
		end
		if round.phase == "SPINNING" then
			if t < 0 then
				headline:SetText(tostring(math.ceil(-t)))
				headline:SetTextColor(T.Unpack(C.gold))
			elseif t < 1 then
				headline:SetText("GO!")
				headline:SetTextColor(T.Unpack(C.green))
			else
				local current
				for _, e in ipairs(script.events) do
					if e.t <= t then current = e end
				end
				if current then
					headline:SetText(current.text)
					headline:SetTextColor(T.Unpack(current.kind == "stumble" and ORANGE
						or current.kind == "finish" and C.gold or C.text))
				end
			end
		end
	end

	function v:Refresh()
		local round = J.round
		if not round or round.game ~= "derby" then
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

		-- lanes follow the entries
		runners = U.SortedKeys(round.bets)
		assign = D.Assign(round)
		local signature = table.concat(runners, ",")
		if signature ~= lastSignature then
			lastSignature = signature
			Layout(#runners)
		end
		for i, name in ipairs(runners) do
			local lane = lanes[i]
			colors[name] = ns.Wheel.ColorFor(i)
			local a = assign[name]
			lane.ring:SetColorTexture(T.Unpack(colors[name]))
			local who = U.Short(name) .. (name == round.host and "  |cff9d8fbfhost|r" or "")
			if lane.twoLines then
				lane.name:SetText(ColorCode(colors[name]) .. a.murloc .. "|r")
				lane.player:SetText(who .. "  ·  " .. a.trait.name)
			else
				lane.name:SetText(ColorCode(colors[name]) .. a.murloc .. "|r  |cff9d8fbf" .. U.Short(name) .. "|r")
			end
			lane.mine:SetShown(name == me)
			SetSkin(lane, a.skin)
			if round.phase == "BETTING" or round.phase == "ROLLING" then
				PlaceRunner(lane, 0)
				SetAnim(lane, D.ANIM.stand)
				lane.place:SetText("")
				lane.win:Hide()
			end
		end

		-- the race script, once per round
		if round.result and scriptRound ~= round.id then
			scriptRound = round.id
			script = D.Script(round)
			showRace = false
		elseif not round.result then
			script = nil
		end
		Animate(round)

		local pot = U.Gold(round.limit * #runners)
		local inRace = round.bets[me] ~= nil
		local note, noteColor = round.warning or round.error, round.error and RED or ORANGE
		overlay:Hide()
		info:SetWidth(320)

		if round.phase == "SETUP" then
			headline:SetText("CHOOSE THE ENTRY FEE")
			headline:SetTextColor(T.Unpack(C.gold))
			message:SetText("Everyone who joins pays this fee and the winner takes the whole pot. It can't change once entries are open. "
				.. (round.practice and "Then open entries for the bots." or "Then open entries for your group."))
			message:SetTextColor(T.Unpack(C.textDim))
			ShowOnly(feeBox, presets[1], presets[2], presets[3], presets[4], openBtn, cancelBtn)
			if not feeBox:HasFocus() then feeBox:SetNumber(round.limit) end

		elseif round.phase == "BETTING" then
			headline:SetText(#runners .. (#runners == 1 and " MURLOC" or " MURLOCS") .. "  ·  POT " .. U.Thousands(round.limit * #runners) .. "G")
			headline:SetTextColor(T.Unpack(C.gold))
			local hint = (isHost and #runners < 2) and "You can start once at least 2 murlocs are in."
			message:SetText(note or hint or "Everyone pays the same entry and the winner takes the whole pot. "
				.. "Traits are just for show: every murloc has exactly the same chance.")
			message:SetTextColor(T.Unpack(note and noteColor or C.textDim))
			joinBtn:SetLabel("JOIN  ·  " .. U.Thousands(round.limit) .. "G")
			local entry = inRace and leaveBtn or joinBtn
			if isHost then
				ShowOnly(entry, lockBtn, cancelBtn)
				lockBtn:SetActive(#runners >= 2)
			else
				ShowOnly(entry, info, quitBtn)
				info:SetWidth(240)
				info:SetText("Waiting for " .. U.Short(round.host) .. " to start the race")
			end

		elseif round.phase == "ROLLING" then
			local rolled = 0
			for _, name in ipairs(runners) do
				if round.seen and round.seen[name] then rolled = rolled + 1 end
			end
			headline:SetText("AT THE GATE  ·  " .. rolled .. "/" .. #runners .. " ROLLED")
			headline:SetTextColor(T.Unpack(C.cyan))
			message:SetText(note or "Everyone's /roll makes the seed. Only the seed decides the race, not who rolls higher.")
			message:SetTextColor(T.Unpack(note and noteColor or C.textDim))
			local left = math.max(0, math.ceil((round.deadline or 0) - GetTime()))
			if inRace and not J.HasRolled() then
				ShowOnly(rollBtn, info)
				rollBtn:SetActive(left > 0)
				info:SetText(left > 0 and ("Roll within |cffffd84d" .. left .. "s|r") or "Too late, the host rolls for you")
			elseif not isHost and GetTime() > (round.deadline or 0) + 20 then
				-- the host should have finished long ago (offline, /reload, or messages blocked)
				ShowOnly(info, quitBtn)
				info:SetWidth(240)
				info:SetText("The host hasn't finished the race")
			else
				ShowOnly(info)
				info:SetText(left > 0 and ("Waiting for rolls  ·  " .. left .. "s") or "The host rolls for missing players...")
			end

		elseif round.phase == "SPINNING" then
			ShowOnly()
			message:SetText(note or ("Pot " .. pot .. ". Winner takes all."))
			message:SetTextColor(T.Unpack(note and noteColor or C.textDim))

		elseif round.phase == "DONE" then
			local res = round.result
			local a = assign[res.winner]
			headline:SetText((a and a.murloc or "?"):upper() .. " WINS!")
			headline:SetTextColor(T.Unpack(C.gold))
			local count = #res.transfers
			local summary = U.Short(res.winner) .. " wins " .. U.Gold(res.gain) .. ": " .. count
				.. (count == 1 and " player pays " or " players pay ") .. U.Gold(round.limit) .. " each."
			if inRace and res.winner ~= me then
				summary = "You pay " .. U.Short(res.winner) .. " " .. U.Gold(round.limit) .. ". " .. summary
			elseif res.winner == me then
				summary = "Your murloc won! " .. summary
			end
			if round.practice then summary = summary .. " |cff9d8fbf(practice: no gold moves)|r" end
			message:SetText(note and (note .. "\n" .. summary) or summary)
			message:SetTextColor(T.Unpack(note and noteColor or C.text))

			local rows = {}
			for _, t in ipairs(res.transfers) do
				rows[#rows + 1] = {
					color = colors[t.from], left = U.Short(t.from), mid = "pays " .. U.Short(t.to),
					right = U.Gold(t.amount), mine = t.from == me or t.to == me,
					leftColor = t.from == me and C.gold or C.text,
				}
			end
			ovList:SetData(rows)
			ovMeta:SetText((a and a.murloc or "?") .. " (" .. U.Short(res.winner) .. ") takes " .. U.Gold(res.total))
			overlay:SetShown(not showRace)
			raceBtn:SetLabel(showRace and "VIEW PAYMENTS" or "VIEW RACE")

			local canRestart = isHost or round.practice
			ShowOnly(raceBtn, lobbyBtn, canRestart and newBtn or lobbyBtn)
			lobbyBtn:ClearAllPoints()
			if canRestart then
				lobbyBtn:SetPoint("LEFT", newBtn, "RIGHT", 10, 0)
			else
				lobbyBtn:SetPoint("BOTTOMLEFT")
			end

		else -- CANCELLED
			headline:SetText("RACE CANCELLED")
			headline:SetTextColor(T.Unpack(RED))
			message:SetText(round.error or "Nobody pays.")
			message:SetTextColor(T.Unpack(C.textDim))
			ShowOnly(lobbyBtn)
			lobbyBtn:ClearAllPoints()
			lobbyBtn:SetPoint("BOTTOMLEFT")
		end
	end

	-- the race runs every frame; countdowns tick a few times a second
	local clock = 0
	v:SetScript("OnUpdate", function(self, dt)
		local round = J.round
		if not round or round.game ~= "derby" then return end
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
		for _, lane in ipairs(lanes) do
			lane.skin, lane.anim = nil, nil
		end
	end)
	J.OnChange(function()
		if v:IsVisible() then v:Refresh() end
	end)
	return v
end
