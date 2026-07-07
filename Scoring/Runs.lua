-- Aggregates a list of fight records into one synthetic "run" record (same
-- shape as a fight), so the scoring engine and grades work on whole
-- dungeon/raid visits.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Runs = {}
TP.Scoring.Runs = Runs

function Runs.Aggregate(fights, name)
	local run = {
		name = name or "Run",
		isBoss = false,
		duration = 0,
		capturedAt = 0,
		players = {},
		totals = {},
	}
	for _, fight in ipairs(fights) do
		run.duration = run.duration + (fight.duration or 0)
		if (fight.capturedAt or 0) > run.capturedAt then
			run.capturedAt = fight.capturedAt
		end
		if fight.zone and not run.zone then
			run.zone = fight.zone
		end
		for key, value in pairs(fight.totals or {}) do
			run.totals[key] = (run.totals[key] or 0) + value
		end
		for guid, p in pairs(fight.players) do
			local rp = run.players[guid]
			if not rp then
				rp = {
					guid = guid, name = p.name, class = p.class, role = p.role,
					specID = p.specID, ilvl = p.ilvl,
					isLocalPlayer = p.isLocalPlayer, metrics = {},
				}
				run.players[guid] = rp
			end
			-- Later fights carry fresher identity (mid-run spec swaps)
			rp.role = p.role or rp.role
			rp.specID = p.specID or rp.specID
			rp.ilvl = p.ilvl or rp.ilvl
			for key, value in pairs(p.metrics) do
				rp.metrics[key] = (rp.metrics[key] or 0) + value
			end
		end
	end
	return run
end
