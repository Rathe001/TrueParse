-- Click-to-breakdown panel: plain-language bullets explaining the grade.
-- Green + earned points, red - cost points (weak metrics and penalties),
-- dim mid-marks for middling contributions, gold + for awards — biggest
-- weight first. Hovering any bullet shows the full numeric derivation.
local _, TP = ...

local Panel = {}
TP.BreakdownPanel = Panel

local WIDTH = 380
local ROW_HEIGHT = 15
local FIRST_ROW_Y = -40

local COUNT_METRICS = { interrupts = true, dispels = true }

local frame
local rows = {}

local function rowEnter(self)
	local d = self.tooltipData
	if not d then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(d.title)
	for _, line in ipairs(d.lines) do
		GameTooltip:AddLine(line[1], line[2], line[3], line[4], true)
	end
	GameTooltip:Show()
end

local function rowLeave()
	GameTooltip:Hide()
end

local function newRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(WIDTH - 12, ROW_HEIGHT)
	row:EnableMouse(true)
	row:SetScript("OnEnter", rowEnter)
	row:SetScript("OnLeave", rowLeave)

	row.symbol = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.symbol:SetPoint("LEFT", 10, 0)
	row.symbol:SetWidth(14)
	row.symbol:SetJustifyH("CENTER")

	row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.text:SetPoint("LEFT", 28, 0)
	row.text:SetPoint("RIGHT", -8, 0)
	row.text:SetJustifyH("LEFT")
	row.text:SetWordWrap(false)
	return row
end

local function createFrame()
	frame = CreateFrame("Frame", "TrueParseBreakdown", UIParent, "BackdropTemplate")
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0, 0, 0, 0.75)
	frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	frame:SetWidth(WIDTH)
	frame:SetClampedToScreen(true)
	frame:SetFrameStrata("DIALOG")
	frame:Hide()

	frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	frame.close:SetPoint("TOPRIGHT", 2, 2)
	frame.close:SetScript("OnClick", function()
		frame:Hide()
		Panel.currentGUID = nil
	end)

	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.title:SetPoint("TOPLEFT", 10, -8)

	frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.subtitle:SetPoint("TOPLEFT", 10, -24)

	frame.total = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.total:SetPoint("BOTTOMLEFT", 10, 10)
end

local function getRow(i, y)
	local row = rows[i]
	if not row then
		row = newRow(frame)
		rows[i] = row
	end
	row:ClearAllPoints()
	row:SetPoint("TOPLEFT", 0, y)
	row:Show()
	return row
end

local function hideRowsFrom(i)
	for j = i, #rows do
		rows[j]:Hide()
		rows[j].tooltipData = nil
	end
end

-- Full numeric derivation, shown on hover
local function buildMetricTooltip(key, b, duration)
	local label = TP.METRIC_LABELS[key] or key
	local lines = {}
	local value = b.value or 0

	if COUNT_METRICS[key] then
		lines[#lines + 1] = { ("%d this fight."):format(value), 1, 1, 1 }
	elseif duration and duration > 0 then
		lines[#lines + 1] = { ("%s total · %s per second over %d:%02d."):format(
			TP.FormatNumber(value), TP.FormatNumber(value / duration),
			math.floor(duration / 60), duration % 60), 1, 1, 1 }
	else
		lines[#lines + 1] = { ("%s total."):format(TP.FormatNumber(value)), 1, 1, 1 }
	end

	if b.absolute then
		local anchor = TP.Scoring.Weights.absoluteAnchor or 1
		lines[#lines + 1] = { ("WCL %d: you produced %d%% of the elite-logs median for your spec on this fight (gear-adjusted; 100 points at %d%%)."):format(
			b.absolute, b.absolute * anchor, anchor * 100), 0.4, 0.75, 1 }
	end
	if b.relative then
		lines[#lines + 1] = { ("Group %d: compared against the best of your role in this group (spec and gear adjusted)."):format(b.relative), 0.8, 0.8, 0.8 }
	end
	if b.absolute and b.relative then
		local blend = (TP.Scoring.Weights.absoluteBlend or 0) * 100
		lines[#lines + 1] = { ("Score %d = %d%% WCL + %d%% group."):format(b.normalized or 0, blend, 100 - blend), 1, 0.82, 0.2 }
	end
	lines[#lines + 1] = { ("Counts for %d%% of your grade after redistribution → %.1f points."):format(
		(b.effectiveWeight or 0) * 100, b.contribution or 0), 0.7, 0.7, 0.7 }

	return { title = label, lines = lines }
end

local PENALTY_HELP = {
	avoidable = "You took more than an equal share of the group's avoidable damage. Capped at -15.",
	deaths = "Deaths subtract up to -20. Dying late in a fight costs much less than dying early.",
	buffs = "Your class's raid buff wasn't on the whole group when the pull started. Capped at -5.",
}

function Panel:ShowFor(fight, result)
	if not frame then
		createFrame()
	end

	local cr, cg, cb = TP.ClassColor(result.class)
	frame.title:SetText(result.name or "?")
	frame.title:SetTextColor(cr, cg, cb)
	frame.subtitle:SetText(("%s · %s"):format(fight.name or "Fight", result.role))

	local myAwards = TP.Scoring.Awards.Compute(fight)[result.guid]
	local bullets = TP.Scoring.Bullets.ForResult(result, myAwards)

	local y = FIRST_ROW_Y
	for i, bullet in ipairs(bullets) do
		local row = getRow(i, y)
		y = y - ROW_HEIGHT
		row.symbol:SetText(bullet.symbol)
		row.symbol:SetTextColor(bullet.color[1], bullet.color[2], bullet.color[3])
		row.text:SetText(bullet.text)
		row.text:SetTextColor(bullet.color[1], bullet.color[2], bullet.color[3])

		if bullet.kind == "metric" then
			row.tooltipData = buildMetricTooltip(bullet.key, result.breakdown[bullet.key], fight.duration)
		elseif bullet.kind == "penalty" then
			row.tooltipData = { title = bullet.text, lines = { { PENALTY_HELP[bullet.key] or "", 0.95, 0.5, 0.5 } } }
		else
			row.tooltipData = { title = bullet.text, lines = { { "Fight award — earned, not given.", 1, 0.82, 0.2 } } }
		end
	end

	hideRowsFrom(#bullets + 1)

	local grade = TP.Scoring.Grades.ForScore(result.score)
	local gr, gg, gb = TP.Scoring.Grades.Color(grade)
	frame.total:SetText(("Grade |cff%02x%02x%02x%s|r · Score %.1f (base %.1f%s)"):format(
		gr * 255, gg * 255, gb * 255, grade, result.score, result.base,
		result.penalty > 0 and (", penalties -%.1f"):format(result.penalty) or ""))

	frame:SetHeight(-y + ROW_HEIGHT + 34)

	local anchor = _G.TrueParseWindow
	frame:ClearAllPoints()
	if anchor then
		frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
	else
		frame:SetPoint("CENTER")
	end
	frame:Show()
	self.currentGUID = result.guid
end

function Panel:Toggle(fight, result)
	if frame and frame:IsShown() and self.currentGUID == result.guid then
		frame:Hide()
		self.currentGUID = nil
	else
		self:ShowFor(fight, result)
	end
end

-- Called when the scorecard re-renders for a newly captured fight: follow
-- the same player into the new results, or close if they're absent.
function Panel:OnFightRendered(fight, results)
	if not frame or not frame:IsShown() or not self.currentGUID then
		return
	end
	for _, r in ipairs(results) do
		if r.guid == self.currentGUID then
			self:ShowFor(fight, r)
			return
		end
	end
	frame:Hide()
	self.currentGUID = nil
end
