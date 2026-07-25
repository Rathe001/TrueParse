-- Breakdown panel — the Signal Column (2026-07-26 redesign): each scored
-- signal is a micro-row of [icon][verdict label][marks][number][points].
-- Bars are 0-100 tinted by their own WCL bracket with a comparison tick
-- at the group average; counts are squares/pips (ghost squares = beyond
-- capacity); binaries are glyphs. Verdict labels state findings in <= 4
-- words; sentences live only in tooltips. Awards and the group card
-- keep gold/text rows. The panel IS the scorecard's tooltip: hovering a
-- row shows it, clicking pins it open, close/click unpins.
local _, TP = ...

local Panel = { pinned = false }
TP.BreakdownPanel = Panel

local WIDTH = 300
local ROW_HEIGHT = 16

-- Mockup type (Josh 2026-07-24): the clean condensed sans of the
-- quality-addon dialect (Details/WeakAuras ship it too) instead of
-- Friz Quadrata everywhere. Falls back to the template's face on
-- clients without ARIALN (CJK), keeping the mockup's sizes.
local FONT = "Fonts\\ARIALN.TTF"
local BAND_MIN = 8 -- spike-strip blocks: floor width so events read discrete
local function face(fs, size, flags)
	if not fs:SetFont(FONT, size, flags or "") then
		local path, _, fl = fs:GetFont()
		fs:SetFont(path, size, flags or fl)
	end
	return fs
end
local FIRST_ROW_Y = -40

local COUNT_METRICS = { interrupts = true, dispels = true }
local PERCENT_METRICS = { buffUptime = true }

local frame
local rows = {}

-- Tooltips from panel rows always open on the panel's FAR side — away
-- from the meter window — so they never cover it and never flip
-- direction mid-session (Josh 2026-07-26: "they randomly open either
-- left or right"). The side only changes if the window itself moves.
local function tipSide()
	local win = _G.TrueParseWindow
	if win and frame then
		local wx = win:GetCenter()
		local fx = frame:GetCenter()
		if wx and fx then
			return fx <= wx and "LEFT" or "RIGHT"
		end
	end
	return "LEFT"
end

-- Compact visual tooltip for METRIC bullets: what you did, the spec median,
-- and a parse-bracket gauge with a tick at your position — glanceable where
-- the old paragraph wasn't. Non-metric bullets use TP.Tooltip (same card).
local metricTip
local GAUGE_W = 190 -- also the metric tip's base width
local GAUGE_ZONES = { { 0, 25 }, { 25, 50 }, { 50, 75 }, { 75, 95 }, { 95, 100 } }

local function buildMetricTip()
	metricTip = CreateFrame("Frame", "TrueParseMetricTip", UIParent, "BackdropTemplate")
	metricTip:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	metricTip:SetBackdropColor(0.04, 0.04, 0.05, 1)
	metricTip:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	metricTip:SetSize(GAUGE_W + 24, 76)
	metricTip:SetClampedToScreen(true)
	metricTip:SetFrameStrata("TOOLTIP")
	metricTip:Hide()

	metricTip.title = face(metricTip:CreateFontString(nil, "OVERLAY", "GameFontNormal"), 14)
	metricTip.title:SetPoint("TOPLEFT", 10, -8)
	metricTip.value = face(metricTip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), 12)
	metricTip.value:SetPoint("TOPLEFT", 10, -24)
	-- multi-line value blocks (Tanking) left-align like everything else;
	-- without this the extra lines centered (Josh 2026-07-24)
	metricTip.value:SetJustifyH("LEFT")
	metricTip.median = face(metricTip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), 11)
	metricTip.median:SetPoint("TOPLEFT", 10, -38)
	-- no right anchor: the TIP fits its longest line (fitTipWidth), so
	-- lines never truncate or spill
	metricTip.median:SetJustifyH("LEFT")
	metricTip.median:SetWordWrap(false)

	-- (the parse-bracket gauge and the coach line both used to live here;
	-- each moved onto the card itself — the tip is pure metric text now)

	metricTip.footer = face(metricTip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), 11)
	metricTip.footer:SetPoint("BOTTOMLEFT", 10, 8)
end

local function showMetricTip(anchor, data)
	if not metricTip then
		buildMetricTip()
	end
	local b, key, duration = data.b, data.key, data.duration
	metricTip.title:SetText(data.title or TP.METRIC_LABELS[key] or key)

	-- The parse-bracket gauge implies a ranked population behind the
	-- number: show it only for WCL-backed comparisons. Share-scored
	-- metrics (kicks, dispels, tank soak) get words instead.
	local wclBacked = b.wclBacked or b.pctile ~= nil or (b.absolute and true) or false

	local valueText = data.valueText
	if not valueText then
		if COUNT_METRICS[key] then
			if key == "interrupts" and b.opportunities then
				-- opportunity data beats share phrasing when we have it
				valueText = ("Kicked %d · group got %d of %d casts"):format(
					b.value or 0, b.landed or 0, b.opportunities)
			elseif b.groupTotal and not wclBacked then
				valueText = ("%s %d of the group's %d"):format(
					key == "interrupts" and "Kicked" or "Dispelled",
					b.value or 0, b.groupTotal)
			else
				valueText = ("%d this fight"):format(b.value or 0)
			end
			if key == "dispels" and b.reactAvg then
				valueText = valueText .. (" · %.1fs avg response"):format(b.reactAvg)
			end
		elseif PERCENT_METRICS[key] then
			valueText = ("Up %d%% of the fight"):format((b.value or 0) * 100 + 0.5)
		elseif duration and duration > 0 then
			valueText = ("%s · %s per second"):format(
				TP.FormatNumber(b.value or 0), TP.FormatNumber((b.value or 0) / duration))
		else
			valueText = TP.FormatNumber(b.value or 0)
		end
		-- Aug attribution: show the own/enabled split on the damage line
		if key == "damage" and b.attribution and b.attribution.attributed > 0 and duration > 0 then
			valueText = ("%s own + %s buffs enabled = %s effective"):format(
				TP.FormatNumber(b.attribution.own / duration),
				TP.FormatNumber(b.attribution.attributed / duration),
				TP.FormatNumber((b.attribution.own + b.attribution.attributed) / duration)) .. "/s"
		end
		-- depth riders on the same line, never new card lines
		if key == "damage" and b.overkillPct and b.overkillPct >= 5 then
			valueText = valueText .. (" · %d%% overkill"):format(b.overkillPct)
		end
		if key == "healing" and b.manaMinPct then
			if b.dryAt then
				valueText = valueText .. (" · ran dry at %d:%02d"):format(
					math.floor(b.dryAt / 60), b.dryAt % 60)
			else
				valueText = valueText .. (" · lowest mana %d%%"):format(b.manaMinPct)
			end
		end
	end
	metricTip.value:SetText(valueText)
	-- multi-line value blocks (the Tanking ingredients) push everything
	-- below them down one line per extra row
	local extraLines = 0
	for _ in tostring(valueText or ""):gmatch("\n") do
		extraLines = extraLines + 1
	end
	metricTip.median:ClearAllPoints()
	metricTip.median:SetPoint("TOPLEFT", 10, -(38 + extraLines * 14))

	if b.specMedian and duration and duration > 0 then
		-- curveFrom names the comparison population when the evidence
		-- ladder had to zoom out (other bracket, all bosses, everyone)
		metricTip.median:SetText(("%s median: %s/s"):format(
			b.curveFrom or (b.rolePooled and "role" or "spec"), TP.FormatNumber(b.specMedian)))
	elseif b.lowDemand then
		metricTip.median:SetText("barely anything to heal - scored neutral")
	elseif COUNT_METRICS[key] and b.groupTotal and not wclBacked then
		metricTip.median:SetText("scored against an even share of the group's total")
	elseif key == "damageTaken" then
		-- by design, not missing data: WCL has no damage-taken rankings
		metricTip.median:SetText("WCL doesn't rank soaking - your share vs the expected tank share")
	elseif b.relative and not b.absolute then
		if data.role == "SUPPORT" and key == "damage" then
			-- the attribution input never arrived, name it
			metricTip.median:SetText("no Ebon Might uptime reported - vs group share")
		else
			metricTip.median:SetText("no WCL population data - vs group share")
		end
	else
		metricTip.median:SetText("")
	end

	-- (the coach line left this tip 2026-07-25: it leads the card now)
	metricTip:SetHeight(76 + extraLines * 14)

	local footer = data.footerText
	if not footer and COUNT_METRICS[key] and (b.weight or 0) == 0 then
		-- count metrics adjust the score instead of weighting into it
		if b.adjust then
			footer = ("%+.0f points · scaled by the fight's volume"):format(b.adjust)
		else
			footer = "no score impact this fight"
		end
	end
	metricTip.footer:SetText(footer or ("score %d · worth %d%% of the grade"):format(
		b.normalized or 0, (b.effectiveWeight or 0) * 100))

	-- fit the tip to its longest line (same rule as the card): text never
	-- truncates and never spills past the border
	local needed = GAUGE_W + 24
	for _, fs in ipairs({ metricTip.title, metricTip.value, metricTip.median, metricTip.footer }) do
		local w = (fs:GetStringWidth() or 0) + 20
		if w > needed then
			needed = w
		end
	end
	metricTip:SetWidth(math.min(needed, 430))

	metricTip:ClearAllPoints()
	metricTip:SetPoint(tipSide() == "LEFT" and "RIGHT" or "LEFT", anchor,
		tipSide() == "LEFT" and "LEFT" or "RIGHT", tipSide() == "LEFT" and -14 or 14, 0)
	metricTip:Show()
end

local function rowEnter(self)
	-- every hover target announces itself (Josh 2026-07-25: chips had
	-- the highlight, full rows didn't)
	if self.hl and (self.metricData or self.tooltipData) then
		self.hl:Show()
	end
	if self.metricData then
		showMetricTip(self, self.metricData)
		return
	end
	local d = self.tooltipData
	if not d then
		return
	end
	TP.Tooltip:Show(self, tipSide() == "LEFT" and "FORCE_LEFT" or "FORCE_RIGHT", d.title, d.lines)
end

local function rowLeave(self)
	if self and self.hl then
		self.hl:Hide()
	end
	TP.Tooltip:Hide()
	if metricTip then
		metricTip:Hide()
	end
end

local function newRow(parent)
	local row = CreateFrame("Frame", nil, parent)
	row:SetSize(WIDTH - 12, ROW_HEIGHT)
	row:EnableMouse(true)
	row:SetScript("OnEnter", rowEnter)
	row:SetScript("OnLeave", rowLeave)
	row.hl = row:CreateTexture(nil, "BACKGROUND")
	row.hl:SetAllPoints(row)
	row.hl:SetColorTexture(1, 1, 1, 0.06)
	row.hl:Hide()

	-- aligned to the signal rows: icon column at 8 (13px), labels at 26
	row.symbol = face(row:CreateFontString(nil, "OVERLAY", "GameFontNormal"), 13)
	row.symbol:SetPoint("LEFT", 8, 0)
	row.symbol:SetWidth(13)
	row.symbol:SetJustifyH("CENTER")

	row.text = face(row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), 12)
	row.text:SetPoint("LEFT", 26, 0)
	row.text:SetPoint("RIGHT", -8, 0)
	row.text:SetJustifyH("LEFT")
	row.text:SetWordWrap(false)
	return row
end

-- ===== Signal Column rendering (2026-07-26 redesign) =====
-- Each row: [icon][verdict label][marks: bar/squares/pips/glyph][num][pts]
-- Widgets are created lazily and shared with the legacy bullet layout
-- (awards and the group card still render symbol+text rows).
local MARK_POOL = 10 -- fixed segment count: gauges always span the area
local CONTENT_X = 116 -- marks start after icon(16) + label(~80)
local NUM_W, PTS_W = 30, 26
-- full rows carry no points since Active/Mitigation moved to the grid
-- (Josh 2026-07-25): the score sits in the LAST column and the gauge
-- takes the freed width
local BAR_W = 300 - 12 - CONTENT_X - (NUM_W + 14)
local SEG_W = math.floor((BAR_W - (MARK_POOL - 1) * 2) / MARK_POOL)

local function ensureSignalWidgets(row)
	if row.icon then
		return
	end
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(13, 13)
	row.icon:SetPoint("LEFT", 8, 0)
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- the clean-addon crop
	row.label = face(row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), 12)
	row.label:SetPoint("LEFT", 26, 0)
	row.label:SetWidth(CONTENT_X - 30)
	row.label:SetJustifyH("LEFT")
	row.label:SetWordWrap(false)
	row.track = row:CreateTexture(nil, "ARTWORK")
	row.track:SetColorTexture(0.12, 0.12, 0.14, 1)
	row.track:SetPoint("LEFT", CONTENT_X, 0)
	row.track:SetPoint("RIGHT", -(NUM_W + 14), 0)
	row.track:SetHeight(7)
	row.fill = row:CreateTexture(nil, "OVERLAY")
	row.fill:SetPoint("TOPLEFT", row.track, "TOPLEFT", 0, 0)
	row.fill:SetPoint("BOTTOMLEFT", row.track, "BOTTOMLEFT", 0, 0)
	row.tick = row:CreateTexture(nil, "OVERLAY", nil, 2)
	row.tick:SetColorTexture(0.92, 0.92, 0.92, 0.85)
	row.tick:SetSize(1, 11)
	row.num = face(row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), 13)
	row.num:SetPoint("RIGHT", -8, 0)
	row.num:SetWidth(NUM_W)
	row.num:SetJustifyH("RIGHT")
	row.pts = face(row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), 11)
	row.pts:SetPoint("RIGHT", -8, 0)
	row.pts:SetWidth(PTS_W)
	row.pts:SetJustifyH("RIGHT")
	row.marks = {}
	for i = 1, MARK_POOL do
		local t = row:CreateTexture(nil, "OVERLAY")
		t:SetSize(SEG_W, 9)
		t:SetPoint("LEFT", CONTENT_X + (i - 1) * (SEG_W + 2), 0)
		row.marks[i] = t
	end
	-- WCL-percentile rows render the bracket gauge itself (Josh
	-- 2026-07-24: the card shows what the tooltip used to duplicate):
	-- five zone segments + a marker at your position
	row.zones = {}
	for i = 1, #GAUGE_ZONES do
		local t = row:CreateTexture(nil, "OVERLAY")
		t:SetHeight(7)
		row.zones[i] = t
	end
	row.marker = row:CreateTexture(nil, "OVERLAY", nil, 3)
	row.marker:SetColorTexture(1, 1, 1, 1)
	row.marker:SetSize(2, 11)
end

local function hideSignalWidgets(row)
	if not row.icon then
		return
	end
	row.icon:Hide()
	row.label:Hide()
	row.track:Hide()
	row.fill:Hide()
	row.tick:Hide()
	row.num:Hide()
	row.pts:Hide()
	for _, t in ipairs(row.marks) do
		t:Hide()
	end
	for _, t in ipairs(row.zones or {}) do
		t:Hide()
	end
	if row.marker then
		row.marker:Hide()
	end
end

local MARK_GOOD = { 0.18, 0.70, 0.32 }
local MARK_BAD = { 0.90, 0.30, 0.30 }
local MARK_GHOST = { 0.16, 0.16, 0.19 }
local LABEL_INK = { 0.62, 0.61, 0.55 }

local function renderSignal(row, sig, groupAvg)
	ensureSignalWidgets(row)
	row.symbol:SetText("")
	row.text:SetText("")
	-- rows are recycled across kinds: reset EVERY kind's widgets first
	-- (a bar row was wearing the previous tenant's squares, 2026-07-26)
	row.track:Hide()
	row.fill:Hide()
	row.tick:Hide()
	for _, t in ipairs(row.marks) do
		t:Hide()
	end
	for _, t in ipairs(row.zones) do
		t:Hide()
	end
	row.marker:Hide()
	row.num:SetText("")
	row.num:Hide()
	row.pts:Hide()
	row.icon:SetTexture(sig.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
	row.icon:Show()
	row.label:SetText(sig.label or "")
	row.label:Show()
	local warn = (sig.points or 0) < 0 or (sig.kind == "pips")
		or (sig.kind == "glyph" and not sig.good)
	if warn then
		row.label:SetTextColor(0.85, 0.42, 0.42)
	else
		row.label:SetTextColor(LABEL_INK[1], LABEL_INK[2], LABEL_INK[3])
	end
	-- full-width rows carry no points column anymore (every pointed
	-- signal lives in the chip grid, Josh 2026-07-25) — the score sits
	-- in the last column where the +N used to be
	row.pts:SetText("")

	if sig.kind == "bar" then
		row.track:Show()
		local v = sig.value or 0
		local r, g, b
		local gauge, markerAt = false, nil
		if sig.tier then
			-- anchor-tiered composites (Tanking) are population-backed,
			-- so they wear the gauge: marker at the POPULATION TIER, the
			-- number stays the raw value (Josh 2026-07-24)
			r, g, b = TP.Scoring.Grades.ColorForScore(sig.tier)
			gauge, markerAt = true, sig.tier
		elseif sig.num or sig.raw then
			-- non-percentile bars (coverage, share scores, unranked
			-- throughput): VERDICT colors, never brackets — a value that
			-- costs points must not wear parse blue (Josh 2026-07-24).
			-- Green earned, red cost, neutral otherwise.
			local pts = sig.points or 0
			if pts >= 0.5 then
				r, g, b = MARK_GOOD[1], MARK_GOOD[2], MARK_GOOD[3]
			elseif pts <= -0.5 then
				r, g, b = MARK_BAD[1], MARK_BAD[2], MARK_BAD[3]
			else
				r, g, b = 0.58, 0.58, 0.63
			end
		else
			-- a real WCL percentile: render the bracket gauge itself with
			-- a marker at your position (Josh 2026-07-24 — the card now
			-- shows what the tooltip used to duplicate)
			r, g, b = TP.Scoring.Grades.ColorForScore(v)
			gauge, markerAt = true, v
		end
		-- fixed geometry: anchors haven't settled on first render, so
		-- GetWidth() lies — the card is WIDTH wide by construction
		local w = BAR_W
		if gauge then
			for i, z in ipairs(GAUGE_ZONES) do
				local t = row.zones[i]
				local mid = (z[1] + z[2]) / 2
				local zr, zg, zb = TP.Scoring.Grades.ColorForScore(mid > 95 and 96 or mid)
				t:SetColorTexture(zr, zg, zb, 0.55)
				t:ClearAllPoints()
				t:SetPoint("LEFT", row.track, "LEFT", z[1] / 100 * w, 0)
				t:SetWidth(math.max(1, (z[2] - z[1]) / 100 * w))
				t:Show()
			end
			row.marker:ClearAllPoints()
			row.marker:SetPoint("CENTER", row.track, "LEFT", math.min(99, markerAt) / 100 * w, 0)
			row.marker:Show()
		elseif sig.num then
			-- counts and coverage ("1/3", "0/10", dispel counts) are
			-- MARKLESS like Died (Josh 2026-07-24): a bar under a count
			-- implied a continuous scale that isn't there — the colored
			-- count + points carry the whole verdict
			row.track:Hide()
		else
			-- continuous 0-100 shares without a population (Soaking,
			-- unranked throughput, Ebon Might): solid verdict-colored fill
			row.fill:SetColorTexture(r, g, b, 0.9)
			row.fill:SetWidth(math.max(1, w * math.min(99, v) / 100))
			row.fill:Show()
		end
		-- gauge rows carry only the player's marker (Josh 2026-07-24: two
		-- white ticks on one gauge read as noise) — comparison ticks are
		-- for solid-fill bars, where the fill end isn't a marker
		local avg = not gauge and not sig.num and groupAvg and groupAvg[sig.key]
		if avg then
			row.tick:ClearAllPoints()
			row.tick:SetPoint("LEFT", row.track, "LEFT", w * math.min(99, avg) / 100, 0)
			row.tick:Show()
		end
		-- the number wears the same color the fill chose (verdict or
		-- bracket) so a row never argues with itself. With letter grades
		-- on, graded bars show their letter (from the same tier that
		-- picked the color); counts stay counts, tooltips stay numeric.
		local numText = sig.num
		if not numText then
			-- letters are bracket language: only rows whose color came from
			-- a population tier may wear one — a group-share 92 stays "92",
			-- never an "S-" over a neutral fill (audit 2026-07-24)
			if TP.Addon.db.profile.letterGrades and TP.Scoring.Grades.LetterFor
				and (sig.tier or not sig.raw) then
				numText = TP.Scoring.Grades.LetterFor(sig.tier or v)
			else
				numText = ("%d"):format(v + 0.5)
			end
		end
		row.num:SetText(numText)
		row.num:SetTextColor(r, g, b)
		row.num:Show()
	elseif sig.kind == "squares" then
		-- fixed 10-segment gauge, filled proportionally (Josh 2026-07-26:
		-- raw per-event squares looked lonely at 1 and overflowed at 12+).
		-- Every nonzero share gets at least one segment; exact counts ride
		-- the number column.
		local good, bad, ghost = sig.good or 0, sig.bad or 0, sig.ghost or 0
		local total = good + bad + ghost
		if total > 0 then
			local cells = { 0, 0, 0 }
			local shares = { good, bad, ghost }
			local assigned = 0
			for i = 1, 3 do
				if shares[i] > 0 then
					cells[i] = math.max(1, math.floor(shares[i] / total * MARK_POOL + 0.5))
					assigned = assigned + cells[i]
				end
			end
			-- trim/pad the largest share so cells sum to the pool exactly
			local bigI = 1
			for i = 2, 3 do
				if cells[i] > cells[bigI] then
					bigI = i
				end
			end
			cells[bigI] = math.max(1, cells[bigI] + (MARK_POOL - assigned))
			local colors = { MARK_GOOD, MARK_BAD, MARK_GHOST }
			local idx = 0
			for i = 1, 3 do
				for _ = 1, cells[i] do
					idx = idx + 1
					local t = row.marks[idx]
					if t then
						t:SetColorTexture(colors[i][1], colors[i][2], colors[i][3], 1)
						t:Show()
					end
				end
			end
		end
		row.num:SetText(("%d/%d"):format(good, total))
		if (sig.points or 0) >= 0 then
			row.num:SetTextColor(MARK_GOOD[1], MARK_GOOD[2], MARK_GOOD[3])
		else
			row.num:SetTextColor(MARK_BAD[1], MARK_BAD[2], MARK_BAD[3])
		end
		row.num:Show()
	elseif sig.kind == "pips" then
		-- counts need no marks: the red label + number carry it
		row.num:SetText(tostring(sig.count or 0))
		row.num:SetTextColor(MARK_BAD[1], MARK_BAD[2], MARK_BAD[3])
		row.num:Show()
	elseif sig.kind == "glyph" then
		-- binaries need no marks either: verdict label + points say it
		if sig.count then
			row.num:SetText(tostring(sig.count))
			row.num:SetTextColor(LABEL_INK[1], LABEL_INK[2], LABEL_INK[3])
			row.num:Show()
		end
	end
end

-- Side-aware anchoring: the panel takes the roomier side of the meter
-- window (clamping used to slide it back OVER the window at the screen
-- edge), and top-aligns unless that would clip the bottom of the screen.
local function anchorPanel()
	local anchor = _G.TrueParseWindow
	frame:ClearAllPoints()
	if not anchor then
		frame:SetPoint("CENTER")
		return
	end
	local screenW = UIParent:GetWidth()
	local spaceRight = screenW - (anchor:GetRight() or screenW)
	local spaceLeft = anchor:GetLeft() or 0
	local needed = frame:GetWidth() + 10
	local side, opposite, dx = "LEFT", "RIGHT", 6
	if spaceRight < needed and spaceLeft > spaceRight then
		side, opposite, dx = "RIGHT", "LEFT", -6
	end
	local vert = "TOP"
	if (anchor:GetTop() or 0) < frame:GetHeight() then
		vert = "BOTTOM"
	end
	frame:SetPoint(vert .. side, anchor, vert .. opposite, dx, 0)
end

local function createFrame()
	frame = CreateFrame("Frame", "TrueParseBreakdown", UIParent, "BackdropTemplate")
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0.04, 0.04, 0.05, 1)
	frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	frame:SetWidth(WIDTH)
	frame:SetClampedToScreen(true)
	frame:SetFrameStrata("DIALOG")
	frame:Hide()

	frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	frame.close:SetPoint("TOPRIGHT", 2, 2)
	frame.close:SetScript("OnClick", function()
		Panel.pinned = false
		frame:Hide()
		Panel.currentGUID = nil
	end)

	-- mockup header (Josh 2026-07-24): NAME then the big bracket-colored
	-- score right beside it — one hero line, role tag far right
	frame.title = face(frame:CreateFontString(nil, "OVERLAY", "GameFontNormal"), 17)
	frame.title:SetPoint("TOPLEFT", 10, -9)
	frame.title:SetJustifyH("LEFT")

	frame.bigScore = face(frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge"), 21)
	frame.bigScore:SetPoint("BOTTOMLEFT", frame.title, "BOTTOMRIGHT", 7, -1)
	frame.bigScore:SetJustifyH("LEFT")

	-- role tag on the title row, right side
	frame.role = face(frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), 12)
	frame.role:SetPoint("TOPRIGHT", -10, -12)
	frame.role:SetJustifyH("RIGHT")

	frame.subtitle = face(frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), 11)
	frame.subtitle:SetPoint("TOPLEFT", 10, -24)
	frame.subtitle:SetJustifyH("LEFT")

	-- subheader: one dim line — boss · wipe % · duration · run avg
	frame.scoreLine = face(frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), 12)
	frame.scoreLine:SetPoint("TOPLEFT", 10, -30)
	frame.scoreLine:SetPoint("TOPRIGHT", -10, -30)
	frame.scoreLine:SetJustifyH("LEFT")

	frame.runLine = face(frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), 11)
	frame.runLine:SetPoint("TOPLEFT", 10, -43)
	frame.runLine:SetPoint("TOPRIGHT", -10, -43)
	frame.runLine:SetJustifyH("LEFT")

	-- duration + pull time, third header line (Josh 2026-07-25: the
	-- footer's tenants moved up; the footer zone retires on player cards)
	frame.timeLine = face(frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), 11)
	frame.timeLine:SetPoint("TOPLEFT", 10, -43)
	frame.timeLine:SetPoint("TOPRIGHT", -10, -43)
	frame.timeLine:SetJustifyH("LEFT")

	frame.total = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.total:SetPoint("BOTTOMLEFT", 10, 10)

	-- mockup footer: dim closing line (flask/food · pull time)
	frame.footer = face(frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), 11)
	frame.footer:SetPoint("BOTTOMLEFT", 12, 8)
	frame.footer:SetJustifyH("LEFT")
end

-- group-card visualization elements (fight shape, team coverage,
-- staircase) — hidden wholesale when the shared frame shows a player
local GROUP_VIZ = { "shapeLabel", "shapeCols", "covLabel", "covTrack", "covBands",
	"pShapeLabel", "pShapeCols" }
local function hideGroupViz()
	if not frame then
		return
	end
	for _, which in ipairs(GROUP_VIZ) do
		local o = frame[which]
		if o then
			if o.Hide then
				o:Hide()
			else
				for _, t in ipairs(o) do
					t:Hide()
				end
			end
		end
	end
end

-- WCL-style death recap tooltip lines: the last hits, each with a bar
-- sized by the hit (red = avoidable). Shared by the deaths signal row.
local function deathRecapLines(player)
	local maxHit = 1
	for _, hit in ipairs(player.deathRecap) do
		maxHit = math.max(maxHit, hit.amount or 0)
	end
	local lines = { { "The last hits before the death:", 0.8, 0.8, 0.8 } }
	for _, hit in ipairs(player.deathRecap) do
		local w = math.max(2, math.floor((hit.amount or 0) / maxHit * 50))
		local bar = hit.avoidable
			and ("|TInterface\\Buttons\\WHITE8X8:8:%d:0:0:8:8:0:8:0:8:230:77:77|t"):format(w)
			or ("|TInterface\\Buttons\\WHITE8X8:8:%d:0:0:8:8:0:8:0:8:120:120:130|t"):format(w)
		lines[#lines + 1] = {
			("%d:%02d %s %s  %s%s"):format(
				math.floor((hit.t or 0) / 60), (hit.t or 0) % 60,
				bar, hit.spell or "?", TP.FormatNumber(hit.amount or 0),
				hit.avoidable and "  (avoidable)" or ""),
			hit.avoidable and 0.95 or 0.75,
			hit.avoidable and 0.45 or 0.75,
			hit.avoidable and 0.45 or 0.75 }
	end
	return lines
end

local function getRow(i, y)
	local row = rows[i]
	if not row then
		row = newRow(frame)
		rows[i] = row
	end
	-- recycled rows shed wrap state HERE, not per-view: a coach row
	-- reused by the group card kept its double height and spilled into
	-- the neighbor below (audit 2026-07-24)
	row:SetHeight(ROW_HEIGHT)
	row.wraps = nil
	row.text:SetWordWrap(false)
	if row.coachBg then
		row.coachBg:Hide()
	end
	if row.icon then
		row.icon:ClearAllPoints()
		row.icon:SetPoint("LEFT", 8, 0)
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
		rows[j].metricData = nil
	end
end

-- ===== verdict chip grid (layout A, Josh 2026-07-25): markless rows
-- pack two per line — icon, label, value, points — with a hover
-- highlight announcing the tooltip target =====
local CHIP_GAP = 6
local chips = {}
local function getChip(i)
	local c = chips[i]
	if not c then
		c = CreateFrame("Frame", nil, frame)
		c:EnableMouse(true)
		c.hl = c:CreateTexture(nil, "BACKGROUND")
		c.hl:SetAllPoints(c)
		c.hl:SetColorTexture(1, 1, 1, 0.06)
		c.hl:Hide()
		c:SetScript("OnEnter", function(s)
			s.hl:Show()
			rowEnter(s)
		end)
		c:SetScript("OnLeave", function(s)
			s.hl:Hide()
			rowLeave()
		end)
		c.icon = c:CreateTexture(nil, "ARTWORK")
		c.icon:SetSize(13, 13)
		c.icon:SetPoint("LEFT", 0, 0)
		c.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		c.pts = face(c:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), 11)
		c.pts:SetPoint("RIGHT", 0, 0)
		c.pts:SetWidth(22)
		c.pts:SetJustifyH("RIGHT")
		c.val = face(c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), 12)
		c.val:SetPoint("RIGHT", -28, 0)
		c.val:SetJustifyH("RIGHT")
		c.label = face(c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall"), 12)
		c.label:SetPoint("LEFT", 18, 0)
		c.label:SetPoint("RIGHT", c.val, "LEFT", -2, 0)
		c.label:SetJustifyH("LEFT")
		c.label:SetWordWrap(false)
		chips[i] = c
	end
	return c
end

local function hideChipsFrom(i)
	for j = i, #chips do
		chips[j]:Hide()
		chips[j].metricData = nil
		chips[j].tooltipData = nil
	end
end

local function renderChip(c, sig)
	c.icon:SetTexture(sig.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
	local warn = (sig.points or 0) < 0 or sig.kind == "pips"
		or (sig.kind == "glyph" and not sig.good)
	if warn then
		c.label:SetTextColor(0.85, 0.42, 0.42)
	else
		c.label:SetTextColor(LABEL_INK[1], LABEL_INK[2], LABEL_INK[3])
	end
	c.label:SetText(sig.label or "")
	local vtext, vr, vg, vb
	if sig.kind == "pips" then
		vtext = tostring(sig.count or 0)
		vr, vg, vb = MARK_BAD[1], MARK_BAD[2], MARK_BAD[3]
	elseif sig.kind == "glyph" then
		vtext = sig.count and tostring(sig.count) or ""
		vr, vg, vb = LABEL_INK[1], LABEL_INK[2], LABEL_INK[3]
	else -- count-bearing bar rows (Covered c/j, Kicks l/o, dispel counts)
		vtext = sig.num or ""
		local pts = sig.points or 0
		if pts >= 0.5 then
			vr, vg, vb = MARK_GOOD[1], MARK_GOOD[2], MARK_GOOD[3]
		elseif pts <= -0.5 then
			vr, vg, vb = MARK_BAD[1], MARK_BAD[2], MARK_BAD[3]
		else
			vr, vg, vb = 0.58, 0.58, 0.63
		end
	end
	c.val:SetText(vtext)
	c.val:SetTextColor(vr, vg, vb)
	if sig.points and math.abs(sig.points) >= 0.5 then
		c.pts:SetText(("%+d"):format(sig.points >= 0
			and math.floor(sig.points + 0.5) or -math.floor(-sig.points + 0.5)))
	else
		c.pts:SetText("")
	end
end

-- Important lines never truncate: widen the card to its longest bullet
-- (within reason), then keep every row tracking the frame width.
local MAX_WIDTH = 430
local function fitWidth(rowCount)
	local needed = WIDTH
	for i = 1, math.min(rowCount, #rows) do
		-- GetStringWidth measures the FULL text, not the clipped render.
		-- Wrapping rows (the coach) never widen the card: a wider card
		-- stretches the tracks past the fixed-width gauges and bares the
		-- grey tail (Josh 2026-07-24)
		local w = rows[i].wraps and 0
			or rows[i].text:GetStringWidth() + 28 + 8 + 12
		if w > needed then
			needed = w
		end
	end
	needed = math.min(needed, MAX_WIDTH)
	frame:SetWidth(needed)
	for i = 1, #rows do
		rows[i]:SetWidth(needed - 12)
	end
end


local INFO_HELP -- built on first use (TP.Compat is load-order-safe then)
local function infoHelp()
	-- Tooltip doctrine (Josh 2026-07-26): ONE short line, no lectures —
	-- and every claim must match how the engine actually scores TODAY.
	-- The points already ride the bullet; the tooltip only says what was
	-- counted.
	if not INFO_HELP then
		INFO_HELP = {
			adds = "Damage into non-boss targets. Context, not a judgment.",
			tankFocus = "Share of healing that landed on tanks.",
			defensives = TP.Compat.IS_RETAIL
				and "Defensives used, reported by their TrueParse. 2+ earns the bonus."
				or "Defensives used, from the combat log. 2+ earns the bonus.",
			consumables = "Flask/food up at the pull.",
			deathReady = "Defensives sitting unused when they died.",
			lust = "Cooldowns and potions inside the Bloodlust window.",
			activity = "Time spent casting or attacking.",
			overheal = "Healing onto full health bars, judged against this spec's normal range from ranked logs.",
			offensives = "Offensive cooldowns cast. Softens a missed Bloodlust window.",
			avoidable = "Avoidable damage taken, vs your fair share of the group's.",
			cdTiming = "Damage spikes answered in time: raid CDs on group spikes, your external on tank spikes. Judged only on spikes your cooldowns could reach.",
			manaDry = "Ran out of mana before the fight's final stretch.",
			overkill = "Damage wasted on already-dead targets.",
			prepared = "Flask and food up at the pull.",
			kicks = "Interrupts vs your fair share of the group's.",
			rez = "Combat rez cast, from the combat log.",
			coach = "The biggest gap between this fight and top parses of this spec.",
			interrupts = "Casts this player interrupted.",
			dispels = "Debuffs this player dispelled.",
		}
	end
	return INFO_HELP
end

local PENALTY_HELP = {
	avoidable = "More than a fair share of avoidable damage. Capped at -15.",
	deaths = "Up to -20. Late deaths cost less; wipes charge 40%.",
	buffs = "Raid buff not on the group at the pull. Capped at -3.",
	-- threat penalties only exist on captures that HAVE threat data, so no
	-- "on Classic" disclaimers needed - retail never shows these
	pull = "Pulled before the tank. -5; an immediate taunt save forgives it.",
	aggro = "Ripped aggro off the tank. -2.5 each, capped at -8.",
	aggroLoss = "Mobs on non-tanks: -0.4/second, capped at -8.",
}

local ROLE_LABELS = {
	DAMAGER = "DPS", TANK = "Tank", HEALER = "Healer", SUPPORT = "Support DPS",
}

-- invisible hover targets over header fontstrings (name, big score):
-- tipTitle nil = inert for that render (Josh 2026-07-25)
local function headerHover(which, target)
	local hf = frame[which]
	if not hf then
		hf = CreateFrame("Frame", nil, frame)
		hf:SetAllPoints(target)
		hf:EnableMouse(true)
		hf:SetScript("OnEnter", function(sf)
			if sf.tipTitle then
				TP.Tooltip:Show(sf, tipSide() == "LEFT" and "FORCE_LEFT" or "FORCE_RIGHT",
					sf.tipTitle, sf.tipLines)
			end
		end)
		hf:SetScript("OnLeave", function()
			TP.Tooltip:Hide()
		end)
		frame[which] = hf
	end
	return hf
end

-- header identity icon: spec on player cards, the group icon on the
-- raid card (Josh 2026-07-25). Hover names what it shows.
local function ensureSpecIcon()
	if frame.specIcon then
		return
	end
	frame.specIcon = CreateFrame("Frame", nil, frame)
	frame.specIcon:SetSize(18, 18)
	frame.specIcon:SetPoint("TOPLEFT", 10, -9)
	frame.specIcon.tex = frame.specIcon:CreateTexture(nil, "ARTWORK")
	frame.specIcon.tex:SetAllPoints(frame.specIcon)
	frame.specIcon.tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	frame.specIcon:EnableMouse(true)
	frame.specIcon:SetScript("OnEnter", function(sf)
		if sf.tipTitle then
			TP.Tooltip:Show(sf, tipSide() == "LEFT" and "FORCE_LEFT" or "FORCE_RIGHT",
				sf.tipTitle, sf.tipLines)
		end
	end)
	frame.specIcon:SetScript("OnLeave", function()
		TP.Tooltip:Hide()
	end)
end

function Panel:ShowFor(fight, result)
	if not frame then
		createFrame()
	end

	local cr, cg, cb = TP.ClassColor(result.class)
	frame.title:SetText(result.name or "?")
	frame.title:SetTextColor(cr, cg, cb)
	-- spec icon before the name (Josh 2026-07-25); hover names the spec
	ensureSpecIcon()
	local pRec = fight.players and fight.players[result.guid]
	local specID = pRec and pRec.specID
	local specIcon, specName
	if specID and GetSpecializationInfoByID then
		local ok, _, sName, _, sIcon = pcall(GetSpecializationInfoByID, specID)
		if ok then
			specName, specIcon = sName, sIcon
		end
	end
	specIcon = specIcon or (pRec and pRec.specIconID)
	frame.title:ClearAllPoints()
	local className = result.class and (LOCALIZED_CLASS_NAMES_MALE
		and LOCALIZED_CLASS_NAMES_MALE[result.class]) or result.class
	local specLine = (specName and className) and (specName .. " " .. className)
		or specName or className or "Unknown spec"
	if specIcon then
		frame.specIcon.tex:SetTexture(specIcon)
		frame.specIcon.tipTitle = specName or className or "Spec"
		frame.specIcon.tipLines = { { specLine, cr, cg, cb } }
		frame.specIcon:Show()
		frame.title:SetPoint("TOPLEFT", 32, -9)
	else
		frame.specIcon:Hide()
		frame.title:SetPoint("TOPLEFT", 10, -9)
	end
	-- the NAME hovers too, spec icon inline (Josh 2026-07-25)
	local th = headerHover("titleHover", frame.title)
	th.tipTitle = result.name or "?"
	th.tipLines = { { (specIcon and ("|T" .. specIcon .. ":16|t ") or "") .. specLine,
		cr, cg, cb } }
	frame.role:SetText(ROLE_LABELS[result.role] or result.role or "")
	frame.subtitle:SetText("")
	frame.bigScore:SetText("")

	local myAwards = TP.Scoring.Awards.Compute(fight)[result.guid]
	local player = fight.players[result.guid]

	-- compact score lines under the name; ~ marks estimates like the rows do
	local rawShaped = TP.Addon.db.profile.scoring.mode == "parse"
		and result.breakdown.interrupts == nil
	local approx = false
	if rawShaped then
		for _, b in pairs(result.breakdown) do
			-- a raw-SETTING fight that fell back to True (no WCL data) must
			-- not decorate zero-weight display metrics
			if b.applicable and not b.absolute and (b.effectiveWeight or 0) > 0 then
				approx = true
			end
		end
	end
	-- personal-best tag: strictly better than every prior kill of this
	-- boss at this difficulty (needs at least one prior to compare)
	local pbTag = ""
	if fight.isBoss and not fight.wipe and not fight.isRun
		and TP.FightHistory and TP.FightHistory.PersonalBest then
		local prior = TP.FightHistory:PersonalBest(fight, result.guid)
		if prior and result.score > prior then
			pbTag = " |cffe8b923· personal best|r"
		end
	end
	-- hero line: name + big bracket-colored score (mockup header,
	-- Josh 2026-07-24); the subheader is one dim compact line
	frame.bigScore:SetText((approx and "~" or "")
		.. TP.Scoring.Grades.ColoredScore(result.score, TP.Scoring.Grades.IsShamed(result)))
	local runR = self.runScores and self.runScores[result.guid]
	local sub = { fight.name or "this fight" }
	if fight.wipe then
		sub[#sub + 1] = fight.bossPct and ("|cffe64d4dwipe %.0f%%|r"):format(fight.bossPct)
			or "|cffe64d4dwipe|r"
	end
	if runR then
		sub[#sub + 1] = "run avg " .. TP.Scoring.Grades.ColoredScore(runR.score)
	end
	frame.scoreLine:SetText(table.concat(sub, " \194\183 ") .. pbTag)
	-- third header line: duration + pull time (the footer's tenants,
	-- Josh 2026-07-25)
	local tparts = {}
	if (fight.duration or 0) > 0 then
		tparts[#tparts + 1] = ("%d:%02d"):format(math.floor(fight.duration / 60), fight.duration % 60)
	end
	if fight.capturedAt and (fight.duration or 0) > 0 and not result.parse then
		tparts[#tparts + 1] = "pulled " .. date("%H:%M", fight.capturedAt - fight.duration)
	end
	frame.timeLine:SetText(table.concat(tparts, " \194\183 "))
	frame.timeLine:Show()
	-- progression trend lives in the SCORE's hover now (Josh 2026-07-25):
	-- oldest -> newest with arrows carrying the direction
	local trendText
	if fight.isBoss and not fight.isRun and TP.FightHistory and TP.FightHistory.ScoreHistory then
		local hist = TP.FightHistory:ScoreHistory(fight, result.guid, 6)
		if hist then
			local parts = {}
			for _, s in ipairs(hist) do
				parts[#parts + 1] = TP.Scoring.Grades.ColoredScore(s)
			end
			-- \194\187 = » (Latin-1): the true arrow glyph is tofu in the
			-- WoW fonts (Josh 2026-07-25)
			trendText = table.concat(parts, " |cff888888\194\187|r ")
		end
	end
	frame.runLine:SetText("")
	local sh = headerHover("scoreHover", frame.bigScore)
	sh.tipTitle = "Trend"
	sh.tipLines = { trendText and { trendText, 1, 1, 1 }
		or { "No prior kills of this boss recorded.", 0.7, 0.7, 0.7 } }

	local y = -56 -- three header lines now (name, boss, time)
	-- the coach resolves FIRST: when it exists, its full-width wash IS
	-- the header divider (the rule hides, margin keeps the separation);
	-- without one the rule draws as before (Josh 2026-07-25)
	local coachGap
	if not result.parse and player and player.metrics and player.metrics.profCasts
		and player.specID and TP.Scoring.Insights.ParseGap then
		coachGap = TP.Scoring.Insights.ParseGap(player.specID, player.metrics, fight.duration)
	end
	if not frame.headerRule then
		frame.headerRule = frame:CreateTexture(nil, "ARTWORK")
		frame.headerRule:SetColorTexture(0.5, 0.5, 0.55, 0.18)
		frame.headerRule:SetHeight(1)
	end
	if coachGap then
		frame.headerRule:Hide()
		y = y - 6 -- the wash separates; the margin keeps it apart
	else
		y = y - 4
		frame.headerRule:ClearAllPoints()
		frame.headerRule:SetPoint("TOPLEFT", 10, y)
		frame.headerRule:SetPoint("TOPRIGHT", -10, y)
		frame.headerRule:Show()
		y = y - 6
	end

	-- Signal Column (2026-07-26 redesign): awards keep their gold text
	-- rows; every scored signal renders as icon + verdict + marks.
	local rowIndex = 0
	local function nextRow()
		rowIndex = rowIndex + 1
		local row = getRow(rowIndex, y)
		y = y - ROW_HEIGHT
		row.metricData = nil
		row.tooltipData = nil
		return row
	end
	-- the parse coach leads the card (Josh 2026-07-25: the single most
	-- valuable line lives above the fold), on a faint cyan wash so it
	-- reads as THE highlight. Advice, not a signal; Raw stays pure WCL.
	do
		local gap = coachGap
		if gap then
			local row = nextRow()
			ensureSignalWidgets(row)
			hideSignalWidgets(row)
			if not row.coachBg then
				row.coachBg = row:CreateTexture(nil, "BACKGROUND")
				-- full-bleed: left/top/bottom ride the row, the right edge
				-- reaches the CARD edge (rows stop 12px short of it —
				-- Josh 2026-07-25: the wash looked lopsided)
				row.coachBg:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
				row.coachBg:SetPoint("BOTTOM", row, "BOTTOM", 0, 0)
				row.coachBg:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
				row.coachBg:SetColorTexture(0.40, 0.85, 1.00, 0.07)
			end
			row.coachBg:Show()
			-- the coach wears a stopwatch, TOP-anchored so a wrapping
			-- second line never re-centers it; -2.5 optically centers it
			-- on the FIRST text line (Josh 2026-07-25)
			row.icon:SetTexture("Interface\\Icons\\INV_Misc_PocketWatch_01")
			row.icon:ClearAllPoints()
			row.icon:SetPoint("TOPLEFT", 8, -2.5)
			row.icon:Show()
			row.symbol:SetText("")
			-- long advice WRAPS at the card's standard width instead of
			-- widening the card (Josh 2026-07-24)
			row.wraps = true
			row.text:SetWordWrap(true)
			row.text:SetText(gap.text)
			row.text:SetTextColor(0.40, 0.85, 1.00)
			local avail = WIDTH - 12 - 26 - 8
			if row.text:GetStringWidth() > avail then
				row:SetHeight(ROW_HEIGHT * 2)
				y = y - ROW_HEIGHT -- the second line's room
			end
			row.tooltipData = { title = "Parse coach", lines = {
				{ infoHelp().coach, 0.8, 0.8, 0.8, true } } }
			y = y - 6 -- breathe below the wash, matching the rule's rhythm
		end
	end

	for _, award in ipairs(myAwards or {}) do
		local row = nextRow()
		hideSignalWidgets(row)
		row.symbol:SetText(TP.STAR)
		row.symbol:SetTextColor(1, 0.82, 0.2)
		row.text:SetText(award)
		row.text:SetTextColor(1, 0.82, 0.2)
		row.tooltipData = { title = award, lines = {
			{ TP.Scoring.Awards.DESCRIPTIONS[award] or "Fight award.", 1, 1, 1 } } }
	end
	-- comparison ticks come from the whole card's results
	local groupAvg
	do
		local ok, all = pcall(TP.Scoring.Engine.ScoreFight, fight, TP.GetScoringOptions())
		if ok and all then
			groupAvg = TP.Scoring.Signals.GroupAverages(all, fight)
		end
	end
	-- Raw mode = the WCL view (Josh 2026-07-24): only the throughput
	-- bars that MAKE the raw score — no adjustments, no rule, no strip.
	-- Filter on `base`, not `b`: kicks/dispels rows carry `b` for their
	-- numeric tooltips but never weight into the raw score.
	local signals = TP.Scoring.Signals.ForResult(result, fight, player)
	if result.parse then
		local kept = {}
		for _, sig in ipairs(signals) do
			if sig.base then
				kept[#kept + 1] = sig
			end
		end
		signals = kept
	end

	-- one tooltip builder for full rows AND chips: same content either way
	local function buildTip(target, sig)
		if sig.b then
			-- throughput bars keep the full metric tooltip (gauge + coach);
			-- composite rows (Tanking) override the title + value line
			target.metricData = { b = sig.b, key = sig.key,
				duration = fight.duration, role = result.role,
				specID = player and player.specID,
				metrics = player and player.metrics,
				title = sig.tipTitle, valueText = sig.tipText }
		elseif sig.key == "deaths" and player and player.deathRecap then
			target.tooltipData = { title = sig.label, lines = deathRecapLines(player) }
		else
			local lines = {
				{ infoHelp()[sig.key] or PENALTY_HELP[sig.key]
					or "Reported by this player's TrueParse.", 0.8, 0.8, 0.8, true } }
			if sig.detail then
				lines[#lines + 1] = { sig.detail, 1, 1, 1, true }
			end
			target.tooltipData = { title = sig.label, lines = lines }
		end
	end

	-- LAYOUT A (Josh 2026-07-25): every population visualization (gauges
	-- and fills) stacks full-width in one zone; every markless verdict
	-- packs into a two-column chip grid below the rule. Emission order is
	-- preserved in both zones — deaths emit last, so Died ends the grid.
	local fullRows, chipSigs = {}, {}
	for _, sig in ipairs(signals) do
		if sig.kind == "bar" and not sig.num then
			fullRows[#fullRows + 1] = sig
		else
			chipSigs[#chipSigs + 1] = sig
		end
	end
	for _, sig in ipairs(fullRows) do
		local row = nextRow()
		renderSignal(row, sig, groupAvg)
		buildTip(row, sig)
	end
	if #chipSigs > 0 and #fullRows > 0 then
		-- the rule now separates "measured against a population" from
		-- "counted verdicts" (the base-vs-adjustment story rides the
		-- points column)
		if not frame.baseRule then
			frame.baseRule = frame:CreateTexture(nil, "ARTWORK")
			frame.baseRule:SetColorTexture(0.5, 0.5, 0.55, 0.18)
			frame.baseRule:SetHeight(1)
		end
		y = y - 4
		frame.baseRule:ClearAllPoints()
		frame.baseRule:SetPoint("TOPLEFT", 10, y)
		frame.baseRule:SetPoint("TOPRIGHT", -10, y)
		frame.baseRule:Show()
		y = y - 6
	elseif frame.baseRule then
		frame.baseRule:Hide()
	end
	-- grid geometry: the right column's value/points land on the SAME
	-- x as the full rows' num/pts columns (Josh 2026-07-25)
	local chipW = (WIDTH - 28 - CHIP_GAP) / 2
	local gridTop = y
	for i, sig in ipairs(chipSigs) do
		local c = getChip(i)
		local col = (i - 1) % 2
		local rowN = math.floor((i - 1) / 2)
		c:SetSize(chipW, ROW_HEIGHT)
		c:ClearAllPoints()
		c:SetPoint("TOPLEFT", 8 + col * (chipW + CHIP_GAP), gridTop - rowN * ROW_HEIGHT)
		renderChip(c, sig)
		c.metricData, c.tooltipData = nil, nil
		buildTip(c, sig)
		c:Show()
	end
	hideChipsFrom(#chipSigs + 1)
	if #chipSigs > 0 then
		y = gridTop - math.ceil(#chipSigs / 2) * ROW_HEIGHT
	end

	-- (players without TrueParse are flagged by the red X on their
	-- scorecard row, not an extra bullet here)
	hideRowsFrom(rowIndex + 1)
	fitWidth(rowIndex)

	hideGroupViz() -- shared frame: group graphs never linger on players

	-- the player's OWN fight shape (Josh 2026-07-24): healers healing/sec,
	-- tanks intake/sec, dps damage/sec — low output and downtime read at a
	-- glance. Hidden in Raw (our viz, not WCL's).
	local pshape = not result.parse and player and player.metrics
		and player.metrics.shape or nil
	if pshape and #pshape > 1 and (fight.duration or 0) > 0 then
		local peak = 0
		for _, v in ipairs(pshape) do
			peak = math.max(peak, v)
		end
		if peak > 0 then
			if not frame.pShapeLabel then
				frame.pShapeLabel = face(frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), 11)
			end
			local series = result.role == "HEALER" and "your healing/sec"
				or result.role == "TANK" and "damage intake/sec" or "your damage/sec"
			if fight.lustAt and result.role ~= "TANK" then
				series = series .. " \194\183 |cff66ccfflust|r"
			end
			if fight.calledWipeAt then
				series = series .. " \194\183 |cffe64d4dwipe called|r"
			end
			y = y - 6
			frame.pShapeLabel:ClearAllPoints()
			frame.pShapeLabel:SetPoint("TOPLEFT", 12, y)
			frame.pShapeLabel:SetText(series)
			frame.pShapeLabel:Show()
			y = y - 14
			local n = #pshape
			frame.pShapeCols = frame.pShapeCols or {}
			for i = #frame.pShapeCols + 1, n + 4 do
				local t = frame:CreateTexture(nil, "OVERLAY")
				t:SetTexture("Interface\\Buttons\\WHITE8X8")
				frame.pShapeCols[i] = t
			end
			local w = frame:GetWidth() - 24
			local H = 22
			local step = w / n
			local cellDur = fight.duration / n
			for i = 1, n do
				local t = frame.pShapeCols[i]
				local h = math.max(1, math.floor(pshape[i] / peak * H + 0.5))
				local tMid = (i - 0.5) * cellDur
				if fight.calledWipeAt and tMid >= fight.calledWipeAt then
					t:SetVertexColor(0.90, 0.30, 0.30, 0.9)
				elseif result.role ~= "TANK" and fight.lustAt
					and tMid >= fight.lustAt and tMid <= fight.lustAt + 40 then
					t:SetVertexColor(0.40, 0.80, 1.00, 0.95)
				else
					t:SetVertexColor(0.42, 0.44, 0.50, 0.95)
				end
				t:ClearAllPoints()
				t:SetSize(math.max(1, step - 1), h)
				t:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 12 + (i - 1) * step, y - H)
				t:Show()
			end
			-- own death, marked where it happened
			local di = n
			for _, dt in ipairs(player.deathTimes or (player.deathTime and { player.deathTime } or {})) do
				di = di + 1
				local t = frame.pShapeCols[di]
				if t then
					t:SetVertexColor(0.95, 0.30, 0.30, 1)
					t:ClearAllPoints()
					t:SetSize(3, 3)
					t:SetPoint("BOTTOMLEFT", frame, "TOPLEFT",
						12 + math.min(w - 3, dt / fight.duration * w), y - H + H + 2)
					t:Show()
				end
			end
			y = y - H - 4
		end
	end

	-- danger-window timeline (Josh 2026-07-24): healers see the GROUP's
	-- spikes vs their own raid CDs; tanks AND DPS see their PERSONAL
	-- intake spikes vs their own defensives. Legacy records without
	-- personal attribution fall back to team coloring rather than
	-- rendering everything as falsely uncovered. Hidden entirely in Raw
	-- mode — that view is parses and nothing else.
	local mm = player and player.metrics or {}
	-- pick the map AND remember which kind it is: a healer whose record has
	-- no group map falls back to their personal intake map, and the label/
	-- field reads must follow the MAP, not the role (audit 2026-07-24 — the
	-- and-or chain handed healers a personal map wearing group labels)
	local map, isGroupMap
	if not result.parse then
		if result.role == "HEALER" and mm.groupSpikeMap then
			map, isGroupMap = mm.groupSpikeMap, true
		else
			map = mm.spikeMap
		end
	end
	local hasMine = false
	for _, win in ipairs(map or {}) do
		if win[4] ~= nil then
			hasMine = true
			break
		end
	end
	if frame.stripTrack then
		frame.stripTrack:Hide()
		frame.stripLabel:Hide()
		for _, b in ipairs(frame.stripBands or {}) do
			b:Hide()
		end
	end
	if map and #map > 0 and (fight.duration or 0) > 0 then
		if not frame.stripTrack then
			frame.stripLabel = face(frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), 11)
			frame.stripTrack = frame:CreateTexture(nil, "ARTWORK")
			frame.stripTrack:SetTexture("Interface\\Buttons\\WHITE8X8")
			frame.stripTrack:SetVertexColor(0.14, 0.14, 0.17, 1)
			frame.stripBands = {}
		end
		y = y - 6
		frame.stripLabel:ClearAllPoints()
		frame.stripLabel:SetPoint("TOPLEFT", 12, y)
		local lbl
		if not isGroupMap then
			lbl = "your damage spikes \194\183 |cff55cc55defensive met it|r / |cffe64d4dno defensive|r"
		elseif hasMine then
			lbl = "group spikes \194\183 |cff55cc55you covered it|r / |cffe64d4dyou didn't|r"
		else
			-- pre-attribution record: team coloring, honestly labeled
			lbl = "group spikes \194\183 |cff55cc55a cooldown met it|r / |cffe64d4duncovered|r"
		end
		frame.stripLabel:SetText(lbl)
		frame.stripLabel:Show()
		y = y - 14
		local w = frame:GetWidth() - 24
		frame.stripTrack:ClearAllPoints()
		frame.stripTrack:SetPoint("TOPLEFT", 12, y)
		frame.stripTrack:SetSize(w, 7)
		frame.stripTrack:Show()
		local lastRight -- chunky-block layout (see BAND_MIN below)
		for i, win in ipairs(map) do
			local band = frame.stripBands[i]
			if not band or not band.tex then
				-- bands are hoverable frames (Josh 2026-07-24): each tick
				-- tells its own story — what hit, how hard, your answer
				band = CreateFrame("Frame", nil, frame)
				band.tex = band:CreateTexture(nil, "OVERLAY")
				band.tex:SetAllPoints(band)
				band.tex:SetTexture("Interface\\Buttons\\WHITE8X8")
				band:EnableMouse(true)
				band:SetScript("OnEnter", function(b)
					if b.tipLines then
						TP.Tooltip:Show(b, tipSide() == "LEFT" and "FORCE_LEFT" or "FORCE_RIGHT",
							b.tipTitle, b.tipLines)
					end
				end)
				band:SetScript("OnLeave", function()
					TP.Tooltip:Hide()
				end)
				frame.stripBands[i] = band
			end
			-- chunky discrete blocks (Josh 2026-07-24: the design-mock strip
			-- reads as clean event blocks; true-scale 3px slivers packed
			-- edge-to-edge read as smudge): 8px floor, 2px gap enforced,
			-- width still stretches for genuinely long spikes. Blocks
			-- CENTER on the spike's true moment so they line up with the
			-- fight-shape graph above (left-anchoring drifted them right)
			local width = math.max(BAND_MIN, (win[2] - win[1] + 1) / fight.duration * w)
			local left = (win[1] + win[2] + 1) / 2 / fight.duration * w - width / 2
			if lastRight and left < lastRight + 2 then
				left = lastRight + 2
			end
			left = math.max(0, math.min(left, w - BAND_MIN))
			width = math.min(width, w - left)
			lastRight = left + width
			band:ClearAllPoints()
			-- +1: the 9px band centers on the 7px track (at -1 it hung 3px
			-- below the track — audit 2026-07-24)
			band:SetPoint("TOPLEFT", frame.stripTrack, "TOPLEFT", left, 1)
			band:SetSize(width, 9)
			-- personal maps carry "you covered it" in [3]; group maps in [4]
			-- (legacy group records fall back to team coverage [3])
			local covered
			if not isGroupMap then
				covered = win[3]
			else
				covered = hasMine and win[4] or (not hasMine and win[3])
			end
			if covered then
				band.tex:SetVertexColor(0.33, 0.80, 0.33, 1)
			else
				band.tex:SetVertexColor(0.90, 0.30, 0.30, 1)
			end
			-- the band's own story (fields 5-7; absent on legacy records)
			band.tipTitle = ("Spike %d:%02d\226\128\147%d:%02d"):format(
				math.floor(win[1] / 60), win[1] % 60, math.floor(win[2] / 60), win[2] % 60)
			local lines = {}
			if win[5] then
				lines[1] = { win[6] and ("%s \194\183 %s over %ds"):format(
					win[6], TP.FormatNumber(win[5]), math.max(1, win[2] - win[1]))
					or ("%s over %ds"):format(TP.FormatNumber(win[5]), math.max(1, win[2] - win[1])), 1, 1, 1 }
			end
			if covered and win[7] then
				lines[#lines + 1] = { "Covered by " .. win[7], 0.33, 0.80, 0.33 }
			elseif covered then
				lines[#lines + 1] = { "Covered", 0.33, 0.80, 0.33 }
			else
				lines[#lines + 1] = { isGroupMap and "You didn't cover it" or "No defensive", 0.90, 0.35, 0.35 }
			end
			-- a single-target external that rode the spike ([8], personal
			-- maps): context for why you lived — the verdict above still
			-- judges YOUR buttons only
			if not isGroupMap and win[8] then
				lines[#lines + 1] = { win[8] .. " rode this spike", 0.40, 0.85, 1.00 }
			end
			if not win[5] then
				-- legacy capture: a dead hover reads as broken, so say why
				-- the ability/damage detail is missing instead
				lines[#lines + 1] = { "Recorded before hit tracking - new pulls carry the ability and damage.", 0.6, 0.6, 0.6, true }
			end
			band.tipLines = lines
			band:Show()
		end
		for i = #map + 1, #(frame.stripBands or {}) do
			frame.stripBands[i]:Hide()
		end
		y = y - 11
	end

	frame.total:SetText("")
	-- the player-card footer retired (Josh 2026-07-25): flask/food lives
	-- in the verdict grid (scored, where points live) and the pull time
	-- moved to the header's time line
	frame.footer:SetText("")
	frame.footer:Hide()
	-- y already sits at the last row's bottom edge; +8 mirrors the top pad
	frame:SetHeight(-y + 8)

	anchorPanel()
	frame.close:SetShown(self.pinned)
	frame.role:ClearAllPoints()
	frame.role:SetPoint("TOPRIGHT", self.pinned and -28 or -10, -12)
	frame:Show()
	self.currentGUID = result.guid
end

-- Hover lifecycle: the panel IS the scorecard's row tooltip. A ticker keeps
-- it alive while the mouse is over the scorecard or the panel itself (so
-- bullet tooltips stay reachable), and hides it once the mouse leaves both.
local hoverTicker

local function stopHoverWatch()
	if hoverTicker then
		hoverTicker:Cancel()
		hoverTicker = nil
	end
end

local function startHoverWatch()
	if hoverTicker then
		return
	end
	hoverTicker = C_Timer.NewTicker(0.25, function()
		if Panel.pinned then
			stopHoverWatch()
			return
		end
		local card = _G.TrueParseWindow
		-- right offset bridges the 6px gap between the scorecard and the panel
		if (frame and frame:IsShown() and frame:IsMouseOver())
			or (card and card:IsShown() and card:IsMouseOver(0, 0, 0, 8)) then
			return
		end
		stopHoverWatch()
		if frame then
			frame:Hide()
		end
		Panel.currentGUID = nil
	end)
end

-- Close everything at once: pinned or hovering panel, gauge tooltip, and
-- the shared text tooltip (collapsing the meter window calls this)
function Panel:HideAll()
	self.pinned = false
	self.currentGUID = nil
	stopHoverWatch()
	if frame then
		frame:Hide()
	end
	if metricTip then
		metricTip:Hide()
	end
	if TP.Tooltip then
		TP.Tooltip:Hide()
	end
end

function Panel:ShowHover(fight, result)
	if self.pinned then
		return
	end
	self:ShowFor(fight, result)
	startHoverWatch()
end

function Panel:ShowHoverGroup(fight, results)
	if self.pinned then
		return
	end
	self:ShowForGroup(fight, results)
	startHoverWatch()
end

function Panel:Toggle(fight, result)
	if self.pinned and frame and frame:IsShown() and self.currentGUID == result.guid then
		self.pinned = false
		frame:Hide()
		self.currentGUID = nil
	else
		self.pinned = true
		stopHoverWatch()
		self:ShowFor(fight, result)
	end
end

-- Group breakdown: same bullet view, group-level takeaways
function Panel:ShowForGroup(fight, results)
	if not frame then
		createFrame()
	end

	local label = (#results > 5) and "Raid" or "Group"
	frame.title:SetText(label)
	frame.title:SetTextColor(1, 0.82, 0.2)
	-- the group wears its icon too (Josh 2026-07-25), matching the
	-- scorecard's pinned row
	ensureSpecIcon()
	frame.specIcon.tex:SetTexture("Interface\\Icons\\INV_Misc_GroupNeedMore")
	frame.specIcon.tipTitle = label
	frame.specIcon.tipLines = { { ("%d players"):format(#results), 1, 1, 1 } }
	frame.specIcon:Show()
	frame.title:ClearAllPoints()
	frame.title:SetPoint("TOPLEFT", 32, -9)
	-- group header hovers: the name echoes the count; the score is inert
	local gth = headerHover("titleHover", frame.title)
	gth.tipTitle = label
	gth.tipLines = frame.specIcon.tipLines
	headerHover("scoreHover", frame.bigScore).tipTitle = nil
	frame.subtitle:SetText("")
	frame.bigScore:SetText("")
	-- same compact header the player card uses
	frame.role:SetText(("%d players"):format(#results))
	local groupSum = 0
	for _, r in ipairs(results) do
		groupSum = groupSum + r.score
	end
	local groupScore = groupSum / #results
	-- same mockup header as the player card: hero score beside the name,
	-- one dim subheader line
	frame.bigScore:SetText(TP.Scoring.Grades.ColoredScore(groupScore))
	local sub = { fight.name or "this fight" }
	if fight.wipe then
		sub[#sub + 1] = fight.bossPct and ("|cffe64d4dwipe %.0f%%|r"):format(fight.bossPct)
			or "|cffe64d4dwipe|r"
	end
	if self.groupRunScore then
		sub[#sub + 1] = "run avg " .. TP.Scoring.Grades.ColoredScore(self.groupRunScore)
	end
	frame.scoreLine:SetText(table.concat(sub, " \194\183 "))
	frame.runLine:SetText("")
	-- third header line: duration + pull time (Josh 2026-07-25)
	local tparts = {}
	if (fight.duration or 0) > 0 then
		tparts[#tparts + 1] = ("%d:%02d"):format(math.floor(fight.duration / 60), fight.duration % 60)
	end
	if fight.capturedAt and (fight.duration or 0) > 0 then
		tparts[#tparts + 1] = "pulled " .. date("%H:%M", fight.capturedAt - fight.duration)
	end
	frame.timeLine:SetText(table.concat(tparts, " \194\183 "))
	frame.timeLine:Show()
	-- the group card speaks the Signal Column language too (redesign's
	-- last surface): bars/glyphs/pips from the tested ForGroup logic.
	-- Raw mode (Josh 2026-07-24): same purity rule as the player card —
	-- only WCL-backed rows (group-averaged throughput + kill speed), no
	-- advisors, no rollup, no graphs.
	local raw = results[1] and results[1].parse
	local y = -56 -- three header lines now (name, boss, time)
	-- same header rule as the player card (4px above, 6px below)
	if not frame.headerRule then
		frame.headerRule = frame:CreateTexture(nil, "ARTWORK")
		frame.headerRule:SetColorTexture(0.5, 0.5, 0.55, 0.18)
		frame.headerRule:SetHeight(1)
	end
	y = y - 4
	frame.headerRule:ClearAllPoints()
	frame.headerRule:SetPoint("TOPLEFT", 10, y)
	frame.headerRule:SetPoint("TOPRIGHT", -10, y)
	frame.headerRule:Show()
	y = y - 6
	local total = 0
	local function groupRow(sig)
		total = total + 1
		local row = getRow(total, y)
		y = y - ROW_HEIGHT
		row.metricData = nil
		row.tooltipData = nil
		if sig.kind == "text" then
			-- sentence-shaped lines (dispel volume, avoidable pressure,
			-- aggro stories) span the card like award rows — each with
			-- its OWN hover (the Other rollup hid them, Josh 2026-07-25).
			-- They wear their metric's icon when one exists.
			ensureSignalWidgets(row)
			hideSignalWidgets(row)
			if sig.icon then
				row.icon:SetTexture(sig.icon)
				row.icon:Show()
				row.symbol:SetText("")
			else
				row.symbol:SetText("\194\183")
			end
			local bad = (sig.points or 0) < 0
			local suffix = ""
			if sig.points and math.abs(sig.points) >= 0.5 then
				suffix = (" (%+d)"):format(sig.points >= 0
					and math.floor(sig.points + 0.5) or -math.floor(-sig.points + 0.5))
			end
			row.symbol:SetTextColor(bad and 0.90 or 0.55, bad and 0.35 or 0.55, bad and 0.35 or 0.60)
			row.text:SetText((sig.label or "") .. suffix)
			if bad then
				row.text:SetTextColor(0.90, 0.45, 0.45)
			else
				row.text:SetTextColor(0.80, 0.80, 0.75)
			end
			row.tooltipData = sig.tooltip or { title = sig.label, lines = {} }
			return row
		end
		-- no comparison ticks here: the WCL-backed rows render as bracket
		-- gauges (only the player's marker — Josh 2026-07-24), and the
		-- field median is the gauge's own green/blue seam at 50
		renderSignal(row, sig, nil)
		if sig.groupB then
			row.metricData = {
				b = sig.groupB, key = sig.key, duration = fight.duration,
				footerText = ("group average %d \194\183 %d players"):format(
					sig.value or 0, sig.players or #results),
			}
		else
			row.tooltipData = sig.tooltip or { title = sig.label, lines = {} }
		end
		return row
	end
	local sigs = TP.Scoring.Signals.GroupRows(results, fight)

	-- Group-vs-group: kill speed against WCL's ranked kills for this
	-- encounter+bracket (the one number that compares GROUPS, not players)
	local GICONS = TP.Scoring.Signals.ICONS
	local speedPct, speedN, speedMedian, speedBounded = TP.Scoring.Engine.KillSpeedPercentile(fight)
	local function mmss(s)
		return ("%d:%02d"):format(math.floor(s / 60), s % 60)
	end
	if speedPct then
		if speedBounded then
			-- slower than WCL's served fastest 1000: we can't rank it, only
			-- say it fell outside that field (a precise % would be invented)
			sigs[#sigs + 1] = { key = "killSpeed", kind = "glyph", icon = GICONS.speed,
				label = "Past fastest 1000", good = true,
				tooltip = { title = "Kill speed", lines = {
					{ ("Killed in %s. WCL only ranks the fastest 1000 kills, and this was slower than all of them - so the exact speed percentile can't be known."):format(mmss(fight.duration or 0)), 0.8, 0.8, 0.8, true },
				} } }
		else
			-- a REAL population percentile: bracket colors with authority
			sigs[#sigs + 1] = { key = "killSpeed", kind = "bar", icon = GICONS.speed,
				label = "Kill speed", value = speedPct,
				speedMeta = {
					b = { value = fight.duration or 0, normalized = speedPct, pctile = speedPct },
					key = "Kill speed",
					duration = fight.duration,
					valueText = speedMedian
						and ("Killed in %s \194\183 median ranked kill %s"):format(mmss(fight.duration or 0), mmss(speedMedian))
						or ("Killed in %s"):format(mmss(fight.duration or 0)),
					footerText = ("faster than %d%% of ~%s ranked kills"):format(
						speedPct, TP.FormatNumber(speedN or 0)),
				} }
		end
	end

	-- the whole vs the parts: when kill speed and the group's own parses
	-- disagree hard, that gap IS the group-level story (a bounded ceiling
	-- isn't a real speed percentile, so it can't anchor the comparison)
	if speedPct and not speedBounded then
		local ga = TP.Scoring.Insights.GroupAnalysis(results, {}, speedPct)
		if ga.executionGap and math.abs(ga.executionGap) >= 20 then
			local up = ga.executionGap > 0
			sigs[#sigs + 1] = { key = "execGap", kind = "glyph", icon = GICONS.speed,
				label = up and "Execution carried" or "Output outran kill", good = up,
				tooltip = { title = "The whole vs the parts", lines = {
					{ ("speed p%d \194\183 output p%d"):format(ga.killPct + 0.5, ga.outputPct + 0.5), 1, 1, 1 },
					{ up and "The group killed faster than its parses predict: mechanics and timing carried beyond raw output."
						or "Parses outran the kill: output went somewhere other than winning.", 0.8, 0.8, 0.8, true },
				} } }
		end
	end

	-- encounter toughness context: a rough night on a rough boss should
	-- read that way (kill-time medians ranked across the tier)
	local toughness, bosses = nil, nil
	if TP.Scoring.Engine.EncounterToughness then
		toughness, bosses = TP.Scoring.Engine.EncounterToughness(fight)
	end
	if toughness and toughness >= 0.7 then
		sigs[#sigs + 1] = { key = "toughness", kind = "glyph", icon = GICONS.avoidable,
			label = "Tough boss", good = true,
			tooltip = { title = "Encounter toughness", lines = {
				{ ("Top %d%% of the tier's %d bosses by kill time. Context, not a judgment."):format(
					(1 - toughness) * 100 + 1, bosses or 0), 0.8, 0.8, 0.8, true },
			} } }
	end

	if raw then
		-- kill speed stays: it IS WCL data (ranked-kill percentile)
		local kept = {}
		for _, s in ipairs(sigs) do
			if s.base or s.key == "killSpeed" then
				kept[#kept + 1] = s
			end
		end
		sigs = kept
	end

	-- kind order (Josh 2026-07-24): the base WCL metrics (damage/healing)
	-- together on top, then the other bars, then counts, verdicts, and
	-- the Other rollup last. Stable within a tier so related stories
	-- keep their sequence.
	local KIND_RANK = { bar = 2, squares = 3, pips = 4, glyph = 5, text = 6 }
	local function rankOf(s)
		if s.kind == "bar" and (s.key == "damage" or s.key == "healing") then
			return 1
		end
		return KIND_RANK[s.kind] or 5
	end
	for i, s in ipairs(sigs) do
		s._i = i
	end
	table.sort(sigs, function(a, b)
		local ra, rb = rankOf(a), rankOf(b)
		if ra ~= rb then
			return ra < rb
		end
		return a._i < b._i
	end)
	for _, s in ipairs(sigs) do
		s._i = nil
	end
	-- LAYOUT A (Josh 2026-07-25), group flavor: gauges full-width, then
	-- the chip grid for counts/verdicts, then sentence text rows
	local fullRows, chipSigs, textSigs = {}, {}, {}
	for _, sig in ipairs(sigs) do
		if sig.kind == "text" then
			textSigs[#textSigs + 1] = sig
		elseif sig.kind == "bar" and not sig.num then
			fullRows[#fullRows + 1] = sig
		else
			chipSigs[#chipSigs + 1] = sig
		end
	end
	for _, sig in ipairs(fullRows) do
		local row = groupRow(sig)
		if sig.speedMeta then
			row.tooltipData = nil
			row.metricData = sig.speedMeta
		end
	end
	if #fullRows > 0 and (#chipSigs > 0 or #textSigs > 0) then
		if not frame.baseRule then
			frame.baseRule = frame:CreateTexture(nil, "ARTWORK")
			frame.baseRule:SetColorTexture(0.5, 0.5, 0.55, 0.18)
			frame.baseRule:SetHeight(1)
		end
		y = y - 4
		frame.baseRule:ClearAllPoints()
		frame.baseRule:SetPoint("TOPLEFT", 10, y)
		frame.baseRule:SetPoint("TOPRIGHT", -10, y)
		frame.baseRule:Show()
		y = y - 6
	elseif frame.baseRule then
		frame.baseRule:Hide()
	end
	local chipW = (WIDTH - 28 - CHIP_GAP) / 2 -- columns match the rows'
	local gridTop = y
	for i, sig in ipairs(chipSigs) do
		local c = getChip(i)
		local col = (i - 1) % 2
		local rowN = math.floor((i - 1) / 2)
		c:SetSize(chipW, ROW_HEIGHT)
		c:ClearAllPoints()
		c:SetPoint("TOPLEFT", 8 + col * (chipW + CHIP_GAP), gridTop - rowN * ROW_HEIGHT)
		renderChip(c, sig)
		c.metricData = nil
		c.tooltipData = sig.tooltip or { title = sig.label, lines = {} }
		c:Show()
	end
	hideChipsFrom(#chipSigs + 1)
	if #chipSigs > 0 then
		y = gridTop - math.ceil(#chipSigs / 2) * ROW_HEIGHT
	end
	for _, sig in ipairs(textSigs) do
		groupRow(sig)
	end
	hideRowsFrom(total + 1)
	fitWidth(total)

	-- the spike strip is player-view only; this frame is shared
	if frame.stripTrack then
		frame.stripTrack:Hide()
		frame.stripLabel:Hide()
		for _, b in ipairs(frame.stripBands or {}) do
			b:Hide()
		end
	end

	-- ===== group visualizations (2026-07-24 redesign, approved) =====
	local function vizLabel(which, text)
		if not frame[which] then
			frame[which] = face(frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall"), 11)
		end
		y = y - 6
		frame[which]:ClearAllPoints()
		frame[which]:SetPoint("TOPLEFT", 12, y)
		frame[which]:SetText(text)
		frame[which]:Show()
		y = y - 14
	end
	local function vizPool(which, n)
		frame[which] = frame[which] or {}
		for i = #frame[which] + 1, n do
			local t = frame:CreateTexture(nil, "OVERLAY")
			t:SetTexture("Interface\\Buttons\\WHITE8X8")
			frame[which][i] = t
		end
		return frame[which]
	end
	hideGroupViz()

	local w = frame:GetWidth() - 24

	-- 1) fight shape: group output/sec — the pull's whole arc. Steel
	-- columns; cyan inside the Bloodlust window; red after the wipe call;
	-- red dots above at each death.
	if not raw and fight.shape and #fight.shape > 1 and (fight.duration or 0) > 0 then
		local peak = 0
		for _, v in ipairs(fight.shape) do
			peak = math.max(peak, v)
		end
		if peak > 0 then
			-- mockup caption (Josh 2026-07-24): name the series and stamp
			-- the collapse moment when the detector found one
			local cap = "group output/sec \194\183 |cff66ccfflust window|r \194\183 |cffe64d4ddeaths above|r"
			if fight.calledWipeAt then
				cap = cap .. (" \194\183 |cffe64d4dcall collapse at %d:%02d|r"):format(
					math.floor(fight.calledWipeAt / 60), fight.calledWipeAt % 60)
			end
			vizLabel("shapeLabel", cap)
			local n = #fight.shape
			local cols = vizPool("shapeCols", n + 12)
			local H = 32
			-- fractional steps so the columns span EXACTLY the card width
			-- (integer column widths dropped the remainder — the graph fell
			-- short of the strips below it, Josh 2026-07-24)
			local step = w / n
			local cellDur = fight.duration / n
			for i = 1, n do
				local t = cols[i]
				local h = math.max(1, math.floor(fight.shape[i] / peak * H + 0.5))
				local tMid = (i - 0.5) * cellDur
				if fight.calledWipeAt and tMid >= fight.calledWipeAt then
					t:SetVertexColor(0.90, 0.30, 0.30, 0.9)
				elseif fight.lustAt and tMid >= fight.lustAt and tMid <= fight.lustAt + 40 then
					t:SetVertexColor(0.40, 0.80, 1.00, 0.95)
				else
					t:SetVertexColor(0.42, 0.44, 0.50, 0.95)
				end
				t:ClearAllPoints()
				t:SetSize(math.max(1, step - 1), h)
				t:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 12 + (i - 1) * step, y - H)
				t:Show()
			end
			-- death dots above the columns
			local di = n
			for _, p in pairs(fight.players or {}) do
				for _, dt in ipairs(p.deathTimes or (p.deathTime and { p.deathTime } or {})) do
					di = di + 1
					local t = cols[di]
					if t then
						t:SetVertexColor(0.95, 0.30, 0.30, 1)
						t:ClearAllPoints()
						t:SetSize(3, 3)
						t:SetPoint("BOTTOMLEFT", frame, "TOPLEFT",
							12 + math.min(w - 3, dt / fight.duration * w), y - H + H + 2)
						t:Show()
					end
				end
			end
			y = y - H - 6
		end
	end

	-- 2) team coverage strip: the group's spikes, covered by ANY cooldown
	-- (the teammate view removed from player cards lives here now)
	local teamMap
	if not raw then
		for _, r in ipairs(results) do
			local p = fight.players and fight.players[r.guid]
			local mmap = p and p.metrics and p.metrics.groupSpikeMap
			if mmap and #mmap > 0 then
				teamMap = mmap
				break
			end
		end
	end
	if teamMap and (fight.duration or 0) > 0 then
		vizLabel("covLabel", "group spikes \194\183 |cff55cc55a cooldown met it|r / |cffe64d4duncovered|r")
		-- background track (it was missing here — audit 2026-07-24: bands
		-- floated on nothing while the player strip had its rail)
		if not frame.covTrack then
			frame.covTrack = frame:CreateTexture(nil, "ARTWORK")
			frame.covTrack:SetTexture("Interface\\Buttons\\WHITE8X8")
			frame.covTrack:SetVertexColor(0.14, 0.14, 0.17, 1)
		end
		frame.covTrack:ClearAllPoints()
		frame.covTrack:SetPoint("TOPLEFT", 12, y)
		frame.covTrack:SetSize(w, 7)
		frame.covTrack:Show()
		-- hoverable bands, same as the player strip (Josh 2026-07-24)
		frame.covBands = frame.covBands or {}
		for i = #frame.covBands + 1, #teamMap do
			local band = CreateFrame("Frame", nil, frame)
			band.tex = band:CreateTexture(nil, "OVERLAY")
			band.tex:SetAllPoints(band)
			band.tex:SetTexture("Interface\\Buttons\\WHITE8X8")
			band:EnableMouse(true)
			band:SetScript("OnEnter", function(b)
				if b.tipLines then
					TP.Tooltip:Show(b, tipSide() == "LEFT" and "FORCE_LEFT" or "FORCE_RIGHT",
						b.tipTitle, b.tipLines)
				end
			end)
			band:SetScript("OnLeave", function()
				TP.Tooltip:Hide()
			end)
			frame.covBands[i] = band
		end
		local lastRight -- same chunky-block layout as the player strip:
		-- centered on the spike's true moment, collisions resolved after
		for i, win in ipairs(teamMap) do
			local band = frame.covBands[i]
			local bw = math.max(BAND_MIN, (win[2] - win[1] + 1) / fight.duration * w)
			local left = (win[1] + win[2] + 1) / 2 / fight.duration * w - bw / 2
			if lastRight and left < lastRight + 2 then
				left = lastRight + 2
			end
			left = math.max(0, math.min(left, w - BAND_MIN))
			bw = math.min(bw, w - left)
			lastRight = left + bw
			if win[3] then
				band.tex:SetVertexColor(0.33, 0.80, 0.33, 1)
			else
				band.tex:SetVertexColor(0.90, 0.30, 0.30, 1)
			end
			band:ClearAllPoints()
			band:SetSize(bw, 9)
			band:SetPoint("TOPLEFT", 12 + left, y + 1)
			band.tipTitle = ("Spike %d:%02d\226\128\147%d:%02d"):format(
				math.floor(win[1] / 60), win[1] % 60, math.floor(win[2] / 60), win[2] % 60)
			local lines = {}
			if win[5] then
				lines[1] = { win[6] and ("%s \194\183 %s over %ds"):format(
					win[6], TP.FormatNumber(win[5]), math.max(1, win[2] - win[1]))
					or ("%s over %ds"):format(TP.FormatNumber(win[5]), math.max(1, win[2] - win[1])), 1, 1, 1 }
			end
			if win[3] then
				-- name the coverer when the record knows them
				local coverText = "A cooldown met it"
				if win[8] and win[9] then
					coverText = ("Covered by %s's %s"):format(win[8], win[9])
				elseif win[8] then
					coverText = "Covered by " .. win[8]
				elseif win[9] then
					coverText = "Covered by " .. win[9]
				end
				lines[#lines + 1] = { coverText, 0.33, 0.80, 0.33 }
			else
				lines[#lines + 1] = { "Uncovered", 0.90, 0.35, 0.35 }
			end
			if not win[5] then
				lines[#lines + 1] = { "Recorded before hit tracking - new pulls carry the ability and damage.", 0.6, 0.6, 0.6, true }
			end
			band.tipLines = lines
			band:Show()
		end
		y = y - 9 - 4
	end

	-- (the progression staircase retired 2026-07-25, Josh: the fight
	-- picker's wipe-% labels already tell the night's story)

	frame.total:SetText("") -- header lines carry the numbers now
	-- group footer (Josh 2026-07-24, mirroring the player card): how many
	-- of the REPORTING players brought flask+food, plus the pull time.
	-- Consumables are self-reported counts, so only installs can vouch —
	-- the denominator says so honestly. Raw stays pure WCL.
	local footParts = {}
	if not raw then
		local reporting, ready = 0, 0
		for _, r in ipairs(results) do
			local p = fight.players and fight.players[r.guid]
			local cons = p and p.metrics and p.metrics.consumables
			if cons ~= nil then
				reporting = reporting + 1
				if cons >= 2 then
					ready = ready + 1
				end
			end
		end
		if reporting > 0 then
			-- unique info here (no prepared chip exists on the group
			-- card); the pull time moved to the header's time line
			local mark = ready == reporting
				and "|TInterface\\RaidFrame\\ReadyCheck-Ready:11|t"
				or "|TInterface\\RaidFrame\\ReadyCheck-NotReady:11|t"
			footParts[#footParts + 1] = ("flask+food %d/%d %s"):format(ready, reporting, mark)
		end
	end
	if #footParts > 0 then
		frame.footer:SetText(table.concat(footParts, " \194\183 "))
		frame.footer:Show()
		frame:SetHeight(-y + 22)
	else
		frame.footer:SetText("")
		frame.footer:Hide()
		frame:SetHeight(-y + 8)
	end
	anchorPanel()
	frame.close:SetShown(self.pinned)
	frame.role:ClearAllPoints()
	frame.role:SetPoint("TOPRIGHT", self.pinned and -28 or -10, -12)
	frame:Show()
	-- the pinned RUN card is distinct from the fight group card: a scroll
	-- or resize re-render must not swap one for the other (audit 2026-07-16)
	self.currentGUID = fight.isRun and "RUN" or "GROUP"
end

function Panel:ToggleGroup(fight, results)
	local tag = fight.isRun and "RUN" or "GROUP"
	if self.pinned and frame and frame:IsShown() and self.currentGUID == tag then
		self.pinned = false
		frame:Hide()
		self.currentGUID = nil
	else
		self.pinned = true
		stopHoverWatch()
		self:ShowForGroup(fight, results)
	end
end

-- Called when the scorecard re-renders for a newly captured fight: follow
-- the same player into the new results, or close if they're absent.
function Panel:OnFightRendered(fight, results)
	if not frame or not frame:IsShown() or not self.currentGUID then
		return
	end
	if self.currentGUID == "GROUP" then
		self:ShowForGroup(fight, results)
		return
	end
	if self.currentGUID == "RUN" then
		-- the pinned RUN card is a different fight record than the one just
		-- rendered: leave it alone (falling through to the player loop
		-- matched nothing and CLOSED it on every scroll — audit 2026-07-24)
		return
	end
	for _, r in ipairs(results) do
		if r.guid == self.currentGUID then
			self:ShowFor(fight, r)
			return
		end
	end
	self.pinned = false
	frame:Hide()
	self.currentGUID = nil
end
