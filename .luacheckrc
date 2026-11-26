-- luacheck (static checks of the addon's Lua, run by CI): mainly catches misspelled or undeclared
-- variables and leftovers, which otherwise only show up as Lua errors in the game.
-- Run from the repository root: luacheck GoblinCasino
std = "lua51"
max_line_length = false
codes = true

ignore = {
	"212",       -- unused argument (event handlers and callbacks get arguments they don't need)
	"213",       -- unused loop variable
	"211/ADDON", -- every file starts with `local ADDON, ns = ...`
	"42.",       -- a local shadows another local (ok, err ... on purpose)
	"43.",       -- a local shadows an upvalue
	"542",       -- empty if branch
}

-- set by the addon
globals = {
	"GoblinCasinoDB",
	"SLASH_GOBLINCASINO1",
	"SLASH_GOBLINCASINO2",
	"SlashCmdList",
	"StaticPopupDialogs",
	"GoblinCasino_OnAddonCompartmentClick",
	"GoblinCasino_OnAddonCompartmentEnter",
	"GoblinCasino_OnAddonCompartmentLeave",
}

-- the WoW API the addon uses (add new ones here)
read_globals = {
	"C_AddOns", "C_ChatInfo", "C_RestrictedActions", "C_Timer",
	"CopyTable", "CreateColor", "CreateFrame", "Enum",
	"GameTooltip", "GetAddOnMetadata", "GetBuildInfo", "GetCursorPosition", "GetFileIDFromPath",
	"GetLocale", "GetMoney", "GetNormalizedRealmName", "GetNumGroupMembers", "GetRealmName",
	"GetServerTime", "GetTime", "GetUnitName",
	"IsInGroup", "IsInRaid", "LE_PARTY_CATEGORY_HOME", "LE_PARTY_CATEGORY_INSTANCE",
	"Minimap", "NO", "YES", "PlaySound", "PlaySoundFile", "SOUNDKIT", "RANDOM_ROLL_RESULT", "RandomRoll",
	"StaticPopup_Show", "UIParent", "UISpecialFrames", "UNKNOWNOBJECT",
	"UnitExists", "UnitIsConnected", "UnitIsPlayer", "UnitIsVisible", "UnitName",
	"InitiateTrade",
	"date", "time", "debugstack", "geterrorhandler", "seterrorhandler", "issecretvalue",
	"strsplit", "strtrim", "tinsert", "wipe",
}
