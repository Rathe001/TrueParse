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
local ROW_HEIGHT = 15
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

	metricTip.title = metricTip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	metricTip.title:SetPoint("TOPLEFT", 10, -8)
	metricTip.value = metricTip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	metricTip.value:SetPoint("TOPLEFT", 10, -24)
	metricTip.median = metricTip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	metricTip.median:SetPoint("TOPLEFT", 10, -38)
	-- no right anchor: the TIP fits its longest line (fitTipWidth), so
	-- lines never truncate or spill
	metricTip.median:SetJustifyH("LEFT")
	metricTip.median:SetWordWrap(false)

	-- the parse coach's line: own signature-spell rate vs top parses
	-- (one line, only when a real gap exists — never a wall of text)
	metricTip.coach = metricTip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	metricTip.coach:SetPoint("TOPLEFT", 10, -52)
	metricTip.coach:SetJustifyH("LEFT")
	metricTip.coach:SetWordWrap(false)
	metricTip.coach:SetTextColor(0.4, 0.85, 1)

	-- (the parse-bracket gauge used to live here; it moved onto the card's
	-- percentile rows themselves — Josh 2026-07-24 — so the tip is text)

	metricTip.footer = metricTip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	metricTip.footer:SetPoint("BOTTOMLEFT", 10, 8)
end

local function showMetricTip(anchor, data)
	if not metricTip then
		buildMetricTip()
	end
	local b, key, duration = data.b, data.key, data.duration
	metricTip.title:SetText(TP.METRIC_LABELS[key] or key)

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

	-- the parse coach: on throughput metrics, one line naming the biggest
	-- signature-spell gap vs top parses of this spec (nil when close)
	local coachText
	if (key == "damage" or key == "healing") and TP.Scoring.Insights.ParseGap then
		local gap = TP.Scoring.Insights.ParseGap(data.specID, data.metrics, duration)
		if gap then
			coachText = "coach: " .. gap.text
		end
	end
	metricTip.coach:SetText(coachText or "")

	metricTip:SetHeight(76 + (coachText and 14 or 0))

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
	for _, fs in ipairs({ metricTip.title, metricTip.value, metricTip.median, metricTip.coach, metricTip.footer }) do
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

local function rowLeave()
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

-- ===== Signal Column rendering (2026-07-26 redesign) =====
-- Each row: [icon][verdict label][marks: bar/squares/pips/glyph][num][pts]
-- Widgets are created lazily and shared with the legacy bullet layout
-- (awards and the group card still render symbol+text rows).
local MARK_POOL = 10 -- fixed segment count: gauges always span the area
local CONTENT_X = 116 -- marks start after icon(16) + label(~80)
local NUM_W, PTS_W = 30, 26
local BAR_W = 300 - 12 - CONTENT_X - (NUM_W + PTS_W + 14) -- content width
local SEG_W = math.floor((BAR_W - (MARK_POOL - 1) * 2) / MARK_POOL)

local function ensureSignalWidgets(row)
	if row.icon then
		return
	end
	row.icon = row:CreateTexture(nil, "ARTWORK")
	row.icon:SetSize(13, 13)
	row.icon:SetPoint("LEFT", 8, 0)
	row.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92) -- the clean-addon crop
	row.label = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.label:SetPoint("LEFT", 26, 0)
	row.label:SetWidth(CONTENT_X - 30)
	row.label:SetJustifyH("LEFT")
	row.label:SetWordWrap(false)
	row.track = row:CreateTexture(nil, "ARTWORK")
	row.track:SetColorTexture(0.12, 0.12, 0.14, 1)
	row.track:SetPoint("LEFT", CONTENT_X, 0)
	row.track:SetPoint("RIGHT", -(NUM_W + PTS_W + 14), 0)
	row.track:SetHeight(7)
	row.fill = row:CreateTexture(nil, "OVERLAY")
	row.fill:SetPoint("TOPLEFT", row.track, "TOPLEFT", 0, 0)
	row.fill:SetPoint("BOTTOMLEFT", row.track, "BOTTOMLEFT", 0, 0)
	row.tick = row:CreateTexture(nil, "OVERLAY", nil, 2)
	row.tick:SetColorTexture(0.92, 0.92, 0.92, 0.85)
	row.tick:SetSize(1, 11)
	row.num = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.num:SetPoint("RIGHT", -(PTS_W + 10), 0)
	row.num:SetWidth(NUM_W)
	row.num:SetJustifyH("RIGHT")
	row.pts = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
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
	if sig.points and math.abs(sig.points) >= 0.5 then
		row.pts:SetText(("%+d"):format(sig.points >= 0
			and math.floor(sig.points + 0.5) or -math.floor(-sig.points + 0.5)))
		row.pts:Show()
	else
		row.pts:SetText("")
	end

	if sig.kind == "bar" then
		row.track:Show()
		local v = sig.value or 0
		local r, g, b
		local gauge = false
		if sig.tier then
			-- quantile-anchored raw metrics (activity, mitigation): the
			-- bar's width is the raw %, its color the population tier
			r, g, b = TP.Scoring.Grades.ColorForScore(sig.tier)
		elseif sig.num or sig.raw then
			-- non-percentile bars (coverage, activity, mitigation, share
			-- scores, unranked throughput): VERDICT colors, never brackets
			-- — a 68% activity that costs points must not wear parse blue
			-- (Josh 2026-07-24). Green earned, red cost, neutral otherwise.
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
			gauge = true
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
			row.marker:SetPoint("CENTER", row.track, "LEFT", math.min(99, v) / 100 * w, 0)
			row.marker:Show()
		else
			row.fill:SetColorTexture(r, g, b, 0.9)
			row.fill:SetWidth(math.max(1, w * math.min(99, v) / 100))
			row.fill:Show()
		end
		local avg = groupAvg and groupAvg[sig.key]
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

	-- big score, top right (group view only; player view puts the score in
	-- a compact line under the name)
	frame.bigScore = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	local fontPath, _, fontFlags = frame.bigScore:GetFont()
	frame.bigScore:SetFont(fontPath, 26, fontFlags)
	frame.bigScore:SetPoint("TOPRIGHT", -10, -8)
	frame.bigScore:SetJustifyH("RIGHT")

	-- role tag on the title row, right side (player view)
	frame.role = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.role:SetPoint("TOPRIGHT", -10, -10)
	frame.role:SetJustifyH("RIGHT")

	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.title:SetPoint("TOPLEFT", 10, -8)
	frame.title:SetPoint("RIGHT", frame.role, "LEFT", -8, 0)
	frame.title:SetJustifyH("LEFT")

	frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.subtitle:SetPoint("TOPLEFT", 10, -24)
	frame.subtitle:SetPoint("RIGHT", frame.bigScore, "LEFT", -8, 0)
	frame.subtitle:SetJustifyH("LEFT")

	-- "54 vs Siegecrafter Blackfuse" / "58 avg this run" (player view)
	frame.scoreLine = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.scoreLine:SetPoint("TOPLEFT", 10, -23)
	frame.scoreLine:SetPoint("TOPRIGHT", -10, -23)
	frame.scoreLine:SetJustifyH("LEFT")

	frame.runLine = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	frame.runLine:SetPoint("TOPLEFT", 10, -36)
	frame.runLine:SetPoint("TOPRIGHT", -10, -36)
	frame.runLine:SetJustifyH("LEFT")

	frame.total = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.total:SetPoint("BOTTOMLEFT", 10, 10)
end

-- group-card visualization elements (fight shape, team coverage,
-- staircase) — hidden wholesale when the shared frame shows a player
local GROUP_VIZ = { "shapeLabel", "shapeCols", "covLabel", "covBands", "stairLabel", "stairCols" }
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

-- Important lines never truncate: widen the card to its longest bullet
-- (within reason), then keep every row tracking the frame width.
local MAX_WIDTH = 430
local function fitWidth(rowCount)
	local needed = WIDTH
	for i = 1, math.min(rowCount, #rows) do
		-- GetStringWidth measures the FULL text, not the clipped render
		local w = rows[i].text:GetStringWidth() + 28 + 8 + 12
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
			mitigation = "Time with an active-mitigation buff up.",
			avoidable = "No more than a fair share of avoidable damage.",
			cdTiming = "Damage spikes answered in time: raid CDs on group spikes, your external on tank spikes. Judged only on spikes your cooldowns could reach.",
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

function Panel:ShowFor(fight, result)
	if not frame then
		createFrame()
	end

	local cr, cg, cb = TP.ClassColor(result.class)
	frame.title:SetText(result.name or "?")
	frame.title:SetTextColor(cr, cg, cb)
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
	frame.scoreLine:SetText(("%s%s vs %s%s%s"):format(
		approx and "~" or "", TP.Scoring.Grades.ColoredScore(result.score),
		fight.name or "this fight", fight.wipe and (fight.bossPct and (" |cffe64d4d(wipe %.0f%%)|r"):format(fight.bossPct) or " |cffe64d4d(wipe)|r") or "", pbTag))
	local runR = self.runScores and self.runScores[result.guid]
	-- progression line: this player's last kills of this boss, oldest
	-- first, the PB pattern's memo keeps it cheap
	local histText
	if fight.isBoss and not fight.isRun and TP.FightHistory and TP.FightHistory.ScoreHistory then
		local hist = TP.FightHistory:ScoreHistory(fight, result.guid, 6)
		if hist then
			local parts = {}
			for _, s in ipairs(hist) do
				parts[#parts + 1] = TP.Scoring.Grades.ColoredScore(s)
			end
			histText = "|cff888888this boss:|r " .. table.concat(parts, " ")
		end
	end
	if runR and histText then
		frame.runLine:SetText(TP.Scoring.Grades.ColoredScore(runR.score)
			.. " avg this run  " .. histText)
	elseif runR then
		frame.runLine:SetText(TP.Scoring.Grades.ColoredScore(runR.score) .. " avg this run")
	elseif histText then
		frame.runLine:SetText(histText)
	else
		frame.runLine:SetText("")
	end

	local y = (runR or histText) and -50 or -37

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

	-- a light rule after the throughput bars: everything above IS the
	-- base score (no +/- points by design), everything below adjusts it
	-- (Josh 2026-07-24)
	local drewBase, ruleDrawn = false, false
	for _, sig in ipairs(signals) do
		if sig.base then
			drewBase = true
		elseif drewBase and not ruleDrawn then
			ruleDrawn = true
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
		end
		local row = nextRow()
		renderSignal(row, sig, groupAvg)
		if sig.b then
			-- throughput bars keep the full metric tooltip (gauge + coach)
			row.metricData = { b = sig.b, key = sig.key,
				duration = fight.duration, role = result.role,
				specID = player and player.specID,
				metrics = player and player.metrics }
		elseif sig.kind == "other" and sig.items then
			-- the rollup row: itemized breakdown in the tooltip
			local lines = {}
			for _, it in ipairs(sig.items) do
				local pts = ""
				if it.points then
					local n = it.points >= 0 and math.floor(it.points + 0.5)
						or -math.floor(-it.points + 0.5)
					pts = (" (%+d)"):format(n)
				end
				local bad = (it.points or 0) < 0
				lines[#lines + 1] = { it.label .. pts,
					bad and 0.9 or 0.8, bad and 0.45 or 0.8, bad and 0.45 or 0.75 }
			end
			row.tooltipData = { title = "Other", lines = lines }
		elseif sig.key == "deaths" and player and player.deathRecap then
			row.tooltipData = { title = sig.label, lines = deathRecapLines(player) }
		else
			local lines = {
				{ infoHelp()[sig.key] or PENALTY_HELP[sig.key]
					or "Reported by this player's TrueParse.", 0.8, 0.8, 0.8, true } }
			if sig.detail then
				lines[#lines + 1] = { sig.detail, 1, 1, 1, true }
			end
			row.tooltipData = { title = sig.label, lines = lines }
		end
	end

	-- the parse coach keeps its visible line (Josh 2026-07-24: "I don't
	-- see the coach anywhere" — tooltip-only was invisible). Advice, not a
	-- signal: rendered like the award text rows, in the coach's cyan.
	-- Raw mode stays pure WCL.
	if not result.parse and player and player.metrics and player.metrics.profCasts
		and player.specID and TP.Scoring.Insights.ParseGap then
		local gap = TP.Scoring.Insights.ParseGap(player.specID, player.metrics, fight.duration)
		if gap then
			local row = nextRow()
			hideSignalWidgets(row)
			row.symbol:SetText("\194\183")
			row.symbol:SetTextColor(0.40, 0.85, 1.00)
			row.text:SetText("Coach: " .. gap.text)
			row.text:SetTextColor(0.40, 0.85, 1.00)
			row.tooltipData = { title = "Parse coach", lines = {
				{ infoHelp().coach, 0.8, 0.8, 0.8, true } } }
		end
	end

	if frame.baseRule and not ruleDrawn then
		frame.baseRule:Hide()
	end

	-- (players without TrueParse are flagged by the red X on their
	-- scorecard row, not an extra bullet here)
	hideRowsFrom(rowIndex + 1)
	fitWidth(rowIndex)

	hideGroupViz() -- shared frame: group graphs never linger on players

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
			frame.stripLabel = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
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
			local left = math.min(w - 2, win[1] / fight.duration * w)
			local width = math.max(3, (win[2] - win[1] + 1) / fight.duration * w)
			band:ClearAllPoints()
			band:SetPoint("TOPLEFT", frame.stripTrack, "TOPLEFT", left, -1)
			band:SetSize(math.min(width, w - left), 9)
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

	frame.total:SetText("") -- footer text is group-view only
	-- y already sits at the last row's bottom edge; +8 mirrors the top pad
	frame:SetHeight(-y + 8)

	anchorPanel()
	frame.close:SetShown(self.pinned)
	frame.role:ClearAllPoints()
	frame.role:SetPoint("TOPRIGHT", self.pinned and -28 or -10, -10)
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
	frame.subtitle:SetText("")
	frame.bigScore:SetText("")
	-- same compact header the player card uses
	frame.role:SetText(("%d players"):format(#results))
	local groupSum = 0
	for _, r in ipairs(results) do
		groupSum = groupSum + r.score
	end
	local groupScore = groupSum / #results
	frame.scoreLine:SetText(("%s vs %s%s"):format(
		TP.Scoring.Grades.ColoredScore(groupScore),
		fight.name or "this fight", fight.wipe and (fight.bossPct and (" |cffe64d4d(wipe %.0f%%)|r"):format(fight.bossPct) or " |cffe64d4d(wipe)|r") or ""))
	if self.groupRunScore then
		frame.runLine:SetText(TP.Scoring.Grades.ColoredScore(self.groupRunScore) .. " avg this run")
	else
		frame.runLine:SetText("")
	end

	if frame.baseRule then
		frame.baseRule:Hide() -- player-card element; the group card has none
	end
	-- the group card speaks the Signal Column language too (redesign's
	-- last surface): bars/glyphs/pips from the tested ForGroup logic.
	-- Raw mode (Josh 2026-07-24): same purity rule as the player card —
	-- only WCL-backed rows (group-averaged throughput + kill speed), no
	-- advisors, no rollup, no graphs.
	local raw = results[1] and results[1].parse
	local y = self.groupRunScore and -50 or -37 -- below the header lines
	local total = 0
	local function groupRow(sig)
		total = total + 1
		local row = getRow(total, y)
		y = y - ROW_HEIGHT
		-- comparison tick, group-card meaning (per the design guide): the
		-- player card's ticks mark YOUR group's average; here the peer is
		-- the ranked FIELD, so WCL-backed bars tick at the field median
		-- (p50). Share-scored bars have no field and get no tick.
		local fieldAvg
		if sig.kind == "bar" and not sig.raw
			and (sig.groupB or sig.key == "killSpeed") then
			fieldAvg = { [sig.key] = 50 }
		end
		renderSignal(row, sig, fieldAvg)
		row.metricData = nil
		row.tooltipData = nil
		if sig.groupB then
			row.metricData = {
				b = sig.groupB, key = sig.key, duration = fight.duration,
				footerText = ("group average %d \194\183 %d players"):format(
					sig.value or 0, sig.players or #results),
			}
		elseif sig.kind == "other" and sig.items then
			local lines = {}
			for _, it in ipairs(sig.items) do
				local pts = ""
				if it.points then
					local n = it.points >= 0 and math.floor(it.points + 0.5)
						or -math.floor(-it.points + 0.5)
					pts = (" (%+d)"):format(n)
				end
				local bad = (it.points or 0) < 0
				lines[#lines + 1] = { it.label .. pts,
					bad and 0.9 or 0.8, bad and 0.45 or 0.8, bad and 0.45 or 0.75 }
			end
			row.tooltipData = { title = "Other", lines = lines }
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
	local KIND_RANK = { bar = 2, squares = 3, pips = 4, glyph = 5, other = 6 }
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
	for _, sig in ipairs(sigs) do
		local row = groupRow(sig)
		if sig.speedMeta then
			row.tooltipData = nil
			row.metricData = sig.speedMeta
		end
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
			frame[which] = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
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
			vizLabel("shapeLabel", "output \194\183 |cff66ccfflust|r \194\183 |cffe64d4dafter the call|r")
			local n = #fight.shape
			local cols = vizPool("shapeCols", n + 12)
			local H = 26
			local colW = math.max(1, math.floor((w - (n - 1)) / n))
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
				t:SetSize(colW, h)
				t:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 12 + (i - 1) * (colW + 1), y - H)
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
			y = y - 26 - 6
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
		for i, win in ipairs(teamMap) do
			local band = frame.covBands[i]
			local left = math.min(w - 2, win[1] / fight.duration * w)
			local bw = math.max(3, (win[2] - win[1] + 1) / fight.duration * w)
			if win[3] then
				band.tex:SetVertexColor(0.33, 0.80, 0.33, 1)
			else
				band.tex:SetVertexColor(0.90, 0.30, 0.30, 1)
			end
			band:ClearAllPoints()
			band:SetSize(math.min(bw, w - left), 9)
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

	-- 3) progression staircase: boss % remaining per pull tonight, best
	-- pull in bracket green (only when 2+ measured wipes exist this run)
	if not raw and fight.wipe and fight.runID and TP.FightHistory then
		local pulls = {}
		for i = #TP.FightHistory.fights, 1, -1 do -- oldest first
			local f = TP.FightHistory.fights[i]
			if f.runID == fight.runID and f.name == fight.name and f.wipe and f.bossPct then
				pulls[#pulls + 1] = f
			end
		end
		if #pulls >= 2 then
			while #pulls > 12 do
				table.remove(pulls, 1)
			end
			local best = pulls[1]
			for _, f in ipairs(pulls) do
				if f.bossPct < best.bossPct then
					best = f
				end
			end
			vizLabel("stairLabel", ("pulls tonight \194\183 boss %% left \194\183 |cff1eff00best %.0f%%|r"):format(best.bossPct))
			local cols = vizPool("stairCols", #pulls)
			local H = 30
			local colW = math.max(4, math.floor((w - (#pulls - 1) * 3) / #pulls))
			for i, f in ipairs(pulls) do
				local t = cols[i]
				local h = math.max(2, math.floor(f.bossPct / 100 * H + 0.5))
				if f == best then
					t:SetVertexColor(0.12, 1.00, 0.00, 0.95)
				elseif f == fight then
					t:SetVertexColor(0.85, 0.85, 0.90, 0.95)
				else
					t:SetVertexColor(0.42, 0.44, 0.50, 0.9)
				end
				t:ClearAllPoints()
				t:SetSize(colW, h)
				t:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 12 + (i - 1) * (colW + 3), y - H)
				t:Show()
			end
			y = y - H - 4
		end
	end

	frame.total:SetText("") -- header lines carry the numbers now
	frame:SetHeight(-y + 8)
	anchorPanel()
	frame.close:SetShown(self.pinned)
	frame.role:ClearAllPoints()
	frame.role:SetPoint("TOPRIGHT", self.pinned and -28 or -10, -10)
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
