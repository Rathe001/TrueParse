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
			if button == "RightButton" then
				-- the summary row carries the whole run behind right-click
				if self.runGroup then
					TP.BreakdownPanel:ToggleGroup(self.runGroup.fight, self.runGroup.results)
				end
				return
			end
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
		row.track:SetColorTexture(0, 0, 0, 0.55)
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetPoint("TOPLEFT")
		row.bg:SetPoint("BOTTOMLEFT")
		row.bg:SetWidth(1)
		local highlight = row:CreateTexture(nil, "HIGHLIGHT")
		highlight:SetAllPoints()
		highlight:SetColorTexture(1, 1, 1, 0.15)

		-- Name ....... penalty score runAvg (white outlined name; scores in
		-- parse-bracket colors; runAvg = dimmer cumulative True run average)
		local function outlined(template)
			local fs = row:CreateFontString(nil, "OVERLAY", template)
			local path, size = fs:GetFont()
			fs:SetFont(path, size, "OUTLINE")
			return fs
		end
		row.runAvg = outlined("GameFontDisableSmall")
		row.runAvg:SetPoint("RIGHT", -3, 0)
		row.runAvg:SetWidth(20)
		row.runAvg:SetJustifyH("RIGHT")
		row.runAvg:SetAlpha(0.75)

		row.score = outlined("GameFontNormalSmall")
		row.score:SetPoint("RIGHT", row.runAvg, "LEFT", -4, 0)
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

		-- TrueParse presence, just before the name: green check (running
		-- it), red X (not detected), question mark (unknown yet)
		row.addonMark = row:CreateTexture(nil, "ARTWORK")
		row.addonMark:SetSize(9, 9)
		row.addonMark:SetPoint("LEFT", row.icon, "RIGHT", 2, 0)

		row.name = outlined("GameFontHighlightSmall")
		row.name:SetPoint("LEFT", row.addonMark, "RIGHT", 2, 0)
		row.name:SetPoint("RIGHT", row.penalty, "LEFT", -4, 0)
		row.name:SetJustifyH("LEFT")
		-- narrow windows truncate long cross-realm names, never wrap
		row.name:SetWordWrap(false)
		row.name:SetMaxLines(1)
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
