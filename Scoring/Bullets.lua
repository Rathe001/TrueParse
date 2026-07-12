-- Plain-language bullets explaining a score: green + for what earned it,
-- red - for what cost it, a dim middle-dot for middling. Human phrases only;
-- the numbers live in hover tooltips.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Bullets = {}
TP.Scoring.Bullets = Bullets

local GOOD = { 0.30, 0.90, 0.40 }
local BAD = { 0.95, 0.35, 0.35 }
local MID = { 0.80, 0.80, 0.55 }
local GOLD = { 1.00, 0.82, 0.20 }
local MIDDOT = "\194\183"

-- Five tiers matching the parse-bracket colors players already read:
-- grey = low, green = average, blue = good, purple = excellent,
-- orange = godly. Bullet text and color always agree with the gauge.
local function tierOf(score)
	if score >= 95 then
		return "godly", "+"
	elseif score >= 75 then
		return "excellent", "+"
	elseif score >= 50 then
		return "good", "+"
	elseif score >= 25 then
		return "average", MIDDOT
	end
	return "low", "-"
end

local function tierColor(score)
	local r, g, b = TP.Scoring.Grades.ColorForScore(score)
	return { r, g, b }
end

local PHRASES = {
	damage = { godly = "Godly damage", excellent = "Excellent damage", good = "Good damage", average = "Average damage", low = "Low damage", zero = "Did no damage" },
	healing = { godly = "Godly healing", excellent = "Excellent healing", good = "Good healing", average = "Average healing", low = "Low healing", zero = "No healing" },
	healingOff = { godly = "Godly off-healing", excellent = "Excellent off-healing", good = "Good off-healing", average = "Some off-healing", low = "Little off-healing", zero = "No off-healing" },
	selfSustain = { godly = "Godly self-sustain", excellent = "Excellent self-sustain", good = "Good self-sustain", average = "Average self-sustain", low = "Little self-sustain", zero = "No self-healing" },
	damageTaken = { godly = "Soaked everything", excellent = "Excellent soaking", good = "Solid soaking", average = "Average soaking", low = "Light soaking", zero = "Took no hits" },
	interrupts = { godly = "Godly interrupting", excellent = "Excellent interrupting", good = "Good interrupting", average = "Some interrupts", low = "Too few interrupts", zero = "Did not interrupt" },
	dispels = { godly = "Godly dispelling", excellent = "Excellent dispelling", good = "Good dispelling", average = "Some dispels", low = "Too few dispels", zero = "Did not dispel" },
	buffUptime = { godly = "Godly buff uptime", excellent = "Excellent buff uptime", good = "Good buff uptime", average = "Average buff uptime", low = "Low buff uptime", zero = "Buffs never up" },
}

local PENALTY_DEFS = {
	{ key = "deaths", label = "Died" },
	{ key = "avoidable", label = "Stood in bad" },
	{ key = "pull", label = "Pulled before the tank" },
	{ key = "aggro", label = "Ripped aggro off the tank" },
	{ key = "aggroLoss", label = "Lost aggro" },
	{ key = "buffs", label = "Raid buff missing at the pull" },
}

-- result: one engine score row; awards: array of award names (optional);
-- extra: optional { defensives = n } peer-reported data (unscored info).
-- Returns array of { kind = "metric"|"penalty"|"award"|"info", key, symbol,
-- color = {r,g,b}, text }
function Bullets.ForResult(result, awards, extra)
	local out = {}

	-- Trophies first
	for _, award in ipairs(awards or {}) do
		out[#out + 1] = { kind = "award", symbol = TP.STAR, color = GOLD, text = award }
	end

	local metrics = {}
	for key, b in pairs(result.breakdown) do
		if b.applicable then
			metrics[#metrics + 1] = { key = key, b = b }
		end
	end
	table.sort(metrics, function(x, y)
		return (x.b.effectiveWeight or 0) > (y.b.effectiveWeight or 0)
	end)

	for _, m in ipairs(metrics) do
		local b, key = m.b, m.key
		-- tier on the population PERCENTILE when curve-scored: the gauge
		-- marker sits at the percentile, and the True transform (floor 30 +
		-- 0.7x) would call a green p37 "Good" while the gauge shows green
		local score = b.pctile or b.normalized or 0
		local tier, symbol = tierOf(score)
		local color = tierColor(score)
		local phraseKey = key
		if key == "healing" and result.role ~= "HEALER" then
			-- mostly-self healing is sustain, not off-healing: different
			-- compliment, different implication for the group
			phraseKey = (extra and extra.selfShare and extra.selfShare >= 0.8)
				and "selfSustain" or "healingOff"
		end
		local phrases = PHRASES[phraseKey] or PHRASES.damage
		local text = phrases[tier]
		-- a zero count always says so plainly, whatever the smoothed score
		-- ("Great interrupting" on 0 kicks was a real bug)
		if (b.value or 0) == 0 and phrases.zero then
			text = phrases.zero
		end
		-- Count metrics tier on the COUNT, statically: the smoothed
		-- fair-share score painted "Did not interrupt" as a blue + (zero
		-- kicks score 55 so the GRADE stays fair; the bullet shouldn't).
		-- 0 = plain grey statement, 1 grey, 2 green, 3 blue, 4 purple,
		-- 5+ orange.
		if key == "interrupts" or key == "dispels" then
			local n = b.value or 0
			if n == 0 then
				text, symbol, color = phrases.zero, MIDDOT, MID
			else
				local staticScore = (n >= 5 and 96) or (n == 4 and 80)
					or (n == 3 and 60) or (n == 2 and 30) or 10
				if staticScore < 60 and (b.normalized or 0) >= 90 then
					-- a low count on a fight that barely offered any: the
					-- share score says they covered it ("Too few dispels"
					-- next to a gauge at 100 scolded the only dispeller)
					text = (key == "interrupts") and "Did their share of kicks"
						or "Did their share of dispels"
					symbol, color = "+", tierColor(45)
				else
					local sTier, sSymbol = tierOf(staticScore)
					text, symbol, color = phrases[sTier], sSymbol, tierColor(staticScore)
				end
			end
		end
		if b.lowDemand then
			-- floored: the fight barely needed healing, don't scold or gush
			text, symbol, color = "Little healing needed - group stayed topped", MIDDOT, MID
		end
		out[#out + 1] = { kind = "metric", key = key, symbol = symbol, color = color, text = text }
	end

	-- WoWAnalyzer-style basics: informational, never scored
	if extra and extra.activityPct then
		local pct = extra.activityPct
		if pct >= 90 then
			out[#out + 1] = { kind = "info", key = "activity", symbol = "+", color = GOOD,
				text = ("Active %d%% of the fight"):format(pct) }
		elseif pct >= 75 then
			out[#out + 1] = { kind = "info", key = "activity", symbol = MIDDOT, color = MID,
				text = ("Active %d%% of the fight"):format(pct) }
		else
			out[#out + 1] = { kind = "info", key = "activity", symbol = "-", color = BAD,
				text = ("Active %d%% of the fight"):format(pct) }
		end
	end
	if extra and extra.overhealPct and result.role == "HEALER" then
		out[#out + 1] = { kind = "info", key = "overheal", symbol = MIDDOT, color = MID,
			text = ("%d%% overhealing"):format(extra.overhealPct) }
	end
	if extra and extra.offensiveCDs and result.role ~= "HEALER" and result.role ~= "TANK" then
		out[#out + 1] = { kind = "info", key = "offensives", symbol = "+", color = GOOD,
			text = extra.offensiveCDs == 1 and "Used an offensive cooldown"
				or ("Used %d offensive cooldowns"):format(extra.offensiveCDs) }
	end
	if extra and extra.mitigationPct and result.role == "TANK" then
		local pct = extra.mitigationPct
		if pct >= 70 then
			out[#out + 1] = { kind = "info", key = "mitigation", symbol = "+", color = GOOD,
				text = ("Active mitigation up %d%%"):format(pct) }
		elseif pct >= 40 then
			out[#out + 1] = { kind = "info", key = "mitigation", symbol = MIDDOT, color = MID,
				text = ("Active mitigation up %d%%"):format(pct) }
		else
			out[#out + 1] = { kind = "info", key = "mitigation", symbol = "-", color = BAD,
				text = ("Active mitigation up %d%%"):format(pct) }
		end
	end

	-- Peer-reported facts: informational, never scored
	if extra and extra.defensives ~= nil then
		if extra.defensives > 0 then
			out[#out + 1] = { kind = "info", key = "defensives", symbol = "+", color = GOOD,
				text = extra.defensives == 1 and "Used a defensive cooldown" or ("Used %d defensive cooldowns"):format(extra.defensives) }
		else
			out[#out + 1] = { kind = "info", key = "defensives", symbol = MIDDOT, color = MID,
				text = "No defensive cooldowns used" }
		end
	end
	if extra and extra.consumables ~= nil then
		if extra.consumables >= 2 then
			-- being prepared is praiseworthy for anyone, anywhere
			out[#out + 1] = { kind = "info", key = "consumables", symbol = "+", color = GOOD,
				text = "Came prepared (flask/food up)" }
		elseif not extra.isRetail
			and (result.role == "DAMAGER" or result.role == "SUPPORT") then
			-- ...but the EXPECTATION is Classic DPS culture only: tanks and
			-- healers were never expected to burn gold at the pull, and
			-- retail killed the pre-pot entirely
			if extra.consumables == 1 then
				out[#out + 1] = { kind = "info", key = "consumables", symbol = MIDDOT, color = MID,
					text = "Partially prepared" }
			else
				out[#out + 1] = { kind = "info", key = "consumables", symbol = MIDDOT, color = MID,
					text = "No consumables at the pull" }
			end
		end
	end
	-- Bloodlust window (CLEU): DPS should stack cooldowns and a potion
	-- into the 40s. Informational only - crediting or calling it out,
	-- never scoring it.
	if extra and extra.lustCasts ~= nil and result.role == "DAMAGER" then
		if extra.lustCasts > 0 and (extra.lustPotion or 0) > 0 then
			out[#out + 1] = { kind = "info", key = "lust", symbol = "+", color = GOOD,
				text = "Made the most of Bloodlust (cooldowns + potion)" }
		elseif extra.lustCasts > 0 then
			out[#out + 1] = { kind = "info", key = "lust", symbol = "+", color = GOOD,
				text = "Used cooldowns during Bloodlust" }
		else
			out[#out + 1] = { kind = "info", key = "lust", symbol = "-", color = BAD,
				text = "Wasted Bloodlust - no cooldowns used" }
		end
	end
	-- Target-split facts (CLEU, Classic): neutral context, not judgments —
	-- whether 62% into adds was right depends on the fight
	if extra and extra.addsShare and extra.addsShare >= 0.1 and result.role ~= "HEALER" then
		out[#out + 1] = { kind = "info", key = "adds", symbol = MIDDOT, color = MID,
			text = ("Put %d%% of damage into adds"):format(extra.addsShare * 100 + 0.5) }
	end
	if extra and extra.tankFocus and result.role == "HEALER" then
		out[#out + 1] = { kind = "info", key = "tankFocus", symbol = MIDDOT, color = MID,
			text = ("Healing focus: %d%% on tanks"):format(extra.tankFocus * 100 + 0.5) }
	end

	if extra and extra.deathReady ~= nil then
		if extra.deathReady > 0 then
			out[#out + 1] = { kind = "info", key = "deathReady", symbol = "-", color = BAD,
				text = extra.deathReady == 1 and "Died with a defensive ready"
					or ("Died with %d defensives ready"):format(extra.deathReady) }
		else
			out[#out + 1] = { kind = "info", key = "deathReady", symbol = MIDDOT, color = MID,
				text = "Died with everything on cooldown" }
		end
	end

	local pd = result.penaltyDetail or {}
	for _, def in ipairs(PENALTY_DEFS) do
		local amount = pd[def.key] or 0
		if amount > 0 then
			out[#out + 1] = { kind = "penalty", key = def.key, symbol = "-", color = BAD, text = def.label }
		end
	end

	return out
end

local GROUP_PHRASES = {
	damage = { godly = "Godly group damage", excellent = "Excellent group damage", good = "Good group damage", average = "Average group damage", low = "Low group damage" },
	healing = { godly = "Godly group healing", excellent = "Excellent group healing", good = "Good group healing", average = "Average group healing", low = "Healing struggled" },
	interrupts = { godly = "Godly kick coverage", excellent = "Kicks were covered", good = "Good interrupting", average = "Interrupts were spotty", low = "Not enough interrupting", zero = "Nobody interrupted" },
	dispels = { godly = "Godly dispel coverage", excellent = "Dispels were handled", good = "Good dispelling", average = "Dispels were spotty", low = "Too few dispels", zero = "Nobody dispelled" },
}
local GROUP_ORDER = { "damage", "healing", "interrupts", "dispels" }

-- Group-level bullets from a full results array. Each carries its own
-- tooltip = { title, lines } since the caller has no per-player breakdown.
function Bullets.ForGroup(results)
	local out = {}
	local sums, counts, totals = {}, {}, {}
	local died, avoidable, buffsMissing = 0, 0, false
	local aggroed, tankLostAggro = 0, false

	for _, r in ipairs(results) do
		for key, b in pairs(r.breakdown) do
			if b.applicable and GROUP_PHRASES[key] then
				-- same percentile-first basis as the individual bullets
				sums[key] = (sums[key] or 0) + (b.pctile or b.normalized or 0)
				counts[key] = (counts[key] or 0) + 1
				totals[key] = (totals[key] or 0) + (b.value or 0)
			end
		end
		local pd = r.penaltyDetail or {}
		if (pd.deaths or 0) > 0 then died = died + 1 end
		if (pd.avoidable or 0) > 0 then avoidable = avoidable + 1 end
		if (pd.buffs or 0) > 0 then buffsMissing = true end
		if (pd.aggro or 0) > 0 or (pd.pull or 0) > 0 then aggroed = aggroed + 1 end
		if (pd.aggroLoss or 0) > 0 then tankLostAggro = true end
	end

	for _, key in ipairs(GROUP_ORDER) do
		if counts[key] and counts[key] > 0 then
			local avg = sums[key] / counts[key]
			local tier, symbol = tierOf(avg)
			local color = tierColor(avg)
			local phrases = GROUP_PHRASES[key]
			local text = phrases[tier]
			if (totals[key] or 0) == 0 and phrases.zero then
				text = phrases.zero
			end
			out[#out + 1] = {
				kind = "metric", key = key, symbol = symbol, color = color, text = text,
				-- gauge fuel for the group tooltip: marker at the group
				-- average, value line from the group total
				avg = avg, total = totals[key] or 0, players = counts[key],
				tooltip = {
					title = TP.METRIC_LABELS[key] or key,
					lines = {
						{ ("Group average %.0f/100 across %d players."):format(avg, counts[key]), 1, 1, 1 },
					},
				},
			}
		end
	end

	if died > 0 then
		out[#out + 1] = { kind = "penalty", key = "deaths", symbol = "-", color = BAD,
			text = died == 1 and "1 player died" or ("%d players died"):format(died) }
	end
	if avoidable > 0 then
		out[#out + 1] = { kind = "penalty", key = "avoidable", symbol = "-", color = BAD,
			text = avoidable == 1 and "1 player stood in bad" or ("%d players stood in bad"):format(avoidable) }
	end
	if aggroed > 0 then
		out[#out + 1] = { kind = "penalty", key = "aggro", symbol = "-", color = BAD,
			text = aggroed == 1 and "1 player pulled aggro" or ("%d players pulled aggro"):format(aggroed) }
	end
	if tankLostAggro then
		out[#out + 1] = { kind = "penalty", key = "aggroLoss", symbol = "-", color = BAD,
			text = "Aggro slipped off the tank" }
	end
	if buffsMissing then
		out[#out + 1] = { kind = "penalty", key = "buffs", symbol = "-", color = BAD,
			text = "Raid buffs missing at the pull" }
	end

	return out
end
