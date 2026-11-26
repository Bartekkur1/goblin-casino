-- Goblin Casino: startup, SavedVariables, slash commands.
local ADDON, ns = ...

local DEFAULTS = {
	minimap = { hide = false, angle = 215 },
	stakeLimit = 100,
	history = {},
	ledger = {}, -- [me] = { entries, rounds, outbox, seen } (see Core/Ledger.lua)
	-- window = { point, relPoint, x, y } once the window has been moved
}

function ns.Print(msg)
	print("|cffffd84dGoblin Casino:|r " .. msg)
end

local function ApplyDefaults(db, defaults)
	for k, v in pairs(defaults) do
		if db[k] == nil then
			db[k] = type(v) == "table" and CopyTable(v) or v
		elseif type(v) == "table" and type(db[k]) == "table" then
			ApplyDefaults(db[k], v)
		end
	end
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:SetScript("OnEvent", function(self, _, name)
	if name ~= ADDON then return end
	self:UnregisterEvent("ADDON_LOADED")
	if type(GoblinCasinoDB) ~= "table" then GoblinCasinoDB = {} end
	if type(GoblinCasinoDB.history) ~= "table" then GoblinCasinoDB.history = nil end
	ApplyDefaults(GoblinCasinoDB, DEFAULTS)
	ns.db = GoblinCasinoDB
	ns.Log.Init(ns.db)
	-- practice mode (PLAY starts a round with bots) is off at every login; /casino practice turns
	-- it on for the session only. Older versions saved it, so drop that.
	ns.practice = false
	ns.db.practice = nil
	ns.Minimap:Init()
	if ns.db.debug then
		ns.Rolls.SetDebug(true)
		ns.Print("roll debug is |cff4dff9aON|r. Turn it off with /casino debug.")
	end
end)

SLASH_GOBLINCASINO1 = "/casino"
SLASH_GOBLINCASINO2 = "/goblincasino"
SlashCmdList.GOBLINCASINO = function(msg)
	msg = strtrim(msg or ""):lower()
	if msg == "minimap" then
		ns.Minimap:Toggle()
	elseif msg == "reset" then
		ns.Main:ResetPosition()
		ns.Print("window moved back to the center of the screen.")
	elseif msg == "history" then
		ns.Main:Get():Show()
		ns.Main:ShowView("history")
	elseif msg == "log" then
		ns.LogWindow:Toggle()
	elseif msg == "models" then
		ns.ModelTest:Toggle()
	elseif msg == "tune" then
		-- Onyxia's model, adjusted live (open Onyxia's Deep Breath first)
		ns.Main:Get():Show()
		if ns.Main.view ~= "onyxia" then
			ns.Print("open Onyxia's Deep Breath first (a practice round works: /casino practice), then /casino tune.")
		else
			ns.OnyxiaView.ToggleTune()
		end
	elseif msg == "sounds" then
		ns.Sound.ToggleTest()
	elseif msg == "sound" then
		ns.Sound.SetEnabled(not ns.Sound.Enabled())
		ns.Print("sounds " .. (ns.Sound.Enabled() and "|cff4dff9aON|r." or "|cffff6b6bOFF|r. Turn them on with /casino sound."))
	elseif msg == "debug" then
		ns.Rolls.SetDebug(not ns.Rolls.debug)
		ns.Print("roll debug " .. (ns.Rolls.debug and "|cff4dff9aON|r (stays on after /reload). Now /roll or click ROLL! and send the [debug] lines." or "|cffff6b6bOFF|r."))
	elseif msg == "practice" then
		ns.practice = not ns.practice
		if ns.practice then
			ns.Print("practice mode |cff4dff9aON|r until you log out: PLAY starts a round with bots, nobody pays. Type /casino practice again to turn it off.")
		else
			ns.Print("practice mode |cffff6b6bOFF|r: PLAY opens a real round for your group.")
		end
		ns.Main:UpdateLobby()
	elseif msg:match("^limit") then
		local ok, err = ns.Jackpot.SetLimit(msg:match("%d+"), "wheel")
		if ok then
			ns.Print("stake limit for rounds you host: " .. ns.db.stakeLimit .. " gold.")
		else
			ns.Print(err .. " Usage: /casino limit 100")
		end
	elseif msg == "help" then
		ns.Print("/casino - open/close, /casino practice - practice mode with bots on/off, /casino limit N - stake limit when you host, /casino sound - sounds on/off, /casino minimap - minimap icon, /casino reset - window position, /casino log - debug log to copy.")
	else
		ns.Main:Toggle()
	end
end

-- Addon compartment menu next to the minimap (AddonCompartmentFunc in the .toc).
function GoblinCasino_OnAddonCompartmentClick() ns.Main:Toggle() end
function GoblinCasino_OnAddonCompartmentEnter(_, frame) ns.Minimap.Tooltip(frame) end
function GoblinCasino_OnAddonCompartmentLeave() GameTooltip:Hide() end
