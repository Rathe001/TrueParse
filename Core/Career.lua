-- Per-character career stats: rolling GPA, grade counts, best fight,
-- per-metric averages. Accumulated at capture time into db.char so it
-- survives the fight-history ring buffer. View: /tp career.
local _, TP = ...

local Career = {}
TP.Career = Career

local RECENT_CAP = 40

-- Career totals are ACCUMULATED at capture time, so they freeze whatever the
-- scoring said on the day. Fight scores do not: they are recomputed from the
-- stored raw metrics every time a card is drawn, so after a calibration change
-- the same fights re-grade while the career GPA does not - and /tp career ends
-- up disagreeing with the scorecard it came from.
-- Bump this whenever scoring moves enough to invalidate accumulated totals;
-- the stats reset once and re-accumulate honestly under the new rules
-- (Josh 2026-07-28: "reset them on login and let them reaccumulate").
-- Bumped 2026-08-01: tank damage moved to a group-mean multiple, five-man
-- healers to intake coverage, and tier 1 gained gear normalisation. All three
-- change what a score MEANS, so averaging career stats across the boundary
-- compares two different scales. Josh would have hit this silently after
-- reloading, since per-fight cards rescore live but career totals accumulate
-- at capture and never revisit.
-- Bumped 2026-08-08: retail tanks stopped being graded on active-mitigation
-- uptime, and its 0.55 moved to damage and healing. WCL's ranked field for that
-- metric is saturated (every ranked tank holds it ~99%, so the anchor bands are
-- 1.3 and 0.6 points wide) and could not separate anybody. Measured on real
-- captures, individual retail tank rows move -45.8 to +53.7 and the p25-p75
-- span widens 22.6 -> 36.1 points, so a tank's career GPA would otherwise
-- average two incompatible definitions of the same number. Retail tanks are the
-- only rows affected; everyone else resets for consistency, which is the cost of
-- the epoch being global.
local SCORING_EPOCH = "2026-08-08-retail-tank-mitigation"

local function countPlayers(players)
	local n = 0
	for _ in pairs(players) do
		n = n + 1
	end
	return n
end

local function freshStore()
	return {
		fights = 0, sumScore = 0,
		best = nil, recent = {}, metricSum = {}, metricN = {},
		epoch = SCORING_EPOCH,
	}
end

local function getStore()
	local db = TP.Addon.db.char
	-- a store from an older scoring epoch holds numbers the current engine
	-- would never produce: start it over rather than average across the two
	if not db.career or db.career.epoch ~= SCORING_EPOCH then
		db.career = freshStore()
	end
	return db.career
end

-- Exposed so Init can retire stale totals on login rather than lazily on the
-- next capture, which would otherwise leave /tp career showing old numbers
-- until the player's next boss kill.
function Career.ResetIfStale()
	local db = TP.Addon and TP.Addon.db and TP.Addon.db.char
	if not db then
		return false
	end
	if db.career and db.career.epoch == SCORING_EPOCH then
		return false
	end
	-- a fresh character has nothing to retire: stamp the epoch quietly so the
	-- first login does not announce a reset of stats that never existed
	local hadStats = db.career and (db.career.fights or 0) > 0
	db.career = freshStore()
	return hadStats and true or false
end

local function onFightCaptured(_, fight)
	if countPlayers(fight.players) < 3 then
		return
	end
	if fight.wipe or not TP.CountsInAggregates(fight) then
		return -- wipes and dummy practice are graded on the card but
		-- don't move the career GPA
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
	TP.Addon:Print(("Career: %s average over %d fights"):format(
		TP.Scoring.Grades.ColoredScore(gpa), c.fights))
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
