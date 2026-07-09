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
			if self.result then
				TP.BreakdownPanel:ShowHover(self.fight, self.result)
			elseif self.groupResults then
				TP.BreakdownPanel:ShowHoverGroup(self.fight, self.groupResults)
			end
		end)

		-- Details-style bar: dark track, class-colored fill whose WIDTH is
		-- the score (a 45 bar fills 45% of the row), mouseover brightening
		row.track = row:CreateTexture(nil, "BACKGROUND", nil, -1)
		row.track:SetAllPoints()
		row.track:SetColorTexture(0, 0, 0, 0.35)
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetPoint("TOPLEFT")
		row.bg:SetPoint("BOTTOMLEFT")
		row.bg:SetWidth(1)
		local highlight = row:CreateTexture(nil, "HIGHLIGHT")
		highlight:SetAllPoints()
		highlight:SetColorTexture(1, 1, 1, 0.15)

		-- Name ................. penalty score (white outlined name; the
		-- score wears its parse-bracket color, on the right)
		local function outlined(template)
			local fs = row:CreateFontString(nil, "OVERLAY", template)
			local path, size = fs:GetFont()
			fs:SetFont(path, size, "OUTLINE")
			return fs
		end
		row.score = outlined("GameFontNormalSmall")
		row.score:SetPoint("RIGHT", -4, 0)
		row.score:SetWidth(26)
		row.score:SetJustifyH("RIGHT")

		row.penalty = outlined("GameFontDisableSmall")
		row.penalty:SetPoint("RIGHT", row.score, "LEFT", -3, 0)
		row.penalty:SetJustifyH("RIGHT")

		-- spec icon (class icon fallback), like Details: flush with the row
		-- edges, full row height (renderer sets the width to match)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetPoint("TOPLEFT")
		row.icon:SetPoint("BOTTOMLEFT")
		row.icon:SetWidth(14)

		row.name = outlined("GameFontHighlightSmall")
		row.name:SetPoint("LEFT", row.icon, "RIGHT", 3, 0)
		row.name:SetPoint("RIGHT", row.penalty, "LEFT", -4, 0)
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
