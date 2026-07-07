-- Recycled scorecard row pool: [grade] Name ......... score
local _, TP = ...

local Scorecard = { pool = {} }
TP.Scorecard = Scorecard

function Scorecard:Acquire(parent)
	local row = table.remove(self.pool)
	if not row then
		row = CreateFrame("Frame", nil, parent)

		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(1, 1, 1, 0.04)

		row.grade = row:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
		row.grade:SetPoint("LEFT", 4, 0)
		row.grade:SetWidth(34)
		row.grade:SetJustifyH("LEFT")

		row.score = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.score:SetPoint("RIGHT", -4, 0)
		row.score:SetJustifyH("RIGHT")

		row.name = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.name:SetPoint("LEFT", row.grade, "RIGHT", 4, 0)
		row.name:SetPoint("RIGHT", row.score, "LEFT", -4, 0)
		row.name:SetJustifyH("LEFT")
	end
	row:SetParent(parent)
	row:Show()
	return row
end

function Scorecard:Release(row)
	row:Hide()
	row:ClearAllPoints()
	self.pool[#self.pool + 1] = row
end
