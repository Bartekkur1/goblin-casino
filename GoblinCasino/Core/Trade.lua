-- FINDING (placeholder): which event sequence marks a completed trade on the Forever client, whether
-- TRADE_ACCEPT_UPDATE reports (1, 1) before completion, whether UI_INFO_MESSAGE carries
-- ERR_TRADE_COMPLETE and whether SetTradeMoney(copper) fills the money box goes here once checked in game.
--
-- Temporary probe: every trade event goes to the debug log (/casino log), category "trade".
local ADDON, ns = ...

local Trade = {}
ns.Trade = Trade

Trade.probeMoney = nil -- copper put into the money box on TRADE_SHOW (/casino tradetest N)

local EVENTS = {
	"TRADE_SHOW", "TRADE_MONEY_CHANGED", "TRADE_PLAYER_ITEM_CHANGED", "TRADE_TARGET_ITEM_CHANGED",
	"TRADE_ACCEPT_UPDATE", "TRADE_REQUEST_CANCEL", "TRADE_CLOSED", "UI_INFO_MESSAGE", "PLAYER_MONEY",
}

-- result of a call in pcall as text
local function Probe(fn, ...)
	if type(fn) ~= "function" then return "n/a" end
	local ok, v = pcall(fn, ...)
	return ok and tostring(v) or ("err " .. tostring(v))
end

local function Args(...)
	local parts = {}
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring((select(i, ...)))
	end
	return table.concat(parts, ", ")
end

local frame = CreateFrame("Frame")
for _, e in ipairs(EVENTS) do frame:RegisterEvent(e) end
frame:SetScript("OnEvent", function(_, event, ...)
	local ok, err = pcall(function(...)
		local line = string.format("%s (%s) npc=%s player=%s target=%s money=%s", event, Args(...),
			Probe(UnitName, "NPC"), Probe(GetPlayerTradeMoney), Probe(GetTargetTradeMoney), Probe(GetMoney))
		if event == "UI_INFO_MESSAGE" then
			line = line .. string.format(" isTradeComplete=%s", tostring(select(2, ...) == ERR_TRADE_COMPLETE))
		end
		ns.Log.Add("trade", "%s", line)
		if event == "TRADE_SHOW" and Trade.probeMoney then
			ns.Log.Add("trade", "SetTradeMoney(%s) -> %s", Trade.probeMoney, Probe(SetTradeMoney, Trade.probeMoney))
		end
	end, ...)
	if not ok then ns.Log.Add("trade", "probe error: %s", tostring(err)) end
end)
