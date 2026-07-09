-- /tp trends: which way your play is going. Rescores the recent fight
-- history for the local player and compares the newest half against the
-- older half — overall score, each metric, deaths per fight — plus where
-- you've been running. Wipes are skipped (they're graded on the card but
-- would poison direction math).
local _, TP = ...

local Trends = {}
TP.Trends = Trends

local MAX_FIGHTS = 20
local METRIC_ORDER = { "damage", "healing", "damageTaken", "interrupts", "dispels", "buffUptime" }

local function directionWord(delta, threshold)
	if delta >= threshold then
		return "|cff4dd94drising|r"
	elseif delta <= -threshold then
		return "|cffe64d4dfalling|r"
	end
	return "|cff999999steady|r"
end

function Trends:Report()
	local myGUID = UnitGUID("player")
	local rows = {}
	for _, fight in ipairs(TP.FightHistory.fights) do
		if #rows >= MAX_FIGHTS then
			break
		end
		if fight.players[myGUID] and not fight.wipe then
			local results = TP.Scoring.Engine.ScoreFight(fight, TP.GetScoringOptions())
			for _, r in ipairs(results) do
				if r.guid == myGUID then
					rows[#rows + 1] = { fight = fight, result = r }
					break
				end
			end
		end
	end

	if #rows < 4 then
		TP.Addon:Print("Not enough recent fights for trends yet — need at least 4 with you on the card.")
		return
	end

	-- rows are newest first; split into recent half vs older half
	local half = math.floor(#rows / 2)
	local function avg(getter, from, to)
		local sum, n = 0, 0
		for i = from, to do
			local v = getter(rows[i])
			if v then
				sum = sum + v
				n = n + 1
			end
		end
		if n == 0 then
			return nil
		end
		return sum / n, n
	end
	local function score(row)
		return row.result.score
	end

	local recentAvg = avg(score, 1, half)
	local olderAvg = avg(score, half + 1, #rows)
	local delta = recentAvg - olderAvg
	local grade = TP.Scoring.Grades.ForScore(recentAvg)
	local gr, gg, gb = TP.Scoring.Grades.Color(grade, recentAvg)
	TP.Addon:Print(("Trends over your last %d fights:"):format(#rows))
	TP.Addon:Print(("  Score: |cff%02x%02x%02x%.0f|r %s (recent %d avg %.0f, before that %.0f)"):format(
		gr * 255, gg * 255, gb * 255, recentAvg, directionWord(delta, 3), half, recentAvg, olderAvg))

	for _, key in ipairs(METRIC_ORDER) do
		local function metric(row)
			local b = row.result.breakdown[key]
			return (b and b.applicable) and b.normalized or nil
		end
		local rAvg, rN = avg(metric, 1, half)
		local oAvg = avg(metric, half + 1, #rows)
		if rAvg and oAvg and rN >= 2 then
			TP.Addon:Print(("  %s: %.0f %s"):format(
				TP.METRIC_LABELS[key] or key, rAvg, directionWord(rAvg - oAvg, 5)))
		end
	end

	local function deaths(row)
		return row.result.penaltyDetail and row.result.penaltyDetail.deaths > 0 and 1 or 0
	end
	local rDeaths = avg(deaths, 1, half)
	local oDeaths = avg(deaths, half + 1, #rows)
	if rDeaths and oDeaths and (rDeaths > 0 or oDeaths > 0) then
		-- inverted: fewer deaths = rising
		TP.Addon:Print(("  Deaths: died in %.0f%% of recent fights %s"):format(
			rDeaths * 100, directionWord(oDeaths - rDeaths, 0.15)))
	end

	-- Where you've been playing, best first
	local zones, zoneOrder = {}, {}
	for _, row in ipairs(rows) do
		local zone = row.fight.zone or "?"
		local z = zones[zone]
		if not z then
			z = { sum = 0, n = 0 }
			zones[zone] = z
			zoneOrder[#zoneOrder + 1] = zone
		end
		z.sum = z.sum + row.result.score
		z.n = z.n + 1
	end
	table.sort(zoneOrder, function(a, b)
		return zones[a].sum / zones[a].n > zones[b].sum / zones[b].n
	end)
	for i = 1, math.min(#zoneOrder, 3) do
		local zone = zoneOrder[i]
		local z = zones[zone]
		if z.n >= 2 then
			TP.Addon:Print(("  %s: avg %.0f over %d fights"):format(zone, z.sum / z.n, z.n))
		end
	end
end
