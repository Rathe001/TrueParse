-- Per-character career stats: rolling GPA, grade counts, best fight,
-- per-metric averages. Accumulated at capture time into db.char so it
-- survives the fight-history ring buffer. View: /tp career.
local _, TP = ...

local Career = {}
TP.Career = Career

local RECENT_CAP = 40

local function countPlayers(players)
	local n = 0
	for _ in pairs(players) do
		n = n + 1
	end
	return n
end

local function getStore()
	local db = TP.Addon.db.char
	if not db.career then
		db.career = {
			fights = 0, sumScore = 0, gradeCounts = {},
			best = nil, recent = {}, metricSum = {}, metricN = {},
		}
	end
	return db.career
end

local function onFightCaptured(_, fight)
	if countPlayers(fight.players) < 3 then
		return
	end
	local results = TP.Scoring.Engine.ScoreFight(fight, TP.GetScoringOptions())
	local me
	for _, r in ipairs(results) do
		local p = fight.players[r.guid]
		if p and p.isLocalPlayer then
			me = r
			break
		end
	end
	if not me then
		return
	end

	local c = getStore()
	c.fights = c.fights + 1
	c.sumScore = c.sumScore + me.score
	local grade = TP.Scoring.Grades.ForScore(me.score)
	c.gradeCounts[grade] = (c.gradeCounts[grade] or 0) + 1
	if not c.best or me.score > c.best.score then
		c.best = { score = me.score, name = fight.name, when = fight.capturedAt }
	end
	table.insert(c.recent, 1, me.score)
	for i = #c.recent, RECENT_CAP + 1, -1 do
		table.remove(c.recent, i)
	end
	for key, b in pairs(me.breakdown) do
		if b.applicable then
			c.metricSum[key] = (c.metricSum[key] or 0) + b.normalized
			c.metricN[key] = (c.metricN[key] or 0) + 1
		end
	end
end

local function avgRange(list, from, to)
	local sum, n = 0, 0
	for i = from, math.min(to, #list) do
		sum = sum + list[i]
		n = n + 1
	end
	if n == 0 then
		return nil
	end
	return sum / n
end

function Career:PrintSummary()
	local c = TP.Addon.db.char.career
	if not c or c.fights == 0 then
		TP.Addon:Print("No career data yet — go fight something (3+ player groups count).")
		return
	end
	local gpa = c.sumScore / c.fights
	local grade = TP.Scoring.Grades.ForScore(gpa)
	local gr, gg, gb = TP.Scoring.Grades.Color(grade)
	TP.Addon:Print(("Career: |cff%02x%02x%02x%s|r average (%.1f) over %d fights"):format(
		gr * 255, gg * 255, gb * 255, grade, gpa, c.fights))
	if c.best then
		TP.Addon:Print(("  Best: %.0f — %s"):format(c.best.score, c.best.name or "?"))
	end

	local recentAvg = avgRange(c.recent, 1, 10)
	local priorAvg = avgRange(c.recent, 11, 20)
	if recentAvg and priorAvg then
		local delta = recentAvg - priorAvg
		local arrow = delta >= 1 and "|cff4dd94dup|r" or (delta <= -1 and "|cffe64d4ddown|r" or "steady")
		TP.Addon:Print(("  Trend: %s (last 10 avg %.0f vs prior %.0f)"):format(arrow, recentAvg, priorAvg))
	end

	local bestKey, bestAvg, worstKey, worstAvg
	for key, sum in pairs(c.metricSum) do
		local n = c.metricN[key] or 0
		if n >= 5 then
			local avg = sum / n
			if not bestKey or avg > bestAvg then
				bestKey, bestAvg = key, avg
			end
			if not worstKey or avg < worstAvg then
				worstKey, worstAvg = key, avg
			end
		end
	end
	if bestKey and worstKey and bestKey ~= worstKey then
		TP.Addon:Print(("  Strength: %s (avg %.0f) · Focus: %s (avg %.0f)"):format(
			(TP.METRIC_LABELS[bestKey] or bestKey):lower(), bestAvg,
			(TP.METRIC_LABELS[worstKey] or worstKey):lower(), worstAvg))
	end
end

function Career:OnEnable()
	-- Own AceEvent identity (one handler per message per object)
	LibStub("AceEvent-3.0"):Embed(self)
	self:RegisterMessage("TrueParse_FIGHT_CAPTURED", onFightCaptured)
end
