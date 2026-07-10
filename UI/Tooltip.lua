-- One tooltip style for every TrueParse hover: the same solid dark card
-- the gauge tooltip uses. Replaces the mix of GameTooltip and custom
-- frames that made hovers look like two different addons.
local _, TP = ...

local Tooltip = {}
TP.Tooltip = Tooltip

local WIDTH = 220
local tip
local lines = {}

local function build()
	tip = CreateFrame("Frame", "TrueParseTooltip", UIParent, "BackdropTemplate")
	tip:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	tip:SetBackdropColor(0.04, 0.04, 0.05, 1)
	tip:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	tip:SetWidth(WIDTH)
	tip:SetClampedToScreen(true)
	tip:SetFrameStrata("TOOLTIP")
	tip.title = tip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	tip.title:SetPoint("TOPLEFT", 10, -8)
	tip.title:SetPoint("TOPRIGHT", -10, -8)
	tip.title:SetJustifyH("LEFT")
	tip:Hide()
end

local function lineFS(i)
	local fs = lines[i]
	if not fs then
		fs = tip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetJustifyH("LEFT")
		lines[i] = fs
	end
	return fs
end

-- owner: frame to anchor to. anchor: "TOP" (above the owner) or "RIGHT"
-- (beside it, flipping to whichever side has screen room).
-- data: array of { text, r, g, b } lines; text wraps to the card width.
function Tooltip:Show(owner, anchor, title, data)
	if not tip then
		build()
	end
	tip.title:SetText(title or "")
	local y = -(8 + tip.title:GetStringHeight() + 4)
	local shown = 0
	for _, line in ipairs(data or {}) do
		shown = shown + 1
		local fs = lineFS(shown)
		fs:ClearAllPoints()
		fs:SetPoint("TOPLEFT", 10, y)
		fs:SetPoint("TOPRIGHT", -10, y)
		fs:SetText(line[1] or "")
		fs:SetTextColor(line[2] or 1, line[3] or 1, line[4] or 1)
		fs:Show()
		y = y - fs:GetStringHeight() - 3
	end
	for i = shown + 1, #lines do
		lines[i]:Hide()
	end
	tip:SetHeight(-y + 7)
	tip:ClearAllPoints()
	if anchor == "TOP" then
		tip:SetPoint("BOTTOM", owner, "TOP", 0, 6)
	elseif (owner:GetRight() or 0) + WIDTH + 12 <= UIParent:GetWidth() then
		tip:SetPoint("LEFT", owner, "RIGHT", 8, 0)
	else
		tip:SetPoint("RIGHT", owner, "LEFT", -8, 0)
	end
	tip:Show()
end

function Tooltip:Hide()
	if tip then
		tip:Hide()
	end
end
