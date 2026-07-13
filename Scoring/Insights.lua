-- Group-level takeaways from a set of score results: what the group did
-- well and what to work on. Feeds the one-line group chat summary.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Insights = {}
TP.Scoring.Insights = Insights

-- Metrics eligible as group strengths/weaknesses: shared by several
-- players. damageTaken is excluded — it's effectively a solo tank metric
-- and its average says nothing about the group.
local GROUP_METRICS = { damage = true, healing = true, interrupts = true, dispels = true }
local MIN_PLAYERS = 2

-- Returns { strength = key|nil, weakness = key|nil, deaths = playerCount,
-- avoidableHitters = playerCount, buffsMissing = bool }
function Insights.ForResults(results)
	local sums, counts = {}, {}
	local deaths, avoidableHitters = 0, 0
	local buffsMissing = false

	for _, r in ipairs(results) do
		for key, b in pairs(r.breakdown) do
			if b.applicable and GROUP_METRICS[key] then
				sums[key] = (sums[key] or 0) + (b.normalized or 0)
				counts[key] = (counts[key] or 0) + 1
			end
		end
		local pd = r.penaltyDetail or {}
		if (pd.deaths or 0) > 0 then
			deaths = deaths + 1
		end
		if (pd.avoidable or 0) > 0 then
			avoidableHitters = avoidableHitters + 1
		end
		if (pd.buffs or 0) > 0 then
			buffsMissing = true
		end
	end

	local best, bestAvg, worst, worstAvg
	for key, sum in pairs(sums) do
		if counts[key] >= MIN_PLAYERS then
			local avg = sum / counts[key]
			if not best or avg > bestAvg then
				best, bestAvg = key, avg
			end
			if not worst or avg < worstAvg then
				worst, worstAvg = key, avg
			end
		end
	end

	return {
		strength = (best and bestAvg >= 65) and best or nil,
		strengthAvg = bestAvg,
		weakness = (worst and worst ~= best and worstAvg < 55) and worst or nil,
		weaknessAvg = worstAvg,
		deaths = deaths,
		avoidableHitters = avoidableHitters,
		buffsMissing = buffsMissing,
	}
end

-- The whole vs the sum of the parts (2026-07-13): individual output
-- percentiles are the parts; the kill-speed percentile is the whole.
-- Killing faster than the parses say means the group executed —
-- target discipline, mechanics, cooldown timing. Big parses with slow
-- kills mean output went somewhere other than winning. facts carries
-- run-level tallies the results array can't see: { kickOpps,
-- kicksLanded, deaths }. killPct = kill-speed percentile (0-99).
function Insights.GroupAnalysis(results, facts, killPct)
	facts = facts or {}
	local outSum, outN = 0, 0
	for _, r in ipairs(results) do
		local key = (r.role == "HEALER") and "healing" or "damage"
		local b = r.breakdown and r.breakdown[key]
		-- percentile-backed entries only: the parts must be measured on
		-- the same WCL scale as the whole
		if b and b.applicable and b.pctile and not b.lowDemand then
			outSum = outSum + b.pctile
			outN = outN + 1
		end
	end
	local a = {
		outputPct = outN > 0 and (outSum / outN) or nil,
		outputN = outN,
		killPct = killPct,
		deaths = facts.deaths,
		flawless = facts.deaths == 0 or nil,
	}
	if a.outputPct and killPct and outN >= 2 then
		a.executionGap = killPct - a.outputPct
	end
	if (facts.kickOpps or 0) > 0 then
		a.kickOpps = facts.kickOpps
		a.kicksLanded = facts.kicksLanded or 0
		a.kickCoverage = a.kicksLanded / facts.kickOpps
	end
	return a
end
