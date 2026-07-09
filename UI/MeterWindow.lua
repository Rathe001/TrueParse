-- The main TrueParse window. Primary view: post-fight SCORECARD — one row
-- per player with a colored letter grade, sorted by contribution score.
-- Until the first fight is captured it falls back to a live damage view
-- (Blizzard session data), and Classic clients use the CLEU segment view.
local _, TP = ...

local MeterWindow = {}
TP.MeterWindow = MeterWindow

local HEADER_HEIGHT = 22
local MODE_HEIGHT = 16 -- bottom strip: Mode: (*)Real ( )Raw
local PADDING = 6
local SCORECARD_ROW_HEIGHT = 14

local window
local activeBars = {}
local activeRows = {}
local sortScratch = {}
local lastDrawnRevision = -1
local lastRenderedFight
local autoCollapsed = false -- runtime combat collapse, separate from the saved toggle
local viewOffset = 0 -- fight-history browsing: 0 = latest capture

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

-- Shared drag handlers: every draggable region uses these so the dragging
-- flag stays accurate (applyWindowHeight must never re-anchor mid-drag —
-- it would snap the frame away from the cursor)
local isDragging = false

-- Re-anchor to a plain TOPLEFT point at the frame's exact current screen
-- rect. The window's anchor shape varies with history (saved CENTER from
-- the DB, TOPLEFT after a collapse, whatever StopMovingOrSizing chose) and
-- StartMoving on a mismatched anchor is the classic grab-point teleport.
local function normalizeAnchor()
	local left, top = window:GetLeft(), window:GetTop()
	if left and top then
		window:ClearAllPoints()
		window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
	end
end

local function startDrag()
	if not db().window.locked then
		isDragging = true
		normalizeAnchor()
		window:StartMoving()
	end
end
local function stopDrag()
	if isDragging then
		isDragging = false
		window:StopMovingOrSizing()
		normalizeAnchor()
		savePosition()
	end
end

local function createWindow()
	window = CreateFrame("Frame", "TrueParseWindow", UIParent, "BackdropTemplate")
	window:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	window:SetBackdropColor(0, 0, 0, 0.85)
	window:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	window:SetSize(db().window.width, 100)
	window:SetClampedToScreen(true)
	window:SetMovable(true)
	window:EnableMouse(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", startDrag)
	window:SetScript("OnDragStop", stopDrag)

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
	window.headerButton:SetScript("OnDragStart", startDrag)
	window.headerButton:SetScript("OnDragStop", stopDrag)
	window.headerButton:SetScript("OnClick", function()
		MeterWindow:ToggleCollapse()
	end)

	-- Fight browser: the subtitle is a button — click steps to the previous
	-- (older) fight, right-click back toward the latest. Hidden while
	-- collapsed (the header click is collapse/expand there).
	window.subtitleButton = CreateFrame("Button", nil, window)
	window.subtitleButton:SetAllPoints(window.subtitle)
	window.subtitleButton:SetFrameLevel(window.headerButton:GetFrameLevel() + 1)
	window.subtitleButton:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	window.subtitleButton:RegisterForDrag("LeftButton")
	window.subtitleButton:SetScript("OnDragStart", startDrag)
	window.subtitleButton:SetScript("OnDragStop", stopDrag)
	window.subtitleButton:SetScript("OnClick", function(_, button)
		MeterWindow:StepFight(button == "RightButton" and -1 or 1)
	end)
	window.subtitleButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:SetText("Fight history")
		GameTooltip:AddLine("Click: older fight", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("Right-click: back toward the latest", 0.8, 0.8, 0.8)
		GameTooltip:AddLine("New captures snap back to the latest.", 0.5, 0.5, 0.5)
		GameTooltip:Show()
	end)
	window.subtitleButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	-- Mode strip along the bottom edge: Real = the full contribution score,
	-- Raw = pure throughput vs WCL top logs (damage, healing for healers)
	local function makeRadio(labelText, mode, tooltip)
		local btn = CreateFrame("CheckButton", nil, window)
		btn:SetSize(14, 14)
		btn:SetNormalTexture("Interface\\Buttons\\UI-RadioButton")
		btn:GetNormalTexture():SetTexCoord(0, 0.25, 0, 1)
		btn:SetCheckedTexture("Interface\\Buttons\\UI-RadioButton")
		btn:GetCheckedTexture():SetTexCoord(0.25, 0.5, 0, 1)
		btn:SetHighlightTexture("Interface\\Buttons\\UI-RadioButton")
		btn:GetHighlightTexture():SetTexCoord(0.5, 0.75, 0, 1)
		btn.label = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		btn.label:SetPoint("LEFT", btn, "RIGHT", 1, 0)
		btn.label:SetText(labelText)
		btn:SetScript("OnClick", function()
			db().scoring.mode = mode
			MeterWindow:UpdateModeButtons()
			MeterWindow:Invalidate()
		end)
		btn:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:SetText(labelText)
			GameTooltip:AddLine(tooltip, 0.8, 0.8, 0.8, true)
			GameTooltip:Show()
		end)
		btn:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		return btn
	end
	window.modeLabel = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	window.modeLabel:SetPoint("BOTTOMLEFT", PADDING + 2, 6)
	window.modeLabel:SetText("Mode:")
	window.modeReal = makeRadio("True", "contribution",
		"The full TrueParse score: damage, healing, kicks, dispels, soaking, minus penalties. What careers and run reports use.")
	window.modeReal:SetPoint("LEFT", window.modeLabel, "RIGHT", 5, 0)
	window.modeRaw = makeRadio("Raw", "parse",
		"Straight comparison to top Warcraft Logs parses for your spec on this fight: damage for DPS and tanks, healing for healers. Nothing else counts.")
	window.modeRaw:SetPoint("LEFT", window.modeReal.label, "RIGHT", 12, 0)
	MeterWindow:UpdateModeButtons()
end

function MeterWindow:UpdateModeButtons()
	if not (window and window.modeReal) then
		return
	end
	local raw = db().scoring.mode == "parse"
	window.modeReal:SetChecked(not raw)
	window.modeRaw:SetChecked(raw)
end

local function setModeStripShown(shown)
	if not (window and window.modeReal) then
		return
	end
	window.modeLabel:SetShown(shown)
	window.modeReal:SetShown(shown)
	window.modeReal.label:SetShown(shown)
	window.modeRaw:SetShown(shown)
	window.modeRaw.label:SetShown(shown)
end

-- Force the next refresh to re-render (e.g. after a scoring option change)
function MeterWindow:Invalidate()
	lastRenderedFight = nil
	self:Refresh(true)
end

-- Step through captured fights: positive = older, negative = toward latest
function MeterWindow:StepFight(delta)
	local count = #TP.FightHistory.fights
	if count == 0 then
		return
	end
	viewOffset = math.max(0, math.min(count - 1, viewOffset + delta))
	self:Invalidate()
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
		viewOffset = 0 -- a fresh capture always snaps the view to the latest
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
-- pinTop forces top-edge pinning: used when COLLAPSING, so the title bar
-- stays exactly where it was clicked. Bottom-pinning a collapse used to
-- drop the bar to the window's old bottom edge — straight under hotbars,
-- where their frames eat the clicks and the window becomes unreachable.
local function applyWindowHeight(newHeight, pinTop)
	-- No-op when nothing changes (the 0.5s refresh calls this constantly),
	-- and never re-anchor mid-drag — SetPoint during StartMoving snaps the
	-- frame away from the cursor.
	if isDragging or math.abs(window:GetHeight() - newHeight) < 0.5 then
		window:SetHeight(newHeight)
		return
	end
	local left, top, bottom = window:GetLeft(), window:GetTop(), window:GetBottom()
	local _, centerY = window:GetCenter()
	local screenH = UIParent:GetHeight()
	window:SetHeight(newHeight)
	if not (left and top and bottom and centerY and screenH) then
		return
	end
	window:ClearAllPoints()
	if pinTop or centerY >= screenH / 2 then
		window:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
	else
		window:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
	end
end

local function setWindowHeight(shown, rowHeight)
	setModeStripShown(true)
	applyWindowHeight(HEADER_HEIGHT + math.max(shown, 1) * (rowHeight + 1) + MODE_HEIGHT + PADDING * 2)
end

-- ========================= Scorecard (primary) =========================

-- Spec icon for a row: the capture's own specIconID (retail sessions carry
-- it), then the inspected/synced specID's icon, then the class crest.
local ICON_CROP = 0.07
local function setSpecIcon(icon, player, class)
	local fileID = player and player.specIconID
	if not fileID and player and player.specID and GetSpecializationInfoByID then
		local ok, _, _, _, specIcon = pcall(GetSpecializationInfoByID, player.specID)
		if ok then
			fileID = specIcon
		end
	end
	if fileID then
		icon:SetTexture(fileID)
		icon:SetTexCoord(ICON_CROP, 1 - ICON_CROP, ICON_CROP, 1 - ICON_CROP)
		icon:Show()
		return
	end
	if class and CLASS_ICON_TCOORDS and CLASS_ICON_TCOORDS[class] then
		icon:SetTexture("Interface\\WorldStateFrame\\Icons-Classes")
		icon:SetTexCoord(unpack(CLASS_ICON_TCOORDS[class]))
		icon:Show()
		return
	end
	icon:Hide()
end

function MeterWindow:RenderScorecard(fight)
	local duration = fight.duration or 0
	local label = ("%s · %d:%02d"):format(fight.name or "Fight", math.floor(duration / 60), duration % 60)
	if viewOffset > 0 then
		label = ("|cffaaaaaa%d/%d|r · "):format(viewOffset + 1, #TP.FightHistory.fights) .. label
	end
	if TP.Addon.db.profile.scoring.mode == "parse" then
		label = "|cff66ccffraw|r · " .. label
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

		local gcr, gcg, gcb = TP.Scoring.Grades.ColorForScore(r.score)

		-- Players not running TrueParse render dimmed: less data, not worse.
		-- The local player always has the addon (fights captured before the
		-- presence stamp existed rely on the isLocalPlayer fallback).
		local player = fight.players[r.guid]
		local hasAddon = player and (player.hasAddon or player.isLocalPlayer)
		row.name:SetAlpha(1)
		row.score:SetAlpha(1)
		row.penalty:SetAlpha(1)
		row.icon:SetAlpha(hasAddon and 1 or 0.7)

		-- Details-style: the row IS a solid class-colored bar with a white
		-- outlined name. Non-addon players get the color MUTED (washed
		-- toward grey), never transparency - transparency stacked with the
		-- window backdrop made whole pug scorecards unreadable.
		local cr, cg, cb = TP.ClassColor(r.class)
		if not hasAddon then
			cr = cr * 0.4 + 0.22
			cg = cg * 0.4 + 0.22
			cb = cb * 0.4 + 0.22
		end
		row.bg:SetColorTexture(cr, cg, cb, 0.95)
		row.bg:SetWidth(math.max(8, width * math.min(math.max(r.score, 0), 100) / 100))
		row.icon:SetWidth(rowHeight)
		setSpecIcon(row.icon, player, r.class)

		local myAwards = awards[r.guid]
		row.name:SetText(myAwards and (r.name .. " " .. TP.STAR) or r.name)
		row.name:SetTextColor(1, 1, 1)
		row.playerName = r.name

		row.score:SetText(("%.0f"):format(r.score))
		row.score:SetTextColor(gcr, gcg, gcb)
		row.penalty:SetText(r.penalty > 0 and ("|cffff4444-%.0f|r"):format(r.penalty) or "")

		row.fight = fight
		row.result = r
		row.groupResults = nil
	end

	-- Footer: the collective score, visually distinct from player rows
	if hasFooter then
		local sum = 0
		for _, r in ipairs(results) do
			sum = sum + r.score
		end
		local groupScore = sum / #results

		local row = activeRows[totalRows]
		if not row then
			row = TP.Scorecard:Acquire(window)
			activeRows[totalRows] = row
		end
		row:SetSize(width, rowHeight)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", PADDING, -(HEADER_HEIGHT + (totalRows - 1) * (rowHeight + 1)))

		local ggr, ggg, ggb = TP.Scoring.Grades.ColorForScore(groupScore)
		row.name:SetAlpha(1)
		row.score:SetAlpha(1)
		row.penalty:SetAlpha(1)
		row.icon:SetAlpha(1)
		local label = (#results > 5) and "Raid" or "Group"
		row.name:SetText(label)
		row.name:SetTextColor(1, 1, 1)
		row.score:SetText(("%.0f"):format(groupScore))
		row.score:SetTextColor(ggr, ggg, ggb)
		row.penalty:SetText("")
		row.bg:SetColorTexture(0.60, 0.48, 0.10, 0.95)
		row.bg:SetWidth(math.max(8, width * math.min(math.max(groupScore, 0), 100) / 100))
		row.icon:Hide()
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

-- Collapsed, the title bar still leads with the numbers that matter: your
-- score and the group's. They go FIRST so truncation eats the fight name.
-- Cached per fight+options: this runs on the 0.5s refresh timer.
local collapsedCache = {}
local function collapsedSummary(fight)
	local opts = TP.GetDisplayScoringOptions()
	local key = tostring(opts.mode) .. ":" .. tostring(opts.normalizeIlvl)
	if collapsedCache.fight ~= fight or collapsedCache.key ~= key then
		collapsedCache.fight, collapsedCache.key = fight, key
		local results = TP.Scoring.Engine.ScoreFight(fight, opts)
		local myGUID = UnitGUID("player")
		local sum, mine = 0, nil
		for _, r in ipairs(results) do
			sum = sum + r.score
			if r.guid == myGUID then
				mine = r
			end
		end
		local parts = {}
		if mine then
			parts[#parts + 1] = TP.Scoring.Grades.ColoredScore(mine.score) .. " you"
		end
		if #results > 1 then
			parts[#parts + 1] = TP.Scoring.Grades.ColoredScore(sum / #results)
				.. ((#results > 5) and " raid" or " group")
		end
		collapsedCache.prefix = table.concat(parts, " · ")
	end
	local tail = ("%s · %d:%02d"):format(fight.name or "Fight",
		math.floor((fight.duration or 0) / 60), (fight.duration or 0) % 60)
	if collapsedCache.prefix ~= "" then
		return collapsedCache.prefix .. " · " .. tail
	end
	return tail
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
			window.subtitle:SetText(collapsedSummary(latest))
		else
			window.subtitle:SetText("")
		end
		window.subtitleButton:Hide()
		setModeStripShown(false)
		applyWindowHeight(HEADER_HEIGHT + PADDING, true)
		return
	end
	window.title:SetText("TrueParse")
	window.subtitleButton:Show()
	local fights = TP.FightHistory.fights
	local fight = fights[1 + viewOffset] or fights[1]
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
