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
	-- Aug damage is contribution the buffs ENABLED, not personal output
	amplification = { godly = "Godly amplification", excellent = "Excellent amplification", good = "Good amplification", average = "Average amplification", low = "Low amplification", zero = "No amplification" },
}

local PENALTY_DEFS = {
	{ key = "deaths", label = "Died" },
	{ key = "avoidable", label = "Stood in bad" },
	{ key = "pull", label = "Pulled before the tank" },
	{ key = "aggro", label = "Ripped aggro off the tank" },
	{ key = "aggroLoss", label = "Lost aggro" },
	{ key = "buffs", label = "Raid buff missing at the pull" },
}

-- Signed point tag for bullets whose metric adjusts the score
-- (2026-07-13 redesign): cause and effect on the same line.
local function pts(points)
	if not points or math.abs(points) < 0.5 then
		return ""
	end
	local n = points >= 0 and math.floor(points + 0.5) or -math.floor(-points + 0.5)
	return (" (%+d)"):format(n)
end

-- result: one engine score row; awards: array of award names (optional);
-- extra: optional { defensives = n } peer-reported data (unscored info).
-- Returns array of { kind = "metric"|"penalty"|"award"|"info", key, symbol,
-- color = {r,g,b}, text }
function Bullets.ForResult(result, awards, extra)
	local out = {}
	local ad = result.adjustDetail or {}

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
		if key == "damage" and result.role == "SUPPORT" and b.attribution then
			-- an Aug's "damage" is the contribution their buffs enabled
			phraseKey = "amplification"
		elseif key == "healing" and result.role ~= "HEALER" then
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
				-- tier scales are quantile-anchored per metric (2026-07-13
				-- fight-history audit): kick tiers 1/2/3/4/5+ already match
				-- real kicker quantiles; dispels come in volleys (median
				-- dispeller does 4, p90 does 10) and need their own scale
				local staticScore
				if key == "interrupts" then
					staticScore = (n >= 5 and 96) or (n == 4 and 80)
						or (n == 3 and 60) or (n == 2 and 30) or 10
				else
					staticScore = (n >= 13 and 96) or (n >= 10 and 80)
						or (n >= 7 and 60) or (n >= 4 and 30) or 10
				end
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
			-- the score impact rides the same line, scaled by how much of
			-- this mechanic the fight actually had
			text = text .. pts(b.adjust)
		end
		if b.lowDemand then
			-- floored: the fight barely needed healing, don't scold or gush
			text, symbol, color = "Little healing needed - group stayed topped", MIDDOT, MID
		end
		if b.noInput then
			-- pinned neutral: an Aug's amplification is invisible without
			-- their own TrueParse reporting Ebon Might uptime
			text, symbol, color = "Amplification unmeasured - needs their TrueParse", MIDDOT, MID
		end
		-- sort weight: count metrics use their real adjustment points
		-- ONLY (a nil adjust means the score moved 0 — the pctile
		-- fallback kept zero-impact "Did not interrupt" lines alive
		-- past the impact filter, audit 2026-07-16); base throughput
		-- uses its percentile distance from the middle — a godly parse
		-- IS the score and outranks any +4 nudge
		local sortPts
		if key == "interrupts" or key == "dispels" then
			sortPts = b.adjust or 0
		else
			sortPts = b.adjust or ((b.pctile or b.normalized or 50) - 50) / 5
		end
		out[#out + 1] = { kind = "metric", key = key, symbol = symbol, color = color,
			text = text, points = sortPts }
	end

	-- Staying clean earned points: say so (the negative twin lives in the
	-- penalty bullets as "Stood in bad")
	if (ad.avoidable or 0) > 0 then
		out[#out + 1] = { kind = "info", key = "avoidable", symbol = "+", color = GOOD,
			text = "Stayed out of the bad" .. pts(ad.avoidable), points = ad.avoidable }
	end
	if (ad.rez or 0) > 0 then
		out[#out + 1] = { kind = "info", key = "rez", symbol = "+", color = GOOD,
			text = "Combat-rezzed an ally" .. pts(ad.rez), points = ad.rez }
	end

	-- WoWAnalyzer-style basics (addon-reported; they nudge the score now)
	if extra and extra.activityPct then
		local pct = extra.activityPct
		local tag = pts(ad.activity)
		if pct >= 90 then
			out[#out + 1] = { kind = "info", key = "activity", symbol = "+", color = GOOD,
				text = ("Active %d%% of the fight"):format(pct) .. tag }
		elseif pct >= 75 then
			out[#out + 1] = { kind = "info", key = "activity", symbol = MIDDOT, color = MID,
				text = ("Active %d%% of the fight"):format(pct) .. tag }
		else
			out[#out + 1] = { kind = "info", key = "activity", symbol = "-", color = BAD,
				text = ("Active %d%% of the fight"):format(pct) .. tag }
		end
	end
	if (ad.overheal or 0) ~= 0 and extra and extra.overhealPct then
		local good = ad.overheal > 0
		out[#out + 1] = { kind = "info", key = "overheal",
			symbol = good and "+" or "-", color = good and GOOD or BAD,
			text = (good and "Lean healing - %d%% overheal" or "%d%% overhealing")
				:format(extra.overhealPct) .. pts(ad.overheal) }
	end
	if (ad.overkill or 0) ~= 0 then
		out[#out + 1] = { kind = "info", key = "overkill", symbol = "-", color = BAD,
			text = (extra and extra.overkillPct
				and ("%d%% of damage was overkill"):format(extra.overkillPct)
				or "Overkill-heavy damage") .. pts(ad.overkill) }
	end
	if (ad.manaDry or 0) ~= 0 then
		out[#out + 1] = { kind = "info", key = "manaDry", symbol = "-", color = BAD,
			text = "Ran out of mana mid-fight" .. pts(ad.manaDry) }
	end
	if extra and extra.offensiveCDs and result.role ~= "HEALER" and result.role ~= "TANK" then
		out[#out + 1] = { kind = "info", key = "offensives", symbol = "+", color = GOOD,
			text = extra.offensiveCDs == 1 and "Used an offensive cooldown"
				or ("Used %d offensive cooldowns"):format(extra.offensiveCDs) }
	end
	if extra and extra.mitigationPct and result.role == "TANK" then
		local pct = extra.mitigationPct
		local tag = pts(ad.mitigation)
		if pct >= 70 then
			out[#out + 1] = { kind = "info", key = "mitigation", symbol = "+", color = GOOD,
				text = ("Active mitigation up %d%%"):format(pct) .. tag }
		elseif pct >= 40 then
			out[#out + 1] = { kind = "info", key = "mitigation", symbol = MIDDOT, color = MID,
				text = ("Active mitigation up %d%%"):format(pct) .. tag }
		else
			out[#out + 1] = { kind = "info", key = "mitigation", symbol = "-", color = BAD,
				text = ("Active mitigation up %d%%"):format(pct) .. tag }
		end
	end

	-- Cooldown timing vs the fight's danger windows (Classic CLEU sees
	-- everyone; retail players self-report their own)
	if extra and (extra.spikeWindows or 0) >= 2 and result.role == "TANK" then
		local covered = extra.spikeCovered or 0
		local a = ad.cdTiming or 0
		local sym, col = MIDDOT, MID
		if a > 0 then
			sym, col = "+", GOOD
		elseif a < 0 then
			sym, col = "-", BAD
		end
		out[#out + 1] = { kind = "info", key = "cdTiming", symbol = sym, color = col,
			text = ("Cooldowns met %d of %d damage spikes"):format(covered, extra.spikeWindows) .. pts(a) }
	end
	if extra and (extra.groupSpikeWindows or 0) >= 2 and result.role == "HEALER" then
		local covered = extra.groupSpikeCovered or 0
		local a = ad.cdTiming or 0
		local sym, col = MIDDOT, MID
		if a > 0 then
			sym, col = "+", GOOD
		elseif a < 0 then
			sym, col = "-", BAD
		end
		out[#out + 1] = { kind = "info", key = "cdTiming", symbol = sym, color = col,
			text = ("Cooldowns met %d of %d raid-damage spikes"):format(covered, extra.groupSpikeWindows) .. pts(a) }
	end

	-- Peer-reported facts
	if extra and extra.defensives ~= nil then
		if extra.defensives > 0 then
			out[#out + 1] = { kind = "info", key = "defensives", symbol = "+", color = GOOD,
				text = (extra.defensives == 1 and "Used a defensive cooldown"
					or ("Used %d defensive cooldowns"):format(extra.defensives)) .. pts(ad.defensives) }
		elseif extra.died then
			-- zero is the MEDIAN player's night (2026-07-13 audit) — it
			-- only costs (and only shows) when they died without one
			out[#out + 1] = { kind = "info", key = "defensives", symbol = "-", color = BAD,
				text = "Died without using a defensive" .. pts(ad.deathNoDefensives) }
		end
	end
	if extra and extra.consumables ~= nil then
		if extra.consumables >= 2 then
			-- being prepared is praiseworthy for anyone, anywhere
			out[#out + 1] = { kind = "info", key = "consumables", symbol = "+", color = GOOD,
				text = "Came prepared (flask/food up)" .. pts(ad.prepared) }
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
	-- into the 40s. Scored ±3 via the lust adjustment; the points ride
	-- the line (and a gated adjustment silences it via the impact filter).
	if extra and extra.lustCasts ~= nil and result.role == "DAMAGER" then
		if extra.lustCasts > 0 and (extra.lustPotion or 0) > 0 then
			out[#out + 1] = { kind = "info", key = "lust", symbol = "+", color = GOOD,
				text = "Made the most of Bloodlust (cooldowns + potion)" .. pts(ad.lust) }
		elseif extra.lustCasts > 0 then
			out[#out + 1] = { kind = "info", key = "lust", symbol = "+", color = GOOD,
				text = "Used cooldowns during Bloodlust" .. pts(ad.lust) }
		else
			out[#out + 1] = { kind = "info", key = "lust", symbol = "-", color = BAD,
				text = "Wasted Bloodlust - no cooldowns used" .. pts(ad.lust) }
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

	if extra and extra.deathReady ~= nil and extra.deathReady > 0 then
		out[#out + 1] = { kind = "info", key = "deathReady", symbol = "-", color = BAD,
			text = (extra.deathReady == 1 and "Died with a defensive ready"
				or ("Died with %d defensives ready"):format(extra.deathReady)) .. pts(ad.deathReady) }
	end

	local pd = result.penaltyDetail or {}
	for _, def in ipairs(PENALTY_DEFS) do
		local amount = pd[def.key] or 0
		if amount > 0 then
			out[#out + 1] = { kind = "penalty", key = def.key, symbol = "-", color = BAD,
				text = def.label .. pts(-amount), points = -amount }
		end
	end

	-- Impact-only card (2026-07-15, Josh): a bullet earns its line by
	-- moving the score. Damage and healing anchor the card whatever
	-- their tier (they ARE the base, and the lowDemand/noInput variants
	-- explain a pinned score); everything else needs nonzero points.
	local shown = {}
	for _, b in ipairs(out) do
		local anchor = b.kind == "metric" and (b.key == "damage" or b.key == "healing")
		local p = b.points or tonumber((b.text or ""):match("%(([%+%-]%d+)%)$")) or 0
		if anchor or b.kind == "penalty"
			or (b.kind ~= "metric" and b.kind ~= "info") or p ~= 0 then
			shown[#shown + 1] = b
		end
	end
	return Bullets.SortBestFirst(shown)
end

-- Best to worst: awards, then positives (largest point gain first),
-- neutrals, negatives (worst last). Stable within a band so related
-- lines keep their narrative order. Points parse from the "(+3)"
-- suffix every adjusting bullet already carries.
local SYMBOL_BAND = { ["+"] = 1, [MIDDOT] = 2, ["-"] = 3 }
local function pointsOf(b)
	return b.points or tonumber((b.text or ""):match("%(([%+%-]%d+)%)$")) or 0
end
function Bullets.SortBestFirst(out)
	for i, b in ipairs(out) do
		b._i = i
	end
	table.sort(out, function(a, b)
		local ba = (a.kind == "award") and 0 or (SYMBOL_BAND[a.symbol] or 2)
		local bb = (b.kind == "award") and 0 or (SYMBOL_BAND[b.symbol] or 2)
		if ba ~= bb then
			return ba < bb
		end
		local pa, pb = pointsOf(a), pointsOf(b)
		if pa ~= pb then
			return pa > pb
		end
		return a._i < b._i
	end)
	for _, b in ipairs(out) do
		b._i = nil
	end
	return out
end

local GROUP_PHRASES = {
	damage = { godly = "Godly group damage", excellent = "Excellent group damage", good = "Good group damage", average = "Average group damage", low = "Low group damage" },
	healing = { godly = "Godly healing", excellent = "Excellent healing", good = "Solid healing", average = "Average healing", low = "Healing struggled" },
}

-- Group-level overview from a full results array: WHAT HAPPENED, under
-- the same rules the player rows follow (2026-07-13). Throughput
-- verdicts are role-filtered — a DPS's self-heal percentile must not
-- drag "group healing" to 17 — and demand-aware: a fight with nothing
-- to heal reads as that, not as "healing struggled". Count metrics
-- state facts (volume), never averaged share scores. Pass the fight
-- for totals-based lines (deaths, avoidable pressure).
function Bullets.ForGroup(results, fight)
	-- the raid row's points work like player rows (2026-07-15): each
	-- line carries the AVERAGE adjustment across the group for its key
	local function avgAdj(key, penalty)
		local sum, n = 0, 0
		for _, r in ipairs(results) do
			local v = penalty and -((r.penaltyDetail or {})[key] or 0)
				or ((r.adjustDetail or {})[key] or 0)
			sum = sum + v
			n = n + 1
		end
		if n == 0 then
			return ""
		end
		local avg = sum / n
		if avg >= 0.5 or avg <= -0.5 then
			return (" (%+.0f)"):format(avg)
		end
		return ""
	end
	local out = {}
	local A = TP.Scoring.Weights and TP.Scoring.Weights.adjustments or {}
	local died, avoidable, buffsMissing = 0, 0, false
	local aggroed, tankLostAggro = 0, false

	-- damage: every non-healer, each vs their OWN spec's population
	local dmgSum, dmgN, dmgWcl, dmgTotal = 0, 0, false, 0
	-- healing: healers only, demand floors respected
	local healSum, healN, healWcl, healLowDemand, healTotal = 0, 0, false, true, 0
	local kicks, dispels = 0, 0

	for _, r in ipairs(results) do
		local bd = r.breakdown.damage
		if bd and bd.applicable and r.role ~= "HEALER" then
			dmgSum = dmgSum + (bd.pctile or bd.normalized or 0)
			dmgN = dmgN + 1
			dmgTotal = dmgTotal + (bd.value or 0)
			dmgWcl = dmgWcl or (bd.pctile ~= nil) or (bd.absolute and true or false)
		end
		local bh = r.breakdown.healing
		if bh and bh.applicable and r.role == "HEALER" then
			healSum = healSum + ((bh.lowDemand and bh.normalized) or bh.pctile or bh.normalized or 0)
			healN = healN + 1
			healTotal = healTotal + (bh.value or 0)
			healWcl = healWcl or (bh.pctile ~= nil) or (bh.absolute and true or false)
			if not bh.lowDemand then
				healLowDemand = false
			end
		end
		local bi = r.breakdown.interrupts
		kicks = kicks + ((bi and bi.value) or 0)
		local bdisp = r.breakdown.dispels
		dispels = dispels + ((bdisp and bdisp.value) or 0)

		local pd = r.penaltyDetail or {}
		if (pd.deaths or 0) > 0 then died = died + 1 end
		if (pd.avoidable or 0) > 0 then avoidable = avoidable + 1 end
		if (pd.buffs or 0) > 0 then buffsMissing = true end
		if (pd.aggro or 0) > 0 or (pd.pull or 0) > 0 then aggroed = aggroed + 1 end
		if (pd.aggroLoss or 0) > 0 then tankLostAggro = true end
	end

	if dmgN > 0 then
		local avg = dmgSum / dmgN
		local tier, symbol = tierOf(avg)
		out[#out + 1] = {
			kind = "metric", key = "damage", symbol = symbol, color = tierColor(avg),
			text = GROUP_PHRASES.damage[tier],
			avg = avg, total = dmgTotal, players = dmgN, wclBacked = dmgWcl or nil,
			tooltip = { title = TP.METRIC_LABELS.damage,
				lines = { { ("Average percentile of the %d damage-role players, each vs their own spec's population."):format(dmgN), 1, 1, 1 } } },
		}
	end
	if healN > 0 then
		if healLowDemand then
			out[#out + 1] = {
				kind = "metric", key = "healing", symbol = MIDDOT, color = MID,
				text = "Little healing needed - group stayed topped",
				players = healN,
				tooltip = { title = TP.METRIC_LABELS.healing,
					lines = { { "Incoming damage never demanded real healing output; healers are not graded on a fight with nothing to heal.", 1, 1, 1 } } },
			}
		else
			local avg = healSum / healN
			local tier, symbol = tierOf(avg)
			out[#out + 1] = {
				kind = "metric", key = "healing", symbol = symbol, color = tierColor(avg),
				text = GROUP_PHRASES.healing[tier],
				avg = avg, total = healTotal, players = healN, wclBacked = healWcl or nil,
				tooltip = { title = TP.METRIC_LABELS.healing,
					lines = { { ("Average percentile of the %d healer(s), each vs their own spec's population."):format(healN), 1, 1, 1 } } },
			}
		end
	end
	-- count metrics: coverage when opportunity data exists (self-curating
	-- kickable list), plain volume otherwise
	local opps = fight and fight.totals and fight.totals.kickOpportunities
	if opps and opps > 0 then
		local landed = fight.totals.kicksLanded or 0
		local coverage = landed / opps
		local sym, col = MIDDOT, MID
		if coverage >= 0.9 then
			sym, col = "+", GOOD
		elseif coverage < 0.6 then
			sym, col = "-", BAD
		end
		out[#out + 1] = { kind = "metric", key = "interrupts", symbol = sym, color = col,
			text = ("Kicked %d of %d interruptible casts"):format(landed, opps) .. avgAdj("kicks"),
			tooltip = { title = TP.METRIC_LABELS.interrupts,
				lines = { { "Opportunities = casts of spells this addon has ever seen interrupted (the list teaches itself). Casts that got through hit somebody.", 1, 1, 1 } } } }
	elseif kicks > 0 then
		local heavy = kicks >= (A.kicksFullIntensity or 6)
		-- no opportunity data: say WHY the "kicked X of Y" stat is absent
		-- instead of a generic shrug — the reason differs by client
		local why
		if TP.Compat and TP.Compat.IS_RETAIL then
			why = "Blizzard hides enemy casts on retail, so interruptible casts can't be counted - landed kicks are all any addon can see here."
		else
			why = "Interruptible-cast counting is still learning this content: every spell anyone kicks is tracked forever after, then this reads \"kicked X of Y casts\"."
		end
		out[#out + 1] = { kind = "metric", key = "interrupts",
			symbol = heavy and "+" or MIDDOT, color = heavy and GOOD or MID,
			text = (kicks == 1 and "1 interrupt landed" or ("%d interrupts landed"):format(kicks)) .. avgAdj("kicks"),
			tooltip = { title = TP.METRIC_LABELS.interrupts,
				lines = {
					{ "Group total. Hover a player's kick bullet for their share.", 1, 1, 1 },
					{ why, 0.8, 0.8, 0.8, true },
				} } }
	end
	if dispels > 0 then
		local heavy = dispels >= (A.dispelsFullIntensity or 8)
		out[#out + 1] = { kind = "metric", key = "dispels",
			symbol = heavy and "+" or MIDDOT, color = heavy and GOOD or MID,
			text = (dispels == 1 and "1 dispel" or ("%d dispels"):format(dispels)) .. avgAdj("dispels"),
			tooltip = { title = TP.METRIC_LABELS.dispels,
				lines = { { "Group total. Hover a player's dispel bullet for their share.", 1, 1, 1 } } } }
	end

	-- Bloodlust discipline, the group view: how many DPS actually stacked
	-- cooldowns (and potions) into the window. The per-player lust points
	-- already exist; this line rolls them up so the raid argument about
	-- "save it or send it" gets a number. Classic CLEU sees everyone;
	-- retail fights have no lustCasts and the line stays absent.
	if fight and fight.players then
		local dps, aligned, potioned = 0, 0, 0
		for _, p in pairs(fight.players) do
			local m = p.metrics or {}
			local role = TP.Scoring.Capabilities.EffectiveRole(p.role, p.specIconID, p.specID)
			-- dead before the window opened = excused, same as the engine
			if role == "DAMAGER" and m.lustCasts ~= nil
				and not (fight.lustAt and p.deathTime and p.deathTime <= fight.lustAt) then
				dps = dps + 1
				if m.lustCasts > 0 then
					aligned = aligned + 1
				end
				if (m.lustPotion or 0) > 0 then
					potioned = potioned + 1
				end
			end
		end
		if dps >= 2 then
			local ratio = aligned / dps
			local sym, col = MIDDOT, MID
			if ratio >= 0.8 then
				sym, col = "+", GOOD
			elseif ratio < 0.5 then
				sym, col = "-", BAD
			end
			local potPart = potioned > 0 and (", %d potioned"):format(potioned) or ", nobody potioned"
			out[#out + 1] = { kind = "metric", key = "lust", symbol = sym, color = col,
				text = ("Bloodlust: %d of %d DPS stacked cooldowns%s"):format(aligned, dps, potPart) .. avgAdj("lust"),
				tooltip = { title = "Bloodlust discipline",
					lines = {
						{ "Those 40 seconds are the fight's damage jackpot: offensive cooldowns and potions multiply inside them. Hover a DPS row's Bloodlust bullet for their part.", 1, 1, 1 },
						{ "Players dead before the lust went out are excused.", 0.8, 0.8, 0.8, true },
					} } }
		end
	end

	-- Healer-count advisor (raid kills): compare the comp against what
	-- ranked kills of this boss actually field. Advice, never points -
	-- comp is a group choice, and progression comps 3-heal on purpose.
	-- Only speaks when the group ran HEAVIER than the field's dominant
	-- comp (deaths already argue the other direction) and the raid sizes
	-- are comparable (flex guard).
	if fight and fight.isBoss and not fight.wipe and fight.players then
		local field, fieldSize = TP.Scoring.Engine.HealerCountField(fight)
		if field and field.mode and (field.modePct or 0) >= 50 then
			local healers, size = 0, 0
			for _, p in pairs(fight.players) do
				size = size + 1
				if TP.Scoring.Capabilities.EffectiveRole(p.role, p.specIconID, p.specID) == "HEALER" then
					healers = healers + 1
				end
			end
			if healers > field.mode and fieldSize and math.abs(size - fieldSize) <= 2 then
				out[#out + 1] = { kind = "info", key = "healerComp", symbol = MIDDOT, color = MID,
					text = ("Ran %d healers - ranked kills mostly run %d"):format(healers, field.mode),
					tooltip = { title = "Healer count",
						lines = {
							{ ("%d%% of ranked kills of this boss bring %d healer(s); the field average is %.1f. Every healer swapped to DPS shortens the fight - and the healing parses split fewer ways."):format(field.modePct, field.mode, field.avg or field.mode), 1, 1, 1 },
							{ "Advice, not a grade: progression comps run extra healers on purpose.", 0.8, 0.8, 0.8, true },
						} } }
			end
		end
	end

	-- what the fight cost, in facts
	if fight and fight.isBoss and (fight.totals and fight.totals.deaths) == 0 and not fight.wipe then
		out[#out + 1] = { kind = "info", key = "deaths", symbol = "+", color = GOOD,
			text = "Nobody died" }
	elseif died > 0 then
		out[#out + 1] = { kind = "penalty", key = "deaths", symbol = "-", color = BAD,
			text = (died == 1 and "1 player died" or ("%d players died"):format(died)) .. avgAdj("deaths", true) }
	end
	if avoidable > 0 then
		local pressure = ""
		if fight and fight.totals and (fight.totals.damageTaken or 0) > 0 then
			pressure = (" (%d%% avoidable)"):format(
				(fight.totals.avoidableTaken or 0) / fight.totals.damageTaken * 100 + 0.5)
		end
		out[#out + 1] = { kind = "penalty", key = "avoidable", symbol = "-", color = BAD,
			text = (avoidable == 1 and "1 player stood in bad" or ("%d players stood in bad"):format(avoidable)) .. pressure }
	end
	-- one story, not two: a non-tank holding aggro IS the tank losing
	-- it. Prefer the line that names culprits; the tank-side line only
	-- shows when nobody specific got charged
	if aggroed > 0 then
		out[#out + 1] = { kind = "penalty", key = "aggro", symbol = "-", color = BAD,
			text = aggroed == 1 and "1 player pulled aggro" or ("%d players pulled aggro"):format(aggroed) }
	elseif tankLostAggro then
		out[#out + 1] = { kind = "penalty", key = "aggroLoss", symbol = "-", color = BAD,
			text = "Aggro slipped off the tank" }
	end
	if buffsMissing then
		out[#out + 1] = { kind = "penalty", key = "buffs", symbol = "-", color = BAD,
			text = "Raid buffs missing at the pull" .. avgAdj("buffs", true) }
	end

	return Bullets.SortBestFirst(out)
end
