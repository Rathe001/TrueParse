-- Click-to-breakdown panel: shows exactly how one player's grade was built.
-- One row per metric (raw value, normalized 0-100, effective weight, points
-- contributed), greyed rows for inapplicable metrics whose weight was
-- redistributed, penalty lines, and the final score + grade.
local _, TP = ...

local Panel = {}
TP.BreakdownPanel = Panel

local WIDTH = 360
local ROW_HEIGHT = 15
local HEADER_Y = -40

local METRIC_ORDER = { "damage", "healing", "damageTaken", "interrupts", "dispels" }

-- x offset, width, justify for each column
local COLUMNS = {
	label = { 10, 115, "LEFT" },
	raw = { 125, 70, "RIGHT" },
	norm = { 195, 40, "RIGHT" },
	wt = { 235, 45, "RIGHT" },
	pts = { 280, 66, "RIGHT" },
}

local frame
local rows = {}

local function makeCell(parent, col, y, font)
	local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
	local x, width, justify = COLUMNS[col][1], COLUMNS[col][2], COLUMNS[col][3]
	fs:SetPoint("TOPLEFT", x, y)
	fs:SetWidth(width)
	fs:SetJustifyH(justify)
	return fs
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

	-- column headers
	frame.headers = {}
	local headerLabels = { label = "Metric", raw = "Raw", norm = "Score", wt = "Weight", pts = "Points" }
	for col, text in pairs(headerLabels) do
		local h = makeCell(frame, col, HEADER_Y, "GameFontDisableSmall")
		h:SetText(text)
		frame.headers[col] = h
	end

	frame.total = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.total:SetPoint("BOTTOMLEFT", 10, 10)
end

local function getRow(i, y)
	local row = rows[i]
	if not row then
		row = {
			label = makeCell(frame, "label", 0),
			raw = makeCell(frame, "raw", 0),
			norm = makeCell(frame, "norm", 0),
			wt = makeCell(frame, "wt", 0),
			pts = makeCell(frame, "pts", 0),
		}
		rows[i] = row
	end
	for col, fs in pairs(row) do
		fs:ClearAllPoints()
		fs:SetPoint("TOPLEFT", COLUMNS[col][1], y)
		fs:Show()
	end
	return row
end

local function setRowColor(row, r, g, b)
	for _, fs in pairs(row) do
		fs:SetTextColor(r, g, b)
	end
end

local function hideRowsFrom(i)
	for j = i, #rows do
		for _, fs in pairs(rows[j]) do
			fs:Hide()
		end
	end
end

function Panel:ShowFor(fight, result)
	if not frame then
		createFrame()
	end

	local cr, cg, cb = TP.ClassColor(result.class)
	frame.title:SetText(result.name or "?")
	frame.title:SetTextColor(cr, cg, cb)
	frame.subtitle:SetText(("%s · %s"):format(fight.name or "Fight", result.role))

	local y = HEADER_Y - ROW_HEIGHT
	local used = 0

	for _, key in ipairs(METRIC_ORDER) do
		local b = result.breakdown[key]
		if b then
			used = used + 1
			local row = getRow(used, y)
			y = y - ROW_HEIGHT
			row.label:SetText(TP.METRIC_LABELS[key] or key)
			row.raw:SetText(TP.FormatNumber(b.value or 0))
			if b.applicable then
				row.norm:SetText(("%.0f"):format(b.normalized or 0))
				row.wt:SetText(("%.0f%%"):format((b.effectiveWeight or 0) * 100))
				row.pts:SetText(("%.1f"):format(b.contribution or 0))
				setRowColor(row, 0.92, 0.92, 0.92)
			else
				row.norm:SetText("—")
				row.wt:SetText("n/a")
				row.pts:SetText("—")
				setRowColor(row, 0.45, 0.45, 0.45)
			end
		end
	end

	local pd = result.penaltyDetail or {}
	local function penaltyRow(label, amount)
		if amount and amount > 0 then
			used = used + 1
			local row = getRow(used, y)
			y = y - ROW_HEIGHT
			row.label:SetText(label)
			row.raw:SetText("")
			row.norm:SetText("")
			row.wt:SetText("")
			row.pts:SetText(("-%.1f"):format(amount))
			setRowColor(row, 0.95, 0.35, 0.35)
		end
	end
	penaltyRow("Avoidable damage", pd.avoidable)
	penaltyRow("Deaths", pd.deaths)

	hideRowsFrom(used + 1)

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
