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
		currentInstance = { name = name }
	else
		currentInstance = nil
	end
end

-- The current run = the newest capture's runID streak (FightHistory stamps
-- one per group+instance+difficulty visit — zone alone mixed LFR wings
-- with last week's guild raid in the same instance). Post-raid review from
-- a city still sees the run; inside a DIFFERENT instance it doesn't.
local function collectRunFights()
	local newest = TP.FightHistory.fights[1]
	if not newest or not newest.runID then
		return nil
	end
	if currentInstance and currentInstance.name ~= newest.zone then
		return nil -- we're somewhere else now; that run isn't THIS run
	end
	local fights = {}
	for _, fight in ipairs(TP.FightHistory.fights) do -- newest first
		if fight.runID ~= newest.runID then
			break
		end
		fights[#fights + 1] = fight
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

-- One informative, non-spammy line: group score plus the group's biggest
-- strength and up to three things to work on. Plain text (chat can't color).
-- Scope is stated explicitly ("run so far, N fights") because the scorecard
-- window grades the latest single fight — a different number.
local function composeSummary(run, fightCount, results, groupScore)
	local insights = TP.Scoring.Insights.ForResults(results)
	local msg = ("TrueParse: %s run so far (%d fights) — group score %d/100 (True)."):format(
		run.name or "instance", fightCount, groupScore)
	if insights.strength then
		msg = msg .. (" Strong: %s."):format((TP.METRIC_LABELS[insights.strength] or insights.strength):lower())
	end
	local work = {}
	if insights.weakness then
		work[#work + 1] = (TP.METRIC_LABELS[insights.weakness] or insights.weakness):lower()
	end
	if insights.avoidableHitters >= 2 then
		work[#work + 1] = "avoidable damage"
	end
	local totalDeaths = run.totals and run.totals.deaths or 0
	if totalDeaths >= math.max(3, #results) then
		work[#work + 1] = ("deaths (%d)"):format(totalDeaths)
	end
	if insights.buffsMissing then
		work[#work + 1] = "raid buffs at pull"
	end
	if #work > 0 then
		msg = msg .. " Work on: " .. table.concat(work, ", ", 1, math.min(#work, 3)) .. "."
	end
	return msg
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
	return runForCache.run, #fights
end

-- announce=true (auto triggers only) additionally posts to group chat per
-- the /tp announce (MVP line) and announce-summary settings. Manual /tp run
-- never announces; /tp share posts the summary on demand.
function RunSummary:Report(announce)
	local fights, anchor = collectRunFights()
	if not fights or #fights == 0 then
		TP.Addon:Print("No fights captured in this instance yet.")
		return
	end
	local run = TP.Scoring.Runs.Aggregate(fights, anchor)
	local results = TP.Scoring.Engine.ScoreFight(run, TP.GetScoringOptions())
	if #results == 0 then
		return
	end

	local sum = 0
	for _, r in ipairs(results) do
		sum = sum + r.score
	end
	local groupScore = sum / #results

	TP.Addon:Print(("Run report — %s (%d fights, %d:%02d) · group score %s · True scores, whole run"):format(
		anchor, #fights,
		math.floor(run.duration / 60), run.duration % 60,
		TP.Scoring.Grades.ColoredScore(groupScore)))

	local awards = TP.Scoring.Awards.Compute(run)
	for i, r in ipairs(results) do
		local line = ("  %d. %s %s"):format(
			i, TP.Scoring.Grades.ColoredScore(r.score), r.name)
		if awards[r.guid] then
			line = line .. " " .. TP.STAR .. " |cffffd700" .. table.concat(awards[r.guid], ", ") .. "|r"
		end
		TP.Addon:Print(line)
	end

	if announce and IsInGroup() then
		if TP.Addon.db.profile.announce then
			local mvp = results[1]
			SendChatMessage(("TrueParse run MVP: %s (True %d/100). Group score: %d/100"):format(
				mvp.name, math.floor(mvp.score + 0.5), math.floor(groupScore + 0.5)), groupChannel())
		end
		if TP.Addon.db.profile.announceSummary then
			SendChatMessage(composeSummary(run, #fights, results,
				math.floor(groupScore + 0.5)), groupChannel())
		end
	end
end

-- Manual share: post ONLY the one-line group summary, on demand.
function RunSummary:Share()
	local fights, anchor = collectRunFights()
	if not fights or #fights == 0 then
		TP.Addon:Print("No fights captured in this instance yet.")
		return
	end
	local run = TP.Scoring.Runs.Aggregate(fights, anchor)
	local results = TP.Scoring.Engine.ScoreFight(run, TP.GetScoringOptions())
	if #results == 0 then
		return
	end
	local sum = 0
	for _, r in ipairs(results) do
		sum = sum + r.score
	end
	local line = composeSummary(run, #fights, results, math.floor(sum / #results + 0.5))
	if IsInGroup() then
		SendChatMessage(line, groupChannel())
	else
		TP.Addon:Print(line)
	end
end

function RunSummary:OnEnable()
	LibStub("AceEvent-3.0"):Embed(self)
	self:RegisterEvent("PLAYER_ENTERING_WORLD", updateInstance)
	self:RegisterEvent("ZONE_CHANGED_NEW_AREA", updateInstance)
	-- Auto-report on completion where the client tells us
	pcall(self.RegisterEvent, self, "LFG_COMPLETION_REWARD", function()
		RunSummary:Report(true)
	end)
	pcall(self.RegisterEvent, self, "CHALLENGE_MODE_COMPLETED", function()
		RunSummary:Report(true)
	end)
	updateInstance()
end
