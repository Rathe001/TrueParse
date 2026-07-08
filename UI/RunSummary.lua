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

-- The current run = the contiguous streak of fights in this instance ending
-- at the newest capture (an hour-plus gap separates distinct visits).
-- Deliberately NOT keyed to "time we zoned in": /reload would reset that and
-- orphan everything already captured.
local MAX_PULL_GAP = 3600

local function collectRunFights()
	if not currentInstance then
		return nil
	end
	local fights = {}
	local previousAt
	for _, fight in ipairs(TP.FightHistory.fights) do -- newest first
		if fight.zone ~= currentInstance.name then
			break -- older fight elsewhere: previous visit boundary
		end
		if previousAt and (previousAt - (fight.capturedAt or 0)) > MAX_PULL_GAP then
			break -- long idle gap: treat as a separate visit
		end
		fights[#fights + 1] = fight
		previousAt = fight.capturedAt or 0
	end
	return fights
end

-- announce=true (auto triggers only) additionally posts one MVP line to
-- group chat when /tp announce is enabled. Manual /tp run never announces.
function RunSummary:Report(announce)
	local fights = collectRunFights()
	if not fights or #fights == 0 then
		TP.Addon:Print("No fights captured in this instance yet.")
		return
	end
	local run = TP.Scoring.Runs.Aggregate(fights, currentInstance.name)
	local results = TP.Scoring.Engine.ScoreFight(run, TP.GetScoringOptions())
	if #results == 0 then
		return
	end

	local sum = 0
	for _, r in ipairs(results) do
		sum = sum + r.score
	end
	local groupGrade = TP.Scoring.Grades.ForScore(sum / #results)
	local ggr, ggg, ggb = TP.Scoring.Grades.Color(groupGrade)

	TP.Addon:Print(("Run report — %s (%d fights, %d:%02d) · group grade |cff%02x%02x%02x%s|r"):format(
		currentInstance.name, #fights,
		math.floor(run.duration / 60), run.duration % 60,
		ggr * 255, ggg * 255, ggb * 255, groupGrade))

	local awards = TP.Scoring.Awards.Compute(run)
	for i, r in ipairs(results) do
		local grade = TP.Scoring.Grades.ForScore(r.score)
		local gr, gg, gb = TP.Scoring.Grades.Color(grade)
		local line = ("  %d. |cff%02x%02x%02x%-2s|r %s (%.0f)"):format(
			i, gr * 255, gg * 255, gb * 255, grade, r.name, r.score)
		if awards[r.guid] then
			line = line .. " " .. TP.STAR .. " |cffffd700" .. table.concat(awards[r.guid], ", ") .. "|r"
		end
		TP.Addon:Print(line)
	end

	if announce and TP.Addon.db.profile.announce and IsInGroup() then
		local mvp = results[1]
		local mvpGrade = TP.Scoring.Grades.ForScore(mvp.score)
		local channel = "PARTY"
		if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
			channel = "INSTANCE_CHAT"
		elseif IsInRaid() then
			channel = "RAID"
		end
		-- plain text only: chat messages can't carry color codes
		SendChatMessage(("TrueParse run MVP: %s — %s (%d). Group grade: %s"):format(
			mvp.name, mvpGrade, math.floor(mvp.score + 0.5), groupGrade), channel)
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
