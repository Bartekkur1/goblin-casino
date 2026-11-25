-- Minimap button: click opens the casino, drag moves the icon around the minimap.
local ADDON, ns = ...

local MM = {}
ns.Minimap = MM

local ICON = "Interface\\Icons\\INV_Misc_Coin_01"

function MM.Tooltip(owner)
	GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
	GameTooltip:AddLine("Goblin Casino", 1, 0.85, 0.3)
	GameTooltip:AddLine("|cffffd100Click|r to open / close", 1, 1, 1)
	if owner == MM.button then
		GameTooltip:AddLine("|cffffd100Drag|r to move this icon", 1, 1, 1)
		GameTooltip:AddLine("|cffffd100/casino minimap|r to hide it", 1, 1, 1)
	end
	GameTooltip:Show()
end

local function Place(b)
	local angle = math.rad(ns.db.minimap.angle or 215)
	local r = (Minimap:GetWidth() / 2) + 5
	b:ClearAllPoints()
	b:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * r, math.sin(angle) * r)
end

local function Create()
	local b = CreateFrame("Button", "GoblinCasinoMinimapButton", Minimap)
	b:SetSize(31, 31)
	b:SetFrameStrata("MEDIUM")
	b:SetFrameLevel(8)
	b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	b:RegisterForDrag("LeftButton")
	b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	local bg = b:CreateTexture(nil, "BACKGROUND")
	bg:SetSize(24, 24)
	bg:SetPoint("CENTER", b, "TOPLEFT", 16.8, -16.3)
	bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")

	-- The ring of MiniMap-TrackingBorder is not centered in the button (same offsets as CheapUpgrades).
	local icon = b:CreateTexture(nil, "ARTWORK")
	icon:SetSize(22, 22)
	icon:SetPoint("CENTER", b, "TOPLEFT", 16.8, -16.3)
	icon:SetTexture(ICON)
	icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

	local border = b:CreateTexture(nil, "OVERLAY")
	border:SetSize(53, 53)
	border:SetPoint("TOPLEFT")
	border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")

	b:SetScript("OnClick", function() ns.Main:Toggle() end)
	b:SetScript("OnEnter", MM.Tooltip)
	b:SetScript("OnLeave", function() GameTooltip:Hide() end)
	b:SetScript("OnDragStart", function(self)
		GameTooltip:Hide()
		self:SetScript("OnUpdate", function()
			local mx, my = Minimap:GetCenter()
			local scale = Minimap:GetEffectiveScale()
			local cx, cy = GetCursorPosition()
			ns.db.minimap.angle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
			Place(self)
		end)
	end)
	b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
	return b
end

function MM:Update()
	if ns.db.minimap.hide then
		if self.button then self.button:Hide() end
		return
	end
	self.button = self.button or Create()
	Place(self.button)
	self.button:Show()
end

function MM:Init()
	self:Update()
end

function MM:Toggle()
	ns.db.minimap.hide = not ns.db.minimap.hide
	self:Update()
	if ns.db.minimap.hide then
		ns.Print("minimap icon hidden. Bring it back with /casino minimap.")
	else
		ns.Print("minimap icon shown.")
	end
end
