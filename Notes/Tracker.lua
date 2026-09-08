-- Decides what the Notes view shows: which dungeon, which difficulty, which
-- stretch of trash, which boss. Everything it reads is non-combat data; the
-- few values that could be secret are checked before use. Rendering is the
-- meter window's job: this file hands it row descriptors via Rows() and
-- pokes it with Invalidate() when the state changes.
local _, TP = ...
local KN = TP.Notes

local Tracker = {}
KN.Tracker = Tracker

local IsSecret = KN.IsSecret

local state = {
	dungeon = nil,     -- data def from KN.instances
	diff = "m",        -- "n" | "h" | "m" | "k"
	difficultyID = nil,
	bosses = nil,      -- journal list (Journal.Bosses)
	killed = 0,        -- ENCOUNTER_END successes this run
	leg = 1,           -- 1 = before boss 1; manual paging overrides killed+1
	manualLeg = nil,
	boss = nil,        -- data boss entry while an encounter is running
	journalBoss = nil,
	affixes = nil,     -- { {name=, icon=} }, keystone only
	keyLevel = nil,
	preview = false,   -- /tp notes show <name> outside the instance
	inDungeon = false,
}
Tracker.state = state

local function plain(v)
	if v == nil or IsSecret(v) then return nil end
	return v
end

local function diffOK(min)
	local need = KN.DIFF_RANK[min or "n"] or 1
	return (KN.DIFF_RANK[state.diff] or 3) >= need
end

-- A note's `affix` = "Tyrannical" | "Fortified" | "Devour" ... shows only on
-- that week. Outside a key there are no affixes: boss-week lines show (a
-- dungeon run lusts bosses), Fortified-only lines don't.
local function affixOK(key)
	if not key then return true end
	if state.affixes == nil then return key ~= "Fortified" end
	for _, a in ipairs(state.affixes) do
		if a.name:find(key, 1, true) then return true end
	end
	return false
end

local function findDataBoss(name)
	if not (state.dungeon and name) then return nil end
	local lname = name:lower()
	for i, b in ipairs(state.dungeon.bosses) do
		local bn = b.name:lower()
		if bn == lname or lname:find(bn, 1, true) or bn:find(lname, 1, true) then
			return b, i
		end
	end
	return nil
end

local function findJournalBoss(name)
	if not (state.bosses and name) then return nil end
	local lname = name:lower()
	for _, jb in ipairs(state.bosses) do
		local jn = jb.name:lower()
		if jn == lname or lname:find(jn, 1, true) or jn:find(lname, 1, true) then
			return jb
		end
	end
	return nil
end

---------------------------------------------------------------------------
-- Rows (see View.lua for the descriptor shapes)
---------------------------------------------------------------------------

-- Role, capability, class and week filter. Core rows never pass through
-- here: the fight is everyone's.
local function forMe(entry)
	if not KN.Player.RoleMatches(entry.role) then return false end
	if entry.class and entry.class ~= KN.Player.Class() then return false end
	if not affixOK(entry.affix) then return false end
	local need = entry.need
	if need == nil then return true end
	if type(need) == "table" then
		for _, n in ipairs(need) do
			if KN.Player.Can(n) then return true end
		end
		return false
	end
	return KN.Player.Can(need)
end

local TAG_NEED = {
	KICK = "kick", PURGE = "purge", STUN = "stun", SOOTHE = "soothe", LUST = "lust",
	MAGIC = "magic", CURSE = "curse", POISON = "poison", DISEASE = "disease",
	FEAR = "fear", MASSDISP = "massdispel",
}
local function pickTag(n)
	if not n.tag then return nil end
	local list = type(n.tag) == "table" and n.tag or { n.tag }
	for _, tag in ipairs(list) do
		local need = TAG_NEED[tag]
		if not need or KN.Player.Can(need) then return tag end
	end
	return nil
end

local function decorate(row, n)
	local tag = pickTag(n)
	if not tag then return row end
	local def = KN.TAGS[tag]
	row.icon = KN.ICONS[tag]
	row.rgb = def and def.rgb
	row.label = KN.Player.Label(tag) or (def and def.label)
	return row
end

local function noteHidden(n, jb)
	if not diffOK(n.min) then return true end
	if not forMe(n) then return true end
	if n.ability and jb and KN.Journal.AbilityHidden(jb, n.ability) then return true end
	return false
end

local function addCoreRows(rows, b, jb)
	if not b.core then return 0 end
	if b.coreMin and not diffOK(b.coreMin) then return 0 end
	if b.coreAbility and jb and KN.Journal.AbilityHidden(jb, b.coreAbility) then return 0 end
	local lines = type(b.core) == "table" and b.core or { b.core }
	for i, text in ipairs(lines) do
		rows[#rows + 1] = { type = "core", text = text, num = i }
	end
	return #lines
end

-- "BOSS 2 OF 3  Atroxus" (or "NEXT · BOSS 2 OF 3" on a trash stretch), the
-- numbered core lines, then a YOURS section with the lines that are yours.
local function addBossRows(rows, b, idx, jb, fullNotes)
	local n = #state.dungeon.bosses
	local where = "Boss " .. (idx or "?") .. " of " .. n
	rows[#rows + 1] = { type = "section", label = fullNotes and where or ("Next · " .. where), name = b.name }
	local cores = addCoreRows(rows, b, jb)
	if not fullNotes then return end
	local mine = {}
	for _, x in ipairs(b.notes or {}) do
		if not noteHidden(x, jb) then
			mine[#mine + 1] = decorate({ type = "note", text = x.text }, x)
		end
	end
	if #mine > 0 then
		rows[#rows + 1] = { type = "section", label = "Yours", text = "" }
		for _, r in ipairs(mine) do rows[#rows + 1] = r end
	elseif cores == 0 then
		rows[#rows + 1] = { type = "note", text = "nothing extra at this difficulty" }
	end
end

local function legLabel()
	local d = state.dungeon
	local n = #d.bosses
	local leg = state.leg
	if leg <= 1 then
		return "to " .. d.bosses[1].name
	elseif leg > n then
		return "after " .. d.bosses[n].name
	end
	return d.bosses[leg - 1].name .. " → " .. d.bosses[leg].name
end

-- Trash notes are a Mythic+ feature (Josh 2026-09-08): route knowledge is
-- what they are for, and outside a key nobody is routing. A raid never has
-- them at all - RegisterRaid refuses a trash table.
local function trashApplies()
	local d = state.dungeon
	return d ~= nil and d.kind ~= "raid" and d.trash ~= nil and state.diff == "k"
end

local function addTrashRows(rows)
	local d = state.dungeon
	if trashApplies() then
		rows[#rows + 1] = { type = "section", label = "Trash", text = legLabel() }
		local any = false
		for _, t in ipairs(d.trash) do
			local inLeg = (t.leg == nil) or (t.leg == state.leg)
			if inLeg and diffOK(t.min) and forMe(t) then
				if t.name then
					rows[#rows + 1] = decorate({ type = "mob", name = t.name, text = t.text }, t)
				else
					rows[#rows + 1] = decorate({ type = "note", text = t.text }, t)
				end
				any = true
			end
		end
		if not any then
			rows[#rows + 1] = { type = "note", text = "nothing noted for this stretch" }
		end
	end
	-- A raid's boss order is not a line. Wings can be cleared either way
	-- round, and `killed` is only a count, so naming one boss "next" would
	-- be a guess we cannot back up. List them and let ENCOUNTER_START pick
	-- the real one the moment a pull starts.
	if d.kind == "raid" then
		rows[#rows + 1] = { type = "section", label = "Bosses", text = d.name }
		for i, b in ipairs(d.bosses) do
			rows[#rows + 1] = { type = "note", text = i .. ". " .. b.name }
		end
		return
	end
	local nextBoss = d.bosses[state.leg]
	if nextBoss then
		addBossRows(rows, nextBoss, state.leg, findJournalBoss(nextBoss.name), false)
	end
end

local function addHeader(rows)
	local d = state.dungeon
	local affixes
	if state.affixes then
		affixes = {}
		for _, a in ipairs(state.affixes) do
			local def = KN.AffixDef(a.name)
			affixes[#affixes + 1] = {
				icon = a.icon,
				name = def and def.key or a.name,
				rgb = def and def.rgb,
				short = def and def.short or "",
			}
		end
	end
	rows[#rows + 1] = {
		type = "header", name = d.name, diff = state.diff,
		level = state.diff == "k" and state.keyLevel or nil,
		spec = KN.Player.SpecName(), role = KN.Player.RoleLine(), affixes = affixes,
	}
end

-- nil when there is nothing to show (not in a dungeon we have notes for)
function Tracker.Rows()
	local d = state.dungeon
	if not d then return nil end
	local rows = {}
	addHeader(rows)
	if state.boss then
		local _, idx = findDataBoss(state.boss.name)
		addBossRows(rows, state.boss, idx, state.journalBoss, true)
	else
		addTrashRows(rows)
	end
	return rows
end

-- The window re-renders on the next refresh; nothing to do unless the Notes
-- view is the one showing.
function Tracker.Render()
	if KN.ViewIsNotes() and TP.MeterWindow and TP.MeterWindow.Invalidate then
		if TP.MeterWindow.ResetNotesScroll then TP.MeterWindow:ResetNotesScroll() end
		TP.MeterWindow:Invalidate()
	end
end

---------------------------------------------------------------------------
-- Resolution
---------------------------------------------------------------------------

local function readAffixes()
	state.affixes = nil
	state.keyLevel = nil
	if state.diff ~= "k" or not (C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo) then
		return
	end
	local ok, level, ids = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
	if not ok then return end
	level = plain(level)
	if type(level) == "number" and level > 0 then state.keyLevel = level end
	if type(ids) ~= "table" then return end
	local list = {}
	for _, id in ipairs(ids) do
		id = plain(id)
		if id and C_ChallengeMode.GetAffixInfo then
			local okA, name, _, icon = pcall(C_ChallengeMode.GetAffixInfo, id)
			name = okA and plain(name) or nil
			if name then list[#list + 1] = { name = name, icon = plain(icon) } end
		end
	end
	state.affixes = list
end

local function readDifficulty()
	local _, instanceType, difficultyID = GetInstanceInfo()
	instanceType = plain(instanceType)
	difficultyID = plain(difficultyID)
	state.difficultyID = difficultyID
	state.diff = KN.DIFF_BY_ID[difficultyID or 0] or "m"
	return instanceType
end

local dbgAmbiguous = nil
-- Name matching lives in Core now (KN.Find), so the registry and the tracker
-- cannot disagree about what "the necrotic wake" means. The journal's
-- instanceID is threaded through because it is the only identifier that is
-- actually unique - see the Magisters' Terrace collision in Core.lua.
local function lookup(name, instanceID)
	if not name and not instanceID then return nil end
	local def, why = KN.Find(name, instanceID)
	if not def and why then dbgAmbiguous = why end
	return def
end

local dbg = {}
local function resolveDungeon()
	local instanceID, name = KN.Journal.CurrentInstance()
	dbg.journalInstanceID = instanceID
	dbg.journalName = name
	local def = lookup(name, instanceID)
	if not def and C_ChallengeMode and C_ChallengeMode.GetActiveChallengeMapID then
		local ok, mapID = pcall(C_ChallengeMode.GetActiveChallengeMapID)
		mapID = ok and plain(mapID) or nil
		dbg.challengeMapID = mapID
		if mapID and C_ChallengeMode.GetMapUIInfo then
			local okN, n = pcall(C_ChallengeMode.GetMapUIInfo, mapID)
			n = okN and plain(n) or nil
			dbg.challengeName = n
			def = lookup(n)
		end
	end
	if not def then
		local n = plain((GetInstanceInfo()))
		dbg.instanceName = n
		def = lookup(n)
	end
	dbg.matched = def and def.name or nil
	dbg.ambiguous = dbgAmbiguous
	dbgAmbiguous = nil
	return def, instanceID
end

local retries = 0
function Tracker.Refresh(reason)
	wipe(dbg)
	local instanceType = readDifficulty()
	dbg.instanceType = instanceType
	dbg.difficultyID = state.difficultyID
	dbg.reason = reason
	if instanceType ~= "party" then
		state.inDungeon = false
		if state.preview then return end
		state.dungeon = nil
		state.boss = nil
		Tracker.Render()
		return
	end
	state.preview = false
	local def, instanceID = resolveDungeon()
	if not def and retries < 5 then
		-- map data and the journal can lag the zone event by seconds on a
		-- fresh load; try again before giving up
		retries = retries + 1
		C_Timer.After(2, function() Tracker.Refresh("retry " .. retries) end)
	elseif def then
		retries = 0
	end
	if def ~= state.dungeon then
		state.dungeon = def
		state.killed = 0
		state.manualLeg = nil
		state.boss = nil
	end
	if def and instanceID then
		state.bosses = KN.Journal.Bosses(instanceID, state.difficultyID)
		local learned = KN.LearnedBosses()
		for _, jb in ipairs(state.bosses or {}) do
			if jb.dungeonEncounterID then
				learned[jb.dungeonEncounterID] = jb.name
			end
		end
	end
	readAffixes()
	state.leg = state.manualLeg or (state.killed + 1)
	-- Option I's behaviour as an opt-in: walking into a dungeon we have
	-- notes for flips the window to Notes (and a captured fight flips it
	-- back, see OnEnable)
	local p = KN.Profile()
	if def and not state.inDungeon and p and p.notes and p.notes.autoSwitch
		and TP.MeterWindow and TP.MeterWindow.SetView and not KN.ViewIsNotes() then
		TP.MeterWindow:SetView("notes")
	end
	state.inDungeon = def ~= nil
	Tracker.Render()
end

function Tracker.OnEncounterStart(encounterID, encounterName)
	if not state.dungeon then return end
	encounterID = plain(encounterID)
	encounterName = plain(encounterName)
	local name = encounterName or (encounterID and KN.LearnedBosses()[encounterID])
	state.boss = findDataBoss(name)
	state.journalBoss = findJournalBoss(name)
	if not state.boss and name then
		state.boss = { name = name, notes = {} }
	end
	Tracker.Render()
end

function Tracker.OnEncounterEnd(encounterID, success)
	if not state.dungeon then return end
	success = plain(success)
	if success == 1 then
		state.killed = state.killed + 1
		if state.manualLeg then
			state.manualLeg = state.manualLeg + 1
			state.leg = state.manualLeg
		else
			state.leg = state.killed + 1
		end
	end
	state.boss = nil
	state.journalBoss = nil
	Tracker.Render()
end

function Tracker.Step(delta)
	if not state.dungeon then return end
	-- nothing to page in a raid: no trash, and the boss list is not ordered
	if state.dungeon.kind == "raid" then return end
	local n = #state.dungeon.bosses + 1
	local leg = (state.manualLeg or state.leg) + delta
	if leg < 1 then leg = 1 end
	if leg > n then leg = n end
	state.manualLeg = leg
	state.leg = leg
	state.boss = nil
	Tracker.Render()
end

-- /tp notes show <dungeon> [n|h|m|k] [+level] [affix names...]
function Tracker.Preview(query, diff, level, affixNames)
	if not query or query == "" then
		state.preview = false
		Tracker.Refresh("preview off")
		return
	end
	local q = query:lower()
	local def, matches = nil, {}
	for _, d in ipairs(KN.instances) do
		if d.name:lower():find(q, 1, true) then
			matches[#matches + 1] = d
			def = def or d
		end
	end
	if not def then
		KN.Print("no dungeon matching '" .. query .. "'")
		return
	end
	if #matches > 1 then
		-- two instances can share a name (Magisters' Terrace); say so rather
		-- than silently previewing whichever registered first
		local names = {}
		for _, d in ipairs(matches) do
			names[#names + 1] = d.name .. (d.instanceID and (" [" .. tostring(d.instanceID) .. "]") or "")
		end
		KN.Print("'" .. query .. "' matches " .. #matches .. ": " .. table.concat(names, ", "))
		return
	end
	state.preview = true
	state.dungeon = def
	state.diff = KN.DIFF_RANK[diff or ""] and diff or "k"
	state.bosses = nil
	state.killed = 0
	state.manualLeg = nil
	state.leg = 1
	state.boss = nil
	state.keyLevel = state.diff == "k" and (level or 10) or nil
	state.affixes = nil
	if state.diff == "k" then
		state.affixes = {}
		for _, n in ipairs(affixNames or { "Tyrannical", "Xal'atath's Bargain: Devour" }) do
			state.affixes[#state.affixes + 1] = { name = n }
		end
	end
	if TP.MeterWindow and TP.MeterWindow.SetView then
		TP.MeterWindow:SetView("notes")
	end
	Tracker.Render()
end

function Tracker.PreviewBoss(query)
	if not state.dungeon then return end
	local b = findDataBoss(query)
	if not b then
		KN.Print("no boss matching '" .. tostring(query) .. "'")
		return
	end
	state.boss = b
	state.journalBoss = findJournalBoss(b.name)
	Tracker.Render()
end

-- /tp notes journal [boss] - dump what the Adventure Guide actually exposes
-- for one encounter. Diagnostic for the question of whether the journal's own
-- summary bullets are readable by an addon (Josh 2026-09-08).
-- set by "/kn journal at <instance>"; lets the probe read an instance we are
-- nowhere near
Tracker.journalTarget = nil

function Tracker.JournalAt(query)
	local id, name, matches = KN.Journal.FindInstance(query)
	if not id then
		return { "no journal instance matching '" .. tostring(query) .. "'" }
	end
	Tracker.journalTarget = { instanceID = id, name = name }
	local out = { "journal target: " .. tostring(name) .. " (instanceID=" .. tostring(id) .. ")" }
	if matches and #matches > 1 then
		out[#out + 1] = "  (also matched: " .. table.concat(matches, ", ") .. ")"
	end
	local bosses = KN.Journal.Bosses(id, nil) or {}
	for i, b in ipairs(bosses) do
		out[#out + 1] = "  " .. i .. ". " .. tostring(b.name)
	end
	out[#out + 1] = "now: /kn journal overview <boss>"
	return out
end

function Tracker.JournalLines(query, overview)
	Tracker.Refresh("journal dump")
	-- Deliberately independent of KN.instances: the journal is the journal
	-- whether or not we have hand-written notes for the place. Without this
	-- the probe would only work in the eight Season 2 dungeons, which are the
	-- least interesting ones to ask the question about.
	local bosses = state.bosses
	-- an explicit browse target wins over wherever we happen to be standing
	if Tracker.journalTarget then
		bosses = KN.Journal.Bosses(Tracker.journalTarget.instanceID, nil)
	end
	if not bosses or #bosses == 0 then
		local instanceID = KN.Journal.CurrentInstance()
		local diffID = state.difficultyID
		if not diffID and GetInstanceInfo then
			local ok, _, _, d = pcall(GetInstanceInfo)
			if ok then diffID = d end
		end
		if instanceID then bosses = KN.Journal.Bosses(instanceID, diffID) end
	end
	if not bosses or #bosses == 0 then
		return { "no journal bosses here - run this inside an instance, or /kn journal at <instance>" }
	end
	state.bosses = state.bosses or bosses
	local pick
	if query and query ~= "" then
		local q = query:lower()
		for _, jb in ipairs(bosses) do
			if jb.name and jb.name:lower():find(q, 1, true) then pick = jb break end
		end
		if not pick then return { "no journal boss matching '" .. query .. "'" } end
	else
		pick = state.journalBoss or bosses[1]
	end
	local out = { "journal: " .. tostring(pick.name)
		.. " (encounterID=" .. tostring(pick.journalEncounterID)
		.. " root=" .. tostring(pick.rootSectionID) .. ")" }

	-- "overview" mode: the per-role bullets in full, untruncated, one bullet
	-- per line. This is the comparison that matters - whether the three role
	-- sections actually say different things, or repeat one shared list.
	if overview then
		local blocks = KN.Journal.Overview(pick.rootSectionID)
		if #blocks == 0 then
			out[#out + 1] = "no hdr=3 overview sections found"
			return out
		end
		for _, b in ipairs(blocks) do
			out[#out + 1] = ("-- %s (role=%s, %d bullets)"):format(b.title, tostring(b.role), #b.bullets)
			for i, text in ipairs(b.bullets) do
				out[#out + 1] = "   " .. i .. ". " .. text
			end
		end
		return out
	end

	for _, line in ipairs(KN.Journal.DumpSections(pick.rootSectionID)) do
		out[#out + 1] = line
	end
	return out
end

function Tracker.DebugLines()
	Tracker.Refresh("debug")
	local function v(x) if x == nil then return "nil" end if IsSecret(x) then return "SECRET" end return tostring(x) end
	local out = { KN.Player.DebugLine() }
	out[#out + 1] = "instanceType=" .. v(dbg.instanceType) .. " difficultyID=" .. v(dbg.difficultyID) .. " diff=" .. v(state.diff)
	out[#out + 1] = "mapID=" .. v(C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player"))
		.. " journalInstanceID=" .. v(dbg.journalInstanceID) .. " journalName=" .. v(dbg.journalName)
	out[#out + 1] = "challengeMapID=" .. v(dbg.challengeMapID) .. " challengeName=" .. v(dbg.challengeName)
		.. " instanceName=" .. v(dbg.instanceName)
	out[#out + 1] = "matched=" .. v(dbg.matched) .. " preview=" .. tostring(state.preview)
		.. " view=" .. tostring(KN.ViewIsNotes() and "notes" or "scores") .. " leg=" .. v(state.leg) .. " killed=" .. v(state.killed)
	local names = {}
	for _, a in ipairs(state.affixes or {}) do names[#names + 1] = a.name .. "(" .. tostring(a.icon) .. ")" end
	out[#out + 1] = "key=" .. v(state.keyLevel) .. " affixes=" .. table.concat(names, ", ")
	if state.bosses then
		local list = {}
		for _, b in ipairs(state.bosses) do
			local n = 0
			for _ in pairs(b.abilities or {}) do n = n + 1 end
			list[#list + 1] = b.name .. "(" .. tostring(b.dungeonEncounterID) .. ", " .. n .. " abilities)"
		end
		out[#out + 1] = "journal bosses: " .. table.concat(list, "; ")
	else
		out[#out + 1] = "journal bosses: none read"
	end
	return out
end

---------------------------------------------------------------------------
-- Events, commands, keybinds
---------------------------------------------------------------------------

-- Own frame: AceEvent allows one handler per event per object, and the
-- segment collector already owns ENCOUNTER_START/END on the addon object.
local ev = CreateFrame("Frame")
ev:SetScript("OnEvent", function(_, event, a1, a2, a3, a4, a5)
	if event == "ENCOUNTER_START" then
		Tracker.OnEncounterStart(a1, a2)
	elseif event == "ENCOUNTER_END" then
		Tracker.OnEncounterEnd(a1, a5)
	else
		-- map data can lag the zone event by a frame
		C_Timer.After(0.5, function() Tracker.Refresh(event) end)
	end
end)

function Tracker.OnEnable()
	for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "CHALLENGE_MODE_START",
		"ENCOUNTER_START", "ENCOUNTER_END" }) do
		pcall(ev.RegisterEvent, ev, e)
	end
	-- a captured fight flips an auto-switched window back to Scores
	local AceEvent = LibStub and LibStub("AceEvent-3.0", true)
	if AceEvent and AceEvent.Embed then
		AceEvent:Embed(Tracker)
		if Tracker.RegisterMessage then
			Tracker:RegisterMessage("TrueParse_FIGHT_CAPTURED", function()
				local p = KN.Profile()
				if p and p.notes and p.notes.autoSwitch and KN.ViewIsNotes()
					and TP.MeterWindow and TP.MeterWindow.SetView then
					TP.MeterWindow:SetView("scores")
				end
			end)
		end
	end
end

-- Keybindings (Bindings.xml)
function TrueParse_ToggleNotes()
	if TP.MeterWindow and TP.MeterWindow.SetView then
		TP.MeterWindow:SetView(KN.ViewIsNotes() and "scores" or "notes")
	end
end
function TrueParse_NotesStep(delta)
	Tracker.Step(delta)
end

-- /tp notes ... (and /kn ... as an alias). Returns true when handled.
function KN:Command(input)
	local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
	cmd = (cmd or ""):lower()
	if cmd == "" or cmd == "toggle" then
		TrueParse_ToggleNotes()
	elseif cmd == "show" then
		-- /tp notes show voidscar k 9 fortified pulsar
		local words = {}
		for w in rest:gmatch("%S+") do words[#words + 1] = w end
		local name = table.remove(words, 1)
		local diff, level, affixes = nil, nil, {}
		for _, w in ipairs(words) do
			local lw = w:lower()
			if KN.DIFF_RANK[lw] then diff = lw
			elseif tonumber((lw:gsub("^%+", ""))) then level = tonumber((lw:gsub("^%+", "")))
			else affixes[#affixes + 1] = (lw:gsub("^%l", string.upper)) end
		end
		Tracker.Preview(name, diff, level, #affixes > 0 and affixes or nil)
	elseif cmd == "boss" then
		Tracker.PreviewBoss(rest)
	elseif cmd == "as" then
		KN.Print(KN.Player.SetOverride(rest))
		Tracker.Render()
	elseif cmd == "off" then
		Tracker.Preview(nil)
	elseif cmd == "next" then
		Tracker.Step(1)
	elseif cmd == "prev" then
		Tracker.Step(-1)
	elseif cmd == "ladder" then
		local level = tonumber(rest) or state.keyLevel
		KN.Print("Season 2 keystone ladder" .. (level and (" (at +" .. level .. ")") or ""))
		for _, row in ipairs(KN.LadderLines(level)) do
			local mark = row.active and "|cffffd36e> |r" or "  "
			KN.Print(mark .. row.range .. ": " .. row.text)
		end
	elseif cmd == "debug" then
		for _, line in ipairs(Tracker.DebugLines()) do KN.Print(line) end
	elseif cmd == "journal" then
		local mode, who = rest:match("^(%S*)%s*(.-)$")
		mode = (mode or ""):lower()
		if mode == "at" then
			for _, line in ipairs(Tracker.JournalAt(who)) do KN.Print(line) end
		elseif mode == "here" then
			Tracker.journalTarget = nil
			KN.Print("journal target cleared; reading wherever you are standing")
		else
			local overview = mode == "overview"
			for _, line in ipairs(Tracker.JournalLines(overview and who or rest, overview)) do KN.Print(line) end
		end
	elseif cmd == "list" then
		local names = {}
		for _, d in ipairs(KN.instances) do names[#names + 1] = d.name end
		table.sort(names)
		KN.Print(table.concat(names, ", "))
	else
		return false
	end
	return true
end

-- /kn from the standalone days keeps working
SLASH_TPNOTES1 = "/kn"
SlashCmdList.TPNOTES = function(msg)
	if TP.Addon and TP.Addon.HandleSlash then
		TP.Addon:HandleSlash("notes " .. (msg or ""))
	end
end
