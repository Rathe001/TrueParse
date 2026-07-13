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
		-- the score (a 45 bar fills 45% of the bar area), mouseover
		-- brightening. The bar spans the NAME area only — the renderer
		-- sets the track width so scores sit on clean backdrop.
		row.track = row:CreateTexture(nil, "BACKGROUND", nil, -1)
		row.track:SetPoint("TOPLEFT")
		row.track:SetPoint("BOTTOMLEFT")
		row.track:SetWidth(100)
		row.track:SetColorTexture(0, 0, 0, 0.55)
		row.bg = row:CreateTexture(nil, "BACKGROUND")
		row.bg:SetPoint("TOPLEFT")
		row.bg:SetPoint("BOTTOMLEFT")
		row.bg:SetWidth(1)
		-- subtle column border where the bar area ends
		row.sep = row:CreateTexture(nil, "BACKGROUND", nil, 0)
		row.sep:SetPoint("TOPLEFT", row.track, "TOPRIGHT", 0, 0)
		row.sep:SetPoint("BOTTOMLEFT", row.track, "BOTTOMRIGHT", 0, 0)
		row.sep:SetWidth(1)
		row.sep:SetColorTexture(1, 1, 1, 0.10)
		local highlight = row:CreateTexture(nil, "HIGHLIGHT")
		highlight:SetAllPoints()
		highlight:SetColorTexture(1, 1, 1, 0.15)

		-- Name ....... penalty score runAvg (white outlined name; scores in
		-- parse-bracket colors; runAvg = dimmer cumulative True run average)
		-- Details-style type: Arial Narrow with a hard drop shadow, no
		-- outline — the look meter users already read all day
		local function outlined(template, size)
			local fs = row:CreateFontString(nil, "OVERLAY", template)
			fs:SetFont("Fonts\\ARIALN.TTF", size or 12, "")
			fs:SetShadowColor(0, 0, 0, 1)
			fs:SetShadowOffset(1, -1)
			return fs
		end
		row.runAvg = outlined("GameFontDisableSmall", 11)
		row.runAvg:SetPoint("RIGHT", -3, 0)
		row.runAvg:SetWidth(20)
		row.runAvg:SetJustifyH("RIGHT")
		row.runAvg:SetAlpha(0.75)

		row.score = outlined("GameFontNormalSmall", 12)
		row.score:SetPoint("RIGHT", row.runAvg, "LEFT", -4, 0)
		row.score:SetWidth(26)
		row.score:SetJustifyH("RIGHT")

		row.penalty = outlined("GameFontDisableSmall", 10)
		row.penalty:SetPoint("RIGHT", row.score, "LEFT", -3, 0)
		row.penalty:SetJustifyH("RIGHT")
		-- fixed slot: an unconstrained width let truncated names crowd
		-- right up against the score column. One line, always.
		row.penalty:SetWidth(22)
		row.penalty:SetWordWrap(false)
		row.penalty:SetMaxLines(1)

		-- hairline between the penalty column and the fight score
		row.sep3 = row:CreateTexture(nil, "BACKGROUND", nil, 0)
		row.sep3:SetPoint("TOP", 0, 0)
		row.sep3:SetPoint("BOTTOM", 0, 0)
		row.sep3:SetPoint("RIGHT", row.score, "LEFT", -1, 0)
		row.sep3:SetWidth(1)
		row.sep3:SetColorTexture(1, 1, 1, 0.10)

		-- hairline between the fight and run score columns (the renderer
		-- hides it when there's no run column yet)
		row.sep2 = row:CreateTexture(nil, "BACKGROUND", nil, 0)
		row.sep2:SetPoint("TOP", 0, 0)
		row.sep2:SetPoint("BOTTOM", 0, 0)
		row.sep2:SetPoint("RIGHT", row.runAvg, "LEFT", -2, 0)
		row.sep2:SetWidth(1)
		row.sep2:SetColorTexture(1, 1, 1, 0.10)

		-- spec icon (class icon fallback), like Details: flush with the row
		-- edges, full row height (renderer sets the width to match)
		row.icon = row:CreateTexture(nil, "ARTWORK")
		row.icon:SetPoint("TOPLEFT")
		row.icon:SetPoint("BOTTOMLEFT")
		row.icon:SetWidth(14)

		-- TrueParse presence: a green dot on the spec icon's corner, users
		-- only. A solid indicator dot reads at small sizes where the
		-- ready-check swoosh vanished into the icon art. Non-users are
		-- already told by the muted bar color.
		row.addonMark = row:CreateTexture(nil, "OVERLAY")
		row.addonMark:SetSize(9, 9)
		row.addonMark:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", 3, -3)
		row.addonMark:SetTexture("Interface\\COMMON\\Indicator-Green")

		row.name = outlined("GameFontHighlightSmall", 12)
		row.name:SetPoint("LEFT", row.icon, "RIGHT", 3, 0)
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
