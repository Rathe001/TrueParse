-- End-of-run report card: aggregates every fight captured during the
-- current instance visit, grades the whole run, and prints the summary
-- (auto on dungeon/key completion, or /tp run any time).
local _, TP = ...

local RunSummary = {}
TP.RunSummary = RunSummary

local currentInstance -- { name, enteredAt }

local function updateInstance()
	local name, instanceType = GetInstanceInfo()
	if instanceType == "party" or instanceType == "raid" or instanceType == "scenario" then
		if not currentInstance or currentInstance.name ~= name then
			currentInstance = { name = name, enteredAt = time() }
		end
	else
		currentInstance = nil
	end
end

local function collectRunFights()
	if not currentInstance then
		return nil
	end
	local fights = {}
	for _, fight in ipairs(TP.FightHistory.fights) do
		if fight.zone == currentInstance.name and (fight.capturedAt or 0) >= currentInstance.enteredAt then
			fights[#fights + 1] = fight
		end
	end
	return fights
end

function RunSummary:Report()
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
			line = line .. " |cffffd700\226\152\133 " .. table.concat(awards[r.guid], ", ") .. "|r"
		end
		TP.Addon:Print(line)
	end
end

function RunSummary:OnEnable()
	LibStub("AceEvent-3.0"):Embed(self)
	self:RegisterEvent("PLAYER_ENTERING_WORLD", updateInstance)
	self:RegisterEvent("ZONE_CHANGED_NEW_AREA", updateInstance)
	-- Auto-report on completion where the client tells us
	pcall(self.RegisterEvent, self, "LFG_COMPLETION_REWARD", function()
		RunSummary:Report()
	end)
	pcall(self.RegisterEvent, self, "CHALLENGE_MODE_COMPLETED", function()
		RunSummary:Report()
	end)
	updateInstance()
end
