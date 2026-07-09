-- Recycled scorecard row pool: [grade] Name ......... score
local _, TP = ...

local Scorecard = { pool = {} }
TP.Scorecard = Scorecard

function Scorecard:Acquire(parent)
	local row = table.remove(self.pool)
	if not row then
		row = CreateFrame("Frame", nil, parent)
		row:EnableMouse(true)
		-- payload (row.fight / row.result) is set by the scorecard renderer
		row:SetScript("OnMouseUp", function(self, button)
			if button ~= "LeftButton" then
				return
			end
			if self.result then
				TP.BreakdownPanel:Toggle(self.fight, self.result)
			elseif self.groupResults then
				TP.BreakdownPanel:ToggleGroup(self.fight, self.groupResults)
			end
		end)
		-- the breakdown panel is the row tooltip: hover previews, click pins
		row:SetScript("OnEnter", function(self)
			self.bg:SetColorTexture(1, 1, 1, 0.12)
			if self.result then
				TP.BreakdownPanel:ShowHover(self.fight, self.result)
			elseif self.groupResults then
				TP.BreakdownPanel:ShowHoverGroup(self.fight, self.groupResults)
			end
		end)
		row:SetScript("OnLeave", function(self)
			local base = self.baseBg
			if base then
				self.bg:SetColorTexture(base[1], base[2], base[3], base[4])
			else
				self.bg:SetColorTexture(1, 1, 1, 0.04)
			end
		end)

		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetAllPoints()
		row.bg:SetColorTexture(1, 1, 1, 0.04)

		row.grade = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
		row.grade:SetPoint("LEFT", 4, 0)
		row.grade:SetWidth(24)
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
