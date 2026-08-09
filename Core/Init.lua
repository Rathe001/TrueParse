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
	-- error sink: persists so a capture handed over carries its own crash log
	self.db.global.errors = self.db.global.errors or {}
	TP.TrapInit(self.db.global.errors)
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
		local found, checked, callErr = {}, 0, nil
		for spellId in pairs(list) do
			checked = checked + 1
			local ok, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellId)
			if not ok then
				-- a REFUSED call and a wrong id both produced "not up"
				-- before, which is the difference between "fix the data
				-- file" and "this approach is dead on Midnight"
				callErr = callErr or tostring(aura)
			elseif aura then
				found[#found + 1] = tostring(spellId)
			end
		end
		self:Print(("  Watching %d mitigation buff ids; %d up right now%s"):format(
			checked, #found, #found > 0 and (": " .. table.concat(found, ", ")) or ""))
		if #found > 0 then
			return
		end
		-- None of the watched ids are up. Testing a guessed list can only
		-- ever say "no" (Josh 2026-07-29: his Prot Paladin read 0 of 6 with
		-- the buff visibly up on a training dummy), so DUMP what the player
		-- actually has instead - press the button, run this, read the id off
		-- the list and the data file can be corrected from evidence.
		self:Print("  None up. Press your active-mitigation button and run this again;"
			.. " your current buffs are listed below - the id you want is in here.")
		local IsSecret = TP.Compat.IsSecret
		-- SUMMARISE, don't flood (Josh 2026-07-29: 40 identical
		-- "<secret> = <secret>" rows pushed the one line that mattered off
		-- the top of the chat frame). Readable ids are the whole point, so
		-- print those and count the rest.
		local secretCount = 0
		local readable = {}
		local function show(id, name)
			if IsSecret(id) then
				secretCount = secretCount + 1
				return
			end
			-- collected, not printed one-per-line: a dozen rows scroll the
			-- verdict off the chat frame (Josh 2026-07-29, twice)
			readable[#readable + 1] = IsSecret(name) and tostring(id)
				or ("%s(%s)"):format(tostring(id), tostring(name))
		end
		-- Report WHY nothing listed rather than falling silent (Josh
		-- 2026-07-29: the first cut printed the header and then nothing,
		-- which says "no buffs" when it actually meant "the call failed").
		-- Two APIs, because a nil function inside pcall looks exactly like
		-- an empty aura list from the outside.
		local seen, firstErr = 0, nil
		if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
			for i = 1, 40 do
				local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
				if not ok then
					firstErr = firstErr or tostring(aura)
					break
				end
				if not aura then
					break
				end
				show(aura.spellId, aura.name)
				seen = seen + 1
			end
		else
			firstErr = "C_UnitAuras.GetAuraDataByIndex missing"
		end
		if seen == 0 and UnitBuff then
			for i = 1, 40 do
				local ok, name, _, _, _, _, _, _, _, spellId = pcall(UnitBuff, "player", i)
				if not ok then
					firstErr = firstErr or tostring(name)
					break
				end
				if not name then
					break
				end
				show(spellId, name)
				seen = seen + 1
			end
		end
		-- four per line keeps the whole thing on screen next to the verdict
		for i = 1, #readable, 4 do
			local chunk = {}
			for j = i, math.min(i + 3, #readable) do
				chunk[#chunk + 1] = readable[j]
			end
			self:Print("    " .. table.concat(chunk, "  "))
		end
		-- VERDICT LAST: this is the line that decides whether the data file
		-- needs corrected ids or the approach is dead on Midnight, so it
		-- must be the one still on screen.
		-- seen counts auras, NOT readable ones: incrementing it per aura
		-- while show() tallied secrets separately double-counted the total
		-- and reported every secret id as readable (Josh 2026-07-29: "28
		-- auras seen, 14 with a readable id" for 14 auras, all secret),
		-- which sent the verdict down the wrong branch entirely.
		self:Print(("  => %d auras seen, %d with a readable id, %d secret%s"):format(
			seen, #readable, secretCount,
			firstErr and (" [" .. firstErr .. "]") or ""))
		if callErr then
			self:Print("  => VERDICT: the aura lookup is REFUSED, not empty: " .. callErr)
		elseif #readable == 0 then
			self:Print("  => VERDICT: lookup works, but every aura id is secret -"
				.. " we cannot discover the id from the client.")
		else
			self:Print("  => VERDICT: lookup works and ids are readable -"
				.. " the watched id is simply wrong.")
		end
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
		-- absorbs too (2026-07-30): a boss-granted shield is credited to
		-- whoever WEARS it, so it reads as healing that player never did.
		-- Naming it here is how it gets retired.
		top(TP.AbsorbSpells, "Top absorb shields this session:")
		-- by-TARGET for the last pull only: this is the line that can be
		-- diffed straight against a WCL "Damage Done -> by Target" table,
		-- which is how the Paragons over-count gets pinned down instead of
		-- reasoned about from raid totals (2026-07-31).
		do
			local list = {}
			for npc, total in pairs(TP.DoneByTarget or {}) do
				list[#list + 1] = { npc = npc, total = total }
			end
			if #list > 0 then
				table.sort(list, function(a, b)
					return a.total > b.total
				end)
				local sum = 0
				for _, e in ipairs(list) do
					sum = sum + e.total
				end
				self:Print(("Group damage by target, LAST PULL (total %s):")
					:format(TP.FormatNumber(sum)))
				for i = 1, math.min(15, #list) do
					local e = list[i]
					self:Print(("  %d. npc %s - %s (%.1f%%)"):format(
						i, e.npc, TP.FormatNumber(e.total), e.total / sum * 100))
				end
			end
		end
		if not next(TP.DoneSpells or {}) and not next(TP.HealSpells or {})
			and not next(TP.AbsorbSpells or {}) then
			self:Print("No spell damage, healing or absorbs recorded this session.")
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
	elseif cmd == "diag" then
		-- One umbrella over every diagnostic, so there is one command to
		-- remember instead of six. The sections keep working as top-level
		-- commands too (habits are already formed, and breaking them buys
		-- nothing) - this just routes to the same code rather than copying it.
		local section = rest:match("^(%S*)") or ""
		if TP.DIAG_SECTIONS[section] then
			return self:HandleSlash(section .. " " .. rest:sub(#section + 1))
		end
		if section == "copy" then
			TP.ShowDiagString()
			return
		end
		-- Everything a bug report needs, in one paste: what is running, and
		-- what has thrown. The errors persist in SavedVariables, so this is
		-- also what a handed-over capture carries with it.
		self:Print(("TrueParse %s%s on %s (interface %s)"):format(
			TP.AddonVersion and TP.AddonVersion() or "?",
			TP.BUILD and (" @" .. TP.BUILD .. " " .. (TP.BUILD_BRANCH or "?")) or "",
			TP.Compat.IS_RETAIL and "retail" or "mists",
			tostring((GetBuildInfo and select(4, GetBuildInfo())) or "?")))
		local nf = TP.FightHistory and #(TP.FightHistory.fights or {}) or 0
		local nu = 0
		for _ in pairs(TP.Sync.users or {}) do
			nu = nu + 1
		end
		self:Print(("  %d captures held, %d addon peers seen this session"):format(nf, nu))
		if rest == "reset" then
			wipe(self.db.global.errors)
			self:Print("  Error log cleared.")
			return
		end
		local errs = self.db.global.errors or {}
		if #errs == 0 then
			self:Print("  No errors recorded. (/tp diag reset clears the log.)")
			return
		end
		self:Print(("  |cffff6666%d distinct error(s) recorded:|r"):format(#errs))
		for i, e in ipairs(errs) do
			self:Print(("   %d. %s x%d - last %s%s"):format(
				i, e.context or "?", e.count or 1,
				date("%m/%d %H:%M", e.last or 0),
				e.build and (" on @" .. e.build) or (e.version and (" on v" .. e.version) or "")))
			self:Print("      " .. tostring(e.msg))
		end
		self:Print("  /tp diag copy - all of this as one pasteable line")
	elseif cmd == "who" then
		-- Who in the group is running TrueParse, on what build, and what they
		-- announced about themselves. Added 2026-07-31: `hasAddon` alone could
		-- not tell "old version" from "uninstalled", and an evening went into
		-- theorising about the wire when this one line would have answered it.
		local roster, rows = TP.Roster.players or {}, {}
		local myGUID = UnitGUID("player")
		for guid, info in pairs(roster) do
			local u = TP.Sync.users[guid]
			local me = guid == myGUID
			rows[#rows + 1] = {
				name = TP.ShortName(info.name) or "?",
				role = info.role or "?",
				spec = info.specID,
				ilvl = info.ilvl,
				ver = me and TP.AddonVersion() or (u and u.addonVersion),
				client = me and (TP.Compat.IS_RETAIL and "retail" or "mists") or (u and u.client),
				build = me and TP.BUILD or nil,
				-- RECENTLY heard, not ever-heard: a peer who logged off or
				-- disabled the addon kept counting all night, which is exactly
				-- the ambiguity this command was added to kill
				has = me or (TP.Sync.HeardRecently and TP.Sync:HeardRecently(guid)) or false,
				-- ...and when absent, say WHICH kind: never heard from at all,
				-- or heard earlier and since gone quiet
				quietFor = (not me) and TP.Sync.SecondsSinceHeard
					and TP.Sync:SecondsSinceHeard(guid) or nil,
			}
		end
		if #rows == 0 then
			self:Print("Not in a group.")
			return
		end
		table.sort(rows, function(a, b)
			if a.has ~= b.has then
				return a.has
			end
			return a.name < b.name
		end)
		local n = 0
		for _, r in ipairs(rows) do
			if r.has then
				n = n + 1
			end
		end
		self:Print(("TrueParse in your group: %d of %d"):format(n, #rows))
		for _, r in ipairs(rows) do
			local specName
			if r.spec and GetSpecializationInfoByID then
				local ok, _, nm = pcall(GetSpecializationInfoByID, r.spec)
				specName = ok and nm or nil
			end
			self:Print(("  %-14s %-7s %-18s %s"):format(
				r.name:sub(1, 14), r.role:sub(1, 7),
				("%s%s"):format(specName or (r.spec and ("spec " .. r.spec)) or "?",
					(r.ilvl and r.ilvl > 0) and (" i" .. r.ilvl) or ""),
				r.has and ("v" .. (r.ver or "?")
					.. (r.client and (" " .. r.client) or "")
					.. (r.build and (" |cff888888@" .. r.build .. "|r") or ""))
					or (r.quietFor
						and ("|cffb0a040quiet %dm (v%s)|r"):format(
							math.floor(r.quietFor / 60), r.ver or "?")
						or "|cff808080no addon|r")))
		end
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
		self:Print("  /tp diag - build, errors and every diagnostic below")
		self:Print("    diag copy - all of it as one pasteable line")
		self:Print("    diag who / mit / procs / baddies / buffs / fights")
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
