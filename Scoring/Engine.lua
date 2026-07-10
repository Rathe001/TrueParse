-- The contribution score. Consumes one FightHistory record (plain data) and
-- returns 0-100 scores with full per-metric breakdowns.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
--
-- Model (user-approved design):
--  1. Every metric normalizes to 0-100 first:
--     - damage / healing / damageTaken: relative to the best of your ROLE
--       cohort; when you're the only one of your role, your group share is
--       scored against Weights.expectedShare instead.
--     - interrupts / dispels: your count vs an equal share of the group's
--       total (opportunity data isn't exposed on Midnight clients).
--  2. Inapplicable metrics (no kick on your spec, nothing dispelled this
--     fight, not a tank) drop out and remaining weights renormalize — this
--     keeps 100 reachable for every role on every fight.
--  3. Penalties (avoidable damage excess, deaths) subtract; clamp [0,100].
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Engine = {}
TP.Scoring.Engine = Engine

local function effHealing(m)
	return (m.healing or 0) + (m.absorbs or 0)
end

local function metricValue(p, key)
	if key == "healing" then
		return effHealing(p.metrics)
	end
	return p.metrics[key] or 0
end

local function normalizeRole(p)
	return TP.Scoring.Capabilities.EffectiveRole(p.role, p.specIconID)
end

-- Difficulties whose runs actually populate the WCL dungeon rankings
local DUNGEON_ABSOLUTE_DIFFICULTY = {
	["Mythic Keystone"] = true,
	["Challenge Mode"] = true, -- MoP Classic
}

-- Fight-specific spec expectations: boss fights match a WCL encounter table
-- by name (retail prefixes encounters with "(!) "), anything inside a
-- dungeon matches the dungeon's table by zone name. This is the per-fight
-- handicap curve — a spec that underperforms on THIS fight (movement,
-- cleave, ...) is measured against that fight's medians, not global ones.
local function resolveFightFactors(fight)
	local B = TP.Benchmarks
	if not B then
		return nil
	end
	if fight.isBoss and fight.name and B.encounters then
		local plainName = fight.name:gsub("^%(!%)%s*", "")
		local set = B.encounters[plainName]
		if set then
			return set
		end
	end
	if fight.zone and B.dungeons then
		local set = B.dungeons[fight.zone]
		if set then
			-- Dungeon benchmarks are sampled from M+/Challenge Mode logs.
			-- On other difficulties (Heroic, Timewalking scale-down) the
			-- spec factors still apply RELATIVELY, but comparing absolute
			-- output against top-key medians would grade the content, not
			-- the player.
			if DUNGEON_ABSOLUTE_DIFFICULTY[fight.difficulty or ""] then
				return set
			end
			return {
				damageFactor = set.damageFactor,
				healingFactor = set.healingFactor,
				ilvlMedian = set.ilvlMedian,
			}
		end
	end
	return nil
end

-- Combined spec + item-level output factor (from Data/Benchmarks.lua, WCL
-- statistics). A player's throughput is divided by this before comparison,
-- so a low-output spec or low-ilvl player is graded on performance relative
-- to what their spec and gear can produce. Fight-specific factors take
-- precedence over global ones. SUPPORT keeps its hand-calibrated
-- expectations (WCL aug numbers include support damage we can't see).
local function outputFactor(p, role, key, ctx)
	local B = TP.Benchmarks
	if not B or role == "SUPPORT" then
		return 1
	end
	local factor = 1
	local wantHealing = (key == "healing")
	local specFactor
	if ctx.fightFactors then
		local t = wantHealing and ctx.fightFactors.healingFactor or ctx.fightFactors.damageFactor
		specFactor = t and p.specID and t[p.specID]
	end
	if not specFactor then
		local t = wantHealing and B.healingFactor or B.damageFactor
		specFactor = t and p.specID and t[p.specID]
	end
	if specFactor and specFactor > 0 then
		factor = factor * specFactor
	end
	if ctx.normalizeIlvl and B.ilvlSlopePct and p.ilvl and ctx.meanIlvl then
		factor = factor * (1 + B.ilvlSlopePct / 100) ^ (p.ilvl - ctx.meanIlvl)
	end
	return factor
end

local function adjustedValue(p, role, key, ctx)
	return metricValue(p, key) / outputFactor(p, role, key, ctx)
end

-- Percentile curves (Data/Percentiles*.lua): the metric value at fixed
-- population percentiles per encounter+spec. When present, Raw scores are
-- TRUE percentiles — matching WCL's parse numbers — instead of the linear
-- %-of-elite-median fallback (which reads far too generous mid-pack:
-- logged populations bunch high, so 60% of elite output can be p12).
-- WoW difficultyID -> WCL ranking bracket. Classic raid sizes rank
-- separately (a 10N raider measured against 25H parses reads absurdly
-- low); retail raids are flex-sized so difficulty alone brackets them.
local WCL_BRACKET = {
	[3] = "3x10", [4] = "3x25", [5] = "4x10", [6] = "4x25", -- classic 10/25 N/H
	[14] = "3", [15] = "4", [16] = "5", -- retail Normal/Heroic/Mythic
}

local function resolvePercentiles(fight)
	local P = TP.Percentiles
	if not P or not P.encounters or not fight.isBoss or not fight.name then
		return nil
	end
	local enc = P.encounters[fight.name:gsub("^%(!%)%s*", "")]
	if not enc then
		return nil
	end
	local key = fight.difficultyID and WCL_BRACKET[fight.difficultyID]
	return (key and enc[key]) or enc.all
end

-- curve: { {99, value}, {95, value}, ... } descending. Linear interpolation
-- between sampled points; above p99 pins at 99, below the lowest sample
-- fades linearly to 0 at zero output.
local function percentileFor(curve, rate)
	if not rate or rate <= 0 then
		return 0
	end
	if rate >= curve[1][2] then
		return 99
	end
	local prev = curve[1]
	for i = 2, #curve do
		local point = curve[i]
		if rate >= point[2] then
			local span = prev[2] - point[2]
			if span <= 0 then
				return point[1]
			end
			return point[1] + (prev[1] - point[1]) * (rate - point[2]) / span
		end
		prev = point
	end
	local last = curve[#curve]
	if last[2] <= 0 then
		return last[1]
	end
	return last[1] * rate / last[2]
end

-- Returns normalizedScore (0-100), applicable, absolute, relative,
-- specMedian (the p50 rate for this spec+fight+bracket, when curve-scored)
local function normalizeMetric(p, role, key, ctx)
	local specMedian
	local W = TP.Scoring.Weights
	local value = metricValue(p, key)

	-- Count metrics use Laplace smoothing (+0.5): when a whole fight has
	-- one or two kicks, raw fair-share scoring is winner-take-all — the
	-- kicker gets 100, everyone else 0, pure noise (2026-07-09 audit: DPS
	-- averaged 30/100 on interrupts, dispel-capable DPS 1/100 on dispels).
	-- Smoothed, a non-kicker on a 1-kick fight scores ~43; on a 10-kick
	-- fight still ~12. Signal survives, coin-flips don't.
	-- Zero participation can never grade "good" no matter how forgiving the
	-- smoothing gets on a 1-kick fight: cap it in neutral territory.
	if key == "interrupts" then
		if not TP.Scoring.Capabilities.CanInterrupt(p.class, role) then
			return 0, false
		end
		if ctx.totals.interrupts <= 0 or ctx.kickCapable <= 0 then
			return 0, false -- nothing was kicked this fight: not scoreable
		end
		local fairShare = ctx.totals.interrupts / ctx.kickCapable
		local smoothed = math.min(100, 100 * (value + 0.5) / (fairShare + 0.5))
		if value <= 0 then
			smoothed = math.min(smoothed, 55)
		end
		return smoothed, true
	end

	if key == "dispels" then
		if not TP.Scoring.Capabilities.CanDispel(p.class) then
			return 0, false -- no cleanse on this class
		end
		if ctx.totals.dispels <= 0 then
			return 0, false -- nothing dispellable happened
		end
		local fairShare = ctx.totals.dispels / ctx.playerCount
		local smoothed = math.min(100, 100 * (value + 0.5) / (fairShare + 0.5))
		if value <= 0 then
			smoothed = math.min(smoothed, 55)
		end
		return smoothed, true
	end

	if key == "buffUptime" then
		-- Self-reported Ebon Might uptime (fraction of the fight), only
		-- present when the support player runs TrueParse. Absent -> weight
		-- redistributes, exactly like a missing capability.
		local uptime = p.metrics and p.metrics.buffUptime
		if not uptime then
			return 0, false
		end
		return math.min(100, 100 * uptime / (W.supportUptimeAnchor or 1)), true
	end

	if key == "damageTaken" and role ~= "TANK" then
		return 0, false
	end

	-- Throughput family. Two views, blended when both exist:
	--  * ABSOLUTE: preferred source is the bracket percentile curve mapped
	--    through the contribution transform (p50 -> 65, elite -> ~100);
	--    fallback is the elite-median anchor (whose ilvl extrapolation
	--    collapses far below elite gear — see Weights).
	--  * RELATIVE: cohort comparison (spec/ilvl-adjusted), expected-share
	--    fallback for solo-role slots — differentiates the room.
	local absolute, fromCurve
	if role ~= "SUPPORT" and ctx.duration and ctx.duration > 0 then
		if ctx.percentiles then
			local kindTbl = (key == "healing") and ctx.percentiles.hps
				or (key == "damage") and ctx.percentiles.dps
			local entry = kindTbl and p.specID and kindTbl[p.specID]
			if entry and entry.curve and #entry.curve > 1 then
				local pct = percentileFor(entry.curve, metricValue(p, key) / ctx.duration)
				absolute = math.min(100, (W.trueAbsFloor or 0) + (W.trueAbsSlope or 1) * pct)
				fromCurve = true
				-- surfaced in tooltips: "the median of your spec does Y/s
				-- here" — answers every 'but I topped the meter?!'
				for _, point in ipairs(entry.curve) do
					if point[1] == 50 then
						specMedian = point[2]
					end
				end
			end
		end
		if not absolute and ctx.fightFactors then
			local medians = (key == "healing") and ctx.fightFactors.healingMedian
				or (key == "damage") and ctx.fightFactors.damageMedian
			local bench = medians and p.specID and medians[p.specID]
			if bench and bench > 0 then
				local B = TP.Benchmarks
				if ctx.normalizeIlvl and B.ilvlSlopePct and p.ilvl and ctx.fightFactors.ilvlMedian then
					bench = bench * (1 + B.ilvlSlopePct / 100) ^ (p.ilvl - ctx.fightFactors.ilvlMedian)
				end
				bench = bench * (W.absoluteAnchor or 1)
				absolute = math.min(100, 100 * (metricValue(p, key) / ctx.duration) / bench)
			end
		end
	end

	-- A per-spec, per-fight, per-bracket population percentile is complete
	-- evidence: blending in the cohort comparison only re-introduces the
	-- structural spec biases it exists to paper over (Blood DK self-healing
	-- vs other tanks, Disc/Mistweaver damage vs other healers). Curves for
	-- EVERY spec x metric make cross-metric contributions spec-fair.
	if absolute and fromCurve and not ctx.parseMode then
		return absolute, true, absolute, nil, specMedian
	end

	local relative, applicable
	local adjusted = adjustedValue(p, role, key, ctx)
	local cohort = ctx.cohorts[role]
	if #cohort > 1 then
		local best = 0
		for _, member in ipairs(cohort) do
			local v = adjustedValue(member, role, key, ctx)
			if v > best then
				best = v
			end
		end
		if best > 0 then
			relative, applicable = math.min(100, 100 * adjusted / best), true
		end
	else
		local expected = W.expectedShare[role] and W.expectedShare[role][key]
		local groupTotal = ctx.totals[key]
		if expected and groupTotal and groupTotal > 0 then
			relative = math.min(W.soloCohortCap or 100, 100 * (adjusted / groupTotal) / expected)
			applicable = true
		end
	end

	if ctx.parseMode then
		-- Best evidence first: a true population percentile when a curve
		-- covers this fight+spec (raw per-second output, no ilvl adjustment
		-- — WCL's headline parse doesn't bracket by gear either), then the
		-- %-of-elite-median, then the group comparison.
		if ctx.percentiles and ctx.duration and ctx.duration > 0 then
			local kindTbl = (key == "healing") and ctx.percentiles.hps
				or (key == "damage") and ctx.percentiles.dps
			local entry = kindTbl and p.specID and kindTbl[p.specID]
			if entry and entry.curve and #entry.curve > 1 then
				local pct = percentileFor(entry.curve, metricValue(p, key) / ctx.duration)
				for _, point in ipairs(entry.curve) do
					if point[1] == 50 then
						specMedian = point[2]
					end
				end
				return pct, true, pct, nil, specMedian
			end
		end
		-- WCL semantics: 100 doesn't exist. And a relative-only fallback
		-- (no benchmark for this fight) makes the group's best a 99 "parse"
		-- by definition — the UI marks those scores as approximations.
		if absolute then
			return math.min(absolute, 99), true, math.min(absolute, 99), nil
		elseif relative then
			return math.min(relative, 99), applicable, nil, math.min(relative, 99)
		end
		return 0, false
	end

	if absolute and relative then
		local blend = W.absoluteBlend or 0
		return blend * absolute + (1 - blend) * relative, true, absolute, relative
	elseif absolute then
		return absolute, true, absolute, nil
	elseif relative then
		return relative, applicable, nil, relative
	end
	return 0, false
end

-- Parse mode: the WCL-style lens. One throughput metric per role, no
-- utility weights and no penalties. The contribution score remains the
-- default and feeds career/coach/run reports; this is a display lens.
local PARSE_WEIGHTS = {
	TANK = { damage = 1 },
	HEALER = { healing = 1 },
	DAMAGER = { damage = 1 },
	SUPPORT = { damage = 1 },
}

-- fight: a FightHistory record. opts.normalizeIlvl (default true) grades
-- throughput relative to gear. Returns an array sorted by score desc:
-- { guid, name, class, role, score, base, penalty, breakdown }, where
-- breakdown[metric] = { weight, effectiveWeight, normalized, contribution,
-- applicable, value }.
function Engine.ScoreFight(fight, opts)
	local W = TP.Scoring.Weights
	local Cap = TP.Scoring.Capabilities
	opts = opts or {}

	local players = {}
	for _, p in pairs(fight.players) do
		players[#players + 1] = p
	end
	if #players == 0 then
		return {}
	end

	local ctx = {
		playerCount = #players,
		cohorts = {},
		kickCapable = 0,
		normalizeIlvl = opts.normalizeIlvl ~= false,
		parseMode = (opts.mode == "parse"),
		percentiles = resolvePercentiles(fight), -- raw pct in parse; transformed in True
		fightFactors = resolveFightFactors(fight),
		duration = fight.duration,
		totals = { damage = 0, healing = 0, damageTaken = 0, interrupts = 0, dispels = 0, avoidable = 0 },
	}

	-- Reference ilvl for gear normalization: group mean of known ilvls
	local ilvlSum, ilvlCount = 0, 0
	for _, p in ipairs(players) do
		if p.ilvl and p.ilvl > 0 then
			ilvlSum = ilvlSum + p.ilvl
			ilvlCount = ilvlCount + 1
		end
	end
	if ilvlCount >= 2 then
		ctx.meanIlvl = ilvlSum / ilvlCount
	end
	for _, p in ipairs(players) do
		local m = p.metrics
		ctx.totals.damage = ctx.totals.damage + (m.damage or 0)
		ctx.totals.healing = ctx.totals.healing + effHealing(m)
		ctx.totals.damageTaken = ctx.totals.damageTaken + (m.damageTaken or 0)
		ctx.totals.interrupts = ctx.totals.interrupts + (m.interrupts or 0)
		ctx.totals.dispels = ctx.totals.dispels + (m.dispels or 0)
		ctx.totals.avoidable = ctx.totals.avoidable + (m.avoidableTaken or 0)

		local role = normalizeRole(p)
		ctx.cohorts[role] = ctx.cohorts[role] or {}
		table.insert(ctx.cohorts[role], p)
		if Cap.CanInterrupt(p.class, role) then
			ctx.kickCapable = ctx.kickCapable + 1
		end
	end

	-- Healing demand: when nobody died and nobody even dipped (Classic
	-- health sampler), share-based healing comparisons are noise — passive
	-- DPS self-healing outweighs real healing when there's nothing to heal.
	-- Healers get a neutral floor instead of a "low healing" slap.
	do
		local deaths = 0
		for _, p in ipairs(players) do
			deaths = deaths + (p.metrics.deaths or 0)
		end
		if deaths == 0 then
			local sampled, worst = 0, 1
			for _, p in ipairs(players) do
				if p.minHealthPct then
					sampled = sampled + 1
					if p.minHealthPct < worst then
						worst = p.minHealthPct
					end
				end
			end
			ctx.lowHealingDemand = (sampled > 0 and worst >= 0.70) or nil
		end
	end

	local results = {}
	for _, p in ipairs(players) do
		local role = normalizeRole(p)
		local weights = ctx.parseMode and PARSE_WEIGHTS[role] or W.roleWeights[role]

		local breakdown = {}
		local activeWeight = 0
		for key, weight in pairs(weights) do
			local normalized, applicable, absolute, relative, specMedian = normalizeMetric(p, role, key, ctx)
			-- Trivial-demand floor: only for share-based healer healing (a
			-- WCL absolute already prices the fight's real demand), and only
			-- outside parse mode (a raw parse SHOULD read low on a fight
			-- with nothing to heal)
			local lowDemand
			if key == "healing" and role == "HEALER" and applicable
				and not absolute and not ctx.parseMode
				and ctx.lowHealingDemand and normalized < 75 then
				normalized = 75
				lowDemand = true
			end
			breakdown[key] = {
				weight = weight,
				normalized = normalized,
				applicable = applicable,
				absolute = absolute, -- vs WCL top-logs median, when available
				relative = relative, -- vs the group, when available
				lowDemand = lowDemand, -- floored: nothing to heal this fight
				specMedian = specMedian, -- p50 rate for this spec+fight+bracket
				value = metricValue(p, key),
			}
			if applicable then
				activeWeight = activeWeight + weight
			end
		end

		local base = 0
		for _, b in pairs(breakdown) do
			if b.applicable and activeWeight > 0 then
				b.effectiveWeight = b.weight / activeWeight
				b.contribution = b.normalized * b.effectiveWeight
				base = base + b.contribution
			else
				b.effectiveWeight = 0
				b.contribution = 0
			end
		end

		local m = p.metrics
		local penaltyAvoidable = 0
		if not ctx.parseMode and ctx.totals.avoidable > 0 then
			local share = (m.avoidableTaken or 0) / ctx.totals.avoidable
			local excess = share - (1 / ctx.playerCount)
			if excess > 0 then
				penaltyAvoidable = math.min(W.penalties.avoidableCap, excess * W.penalties.avoidablePerExcessShare)
			end
		end
		local penaltyDeaths = 0
		local deathCount = m.deaths or 0
		if not ctx.parseMode and deathCount > 0 then
			local lastDeathCost = W.penalties.perDeath
			if p.deathTime and ctx.duration and ctx.duration > 0 then
				local fraction = math.max(0, math.min(1, p.deathTime / ctx.duration))
				lastDeathCost = W.penalties.perDeath * (1 - (W.penalties.deathTimingRelief or 0) * fraction)
			end
			penaltyDeaths = math.min(W.penalties.deathsCap,
				(deathCount - 1) * W.penalties.perDeath + lastDeathCost)
			if fight.wipe then
				penaltyDeaths = penaltyDeaths * (W.penalties.wipeDeathScale or 1)
			end
		end
		local penaltyBuffs = 0
		local buffFloor = W.penalties.buffCoverageFloor or 1
		if not ctx.parseMode and p.buffCoverage and p.buffCoverage < buffFloor then
			penaltyBuffs = ((buffFloor - p.buffCoverage) / buffFloor) * (W.penalties.missingBuffMax or 0)
		end

		-- Threat discipline (fields only present on Classic captures).
		-- Tanks pulling is their job; everyone else pays for it. Tanks pay
		-- for the time mobs spent on someone who isn't a tank.
		local penaltyPull, penaltyAggro, penaltyAggroLoss = 0, 0, 0
		if ctx.parseMode
			or ctx.playerCount > (W.penalties.threatMaxPlayers or math.huge) then
			-- raids: fixates and forced target swaps make threat data
			-- mechanics-noise; it stays visible in bullets, never scored
		elseif role == "TANK" then
			if (p.aggroLostTime or 0) > 0 then
				penaltyAggroLoss = math.min(W.penalties.aggroLossCap or 0,
					p.aggroLostTime * (W.penalties.aggroLossPerSecond or 0))
			end
		else
			if p.aggroPulled then
				penaltyPull = W.penalties.pulledPack or 0
			end
			if (p.aggroRips or 0) > 0 then
				local perRip = W.penalties.perAggroRip or 0
				if role == "HEALER" then
					-- healing aggro chasing a slacking tank isn't the
					-- healer's crime; charge it at half price
					perRip = perRip * (W.penalties.healerRipScale or 1)
				end
				penaltyAggro = math.min(W.penalties.aggroRipsCap or 0, p.aggroRips * perRip)
			end
		end

		local penalty = math.min(W.penalties.totalCap, penaltyAvoidable + penaltyDeaths + penaltyBuffs
			+ penaltyPull + penaltyAggro + penaltyAggroLoss)

		results[#results + 1] = {
			guid = p.guid,
			name = p.name,
			class = p.class,
			role = role,
			score = math.max(0, math.min(100, base - penalty)),
			base = base,
			penalty = penalty,
			penaltyDetail = { avoidable = penaltyAvoidable, deaths = penaltyDeaths, buffs = penaltyBuffs,
				pull = penaltyPull, aggro = penaltyAggro, aggroLoss = penaltyAggroLoss },
			breakdown = breakdown,
		}
	end

	table.sort(results, function(a, b)
		return a.score > b.score
	end)
	return results
end
