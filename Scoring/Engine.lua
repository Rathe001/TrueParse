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

local function normalizeRole(role)
	if role == "TANK" or role == "HEALER" then
		return role
	end
	return "DAMAGER"
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

	-- Throughput family: cohort-relative, expected-share fallback
	local cohort = ctx.cohorts[role]
	if #cohort > 1 then
		local best = 0
		for _, member in ipairs(cohort) do
			local v = metricValue(member, key)
			if v > best then
				best = v
			end
		end
		if best <= 0 then
			return 0, false
		end
		return 100 * value / best, true
	end

	local expected = W.expectedShare[role] and W.expectedShare[role][key]
	local groupTotal = ctx.totals[key]
	if not expected or not groupTotal or groupTotal <= 0 then
		return 0, false
	end
	return math.min(100, 100 * (value / groupTotal) / expected), true
end

-- fight: a FightHistory record. Returns an array sorted by score desc:
-- { guid, name, class, role, score, base, penalty, breakdown }, where
-- breakdown[metric] = { weight, effectiveWeight, normalized, contribution,
-- applicable, value }.
function Engine.ScoreFight(fight)
	local W = TP.Scoring.Weights
	local Cap = TP.Scoring.Capabilities

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
		totals = { damage = 0, healing = 0, damageTaken = 0, interrupts = 0, dispels = 0, avoidable = 0 },
	}
	for _, p in ipairs(players) do
		local m = p.metrics
		ctx.totals.damage = ctx.totals.damage + (m.damage or 0)
		ctx.totals.healing = ctx.totals.healing + effHealing(m)
		ctx.totals.damageTaken = ctx.totals.damageTaken + (m.damageTaken or 0)
		ctx.totals.interrupts = ctx.totals.interrupts + (m.interrupts or 0)
		ctx.totals.dispels = ctx.totals.dispels + (m.dispels or 0)
		ctx.totals.avoidable = ctx.totals.avoidable + (m.avoidableTaken or 0)

		local role = normalizeRole(p.role)
		ctx.cohorts[role] = ctx.cohorts[role] or {}
		table.insert(ctx.cohorts[role], p)
		if Cap.CanInterrupt(p.class, role) then
			ctx.kickCapable = ctx.kickCapable + 1
		end
	end

	local results = {}
	for _, p in ipairs(players) do
		local role = normalizeRole(p.role)
		local weights = W.roleWeights[role]

		local breakdown = {}
		local activeWeight = 0
		for key, weight in pairs(weights) do
			local normalized, applicable = normalizeMetric(p, role, key, ctx)
			breakdown[key] = {
				weight = weight,
				normalized = normalized,
				applicable = applicable,
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
		local penalty = 0
		if ctx.totals.avoidable > 0 then
			local share = (m.avoidableTaken or 0) / ctx.totals.avoidable
			local excess = share - (1 / ctx.playerCount)
			if excess > 0 then
				penalty = penalty + math.min(W.penalties.avoidableCap, excess * W.penalties.avoidablePerExcessShare)
			end
		end
		penalty = penalty + math.min(W.penalties.deathsCap, (m.deaths or 0) * W.penalties.perDeath)
		penalty = math.min(W.penalties.totalCap, penalty)

		results[#results + 1] = {
			guid = p.guid,
			name = p.name,
			class = p.class,
			role = role,
			score = math.max(0, math.min(100, base - penalty)),
			base = base,
			penalty = penalty,
			breakdown = breakdown,
		}
	end

	table.sort(results, function(a, b)
		return a.score > b.score
	end)
	return results
end
