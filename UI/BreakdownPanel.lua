-- Breakdown panel: plain-language bullets explaining the grade.
-- Green + earned points, red - cost points (weak metrics and penalties),
-- dim mid-marks for middling contributions, gold + for awards — biggest
-- weight first. Hovering any bullet shows the full numeric derivation.
-- The panel IS the scorecard's tooltip: hovering a row shows it, clicking
-- a row pins it open (so bullets can be explored), close/click unpins.
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
	-- no right anchor: the TIP fits its longest line (fitTipWidth), so
	-- lines never truncate or spill
	metricTip.median:SetJustifyH("LEFT")
	metricTip.median:SetWordWrap(false)

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

	-- tick at your percentile when known, else at the normalized score
	metricTip.gauge:SetShown(wclBacked)
	metricTip.markerText:SetShown(wclBacked)
	if wclBacked then
		local pos = b.pctile or b.normalized or 0
		local frac = math.max(0, math.min(99, pos)) / 100
		metricTip.marker:ClearAllPoints()
		metricTip.marker:SetPoint("CENTER", metricTip.gauge, "LEFT", frac * GAUGE_W, 0)
		metricTip.markerText:ClearAllPoints()
		metricTip.markerText:SetPoint("BOTTOM", metricTip.marker, "TOP", 0, 1)
		metricTip.markerText:SetText(b.pctile and ("p%.0f"):format(b.pctile) or ("%.0f"):format(pos))
	end
	metricTip:SetHeight(wclBacked and 108 or 76)

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
	if not INFO_HELP then
		INFO_HELP = {
			adds = "Share of this player's damage that went into non-boss targets. Whether that's right depends on the fight - context, not a judgment.",
			tankFocus = "Share of this healer's output that landed on tanks.",
			defensives = TP.Compat.IS_RETAIL
				and "Major defensive cooldowns used this fight, reported by the player's own TrueParse. Using 2+ adds a couple of points on top of the base score."
				or "Major defensive cooldowns used this fight, read from the combat log. Using 2+ adds a couple of points on top of the base score.",
			consumables = "Long-duration buffs (flask, food, rune) detected on this player at pull start, self-reported by their TrueParse. Full preparation adds a point.",
			deathReady = "At the moment they died, this many major defensive cooldowns were available and unused. Self-reported by their TrueParse. Dying with 2+ ready costs a few points.",
			lust = "Offensive cooldowns and DPS potions cast inside the 40s Bloodlust/Heroism window. Stacking them there is free extra output - it adds or costs a few points.",
			activity = "Share of the fight spent actually doing things (casting, attacking) - the always-be-casting number. Nudges the score a few points either way; movement-heavy fights read lower for everyone.",
			overheal = "Share of raw healing that landed on already-full health bars. Some overhealing is normal and safe; big numbers on hard fights suggest snipe-heavy targeting. Informational only - not scored.",
			offensives = "Major offensive cooldowns cast this fight, read from the combat log. Informational only - not scored.",
			mitigation = "Share of the fight with an active-mitigation buff up (Shuffle, Shield Block/Barrier, Shield of the Righteous, Savage Defense, Blood Shield). Nudges a tank's score a few points either way.",
			avoidable = "Took at most an even share of the group's avoidable damage while it was actually going out. Clean play earns a few points on top of the base.",
			cdTiming = "Danger windows are the fight's damage spikes; this counts how many had a defensive or healing cooldown active inside them. Timing beats total usage - it adjusts the score a few points either way.",
		}
	end
	return INFO_HELP
end

local PENALTY_HELP = {
	avoidable = "Took more than an equal share of the group's avoidable damage (fire, swirls, void zones). A mechanic everyone eats equally penalizes nobody. Capped at -15.",
	deaths = "Deaths subtract up to -20. Dying late in a fight costs much less than dying early.",
	buffs = "Your class's raid buff wasn't on the whole group when the pull started. Capped at -5.",
	-- threat penalties only exist on captures that HAVE threat data, so no
	-- "on Classic" disclaimers needed - retail never shows these
	pull = "Started combat before the tank and held the aggro. -5. An immediate taunt save forgives it.",
	aggro = "Took a mob off the tank mid-fight. -2.5 each, capped at -8.",
	aggroLoss = "Time mobs spent beating on a non-tank while a tank was alive: -0.4 per second, capped at -8. Taunt swaps to another tank never count.",
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
			-- Bloodlust-window usage (CLEU; nil when no lust this fight)
			lustCasts = m.lustCasts,
			lustPotion = m.lustPotion,
			-- WoWAnalyzer-style basics
			activityPct = m.activityPct,
			overhealPct = m.overhealPct,
			offensiveCDs = m.offensiveCDs,
			mitigationPct = m.mitigationPct,
			-- cooldown timing vs danger windows + death context
			spikeWindows = m.spikeWindows,
			spikeCovered = m.spikeCovered,
			groupSpikeWindows = m.groupSpikeWindows,
			groupSpikeCovered = m.groupSpikeCovered,
			died = (m.deaths or 0) > 0,
		}
	end
	local bullets = TP.Scoring.Bullets.ForResult(result, myAwards, extra)

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
		fight.name or "this fight", fight.wipe and " |cffe64d4d(wipe)|r" or "", pbTag))
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
			row.metricData = { b = result.breakdown[bullet.key], key = bullet.key,
				duration = fight.duration, role = result.role }
		elseif bullet.kind == "penalty" then
			if bullet.key == "deaths" and player and player.deathRecap then
				-- WCL-style death recap: the last hits, right on the bullet,
				-- each with a bar sized by the hit (red = avoidable)
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
				row.tooltipData = { title = bullet.text, lines = lines }
			else
				row.tooltipData = { title = bullet.text, lines = { { PENALTY_HELP[bullet.key] or "", 0.95, 0.5, 0.5 } } }
			end
		elseif bullet.kind == "info" then
			row.tooltipData = { title = bullet.text, lines = {
				{ infoHelp()[bullet.key] or "Self-reported by this player's TrueParse. Informational only.", 0.8, 0.8, 0.8, true },
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
	fitWidth(#bullets)

	-- danger-window timeline: one strip for the whole fight, a band per
	-- damage spike — green if their cooldown met it, red if not. Tanks
	-- see their own spikes, healers the group's.
	local mm = player and player.metrics or {}
	local map = (result.role == "TANK" and mm.spikeMap)
		or (result.role == "HEALER" and mm.groupSpikeMap)
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
		frame.stripLabel:SetText(result.role == "TANK"
			and "your damage spikes \194\183 |cff55cc55defensive met it|r / |cffe64d4dno defensive|r"
			or "group damage spikes \194\183 |cff55cc55cooldown met it|r / |cffe64d4duncovered|r")
		frame.stripLabel:Show()
		y = y - 14
		local w = frame:GetWidth() - 24
		frame.stripTrack:ClearAllPoints()
		frame.stripTrack:SetPoint("TOPLEFT", 12, y)
		frame.stripTrack:SetSize(w, 7)
		frame.stripTrack:Show()
		for i, win in ipairs(map) do
			local band = frame.stripBands[i]
			if not band then
				band = frame:CreateTexture(nil, "OVERLAY")
				band:SetTexture("Interface\\Buttons\\WHITE8X8")
				frame.stripBands[i] = band
			end
			local left = math.min(w - 2, win[1] / fight.duration * w)
			local width = math.max(3, (win[2] - win[1] + 1) / fight.duration * w)
			band:ClearAllPoints()
			band:SetPoint("TOPLEFT", frame.stripTrack, "TOPLEFT", left, 0)
			band:SetSize(math.min(width, w - left), 7)
			if win[3] then
				band:SetVertexColor(0.33, 0.80, 0.33, 1)
			else
				band:SetVertexColor(0.90, 0.30, 0.30, 1)
			end
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
		fight.name or "this fight", fight.wipe and " |cffe64d4d(wipe)|r" or ""))
	if self.groupRunScore then
		frame.runLine:SetText(TP.Scoring.Grades.ColoredScore(self.groupRunScore) .. " avg this run")
	else
		frame.runLine:SetText("")
	end

	local bullets = TP.Scoring.Bullets.ForGroup(results, fight)
	local y = self.groupRunScore and -50 or -37 -- below the header lines
	for i, bullet in ipairs(bullets) do
		local row = getRow(i, y)
		y = y - ROW_HEIGHT
		row.symbol:SetText(bullet.symbol)
		row.symbol:SetTextColor(bullet.color[1], bullet.color[2], bullet.color[3])
		row.text:SetText(bullet.text)
		row.text:SetTextColor(bullet.color[1], bullet.color[2], bullet.color[3])
		if bullet.kind == "metric" and bullet.avg then
			-- same gauge the player bullets get: marker at the group
			-- average, value line from the group total. ForGroup already
			-- says whether the average is WCL-backed (role-filtered,
			-- own-spec percentiles) — share-scored rows carry no gauge.
			row.tooltipData = nil
			row.metricData = {
				b = { value = bullet.total, normalized = bullet.avg, wclBacked = bullet.wclBacked },
				key = bullet.key,
				duration = fight.duration,
				footerText = ("group average %d · %d players"):format(
					bullet.avg, bullet.players or #results),
			}
		else
			row.tooltipData = bullet.tooltip
			row.metricData = nil
		end
	end
	local total = #bullets

	-- Group-vs-group: kill speed against WCL's ranked kills for this
	-- encounter+bracket (the one number that compares GROUPS, not players)
	local speedPct, speedN, speedMedian = TP.Scoring.Engine.KillSpeedPercentile(fight)
	if speedPct then
		total = total + 1
		local row = getRow(total, y)
		y = y - ROW_HEIGHT
		local sr, sg, sb = TP.Scoring.Grades.ColorForScore(speedPct)
		row.symbol:SetText(speedPct >= 50 and "+" or "\194\183")
		row.symbol:SetTextColor(sr, sg, sb)
		row.text:SetText(("Killed faster than %d%% of groups"):format(speedPct))
		row.text:SetTextColor(sr, sg, sb)
		local function mmss(s)
			return ("%d:%02d"):format(math.floor(s / 60), s % 60)
		end
		-- gauge with the marker at the speed percentile
		row.tooltipData = nil
		row.metricData = {
			b = { value = fight.duration or 0, normalized = speedPct, pctile = speedPct },
			key = "Kill speed",
			duration = fight.duration,
			valueText = ("Killed in %s · median ranked kill %s"):format(
				mmss(fight.duration or 0), speedMedian and mmss(speedMedian) or "?"),
			footerText = ("faster than %d%% of %s ranked kills"):format(
				speedPct, TP.FormatNumber(speedN or 0)),
		}
	end

	-- the whole vs the parts: when kill speed and the group's own parses
	-- disagree hard, that gap IS the group-level story
	if speedPct then
		local ga = TP.Scoring.Insights.GroupAnalysis(results, {}, speedPct)
		if ga.executionGap and math.abs(ga.executionGap) >= 20 then
			total = total + 1
			local row = getRow(total, y)
			y = y - ROW_HEIGHT
			local up = ga.executionGap > 0
			row.symbol:SetText(up and "+" or "\194\183")
			local cr2, cg2, cb2 = up and 0.30 or 0.80, up and 0.90 or 0.80, up and 0.40 or 0.55
			row.symbol:SetTextColor(cr2, cg2, cb2)
			row.text:SetText(up
				and ("Execution beat the meters (speed p%d vs output p%d)"):format(ga.killPct + 0.5, ga.outputPct + 0.5)
				or ("Output outran the kill (output p%d, speed p%d)"):format(ga.outputPct + 0.5, ga.killPct + 0.5))
			row.text:SetTextColor(cr2, cg2, cb2)
			row.metricData = nil
			row.tooltipData = { title = "The whole vs the parts", lines = {
				{ up and "The group killed faster than its individual parses predict: target discipline, mechanics, and cooldown timing carried beyond raw output."
					or "Individual parses outran the kill speed: output went somewhere other than winning - time off target, deaths, or damage that didn't matter.", 0.8, 0.8, 0.8, true },
			} }
		end
	end

	-- encounter toughness context: a rough night on a rough boss should
	-- read that way (kill-time medians ranked across the tier)
	local toughness, bosses = nil, nil
	if TP.Scoring.Engine.EncounterToughness then
		toughness, bosses = TP.Scoring.Engine.EncounterToughness(fight)
	end
	if toughness and toughness >= 0.7 then
		total = total + 1
		local row = getRow(total, y)
		y = y - ROW_HEIGHT
		row.symbol:SetText("\194\183")
		row.symbol:SetTextColor(0.8, 0.8, 0.55)
		row.text:SetText(("One of the tier's tougher bosses (top %d%% by kill time)"):format(
			(1 - toughness) * 100 + 1))
		row.text:SetTextColor(0.8, 0.8, 0.55)
		row.metricData = nil
		row.tooltipData = { title = "Encounter toughness", lines = {
			{ ("This boss's median ranked kill is among the longest of the %d bosses with kill-time data at this difficulty. Context, not a judgment."):format(bosses or 0), 0.8, 0.8, 0.8, true },
		} }
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
