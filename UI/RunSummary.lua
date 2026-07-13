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

-- One informative, non-spammy line: the WHOLE-group story, not just an
-- average of the parts (2026-07-13). Kill speed vs the group's own
-- parses is the lead when they disagree — that gap IS the group-level
-- finding. Plain text (chat can't color); stays under the 255-char
-- chat limit by construction.
local function composeSummary(run, fights, results, groupScore)
	-- run-level facts the results array can't see
	local kickOpps, kicksLanded, deaths = 0, 0, 0
	local killSum, killN = 0, 0
	for _, f in ipairs(fights) do
		local t = f.totals or {}
		kickOpps = kickOpps + (t.kickOpportunities or 0)
		kicksLanded = kicksLanded + (t.kicksLanded or 0)
		deaths = deaths + (t.deaths or 0)
		local pct = TP.Scoring.Engine.KillSpeedPercentile(f)
		if pct then
			killSum = killSum + pct
			killN = killN + 1
		end
	end
	local a = TP.Scoring.Insights.GroupAnalysis(results,
		{ kickOpps = kickOpps, kicksLanded = kicksLanded, deaths = deaths },
		killN > 0 and killSum / killN or nil)

	local msg = ("TrueParse: %s — group %d/100 over %d fights."):format(
		run.name or "run", groupScore, #fights)
	if a.executionGap and a.executionGap >= 15 then
		msg = msg .. (" Kills came faster than the parses say — execution carried (speed p%d vs output p%d)."):format(
			a.killPct + 0.5, a.outputPct + 0.5)
	elseif a.executionGap and a.executionGap <= -15 then
		msg = msg .. (" Big parses, slow kills (output p%d, speed p%d) — time on target, not throughput."):format(
			a.outputPct + 0.5, a.killPct + 0.5)
	elseif a.killPct then
		msg = msg .. (" Kill speed: faster than %d%% of ranked groups."):format(a.killPct + 0.5)
	end
	if a.kickOpps and a.kickOpps >= 3 then
		msg = msg .. (" Kicks: %d of %d."):format(a.kicksLanded, a.kickOpps)
	end
	if deaths == 0 and #fights > 0 then
		msg = msg .. " Deathless."
	elseif deaths > #results then
		msg = msg .. (" %d deaths."):format(deaths)
	end
	local insights = TP.Scoring.Insights.ForResults(results)
	if insights.weakness then
		msg = msg .. (" Work on: %s."):format(
			(TP.METRIC_LABELS[insights.weakness] or insights.weakness):lower())
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
	return runForCache.run, #fights, fights
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
		-- one announcer per group: defer to a groupmate whose TrueParse
		-- is newer (or equal + lower GUID) — no duplicate lines
		if TP.Sync and TP.Sync.ShouldAnnounce and not TP.Sync:ShouldAnnounce() then
			return
		end
		local lines = {}
		if TP.Addon.db.profile.announce then
			local mvp = results[1]
			-- name the thing that made them MVP, not just the number
			local why
			local bestPct = 0
			for key, b in pairs(mvp.breakdown or {}) do
				if b.applicable and (b.pctile or 0) > bestPct and (b.effectiveWeight or 0) > 0 then
					bestPct = b.pctile
					why = (TP.METRIC_LABELS[key] or key):lower()
				end
			end
			lines[#lines + 1] = ("TrueParse MVP: %s %d/100%s. Group: %d/100."):format(
				mvp.name, math.floor(mvp.score + 0.5),
				why and (" (%s p%d)"):format(why, bestPct + 0.5) or "",
				math.floor(groupScore + 0.5))
		end
		if TP.Addon.db.profile.announceSummary then
			lines[#lines + 1] = composeSummary(run, fights, results,
				math.floor(groupScore + 0.5))
		end
		if #lines == 0 then
			return
		end
		if TP.Compat.IS_RETAIL then
			-- Midnight blocks SendChatMessage from addon-driven code
			-- ("Interface action failed because of an AddOn"): posting
			-- needs a hardware event, so offer a click instead
			self:PromptPost(lines)
		else
			for _, line in ipairs(lines) do
				SendChatMessage(line, groupChannel())
			end
		end
	end
end

-- Retail post prompt: a small click-through so the send happens on a
-- hardware event (the only path Midnight allows). Auto-dismisses.
local prompt
function RunSummary:PromptPost(lines)
	if not prompt then
		prompt = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
		prompt:SetBackdrop({
			bgFile = "Interface\\Buttons\\WHITE8X8",
			edgeFile = "Interface\\Buttons\\WHITE8X8",
			edgeSize = 1,
		})
		prompt:SetBackdropColor(0.04, 0.04, 0.05, 1)
		prompt:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
		prompt:SetSize(260, 54)
		prompt:SetPoint("TOP", UIParent, "TOP", 0, -140)
		prompt:SetFrameStrata("DIALOG")
		prompt.text = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		prompt.text:SetPoint("TOP", 0, -8)
		prompt.text:SetText("Post the TrueParse run summary to group chat?")
		local function makeBtn(label, x)
			local b = CreateFrame("Button", nil, prompt, "UIPanelButtonTemplate")
			b:SetSize(90, 20)
			b:SetPoint("BOTTOM", x, 7)
			b:SetText(label)
			return b
		end
		prompt.post = makeBtn("Post", -50)
		prompt.dismiss = makeBtn("Dismiss", 50)
		prompt.dismiss:SetScript("OnClick", function()
			prompt:Hide()
		end)
		prompt.post:SetScript("OnClick", function()
			-- the click IS the hardware event; sending here is allowed
			for _, line in ipairs(prompt.lines or {}) do
				SendChatMessage(line, groupChannel())
			end
			prompt:Hide()
		end)
	end
	prompt.lines = lines
	prompt:Show()
	C_Timer.After(45, function()
		if prompt and prompt.lines == lines then
			prompt:Hide()
		end
	end)
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
	-- user-initiated (button/slash = hardware event): direct send is fine
	local line = composeSummary(run, fights, results, math.floor(sum / #results + 0.5))
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
