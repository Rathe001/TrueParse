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
		return B.dungeons[fight.zone]
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

-- Returns normalizedScore (0-100), applicable (boolean)
local function normalizeMetric(p, role, key, ctx)
	local W = TP.Scoring.Weights
	local value = metricValue(p, key)

	if key == "interrupts" then
		if not TP.Scoring.Capabilities.CanInterrupt(p.class, role) then
			return 0, false
		end
		if ctx.totals.interrupts <= 0 or ctx.kickCapable <= 0 then
			return 0, false -- nothing was kicked this fight: not scoreable
		end
		local fairShare = ctx.totals.interrupts / ctx.kickCapable
		return math.min(100, 100 * value / fairShare), true
	end

	if key == "dispels" then
		if ctx.totals.dispels <= 0 then
			return 0, false -- nothing dispellable happened
		end
		local fairShare = ctx.totals.dispels / ctx.playerCount
		return math.min(100, 100 * value / fairShare), true
	end

	if key == "damageTaken" and role ~= "TANK" then
		return 0, false
	end

	-- Throughput family. Two views, blended when both exist:
	--  * ABSOLUTE: your per-second output as a fraction of the WCL top-logs
	--    median for your spec on this fight (ilvl-scaled) — consistent
	--    across groups.
	--  * RELATIVE: cohort comparison (spec/ilvl-adjusted), expected-share
	--    fallback for solo-role slots — differentiates the room.
	local absolute
	if role ~= "SUPPORT" and ctx.fightFactors and ctx.duration and ctx.duration > 0 then
		local medians = (key == "healing") and ctx.fightFactors.healingMedian
			or (key == "damage") and ctx.fightFactors.damageMedian
		local bench = medians and p.specID and medians[p.specID]
		if bench and bench > 0 then
			local B = TP.Benchmarks
			if ctx.normalizeIlvl and B.ilvlSlopePct and p.ilvl and ctx.fightFactors.ilvlMedian then
				bench = bench * (1 + B.ilvlSlopePct / 100) ^ (p.ilvl - ctx.fightFactors.ilvlMedian)
			end
			absolute = math.min(100, 100 * (metricValue(p, key) / ctx.duration) / bench)
		end
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
			relative, applicable = math.min(100, 100 * (adjusted / groupTotal) / expected), true
		end
	end

	if absolute and relative then
		local blend = W.absoluteBlend or 0
		return blend * absolute + (1 - blend) * relative, true, absolute
	elseif absolute then
		return absolute, true, absolute
	elseif relative then
		return relative, applicable
	end
	return 0, false
end

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

	local results = {}
	for _, p in ipairs(players) do
		local role = normalizeRole(p)
		local weights = W.roleWeights[role]

		local breakdown = {}
		local activeWeight = 0
		for key, weight in pairs(weights) do
			local normalized, applicable, absolute = normalizeMetric(p, role, key, ctx)
			breakdown[key] = {
				weight = weight,
				normalized = normalized,
				applicable = applicable,
				absolute = absolute, -- vs WCL top-logs median, when available
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
		if ctx.totals.avoidable > 0 then
			local share = (m.avoidableTaken or 0) / ctx.totals.avoidable
			local excess = share - (1 / ctx.playerCount)
			if excess > 0 then
				penaltyAvoidable = math.min(W.penalties.avoidableCap, excess * W.penalties.avoidablePerExcessShare)
			end
		end
		local penaltyDeaths = 0
		local deathCount = m.deaths or 0
		if deathCount > 0 then
			local lastDeathCost = W.penalties.perDeath
			if p.deathTime and ctx.duration and ctx.duration > 0 then
				local fraction = math.max(0, math.min(1, p.deathTime / ctx.duration))
				lastDeathCost = W.penalties.perDeath * (1 - (W.penalties.deathTimingRelief or 0) * fraction)
			end
			penaltyDeaths = math.min(W.penalties.deathsCap,
				(deathCount - 1) * W.penalties.perDeath + lastDeathCost)
		end
		local penalty = math.min(W.penalties.totalCap, penaltyAvoidable + penaltyDeaths)

		results[#results + 1] = {
			guid = p.guid,
			name = p.name,
			class = p.class,
			role = role,
			score = math.max(0, math.min(100, base - penalty)),
			base = base,
			penalty = penalty,
			penaltyDetail = { avoidable = penaltyAvoidable, deaths = penaltyDeaths },
			breakdown = breakdown,
		}
	end

	table.sort(results, function(a, b)
		return a.score > b.score
	end)
	return results
end
