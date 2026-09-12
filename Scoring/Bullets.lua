-- Plain-language bullets explaining the group's fight: green + for what
-- went well, red - for what cost it, a dim middle-dot for middling. Human
-- phrases only; the numbers live in hover tooltips.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Bullets = {}
TP.Scoring.Bullets = Bullets

local GOOD = { 0.30, 0.90, 0.40 }
local BAD = { 0.95, 0.35, 0.35 }
local MID = { 0.80, 0.80, 0.55 }
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
	-- ...and whether ANY of those floors was "they covered real intake"
	-- rather than "the fight was quiet" — the group row has to say so too
	local healDemandMet = false
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
			elseif bh.demandMet then
				healDemandMet = true
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
				lines = { { ("Average percentile of %d damage players, each vs their own spec."):format(dmgN), 1, 1, 1 } } },
		}
	end
	if healN > 0 then
		if healLowDemand then
			out[#out + 1] = {
				kind = "metric", key = "healing", symbol = MIDDOT, color = MID,
				text = healDemandMet
					and "Covered the group's damage - too small a fight to rank"
					or "Little healing needed - group stayed topped",
				players = healN,
				demandMet = healDemandMet or nil,
				tooltip = { title = TP.METRIC_LABELS.healing,
					lines = { { healDemandMet
						and "Healing kept pace with the group's damage taken. The ranked field for this spec heals raid-sized volumes, so a 5-man cannot place against it - the score is pinned neutral rather than graded."
						or "Nothing to heal, nothing to grade.", 1, 1, 1 } } },
			}
		else
			local avg = healSum / healN
			local tier, symbol = tierOf(avg)
			out[#out + 1] = {
				kind = "metric", key = "healing", symbol = symbol, color = tierColor(avg),
				text = GROUP_PHRASES.healing[tier],
				avg = avg, total = healTotal, players = healN, wclBacked = healWcl or nil,
				tooltip = { title = TP.METRIC_LABELS.healing,
					lines = { { ("Average percentile of %d healer(s), each vs their own spec."):format(healN), 1, 1, 1 } } },
			}
		end
	end
	-- count metrics: coverage when opportunity data exists (self-curating
	-- kickable list), plain volume otherwise
	local opps = fight and fight.totals and fight.totals.kickOpportunities
	if opps and opps > 0 then
		local landed = fight.totals.kicksLanded or 0
		-- a landed kick IS proof of an opportunity: the 10s post-kick
		-- grace can under-count them, and "13/12" is nonsense (Josh
		-- 2026-07-25) — the denominator floors at landed
		if landed > opps then
			opps = landed
		end
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
				lines = { { "Casts of known-kickable spells. Every one that got through hit somebody.", 1, 1, 1 } } } }
	elseif kicks > 0 then
		local heavy = kicks >= (A.kicksFullIntensity or 6)
		-- no opportunity data: say WHY the "kicked X of Y" stat is absent
		-- instead of a generic shrug — the reason differs by client
		local why
		if TP.Compat and TP.Compat.IS_RETAIL then
			why = "Retail hides enemy casts - landed kicks are all any addon sees."
		else
			why = "Still learning this content's kickable spells - counts appear once seen."
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
						{ "Cooldowns and potions multiply inside the window. Dead before it = excused.", 1, 1, 1 },
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
							{ ("%d%% of ranked kills bring %d healer(s). Advice, never points."):format(field.modePct, field.mode), 1, 1, 1 },
						} } }
			end
		end
	end

	-- Raid-CD assignment: heavy-damage moments went uncovered while
	-- raid-wide cooldowns sat in someone's kit unused ALL fight. Names
	-- the buttons, so "assign the raid CDs" stops being abstract. The
	-- healers' cdTiming points already judge coverage; this line is the
	-- to-do list. Classic only (retail can't see others' casts).
	if fight and fight.players and TP.RAID_CDS then
		local windows, covered = 0, 0
		for _, p in pairs(fight.players) do
			local m = p.metrics or {}
			if (m.groupSpikeWindows or 0) > windows then
				windows = m.groupSpikeWindows
				covered = m.groupSpikeCovered or 0
			end
		end
		if windows >= 2 and covered < windows then
			local used = (fight.totals and fight.totals.raidCdsUsed) or {}
			local unused = {}
			for spellID, cd in pairs(TP.RAID_CDS) do
				if not used[spellID] then
					for _, p in pairs(fight.players) do
						if (cd.spec and p.specID == cd.spec) or (cd.class and p.class == cd.class) then
							unused[#unused + 1] = cd.name
							break
						end
					end
				end
			end
			if #unused > 0 then
				table.sort(unused)
				local names = table.concat(unused, ", ", 1, math.min(3, #unused))
				if #unused > 3 then
					names = names .. (" and %d more"):format(#unused - 3)
				end
				local bad = covered / windows < 0.5
				out[#out + 1] = { kind = "info", key = "raidCds",
					symbol = bad and "-" or MIDDOT, color = bad and BAD or MID,
					-- the full count rides the bullet: the group card's glyph
					-- used to count commas in a list already cut to three
					count = #unused,
					text = ("%d of %d heavy-damage moments had no cooldown - %s sat unused"):format(
						windows - covered, windows, names),
					tooltip = { title = "Raid cooldown assignment",
						lines = {
							{ "Owned, never pressed. Assign one button per big moment.", 1, 1, 1 },
						} } }
			end
		end
	end

	-- Speed trend: this kill vs the group's previous kill of the same
	-- boss+difficulty (stamped at capture by FightHistory). The percentile
	-- move rides along when curves cover the fight; ties within 5s stay
	-- silent (that's variance, not a trend).
	if fight and fight.isBoss and not fight.wipe and not fight.practice
		and fight.prevKillDuration and (fight.duration or 0) > 0 then
		local delta = fight.prevKillDuration - fight.duration
		if math.abs(delta) >= 5 then
			local pctPart = ""
			local E2 = TP.Scoring and TP.Scoring.Engine
			if E2 and E2.KillSpeedPercentile then
				local curPct, _, _, curB = E2.KillSpeedPercentile(fight)
				if curPct and not curB then
					local prevPct, _, _, prevB = E2.KillSpeedPercentile({
						name = fight.name, encounterID = fight.encounterID, isBoss = true,
						duration = fight.prevKillDuration, difficultyID = fight.difficultyID,
					})
					if prevPct and not prevB then
						pctPart = (" (p%d -> p%d)"):format(
							math.floor(prevPct + 0.5), math.floor(curPct + 0.5))
					end
				end
			end
			local faster = delta > 0
			out[#out + 1] = { kind = "info", key = "speedTrend",
				symbol = faster and "+" or MIDDOT, color = faster and GOOD or MID,
				text = (faster
					and ("Killed %ds faster than last time%s")
					or ("%ds slower than the last kill%s")):format(math.floor(math.abs(delta) + 0.5), pctPart),
				tooltip = { title = "Kill speed trend",
					lines = {
						{ "Vs this group's previous kill of this boss.", 1, 1, 1 },
					} } }
		end
	end

	-- Wipe-call crispness: once a wipe is called, dying fast IS the reset
	-- - every second spent kiting is a second not spent re-pulling. The
	-- forgiveness set already stops the call from costing anyone points;
	-- this line grades the wrap itself.
	if fight and fight.wipe and fight.calledWipeAt
		and (fight.duration or 0) > fight.calledWipeAt then
		local tail = math.floor(fight.duration - fight.calledWipeAt + 0.5)
		local sym, col, suffix = "-", BAD, ""
		if tail <= 15 then
			sym, col, suffix = "+", GOOD, " - crisp"
		elseif tail <= 30 then
			sym, col = MIDDOT, MID
		end
		out[#out + 1] = { kind = "info", key = "wipeWrap", symbol = sym, color = col,
			text = ("Wipe called, wrapped %ds later%s"):format(tail, suffix),
			tooltip = { title = "Wipe-call crispness",
				lines = {
					{ "Time from the wipe call to the end. Dying fast IS the reset.", 1, 1, 1 },
				} } }
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
			pressure = (" (%.0f%% avoidable)"):format(
				(fight.totals.avoidableTaken or 0) / fight.totals.damageTaken * 100)
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
	-- A buff no class here can bring is the comp's doing, not a player's:
	-- the group gets the point back (Engine.GroupAdjustments adds it to
	-- the group score; this line is where the card shows it)
	local gadj = TP.Scoring.Engine.GroupAdjustments(fight)
	if gadj.compBuffs then
		local missing = TP.Scoring.Engine.CompBuffsMissing(fight)
		local short = {}
		for _, label in ipairs(missing) do
			short[#short + 1] = (label:gsub("%s*%(.-%)", ""))
		end
		out[#out + 1] = { kind = "bonus", key = "compBuffs", symbol = "+", color = GOOD,
			text = ("Nobody here brings %s (+%d)"):format(table.concat(short, ", "), gadj.compBuffs),
			tooltip = { title = "Buffs the comp lacks",
				lines = {
					{ "Ranked kills nearly always have the full set, so the group is graded a little short without it. Nobody is at fault; the group gets the points back.", 1, 1, 1, true },
				} } }
	end

	return Bullets.SortBestFirst(out)
end
