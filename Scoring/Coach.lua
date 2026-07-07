-- Post-fight coaching: given one player's score result, identify the single
-- change that would have raised their score most.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Coach = {}
TP.Scoring.Coach = Coach

-- Returns { kind = "avoidable"|"deaths", gain } when penalties dominate,
-- { kind = "metric", key, gain, normalized } for the weakest weighted
-- metric, or nil when there's nothing worth coaching (clean, high play).
function Coach.BiggestOpportunity(result)
	local pd = result.penaltyDetail
	if pd then
		if (pd.avoidable or 0) >= 8 then
			return { kind = "avoidable", gain = pd.avoidable }
		end
		if (pd.deaths or 0) >= 10 then
			return { kind = "deaths", gain = pd.deaths }
		end
	end

	local bestKey, bestGain, bestNorm
	for key, b in pairs(result.breakdown) do
		if b.applicable then
			local gain = (100 - (b.normalized or 0)) * (b.effectiveWeight or 0)
			if not bestKey or gain > bestGain then
				bestKey, bestGain, bestNorm = key, gain, b.normalized
			end
		end
	end
	if bestKey and bestGain >= 5 then
		return { kind = "metric", key = bestKey, gain = bestGain, normalized = bestNorm }
	end
	return nil
end
