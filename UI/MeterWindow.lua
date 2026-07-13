-- The main TrueParse window. Primary view: post-fight SCORECARD — one row
-- per player with a colored letter grade, sorted by contribution score.
-- Until the first fight is captured it falls back to a live damage view
-- (Blizzard session data), and Classic clients use the CLEU segment view.
local _, TP = ...

local MeterWindow = {}
TP.MeterWindow = MeterWindow

local HEADER_HEIGHT = 26
local COLHEAD_HEIGHT = 11 -- thin "fight / run" column labels (scorecard only)
local COL_RESERVE = 78 -- right-side score columns the class bar never enters
local MODE_HEIGHT = 16 -- bottom strip: Mode: (*)Real ( )Raw
local PADDING = 6
local SCORECARD_ROW_HEIGHT = 14

local window
local activeRows = {}
local lastRenderedFight
local autoCollapsed = false -- runtime combat collapse, separate from the saved toggle
-- Fight selection: nil = "Current" (follows new captures and the waiting
-- state). An explicit dropdown pick pins a fight BY REFERENCE, so a new
-- capture inserting at the top never shifts what's on screen.
local pinnedFight

local function db()
	return TP.Addon.db.profile
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
local isSizing = false -- grip drag in progress: layout must not re-anchor
local scrollOffset = 0 -- first visible player row (mouse wheel)
local lastScrollOffset = -1

-- Scored-result memos (weak keyed by fight/run record). Declared HERE
-- because Invalidate wipes them and compiles above their users — a later
-- declaration makes earlier references nil globals (the blank-window bug).
local displayCache = setmetatable({}, { __mode = "k" })
local runScoreCache = setmetatable({}, { __mode = "k" })

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
		-- WHITE8x8: truly solid. The tooltip gradient texture reads
		-- translucent over bright rooms no matter the alpha.
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	window:SetBackdropColor(0.04, 0.04, 0.05, 1)
	window:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	window:SetSize(db().window.width, 100)
	window:SetClampedToScreen(true)
	window:SetMovable(true)
	window:EnableMouse(true)
	window:RegisterForDrag("LeftButton")
	window:SetScript("OnDragStart", startDrag)
	window:SetScript("OnDragStop", stopDrag)

	-- Resizable: the grip owns width AND height; rows render into whatever
	-- fits and the wheel scrolls the rest
	window:SetResizable(true)
	if window.SetResizeBounds then
		window:SetResizeBounds(180, 110, 640, 1000)
	elseif window.SetMinResize then
		window:SetMinResize(180, 110)
		window:SetMaxResize(640, 1000)
	end
	local grip = CreateFrame("Button", nil, window)
	grip:SetSize(16, 16)
	grip:SetPoint("BOTTOMRIGHT", -1, 1)
	grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
	grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
	grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
	grip:SetScript("OnMouseDown", function()
		if db().window.locked or db().window.collapsed or autoCollapsed then
			return
		end
		isSizing = true
		normalizeAnchor()
		window:StartSizing("BOTTOMRIGHT")
	end)
	grip:SetScript("OnMouseUp", function()
		if not isSizing then
			return
		end
		isSizing = false
		window:StopMovingOrSizing()
		normalizeAnchor()
		local w = db().window
		w.width = math.floor(window:GetWidth() + 0.5)
		w.height = math.floor(window:GetHeight() + 0.5)
		savePosition()
		MeterWindow:Invalidate()
	end)
	window.grip = grip

	-- Live relayout while the grip drags: rows re-flow every size tick
	-- using CACHED scores (scoreForDisplay/scoreRun memoize), so this is
	-- pure layout work, not engine work
	window:SetScript("OnSizeChanged", function(_, w, h)
		if not isSizing then
			return
		end
		local win = db().window
		win.width = math.floor(w + 0.5)
		win.height = math.floor(h + 0.5)
		lastRenderedFight = nil
		MeterWindow:Refresh(true)
	end)

	-- thin scroll hints above/below the row list (textures, not the
	-- Unicode triangles: Classic fonts tofu'd the award star the same
	-- way). A dark backing pill keeps them visible on bright class bars.
	local function mkArrow(tex)
		local f = CreateFrame("Frame", nil, window)
		f:SetSize(26, 11)
		f:SetFrameLevel(window:GetFrameLevel() + 10)
		local bgTex = f:CreateTexture(nil, "BACKGROUND")
		bgTex:SetAllPoints()
		bgTex:SetColorTexture(0, 0, 0, 0.75)
		local t = f:CreateTexture(nil, "OVERLAY")
		t:SetSize(14, 10)
		t:SetPoint("CENTER", 0, 0)
		t:SetTexture(tex)
		f:Hide()
		return f
	end
	window.scrollUp = mkArrow("Interface\\Buttons\\Arrow-Up-Up")
	window.scrollDown = mkArrow("Interface\\Buttons\\Arrow-Down-Up")

	window:EnableMouseWheel(true)
	window:SetScript("OnMouseWheel", function(_, delta)
		if db().window.collapsed or autoCollapsed then
			return
		end
		-- wheel up = toward the top of the list; upper clamp happens in
		-- RenderScorecard where the visible count is known
		local newOffset = math.max(0, scrollOffset - delta)
		if newOffset ~= scrollOffset then
			scrollOffset = newOffset
			MeterWindow:Refresh(true)
		end
	end)

	window.title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	-- centered in the header band, which is also the whole collapsed bar:
	-- the title must not move when the window toggles
	window.title:SetPoint("LEFT", window, "TOPLEFT", PADDING, -HEADER_HEIGHT / 2)
	window.title:SetText("TrueParse")

	-- The fight picker looks like a real dropdown: bordered inset box with
	-- the classic round arrow button, sized into the header
	window.fightDrop = CreateFrame("Button", nil, window, "BackdropTemplate")
	window.fightDrop:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	window.fightDrop:SetBackdropColor(0, 0, 0, 0.55)
	window.fightDrop:SetBackdropBorderColor(0.38, 0.38, 0.38, 0.9)
	window.fightDrop:SetHeight(16)
	local dropInset = (HEADER_HEIGHT - 16) / 2 -- even air above and below
	window.fightDrop:SetPoint("TOPRIGHT", -PADDING, -dropInset)
	window.fightDrop:SetPoint("TOPLEFT", 74, -dropInset) -- clears the mode title
	window.fightDrop.arrowTex = window.fightDrop:CreateTexture(nil, "OVERLAY")
	window.fightDrop.arrowTex:SetSize(16, 16)
	window.fightDrop.arrowTex:SetPoint("RIGHT", 0, 0)
	window.fightDrop.arrowTex:SetTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
	window.fightDrop:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
	window.fightDrop:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.06)

	window.subtitle = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	window.subtitle:SetWordWrap(false)

	-- the subtitle lives INSIDE the dropdown box normally, but spans the
	-- header when collapsed (the box hides there)
	local function layoutSubtitle(collapsed)
		window.subtitle:ClearAllPoints()
		if collapsed then
			-- centered like the title (the collapsed bar is one text line)
			window.subtitle:SetPoint("RIGHT", -PADDING, 0)
			window.subtitle:SetPoint("LEFT", window.title, "RIGHT", 6, 0)
			window.subtitle:SetJustifyH("RIGHT")
		else
			window.subtitle:SetPoint("LEFT", window.fightDrop, "LEFT", 6, 0)
			window.subtitle:SetPoint("RIGHT", window.fightDrop.arrowTex, "LEFT", -2, 0)
			window.subtitle:SetJustifyH("LEFT")
		end
	end
	window.LayoutSubtitle = layoutSubtitle
	layoutSubtitle(false)

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

	-- Fight browser: the dropdown box opens the fight picker. Hidden while
	-- collapsed (the header click is collapse there).
	window.fightDrop:SetFrameLevel(window.headerButton:GetFrameLevel() + 1)
	window.fightDrop:RegisterForClicks("LeftButtonUp")
	window.fightDrop:RegisterForDrag("LeftButton")
	window.fightDrop:SetScript("OnDragStart", startDrag)
	window.fightDrop:SetScript("OnDragStop", stopDrag)
	-- Fight picker: click the subtitle for a dropdown of recent captures.
	-- "Current" follows whatever is happening (the newest capture, or the
	-- waiting card inside unrecorded content); every capture — the newest
	-- included — is its own pinnable entry. Falls back to click-cycling on
	-- any client without the modern menu API.
	local function fightLabel(fight)
		local name = (fight.name or "Fight"):gsub("^%(!%)%s*", "")
		local d = fight.duration or 0
		return ("%s · %d:%02d%s"):format(name, math.floor(d / 60), d % 60,
			fight.wipe and " |cffe64d4d(wipe)|r" or "")
	end
	local function selectFight(f)
		pinnedFight = f -- nil = back to Current
		scrollOffset = 0
		MeterWindow:Invalidate()
	end
	local function openFightMenu(anchor)
		local fights = TP.FightHistory.fights
		if #fights == 0 or not (MenuUtil and MenuUtil.CreateContextMenu) then
			return false
		end
		MenuUtil.CreateContextMenu(anchor, function(_, root)
			-- a night of dungeon-hopping otherwise renders one screen-tall
			-- column; cap the height and let the wheel do the rest
			if root.SetScrollMode then
				root:SetScrollMode(320)
			end
			root:CreateRadio("Current · follows new fights",
				function() return pinnedFight == nil end,
				function() selectFight(nil) end)
			-- grouped by run: one group's visit to one instance+difficulty
			local lastRunID
			for i = 1, math.min(#fights, 25) do
				local f = fights[i]
				if f.runID ~= lastRunID then
					lastRunID = f.runID
					local diff = f.difficulty and f.difficulty ~= "" and (" · " .. f.difficulty) or ""
					root:CreateTitle((f.zone or "Unknown") .. diff)
				end
				root:CreateRadio(fightLabel(f),
					function() return pinnedFight == f end,
					function() selectFight(f) end)
			end
		end)
		return true
	end
	window.fightDrop:SetScript("OnClick", function(self)
		if not openFightMenu(self) then
			MeterWindow:StepFight(1) -- no menu API: old cycling behavior
		end
	end)

	-- Mode strip along the bottom edge: Real = the full contribution score,
	-- Raw = pure throughput vs WCL top logs (damage, healing for healers)
	local function makeRadio(labelText, mode, tooltip)
		local btn = CreateFrame("CheckButton", nil, window)
		btn:SetSize(11, 11)
		btn:SetNormalTexture("Interface\\Buttons\\UI-RadioButton")
		btn:GetNormalTexture():SetTexCoord(0, 0.25, 0, 1)
		btn:SetCheckedTexture("Interface\\Buttons\\UI-RadioButton")
		btn:GetCheckedTexture():SetTexCoord(0.25, 0.5, 0, 1)
		btn:SetHighlightTexture("Interface\\Buttons\\UI-RadioButton")
		btn:GetHighlightTexture():SetTexCoord(0.5, 0.75, 0, 1)
		btn.label = window:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		local labelPath = btn.label:GetFont()
		btn.label:SetFont(labelPath, 9, "")
		btn.label:SetPoint("LEFT", btn, "RIGHT", 1, 0)
		btn.label:SetText(labelText)
		-- the label is part of the click target, not just the 14px circle
		btn:SetHitRectInsets(0, -(btn.label:GetStringWidth() + 4), 0, 0)
		btn:SetScript("OnClick", function()
			db().scoring.mode = mode
			MeterWindow:UpdateModeButtons()
			MeterWindow:Invalidate()
		end)
		btn:SetScript("OnEnter", function(self)
			local body = { { tooltip, 0.8, 0.8, 0.8 } }
			if not self:IsEnabled() then
				body[#body + 1] = { "Unavailable: no Warcraft Logs data covers this fight.", 0.95, 0.5, 0.5 }
			end
			TP.Tooltip:Show(self, "TOP", labelText, body)
		end)
		btn:SetScript("OnLeave", function()
			TP.Tooltip:Hide()
		end)
		return btn
	end
	-- Column labels over the two number columns, aligned to their edges
	local function colLabel(text, rightOffset, colWidth)
		local fs = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		local path = fs:GetFont()
		fs:SetFont(path, 9, "")
		fs:SetPoint("TOPRIGHT", rightOffset, -(HEADER_HEIGHT - 1))
		fs:SetWidth(colWidth)
		fs:SetJustifyH("RIGHT")
		fs:SetTextColor(0.55, 0.55, 0.55)
		fs:SetText(text)
		return fs
	end
	window.colRun = colLabel("run", -(PADDING + 3), 20)
	window.colFight = colLabel("fight", -(PADDING + 3 + 20 + 4), 30)

	window.modeReal = makeRadio("TrueParse", "contribution",
		"Considers damage, healing, damage taken, interrupts, and much more compared to others of your same spec and role.")
	window.modeRaw = makeRadio("Raw", "parse",
		"Straight comparison to Warcraft Logs parses for your spec on this fight: damage for DPS and tanks, healing for healers.")
	-- right-aligned in the footer: ... Mode:  (*)True  ( )Raw]
	-- 16px of clearance on the right for the resize grip
	window.modeRaw:SetPoint("BOTTOMRIGHT",
		-(PADDING + 14 + window.modeRaw.label:GetStringWidth() + 2), 6)
	window.modeReal:SetPoint("RIGHT", window.modeRaw, "LEFT",
		-(window.modeReal.label:GetStringWidth() + 10), 0)

	-- empty-state message for instances with nothing recorded yet:
	-- makes "recording vs not" explicit instead of showing a stale card
	window.emptyTitle = window:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	window.emptyTitle:SetPoint("TOPLEFT", PADDING + 6, -(HEADER_HEIGHT + 14))
	window.emptyTitle:SetPoint("TOPRIGHT", -(PADDING + 6), -(HEADER_HEIGHT + 14))
	window.emptyTitle:SetJustifyH("LEFT")
	window.emptyTitle:SetText("Nothing recorded here yet.")
	window.emptyTitle:Hide()
	window.emptyMsg = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	window.emptyMsg:SetPoint("TOPLEFT", window.emptyTitle, "BOTTOMLEFT", 0, -6)
	window.emptyMsg:SetPoint("TOPRIGHT", window.emptyTitle, "BOTTOMRIGHT", 0, -6)
	window.emptyMsg:SetJustifyH("LEFT")
	window.emptyMsg:SetWordWrap(true)
	window.emptyMsg:SetSpacing(3)
	window.emptyMsg:Hide()

	-- presence-mark legend, sharing the bottom line with the radios
	window.footnote = window:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	local footPath = window.footnote:GetFont()
	window.footnote:SetFont(footPath, 9, "")
	window.footnote:SetPoint("BOTTOMLEFT", PADDING + 2, 8)
	window.footnote:SetPoint("RIGHT", window.modeReal, "LEFT", -6, 0)
	window.footnote:SetJustifyH("LEFT")
	window.footnote:SetWordWrap(false) -- truncate at the radios, never wrap
	window.footnote:SetText("|TInterface\\RaidFrame\\ReadyCheck-Ready:8:8|t = Addon installed")
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
	window.modeReal:SetShown(shown)
	window.modeReal.label:SetShown(shown)
	window.modeRaw:SetShown(shown)
	window.modeRaw.label:SetShown(shown)
	if not shown and window.footnote then
		window.footnote:Hide()
	end
end

-- Force the next refresh to re-render (e.g. after a scoring option change)
function MeterWindow:Invalidate()
	lastRenderedFight = nil
	wipe(displayCache)
	wipe(runScoreCache)
	self:Refresh(true)
end

-- Step through captured fights: positive = older, negative = toward latest.
-- Menu-less fallback only; stepping always pins (Current is treated as the
-- newest capture and there is no step back into follow mode).
function MeterWindow:StepFight(delta)
	local fights = TP.FightHistory.fights
	if #fights == 0 then
		return
	end
	local idx = 1
	if pinnedFight then
		for i = 1, #fights do
			if fights[i] == pinnedFight then
				idx = i
				break
			end
		end
	end
	pinnedFight = fights[math.max(1, math.min(#fights, idx + delta))]
	scrollOffset = 0 -- a different fight starts back at the top
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
		-- No live view on any client — when a fight starts, give the
		-- screen back
		if TP.Segments.current and db().window.autoCollapse then
			autoCollapsed = true
			TP.BreakdownPanel:HideAll()
		end
		MeterWindow:Refresh(true)
	end)
	TP.Addon:RegisterMessage("TrueParse_FIGHT_CAPTURED", function()
		autoCollapsed = false
		-- "Current" picks up the new capture on its own; an explicit pin
		-- holds. A pin whose fight aged out of history falls back to Current.
		if pinnedFight then
			local found = false
			for _, f in ipairs(TP.FightHistory.fights) do
				if f == pinnedFight then
					found = true
					break
				end
			end
			if not found then
				pinnedFight = nil
			end
		else
			scrollOffset = 0
		end
		MeterWindow:Refresh(true)
	end)
	TP.Addon:ScheduleRepeatingTimer(function()
		MeterWindow:Refresh(false)
	end, 0.5)
	self:Refresh(true)
end

-- Resize while keeping the on-screen edge stable: a window in the top half
-- of the screen stays pinned at its top and grows downward; in the bottom
-- half it stays pinned at its bottom and grows upward — collapse included,
-- so a bottom-anchored window's title bar drops to its bottom edge instead
-- of floating mid-screen.
local function applyWindowHeight(newHeight, pinTop)
	-- No-op when nothing changes (the 0.5s refresh calls this constantly),
	-- and never re-anchor mid-drag — SetPoint during StartMoving snaps the
	-- frame away from the cursor.
	if isSizing then
		return -- the grip owns the frame right now
	end
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

-- The window height is USER-set (resize grip); rows render into whatever
-- fits. How many row slots the current height offers:
local function contentSlots(rowHeight, withColHead)
	-- bottom reserve is just the mode strip plus a hair of air: doubling
	-- the padding left a dead band under the pinned Raid row
	local chrome = HEADER_HEIGHT + (withColHead and COLHEAD_HEIGHT or 0)
		+ MODE_HEIGHT + PADDING
	return math.max(1, math.floor((db().window.height - chrome) / (rowHeight + 1)))
end

local function setWindowHeight(withColHead)
	setModeStripShown(true)
	if window.colFight then
		window.colFight:SetShown(withColHead and true or false)
		window.colRun:SetShown(withColHead and true or false)
	end
	-- presence-mark legend only makes sense on the scorecard; it shares
	-- the bottom line with the radios, so no extra height
	if window.footnote then
		window.footnote:SetShown(withColHead and true or false)
	end
	applyWindowHeight(db().window.height)
end

-- ========================= Scorecard (primary) =========================

-- Score a fight for display. Raw mode requires WCL evidence (a percentile
-- curve or benchmark median) somewhere on the card — a "parse" against
-- nothing but your own group is noise, so those fights render True scores
-- and the Raw radio disables. Returns results, rawAvailable.
-- MUST be defined above every caller: a later definition compiles callers'
-- references as globals (nil) — exactly the blank-window bug this fixes.
local function anyWclEvidence(parseResults)
	for _, r in ipairs(parseResults) do
		for _, b in pairs(r.breakdown) do
			if b.absolute then
				return true
			end
		end
	end
	return false
end

-- Raw availability is fight-static (curve coverage doesn't change after
-- capture): cache it so re-renders don't pay a probe ScoreFight each time
local rawAvailCache = setmetatable({}, { __mode = "k" })

local function rawAvailableFor(fight, parseResults)
	local hit = rawAvailCache[fight]
	if hit ~= nil then
		return hit
	end
	local results = parseResults
	if not results then
		local parseOpts = TP.GetScoringOptions()
		parseOpts.mode = "parse"
		results = TP.Scoring.Engine.ScoreFight(fight, parseOpts)
	end
	local avail = anyWclEvidence(results)
	rawAvailCache[fight] = avail
	return avail
end

-- Scored results cached per fight+options (displayCache, declared with
-- the top-of-file locals): live resize relayouts rows every frame and
-- must not re-run the engine each time
local function scoreForDisplay(fight)
	local opts = TP.GetDisplayScoringOptions()
	local key = tostring(opts.mode) .. ":" .. tostring(opts.normalizeIlvl)
	local hit = displayCache[fight]
	if hit and hit.key == key then
		return hit.results, hit.rawAvailable
	end
	local results, rawAvailable
	if opts.mode == "parse" then
		if rawAvailCache[fight] == false then
			results, rawAvailable = TP.Scoring.Engine.ScoreFight(fight, TP.GetScoringOptions()), false
		else
			results = TP.Scoring.Engine.ScoreFight(fight, opts)
			rawAvailable = rawAvailableFor(fight, results)
			if not rawAvailable then
				results = TP.Scoring.Engine.ScoreFight(fight, TP.GetScoringOptions())
			end
		end
	else
		results, rawAvailable = TP.Scoring.Engine.ScoreFight(fight, TP.GetScoringOptions()), rawAvailableFor(fight)
	end
	displayCache[fight] = { key = key, results = results, rawAvailable = rawAvailable }
	return results, rawAvailable
end

-- The run row re-scores the aggregate on every render; cached per run
-- table (RunSummary reuses the aggregate between captures)
local function scoreRun(run)
	local opts = TP.GetScoringOptions()
	local hit = runScoreCache[run]
	if hit and hit.ilvl == opts.normalizeIlvl then
		return hit.rr
	end
	local rr = TP.Scoring.Engine.ScoreFight(run, opts)
	runScoreCache[run] = { ilvl = opts.normalizeIlvl, rr = rr }
	return rr
end

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

local lastRawAvailable = true

function MeterWindow:RenderScorecard(fight)
	local isRawSetting = TP.Addon.db.profile.scoring.mode == "parse"
	local function subtitleText(rawAvail)
		local duration = fight.duration or 0
		local label = ("%s · %d:%02d"):format(fight.name or "Fight", math.floor(duration / 60), duration % 60)
		if pinnedFight then
			local fights = TP.FightHistory.fights
			for i = 1, #fights do
				if fights[i] == pinnedFight then
					label = ("|cffaaaaaa%d/%d|r · "):format(i, #fights) .. label
					break
				end
			end
		end
		if isRawSetting and not rawAvail then
			-- no WCL data for this fight: the card falls back to True scores
			-- (the mode itself lives in the window title now)
			label = "|cff888888no WCL data|r · " .. label
		end
		if fight.wipe then
			label = "|cffe64d4dwipe|r · " .. label
		end
		if UnitAffectingCombat("player") then
			label = label .. " |cffff8888· fighting…|r"
		end
		return label
	end

	if lastRenderedFight == fight and lastScrollOffset == scrollOffset then
		-- scores are static once captured; only the subtitle changes
		window.subtitle:SetText(subtitleText(lastRawAvailable))
		return
	end
	lastRenderedFight = fight
	lastScrollOffset = scrollOffset

	local results, rawAvailable = scoreForDisplay(fight)
	lastRawAvailable = rawAvailable
	window.subtitle:SetText(subtitleText(rawAvailable))
	-- effective mode for THIS card: raw only when WCL evidence backs it
	local isRaw = isRawSetting and rawAvailable
	if window.modeRaw then
		local a = rawAvailable and 1 or 0.45
		window.modeRaw:SetAlpha(a)
		window.modeRaw.label:SetAlpha(a)
		if rawAvailable then
			window.modeRaw:Enable()
		else
			window.modeRaw:Disable()
		end
	end
	local conf = db().bars
	local rowHeight = SCORECARD_ROW_HEIGHT
	local shown = math.min(#results, conf.max)
	local width = db().window.width - PADDING * 2
	local hasFooter = #results >= 3

	-- Run row: THIS fight's run average (always True — same currency the
	-- chat reports use). A one-boss run just mirrors the fight score, but
	-- the column showing up and disappearing read as a bug — it's always
	-- there now. Browsing an old card shows that card's run, not whatever
	-- run is live now.
	local runFight, runResults, runScore, runBy
	if TP.RunSummary and TP.RunSummary.RunFor then
		local run, count = TP.RunSummary:RunFor(fight)
		if run and count and count >= 1 then
			local rr = scoreRun(run)
			if #rr > 0 then
				local s = 0
				runBy = {}
				for _, r in ipairs(rr) do
					s = s + r.score
					runBy[r.guid] = r
				end
				runFight, runResults, runScore = run, rr, s / #rr
			end
		end
	end
	-- the breakdown panel shows "N avg this run" from the same numbers
	TP.BreakdownPanel.runScores = runBy
	TP.BreakdownPanel.groupRunScore = runScore

	-- fit rows to the user-sized window; the wheel scrolls the remainder
	-- (footer keeps a pinned slot at the bottom)
	local slots = contentSlots(rowHeight, true)
	local playerSlots = math.max(1, slots - (hasFooter and 1 or 0))
	local visible = math.min(shown, playerSlots)
	scrollOffset = math.max(0, math.min(scrollOffset, shown - visible))
	lastScrollOffset = scrollOffset
	local totalRows = visible + (hasFooter and 1 or 0)

	for i = #activeRows, totalRows + 1, -1 do
		TP.Scorecard:Release(activeRows[i])
		activeRows[i] = nil
	end

	for i = 1, visible do
		local r = results[i + scrollOffset]
		local row = activeRows[i]
		if not row then
			row = TP.Scorecard:Acquire(window)
			activeRows[i] = row
		end
		row:SetSize(width, rowHeight)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", PADDING, -(HEADER_HEIGHT + COLHEAD_HEIGHT + (i - 1) * (rowHeight + 1)))

		local gcr, gcg, gcb = TP.Scoring.Grades.ColorForScore(r.score)

		-- Players not running TrueParse render dimmed: less data, not worse.
		-- The local player always has the addon (fights captured before the
		-- presence stamp existed rely on the isLocalPlayer fallback).
		local player = fight.players[r.guid]
		local hasAddon = player and (player.hasAddon or player.isLocalPlayer)
		row.name:SetAlpha(1)
		row.score:SetAlpha(1)
		row.penalty:SetAlpha(1)
		-- letters read ragged when right-aligned; numbers ragged when left
		local letterAlign = db().letterGrades and "LEFT" or "RIGHT"
		row.score:SetJustifyH(letterAlign)
		row.runAvg:SetJustifyH(letterAlign)
		row.icon:SetAlpha(hasAddon and 1 or 0.7)
		if hasAddon then
			row.addonMark:SetTexture("Interface\\RaidFrame\\ReadyCheck-Ready")
			row.addonMark:SetTexCoord(0, 1, 0, 1)
		elseif player and player.hasAddon == false then
			row.addonMark:SetTexture("Interface\\RaidFrame\\ReadyCheck-NotReady")
			row.addonMark:SetTexCoord(0, 1, 0, 1)
		else
			-- presence not settled yet (hellos still in flight, or an old
			-- capture from before the three-state stamp)
			row.addonMark:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
			row.addonMark:SetTexCoord(0.12, 0.88, 0.12, 0.88)
		end
		row.addonMark:Show()

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
		local barArea = math.max(40, width - COL_RESERVE)
		row.track:SetWidth(barArea)
		row.bg:SetWidth(math.max(8, barArea * math.min(math.max(r.score, 0), 100) / 100))
		row.icon:SetWidth(rowHeight)
		setSpecIcon(row.icon, player, r.class)

		-- no award star here: it wrapped long cross-realm names and the
		-- row already carries a lot (awards live in the breakdown + toasts)
		row.name:SetText(r.name)
		row.name:SetTextColor(1, 1, 1)
		row.playerName = r.name

		-- A "parse" with no WCL evidence behind it (group-relative fallback:
		-- unlisted fight, wrong difficulty) is an estimate — mark it so a
		-- best-in-group 99 can't masquerade as a real percentile
		local approx = false
		if isRaw then
			for _, b in pairs(r.breakdown) do
				-- zero-weight display metrics don't make a parse approximate
				if b.applicable and not b.absolute and (b.effectiveWeight or 0) > 0 then
					approx = true
				end
			end
		end
		row.score:SetText((approx and "~" or "") .. TP.Scoring.Grades.ScoreLabel(r.score))
		row.score:SetTextColor(gcr, gcg, gcb)
		row.penalty:SetText(r.penalty > 0 and ("|cffff4444-%.0f|r"):format(r.penalty) or "")

		-- cumulative True run average, dimmed, far right (True currency in
		-- both modes: the distinct dimmed column carries the distinction)
		-- the cell keeps its width whenever the COLUMN exists: a 1px cell
		-- let the fight score slide into the run column's position
		local runR = runBy and runBy[r.guid]
		row.runAvg:SetWidth(runBy and 20 or 1)
		if runR then
			row.runAvg:SetText(TP.Scoring.Grades.ScoreLabel(runR.score))
			row.runAvg:SetTextColor(TP.Scoring.Grades.ColorForScore(runR.score))
		else
			row.runAvg:SetText("")
		end
		row.sep2:SetShown(runBy ~= nil)

		row.fight = fight
		row.result = r
		row.groupResults = nil
		row.runGroup = nil
	end

	-- Footer: one combined summary row — this fight's group score in the
	-- score column, the cumulative True run average in the run column (the
	-- same two-number shape as player rows). Left-click = fight breakdown,
	-- right-click = run breakdown.
	if hasFooter then
		local index = visible + 1
		local row = activeRows[index]
		if not row then
			row = TP.Scorecard:Acquire(window)
			activeRows[index] = row
		end
		row:SetSize(width, rowHeight)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", PADDING, -(HEADER_HEIGHT + COLHEAD_HEIGHT + (index - 1) * (rowHeight + 1)))
		local sum = 0
		for _, r in ipairs(results) do
			sum = sum + r.score
		end
		local groupScore = sum / #results
		local sr, sg, sb = TP.Scoring.Grades.ColorForScore(groupScore)
		local label = (#results > 5) and "Raid" or "Group"
		row.name:SetAlpha(1)
		row.score:SetAlpha(1)
		row.penalty:SetAlpha(1)
		local letterAlign = db().letterGrades and "LEFT" or "RIGHT"
		row.score:SetJustifyH(letterAlign)
		row.runAvg:SetJustifyH(letterAlign)
		row.name:SetText(label)
		row.name:SetTextColor(1, 1, 1)
		row.score:SetText(TP.Scoring.Grades.ScoreLabel(groupScore))
		row.score:SetTextColor(sr, sg, sb)
		-- the group's combined penalties, same shape as player rows
		local penaltySum = 0
		for _, r in ipairs(results) do
			penaltySum = penaltySum + (r.penalty or 0)
		end
		row.penalty:SetText(penaltySum > 0 and ("|cffff4444-%.0f|r"):format(penaltySum) or "")
		if runScore then
			row.runAvg:SetText(TP.Scoring.Grades.ScoreLabel(runScore))
			row.runAvg:SetTextColor(TP.Scoring.Grades.ColorForScore(runScore))
			row.runAvg:SetWidth(20)
		else
			row.runAvg:SetText("")
			row.runAvg:SetWidth(1)
		end
		row.sep2:SetShown(runScore ~= nil)
		row.bg:SetColorTexture(0.60, 0.48, 0.10, 0.95)
		local barArea = math.max(40, width - COL_RESERVE)
		row.track:SetWidth(barArea)
		row.bg:SetWidth(math.max(8, barArea * math.min(math.max(groupScore, 0), 100) / 100))
		row.icon:Hide()
		row.addonMark:Hide()
		row.playerName = label
		row.fight = fight
		row.result = nil
		row.groupResults = results -- left-click/hover: this fight's breakdown
		row.runGroup = runResults and { fight = runFight, results = runResults } or nil
	end

	-- scroll hints: a thin arrow over the top/bottom row edge when more
	-- rows exist in that direction
	if window.scrollUp then
		window.scrollUp:ClearAllPoints()
		window.scrollUp:SetPoint("TOP", 0, -(HEADER_HEIGHT + COLHEAD_HEIGHT - 3))
		window.scrollUp:SetShown(scrollOffset > 0)
		local hiddenBelow = shown - (scrollOffset + visible)
		window.scrollDown:ClearAllPoints()
		window.scrollDown:SetPoint("TOP", 0,
			-(HEADER_HEIGHT + COLHEAD_HEIGHT + visible * (rowHeight + 1) - 4))
		window.scrollDown:SetShown(hiddenBelow > 0)
	end

	setWindowHeight(true)
	window.colRun:SetShown(runBy ~= nil) -- no run yet: no misleading label
	TP.BreakdownPanel:OnFightRendered(fight, results)
end

-- ============================== Dispatch ==============================

function MeterWindow:ToggleCollapse()
	if autoCollapsed or db().window.collapsed then
		autoCollapsed = false
		db().window.collapsed = false
	else
		db().window.collapsed = true
		-- a collapsed card shouldn't leave its tooltips floating around
		TP.BreakdownPanel:HideAll()
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
		.. ":" .. tostring(db().letterGrades) -- letters toggle re-renders the title too
	if collapsedCache.fight ~= fight or collapsedCache.key ~= key then
		collapsedCache.fight, collapsedCache.key = fight, key
		local results = scoreForDisplay(fight)
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

-- Waiting condition: inside instanced content (dungeon/raid/scenario,
-- delves included) with nothing captured from THIS place -> returns the
-- zone name and whether the content is unsupported (delves/scenarios and
-- companion difficulties, which are never captured); nil otherwise.
-- Combat never bypasses this: there is no live view, so mid-fight the
-- waiting card simply stays put.
local function waitingHere()
	local inInst, instType = IsInInstance()
	if not (inInst and (instType == "party" or instType == "raid" or instType == "scenario")) then
		return nil
	end
	local here, _, difficultyID = GetInstanceInfo()
	local unsupported = instType == "scenario"
		or TP.UNSUPPORTED_DIFFICULTY[difficultyID or 0] or false
	local newest = TP.FightHistory.fights[1]
	if unsupported or not newest or newest.zone ~= here then
		return here or "this instance", unsupported
	end
end

local function refreshImpl(self, force)
	if not window or not window:IsShown() then
		return
	end
	-- the title carries the selected mode; the subtitle no longer tags raw
	local modeTitle = (db().scoring.mode == "parse") and "Raw" or "TrueParse"
	if db().window.collapsed or autoCollapsed then
		releaseAllRows()
		lastRenderedFight = nil
		if window.grip then
			window.grip:Hide()
		end
		if window.scrollUp then
			window.scrollUp:Hide()
			window.scrollDown:Hide()
		end
		window.title:SetText(modeTitle .. " (+)")
		-- a pinned fight is explicit: its summary wins over the waiting state
		local waitingZone, waitingUnsupported
		if not pinnedFight then
			waitingZone, waitingUnsupported = waitingHere()
		end
		local latest = pinnedFight or TP.FightHistory.fights[1]
		if waitingZone then
			-- stale scores must not impersonate a live summary while the
			-- expanded card would be showing the waiting state
			window.subtitle:SetText(waitingZone
				.. (waitingUnsupported and " · not supported"
					or TP.FightHistory.pending and " · unlocking..."
					or " · waiting"))
		elseif latest then
			window.subtitle:SetText(collapsedSummary(latest))
		else
			window.subtitle:SetText("")
		end
		window.fightDrop:Hide()
		window.LayoutSubtitle(true)
		if window.emptyTitle then
			window.emptyTitle:Hide()
			window.emptyMsg:Hide()
		end
		setModeStripShown(false)
		if window.colFight then
			window.colFight:Hide()
			window.colRun:Hide()
		end
		-- screen-half pinning (no pinTop): top half keeps the title bar in
		-- place, bottom half collapses DOWN to the window's bottom edge.
		-- Exactly one header tall: the centered title doesn't move between
		-- the collapsed bar and the expanded card's header band.
		applyWindowHeight(HEADER_HEIGHT)
		return
	end
	window.title:SetText(modeTitle)
	window.fightDrop:Show()
	window.LayoutSubtitle(false)
	if window.grip then
		window.grip:Show()
	end
	if window.emptyMsg then
		window.emptyTitle:Hide()
		window.emptyMsg:Hide()
	end
	local fight = pinnedFight or TP.FightHistory.fights[1]

	-- Recording clarity: "Current" inside an instance with nothing captured
	-- HERE must not impersonate a live card with stale data — show what
	-- will and won't record instead. A pinned fight is explicit and always
	-- renders its card.
	local here, hereUnsupported
	if not pinnedFight then
		here, hereUnsupported = waitingHere()
	end
	if here or not fight then
		releaseAllRows()
		lastRenderedFight = nil
		if hereUnsupported then
			window.subtitle:SetText(here .. " · not supported")
			window.emptyTitle:SetText("This content isn't supported.")
			window.emptyMsg:SetText("Delves, scenarios, and follower content aren't ranked on Warcraft Logs, so fights here aren't captured. Dungeon and raid bosses record automatically.")
		elseif here and TP.FightHistory.pending then
			-- a session exists but its values are still secret-locked:
			-- "nothing recorded" would be a lie that reads as a bug
			window.subtitle:SetText(here .. " · unlocking...")
			window.emptyTitle:SetText("Fight recorded - numbers still locked.")
			window.emptyMsg:SetText("Blizzard keeps combat data locked for a while after an encounter (longest in raids). Scores fill in automatically - no reload needed.")
		elseif here then
			window.subtitle:SetText(here .. " · waiting")
			window.emptyTitle:SetText("Nothing recorded here yet.")
			window.emptyMsg:SetText("Boss fights are captured automatically; trash pulls and most solo content are not. Fights without Warcraft Logs rankings score in TrueParse mode only (no Raw).")
		else
			-- nothing captured anywhere yet (fresh install, open world)
			window.subtitle:SetText("no fights yet")
			window.emptyTitle:SetText("Nothing recorded yet.")
			window.emptyMsg:SetText("Dungeon and raid bosses are captured and scored automatically. Your scorecard appears after your first boss fight.")
		end
		window.emptyTitle:Show()
		window.emptyMsg:Show()
		if window.scrollUp then
			window.scrollUp:Hide()
			window.scrollDown:Hide()
		end
		setWindowHeight(false)
		return
	end

	self:RenderScorecard(fight)
end

-- Errors on the 0.5s refresh path die silently without an error addon and
-- leave a blank window; surface the first one in chat instead.
local refreshErrorShown = false
function MeterWindow:Refresh(force)
	local ok, err = pcall(refreshImpl, self, force)
	if not ok and not refreshErrorShown then
		refreshErrorShown = true
		print("|cffff4444TrueParse render error (please report):|r " .. tostring(err))
	end
end
