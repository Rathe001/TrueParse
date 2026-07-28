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
			-- height = header 26 + column labels 11 + mode strip 16 +
			-- padding 6 + 11 row slots (10 players + the Raid row) x 21
			width = 260, height = 290,
			locked = false, shown = true, collapsed = false, autoCollapse = true,
			clickThroughCombat = false,
		},
		-- shareable reports (2026-07-25): per-report channel + auto flag
		-- (auto delivery is always local-only regardless of channel)
		reports = { ["*"] = { channel = "INFO", auto = false } },
	-- (wipeDebrief/announce/announceSummary defaults retired 2026-07-25:
	-- the Reports panel owns chat output; saved values scrubbed at enable)
		-- "Wipe it" header button: records the exact wipe-call moment and
		-- syncs it to every TrueParse in the group (heuristic detection
		-- stays as the fallback). Off by default; Classic only.
		wipeButton = false,
		-- Score raider's-training-dummy sessions as labeled practice
		-- fights (vs the tier's patchwerk anchor). Classic only.
		practiceDummies = true,
		toasts = true, -- on-screen flash when you earn an award
		letterGrades = false, -- show D-/C/B+/S letter tiers instead of numbers
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
	},
}

function Addon:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("TrueParseDB", defaults, true)
	self:RegisterChatCommand("trueparse", "HandleSlash")
	self:RegisterChatCommand("tp", "HandleSlash")
	-- probes retired 2026-07-12 (all experiments concluded); clear the log
	self.db.global.probeLog = nil
	-- /tp baddies curation data survives reloads (account-wide, resettable).
	-- Prune at login so months of raiding can't bloat SavedVariables: keep
	-- the 200 biggest totals (the curation-relevant tail).
	self.db.global.takenSpells = self.db.global.takenSpells or {}
	TP.TakenSpells = self.db.global.takenSpells
	-- /tp procs twins (damage done / healing done by spell): same
	-- account-wide persistence, same login prune
	self.db.global.doneSpells = self.db.global.doneSpells or {}
	self.db.global.healSpells = self.db.global.healSpells or {}
	TP.DoneSpells = self.db.global.doneSpells
	TP.HealSpells = self.db.global.healSpells
	for _, tally in ipairs({ TP.TakenSpells, TP.DoneSpells, TP.HealSpells }) do
		local list = {}
		for id, e in pairs(tally) do
			list[#list + 1] = { id = id, total = e.total or 0 }
		end
		if #list > 300 then
			table.sort(list, function(a, b)
				return a.total > b.total
			end)
			for i = 201, #list do
				tally[list[i].id] = nil
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
	-- retired options must not linger in saved profiles (Josh 2026-07-25:
	-- a stuck-on value with no UI to disable it would be unfixable) — the
	-- defaults are gone too, so nil removes them outright
	self.db.profile.wipeDebrief = nil
	self.db.profile.announce = nil
	self.db.profile.announceSummary = nil
	-- coach chat line retired 2026-07-28: the breakdown card already shows
	-- the advice, so the chat copy was just noise after every pull
	self.db.profile.coach = nil
	checkBenchmarkAge()
	TP.Roster:OnEnable()
	TP.Segments:OnEnable()
	TP.EnableCombatLog()
	TP.FightHistory:OnEnable()
	TP.Career:OnEnable()
	-- career totals are accumulated at capture, so a scoring change leaves
	-- them averaging old numbers against new ones; retire them once per
	-- scoring epoch and say so, otherwise it just reads as lost data
	if TP.Career.ResetIfStale() then
		self:Print("Scoring changed - career stats reset and will re-accumulate.")
	end
	TP.AwardToast:OnEnable()
	TP.Sync:OnEnable()
	TP.Readiness:OnEnable()
	TP.RunSummary:OnEnable()
	TP.ReportsUI:OnEnable()
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
	elseif cmd == "mit" then
		-- Mitigation tracking is self-reported and silent when it fails: a
		-- wrong buff id or a spec that doesn't read as TANK both just produce
		-- no number. This says which, in one line, while standing in the
		-- world (Josh 2026-07-28: a tank showing 0% uptime).
		local role = TP.SelfCasts and TP.SelfCasts.DebugRole and TP.SelfCasts.DebugRole()
		self:Print(("Spec role reads: %s"):format(tostring(role)))
		if role ~= "TANK" then
			self:Print("  Not a tank spec, so mitigation is not tracked (expected).")
			return
		end
		local list = TP.MITIGATION_BUFFS or {}
		local found, checked = {}, 0
		for spellId in pairs(list) do
			checked = checked + 1
			local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellId)
			local name = C_Spell and C_Spell.GetSpellName and select(1, pcall(C_Spell.GetSpellName, spellId))
			if ok and aura then
				found[#found + 1] = tostring(spellId)
			end
		end
		self:Print(("  Watching %d mitigation buff ids; %d up right now%s"):format(
			checked, #found, #found > 0 and (": " .. table.concat(found, ", ")) or ""))
		self:Print("  Use your active-mitigation button, then run this again -"
			.. " if the count stays 0 the id for your spec is wrong.")
	elseif cmd == "mock" then
		if rest == "clear" then
			TP.MockFight:Clear()
		else
			TP.MockFight:Inject()
		end
	elseif cmd == "probe" then
		TP.TankProbe:Toggle()
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
	elseif cmd == "procs" then
		-- curation aid for Data/ProcExclusions_*.lua: top damage and
		-- healing sources this session, IDs included
		if rest == "reset" then
			for k in pairs(TP.DoneSpells or {}) do
				TP.DoneSpells[k] = nil
			end
			for k in pairs(TP.HealSpells or {}) do
				TP.HealSpells[k] = nil
			end
			self:Print("Damage/healing source tallies reset.")
			return
		end
		local function top(tally, label)
			local list = {}
			for id, e in pairs(tally or {}) do
				list[#list + 1] = { id = id, name = e.name, total = e.total }
			end
			if #list == 0 then
				return
			end
			table.sort(list, function(a, b)
				return a.total > b.total
			end)
			self:Print(label)
			for i = 1, math.min(12, #list) do
				local e = list[i]
				local excluded = TP.IsExcludedProc and TP.IsExcludedProc(e.id, e.name)
				self:Print(("  %d. %s (%d) - %s%s"):format(
					i, e.name or "?", e.id, TP.FormatNumber(e.total),
					excluded and " [excluded]" or ""))
			end
		end
		top(TP.DoneSpells, "Top damage sources this session (for proc exclusions):")
		top(TP.HealSpells, "Top healing sources this session:")
		if not next(TP.DoneSpells or {}) and not next(TP.HealSpells or {}) then
			self:Print("No spell damage or healing recorded this session.")
		end
	elseif cmd == "guild" then
		-- weekly standings across TrueParse users heard this session
		local wk = TP.FightHistory.WeekKey and TP.FightHistory.WeekKey()
		local rows = {}
		local mw = self.db.global.myWeek
		if mw and mw.week == wk and mw.fights > 0 then
			rows[#rows + 1] = { name = UnitName("player") .. " (you)",
				gpa = mw.scoreSum / mw.fights, fights = mw.fights, tops = mw.tops }
		end
		for _, e in pairs((TP.Sync and TP.Sync.weekBoard) or {}) do
			if e.week == wk then
				rows[#rows + 1] = { name = e.name, gpa = e.gpa, fights = e.fights, tops = e.tops }
			end
		end
		if #rows == 0 then
			self:Print("No TrueParse standings heard yet this week - they arrive as groupmates with the addon finish fights.")
			return
		end
		table.sort(rows, function(a, b)
			return (a.gpa or 0) > (b.gpa or 0)
		end)
		self:Print("This week's TrueParse standings:")
		for i, r in ipairs(rows) do
			-- synced week-board rows can carry nil numeric fields (a
			-- malformed/old-version peer payload); default them so /tp guild
			-- never errors on someone else's data (Josh 2026-07-26 audit)
			self:Print(("  %d. %s %s - %d fights%s"):format(
				i, TP.Scoring.Grades.ColoredScore(r.gpa or 0), r.name or "?", r.fights or 0,
				(r.tops or 0) > 0 and (", top of the card %dx"):format(r.tops) or ""))
		end
	elseif cmd == "announce" then
		self:Print("Announcements moved to the Reports panel (chat icon on the meter, or /tp reports).")
	elseif cmd == "reports" then
		if TP.ReportsUI then
			TP.ReportsUI.Toggle()
		end
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
	else
		-- /tp help, and the landing spot for any unknown command
		local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
		local version = (getMeta and getMeta(ADDON_NAME, "Version")) or "?"
		self:Print(("TrueParse v%s - commands:"):format(version))
		self:Print("  /tp - toggle the scorecard window")
		self:Print("  /tp config - options panel")
		self:Print("  /tp mode - switch TrueParse/Raw scoring")
		self:Print("  /tp letters - letter grades instead of numbers")
		self:Print("  /tp run - run report · /tp share - post last kill vs WCL · /tp guild - weekly standings")
		self:Print("  /tp career - your stats · /tp trends - where they're heading")
		self:Print("  /tp fights - capture history · /tp score [n] - rescore one")
		self:Print("  /tp buffs - pre-pull raid buff diagnostic")
		self:Print("  /tp announce · /tp ilvl - toggles")
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

-- Taint diagnostics: these events fire synchronously inside the blocked
-- call, so debugstack() reveals the offending call site. The chat spew is
-- gated behind /tp debug (Josh 2026-07-26 audit: it was printing red text
-- to every user's chat in the public build); the silent SavedVariables
-- record stays so a block can be inspected after the fact with /tp debug.
local diag = CreateFrame("Frame")
diag:RegisterEvent("ADDON_ACTION_FORBIDDEN")
diag:RegisterEvent("ADDON_ACTION_BLOCKED")
diag:SetScript("OnEvent", function(_, event, addonName, func)
	if addonName ~= ADDON_NAME then
		return
	end
	local stack = debugstack(3, 20, 0)
	if Addon.db and Addon.db.profile.debug then
		print("|cffff4444TrueParse diag:|r", event, "->", tostring(func))
		for line in stack:gmatch("[^\n]+") do
			if line:find("TrueParse", 1, true) then
				print("|cffff8888  at:|r", line)
			end
		end
	end
	if Addon.db then
		Addon.db.global.lastBlocked = { event = event, func = tostring(func), stack = stack, when = date() }
	end
end)
