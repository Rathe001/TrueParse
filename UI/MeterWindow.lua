-- The main TrueParse window. Primary view: post-fight SCORECARD — one row
-- per player with a colored letter grade, sorted by contribution score.
-- Until the first fight is captured it falls back to a live damage view
-- (Blizzard session data), and Classic clients use the CLEU segment view.
local _, TP = ...

local MeterWindow = {}
TP.MeterWindow = MeterWindow

local HEADER_HEIGHT = 26
local COLHEAD_HEIGHT = 0 -- header labels removed: tooltips explain the columns
local COL_RESERVE = 66 -- right-side score columns the class bar never enters
local MODE_HEIGHT = 16 -- bottom strip: Mode: (*)Real ( )Raw
-- sized to fit "III" with even padding all round, then centred in the
-- penalty column (Josh 2026-07-28)
local TIER_CHIP_W, TIER_CHIP_H = 18, 14
local LOGO_SIZE = 14 -- the mark that replaced the "TrueParse" wordmark

-- Header/row grid (Josh 2026-07-28: "so things all line up in a nice grid").
-- These MIRROR UI/Scorecard.lua's row columns, measured as an inset from the
-- ROW's right edge — change one and you must change the other:
--   runAvg   RIGHT -3,  width 15   -> the cog sits here
--   score    RIGHT -22, width 17   -> the reports icon sits here
--   penalty  RIGHT -45, width 19   -> the evidence-tier chip sits here
-- and the class bar ends COL_RESERVE short of the row's right edge, which is
-- where the fight selector now ends too.
local COL = {
	runAvg  = { right = 3,  w = 15 },
	score   = { right = 22, w = 17 },
	penalty = { right = 45, w = 19 },
}
local PADDING = 6

-- Evidence tiers, in the engine's own numbering (Scoring/Engine.lua): I is
-- the strongest evidence, III the weakest, and the colour says so. Josh
-- 2026-07-28 asked for these to stay consistent with the engine rather than
-- reading as a 1-2-3 quality ladder in the other direction, so DO NOT
-- renumber one without the other.
--
-- The chip rides INSIDE the fight selector rather than under the window
-- (Josh 2026-07-28, option D): the tier describes the SELECTED ENCOUNTER, so
-- it belongs next to the encounter's name — changing the selection visibly
-- changes the chip. The header band is also the collapsed bar, so it stays
-- visible collapsed without hanging anything off the frame to clip.
-- Copy rule (Josh 2026-07-28): `what` is the whole answer for anyone who
-- just wants one — it leads, one sentence, at a larger size. `how` is the
-- footnote for anyone who doesn't believe it, and it earns at most a line.
-- If a `how` grows past ~140 characters it has stopped being a footnote.
-- One word each, and all three on the SAME axis — precision (Josh
-- 2026-07-28). That constraint is what rules out "Derived": it names where a
-- number came from, not how exact it is, so it can't be ranked against
-- "Precise". Precise > Approximate > Rough reads as a scale on sight, and
-- the colour reinforces it rather than carrying it alone. The severity Josh
-- wanted on III lives in the copy ("Don't quote this number") instead of in
-- a loaded title — the tier is imprecise, not dishonest.
local TIERS = {
	-- %s = the client's ranked dungeon tier. Mists has no Mythic+ at all -
	-- Warcraft Logs ranks its Challenge Modes - so this copy was describing a
	-- system that does not exist there (Josh 2026-07-30).
	{ tier = 1, numeral = "I", title = "Precise", r = 0.35, g = 0.85, b = 0.4,
		what = "A 1:1 comparison against Warcraft Logs.",
		how = ("Ranked at the difficulty you played - any raid difficulty, any %s run.")
			:format(TP.RANKED_DUNGEON_TIER or "Mythic+") },
	{ tier = 2, numeral = "II", title = "Approximate", r = 0.95, g = 0.8, b = 0.3,
		what = "This dungeon's real curves, scaled to your gear.",
		how = ("Not a real parse: WCL only ranks this dungeon at %s, so the difficulty gap is corrected.")
			:format(TP.RANKED_DUNGEON_TIER or "Mythic+") },
	{ tier = 3, numeral = "III", title = "Rough", r = 0.9, g = 0.4, b = 0.35,
		what = "Nothing on Warcraft Logs covers this fight.",
		how = "Averaged across everything we do have, scaled to your gear. Don't quote this number." },
}
local lastTier = 1
local SCORECARD_ROW_HEIGHT = 18 -- Details-proportioned rows: icon = row height

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

-- Combat click-through: the window (and everything on it) stops eating
-- mouse events so clicks land on the world behind it. EnableMouse is
-- not a protected call, so combat toggling is safe.
local clickThrough = false
local function applyClickThrough(on)
	clickThrough = on
	if not window then
		return
	end
	window:EnableMouse(not on)
	window:EnableMouseWheel(not on)
	for _, f in ipairs({ window.headerButton, window.fightDrop, window.cog,
		window.chat, window.footerButton, window.grip, window.modeReal, window.modeRaw }) do
		if f then
			f:EnableMouse(not on)
		end
	end
	for _, row in ipairs(activeRows) do
		row:EnableMouse(not on)
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
	-- Palette (Josh 2026-07-28, from the design review): the neutrals carry
	-- a violet bias rather than sitting on a default grey, and the border
	-- picks the same hue instead of a flat 40% grey. #14111f / #38314c.
	window:SetBackdropColor(0.078, 0.067, 0.122, 1)
	window:SetBackdropBorderColor(0.220, 0.192, 0.298, 0.95)
	-- REAL saved height from the start: a placeholder height let the
	-- first layout derive (and persist) the screen-half pin from a
	-- transient rect — the window walked on every reload
	window:SetSize(db().window.width, db().window.height)
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

	-- The word "TrueParse" spent 74px of header telling you which addon you
	-- were already looking at (Josh 2026-07-28). The mark says it in 14, and
	-- the selector starts where the word used to.
	window.logo = window:CreateTexture(nil, "OVERLAY")
	window.logo:SetSize(LOGO_SIZE, LOGO_SIZE)
	window.logo:SetPoint("LEFT", window, "TOPLEFT", PADDING, -HEADER_HEIGHT / 2)
	-- extension omitted on purpose: the client resolves .tga/.blp itself
	window.logo:SetTexture("Interface\\AddOns\\TrueParse\\Logo")

	-- Mode tag, not a title. TrueParse is the default, so it says nothing;
	-- Raw is the deviation and earns a word. Collapse still shows the mode,
	-- which is why this can't just live on the footer radios (those hide).
	window.title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
	window.title:SetPoint("LEFT", window.logo, "RIGHT", 5, 0)
	window.title:SetText("")

	-- The fight picker looks like a real dropdown: bordered inset box with
	-- the classic round arrow button, sized into the header
	window.fightDrop = CreateFrame("Button", nil, window, "BackdropTemplate")
	window.fightDrop:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	-- one step up from the window ground so the pill reads as an inset
	-- control, not a hole punched in the frame (#221d31 / #3a3350)
	window.fightDrop:SetBackdropColor(0.133, 0.114, 0.192, 0.9)
	window.fightDrop:SetBackdropBorderColor(0.227, 0.200, 0.314, 0.95)
	-- options cog at the header's right edge; the dropdown yields the room
	window.cog = CreateFrame("Button", nil, window)
	window.cog:SetSize(14, 14)
	window.cog:SetNormalTexture("Interface\\Buttons\\UI-OptionsButton")
	window.cog:SetHighlightTexture("Interface\\Buttons\\UI-OptionsButton")
	window.cog:GetHighlightTexture():SetAlpha(0.4)
	window.cog:SetScript("OnClick", function()
		if TP.Options and TP.Options.Open then
			TP.Options.Open()
		end
	end)

	-- chat icon beside the cog: opens the shareable-reports panel
	window.chat = CreateFrame("Button", nil, window)
	window.chat:SetSize(14, 14)
	window.chat:SetNormalTexture("Interface\\GossipFrame\\ChatBubbleGossipIcon")
	window.chat:SetHighlightTexture("Interface\\GossipFrame\\ChatBubbleGossipIcon")
	window.chat:GetHighlightTexture():SetAlpha(0.4)
	window.chat:SetScript("OnClick", function()
		if TP.ReportsUI then
			TP.ReportsUI.Toggle()
		end
	end)
	window.chat:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Reports", 1, 1, 1)
		GameTooltip:AddLine("Share wipe, kill, and run summaries.", 0.8, 0.8, 0.8)
		GameTooltip:Show()
	end)
	window.chat:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	window.fightDrop:SetHeight(16)
	local dropInset = (HEADER_HEIGHT - 16) / 2 -- even air above and below
	MeterWindow:LayoutHeader() -- owns the selector's, chip's, chat's and
	-- cog's points; re-run at the end of createWindow once they all exist

	-- A drawn chevron, not a borrowed texture (Josh 2026-07-28, twice: "the
	-- handle doesn't read as a handle"). Every stock candidate carries button
	-- chrome around the glyph — UI-ScrollBar-ScrollDownButton is literally a
	-- scrollbar nub, and Arrow-Down-Up smudges at this size. Two thin bars
	-- rotated into a "v" gives the clean caret a dropdown wants, with no
	-- dependency on an atlas that may not exist on both clients.
	window.fightDrop.caret = CreateFrame("Frame", nil, window.fightDrop)
	window.fightDrop.caret:SetSize(9, 6)
	window.fightDrop.caret:SetPoint("RIGHT", -6, 0)
	do
		local caret = window.fightDrop.caret
		caret.arms = {}
		-- arms meet at the bottom centre: left arm slopes down to the right
		-- (clockwise = negative), right arm slopes back up (positive)
		for i, spec in ipairs({ { -2, -math.pi / 4 }, { 2, math.pi / 4 } }) do
			local arm = caret:CreateTexture(nil, "OVERLAY")
			arm:SetSize(6, 1.6)
			arm:SetPoint("CENTER", caret, "CENTER", spec[1], 0)
			arm:SetColorTexture(0.82, 0.79, 0.90, 1)
			-- SetRotation is modern-engine only; MoP Classic ships that
			-- engine, but degrade to a flat bar rather than erroring
			pcall(arm.SetRotation, arm, spec[2])
			caret.arms[i] = arm
		end
	end
	window.fightDrop:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
	window.fightDrop:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.06)

	-- Evidence-tier chip: a small filled plate carrying the roman numeral,
	-- parked at the right end of the selector box beside the dropdown arrow.
	-- Everything that sits ON the selector pill — the encounter name and the
	-- tier chip — has to draw ABOVE it. Both used to hang off `window` at
	-- the pill's own frame level, so the pill's backdrop painted straight
	-- over them: at the old 55%-alpha black that merely dimmed the name, but
	-- against the new near-opaque pill it swallowed the chip entirely and
	-- left the encounter unreadable (Josh 2026-07-28).
	-- Parenting them to the pill would fix the layering and break collapse
	-- (the pill hides there, these must not). A sibling overlay frame at a
	-- higher level does both.
	window.headerOverlay = CreateFrame("Frame", nil, window)
	window.headerOverlay:SetAllPoints(window)
	window.headerOverlay:SetFrameLevel(window.fightDrop:GetFrameLevel() + 5)

	window.tierChip = CreateFrame("Button", nil, window.headerOverlay)
	window.tierChip:SetSize(TIER_CHIP_W, TIER_CHIP_H)
	window.tierChip.bg = window.tierChip:CreateTexture(nil, "BACKGROUND")
	window.tierChip.bg:SetAllPoints()
	window.tierChip.bg:SetColorTexture(1, 1, 1, 1)
	-- 1px inset frame, drawn as four edges so it never washes the fill
	window.tierChip.edges = {}
	for i = 1, 4 do
		local e = window.tierChip:CreateTexture(nil, "BORDER")
		e:SetColorTexture(1, 1, 1, 1)
		if i == 1 then
			e:SetPoint("TOPLEFT"); e:SetPoint("TOPRIGHT"); e:SetHeight(1)
		elseif i == 2 then
			e:SetPoint("BOTTOMLEFT"); e:SetPoint("BOTTOMRIGHT"); e:SetHeight(1)
		elseif i == 3 then
			e:SetPoint("TOPLEFT"); e:SetPoint("BOTTOMLEFT"); e:SetWidth(1)
		else
			e:SetPoint("TOPRIGHT"); e:SetPoint("BOTTOMRIGHT"); e:SetWidth(1)
		end
		window.tierChip.edges[i] = e
	end
	window.tierChip.label = window.tierChip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	do
		local fontPath = window.tierChip.label:GetFont()
		window.tierChip.label:SetFont(fontPath, 9, "")
	end
	window.tierChip.label:SetPoint("CENTER", 0, 0)
	window.tierChip:SetScript("OnEnter", function(self)
		local t = self.tierDef
		if not t then
			return
		end
		-- summary leads at +2pt and near-white; the footnote drops back to
		-- the default size and dims, so the eye lands on the answer first
		local body = {
			{ t.what, 0.95, 0.95, 0.95, size = 13 },
			-- a fight can explain its OWN tier better than the generic
			-- footnote can (tier II's names dungeons and Mythic+, which says
			-- nothing true about a training dummy)
			{ self.tierHow or t.how, 0.66, 0.66, 0.70 },
		}
		-- The chip is the only tier surface, so it carries the legend too —
		-- as real chips, matching the one in the header. The active plate is
		-- coloured and the other two are grey, which says "you are here"
		-- without a marker glyph (WoW's fonts have no bullet: U+25CF/U+25CB
		-- rendered as tofu squares, the same trap that made TP.STAR a
		-- texture escape rather than a Unicode star).
		for i, other in ipairs(TIERS) do
			body[#body + 1] = {
				other.title,
				other.r, other.g, other.b,
				chip = other.numeral,
				active = (other.tier == t.tier),
				-- the hairline splits "about this tier" from "all tiers"
				rule = (i == 1) or nil,
				gapBefore = (i == 1) and 4 or nil,
			}
		end
		TP.Tooltip:Show(self, "TOP", ("Tier %s · %s"):format(t.numeral, t.title), body)
	end)
	window.tierChip:SetScript("OnLeave", function()
		TP.Tooltip:Hide()
	end)

	-- on the overlay, not the window: see headerOverlay above
	window.subtitle = window.headerOverlay:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	window.subtitle:SetWordWrap(false)
	-- GameFontDisableSmall is a 50% grey. That read acceptably on the old
	-- near-black pill, but the pill is now a lighter violet (it reads as an
	-- inset control instead of a hole) and the grey vanished into it — the
	-- encounter name was unreadable. The design review's #cfc8de is what
	-- that pill was drawn with; use it. Embedded |cff..| runs in the text
	-- still override this per segment.
	window.subtitle:SetTextColor(0.812, 0.784, 0.871)

	-- the subtitle lives INSIDE the dropdown box normally, but spans the
	-- header when collapsed (the box hides there)
	-- The chip is no longer inside the pill — LayoutHeader parks it in the
	-- penalty column — so expanded, the encounter name owns the whole
	-- selector out to the caret. Collapsed, the pill is hidden and the name
	-- spans the bar, still stopping short of the chip.
	local function layoutSubtitle(collapsed)
		window.subtitle:ClearAllPoints()
		if collapsed then
			window.subtitle:SetPoint("LEFT", window.title, "RIGHT", 6, 0)
			window.subtitle:SetPoint("RIGHT", window.tierChip, "LEFT", -6, 0)
			window.subtitle:SetJustifyH("RIGHT")
		else
			window.subtitle:SetPoint("LEFT", window.fightDrop, "LEFT", 6, 0)
			window.subtitle:SetPoint("RIGHT", window.fightDrop.caret, "LEFT", -4, 0)
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

	-- "Wipe it" (Josh 2026-07-26): one press records the exact call moment
	-- and locks every install out for the rest of the fight. A LARGE icon
	-- button anchored off the window's top/bottom edge (never on the
	-- header — misclicks there collapse the window), on the side away
	-- from the screen edge. Own mouse so click-through-in-combat never
	-- eats it. Visibility rules in UpdateWipeButton.
	window.wipeBtn = CreateFrame("Button", nil, window, "BackdropTemplate")
	window.wipeBtn:SetSize(40, 40)
	window.wipeBtn:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 2,
	})
	window.wipeBtn:SetBackdropColor(0.15, 0.02, 0.02, 0.95)
	window.wipeBtn:SetBackdropBorderColor(1, 0.25, 0.25, 1)
	window.wipeBtn.icon = window.wipeBtn:CreateTexture(nil, "ARTWORK")
	window.wipeBtn.icon:SetPoint("TOPLEFT", 4, -4)
	window.wipeBtn.icon:SetPoint("BOTTOMRIGHT", -4, 4)
	-- the skull raid marker: the universal "we're dead" glyph
	window.wipeBtn.icon:SetTexture("Interface\\TargetingFrame\\UI-RaidTargetingIcon_8")
	window.wipeBtn:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
	window.wipeBtn:GetHighlightTexture():SetVertexColor(1, 0.4, 0.4, 0.2)
	window.wipeBtn:EnableMouse(true)
	window.wipeBtn:Hide()
	window.wipeBtn:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:SetText("Wipe it")
		GameTooltip:AddLine("Marks the call for every TrueParse in the group - nothing after it counts against anyone.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	window.wipeBtn:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	window.wipeBtn:SetScript("OnClick", function()
		local seg = TP.Segments and TP.Segments.current
		if not seg or seg.manualWipeAt then
			return
		end
		if TP.Segments:ManualWipeCall(GetTime() - seg.startTime, UnitName("player")) then
			if TP.Sync and TP.Sync.BroadcastWipeCall then
				TP.Sync:BroadcastWipeCall()
			end
			TP.Addon:Print("Wipe called — nothing after this counts against anyone.")
		end
		MeterWindow:UpdateWipeButton()
	end)

	-- Fight browser: the dropdown box opens the fight picker. Hidden while
	-- collapsed (the header click is collapse there).
	window.fightDrop:SetFrameLevel(window.headerButton:GetFrameLevel() + 1)
	-- the cog needs the same explicit raise: at EQUAL level with the
	-- header button, a collapse/expand cycle reshuffles mouse priority
	-- among siblings and the collapse button starts eating the clicks
	window.cog:SetFrameLevel(window.headerButton:GetFrameLevel() + 1)
	-- the chat icon too (Josh 2026-07-25: unclickable on retail — the
	-- header's collapse button was swallowing it)
	window.chat:SetFrameLevel(window.headerButton:GetFrameLevel() + 1)
	window.fightDrop:RegisterForClicks("LeftButtonUp")
	window.fightDrop:RegisterForDrag("LeftButton")
	window.fightDrop:SetScript("OnDragStart", startDrag)
	window.fightDrop:SetScript("OnDragStop", stopDrag)
	-- Fight picker: click the subtitle for a dropdown of recent captures.
	-- "Current" follows whatever is happening (the newest capture, or the
	-- waiting card inside unrecorded content); every capture — the newest
	-- included — is its own pinnable entry. Falls back to click-cycling on
	-- any client without the modern menu API.
	-- The deepest wipe on each boss, so the pull list answers "how close did we
	-- get" without the reader ranking eleven rows by hand. Keyed by encounter
	-- AND difficulty: a Heroic attempt is not progress on the Normal boss.
	-- PullDepth already orders phase-first, which is the only ordering that
	-- holds when a boss refills.
	local function markBestPulls(fights, upto)
		local best = {}
		for i = 1, upto do
			local f = fights[i]
			if f and f.wipe then
				local d = TP.PullDepth(f)
				local key = ("%s|%s"):format(tostring(f.encounterID or f.name),
					tostring(f.difficultyID))
				if d and (not best[key] or d > best[key].d) then
					best[key] = { d = d, f = f }
				end
			end
		end
		local mark = {}
		for _, b in pairs(best) do
			mark[b.f] = true
		end
		return mark
	end
	local bestPulls = {}

	local function fightLabel(fight)
		local name = (fight.name or "Fight"):gsub("^%(!%)%s*", "")
		local d = fight.duration or 0
		-- difficulty rides the ROW, not just the run header: the header
		-- scrolls away, and a night of mixed lockouts rendered three
		-- identical "Siege of Orgrimmar" titles (Josh 2026-08-05)
		local chip = TP.DifficultyChip(fight)
		local tag = ""
		if fight.wipe then
			tag = fight.bossPct
				and (" |cffe64d4d%s|r"):format(TP.PullProgress(fight))
				or " |cffe64d4dwipe|r"
			-- the furthest attempt on this boss, at a glance. A WORD, not a
			-- glyph: WoW's default face has patchy symbol coverage and an
			-- unrenderable marker shows the player a hollow box.
			if bestPulls[fight] then
				tag = tag .. " |cffffd36ebest|r"
			end
		elseif fight.practice then
			tag = " |cff66ccffpractice|r"
		else
			-- a kill used to be the ABSENCE of a tag; naming it lets the eye
			-- find it in a wall of attempts
			tag = " |cff7ec98akill|r"
		end
		return ("%s%s · %d:%02d%s"):format(chip and (chip .. " ") or "",
			name, math.floor(d / 60), d % 60, tag)
	end
	local function selectFight(f)
		pinnedFight = f -- nil = back to Current
		scrollOffset = 0
		MeterWindow:Invalidate()
	end
	-- ---------------------------------------------------------------- picker
	-- Blizzard's dropdown is a MenuUtil context menu, and its buttons are TEXT
	-- plus colour escapes - no borders, no columns, no right alignment. That
	-- is the whole reason the picker never looked like the mockup (Josh
	-- 2026-08-05: "we are losing a lot by not following the design mockup").
	-- So the picker is our own frame. Every piece of it already existed here:
	-- the window's backdrop, tierChip's 1px-inset chip, and wheel scrolling.
	-- Anchoring is ours end to end, which is also why this is SAFER than
	-- decorating menu buttons - nothing depends on Blizzard's internals.
	-- Proportions taken off the mockup rather than guessed: a 20px row against
	-- a 13px name, and a heading with room to breathe above its group.
	local PICK_ROW_H, PICK_HEAD_H = 20, 23
	local PICK_CHIP_W, PICK_CHIP_H = 30, 14
	local PICK_VISIBLE = 14 -- entries on screen; the wheel reaches the rest
	local picker, pickRows, pickEntries, pickScroll = nil, {}, {}, 0
	local function entryHeight(e)
		return (e and e.kind == "head") and PICK_HEAD_H or PICK_ROW_H
	end

	local function hexToRGB(hex)
		if not hex or #hex < 6 then return 0.6, 0.63, 0.65 end
		return tonumber(hex:sub(1, 2), 16) / 255,
			tonumber(hex:sub(3, 4), 16) / 255,
			tonumber(hex:sub(5, 6), 16) / 255
	end

	local function makePickRow(parent)
		local row = CreateFrame("Button", nil, parent)
		row:SetHeight(PICK_ROW_H)
		row.hl = row:CreateTexture(nil, "BACKGROUND")
		row.hl:SetAllPoints()
		row.hl:SetColorTexture(1, 1, 1, 0.07)
		row.hl:Hide()
		row:SetScript("OnEnter", function(self) self.hl:Show() end)
		row:SetScript("OnLeave", function(self) self.hl:Hide() end)

		-- Selection dot, as TWO textures from Blizzard's radio art. The ring
		-- is always drawn; the centre only when selected. One texture could
		-- not do it: the "checked" quadrant is a pinprick meant to sit INSIDE
		-- a ring, so on its own it read as a speck rather than the mockup's
		-- filled circle. Drawing both, with the centre scaled up, gives a
		-- gold dot inside a gold ring at any size.
		row.dot = row:CreateTexture(nil, "ARTWORK")
		row.dot:SetSize(16, 16)
		row.dot:SetPoint("LEFT", 7, 0)
		row.dot:SetTexture("Interface\\Buttons\\UI-RadioButton")
		row.dot:SetTexCoord(0, 0.25, 0, 1)
		row.dotFill = row:CreateTexture(nil, "OVERLAY")
		row.dotFill:SetSize(11, 11)
		row.dotFill:SetPoint("CENTER", row.dot, "CENTER", 0, 0)
		row.dotFill:SetTexture("Interface\\Buttons\\UI-RadioButton")
		row.dotFill:SetTexCoord(0.25, 0.5, 0, 1)
		row.dotFill:Hide()

		-- difficulty chip: tierChip's construction, at row scale
		row.chip = CreateFrame("Frame", nil, row)
		row.chip:SetSize(PICK_CHIP_W, PICK_CHIP_H)
		row.chip:SetPoint("LEFT", row.dot, "RIGHT", 7, 0)
		row.chip.bg = row.chip:CreateTexture(nil, "BACKGROUND")
		row.chip.bg:SetAllPoints()
		row.chip.edges = {}
		for i = 1, 4 do
			local e = row.chip:CreateTexture(nil, "BORDER")
			if i == 1 then e:SetPoint("TOPLEFT"); e:SetPoint("TOPRIGHT"); e:SetHeight(1)
			elseif i == 2 then e:SetPoint("BOTTOMLEFT"); e:SetPoint("BOTTOMRIGHT"); e:SetHeight(1)
			elseif i == 3 then e:SetPoint("TOPLEFT"); e:SetPoint("BOTTOMLEFT"); e:SetWidth(1)
			else e:SetPoint("TOPRIGHT"); e:SetPoint("BOTTOMRIGHT"); e:SetWidth(1) end
			row.chip.edges[i] = e
		end
		row.chip.label = row.chip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		row.chip.label:SetPoint("CENTER", 0, 0)
		local cf = row.chip.label:GetFont()
		if cf then row.chip.label:SetFont(cf, 9, "") end

		local function fs(size)
			local t = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
			local f = t:GetFont()
			if f then t:SetFont(f, size, "") end
			return t
		end
		-- RIGHT-anchored and laid out right to left, so the columns line up
		-- however long a boss name is - the thing plain text could not do.
		-- The best marker is a DIAMOND, and a rotated square texture rather
		-- than a glyph, because WoW's face has patchy symbol coverage and an
		-- unrenderable character shows a hollow box.
		row.best = row:CreateTexture(nil, "OVERLAY")
		row.best:SetSize(7, 7)
		row.best:SetColorTexture(1, 0.827, 0.43, 1)
		row.best:SetPoint("RIGHT", -8, 0)
		if row.best.SetRotation then
			row.best:SetRotation(math.rad(45))
		end
		row.prog = fs(12)
		row.prog:SetPoint("RIGHT", row.best, "LEFT", -6, 0)
		row.prog:SetJustifyH("RIGHT")
		row.time = fs(12)
		row.time:SetPoint("RIGHT", row.prog, "LEFT", -8, 0)
		row.time:SetJustifyH("RIGHT")
		row.name = fs(12)
		row.name:SetPoint("LEFT", row.chip, "RIGHT", 9, 0)
		row.name:SetPoint("RIGHT", row.time, "LEFT", -6, 0)
		row.name:SetJustifyH("LEFT")
		row.name:SetWordWrap(false)

		-- group heading: gold zone name over a hairline, drawn by the same
		-- row so the list stays one flat, scrollable sequence
		row.head = fs(12)
		row.head:SetPoint("LEFT", 9, 0)
		row.head:SetPoint("BOTTOM", row, "BOTTOM", 0, 3)
		row.head:SetTextColor(1, 0.827, 0.43)
		row.rule = row:CreateTexture(nil, "ARTWORK")
		row.rule:SetColorTexture(0.22, 0.19, 0.30, 0.95)
		row.rule:SetHeight(1)
		row.rule:SetPoint("TOPLEFT", 0, 0)
		row.rule:SetPoint("TOPRIGHT", 0, 0)
		return row
	end

	local function paintPickRow(row, e)
		if e.kind == "head" then
			row.head:SetText(e.text)
			row.head:Show()
			row.rule:SetShown(not e.first)
			row.dot:Hide(); row.dotFill:Hide(); row.chip:Hide()
			row.name:Hide(); row.time:Hide(); row.prog:Hide(); row.best:Hide()
			row:SetScript("OnClick", nil)
			row:EnableMouse(false)
			return
		end
		row.head:Hide(); row.rule:Hide()
		row.dot:Show(); row.name:Show(); row.time:Show()
		row:EnableMouse(true)

		local sel = e.fight == pinnedFight or (e.current and pinnedFight == nil)
		row.dot:SetVertexColor(sel and 1 or 0.62, sel and 0.827 or 0.64, sel and 0.43 or 0.70)
		row.dotFill:SetVertexColor(1, 0.827, 0.43)
		row.dotFill:SetShown(sel)

		if e.current then
			row.chip:Hide()
			row.name:ClearAllPoints()
			row.name:SetPoint("LEFT", row.dot, "RIGHT", 7, 0)
			row.name:SetPoint("RIGHT", row.time, "LEFT", -6, 0)
			row.name:SetText("Current")
			row.name:SetTextColor(0.91, 0.90, 0.87)
			row.time:SetText("")
			row.prog:SetText("follows new fights")
			row.prog:SetTextColor(0.45, 0.47, 0.53)
			row.best:Hide()
			row:SetScript("OnClick", function() selectFight(nil); picker:Hide() end)
			return
		end

		local f = e.fight
		local _, chip, colour = TP.DifficultyParts(f)
		if chip then
			local r, g, b = hexToRGB(colour)
			row.chip:Show()
			row.chip.bg:SetColorTexture(r, g, b, 0.13)
			for _, t in ipairs(row.chip.edges) do t:SetColorTexture(r, g, b, 0.85) end
			row.chip.label:SetText(chip)
			row.chip.label:SetTextColor(r, g, b)
			row.name:ClearAllPoints()
			row.name:SetPoint("LEFT", row.chip, "RIGHT", 8, 0)
			row.name:SetPoint("RIGHT", row.time, "LEFT", -6, 0)
		else
			row.chip:Hide()
			row.name:ClearAllPoints()
			row.name:SetPoint("LEFT", row.dot, "RIGHT", 7, 0)
			row.name:SetPoint("RIGHT", row.time, "LEFT", -6, 0)
		end

		row.name:SetText((f.name or "Fight"):gsub("^%(!%)%s*", ""))
		row.name:SetTextColor(0.91, 0.90, 0.87)
		local d = f.duration or 0
		row.time:SetText(("%d:%02d"):format(math.floor(d / 60), math.floor(d % 60)))
		-- The DURATION stays neutral and only the outcome carries colour, as
		-- in the mockup. Colouring both made every wipe row a wall of red and
		-- lost the one word the eye is actually looking for.
		row.time:SetTextColor(0.91, 0.90, 0.87)

		if f.wipe then
			row.prog:SetText(TP.PullProgress(f) or "wipe")
			row.prog:SetTextColor(0.90, 0.30, 0.30)
		elseif f.practice then
			row.prog:SetText("practice")
			row.prog:SetTextColor(0.40, 0.80, 1)
		else
			row.prog:SetText("kill")
			row.prog:SetTextColor(0.49, 0.79, 0.54)
		end
		row.prog:Show()
		row.best:SetShown(f.wipe and e.best or false)
		row:SetScript("OnClick", function() selectFight(f); picker:Hide() end)
	end

	local function layoutPicker()
		local n = #pickEntries
		local visible = math.min(PICK_VISIBLE, n)
		pickScroll = math.max(0, math.min(pickScroll, n - visible))
		-- surplus rows stay in the pool, just hidden
		for i = #pickRows, visible + 1, -1 do
			pickRows[i]:Hide()
		end
		local y = 5
		for i = 1, visible do
			local row = pickRows[i]
			if not row then
				row = makePickRow(picker)
				pickRows[i] = row
			end
			local e = pickEntries[i + pickScroll]
			local h = entryHeight(e)
			row:SetHeight(h)
			row:ClearAllPoints()
			row:SetPoint("TOPLEFT", 5, -y)
			row:SetPoint("TOPRIGHT", -5, -y)
			row:Show()
			paintPickRow(row, e)
			y = y + h
		end
		-- extra room at the bottom so the down arrow sits in padding instead
		-- of over the last row's text
		picker:SetHeight(y + 11)
		-- Same arrows the meter uses, for the same reason: without them a
		-- capped list looks like the whole list (Josh 2026-08-05).
		picker.up:SetShown(pickScroll > 0)
		picker.down:SetShown(n - (pickScroll + visible) > 0)
	end

	local function buildPickEntries()
		local fights = TP.FightHistory.fights
		pickEntries = { { kind = "row", current = true, first = true } }
		local shown = math.min(#fights, 25)
		local best = markBestPulls(fights, shown)
		local prev
		for i = 1, shown do
			local f = fights[i]
			-- ONE heading per instance visit even when difficulty changes
			-- mid-night; the chip on each row carries 10N vs 10H.
			if not prev or (f.zone or "?") ~= (prev.zone or "?")
				or math.abs((prev.capturedAt or 0) - (f.capturedAt or 0)) > 3600 then
				pickEntries[#pickEntries + 1] =
					{ kind = "head", text = f.zone or "Unknown", first = #pickEntries == 1 }
			end
			prev = f
			pickEntries[#pickEntries + 1] = { kind = "row", fight = f, best = best[f] }
		end
	end

	local function openFightPicker(anchor)
		if #TP.FightHistory.fights == 0 then
			return false
		end
		if not picker then
			picker = CreateFrame("Frame", "TrueParseFightPicker", UIParent, "BackdropTemplate")
			picker:SetBackdrop({
				bgFile = "Interface\\Buttons\\WHITE8X8",
				edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
				edgeSize = 12,
				insets = { left = 3, right = 3, top = 3, bottom = 3 },
			})
			picker:SetBackdropColor(0.043, 0.047, 0.063, 0.98)
			picker:SetBackdropBorderColor(0.220, 0.192, 0.298, 0.95)
			picker:SetFrameStrata("DIALOG")
			picker:EnableMouse(true)
			picker:EnableMouseWheel(true)

			-- scroll indicators, built the way mkArrow builds the meter's
			local function pickArrow(tex, point, yOff)
				local f = CreateFrame("Frame", nil, picker)
				f:SetSize(26, 11)
				f:SetFrameLevel(picker:GetFrameLevel() + 10)
				local bg = f:CreateTexture(nil, "BACKGROUND")
				bg:SetAllPoints()
				bg:SetColorTexture(0, 0, 0, 0.75)
				local t = f:CreateTexture(nil, "OVERLAY")
				t:SetSize(14, 10)
				t:SetPoint("CENTER", 0, 0)
				t:SetTexture(tex)
				f:SetPoint(point, 0, yOff)
				f:Hide()
				return f
			end
			picker.up = pickArrow("Interface\\Buttons\\Arrow-Up-Up", "TOP", -2)
			picker.down = pickArrow("Interface\\Buttons\\Arrow-Down-Up", "BOTTOM", 2)
			picker:SetScript("OnMouseWheel", function(_, delta)
				local visible = math.min(PICK_VISIBLE, #pickEntries)
				local newOffset = math.max(0,
					math.min(pickScroll - delta, #pickEntries - visible))
				if newOffset ~= pickScroll then
					pickScroll = newOffset
					layoutPicker()
				end
			end)
			-- click anywhere else, or press Escape, closes it - the two things
			-- a real dropdown does that a bare frame does not. Keyboard input
			-- PROPAGATES, so capturing Escape here never swallows a keystroke
			-- meant for chat or a bind.
			picker:EnableKeyboard(true)
			picker:SetScript("OnKeyDown", function(self, key)
				if key == "ESCAPE" then
					if self.SetPropagateKeyboardInput then
						self:SetPropagateKeyboardInput(false)
					end
					self:Hide()
				elseif self.SetPropagateKeyboardInput then
					self:SetPropagateKeyboardInput(true)
				end
			end)
			picker:SetScript("OnShow", function(self)
				if self.SetPropagateKeyboardInput then
					self:SetPropagateKeyboardInput(true)
				end
			end)
			-- CLOSING ON AN OUTSIDE CLICK, WITHOUT EATING IT. This started as a
			-- fullscreen catcher Button, which closed the picker but also
			-- swallowed the mouse-down - so right-click-dragging to spin the
			-- camera just dismissed the menu and the camera never moved
			-- (Josh 2026-08-05). A frame that takes mouse input cannot pass
			-- it through to the world, so the catcher had to go entirely.
			-- GLOBAL_MOUSE_DOWN is an EVENT: it reports the click without
			-- consuming it, which is how Blizzard's own menus manage this.
			local ok = pcall(picker.RegisterEvent, picker, "GLOBAL_MOUSE_DOWN")
			if ok then
				picker:SetScript("OnEvent", function(self)
					-- clicks on the dropdown button itself are ITS business:
					-- closing here would race its OnClick and the picker would
					-- shut and immediately reopen
					if self:IsMouseOver() then return end
					if self.anchor and self.anchor:IsMouseOver() then return end
					self:Hide()
				end)
			end
			-- Frames are born SHOWN. Without this the first click created the
			-- picker, the toggle below saw it as already open, and hid it -
			-- so the first click did nothing and the second one worked.
			picker:Hide()
		end
		if picker:IsShown() then
			picker:Hide()
			return true
		end
		pickScroll = 0
		buildPickEntries()
		picker.anchor = anchor -- so an outside click can spare the button
		picker:ClearAllPoints()
		picker:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
		picker:SetWidth(math.max(300, window:GetWidth() - 12))
		layoutPicker()
		picker:Show()
		picker:Raise()
		return true
	end

	-- Kept for any client without the modern menu API, and as the reference
	-- for what the picker used to be.
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
			-- ONE heading per instance visit, even when the difficulty changes
			-- mid-night (Josh 2026-08-05: "raids can change difficulty from
			-- fight to fight ... a single Siege of Orgrimmar heading, with a
			-- mix of 10N and 10H tags"). runID deliberately SPLITS on
			-- difficulty, because run averages must not blend 10N with 10H -
			-- so the menu groups on its own, coarser rule and leaves runID
			-- alone. Difficulty now rides each row instead of the title.
			local shown = math.min(#fights, 25)
			bestPulls = markBestPulls(fights, shown)
			local prev
			for i = 1, shown do
				local f = fights[i]
				-- the list runs newest-first, so an hour of daylight between
				-- neighbours is the boundary between two nights
				if not prev or (f.zone or "?") ~= (prev.zone or "?")
					or math.abs((prev.capturedAt or 0) - (f.capturedAt or 0)) > 3600 then
					root:CreateTitle(f.zone or "Unknown")
				end
				prev = f
				root:CreateRadio(fightLabel(f),
					function() return pinnedFight == f end,
					function() selectFight(f) end)
			end
		end)
		return true
	end
	window.fightDrop:SetScript("OnClick", function(self)
		-- our own panel first; the Blizzard menu and click-cycling remain as
		-- fallbacks so a failure here degrades instead of breaking the picker
		local ok, opened = TP.Trap("fightPicker", openFightPicker, self)
		if ok and opened then
			return
		end
		if not openFightMenu(self) then
			MeterWindow:StepFight(1) -- no menu API: old cycling behavior
		end
	end)

	-- Mode strip along the bottom edge: Real = the full contribution score,
	-- Raw = pure throughput vs WCL top logs (damage, healing for healers)
	-- summary leads at +2pt, detail sits under it at the default size (the
	-- house pattern, Josh 2026-07-28): the one-liner is the whole answer for
	-- anyone who just wants one.
	local function makeRadio(labelText, mode, summary, detail, gearNote)
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
			local body = { { summary, 0.95, 0.95, 0.95, size = 13 } }
			if detail then
				body[#body + 1] = { detail, 0.66, 0.66, 0.70 }
			end
			-- Gear handling is the whole difference between the two lenses now
			-- (Josh 2026-08-01), and "why doesn't this match my WCL parse" is
			-- the first question it raises - so answer it where the lens is
			-- chosen rather than in an options panel nobody opens.
			if gearNote then
				body[#body + 1] = { gearNote, 0.55, 0.70, 0.55 }
			end
			if not self:IsEnabled() then
				body[#body + 1] = { "No Warcraft Logs data covers this fight.", 0.95, 0.5, 0.5 }
			end
			TP.Tooltip:Show(self, "TOP", labelText, body)
		end)
		btn:SetScript("OnLeave", function()
			TP.Tooltip:Hide()
		end)
		return btn
	end
	-- Column labels over the two number columns, aligned to their edges
	window.modeReal = makeRadio("TrueParse", "contribution",
		"Scores your whole contribution.",
		"Damage, healing, damage taken, interrupts and more, weighted for your spec and role.",
		"Adjusted for your item level, so the score reflects how you played rather than what you are wearing.")
	window.modeRaw = makeRadio("Raw", "parse",
		"Your Warcraft Logs parse only.",
		"Damage for DPS and tanks, healing for healers, against ranked logs for your spec.",
		"No gear adjustment - this is the number Warcraft Logs would give you.")
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
	-- portrait alpha mask rendered as a colored CIRCLE: exists on every
	-- client (Indicator-* files are retail-only and rendered as nothing)
	window.footnote:SetText("|TInterface\\CharacterFrame\\TempPortraitAlphaMask:8:8:0:0:64:64:0:64:0:64:51:217:64|t = Addon installed")

	-- the footer collapses the window like the header does — everywhere
	-- except the mode radios (which keep their own clicks) and the grip
	window.footerButton = CreateFrame("Button", nil, window)
	window.footerButton:SetPoint("BOTTOMLEFT", 0, 0)
	window.footerButton:SetPoint("BOTTOMRIGHT", window.modeReal, "BOTTOMLEFT", -12, -6)
	window.footerButton:SetHeight(MODE_HEIGHT)
	window.footerButton:RegisterForDrag("LeftButton")
	window.footerButton:SetScript("OnDragStart", startDrag)
	window.footerButton:SetScript("OnDragStop", stopDrag)
	window.footerButton:SetScript("OnClick", function()
		MeterWindow:ToggleCollapse()
	end)
	MeterWindow:UpdateModeButtons()
	MeterWindow:UpdateTierChip(nil)
	-- every header widget now exists, so the grid can actually be laid
	MeterWindow:LayoutHeader()
end

-- the fight pinned in the selector (nil = Current); the reports panel
-- scopes manual reports to this (Josh 2026-07-25)
function MeterWindow:SelectedFight()
	return pinnedFight
end

-- back to Current (a cleared history would leave the pin dangling)
function MeterWindow:ResetSelection()
	pinnedFight = nil
	scrollOffset = 0
end

-- Lays the header onto the same grid as the rows below it. The selector ends
-- where the class bars end; the tier chip, reports icon and cog each sit
-- centred in the row column beneath them (penalty / score / run average).
-- Recomputed rather than fixed: the "RAW" tag comes and goes, and the
-- selector should take that width back either way.
function MeterWindow:LayoutHeader()
	if not (window and window.fightDrop) then
		return
	end
	local dropInset = (HEADER_HEIGHT - 16) / 2
	local mid = -(dropInset + 8) -- vertical centre of the selector band

	-- selector: from just past the mark, out to where the class bars end
	local tagW = window.title:GetStringWidth() or 0
	local left = PADDING + LOGO_SIZE + 5 + (tagW > 0 and (tagW + 5) or 0)
	window.fightDrop:ClearAllPoints()
	window.fightDrop:SetPoint("TOPLEFT", left, -dropInset)
	window.fightDrop:SetPoint("TOPRIGHT", -(PADDING + COL_RESERVE), -dropInset)

	-- one helper so all three land the same way: centred in their column
	local function place(widget, col)
		if not widget then
			return
		end
		local centreFromRight = PADDING + col.right + col.w / 2
		widget:ClearAllPoints()
		widget:SetPoint("CENTER", window, "TOPRIGHT", -centreFromRight, mid)
	end
	place(window.chat, COL.score)
	place(window.cog, COL.runAvg)

	-- Collapsed, the chat and cog are hidden and there is no row grid to line
	-- up with — so the chip takes the far right edge and hands the two
	-- columns it was leaving empty back to the encounter name (Josh
	-- 2026-07-28). Expanded, it sits in the penalty column like a header.
	-- The nil guard is not optional: createWindow calls LayoutHeader once to
	-- position the selector BEFORE the chip exists, and a window saved in the
	-- collapsed state took this branch and errored on PLAYER_LOGIN.
	if not window.tierChip then
		return
	end
	if db().window.collapsed or autoCollapsed then
		window.tierChip:ClearAllPoints()
		window.tierChip:SetPoint("CENTER", window, "TOPRIGHT",
			-(PADDING + TIER_CHIP_W / 2), mid)
	else
		place(window.tierChip, COL.penalty)
	end
end

function MeterWindow:UpdateModeButtons()
	if not (window and window.modeReal) then
		return
	end
	local raw = db().scoring.mode == "parse"
	window.modeReal:SetChecked(not raw)
	window.modeRaw:SetChecked(raw)
end

-- Set the chip to the tier the SELECTED encounter's score came from.
-- Engine numbering throughout (1 = direct); see TIERS. tier = nil means
-- nothing is scored on screen (empty/waiting state) and the chip hides
-- rather than describing a fight that isn't there.
function MeterWindow:UpdateTierChip(tier, how)
	lastTier = tier
	if not (window and window.tierChip) then
		return
	end
	window.tierChip.tierHow = how
	local def
	for _, t in ipairs(TIERS) do
		if t.tier == tier then
			def = t
		end
	end
	window.tierChip.tierDef = def
	if not def then
		window.tierChip:Hide()
		return
	end
	window.tierChip:Show()
	window.tierChip.label:SetText(def.numeral)
	window.tierChip.label:SetTextColor(def.r, def.g, def.b)
	-- filled plate, not a dimmed sibling: the fill is what makes the tier
	-- read at 9px against a class-coloured row or open terrain. Sitting on
	-- the selector pill rather than the window ground, it needs more fill
	-- and a firmer edge than the mockup's values to separate.
	window.tierChip.bg:SetColorTexture(def.r, def.g, def.b, 0.26)
	for _, e in ipairs(window.tierChip.edges) do
		e:SetColorTexture(def.r, def.g, def.b, 0.85)
	end
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
	-- collapsed, the footer button would overlap the title bar
	if window.footerButton then
		window.footerButton:SetShown(shown)
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

-- "Wipe it" visibility: option on + Classic + mid-combat boss segment +
-- not yet called + in a group + permitted (lead/assist when any officer
-- runs TrueParse; anyone otherwise). Everything here is cheap and
-- event-driven — no ticker.
function MeterWindow:UpdateWipeButton()
	if not window or not window.wipeBtn then
		return
	end
	local seg = TP.Segments and TP.Segments.current
	-- training dummies count as boss-ish and drop the group requirement:
	-- the button is rehearsable exactly where everything else is (the
	-- press is harmless there — a non-wipe voids the call anyway)
	local practice = seg and not seg.encounterID
		and (seg.name or ""):find("Training Dummy", 1, true) ~= nil
	local show = db().wipeButton
		and not TP.Compat.IS_RETAIL
		and seg ~= nil
		and (seg.encounterID ~= nil or practice)
		and not seg.manualWipeAt
		and UnitAffectingCombat("player")
		and (IsInGroup() or practice)
		-- A dungeon has no lead/assist hierarchy worth deferring to, so
		-- anyone may call it there; raids keep the officer rule (Josh
		-- 2026-07-28).
		and (IsInRaid() == false
			or (TP.Sync and TP.Sync.WipeCallPermitted and TP.Sync:WipeCallPermitted()))
	if show then
		-- hang off whichever window edge faces screen center, so the
		-- button never runs off-screen and never sits on the header
		local btn = window.wipeBtn
		btn:ClearAllPoints()
		local _, wy = window:GetCenter()
		if wy and wy < (UIParent:GetHeight() / 2) then
			btn:SetPoint("BOTTOM", window, "TOP", 0, 8)
		else
			btn:SetPoint("TOP", window, "BOTTOM", 0, -8)
		end
	end
	window.wipeBtn:SetShown(show and true or false)
end

function MeterWindow:OnEnable()
	createWindow()
	self:ApplyPosition()
	if db().window.shown then
		window:Show()
	else
		window:Hide()
	end

	-- own frame: AceEvent allows one handler per event per object, and
	-- other modules already listen to the regen events on TP.Addon
	local ctFrame = CreateFrame("Frame")
	ctFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
	ctFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
	-- lead/assist can change mid-fight: the wipe button's permission moves
	ctFrame:RegisterEvent("GROUP_ROSTER_UPDATE")
	ctFrame:SetScript("OnEvent", function(_, event)
		if event == "PLAYER_REGEN_DISABLED" then
			if db().window.clickThroughCombat then
				applyClickThrough(true)
			end
		elseif event == "PLAYER_REGEN_ENABLED" then
			-- roster updates must NOT restore clicks mid-combat
			applyClickThrough(false)
		end
		MeterWindow:UpdateWipeButton()
	end)
	TP.Addon:RegisterMessage("TrueParse_WIPE_CALLED", function()
		MeterWindow:UpdateWipeButton()
	end)

	TP.Addon:RegisterMessage("TrueParse_SEGMENT_CHANGED", function()
		-- No live view on any client — when a fight starts, give the
		-- screen back
		MeterWindow:UpdateWipeButton()
		if TP.Segments.current and db().window.autoCollapse then
			autoCollapsed = true
			TP.BreakdownPanel:HideAll()
		elseif not TP.Segments.current then
			-- segment ENDED: reopen even when nothing captures (trash
			-- pulls fire no FIGHT_CAPTURED, so the auto-collapse used
			-- to stick until manual clicks — 2026-07-16 report of the
			-- first expand click doing nothing after fights)
			autoCollapsed = false
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
	-- persist the re-anchor: collapse moves the frame's visual position
	-- (bottom-pinning), and restoring the stale expanded-era point after
	-- a reload teleported the bar somewhere else entirely
	savePosition()
end

-- The window height is USER-set (resize grip); rows render into whatever
-- fits. How many row slots the current height offers:
-- breathing room + divider above the pinned Raid/Group row (Josh
-- 2026-07-25: it read as just another player row)
local GROUP_GAP = 5

local function contentSlots(rowHeight, withColHead)
	-- bottom reserve is just the mode strip plus a hair of air: doubling
	-- the padding left a dead band under the pinned Raid row
	local chrome = HEADER_HEIGHT + (withColHead and COLHEAD_HEIGHT or 0)
		+ MODE_HEIGHT + PADDING + (withColHead and GROUP_GAP or 0)
	return math.max(1, math.floor((db().window.height - chrome) / (rowHeight + 1)))
end

local function setWindowHeight(withColHead, maxHeight)
	setModeStripShown(true)
	-- presence-mark legend only makes sense on the scorecard; it shares
	-- the bottom line with the radios, so no extra height
	if window.footnote then
		window.footnote:SetShown(withColHead and true or false)
	end
	-- the saved height is the user's intent; the DISPLAYED height never
	-- exceeds the content (no empty space below the last row). A bigger
	-- group later grows back into the saved height automatically.
	applyWindowHeight(math.min(db().window.height, maxHeight or math.huge))
end

-- ========================= Scorecard (primary) =========================

-- Score a fight for display. Raw mode requires WCL evidence (a percentile
-- curve or benchmark median) somewhere on the card — a "parse" against
-- nothing but your own group is noise, so those fights render True scores
-- and the Raw radio disables. Returns results, rawAvailable.
-- MUST be defined above every caller: a later definition compiles callers'
-- references as globals (nil) — exactly the blank-window bug this fixes.
local function anyWclEvidence(parseResults)
	-- A DERIVED fight has no parse to show (Josh 2026-07-28). Its True score
	-- comes from WCL curves sampled on OTHER content, gear- and
	-- difficulty-scaled to fit; calling that a "parse" would be a lie, and
	-- the unscaled comparison Raw would otherwise draw reads ~0 for everyone
	-- in a leveling dungeon. The engine flags the tier in BOTH modes so this
	-- check works off the parse results it already has.
	if parseResults[1] and parseResults[1].derived then
		return false
	end
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

-- (run means use scoreForDisplay: the avg column follows the ACTIVE
-- lens — True avgs under a Raw card read as a bug, 2026-07-14)

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
-- Tier of the fight currently on the card. Remembered separately from
-- lastTier (which is whatever the STRIP is showing) because the cheap
-- re-render path below returns early: without this, zoning to a
-- nothing-recorded state blanked the strip, and coming back to the SAME
-- fight took the early return and never re-lit it (Josh 2026-07-28).
local lastFightTier = 1
local lastFightHow -- per-fight override for the chip's footnote

-- Every row of a scored fight carries the same tier, but a fight can score
-- to an empty result set; read it defensively.
--
-- `derived` is stamped only where a CURVE produced the score, so a fight no
-- WCL data covers at all comes back nil - and defaulting that to DIRECT made
-- the chip promise "a 1:1 comparison against Warcraft Logs" for a training
-- dummy (Josh 2026-07-30: "how do we have WCL data for target dummy?"). It
-- doesn't; the metric tooltip on the same card already said "no WCL
-- population data - vs group share". No evidence is tier III, whose headline
-- is exactly right: nothing on Warcraft Logs covers this fight.
-- A fight that can explain its own tier better than the generic footnote.
-- Practice is the case that matters: tier II's stock line names dungeons and
-- Mythic+, which says nothing true about a training dummy.
local function tierHowFor(fight)
	if fight and fight.practice then
		local anchor = TP.PRACTICE_ANCHOR and TP.PRACTICE_ANCHOR.name
		return anchor
			and ("Not a real parse: nobody ranks a training dummy, so your rotation is measured against %s's curves."):format(anchor)
			or "Not a real parse: nobody ranks a training dummy, and this client has no anchor fight to stand in for one."
	end
	return nil
end

local function tierOfResults(results, wclBacked)
	local r = results and results[1]
	local tier = r and r.derived
	if tier then
		return tier
	end
	return wclBacked and 1 or 3
end

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
			-- best-pull number right in the label: "wipe 12% · Garrosh"
			label = fight.bossPct
				and ("|cffe64d4d%s|r · "):format(TP.WipeLabel(fight)) .. label
				or "|cffe64d4dwipe|r · " .. label
		elseif fight.practice then
			label = "|cff66ccffpractice|r · " .. label
		end
		if UnitAffectingCombat("player") then
			label = label .. " |cffff8888· fighting…|r"
		end
		return label
	end

	if lastRenderedFight == fight and lastScrollOffset == scrollOffset then
		-- scores are static once captured; only the subtitle changes.
		-- The strip still gets re-asserted: something else (the empty state)
		-- may have blanked it while this same fight stayed pinned.
		MeterWindow:UpdateTierChip(lastFightTier, lastFightHow)
		window.subtitle:SetText(subtitleText(lastRawAvailable))
		return
	end
	lastRenderedFight = fight
	lastScrollOffset = scrollOffset

	local results, rawAvailable = scoreForDisplay(fight)
	lastRawAvailable = rawAvailable
	-- the strip below the window says what the score is built on
	lastFightTier = tierOfResults(results, rawAvailable)
	lastFightHow = tierHowFor(fight)
	MeterWindow:UpdateTierChip(lastFightTier, lastFightHow)
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
			-- Pinning a fight whose Raw is unavailable used to leave the Raw
			-- radio checked but greyed while the card showed True numbers —
			-- the reading was right, the radio lied about it. Move the
			-- setting to match what is actually on screen (Josh 2026-07-28).
			if isRawSetting then
				db().scoring.mode = "contribution"
				MeterWindow:UpdateModeButtons()
			end
			window.modeRaw:Disable()
			-- a disabled button fires no OnEnter, so the "why is this
			-- disabled" tooltip was unreachable (audit 2026-07-16)
			window.modeRaw:SetMotionScriptsWhileDisabled(true)
		end
	end
	local rowHeight = SCORECARD_ROW_HEIGHT
	-- no artificial row cap: window height decides what fits, the wheel
	-- scrolls the rest (the old Max-rows option is gone)
	local shown = #results
	local width = db().window.width - PADDING * 2
	local hasFooter = #results >= 3

	-- Run row: THIS fight's run average (always True — same currency the
	-- chat reports use). A one-boss run just mirrors the fight score, but
	-- the column showing up and disappearing read as a bug — it's always
	-- there now. Browsing an old card shows that card's run, not whatever
	-- run is live now.
	local runFight, runResults, runScore, runBy
	if TP.RunSummary and TP.RunSummary.RunFor then
		local run, count, runFights = TP.RunSummary:RunFor(fight)
		if run and count and count >= 1 then
			-- the avg column is a true average of the player's per-fight
			-- scores in the ACTIVE lens (a Raw card gets Raw averages —
			-- True avgs next to single-digit Raw fights read as a bug).
			-- Scoring the summed aggregate instead let run-long
			-- adjustment totals saturate: 94/98/73 read as 99.
			-- Raw averages KILLS ONLY: WCL never ranks wipes, and a
			-- wipe's rates are structurally low (the dead contribute
			-- zero for the tail) — wipe-heavy runs read half their real
			-- parse (2026-07-14). True mode keeps grading attempts.
			local parseLens = TP.GetDisplayScoringOptions().mode == "parse"
			local sums, counts = {}, {}
			for _, f in ipairs(runFights or {}) do
				if not (parseLens and f.wipe) then
					for _, r in ipairs(scoreForDisplay(f)) do
						sums[r.guid] = (sums[r.guid] or 0) + r.score
						counts[r.guid] = (counts[r.guid] or 0) + 1
					end
				end
			end
			runBy = {}
			local total, n = 0, 0
			for guid, s in pairs(sums) do
				local entry = { guid = guid, score = s / counts[guid] }
				runBy[guid] = entry
				total = total + entry.score
				n = n + 1
			end
			if n > 0 then
				runScore = total / n
				runFight = run
				-- the right-click run breakdown still analyzes the
				-- aggregate (bullets over the whole run's data)
				runResults = scoreRun(run)
			else
				runBy = nil
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
		row:EnableMouse(not clickThrough)
		row:SetSize(width, rowHeight)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", PADDING, -(HEADER_HEIGHT + COLHEAD_HEIGHT + (i - 1) * (rowHeight + 1)))

		local gcr, gcg, gcb
		if TP.Scoring.Grades.IsShamed(r) then
			-- parsed nothing AND took penalties: the zero wears danger red
			local S = TP.Scoring.Grades.SHAME
			gcr, gcg, gcb = S[1], S[2], S[3]
		else
			gcr, gcg, gcb = TP.Scoring.Grades.ColorForScore(r.score)
		end

		-- Players not running TrueParse render dimmed: less data, not worse.
		-- The local player always has the addon (fights captured before the
		-- presence stamp existed rely on the isLocalPlayer fallback).
		local player = fight.players[r.guid]
		-- stamped at capture OR known live right now: a /reload used to
		-- wipe Sync.users and gray the whole raid until re-capture; live
		-- knowledge greens every card the moment their addon speaks
		local hasAddon = player and (player.hasAddon or player.isLocalPlayer
			or (TP.Sync and TP.Sync.users and TP.Sync.users[r.guid] ~= nil))
		row.name:SetAlpha(1)
		row.score:SetAlpha(1)
		row.penalty:SetAlpha(1)
		-- letters read ragged when right-aligned; numbers ragged when left
		local letterAlign = db().letterGrades and "LEFT" or "RIGHT"
		row.score:SetJustifyH(letterAlign)
		row.runAvg:SetJustifyH(letterAlign)
		row.icon:SetAlpha(1)
		if hasAddon then
			row.addonMark:SetVertexColor(0.20, 0.85, 0.25)
		else
			row.addonMark:SetVertexColor(0.45, 0.45, 0.45)
		end
		row.addonMark:Show()
		row.addonMarkBg:Show()

		-- Details-style: the row IS a solid class-colored bar with a white
		-- outlined name. TRUE class colors for everyone — the old muting
		-- wash turned a druid's orange into warrior tan and cost the card
		-- its class identity; the green/gray dot carries presence now.
		local cr, cg, cb = TP.ClassColor(r.class)
		row.bg:SetColorTexture(cr, cg, cb, 0.95)
		local barArea = math.max(40, width - COL_RESERVE)
		row.track:SetWidth(barArea)
		row.bg:SetWidth(math.max(8, barArea * math.min(math.max(r.score, 0), 100) / 100))
		row.icon:SetWidth(rowHeight)
		setSpecIcon(row.icon, player, r.class)
		if row.groupDivider then
			row.groupDivider:Hide() -- recycled footer row rendering a player
		end

		-- no award star here: it wrapped long cross-realm names and the
		-- row already carries a lot (awards live in the breakdown + toasts)
		-- Details-style rank prefix: position in THIS fight's standings
		row.name:SetText(("%d. %s"):format(i + scrollOffset, TP.ShortName(r.name)))
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
		row.score:SetText((approx and "~" or "")
			.. TP.Scoring.Grades.ScoreLabel(r.score, r.unclamped))
		row.score:SetTextColor(gcr, gcg, gcb)
		-- signed net adjustment on top of the WCL base: green earns, red costs
		local netAdj = r.adjust or -(r.penalty or 0)
		if netAdj >= 0.5 then
			row.penalty:SetText(("|cff6bc46f+%.0f|r"):format(netAdj))
		elseif netAdj <= -0.5 then
			row.penalty:SetText(("|cffe05a4f-%.0f|r"):format(-netAdj))
		else
			row.penalty:SetText("")
		end

		-- cumulative True run average, dimmed, far right (True currency in
		-- both modes: the distinct dimmed column carries the distinction)
		-- the cell keeps its width whenever the COLUMN exists: a 1px cell
		-- let the fight score slide into the run column's position
		local runR = runBy and runBy[r.guid]
		row.runAvg:SetWidth(runBy and 15 or 1)
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
		-- pooled rows carry stale mouse state (audit 2026-07-16: a row
		-- released while click-through-in-combat stayed dead forever
		-- when re-acquired as the footer)
		row:EnableMouse(not clickThrough)
		row:SetSize(width, rowHeight)
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", PADDING,
			-(HEADER_HEIGHT + COLHEAD_HEIGHT + (index - 1) * (rowHeight + 1) + GROUP_GAP))
		-- the divider rides the row frame, so it hides with it; player
		-- renders of a recycled footer row hide it explicitly
		if not row.groupDivider then
			row.groupDivider = row:CreateTexture(nil, "ARTWORK")
			row.groupDivider:SetColorTexture(0.361, 0.322, 0.459, 0.35) -- #5c5275
		end
		row.groupDivider:ClearAllPoints()
		-- pixel-snapped so it always rasterizes 1px like the card rules
		if PixelUtil then
			PixelUtil.SetPoint(row.groupDivider, "BOTTOMLEFT", row, "TOPLEFT", 0, 3)
			PixelUtil.SetPoint(row.groupDivider, "BOTTOMRIGHT", row, "TOPRIGHT", 0, 3)
			PixelUtil.SetHeight(row.groupDivider, 1, 1)
		else
			row.groupDivider:SetPoint("BOTTOMLEFT", row, "TOPLEFT", 0, 3)
			row.groupDivider:SetPoint("BOTTOMRIGHT", row, "TOPRIGHT", 0, 3)
			row.groupDivider:SetHeight(1)
		end
		row.groupDivider:Show()
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
			-- the group +/- = the sum of the group CARD's scored chips, so the
			-- row and the details card ALWAYS agree (Josh 2026-07-26: the old
			-- average-of-player-adjustments showed a -6 the card couldn't
			-- explain - those points live on the individual cards). This is the
			-- group-LEVEL net: kicks, raid buffs, and the like.
			local groupNet = 0
			local okg, gsigs = TP.Trap("Signals.GroupRows", TP.Scoring.Signals.GroupRows, results, fight)
			if okg then
				for _, s in ipairs(gsigs) do
					groupNet = groupNet + (s.points or 0)
				end
			end
			local n = groupNet >= 0 and math.floor(groupNet + 0.5) or -math.floor(-groupNet + 0.5)
			if n > 0 then
				row.penalty:SetText(("|cff6bc46f+%d|r"):format(n))
			elseif n < 0 then
				row.penalty:SetText(("|cffe05a4f%d|r"):format(n))
			else
				row.penalty:SetText("")
			end
		if runScore then
			row.runAvg:SetText(TP.Scoring.Grades.ScoreLabel(runScore))
			row.runAvg:SetTextColor(TP.Scoring.Grades.ColorForScore(runScore))
			row.runAvg:SetWidth(15)
		else
			row.runAvg:SetText("")
			row.runAvg:SetWidth(1)
		end
		row.sep2:SetShown(runScore ~= nil)
		row.bg:SetColorTexture(0.541, 0.459, 0.188, 0.95) -- #8a7530
		local barArea = math.max(40, width - COL_RESERVE)
		row.track:SetWidth(barArea)
		row.bg:SetWidth(math.max(8, barArea * math.min(math.max(groupScore, 0), 100) / 100))
		-- the group wears its own icon (Josh 2026-07-25)
		row.icon:SetWidth(rowHeight)
		row.icon:SetAlpha(1)
		row.icon:SetTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
		row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		row.icon:Show()
		row.addonMark:Hide()
		row.addonMarkBg:Hide()
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
		-- hug the bottom of the whole row area (the pinned Group row
		-- included) the same way the up arrow hugs the top
		window.scrollDown:SetPoint("TOP", 0,
			-(HEADER_HEIGHT + COLHEAD_HEIGHT + totalRows * (rowHeight + 1)
				+ (hasFooter and GROUP_GAP or 0) - 4))
		window.scrollDown:SetShown(hiddenBelow > 0)
	end

	-- the content is the ceiling: never render (or let the grip drag)
	-- empty space below the last row. FULL content, not the visible
	-- subset — deriving the ceiling from what currently fits made the
	-- ceiling follow every shrink down (couldn't resize back up).
	local contentH = HEADER_HEIGHT + COLHEAD_HEIGHT
		+ (shown + (hasFooter and 1 or 0)) * (rowHeight + 1)
		+ (hasFooter and GROUP_GAP or 0)
		+ MODE_HEIGHT + PADDING
	if window.SetResizeBounds then
		window:SetResizeBounds(180, 110, 640, math.max(110, contentH))
	elseif window.SetMaxResize then
		window:SetMaxResize(640, math.max(110, contentH))
	end
	setWindowHeight(true, contentH)
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
	local here, _, difficultyID, _, maxPlayers = GetInstanceInfo()
	-- scenario-TYPED content is only unsupported when it's a real MoP
	-- scenario (difficulty 11/12, 3-man); the Celestial dungeon mode is
	-- scenario-typed but captures like any dungeon (2026-07-24)
	local realScenario = instType == "scenario"
		and (difficultyID == 11 or difficultyID == 12 or (maxPlayers or 0) < 5)
	local unsupported = realScenario
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
	-- Mode indicator, COLLAPSED ONLY (Josh 2026-07-28). Expanded, the footer
	-- radios already say which mode you are in, so a tag in the header just
	-- repeats them and costs selector width. Collapsed, those radios are
	-- hidden and the tag is the only thing that can say it.
	local modeTag = (db().scoring.mode == "parse") and "RAW" or ""
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
		window.title:SetText(modeTag ~= "" and (modeTag .. " (+)") or "(+)")
		MeterWindow:LayoutHeader() -- chip moves to the right edge when collapsed
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
		-- Resolve the tier HERE too. Only RenderScorecard did it, and this
		-- branch returns before ever reaching it — so a window that started
		-- collapsed showed no chip until it was expanded once (Josh
		-- 2026-07-28). scoreForDisplay is memoised per fight, so on the
		-- collapsed path this is a table lookup after the first call.
		if latest and not waitingZone then
			lastFightTier = tierOfResults(scoreForDisplay(latest))
			-- scoreForDisplay returns (results, rawAvailable); the call above
			-- passes both through Lua's multiple returns
			lastFightHow = tierHowFor(latest)
			MeterWindow:UpdateTierChip(lastFightTier, lastFightHow)
		else
			MeterWindow:UpdateTierChip(nil)
		end
		window.fightDrop:Hide()
		window.cog:Hide()
		window.chat:Hide()
		window.LayoutSubtitle(true)
		if window.emptyTitle then
			window.emptyTitle:Hide()
			window.emptyMsg:Hide()
		end
		setModeStripShown(false)
		-- screen-half pinning (no pinTop): top half keeps the title bar in
		-- place, bottom half collapses DOWN to the window's bottom edge.
		-- Exactly one header tall: the centered title doesn't move between
		-- the collapsed bar and the expanded card's header band.
		applyWindowHeight(HEADER_HEIGHT)
		return
	end
	window.title:SetText("") -- expanded: the footer radios carry the mode
	MeterWindow:LayoutHeader()
	window.fightDrop:Show()
	window.cog:Show()
	window.chat:Show()
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
			-- "nothing recorded" would be a lie that reads as a bug. The
			-- age clock shows the retry is ALIVE (outdoor raids hold the
			-- lock longest — no leave-the-instance unlock edge)
			local age = TP.FightHistory.pendingSince
				and (time() - TP.FightHistory.pendingSince) or 0
			local ageText = age >= 60
				and (" Locked for %d min so far."):format(math.floor(age / 60)) or ""
			window.subtitle:SetText(here .. " · unlocking...")
			window.emptyTitle:SetText("Fight recorded - numbers still locked.")
			window.emptyMsg:SetText("Blizzard keeps combat data locked for a while after an encounter - longest for raids, and outdoor raids hold it longest of all (leaving the area usually releases it). Scores fill in automatically - no reload needed." .. ageText)
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
		-- nothing scored on screen: no tier applies, so the chip hides
		-- (leaving the last fight's tier up would describe the wrong fight)
		MeterWindow:UpdateTierChip(nil)
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
		print("|cffe05a4fTrueParse render error (please report):|r " .. tostring(err))
	end
end
