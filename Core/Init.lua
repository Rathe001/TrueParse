-- TrueParse: group contribution meter.
-- Every file receives (addonName, privateNamespace) as varargs; modules attach
-- themselves to the shared TP table rather than polluting globals.
local ADDON_NAME, TP = ...

TP.Addon = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0")
local Addon = TP.Addon

local defaults = {
	profile = {
		window = {
			point = "CENTER", relPoint = "CENTER", x = 0, y = 0,
			width = 240, height = 200,
			locked = false, shown = true, collapsed = false, autoCollapse = true,
		},
		coach = true,
		toasts = true, -- on-screen flash when you earn an award
		letterGrades = false, -- show D-/C/B+/S letter tiers instead of numbers
		announce = false, -- opt-in: one MVP line to group chat on run completion
		announceSummary = false, -- opt-in: one group strengths/weaknesses line
		minimap = { hide = false },
		bars = {
			height = 18,
			max = 10,
			fontSize = 11,
		},
		history = {
			maxFights = 200,
		},
		scoring = {
			normalizeIlvl = true,
			-- "contribution" = the TrueParse score (everything counts);
			-- "parse" = WCL-style throughput vs top logs, nothing else.
			-- Display lens only: career/coach/run reports always use
			-- contribution.
			mode = "contribution",
		},
		debug = false,
		probe = false,
	},
}

function Addon:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("TrueParseDB", defaults, true)
	self:RegisterChatCommand("trueparse", "HandleSlash")
	self:RegisterChatCommand("tp", "HandleSlash")
	-- /tp baddies curation data survives reloads (account-wide, resettable).
	-- Prune at login so months of raiding can't bloat SavedVariables: keep
	-- the 200 biggest totals (the curation-relevant tail).
	self.db.global.takenSpells = self.db.global.takenSpells or {}
	TP.TakenSpells = self.db.global.takenSpells
	do
		local list = {}
		for id, e in pairs(TP.TakenSpells) do
			list[#list + 1] = { id = id, total = e.total or 0 }
		end
		if #list > 300 then
			table.sort(list, function(a, b)
				return a.total > b.total
			end)
			for i = 201, #list do
				TP.TakenSpells[list[i].id] = nil
			end
		end
	end
end

-- Benchmarks are point-in-time WCL statistics; class tuning drifts every
-- balance patch. Nudge (once per session) when they're getting stale.
local function checkBenchmarkAge()
	local B = TP.Benchmarks
	if not B or not B.generated then
		return
	end
	local y, m, d = B.generated:match("^(%d+)-(%d+)-(%d+)$")
	if not y then
		return
	end
	local ageDays = (time() - time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })) / 86400
	if ageDays >= 60 then
		Addon:Print(("Spec benchmarks are %d days old; grades may drift from current class tuning. Regenerate with scripts\\fetch-benchmarks.ps1 (see README)."):format(ageDays))
	end
end

function Addon:OnEnable()
	if not TP.Compat.IS_RETAIL then
		TP.Scoring.Capabilities.SetMoPRules(true)
	end
	checkBenchmarkAge()
	TP.Roster:OnEnable()
	TP.Segments:OnEnable()
	TP.EnableCombatLog()
	TP.FightHistory:OnEnable()
	TP.CastProbe:OnEnable()
	TP.CoachLine:OnEnable()
	TP.Career:OnEnable()
	TP.AwardToast:OnEnable()
	TP.Sync:OnEnable()
	TP.Readiness:OnEnable()
	TP.RunSummary:OnEnable()
	TP.Options:OnEnable()
	TP.Minimap:OnEnable()
	TP.MeterWindow:OnEnable()
end

-- Base options: what career/coach/run reports score with (always the full
-- contribution model)
function TP.GetScoringOptions()
	return { normalizeIlvl = Addon.db.profile.scoring.normalizeIlvl }
end

-- Display options: the scorecard and /tp score additionally respect the
-- selected score mode (contribution vs WCL-style parse)
function TP.GetDisplayScoringOptions()
	local opts = TP.GetScoringOptions()
	opts.mode = Addon.db.profile.scoring.mode
	return opts
end

function Addon:HandleSlash(input)
	local cmd, rest = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "" then
		TP.MeterWindow:Toggle()
	elseif cmd == "lock" then
		self.db.profile.window.locked = not self.db.profile.window.locked
		self:Print(self.db.profile.window.locked and "Window locked." or "Window unlocked (drag to move).")
	elseif cmd == "reset" then
		local w = self.db.profile.window
		w.point, w.relPoint, w.x, w.y = "CENTER", "CENTER", 0, 0
		TP.MeterWindow:ApplyPosition()
		self:Print("Window position reset.")
	elseif cmd == "debug" then
		self.db.profile.debug = not self.db.profile.debug
		self:Print("Debug " .. (self.db.profile.debug and "on." or "off."))
	elseif cmd == "fights" then
		local fights = TP.FightHistory.fights
		if #fights == 0 then
			self:Print("No fights captured yet.")
		else
			self:Print(("Captured fights (%d, newest first):"):format(#fights))
			for i = 1, math.min(#fights, 10) do
				local f = fights[i]
				local players = 0
				for _ in pairs(f.players) do
					players = players + 1
				end
				self:Print(("  %d. %s — %d:%02d, %d players, dmg %s, heal %s, kicks %d"):format(
					i, f.name, math.floor(f.duration / 60), f.duration % 60, players,
					TP.FormatNumber(f.totals.damage or 0), TP.FormatNumber(f.totals.healing or 0),
					f.totals.interrupts or 0))
			end
		end
	elseif cmd == "config" or cmd == "options" then
		TP.Options.Open()
	elseif cmd == "run" then
		TP.RunSummary:Report()
	elseif cmd == "share" then
		TP.RunSummary:Share()
	elseif cmd == "career" then
		TP.Career:PrintSummary()
	elseif cmd == "trends" then
		TP.Trends:Report()
	elseif cmd == "buffs" then
		TP.Readiness:Report()
	elseif cmd == "baddies" then
		-- curation aid for Data/Avoidable_*.lua: what hurt people today
		if rest == "reset" then
			for k in pairs(TP.TakenSpells or {}) do
				TP.TakenSpells[k] = nil
			end
			self:Print("Damage-taken spell tally reset.")
			return
		end
		local list = {}
		for id, e in pairs(TP.TakenSpells or {}) do
			list[#list + 1] = { id = id, name = e.name, total = e.total, hits = e.hits }
		end
		if #list == 0 then
			self:Print("No spell damage taken recorded this session.")
		else
			table.sort(list, function(a, b)
				return a.total > b.total
			end)
			self:Print("Top damage-taken spells this session (for the avoidable list):")
			for i = 1, math.min(15, #list) do
				local e = list[i]
				self:Print(("  %d. %s (%d) - %s over %d hits%s"):format(
					i, e.name or "?", e.id, TP.FormatNumber(e.total), e.hits,
					(TP.AVOIDABLE and TP.AVOIDABLE[e.id]) and " [avoidable]" or ""))
			end
		end
	elseif cmd == "coach" then
		self.db.profile.coach = not self.db.profile.coach
		self:Print("Post-fight coach line " .. (self.db.profile.coach and "on." or "off."))
	elseif cmd == "announce" then
		self.db.profile.announce = not self.db.profile.announce
		self:Print("Run-MVP group chat announcement "
			.. (self.db.profile.announce and "ON — one line to group chat when a run completes." or "off."))
	elseif cmd == "mode" then
		local s = self.db.profile.scoring
		s.mode = (s.mode == "parse") and "contribution" or "parse"
		if s.mode == "parse" then
			self:Print("Score mode: RAW — pure damage/healing vs Warcraft Logs parses for your spec on this fight. No utility, no penalties.")
		else
			self:Print("Score mode: TRUE — the full TrueParse score (damage, healing, kicks, dispels, soaking, penalties).")
		end
		TP.MeterWindow:UpdateModeButtons()
		TP.MeterWindow:Invalidate()
	elseif cmd == "letters" then
		self.db.profile.letterGrades = not self.db.profile.letterGrades
		self:Print("Letter grades " .. (self.db.profile.letterGrades and "on (F to S+)." or "off (numbers)."))
		TP.MeterWindow:Invalidate()
	elseif cmd == "ilvl" then
		self.db.profile.scoring.normalizeIlvl = not self.db.profile.scoring.normalizeIlvl
		self:Print("Item-level normalization "
			.. (self.db.profile.scoring.normalizeIlvl and "on — grades are relative to gear."
				or "off — grades compare absolute output."))
		TP.MeterWindow:Invalidate()
	elseif cmd == "score" then
		local idx = tonumber(rest) or 1
		local fight = TP.FightHistory.fights[idx]
		if not fight then
			self:Print("No captured fight #" .. idx .. " (see /tp fights).")
		else
			local results = TP.Scoring.Engine.ScoreFight(fight, TP.GetDisplayScoringOptions())
			self:Print(("%s scores — %s (%d:%02d):"):format(
				self.db.profile.scoring.mode == "parse" and "Raw" or "True",
				fight.name, math.floor(fight.duration / 60), fight.duration % 60))
			for i, r in ipairs(results) do
				local penaltyText = r.penalty > 0 and (" |cffff4444(-%.0f)|r"):format(r.penalty) or ""
				self:Print(("  %d. %s %s [%s]%s"):format(
					i, TP.Scoring.Grades.ColoredScore(r.score), r.name, r.role, penaltyText))
			end
		end
	elseif cmd == "probe" then
		if rest == "status" then
			TP.CastProbe:Report(true)
		else
			self.db.profile.probe = not self.db.profile.probe
			self:Print("Cast probe " .. (self.db.profile.probe and "on." or "off."))
		end
	else
		-- /tp help, and the landing spot for any unknown command
		local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
		local version = (getMeta and getMeta(ADDON_NAME, "Version")) or "?"
		self:Print(("TrueParse v%s - commands:"):format(version))
		self:Print("  /tp - toggle the scorecard window")
		self:Print("  /tp config - options panel")
		self:Print("  /tp mode - switch TrueParse/Raw scoring")
		self:Print("  /tp letters - letter grades instead of numbers")
		self:Print("  /tp run - run report · /tp share - post group summary")
		self:Print("  /tp career - your stats · /tp trends - where they're heading")
		self:Print("  /tp fights - capture history · /tp score [n] - rescore one")
		self:Print("  /tp buffs - pre-pull raid buff diagnostic")
		self:Print("  /tp coach · /tp announce · /tp ilvl - toggles")
		self:Print("  /tp lock - lock the window · /tp reset - re-center it")
		self:Print("Bugs: github.com/Rathe001/TrueParse/issues")
	end
end

-- Secret-proof debug print: secret values crash table.concat inside
-- AceConsole, so stringify every arg defensively first.
function Addon:Debug(...)
	if not (self.db and self.db.profile.debug) then
		return
	end
	local IsSecret = TP.Compat.IsSecret
	local out = {}
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		out[i] = IsSecret(v) and "<secret>" or tostring(v)
	end
	self:Print("|cff888888[debug]|r " .. table.concat(out, " "))
end

-- TEMPORARY diagnostics: these events fire synchronously inside the blocked
-- call, so debugstack() here reveals the offending call site. Remove once
-- the load error is fixed.
local diag = CreateFrame("Frame")
diag:RegisterEvent("ADDON_ACTION_FORBIDDEN")
diag:RegisterEvent("ADDON_ACTION_BLOCKED")
diag:SetScript("OnEvent", function(_, event, addonName, func)
	if addonName ~= ADDON_NAME then
		return
	end
	local stack = debugstack(3, 20, 0)
	print("|cffff4444TrueParse diag:|r", event, "->", tostring(func))
	for line in stack:gmatch("[^\n]+") do
		if line:find("TrueParse", 1, true) then
			print("|cffff8888  at:|r", line)
		end
	end
	if Addon.db then
		Addon.db.global.lastBlocked = { event = event, func = tostring(func), stack = stack, when = date() }
	end
end)
