-- Aggregates a list of fight records into one synthetic "run" record (same
-- shape as a fight), so the scoring engine and grades work on whole
-- dungeon/raid visits.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Runs = {}
TP.Scoring.Runs = Runs

-- per-fight ratios and timestamps: meaningless when summed across
-- fights, so the aggregate omits them (absent data is always neutral)
local RATIO_METRICS = {
	activityPct = true, mitigationPct = true, overhealPct = true,
	overkillPct = true, manaMinPct = true, dryAt = true,
	dispelReactAvg = true,
}

function Runs.Aggregate(fights, name)
	local run = {
		name = name or "Run",
		isBoss = false,
		isRun = true, -- lets the engine's percentile ladder apply: cohort-
		-- relative run averages handed the best of each role a structural
		-- 100 (a 99 "run parse" on the card)
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
		-- bracket/dungeon matching wants the run's difficulty context;
		-- later fights win (mid-run difficulty swaps are rare but real)
		run.difficulty = fight.difficulty or run.difficulty
		run.difficultyID = fight.difficultyID or run.difficultyID
		run.keystoneLevel = fight.keystoneLevel or run.keystoneLevel
		for key, value in pairs(fight.totals or {}) do
			-- totals now carry non-numeric entries (dispelTypes is a
			-- table): summing them crashed the run card (audit 2026-07-16)
			if type(value) == "number" then
				run.totals[key] = (run.totals[key] or 0) + value
			elseif key == "dispelTypes" then
				local t = run.totals.dispelTypes or {}
				run.totals.dispelTypes = t
				for k in pairs(value) do
					t[k] = true
				end
			end
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
				if key == "buffUptime" then
					-- a 0-1 RATIO: summing gave a 5-fight Aug ~3.0 "uptime"
					-- (scored 100 regardless of play). Duration-weight it.
					rp.uptimeWeighted = (rp.uptimeWeighted or 0) + value * (fight.duration or 0)
				elseif RATIO_METRICS[key] or type(value) ~= "number" then
					-- ratios/timestamps must not sum (audit 2026-07-16:
					-- two fights of 35% overheal read 70% on the run row
					-- and earned a penalty neither fight did; summed
					-- activityPct auto-awarded +4). The aggregate simply
					-- omits them - absent data is always neutral.
				else
					rp.metrics[key] = (rp.metrics[key] or 0) + value
				end
			end
		end
	end
	for _, rp in pairs(run.players) do
		if rp.uptimeWeighted then
			rp.metrics.buffUptime = run.duration > 0 and (rp.uptimeWeighted / run.duration) or nil
			rp.uptimeWeighted = nil
		end
	end
	return run
end
