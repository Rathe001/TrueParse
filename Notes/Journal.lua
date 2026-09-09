-- Encounter Journal lookups. Nothing here is combat data, so none of it comes
-- back secret; every return is still guarded because Midnight has surprised
-- this author before (TrueParse's FightHistory has a "secret instance name"
-- crash in its changelog).
local _, TP = ...
local KN = TP.Notes

local Journal = {}
KN.Journal = Journal

local IsSecret = KN.IsSecret

local function plain(v)
	if v == nil or IsSecret(v) then return nil end
	return v
end

-- The journal instance for the map the player is standing on, or nil.
function Journal.CurrentInstance()
	if not (C_Map and C_Map.GetBestMapForUnit and EJ_GetInstanceForMap) then
		return nil
	end
	local mapID = plain(C_Map.GetBestMapForUnit("player"))
	if not mapID then return nil end
	local ok, instanceID = pcall(EJ_GetInstanceForMap, mapID)
	instanceID = ok and plain(instanceID) or nil
	if not instanceID or instanceID == 0 then return nil end
	local okName, name = pcall(EJ_GetInstanceInfo, instanceID)
	name = okName and plain(name) or nil
	return instanceID, name
end

-- Pick the journal difficulty that matches the one we are running. The
-- journal has no separate Keystone listing; keys read the Mythic page.
local function journalDifficulty(difficultyID)
	-- browsing an instance we are not standing in has no difficulty of its
	-- own; leave the journal on whatever it already had
	if difficultyID == nil then return nil end
	if difficultyID == 8 then
		if EJ_IsValidInstanceDifficulty and EJ_IsValidInstanceDifficulty(8) then
			return 8
		end
		return 23
	end
	if EJ_IsValidInstanceDifficulty and not EJ_IsValidInstanceDifficulty(difficultyID) then
		return nil
	end
	return difficultyID
end

-- Walks one encounter's section tree and returns { [abilityTitle] = hiddenAtThisDifficulty }.
local function readSections(rootSectionID)
	local out = {}
	-- MISTS: this namespace does not exist on every client. `pcall(C_X.Y, id)`
	-- indexes C_X *before* pcall runs, so a nil namespace errors outside the
	-- pcall and takes the whole refresh with it. Check it once, up front.
	if not (C_EncounterJournal and C_EncounterJournal.GetSectionInfo) then
		return out
	end
	local stack = { rootSectionID }
	local guard = 0
	while #stack > 0 and guard < 400 do
		guard = guard + 1
		local id = table.remove(stack)
		local ok, info = pcall(C_EncounterJournal.GetSectionInfo, id)
		if ok and type(info) == "table" then
			local title = plain(info.title)
			if title and title ~= "" then
				-- an ability appearing twice (once filtered, once not) counts
				-- as present: the journal lists per-phase copies
				local hidden = plain(info.filteredByDifficulty) and true or false
				if out[title] == nil or out[title] == true then
					out[title] = hidden
				end
			end
			local child = plain(info.firstChildSectionID)
			if child and child ~= 0 then stack[#stack + 1] = child end
			local sib = plain(info.siblingSectionID)
			if sib and sib ~= 0 then stack[#stack + 1] = sib end
		end
	end
	return out
end

-- Reads every boss of an instance at a difficulty:
--   { { name=, dungeonEncounterID=, abilities={ [title]=hidden } }, ... }
-- Cached per instance+difficulty for the session; the journal does not change
-- mid-run.
local cache = {}
function Journal.Bosses(instanceID, difficultyID)
	local key = instanceID .. ":" .. tostring(difficultyID)
	if cache[key] then return cache[key] end
	if not (EJ_SelectInstance and EJ_GetEncounterInfoByIndex) then return nil end

	local ok = pcall(EJ_SelectInstance, instanceID)
	if not ok then return nil end
	local jd = journalDifficulty(difficultyID)
	if jd and EJ_SetDifficulty then pcall(EJ_SetDifficulty, jd) end

	local bosses = {}
	for i = 1, 20 do
		local okE, name, _, journalEncounterID, rootSectionID, _, _, dungeonEncounterID =
			pcall(EJ_GetEncounterInfoByIndex, i, instanceID)
		name = okE and plain(name) or nil
		if not name then break end
		local abilities = {}
		journalEncounterID = plain(journalEncounterID)
		rootSectionID = plain(rootSectionID)
		if journalEncounterID and rootSectionID and EJ_SelectEncounter then
			pcall(EJ_SelectEncounter, journalEncounterID)
			abilities = readSections(rootSectionID)
		end
		bosses[#bosses + 1] = {
			name = name,
			dungeonEncounterID = plain(dungeonEncounterID),
			journalEncounterID = journalEncounterID,
			rootSectionID = rootSectionID,
			abilities = abilities,
		}
	end
	cache[key] = bosses
	return bosses
end

-- True when the journal lists `ability` for this boss and marks it hidden at
-- the selected difficulty. Unknown abilities are NOT hidden: a note whose
-- ability name doesn't match the journal still shows, because a wrong hide
-- costs more than a wrong show.
function Journal.AbilityHidden(boss, ability)
	if not (boss and ability and boss.abilities) then return false end
	return boss.abilities[ability] == true
end

-- DIAGNOSTIC ONLY - the view never calls this.
--
-- Josh 2026-09-08: the Adventure Guide now carries short bullet-point
-- summaries, and the question is whether an addon can read them. We already
-- walk the section tree for `title` and `filteredByDifficulty`; this dumps
-- everything else a section exposes so we can see, in game, exactly what is
-- reachable:
--
--   description        the body text (is the TL;DR bullet in here, or is it
--                      a section of its own?)
--   headerType         section hierarchy - overview sections sit at a
--                      different level from ability sections
--   GetSectionIconFlags the structured tags: role alerts (Tank/Healer/DPS)
--                      and effect types (Magic Effect and friends). This is
--                      the field that decides everything - if the journal
--                      hands us role and dispel school as data rather than
--                      prose, most of what Notes does by hand it can do by
--                      itself.
--
-- Everything is pcall'd and secret-guarded: this runs inside an instance,
-- where Midnight has surprised this author before.
function Journal.DumpSections(rootSectionID, maxLines)
	local out = {}
	if not (C_EncounterJournal and C_EncounterJournal.GetSectionInfo) then
		out[#out + 1] = "C_EncounterJournal.GetSectionInfo unavailable on this client"
		return out
	end
	if not rootSectionID then
		out[#out + 1] = "no rootSectionID (select a boss first)"
		return out
	end
	maxLines = maxLines or 40

	local function flags(id)
		if not C_EncounterJournal.GetSectionIconFlags then return "n/a" end
		local ok, f = pcall(C_EncounterJournal.GetSectionIconFlags, id)
		if not ok or f == nil or IsSecret(f) then return "-" end
		if type(f) ~= "table" then return tostring(f) end
		local parts = {}
		for k, v in pairs(f) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v) end
		return #parts > 0 and table.concat(parts, ",") or "-"
	end

	-- depth-tracked walk so the hierarchy is visible; same 400 guard the
	-- read path uses
	local stack, guard = { { id = rootSectionID, depth = 0 } }, 0
	while #stack > 0 and guard < 400 and #out < maxLines do
		guard = guard + 1
		local node = table.remove(stack)
		local ok, info = pcall(C_EncounterJournal.GetSectionInfo, node.id)
		if ok and type(info) == "table" then
			local title = plain(info.title) or "(no title)"
			local desc = plain(info.description)
			if desc then
				desc = tostring(desc):gsub("%s+", " ")
				if #desc > 120 then desc = desc:sub(1, 120) .. "..." end
			end
			out[#out + 1] = string.format("%s[%s] %s | hdr=%s filt=%s | flags=%s",
				string.rep("  ", node.depth), tostring(node.id), title,
				tostring(plain(info.headerType)), tostring(plain(info.filteredByDifficulty)),
				flags(node.id))
			if desc then
				out[#out + 1] = string.rep("  ", node.depth) .. "   desc: " .. desc
			end
			local sib = plain(info.siblingSectionID)
			if sib and sib ~= 0 then stack[#stack + 1] = { id = sib, depth = node.depth } end
			local child = plain(info.firstChildSectionID)
			if child and child ~= 0 then stack[#stack + 1] = { id = child, depth = node.depth + 1 } end
		end
	end
	if #out >= maxLines then out[#out + 1] = "... truncated" end
	return out
end

-- The Adventure Guide's own per-role summary. Confirmed in game 2026-09-08:
-- each encounter carries `hdr = 3` overview sections titled Tank / Healers /
-- Damage Dealers, tagged by icon flag (0 tank, 1 dps, 2 healer), whose
-- description is a run of bullets separated by the literal token "$bullet;".
--
-- Returns { { title=, role=, bullets={...} }, ... }.
function Journal.Overview(rootSectionID)
	local out = {}
	if not (C_EncounterJournal and C_EncounterJournal.GetSectionInfo and rootSectionID) then
		return out
	end
	local ROLE = { [0] = "tank", [1] = "dps", [2] = "healer" }
	local function roleOf(id)
		if not C_EncounterJournal.GetSectionIconFlags then return nil end
		local ok, f = pcall(C_EncounterJournal.GetSectionIconFlags, id)
		if not ok or type(f) ~= "table" then return nil end
		for _, v in pairs(f) do
			if not IsSecret(v) and ROLE[v] then return ROLE[v] end
		end
		return nil
	end

	local stack, guard = { rootSectionID }, 0
	while #stack > 0 and guard < 400 do
		guard = guard + 1
		local id = table.remove(stack)
		local ok, info = pcall(C_EncounterJournal.GetSectionInfo, id)
		if ok and type(info) == "table" then
			local hdr = plain(info.headerType)
			local desc = plain(info.description)
			-- a section the journal hides at the selected difficulty is not
			-- advice for this run (a Mythic-only bullet on Normal)
			local hidden = plain(info.filteredByDifficulty) and true or false
			if hdr == 3 and desc and desc ~= "" and not hidden then
				local bullets = {}
				-- "$bullet;" is Blizzard's own marker inside the description
				for piece in (tostring(desc) .. "$bullet;"):gmatch("(.-)%$bullet;") do
					piece = piece:gsub("^%s+", ""):gsub("%s+$", "")
					if piece ~= "" then bullets[#bullets + 1] = piece end
				end
				if #bullets > 0 then
					out[#out + 1] = {
						title = plain(info.title) or "(untitled)",
						role = roleOf(id),
						bullets = bullets,
					}
				end
			end
			local sib = plain(info.siblingSectionID)
			if sib and sib ~= 0 then stack[#stack + 1] = sib end
			local child = plain(info.firstChildSectionID)
			if child and child ~= 0 then stack[#stack + 1] = child end
		end
	end
	return out
end

-- An instance def built from the Adventure Guide alone, for a place nothing
-- in Notes\*.lua covers (Josh 2026-09-09: "use the dungeon journal for the
-- remaining dungeons and raids that we never got data for"). Same shape
-- KN.RegisterDungeon takes, so the tracker and the view need no special
-- case beyond the `journal = true` flag:
--
--   bosses  the journal's list, in its order
--   notes   one per role bullet, `role` = tank | healer | dps from the
--           section's icon flag. The role-neutral Overview section is
--           prose, not advice, and is left out; the research found no
--           reliable way to derive core lines from it, so a journal boss
--           has NO core lines. Bullets the journal filters at the selected
--           difficulty are already dropped by Overview.
--   trash   none. `linear` is unset, so a raid lists its bosses.
--
-- Never registered: KN.instances stays the hand-written corpus, and a
-- hand-written def always wins (the tracker asks for this only after every
-- other lookup fails). Cached per instance and difficulty for the session.
local synth = {}
function Journal.Synthesize(instanceID, difficultyID, kind)
	if not instanceID then return nil end
	local key = instanceID .. ":" .. tostring(difficultyID)
	if synth[key] ~= nil then return synth[key] or nil end
	local bosses = Journal.Bosses(instanceID, difficultyID)
	-- not `X and pcall(...)`: `and` keeps only the first return, dropping
	-- the name
	local name
	if EJ_GetInstanceInfo then
		local okName, n = pcall(EJ_GetInstanceInfo, instanceID)
		name = okName and plain(n) or nil
	end
	if not (bosses and #bosses > 0 and name) then
		synth[key] = false
		return nil
	end
	local def = { name = name, instanceID = instanceID, kind = kind or "dungeon", journal = true, bosses = {} }
	for _, jb in ipairs(bosses) do
		local notes = {}
		if jb.journalEncounterID and EJ_SelectEncounter then pcall(EJ_SelectEncounter, jb.journalEncounterID) end
		for _, block in ipairs(Journal.Overview(jb.rootSectionID)) do
			if block.role then
				for _, text in ipairs(block.bullets) do
					notes[#notes + 1] = { role = block.role, text = text }
				end
			end
		end
		def.bosses[#def.bosses + 1] = { name = jb.name, notes = notes }
	end
	synth[key] = def
	return def
end

-- Find a journal instance by name without being anywhere near it. The
-- Encounter Journal is browsable from anywhere - the only reason the probe
-- needed you inside was that we resolve instanceID from the player's map.
-- Walks every tier, dungeons then raids. Restores the tier it found you on.
function Journal.FindInstance(query)
	if not (query and query ~= "" and EJ_GetNumTiers and EJ_SelectTier and EJ_GetInstanceByIndex) then
		return nil
	end
	local q = tostring(query):lower()
	local restore = EJ_GetCurrentTier and select(1, pcall(EJ_GetCurrentTier)) and EJ_GetCurrentTier() or nil
	local foundID, foundName, matches = nil, nil, {}

	local okTiers, tiers = pcall(EJ_GetNumTiers)
	if not okTiers or not tiers then return nil end
	for tier = 1, tiers do
		if not pcall(EJ_SelectTier, tier) then break end
		for _, isRaid in ipairs({ false, true }) do
			local index = 1
			while index < 60 do
				local ok, instanceID, name = pcall(EJ_GetInstanceByIndex, index, isRaid)
				instanceID = ok and plain(instanceID) or nil
				name = ok and plain(name) or nil
				if not instanceID or not name then break end
				if name:lower():find(q, 1, true) then
					matches[#matches + 1] = name
					if not foundID then foundID, foundName = instanceID, name end
				end
				index = index + 1
			end
		end
	end
	if restore then pcall(EJ_SelectTier, restore) end
	return foundID, foundName, matches
end
