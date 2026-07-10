-- Breakdown panel: plain-language bullets explaining the grade.
-- Green + earned points, red - cost points (weak metrics and penalties),
-- dim mid-marks for middling contributions, gold + for awards — biggest
-- weight first. Hovering any bullet shows the full numeric derivation.
-- The panel IS the scorecard's tooltip: hovering a row shows it, clicking
-- a row pins it open (so bullets can be explored), close/click unpins.
local _, TP = ...

local Panel = { pinned = false }
TP.BreakdownPanel = Panel

local WIDTH = 380
local ROW_HEIGHT = 15
local FIRST_ROW_Y = -40

local COUNT_METRICS = { interrupts = true, dispels = true }
local PERCENT_METRICS = { buffUptime = true }

local frame
local rows = {}

-- Compact visual tooltip for METRIC bullets: what you did, the spec median,
-- and a parse-bracket gauge with a tick at your position — glanceable where
-- the old paragraph wasn't. Non-metric bullets use TP.Tooltip (same card).
local metricTip
local GAUGE_W, GAUGE_H = 190, 10
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
	-- tall enough that the marker label gets its own band between the
	-- median line and the gauge (it used to overlap both)
	metricTip:SetSize(GAUGE_W + 24, 108)
	metricTip:SetClampedToScreen(true)
	metricTip:SetFrameStrata("TOOLTIP")
	metricTip:Hide()

	metricTip.title = metricTip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	metricTip.title:SetPoint("TOPLEFT", 10, -8)
	metricTip.value = metricTip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	metricTip.value:SetPoint("TOPLEFT", 10, -24)
	metricTip.median = metricTip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	metricTip.median:SetPoint("TOPLEFT", 10, -38)

	metricTip.gauge = CreateFrame("Frame", nil, metricTip)
	metricTip.gauge:SetSize(GAUGE_W, GAUGE_H)
	metricTip.gauge:SetPoint("TOPLEFT", 12, -67)
	for _, z in ipairs(GAUGE_ZONES) do
		local t = metricTip.gauge:CreateTexture(nil, "ARTWORK")
		t:SetPoint("TOPLEFT", z[1] / 100 * GAUGE_W, 0)
		t:SetSize((z[2] - z[1]) / 100 * GAUGE_W, GAUGE_H)
		local mid = (z[1] + z[2]) / 2
		local r, g, b = TP.Scoring.Grades.ColorForScore(mid > 95 and 96 or mid)
		t:SetColorTexture(r, g, b, 0.55)
	end
	metricTip.marker = metricTip.gauge:CreateTexture(nil, "OVERLAY")
	metricTip.marker:SetSize(2, GAUGE_H + 6)
	metricTip.marker:SetColorTexture(1, 1, 1, 1)
	metricTip.markerText = metricTip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")

	metricTip.footer = metricTip:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	metricTip.footer:SetPoint("BOTTOMLEFT", 10, 8)
end

local function showMetricTip(anchor, data)
	if not metricTip then
		buildMetricTip()
	end
	local b, key, duration = data.b, data.key, data.duration
	metricTip.title:SetText(TP.METRIC_LABELS[key] or key)

	local valueText
	if COUNT_METRICS[key] then
		valueText = ("%d this fight"):format(b.value or 0)
	elseif PERCENT_METRICS[key] then
		valueText = ("Up %d%% of the fight"):format((b.value or 0) * 100 + 0.5)
	elseif duration and duration > 0 then
		valueText = ("%s · %s per second"):format(
			TP.FormatNumber(b.value or 0), TP.FormatNumber((b.value or 0) / duration))
	else
		valueText = TP.FormatNumber(b.value or 0)
	end
	metricTip.value:SetText(valueText)

	if b.specMedian and duration and duration > 0 then
		-- curveFrom names the comparison population when the evidence
		-- ladder had to zoom out (other bracket, all bosses, everyone)
		metricTip.median:SetText(("%s median: %s per second"):format(
			b.curveFrom or (b.rolePooled and "role" or "spec"), TP.FormatNumber(b.specMedian)))
	elseif b.lowDemand then
		metricTip.median:SetText("barely anything to heal - scored neutral")
	elseif b.relative and not b.absolute then
		metricTip.median:SetText("no WCL population data - vs group share")
	else
		metricTip.median:SetText("")
	end

	-- tick at your percentile when known, else at the normalized score
	local pos = b.pctile or b.normalized or 0
	local frac = math.max(0, math.min(99, pos)) / 100
	metricTip.marker:ClearAllPoints()
	metricTip.marker:SetPoint("CENTER", metricTip.gauge, "LEFT", frac * GAUGE_W, 0)
	metricTip.markerText:ClearAllPoints()
	metricTip.markerText:SetPoint("BOTTOM", metricTip.marker, "TOP", 0, 1)
	metricTip.markerText:SetText(b.pctile and ("p%.0f"):format(b.pctile) or ("%.0f"):format(pos))

	metricTip.footer:SetText(("score %d · worth %d%% of the grade"):format(
		b.normalized or 0, (b.effectiveWeight or 0) * 100))

	metricTip:ClearAllPoints()
	-- flip to whichever side of the row has room (the panel itself may sit
	-- left of the meter window near the screen edge)
	if (anchor:GetRight() or 0) + metricTip:GetWidth() + 12 <= UIParent:GetWidth() then
		metricTip:SetPoint("LEFT", anchor, "RIGHT", 8, 0)
	else
		metricTip:SetPoint("RIGHT", anchor, "LEFT", -8, 0)
	end
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
	TP.Tooltip:Show(self, "RIGHT", d.title, d.lines)
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

	-- big score, top right; steps left only when the pin close button exists
	frame.bigScore = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	local fontPath, _, fontFlags = frame.bigScore:GetFont()
	frame.bigScore:SetFont(fontPath, 26, fontFlags)
	frame.bigScore:SetPoint("TOPRIGHT", -10, -8)
	frame.bigScore:SetJustifyH("RIGHT")

	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.title:SetPoint("TOPLEFT", 10, -8)
	frame.title:SetPoint("RIGHT", frame.bigScore, "LEFT", -8, 0)
	frame.title:SetJustifyH("LEFT")

	frame.subtitle = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.subtitle:SetPoint("TOPLEFT", 10, -24)
	frame.subtitle:SetPoint("RIGHT", frame.bigScore, "LEFT", -8, 0)
	frame.subtitle:SetJustifyH("LEFT")

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
		rows[j].metricData = nil
	end
end


local PENALTY_HELP = {
	avoidable = "Took more than an equal share of the group's avoidable damage (fire, swirls, void zones). A mechanic everyone eats equally penalizes nobody. Capped at -15.",
	deaths = "Deaths subtract up to -20. Dying late in a fight costs much less than dying early.",
	buffs = "Your class's raid buff wasn't on the whole group when the pull started. Capped at -5.",
	pull = "Started combat before the tank and held the aggro. -5. Tracked on Classic clients; an immediate taunt save forgives it.",
	aggro = "Took a mob off the tank mid-fight. -2.5 each, capped at -8. Tracked on Classic clients.",
	aggroLoss = "Time mobs spent beating on a non-tank while a tank was alive: -0.4 per second, capped at -8. Tracked on Classic clients; taunt swaps to another tank never count.",
}

function Panel:ShowFor(fight, result)
	if not frame then
		createFrame()
	end

	local cr, cg, cb = TP.ClassColor(result.class)
	frame.title:SetText(result.name or "?")
	frame.title:SetTextColor(cr, cg, cb)
	frame.subtitle:SetText(("%s%s · %s"):format(
		fight.wipe and "|cffe64d4dwipe|r · " or "", fight.name or "Fight", result.role))

	local myAwards = TP.Scoring.Awards.Compute(fight)[result.guid]
	local player = fight.players[result.guid]
	local extra
	if player then
		local m = player.metrics or {}
		extra = {
			defensives = m.defensives,
			consumables = m.consumables,
			deathReady = player.deathReadyDefensives,
			isRetail = TP.Compat.IS_RETAIL, -- consumable expectations differ
			-- how much of their healing landed on themselves (Classic data)
			selfShare = (m.healing and m.healing > 0 and m.selfHealing)
				and (m.selfHealing / m.healing) or nil,
			-- target splits (Classic data; boss GUIDs from ENCOUNTER_START)
			addsShare = (fight.isBoss and m.damageToBoss ~= nil and m.damage and m.damage > 0)
				and math.max(0, (m.damage - m.damageToBoss) / m.damage) or nil,
			tankFocus = (m.healingToTanks ~= nil and m.healing and m.healing > 0)
				and (m.healingToTanks / m.healing) or nil,
		}
	end
	local bullets = TP.Scoring.Bullets.ForResult(result, myAwards, extra)

	local y = FIRST_ROW_Y
	for i, bullet in ipairs(bullets) do
		local row = getRow(i, y)
		y = y - ROW_HEIGHT
		row.symbol:SetText(bullet.symbol)
		row.symbol:SetTextColor(bullet.color[1], bullet.color[2], bullet.color[3])
		row.text:SetText(bullet.text)
		row.text:SetTextColor(bullet.color[1], bullet.color[2], bullet.color[3])

		row.metricData = nil
		if bullet.kind == "metric" then
			row.tooltipData = nil
			row.metricData = { b = result.breakdown[bullet.key], key = bullet.key, duration = fight.duration }
		elseif bullet.kind == "penalty" then
			row.tooltipData = { title = bullet.text, lines = { { PENALTY_HELP[bullet.key] or "", 0.95, 0.5, 0.5 } } }
		elseif bullet.kind == "info" then
			local INFO_HELP = {
				adds = "Share of this player's damage that went into non-boss targets. Whether that's right depends on the fight - context, not a judgment.",
				tankFocus = "Share of this healer's output that landed on tanks.",
				defensives = "Major defensive cooldowns used this fight. On Classic this is read from the combat log for everyone; on retail it's reported by the player's own TrueParse. Informational only - not scored.",
				consumables = "Long-duration buffs (flask, food, rune) detected on this player at pull start, self-reported by their TrueParse. Informational only - not scored.",
				deathReady = "At the moment they died, this many major defensive cooldowns were available and unused. Self-reported by their TrueParse. Informational only - not scored.",
			}
			row.tooltipData = { title = bullet.text, lines = {
				{ INFO_HELP[bullet.key] or "Self-reported by this player's TrueParse. Informational only.", 0.8, 0.8, 0.8, true },
			} }
		else
			row.tooltipData = { title = bullet.text, lines = {
				{ TP.Scoring.Awards.DESCRIPTIONS[bullet.text] or "Fight award.", 1, 1, 1 },
			} }
		end
	end

	-- (players without TrueParse are flagged by the red X on their
	-- scorecard row, not an extra bullet here)
	hideRowsFrom(#bullets + 1)

	local gr, gg, gb = TP.Scoring.Grades.ColorForScore(result.score)
	-- parse-shaped results carry no utility metrics; a raw-SETTING fight
	-- that fell back to True (no WCL data) must not get raw decorations
	local rawShaped = TP.Addon.db.profile.scoring.mode == "parse"
		and result.breakdown.interrupts == nil
	local approx = false
	if rawShaped then
		for _, b in pairs(result.breakdown) do
			if b.applicable and not b.absolute and (b.effectiveWeight or 0) > 0 then
				approx = true
			end
		end
	end
	frame.bigScore:SetText((approx and "~" or "") .. TP.Scoring.Grades.ScoreLabel(result.score))
	frame.bigScore:SetTextColor(gr, gg, gb)
	if result.penalty > 0 then
		frame.total:SetText(("Base %.1f · penalties -%.1f"):format(result.base, result.penalty))
		frame.total:SetTextColor(0.95, 0.5, 0.5)
	elseif rawShaped then
		frame.total:SetText("Raw mode - throughput vs top logs only")
		frame.total:SetTextColor(0.4, 0.75, 1)
	else
		frame.total:SetText("No penalties")
		frame.total:SetTextColor(0.6, 0.6, 0.6)
	end

	frame:SetHeight(-y + ROW_HEIGHT + 34)

	anchorPanel()
	frame.close:SetShown(self.pinned)
	frame.bigScore:ClearAllPoints()
	frame.bigScore:SetPoint("TOPRIGHT", self.pinned and -28 or -10, -8)
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
	frame.subtitle:SetText(("%s%s · %d players"):format(
		fight.wipe and "|cffe64d4dwipe|r · " or "", fight.name or "Fight", #results))

	local bullets = TP.Scoring.Bullets.ForGroup(results)
	local y = FIRST_ROW_Y
	for i, bullet in ipairs(bullets) do
		local row = getRow(i, y)
		y = y - ROW_HEIGHT
		row.symbol:SetText(bullet.symbol)
		row.symbol:SetTextColor(bullet.color[1], bullet.color[2], bullet.color[3])
		row.text:SetText(bullet.text)
		row.text:SetTextColor(bullet.color[1], bullet.color[2], bullet.color[3])
		row.tooltipData = bullet.tooltip
		row.metricData = nil
	end
	hideRowsFrom(#bullets + 1)

	local sum = 0
	for _, r in ipairs(results) do
		sum = sum + r.score
	end
	local groupScore = sum / #results
	local gr, gg, gb = TP.Scoring.Grades.ColorForScore(groupScore)
	frame.bigScore:SetText(TP.Scoring.Grades.ScoreLabel(groupScore))
	frame.bigScore:SetTextColor(gr, gg, gb)
	frame.total:SetText(("Average of %d players"):format(#results))
	frame.total:SetTextColor(0.6, 0.6, 0.6)

	frame:SetHeight(-y + ROW_HEIGHT + 34)
	anchorPanel()
	frame.close:SetShown(self.pinned)
	frame.bigScore:ClearAllPoints()
	frame.bigScore:SetPoint("TOPRIGHT", self.pinned and -28 or -10, -8)
	frame:Show()
	self.currentGUID = "GROUP"
end

function Panel:ToggleGroup(fight, results)
	if self.pinned and frame and frame:IsShown() and self.currentGUID == "GROUP" then
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
