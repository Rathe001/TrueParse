-- Recycled StatusBar pool. Bars are acquired/released on every refresh, so
-- they must never be created fresh per update.
local _, TP = ...

local Bars = { pool = {} }
TP.Bars = Bars

function Bars:Acquire(parent)
	local bar = table.remove(self.pool)
	if not bar then
		bar = CreateFrame("StatusBar", nil, parent)
		bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
		bar:SetMinMaxValues(0, 1)

		bar.bg = bar:CreateTexture(nil, "BACKGROUND")
		bar.bg:SetAllPoints()
		bar.bg:SetColorTexture(0, 0, 0, 0.55)

		bar.nameText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		bar.nameText:SetPoint("LEFT", 4, 0)
		bar.nameText:SetJustifyH("LEFT")

		bar.valueText = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		bar.valueText:SetPoint("RIGHT", -4, 0)
		bar.valueText:SetJustifyH("RIGHT")

		bar.nameText:SetPoint("RIGHT", bar.valueText, "LEFT", -4, 0)
	end
	bar:SetParent(parent)
	bar:Show()
	return bar
end

function Bars:Release(bar)
	bar:Hide()
	bar:ClearAllPoints()
	self.pool[#self.pool + 1] = bar
end
