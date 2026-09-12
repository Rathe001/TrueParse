-- End-of-run report card: aggregates every fight captured during the
-- current instance visit, grades the whole run, and prints the summary
-- (auto on dungeon/key completion, or /tp run any time).
local _, TP = ...

local RunSummary = {}
TP.RunSummary = RunSummary

local currentInstance -- { name }

local function updateInstance()
	local name, instanceType = GetInstanceInfo()
	if instanceType == "party" or instanceType == "raid" or instanceType == "scenario" then
		-- the instance name is a SECRET inside retail instances; storing it
		-- raw made the `~=` compare in collectRunFights throw on /tp run
		-- (Josh 2026-07-26 audit). Sanitize on store like FightHistory does.
		currentInstance = { name = (not (TP.Compat and TP.Compat.IsSecret and TP.Compat.IsSecret(name))) and name or nil }
	else
		currentInstance = nil
	end
end

-- The current run = the newest capture's runID streak (FightHistory stamps
-- one per group+instance+difficulty visit — zone alone mixed LFR wings
-- with last week's guild raid in the same instance). Post-raid review from
-- a city still sees the run; inside a DIFFERENT instance it doesn't.
-- The newest capture that belongs to a run at all. A practice session
-- carries no runID, and taking fights[1] blindly made a dummy session
-- after the raid answer "no fights captured" for /tp run and /tp share
-- (audit 2026-09-11).
local function newestRunFight()
	for _, f in ipairs(TP.FightHistory.fights) do
		if f.runID then
			return f
		end
	end
end

local function collectRunFights()
	local newest = newestRunFight()
	if not newest then
		return nil
	end
	if currentInstance and currentInstance.name ~= newest.zone then
		return nil -- we're somewhere else now; that run isn't THIS run
	end
	local fights = {}
	for _, fight in ipairs(TP.FightHistory.fights) do -- newest first
		if fight.runID == newest.runID then
			fights[#fights + 1] = fight
		elseif fight.runID then
			break -- an older run; practice records in between are skipped
		end
	end
	return fights, newest.zone
end

local function groupChannel()
	if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		return "INSTANCE_CHAT"
	elseif IsInRaid() then
		return "RAID"
	end
	return "PARTY"
end

-- Current run as an aggregate fight record, for the scorecard's Run row.
-- Cached until the fight streak changes (this runs on render).
local runCache = {}
function RunSummary:CurrentRun()
	local fights, anchor = collectRunFights()
	if not fights or #fights == 0 then
		return nil
	end
	if runCache.newest ~= fights[1] or runCache.count ~= #fights then
		runCache.newest, runCache.count = fights[1], #fights
		runCache.run = TP.Scoring.Runs.Aggregate(fights, anchor or "Run")
	end
	return runCache.run, #fights
end

-- The run a SPECIFIC fight belongs to, for browsing history: an old LFR
-- card should show ITS run's averages, not whatever run is live now.
local runForCache = {}
function RunSummary:RunFor(fight)
	if not fight or not fight.runID then
		return nil
	end
	local fights = {}
	for _, f in ipairs(TP.FightHistory.fights) do
		if f.runID == fight.runID then
			fights[#fights + 1] = f
		end
	end
	if #fights == 0 then
		return nil
	end
	if runForCache.runID ~= fight.runID or runForCache.count ~= #fights then
		runForCache.runID, runForCache.count = fight.runID, #fights
		runForCache.run = TP.Scoring.Runs.Aggregate(fights, fights[1].zone or "Run")
	end
	return runForCache.run, #fights, fights
end

-- The local run report for /tp run. Group-chat output lives in the
-- Reports panel (channels, confirmations, the no-names house rule);
-- /tp share posts the brag line on demand.
function RunSummary:Report()
	local fights, anchor = collectRunFights()
	if not fights or #fights == 0 then
		TP.Addon:Print("No fights captured in this instance yet.")
		return
	end
	local run = TP.Scoring.Runs.Aggregate(fights, anchor or "Run")
	local results = TP.Scoring.Engine.ScoreFight(run, TP.GetScoringOptions())
	if #results == 0 then
		return
	end

	-- SAME currency as the window's run column: the mean of each
	-- player's per-fight scores. Scoring the summed aggregate saturated
	-- every adjustment at once (a 94/98/73 run read 99) and the report
	-- contradicted the card it sat next to (2026-07-14).
	local sums, counts, names = {}, {}, {}
	for _, f in ipairs(fights) do
		for _, r in ipairs(TP.Scoring.Engine.ScoreFight(f, TP.GetScoringOptions())) do
			sums[r.guid] = (sums[r.guid] or 0) + r.score
			counts[r.guid] = (counts[r.guid] or 0) + 1
			names[r.guid] = r.name
		end
	end
	local rows = {}
	local total, n = 0, 0
	for guid, s in pairs(sums) do
		local mean = s / counts[guid]
		rows[#rows + 1] = { guid = guid, name = names[guid], score = mean }
		total = total + mean
		n = n + 1
	end
	table.sort(rows, function(a, b)
		return a.score > b.score
	end)
	local groupScore = n > 0 and (total / n) or 0

	TP.Addon:Print(("Run report — %s (%d fights, %s) · group score %s · True scores, whole run"):format(
		anchor or "Run", #fights, TP.FormatMMSS(run.duration),
		TP.Scoring.Grades.ColoredScore(groupScore)))

	local awards = TP.Scoring.Awards.Compute(run)
	for i, r in ipairs(rows) do
		local line = ("  %d. %s %s"):format(
			i, TP.Scoring.Grades.ColoredScore(r.score), r.name)
		if awards[r.guid] then
			line = line .. " " .. TP.STAR .. " |cffffd700" .. table.concat(awards[r.guid], ", ") .. "|r"
		end
		TP.Addon:Print(line)
	end

	-- specific pointers, local only: what the run's own numbers say to
	-- change (never role-shaming averages)
	local tips = TP.Scoring.Insights.RunAdvice(fights)
	if #tips > 0 then
		TP.Addon:Print("Pointers:")
		for i = 1, math.min(3, #tips) do
			TP.Addon:Print("  \194\183 " .. tips[i])
		end
	end

	-- week-over-week: this lockout vs the last one
	local ws = TP.Addon.db.global.weekStats
	local wk = TP.FightHistory.WeekKey and TP.FightHistory.WeekKey()
	local w = ws and wk and ws[wk]
	if w and (w.bosses + w.wipes) > 0 then
		local line = ("This week: %d boss%s down, %d wipe%s"):format(
			w.bosses, w.bosses == 1 and "" or "es", w.wipes, w.wipes == 1 and "" or "s")
		if w.scoreN > 0 then
			line = line .. (" \194\183 group %.0f"):format(w.scoreSum / w.scoreN)
			local lw = ws[wk - 1]
			if lw and lw.scoreN and lw.scoreN > 0 then
				line = line .. (" (last week %.0f)"):format(lw.scoreSum / lw.scoreN)
			end
		end
		TP.Addon:Print(line)
	end
end

-- Share to group (2026-07-14 redesign): a brag line, not coaching — the
-- last kill's time vs WCL's ranked kills plus the group score. Pointers
-- and analysis stay in the LOCAL report; pugs get the flex.
function RunSummary:Share()
	local kill
	local newest = newestRunFight()
	for _, f in ipairs(TP.FightHistory.fights) do
		if newest and f.runID and f.runID ~= newest.runID then
			break
		end
		-- practice rides the boss pipeline but is not a kill anyone wants
		-- broadcast; it also carries no runID, so it is walked past here
		-- rather than ending the walk
		if f.isBoss and not f.wipe and TP.CountsInAggregates(f) then
			kill = f
			break
		end
	end
	if not kill then
		TP.Addon:Print("No kills to share yet.")
		return
	end
	local results = TP.Scoring.Engine.ScoreFight(kill, TP.GetScoringOptions())
	-- the same group score the card and the meter row show
	local groupScore = TP.Scoring.Engine.GroupScore(results, kill) or 0
	local d = TP.FormatMMSS(kill.duration or 0)
	local line
	local pct, _, _, bounded = TP.Scoring.Engine.KillSpeedPercentile(kill)
	-- only cite a percentile when it's a real ranking, not a ceiling: a
	-- bounded kill (outside WCL's served fastest 1000) can't be bragged
	if pct and not bounded then
		line = ("TrueParse: %s down in %s — faster than %d%% of ranked kills on Warcraft Logs. Group score %d/100."):format(
			kill.name or "Boss", d, math.floor(pct + 0.5), math.floor(groupScore + 0.5))
	else
		line = ("TrueParse: %s down in %s. Group score %d/100."):format(
			kill.name or "Boss", d, math.floor(groupScore + 0.5))
	end
	if IsInGroup() then
		SendChatMessage(line, groupChannel())
	else
		TP.Addon:Print((line:gsub("^TrueParse: ", "")))
	end
end

function RunSummary:OnEnable()
	LibStub("AceEvent-3.0"):Embed(self)
	self:RegisterEvent("PLAYER_ENTERING_WORLD", updateInstance)
	self:RegisterEvent("ZONE_CHANGED_NEW_AREA", updateInstance)
	-- (completion auto-report + wipe debrief retired 2026-07-25: the
	-- Reports panel's auto-run checkboxes are the one reporting system —
	-- /tp run and /tp share remain as manual commands)
	updateInstance()
end
