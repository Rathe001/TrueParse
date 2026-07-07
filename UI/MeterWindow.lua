-- The main TrueParse window. Primary view: post-fight SCORECARD — one row
-- per player with a colored letter grade, sorted by contribution score.
-- Until the first fight is captured it falls back to a live damage view
-- (Blizzard session data), and Classic clients use the CLEU segment view.
local _, TP = ...

local MeterWindow = {}
TP.MeterWindow = MeterWindow

local HEADER_HEIGHT = 22
local PADDING = 6

local window
local activeBars = {}
local activeRows = {}
local sortScratch = {}
local lastDrawnRevision = -1
local lastRenderedFight

local function db()
	return TP.Addon.db.profile
end

local function releaseAllBars()
	for i = #activeBars, 1, -1 do
		TP.Bars:Release(activeBars[i])
		activeBars[i] = nil
	end
end

local function releaseAllRows()
	for i = #activeRows, 1, -1 do
		TP.Scorecard:Release(activeRows[i])
		activeRows[i] = nil
	end
end

local function savePosition()
	local w = db().window
	local point, _, relPoint, x, y = window:GetPoint(1)
	w.point, w.relPoint, w.x, w.y = point, relPoint, x, y
end

local function createWindow()
	window = CreateFrame("Frame", "TrueParseWindow", UIParent, "BackdropTemplate")
	window:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	window:SetBackdropColor(0, 0, 0, 0.6)
	window:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	window:SetSize(db().window.width, 100)
	window:SetClampedToScreen(true)
	window:SetMovable(true)
	window:EnableMouse(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", function(self)
		if not db().window.locked then
			self:StartMoving()
		end
	end)
	window:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		savePosition()
	end)

	window.title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	window.title:SetPoint("TOPLEFT", PADDING, -PADDING)
	window.title:SetText("TrueParse")

	window.subtitle = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	window.subtitle:SetPoint("TOPRIGHT", -PADDING, -PADDING)
end

-- Force the next refresh to re-render (e.g. after a scoring option change)
function MeterWindow:Invalidate()
	lastRenderedFight = nil
	self:Refresh(true)
end

function MeterWindow:ApplyPosition()
	local w = db().window
	window:ClearAllPoints()
	window:SetPoint(w.point, UIParent, w.relPoint, w.x, w.y)
end

function MeterWindow:Toggle()
	if window:IsShown() then
		window:Hide()
		db().window.shown = false
	else
		window:Show()
		db().window.shown = true
		self:Refresh(true)
	end
end

function MeterWindow:OnEnable()
	createWindow()
	self:ApplyPosition()
	if db().window.shown then
		window:Show()
	else
		window:Hide()
	end

	TP.Addon:RegisterMessage("TrueParse_SEGMENT_CHANGED", function()
		MeterWindow:Refresh(true)
	end)
	TP.Addon:RegisterMessage("TrueParse_FIGHT_CAPTURED", function()
		MeterWindow:Refresh(true)
	end)
	TP.Addon:ScheduleRepeatingTimer(function()
		MeterWindow:Refresh(false)
	end, 0.5)
	self:Refresh(true)
end

local function setWindowHeight(shown, rowHeight)
	window:SetHeight(HEADER_HEIGHT + math.max(shown, 1) * (rowHeight + 1) + PADDING * 2)
end

-- ========================= Scorecard (primary) =========================

function MeterWindow:RenderScorecard(fight)
	local duration = fight.duration or 0
	local label = ("%s · %d:%02d"):format(fight.name or "Fight", math.floor(duration / 60), duration % 60)
	if UnitAffectingCombat("player") then
		label = label .. " |cffff8888· fighting…|r"
	end
	window.subtitle:SetText(label)

	if lastRenderedFight == fight then
		return -- scores are static once captured; only the subtitle changes
	end
	lastRenderedFight = fight
	releaseAllBars()

	local results = TP.Scoring.Engine.ScoreFight(fight, TP.GetScoringOptions())
	local conf = db().bars
	local rowHeight = conf.height + 2
	local shown = math.min(#results, conf.max)
	local width = db().window.width - PADDING * 2

	for i = #activeRows, shown + 1, -1 do
		TP.Scorecard:Release(activeRows[i])
		activeRows[i] = nil
	end

	for i = 1, shown do
		local r = results[i]
		local row = activeRows[i]
		if not row then
			row = TP.Scorecard:Acquire(window)
			activeRows[i] = row
		end
		row:SetSize(width, rowHeight)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", PADDING, -(HEADER_HEIGHT + (i - 1) * (rowHeight + 1)))

		local grade = TP.Scoring.Grades.ForScore(r.score)
		row.grade:SetText(grade)
		row.grade:SetTextColor(TP.Scoring.Grades.Color(grade))

		row.name:SetText(r.name)
		row.name:SetTextColor(TP.ClassColor(r.class))

		local scoreText = ("%.0f"):format(r.score)
		if r.penalty > 0 then
			scoreText = scoreText .. (" |cffff4444(-%.0f)|r"):format(r.penalty)
		end
		row.score:SetText(scoreText)

		row.fight = fight
		row.result = r
	end

	setWindowHeight(shown, rowHeight)
	TP.BreakdownPanel:OnFightRendered(fight, results)
end

-- ============== Live damage fallback (no fights captured yet) ==============

local function drawBar(i, name, class, fraction, valueText, barWidth, barHeight)
	local bar = activeBars[i]
	if not bar then
		bar = TP.Bars:Acquire(window)
		activeBars[i] = bar
	end
	bar:SetSize(barWidth, barHeight)
	bar:ClearAllPoints()
	bar:SetPoint("TOPLEFT", PADDING, -(HEADER_HEIGHT + (i - 1) * (barHeight + 1)))
	bar:SetValue(fraction)
	local r, g, b = TP.ClassColor(class)
	bar:SetStatusBarColor(r, g, b)
	bar.nameText:SetText(name)
	bar.valueText:SetText(valueText)
end

local function finishBars(shown, barHeight)
	for i = #activeBars, shown + 1, -1 do
		TP.Bars:Release(activeBars[i])
		activeBars[i] = nil
	end
	setWindowHeight(shown, barHeight)
end

local function sortByTotal(a, b)
	return a.totalAmount > b.totalAmount
end

function MeterWindow:RefreshFromBlizzardMeter()
	local Meter = TP.BlizzardMeter
	local session = Meter:GetSession(Enum.DamageMeterType.DamageDone)
	local conf = db().bars
	releaseAllRows()
	lastRenderedFight = nil

	if Meter:IsLocked(session) then
		window.subtitle:SetText("|cffff8888in combat · live data locked|r")
		finishBars(0, conf.height)
		return
	end

	local duration = math.max(session.durationSeconds or 0, 1)
	window.subtitle:SetText(("Damage · %d:%02d"):format(math.floor(duration / 60), duration % 60))

	wipe(sortScratch)
	local sources = session.combatSources
	for i = 1, #sources do
		local src = sources[i]
		if (src.totalAmount or 0) > 0 then
			sortScratch[#sortScratch + 1] = src
		end
	end
	table.sort(sortScratch, sortByTotal)

	local shown = math.min(#sortScratch, conf.max)
	local top = shown > 0 and sortScratch[1].totalAmount or 1
	local barWidth = db().window.width - PADDING * 2

	for i = 1, shown do
		local src = sortScratch[i]
		drawBar(i, src.name, src.classFilename, src.totalAmount / top,
			("%s (%s)"):format(TP.FormatNumber(src.totalAmount), TP.FormatNumber(src.totalAmount / duration)),
			barWidth, conf.height)
	end
	finishBars(shown, conf.height)
end

-- ================== Classic path: CLEU segment damage ==================

local function sortByDamage(a, b)
	return a.damage.total > b.damage.total
end

function MeterWindow:RefreshFromSegments(force)
	local Segments = TP.Segments
	if not force and not Segments.current and Segments.revision == lastDrawnRevision then
		return
	end
	lastDrawnRevision = Segments.revision
	releaseAllRows()

	local seg = Segments:GetDisplaySegment()
	local duration = Segments:GetDuration(seg)
	window.subtitle:SetText(("%s · %d:%02d"):format(seg.name or "", math.floor(duration / 60), duration % 60))

	wipe(sortScratch)
	for _, acc in pairs(seg.players) do
		if acc.damage.total > 0 then
			sortScratch[#sortScratch + 1] = acc
		end
	end
	table.sort(sortScratch, sortByDamage)

	local conf = db().bars
	local shown = math.min(#sortScratch, conf.max)
	local top = shown > 0 and sortScratch[1].damage.total or 1
	local barWidth = db().window.width - PADDING * 2

	for i = 1, shown do
		local acc = sortScratch[i]
		drawBar(i, acc.name, acc.class, acc.damage.total / top,
			("%s (%s)"):format(TP.FormatNumber(acc.damage.total), TP.FormatNumber(acc.damage.total / duration)),
			barWidth, conf.height)
	end
	finishBars(shown, conf.height)
end

-- ============================== Dispatch ==============================

function MeterWindow:Refresh(force)
	if not window or not window:IsShown() then
		return
	end
	if TP.BlizzardMeter.available then
		local fight = TP.FightHistory.fights[1]
		if fight then
			self:RenderScorecard(fight)
		else
			self:RefreshFromBlizzardMeter()
		end
	else
		self:RefreshFromSegments(force)
	end
end
