-- Fit HEALER_COVERAGE_ANCHORS from REAL captured fights (SavedVariables),
-- the method Data/HealerCoverage.lua documents: the observed distribution of
-- five-man healer-fights, NOT a WCL crawl (two crawls failed; see that file).
-- Reproduces Scoring/Engine.lua's coverage math exactly - if the engine's
-- formula changes, this must change with it:
--   handled  = totals.damageTaken + sum(all players' absorbs)
--   selfHeal = sum over NON-healers of (healing + absorbs)
--   healable = max(handled - selfHeal, handled * 0.15)
--   cov      = (healer.healing + healer.absorbs) / healable * healerN
-- Usage: lua scripts/fit-healer-coverage.lua <TrueParse.lua SV path> [...]
-- Multiple paths pool into one distribution (e.g. retail + a second account).

local function quantile(sorted, q)
	if #sorted == 0 then
		return nil
	end
	local idx = 1 + q * (#sorted - 1)
	local lo, hi = math.floor(idx), math.ceil(idx)
	return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo)
end

local covs = {}
local fights, skipped = 0, 0

for _, path in ipairs(arg) do
	TrueParseDB = nil
	dofile(path)
	local db = TrueParseDB
	if not (db and db.char) then
		error("no TrueParseDB.char in " .. path)
	end
	for _, char in pairs(db.char) do
		for _, f in ipairs(char.recentFights or {}) do
			-- five-man content only: the anchors describe dungeons people
			-- actually run, and the engine gates on roster size <= 5
			local ok = f.players and f.instanceType == "party" and not f.practice
			if ok then
				local scored, healerN, absorbed, selfHeal = 0, 0, 0, 0
				local healers = {}
				for _, p in pairs(f.players) do
					local m = p.metrics or {}
					scored = scored + 1
					absorbed = absorbed + (m.absorbs or 0)
					if p.role == "HEALER" then
						healerN = healerN + 1
						healers[#healers + 1] = m
					else
						selfHeal = selfHeal + (m.healing or 0) + (m.absorbs or 0)
					end
				end
				local handled = ((f.totals and f.totals.damageTaken) or 0) + absorbed
				if scored >= 2 and scored <= 5 and healerN > 0 and handled > 0 then
					local healable = math.max(handled - selfHeal, handled * 0.15)
					for _, m in ipairs(healers) do
						covs[#covs + 1] = ((m.healing or 0) + (m.absorbs or 0))
							/ healable * healerN
						fights = fights + 1
					end
				else
					skipped = skipped + 1
				end
			end
		end
	end
end

table.sort(covs)
print(("healer-fights fitted: %d   (five-man party fights skipped by gates: %d)")
	:format(fights, skipped))
if #covs == 0 then
	return
end
print(("p10=%.3f  p25=%.3f  p50=%.3f  p75=%.3f  p90=%.3f"):format(
	quantile(covs, 0.10), quantile(covs, 0.25), quantile(covs, 0.50),
	quantile(covs, 0.75), quantile(covs, 0.90)))
print(("anchor line:  default = { %.3f, %.3f, %.3f },"):format(
	quantile(covs, 0.25), quantile(covs, 0.50), quantile(covs, 0.75)))
