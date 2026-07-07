-- The main meter window. P1: sorted by damage done (verification against
-- Details). P5 switches the sort to the contribution score.
local _, TP = ...

local MeterWindow = {}
TP.MeterWindow = MeterWindow

local HEADER_HEIGHT = 22
local PADDING = 6

local window
local activeBars = {}
local sortScratch = {}
local lastDrawnRevision = -1

local function db()
	return TP.Addon.db.profile
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
	TP.Addon:ScheduleRepeatingTimer(function()
		MeterWindow:Refresh(false)
	end, 0.5)
	self:Refresh(true)
end

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

local function finishDraw(shown, barHeight)
	for i = #activeBars, shown + 1, -1 do
		TP.Bars:Release(activeBars[i])
		activeBars[i] = nil
	end
	window:SetHeight(HEADER_HEIGHT + math.max(shown, 1) * (barHeight + 1) + PADDING * 2)
end

local function sortByTotal(a, b)
	return a.totalAmount > b.totalAmount
end

-- Retail (12.0+): render straight from Blizzard's meter session.
function MeterWindow:RefreshFromBlizzardMeter()
	local Meter = TP.BlizzardMeter
	local session = Meter:GetSession(Enum.DamageMeterType.DamageDone)
	local conf = db().bars

	if Meter:IsLocked(session) then
		-- Mid-combat secret values: can't sort or format them. Keep the last
		-- drawn bars; this refresh loop recovers as soon as values unlock.
		window.subtitle:SetText("Damage · |cffff8888in combat|r")
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
	finishDraw(shown, conf.height)
end

local function sortByDamage(a, b)
	return a.damage.total > b.damage.total
end

-- Classic path: render from our own CLEU-fed segment accumulators.
function MeterWindow:RefreshFromSegments(force)
	local Segments = TP.Segments
	-- Nothing changes out of combat; skip redraw unless a segment event fired
	if not force and not Segments.current and Segments.revision == lastDrawnRevision then
		return
	end
	lastDrawnRevision = Segments.revision

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
	finishDraw(shown, conf.height)
end

function MeterWindow:Refresh(force)
	if not window or not window:IsShown() then
		return
	end
	if TP.BlizzardMeter.available then
		self:RefreshFromBlizzardMeter()
	else
		self:RefreshFromSegments(force)
	end
end
