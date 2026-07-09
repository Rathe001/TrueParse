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

local function rowEnter(self)
	local d = self.tooltipData
	if not d then
		return
	end
	GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
	GameTooltip:SetText(d.title)
	for _, line in ipairs(d.lines) do
		GameTooltip:AddLine(line[1], line[2], line[3], line[4], true)
	end
	GameTooltip:Show()
end

local function rowLeave()
	GameTooltip:Hide()
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

local function createFrame()
	frame = CreateFrame("Frame", "TrueParseBreakdown", UIParent, "BackdropTemplate")
	frame:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	frame:SetBackdropColor(0, 0, 0, 0.75)
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
	end
end

-- Hover derivation: one short line per fact. What you did, the 0-100 score
-- (with its sources when there are two), and what it added to the grade.
local function buildMetricTooltip(key, b, duration)
	local label = TP.METRIC_LABELS[key] or key
	local lines = {}
	local value = b.value or 0

	if COUNT_METRICS[key] then
		lines[#lines + 1] = { ("%d this fight"):format(value), 1, 1, 1 }
	elseif PERCENT_METRICS[key] then
		lines[#lines + 1] = { ("Up %d%% of the fight"):format(value * 100 + 0.5), 1, 1, 1 }
	elseif duration and duration > 0 then
		lines[#lines + 1] = { ("%s · %s per second"):format(
			TP.FormatNumber(value), TP.FormatNumber(value / duration)), 1, 1, 1 }
	else
		lines[#lines + 1] = { TP.FormatNumber(value), 1, 1, 1 }
	end

	lines[#lines + 1] = { ("Score %d of 100"):format(b.normalized or 0), 1, 0.82, 0.2 }
	-- Only itemize the sources when the score blends two of them
	if b.absolute and b.relative then
		lines[#lines + 1] = { ("%d vs top parses for your spec"):format(b.absolute), 0.4, 0.75, 1 }
		lines[#lines + 1] = { ("%d vs this group"):format(b.relative), 0.8, 0.8, 0.8 }
	elseif b.absolute then
		lines[#lines + 1] = { "Measured against top parses for your spec", 0.4, 0.75, 1 }
	elseif b.relative then
		lines[#lines + 1] = { "Measured against this group", 0.8, 0.8, 0.8 }
	end
	lines[#lines + 1] = { ("Added %.0f of a possible %.0f points"):format(
		b.contribution or 0, (b.effectiveWeight or 0) * 100), 0.7, 0.7, 0.7 }

	return { title = label, lines = lines }
end

local PENALTY_HELP = {
	avoidable = "You took more than an equal share of the group's avoidable damage. Capped at -15.",
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
		extra = {
			defensives = player.metrics and player.metrics.defensives,
			consumables = player.metrics and player.metrics.consumables,
			deathReady = player.deathReadyDefensives,
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

		if bullet.kind == "metric" then
			row.tooltipData = buildMetricTooltip(bullet.key, result.breakdown[bullet.key], fight.duration)
		elseif bullet.kind == "penalty" then
			row.tooltipData = { title = bullet.text, lines = { { PENALTY_HELP[bullet.key] or "", 0.95, 0.5, 0.5 } } }
		elseif bullet.kind == "info" then
			local INFO_HELP = {
				defensives = "Major defensive cooldowns used this fight, reported by this player's own TrueParse (other players' cooldowns aren't visible to addons). Informational only - not scored.",
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

	local total = #bullets
	if player and not (player.hasAddon or player.isLocalPlayer) then
		total = total + 1
		local row = getRow(total, y)
		y = y - ROW_HEIGHT
		row.symbol:SetText("\194\183")
		row.symbol:SetTextColor(0.5, 0.5, 0.5)
		row.text:SetText("Not running TrueParse - no peer-reported data")
		row.text:SetTextColor(0.5, 0.5, 0.5)
		row.tooltipData = { title = "Not running TrueParse", lines = {
			{ "Defensives used, consumables at the pull, and death readiness are reported by each player's own TrueParse over a hidden addon channel. This player isn't running it, so those lines are missing. The grade itself is unaffected.", 0.8, 0.8, 0.8, true },
		} }
	end
	hideRowsFrom(total + 1)

	local gr, gg, gb = TP.Scoring.Grades.ColorForScore(result.score)
	local approx = false
	if TP.Addon.db.profile.scoring.mode == "parse" then
		for _, b in pairs(result.breakdown) do
			if b.applicable and not b.absolute then
				approx = true
			end
		end
	end
	frame.bigScore:SetText((approx and "~" or "") .. ("%.0f"):format(result.score))
	frame.bigScore:SetTextColor(gr, gg, gb)
	if result.penalty > 0 then
		frame.total:SetText(("Base %.1f · penalties -%.1f"):format(result.base, result.penalty))
		frame.total:SetTextColor(0.95, 0.5, 0.5)
	elseif TP.Addon.db.profile.scoring.mode == "parse" then
		frame.total:SetText("Raw mode - throughput vs top logs only")
		frame.total:SetTextColor(0.4, 0.75, 1)
	else
		frame.total:SetText("No penalties")
		frame.total:SetTextColor(0.6, 0.6, 0.6)
	end

	frame:SetHeight(-y + ROW_HEIGHT + 34)

	local anchor = _G.TrueParseWindow
	frame:ClearAllPoints()
	if anchor then
		frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
	else
		frame:SetPoint("CENTER")
	end
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
	end
	hideRowsFrom(#bullets + 1)

	local sum = 0
	for _, r in ipairs(results) do
		sum = sum + r.score
	end
	local groupScore = sum / #results
	local gr, gg, gb = TP.Scoring.Grades.ColorForScore(groupScore)
	frame.bigScore:SetText(("%.0f"):format(groupScore))
	frame.bigScore:SetTextColor(gr, gg, gb)
	frame.total:SetText(("Average of %d players"):format(#results))
	frame.total:SetTextColor(0.6, 0.6, 0.6)

	frame:SetHeight(-y + ROW_HEIGHT + 34)
	local anchor = _G.TrueParseWindow
	frame:ClearAllPoints()
	if anchor then
		frame:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 6, 0)
	else
		frame:SetPoint("CENTER")
	end
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
