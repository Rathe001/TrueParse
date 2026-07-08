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
		row:SetScript("OnEnter", function(self)
			self.bg:SetColorTexture(1, 1, 1, 0.12)
			local result = self.result
			if not result then
				if self.groupResults then
					GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
					GameTooltip:SetText(self.playerName or "Group")
					GameTooltip:AddLine("Click for the group breakdown", 0.5, 0.5, 0.5)
					GameTooltip:Show()
				end
				return
			end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:SetText(self.playerName or result.name or "")
			local grade = TP.Scoring.Grades.ForScore(result.score)
			local gr, gg, gb = TP.Scoring.Grades.Color(grade)
			GameTooltip:AddLine(("Grade %s · score %.1f"):format(grade, result.score), gr, gg, gb)

			local parts = {}
			for key, b in pairs(result.breakdown) do
				if b.applicable then
					parts[#parts + 1] = { key = key, pts = b.contribution or 0 }
				end
			end
			table.sort(parts, function(a, b)
				return a.pts > b.pts
			end)
			for _, part in ipairs(parts) do
				GameTooltip:AddLine(("%s: %.1f pts"):format(
					TP.METRIC_LABELS[part.key] or part.key, part.pts), 0.85, 0.85, 0.85)
			end
			if (result.penalty or 0) > 0 then
				GameTooltip:AddLine(("Penalties: -%.1f"):format(result.penalty), 0.95, 0.4, 0.4)
			end
			if self.awards then
				for _, award in ipairs(self.awards) do
					GameTooltip:AddLine(TP.STAR .. " " .. award, 1, 0.82, 0.2)
				end
			end
			GameTooltip:AddLine("Click for the full breakdown", 0.5, 0.5, 0.5)
			GameTooltip:Show()
		end)
		row:SetScript("OnLeave", function(self)
			local base = self.baseBg
			if base then
				self.bg:SetColorTexture(base[1], base[2], base[3], base[4])
			else
				self.bg:SetColorTexture(1, 1, 1, 0.04)
			end
			GameTooltip:Hide()
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
