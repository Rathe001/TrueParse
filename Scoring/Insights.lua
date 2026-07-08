-- Group-level takeaways from a set of score results: what the group did
-- well and what to work on. Feeds the one-line group chat summary.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Insights = {}
TP.Scoring.Insights = Insights

-- Returns { strength = key|nil, weakness = key|nil, deaths = playerCount,
-- avoidableHitters = playerCount, buffsMissing = bool }
function Insights.ForResults(results)
	local sums, counts = {}, {}
	local deaths, avoidableHitters = 0, 0
	local buffsMissing = false

	for _, r in ipairs(results) do
		for key, b in pairs(r.breakdown) do
			if b.applicable then
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
		local avg = sum / counts[key]
		if not best or avg > bestAvg then
			best, bestAvg = key, avg
		end
		if not worst or avg < worstAvg then
			worst, worstAvg = key, avg
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
