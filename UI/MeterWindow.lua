-- The main TrueParse window. Primary view: post-fight SCORECARD — one row
-- per player with a colored letter grade, sorted by contribution score.
-- Until the first fight is captured it falls back to a live damage view
-- (Blizzard session data), and Classic clients use the CLEU segment view.
local _, TP = ...

local MeterWindow = {}
TP.MeterWindow = MeterWindow

local HEADER_HEIGHT = 22
local PADDING = 6
local SCORECARD_ROW_HEIGHT = 14

local window
local activeBars = {}
local activeRows = {}
local sortScratch = {}
local lastDrawnRevision = -1
local lastRenderedFight
local autoCollapsed = false -- runtime combat collapse, separate from the saved toggle

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
	-- Bound by the title so long fight names truncate instead of overlapping
	window.subtitle:SetPoint("LEFT", window.title, "RIGHT", 6, 0)
	window.subtitle:SetJustifyH("RIGHT")
	window.subtitle:SetWordWrap(false)

	-- Title bar: click toggles collapse, drag moves (rows eat mouse below)
	window.headerButton = CreateFrame("Button", nil, window)
	window.headerButton:SetPoint("TOPLEFT", 0, 0)
	window.headerButton:SetPoint("TOPRIGHT", 0, 0)
	window.headerButton:SetHeight(HEADER_HEIGHT)
	window.headerButton:RegisterForDrag("LeftButton")
	window.headerButton:SetScript("OnDragStart", function()
		if not db().window.locked then
			window:StartMoving()
		end
	end)
	window.headerButton:SetScript("OnDragStop", function()
		window:StopMovingOrSizing()
		savePosition()
	end)
	window.headerButton:SetScript("OnClick", function()
		MeterWindow:ToggleCollapse()
	end)
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
		-- Retail shows no live data mid-fight, so give the screen back;
		-- Classic keeps its live bars.
		if TP.Segments.current and db().window.autoCollapse and TP.BlizzardMeter.available then
			autoCollapsed = true
		end
		MeterWindow:Refresh(true)
	end)
	TP.Addon:RegisterMessage("TrueParse_FIGHT_CAPTURED", function()
		autoCollapsed = false
		MeterWindow:Refresh(true)
	end)
	TP.Addon:ScheduleRepeatingTimer(function()
		MeterWindow:Refresh(false)
	end, 0.5)
	self:Refresh(true)
end

-- Resize while keeping the on-screen edge stable: a window in the top half
-- of the screen stays pinned at its top and grows downward; in the bottom
-- half it stays pinned at its bottom and grows upward.
local function applyWindowHeight(newHeight)
	local left, top, bottom = window:GetLeft(), window:GetTop(), window:GetBottom()
	local _, centerY = window:GetCenter()
	local screenH = UIParent:GetHeight()
	window:SetHeight(newHeight)
	if not (left and top and bottom and centerY and screenH) then
		return
	end
	window:ClearAllPoints()
	if centerY >= screenH / 2 then
		window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
	else
		window:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
	end
end

local function setWindowHeight(shown, rowHeight)
	applyWindowHeight(HEADER_HEIGHT + math.max(shown, 1) * (rowHeight + 1) + PADDING * 2)
end

-- ========================= Scorecard (primary) =========================

function MeterWindow:RenderScorecard(fight)
	local duration = fight.duration or 0
	local label = ("%s · %d:%02d"):format(fight.name or "Fight", math.floor(duration / 60), duration % 60)
	if TP.Addon.db.profile.scoring.mode == "parse" then
		label = "|cff66ccffparse|r · " .. label
	end
	if fight.wipe then
		label = "|cffe64d4dwipe|r · " .. label
	end
	if UnitAffectingCombat("player") then
		label = label .. " |cffff8888· fighting…|r"
	end

	window.subtitle:SetText(label)
	if lastRenderedFight == fight then
		return -- scores are static once captured; only the subtitle changes
	end
	lastRenderedFight = fight
	releaseAllBars()

	local results = TP.Scoring.Engine.ScoreFight(fight, TP.GetDisplayScoringOptions())
	local awards = TP.Scoring.Awards.Compute(fight)
	local conf = db().bars
	local rowHeight = SCORECARD_ROW_HEIGHT
	local shown = math.min(#results, conf.max)
	local width = db().window.width - PADDING * 2
	local hasFooter = #results >= 3
	local totalRows = shown + (hasFooter and 1 or 0)

	for i = #activeRows, totalRows + 1, -1 do
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
		local gcr, gcg, gcb = TP.Scoring.Grades.Color(grade, r.score)
		row.grade:SetText(grade)
		row.grade:SetTextColor(gcr, gcg, gcb)

		-- Players not running TrueParse render dimmed: less data, not worse.
		-- The local player always has the addon (fights captured before the
		-- presence stamp existed rely on the isLocalPlayer fallback).
		local player = fight.players[r.guid]
		local hasAddon = player and (player.hasAddon or player.isLocalPlayer)
		local alpha = hasAddon and 1 or 0.55
		row.grade:SetAlpha(alpha)
		row.name:SetAlpha(alpha)
		row.score:SetAlpha(alpha)
		row.penalty:SetAlpha(alpha)

		local myAwards = awards[r.guid]
		row.name:SetText(myAwards and (r.name .. " " .. TP.STAR) or r.name)
		row.name:SetTextColor(TP.ClassColor(r.class))
		row.playerName = r.name

		row.score:SetText(("%.0f"):format(r.score))
		row.score:SetTextColor(gcr, gcg, gcb)
		row.penalty:SetText(r.penalty > 0 and ("|cffff4444-%.0f|r"):format(r.penalty) or "")

		row.baseBg = nil
		row.bg:SetColorTexture(1, 1, 1, 0.04)
		row.fight = fight
		row.result = r
		row.groupResults = nil
	end

	-- Footer: the collective grade, visually distinct from player rows
	if hasFooter then
		local sum = 0
		for _, r in ipairs(results) do
			sum = sum + r.score
		end
		local groupScore = sum / #results
		local groupGrade = TP.Scoring.Grades.ForScore(groupScore)

		local row = activeRows[totalRows]
		if not row then
			row = TP.Scorecard:Acquire(window)
			activeRows[totalRows] = row
		end
		row:SetSize(width, rowHeight)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", PADDING, -(HEADER_HEIGHT + (totalRows - 1) * (rowHeight + 1)))

		local ggr, ggg, ggb = TP.Scoring.Grades.Color(groupGrade, groupScore)
		row.grade:SetText(groupGrade)
		row.grade:SetTextColor(ggr, ggg, ggb)
		row.grade:SetAlpha(1)
		row.name:SetAlpha(1)
		row.score:SetAlpha(1)
		row.penalty:SetAlpha(1)
		local label = (#results > 5) and "Raid" or "Group"
		row.name:SetText(label)
		row.name:SetTextColor(1, 0.82, 0.2)
		row.score:SetText(("%.0f"):format(groupScore))
		row.score:SetTextColor(ggr, ggg, ggb)
		row.penalty:SetText("")
		row.baseBg = { 1, 0.82, 0.2, 0.10 }
		row.bg:SetColorTexture(1, 0.82, 0.2, 0.10)
		row.playerName = label
		row.fight = fight
		row.result = nil
		row.groupResults = results -- click opens the group breakdown
	end

	setWindowHeight(totalRows, rowHeight)
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
	lastRenderedFight = nil

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

function MeterWindow:ToggleCollapse()
	if autoCollapsed or db().window.collapsed then
		autoCollapsed = false
		db().window.collapsed = false
	else
		db().window.collapsed = true
	end
	self:Invalidate()
end

function MeterWindow:Refresh(force)
	if not window or not window:IsShown() then
		return
	end
	if db().window.collapsed or autoCollapsed then
		releaseAllRows()
		releaseAllBars()
		lastRenderedFight = nil
		window.title:SetText("TrueParse (+)")
		local latest = TP.FightHistory.fights[1]
		if latest then
			window.subtitle:SetText(("%s · %d:%02d"):format(
				latest.name or "Fight", math.floor((latest.duration or 0) / 60), (latest.duration or 0) % 60))
		else
			window.subtitle:SetText("")
		end
		applyWindowHeight(HEADER_HEIGHT + PADDING)
		return
	end
	window.title:SetText("TrueParse")
	local fight = TP.FightHistory.fights[1]
	if TP.BlizzardMeter.available then
		if fight then
			self:RenderScorecard(fight)
		else
			self:RefreshFromBlizzardMeter()
		end
	else
		-- Classic: live damage bars while fighting, scorecard after
		if TP.Segments.current or not fight then
			self:RefreshFromSegments(force)
		else
			self:RenderScorecard(fight)
		end
	end
end
