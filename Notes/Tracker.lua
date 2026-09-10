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

-- No `min` means every difficulty, Raid Finder included; `min = "n"` is the
-- way to say "not in LFR".
local function diffOK(min)
	local need = min and KN.DIFF_RANK[min] or 0
	return (KN.DIFF_RANK[state.diff] or KN.DIFF_RANK[KN.DIFF_DEFAULT]) >= need
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
-- which hand-written tags already say what a data kind would say
local TAG_KIND = { KICK = "kick", PURGE = "purge", SOOTHE = "soothe", STUN = "stun", LUST = "lust",
	CD = "healercd", TANK = "defensive", DEF = "defensive", DISPEL = "dispel",
	MAGIC = "dispel", CURSE = "dispel", POISON = "dispel", DISEASE = "dispel", BLEED = "dispel",
	MASSDISP = "dispel", FEAR = "dispel" }
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
	row.tag = tag
	row.icon = KN.ICONS[tag]
	row.rgb = def and def.rgb
	row.label = KN.Player.Label(tag) or (def and def.label)
	return row
end

-- A boss line that is yours: your spec's icon in the numeral column, then
-- one full sentence (Josh 2026-09-09, the last word on it: "axe the tags
-- and show the current spec's icon ... the line items themselves should
-- describe the full task"). The family's generic verb folds into the text
-- - "Dispel Corroding Spittle off immediately", never "Purify Spirit" -
-- and families whose lines are already sentences (tank, stun, fear, mass
-- dispel) get nothing prepended.
local VERB = {
	MAGIC = "Dispel", CURSE = "Dispel", POISON = "Dispel", DISEASE = "Dispel", BLEED = "Dispel", DISPEL = "Dispel",
	KICK = "Kick", PURGE = "Purge", SOOTHE = "Soothe", LUST = "Lust", CD = "Cooldown for",
}
-- "Cooldown for Every Chaotic Burst phase" wants "every": lowercase a
-- leading function word, never a leading name (Frost Overload, Inferno)
local STOPWORD = { every = true, the = true, a = true, an = true, on = true, all = true, each = true,
	when = true, at = true, ["in"] = true, before = true, after = true, both = true, phase = true, save = true, keep = true }
local function sentence(tag, text)
	local verb = tag and VERB[tag]
	if not (verb and text) then return text end
	local first = text:match("^(%a+)")
	if first and STOPWORD[first:lower()] then
		text = first:lower() .. text:sub(#first + 1)
	end
	return verb .. " " .. text
end
local function tagged(row, tag, text)
	row.type = "yours"
	row.tag = tag
	row.icon = nil -- the spec icon sits on the subheading, not the lines
	row.label = nil
	row.rgb = nil
	row.text = text
	return row
end
local function yoursRow(x)
	local tag = pickTag(x)
	return tagged({}, tag, sentence(tag, x.text))
end

local function noteHidden(n, jb)
	if not diffOK(n.min) then return true end
	if not forMe(n) then return true end
	if n.ability and jb and KN.Journal.AbilityHidden(jb, n.ability) then return true end
	return false
end

-- How narrowly a note picks its reader: a role line was written for the
-- reader's seat, a class line for their kit, a need line for anyone with
-- the tool.
local function specificity(n)
	return (n.role and 4 or 0) + (n.class and 2 or 0) + (n.need and 1 or 0)
end

-- The notes this reader sees on a boss, one per enemy ability: a tank with
-- a poison dispel would otherwise read "Dispel Envenom" and "Envenom:
-- defensive, get it dispelled" back to back (Josh 2026-09-09); the line
-- written for their seat is the one that stays. A lust call is a timing,
-- not an answer to the ability, so it never folds.
local function visibleNotes(b, jb)
	local out, at = {}, {}
	for _, x in ipairs(b.notes or {}) do
		if not noteHidden(x, jb) then
			local key = x.ability and pickTag(x) ~= "LUST" and x.ability
			local i = key and at[key]
			if i then
				if specificity(x) > specificity(out[i]) then out[i] = x end
			else
				out[#out + 1] = x
				if key then at[key] = #out end
			end
		end
	end
	return out
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

---------------------------------------------------------------------------
-- Ranked-run casts (Data/BossCasts*.lua, crawled by scripts/fetch-boss-
-- casts.ps1): per boss and spec, how often each UTILITY spell is cast in
-- ranked kills and by what share of that spec. Two uses (Josh 2026-09-09):
-- a "ranked runs cast X here" line for a tool the reader's spec plainly
-- uses on a boss where no hand-written line covers it, and /tp notes check.
---------------------------------------------------------------------------

local KIND_TAG = { kick = "KICK", dispel = "DISPEL", purge = "PURGE", soothe = "SOOTHE", stun = "STUN",
	lust = "LUST", defensive = "DEF", healercd = "CD", utility = "UTIL" }
-- a line earns its place when at least half the spec casts it and the
-- median player casts it at least once a pull
local DATA_SHARE, DATA_CPF = 0.5, 1

-- The data entry for a boss: the instance keyed by the dungeon's own name
-- first (keystone data), then any instance carrying that boss name (the
-- raid crawl keys by the folded zone name).
local function castsFor(bossName)
	local all = TP.BossCasts
	if not (all and bossName and state.dungeon) then return nil end
	local want, bn = KN.Normalize(state.dungeon.name), bossName:lower()
	local function pick(bosses)
		for name, entry in pairs(bosses) do
			local ln = name:lower()
			if ln == bn or ln:find(bn, 1, true) or bn:find(ln, 1, true) then return entry end
		end
	end
	for inst, bosses in pairs(all) do
		if KN.Normalize(inst) == want then
			local e = pick(bosses)
			if e then return e end
		end
	end
	for _, bosses in pairs(all) do
		local e = pick(bosses)
		if e then return e end
	end
	return nil
end

local function specWord(caps)
	return (caps and caps.name or "") .. " " .. (KN.Player.ClassName(caps and caps.class) or "")
end

-- Kinds that are situational by nature: most of a spec using one on a
-- boss says something about the boss. A kick, a personal defensive, a
-- healer cooldown or a group utility button is pressed on every boss (the
-- 378-run sample put Power Infusion and Stampeding Roar on all of them),
-- so those earn a line only where this spec's usage here is unusual for
-- it (see typicalShare), and a kick not at all once any line on the boss
-- names a kick or interrupt.
local SITUATIONAL = { dispel = true, purge = true, soothe = true, stun = true }

-- The share of `sid` casting `name` on the OTHER bosses in the data, as a
-- median; nil when this is the only boss the spec appears on.
local typical = {}
local function typicalShare(sid, name, here)
	local key = sid .. "|" .. name
	if typical[key] == nil then
		local shares = {}
		for _, bosses in pairs(TP.BossCasts or {}) do
			for _, e in pairs(bosses) do
				local spec = e ~= here and e.specs and e.specs[sid]
				if spec then
					local share = 0
					for _, s in ipairs(spec.s or {}) do
						if s[1] == name then share = s[4] break end
					end
					shares[#shares + 1] = share
				end
			end
		end
		table.sort(shares)
		typical[key] = #shares > 0 and shares[math.ceil(#shares / 2)] or false
	end
	return typical[key] or nil
end

-- Does any line on this boss already tell the reader to kick?
local function mentionsKick(b)
	local function hit(text)
		text = text and text:lower()
		return text and (text:find("kick", 1, true) or text:find("interrupt", 1, true))
	end
	local lines = type(b.core) == "table" and b.core or { b.core }
	for _, text in ipairs(lines) do if hit(text) then return true end end
	for _, x in ipairs(b.notes or {}) do if hit(x.text) then return true end end
	return false
end

-- What a tool of this kind is FOR on this boss, so the line can say
-- "Capacitor Totem works well on Mirror Images" rather than that the tool
-- gets used (Josh 2026-09-09). Two sources, the boss's own declaration
-- first:
--   uses = { stun = "Mirror Images", soothe = "Bestial Wrath" }
-- then the `ability` of any note on the boss whose tag is of this kind,
-- whether or not the reader sees that note: the tank line "Defensive for
-- Envenom" tells a Retribution reader what their Divine Shield answers.
-- Reading the target out of the boss's prose was tried and produced
-- "works well on and cleave the Tormentor wave"; the spell-name field is
-- the honest source. nil when neither names one, and then there is no
-- line: "Divine Shield is worth using here" says nothing (Josh
-- 2026-09-09).
local function useTarget(b, kind)
	local declared = b.uses and b.uses[kind]
	if declared then return declared end
	for _, x in ipairs(b.notes or {}) do
		if x.ability then
			local list = type(x.tag) == "table" and x.tag or { x.tag }
			for _, tag in ipairs(list) do
				if TAG_KIND[tag] == kind then return x.ability end
			end
		end
	end
	return nil
end

-- The sentence for a spell of this kind against its target.
local USE_TEXT = {
	stun = "%s works well on %s", soothe = "%s works well on %s",
	dispel = "%s clears %s", purge = "%s strips %s", kick = "%s on %s",
}
local function useText(kind, name, target)
	return (USE_TEXT[kind] or "%s for %s"):format(name, target)
end

-- Rows the data adds for the reader on this boss (Josh 2026-09-09: "just
-- include a line item if the majority of players use X cooldown on a
-- fight", no numbers, no percentages). One line per spell most of the
-- reader's spec casts here that the rules above admit and no hand-written
-- line covers (`covered` = set of kinds), and one for where most groups
-- lust when no hand-written lust line exists and it is on the boss itself
-- (a lust on the way to the boss belongs to the stretch: see
-- stretchLustRow).
local function dataRows(b, covered)
	local entry = castsFor(b.name)
	local caps = KN.Player.Caps()
	local sid = caps and caps.id
	if not (entry and sid) then return {} end
	local out = {}
	local spec = entry.specs and entry.specs[sid]
	if spec then
		local kickSaid = covered.kick or mentionsKick(b)
		for _, s in ipairs(spec.s or {}) do
			local name, kind, cpf, share = s[1], s[2], s[3], s[4]
			local tag = KIND_TAG[kind]
			-- a spell name is not unique across specs: Elemental's Ascendance
			-- and Retribution's Avenging Wrath share names with healer
			-- cooldowns, so that kind is a healer's alone
			local admit = tag and kind ~= "lust" and not covered[kind]
				and share >= DATA_SHARE and cpf >= DATA_CPF
				and not (kind == "healercd" and caps.role ~= "healer")
			if admit and not SITUATIONAL[kind] then
				if kind == "kick" and kickSaid then
					admit = false
				else
					-- unusual means most of the spec presses it HERE and few do
					-- elsewhere; a tool used on half the bosses is a habit,
					-- not a note (the 378-run sample: Death Grip, Stampeding
					-- Roar on fifteen bosses each at the looser test)
					local usual = typicalShare(sid, name, entry)
					admit = usual == nil or usual < DATA_SHARE / 2
				end
			end
			local target = admit and useTarget(b, kind)
			if target then
				out[#out + 1] = tagged({}, tag, useText(kind, name, target))
			end
		end
	end
	local lust = entry.lust
	if lust and caps.lust and not covered.lust and (lust.n or 0) >= 3 then
		local text
		if lust.at then
			if lust.at < 0.1 then text = "Most groups lust on the pull"
			elseif lust.at > 0.7 then text = "Most groups lust at the end"
			else text = "Most groups lust partway through" end
		elseif (lust.on or 0) > (lust.before or 0) then
			text = "Most groups lust on this boss"
		end
		if text then out[#out + 1] = tagged({}, "LUST", text) end
	end
	return out
end

-- The lust line for a trash stretch: most ranked groups lust on the way to
-- the boss this stretch leads to. Only when no hand-written lust line sits
-- on the stretch already.
local function stretchLustRow(nextBoss, legHasLust)
	if legHasLust or not nextBoss or not KN.Player.Caps().lust then return nil end
	local entry = castsFor(nextBoss.name)
	local lust = entry and entry.lust
	if not (lust and (lust.n or 0) >= 3 and (lust.before or 0) > (lust.on or 0)) then return nil end
	return tagged({}, "LUST", "Most groups lust on this stretch")
end

-- "Atroxus  BOSS 2 OF 3" (with a small NEXT before the name on a trash
-- stretch), the numbered core lines, then the lines that are yours.
--
-- The lines that are yours show in the PREVIEW too (Josh 2026-09-09,
-- canvas round 6): the stretch before the boss is when people read them,
-- not the pull. `pulling` only decides the heading's NEXT prefix.
local function addBossRows(rows, b, idx, jb, pulling)
	local n = #state.dungeon.bosses
	local where = "Boss " .. (idx or "?") .. " of " .. n
	rows[#rows + 1] = { type = "section", label = where, name = b.name, pre = (not pulling) and "Next" or nil }
	local cores = addCoreRows(rows, b, jb)
	local mine, covered = {}, {}
	for _, x in ipairs(visibleNotes(b, jb)) do
		local r = yoursRow(x)
		mine[#mine + 1] = r
		if r.tag and TAG_KIND[r.tag] then covered[TAG_KIND[r.tag]] = true end
	end
	-- what most of this spec does here that no line above mentions, as
	-- plain lines among the others: they are notes, not a report
	local extra = dataRows(b, covered)
	if #mine > 0 or #extra > 0 then
		-- a small heading with the spec's icon and name (Josh 2026-09-09,
		-- round 8: tertiary, not a section, so it reads as part of the boss
		-- block); journal-built lines say where they came from beside it
		rows[#rows + 1] = { type = "subhead", label = KN.Player.SpecName(), icon = KN.Player.Icon(),
			text = state.dungeon.journal and "Adventure Guide" or nil }
		for _, r in ipairs(mine) do rows[#rows + 1] = r end
		for _, r in ipairs(extra) do rows[#rows + 1] = r end
	end
	-- a hand-written boss whose every line is gated by difficulty says so;
	-- a journal boss with no bullets (legacy content, Josh 2026-09-09 in
	-- Ragefire Chasm) just shows its heading
	if #mine == 0 and #extra == 0 and cores == 0 and not state.dungeon.journal then
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

local taskProgress -- defined with the scenario reads, below

-- Trash notes are a Mythic+ feature (Josh 2026-09-08): route knowledge is
-- what they are for, and outside a key nobody is routing. Mythic 0 counts
-- (Josh 2026-09-09, standing in a Mythic Murder Row with no snitch line):
-- it is the same dungeon, the same route and the same gates, key or not.
-- Normal and Heroic stay boss-only. A raid never has trash at all -
-- RegisterRaid refuses a trash table.
local function trashApplies()
	local d = state.dungeon
	return d ~= nil and d.kind ~= "raid" and d.trash ~= nil
		and (KN.DIFF_RANK[state.diff] or 0) >= KN.DIFF_RANK.m
end

-- Objective (TASK) lines are not trash notes: the snitches, the offerings,
-- the totems are the same gate on Normal as in a key, so they show at
-- every difficulty (Josh 2026-09-09). Below Mythic they get a heading of
-- their own, since "Trash" would promise mob lines that are not there.
local function addTrashRows(rows)
	local d = state.dungeon
	if d.kind ~= "raid" and d.trash then
		local full = trashApplies()
		local list = {}
		for _, t in ipairs(d.trash) do
			local inLeg = (t.leg == nil) or (t.leg == state.leg)
			if inLeg and (full or t.tag == "TASK") and diffOK(t.min) and forMe(t) then
				list[#list + 1] = t
			end
		end
		-- any hand-written lust on this stretch, whatever week it is for: the
		-- author already placed the lust per week, and the data mixes weeks
		local legHasLust = false
		for _, t in ipairs(d.trash) do
			if t.tag == "LUST" and (t.leg == nil or t.leg == state.leg) then legHasLust = true end
		end
		local lustRow = full and stretchLustRow(d.bosses[state.leg], legHasLust) or nil
		-- objectives first, above the trash heading (Josh 2026-09-09): a
		-- callout across the row, with the group's count leading when the
		-- game tracks one. Then the trash section, keystones and Mythic only.
		local tasks, mobs = {}, {}
		for _, t in ipairs(list) do
			if t.tag == "TASK" then tasks[#tasks + 1] = t else mobs[#mobs + 1] = t end
		end
		for _, t in ipairs(tasks) do
			local progress = taskProgress(t)
			rows[#rows + 1] = { type = "task", icon = KN.ICONS.TASK, tag = "TASK",
				text = (progress and (progress .. " ") or "") .. t.text }
		end
		if full then
			rows[#rows + 1] = { type = "section", label = "Trash", text = legLabel() }
			if lustRow then
				lustRow.type = "note"
				rows[#rows + 1] = lustRow
			end
			for _, t in ipairs(mobs) do
				if t.name then
					-- the text stands alone: written as its own sentence now that
					-- no tool word precedes it (Josh 2026-09-09)
					rows[#rows + 1] = decorate({ type = "mob", name = t.name, text = t.text }, t)
				else
					rows[#rows + 1] = decorate({ type = "note", text = t.text }, t)
				end
			end
			if #mobs == 0 and not lustRow then
				rows[#rows + 1] = { type = "note", text = "nothing noted for this stretch" }
			end
		end
	end
	-- A raid's boss order is not always a line. Wings can be cleared either
	-- way round, and `killed` is only a count, so naming one boss "next"
	-- would be a guess we cannot back up. List them and let ENCOUNTER_START
	-- pick the real one the moment a pull starts. A raid that declares
	-- `linear = true` (every Mists raid) has one fixed order and previews
	-- its next boss like a dungeon does (Josh 2026-09-08: "I should see the
	-- first boss").
	if d.kind == "raid" and not d.linear then
		rows[#rows + 1] = { type = "section", label = "Bosses", text = d.name }
		-- numbered rows, flush left: a `note` row would leave the label
		-- column empty and push every name 100px in (Josh 2026-09-08)
		for i, b in ipairs(d.bosses) do
			rows[#rows + 1] = { type = "core", num = i, text = b.name }
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
			-- Affixes.lua is retail-only; a Mists client never has affixes
			-- to look up, but never assume the file is there either
			local def = KN.AffixDef and KN.AffixDef(a.name)
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
		-- a Challenge Mode is "k" too, but has no level to show
		level = KN.KEYSTONES and state.diff == "k" and state.keyLevel or nil,
		forces = state.forces,
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
	-- Mists' Challenge Modes have no keystone and no affixes; the API is
	-- absent there too, but the client flag is the reason, not the guard
	if not KN.KEYSTONES or state.diff ~= "k"
		or not (C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo) then
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

-- Enemy Forces in a keystone (Josh 2026-09-09): the scenario's weighted
-- criterion, read as the percentage the game itself shows. Two API shapes:
-- C_ScenarioInfo.GetCriteriaInfo returns a table on current clients,
-- C_Scenario.GetCriteriaInfo a list of values on older ones. Nil outside a
-- key, or when nothing answers.
-- Every scenario criterion is kept (Josh 2026-09-09: "are we able to see
-- how many the group has completed?"): the dungeon's own objectives -
-- "Snitches interrogated 0/4" - are criteria too, at every difficulty, and
-- a TASK line that names its criterion (`progress = "Snitches"`) takes the
-- count as its prefix.
local function readForces()
	state.forces = nil
	state.criteria = nil
	-- the step: C_ScenarioInfo.GetScenarioStepInfo (a table) on current
	-- clients, C_Scenario.GetStepInfo (a list) on older ones. The count
	-- went missing in game with only the older call (Josh 2026-09-09).
	local n
	if C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo then
		local ok, step = pcall(C_ScenarioInfo.GetScenarioStepInfo)
		if ok and type(step) == "table" then n = plain(step.numCriteria) end
	end
	if not n and C_Scenario and C_Scenario.GetStepInfo then
		local ok, _, _, num = pcall(C_Scenario.GetStepInfo)
		n = ok and plain(num) or nil
	end
	if not n or n < 1 then return end
	local list = {}
	for i = 1, n do
		local info, description, quantityString, weighted
		if C_ScenarioInfo and C_ScenarioInfo.GetCriteriaInfo then
			local ok, t = pcall(C_ScenarioInfo.GetCriteriaInfo, i)
			if ok and type(t) == "table" then info = t end
		end
		if info then
			description, quantityString, weighted = plain(info.description), plain(info.quantityString), plain(info.isWeightedProgress)
		elseif C_Scenario and C_Scenario.GetCriteriaInfo then
			local ok, desc, _, _, _, _, _, _, qs, _, _, _, _, w = pcall(C_Scenario.GetCriteriaInfo, i)
			if ok then description, quantityString, weighted = plain(desc), plain(qs), plain(w) end
		end
		if type(quantityString) == "string" then
			if weighted then
				if KN.KEYSTONES and state.diff == "k" then
					local pct = tonumber(quantityString:match("(%d+%.?%d*)%%"))
					if pct then state.forces = pct end
				end
			elseif description then
				list[#list + 1] = { description = tostring(description), quantity = quantityString }
			end
		end
	end
	-- Dungeon objectives such as "Snitches interrogated: 0/4" are NOT
	-- scenario criteria (on Normal the criteria are the four boss kills;
	-- Josh's debug line, 2026-09-09). They are UI widgets at the top of the
	-- screen. Read the top-centre set and take any widget whose text holds
	-- an "n/m", under whatever label precedes the colon.
	local W = C_UIWidgetManager
	if W and W.GetAllWidgetsBySetID then
		local sets = {}
		for _, getter in ipairs({ "GetTopCenterWidgetSetID", "GetBelowMinimapWidgetSetID", "GetObjectiveTrackerWidgetSetID" }) do
			if W[getter] then
				local ok, id = pcall(W[getter])
				id = ok and plain(id) or nil
				if id then sets[#sets + 1] = id end
			end
		end
		local getters = { "GetTextWithStateWidgetVisualizationInfo", "GetStatusBarWidgetVisualizationInfo",
			"GetIconAndTextWidgetVisualizationInfo", "GetTextureAndTextWidgetVisualizationInfo",
			"GetTextWithSubtextWidgetVisualizationInfo", "GetIconTextAndBackgroundWidgetVisualizationInfo",
			"GetDoubleStatusBarWidgetVisualizationInfo", "GetTextColumnRowVisualizationInfo" }
		for _, setID in ipairs(sets) do
			local okAll, widgets = pcall(W.GetAllWidgetsBySetID, setID)
			for _, w in ipairs(okAll and type(widgets) == "table" and widgets or {}) do
				local wid = plain(w.widgetID)
				if wid then
					for _, g in ipairs(getters) do
						if W[g] then
							local okG, info = pcall(W[g], wid)
							local text = okG and type(info) == "table" and (plain(info.text) or plain(info.overrideBarText) or plain(info.label))
							if type(text) == "string" then
								-- the text arrives dressed: "|TInterface\ICONS\UI_Chat.BLP:20|t
								-- Snitches interrogated: |cffFFFFFF0/4" (Josh's dump,
								-- 2026-09-09). Strip textures, colours and links before
								-- reading the label, or the texture's own colon wins.
								local bare = text:gsub("|T.-|t", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
									:gsub("|H.-|h", ""):gsub("|h", ""):gsub("^%s+", ""):gsub("%s+$", "")
								local have, want = bare:match("(%d+)%s*/%s*(%d+)")
								if have then
									local label = bare:match("^(.-)%s*:%s*%d+%s*/") or bare:match("^(.-)%s*:") or bare
									list[#list + 1] = { description = label, quantity = have .. "/" .. want }
								end
								break
							end
						end
					end
				end
			end
		end
	end
	if #list > 0 then state.criteria = list end
end

-- "0/4" for the criterion a task names, or nil when no criterion matches
taskProgress = function(t)
	if not (t.progress and state.criteria) then return nil end
	local key = t.progress:lower()
	for _, c in ipairs(state.criteria) do
		if c.description:lower():find(key, 1, true) then return c.quantity end
	end
	return nil
end

local function readDifficulty()
	local _, instanceType, difficultyID = GetInstanceInfo()
	instanceType = plain(instanceType)
	difficultyID = plain(difficultyID)
	state.difficultyID = difficultyID
	state.diff = KN.DIFF_BY_ID[difficultyID or 0] or KN.DIFF_DEFAULT
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
local function resolveDungeon(instanceType)
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
	-- Nothing hand-written: fall back to the Adventure Guide's own role
	-- bullets, so the panel is never empty in a place the journal knows.
	if not def and instanceID then
		def = KN.Journal.Synthesize(instanceID, state.difficultyID,
			instanceType == "raid" and "raid" or "dungeon")
	end
	dbg.matched = def and (def.name .. (def.journal and " (Adventure Guide)" or "")) or nil
	dbg.ambiguous = dbgAmbiguous
	dbgAmbiguous = nil
	return def, instanceID
end

-- Whether this instance has one fixed boss order, so an index into
-- def.bosses is a position on the way through it.
local function ordered(def)
	return def and (def.kind ~= "raid" or def.linear) and true or false
end

-- How many bosses the saved-instance lock says are already dead here, for
-- an instance with a fixed order: the number of leading bosses the lock
-- marks defeated. Joining a raid in progress (Josh 2026-09-10: on
-- Galakras, the panel said Immerseus) or reloading mid-run leaves `killed`
-- at zero otherwise, since only kills seen this session count. The lock
-- is per player and per difficulty (a 10 Player and a 10 Player (Heroic)
-- lock sit side by side in Raid Info), so the one for the difficulty we
-- stand in wins. Its boss names are the lock's own ("Fallen Protectors",
-- not "The Fallen Protectors"), matched the loose way findDataBoss does.
-- nil until the game has saved you; UPDATE_INSTANCE_INFO re-reads it.
local function savedKills(def)
	if not ordered(def) then return nil end
	local ok, n = pcall(GetNumSavedInstances)
	if not ok or not n or n == 0 then return nil end
	local here = plain((GetInstanceInfo()))
	if not here then return nil end
	local best, bestDiff
	for i = 1, n do
		local name, _, _, difficulty, locked, _, _, _, _, _, encounters = GetSavedInstanceInfo(i)
		name = plain(name)
		if name and name:lower() == here:lower() and plain(locked) and (plain(encounters) or 0) > 0 then
			local sameDiff = plain(difficulty) == state.difficultyID
			if not best or (sameDiff and not bestDiff) then
				best, bestDiff = i, sameDiff
			end
		end
	end
	if not best then return nil end
	local dead = {}
	local _, _, _, _, _, _, _, _, _, _, encounters = GetSavedInstanceInfo(best)
	for j = 1, plain(encounters) or 0 do
		local bossName, _, isKilled = GetSavedInstanceEncounterInfo(best, j)
		bossName = plain(bossName)
		if bossName and plain(isKilled) then dead[#dead + 1] = bossName:lower() end
	end
	local function isDead(b)
		local bn = b.name:lower()
		for _, dn in ipairs(dead) do
			if dn == bn or bn:find(dn, 1, true) or dn:find(bn, 1, true) then return true end
		end
		return false
	end
	local killed = 0
	for _, b in ipairs(def.bosses) do
		if not isDead(b) then break end
		killed = killed + 1
	end
	return killed > 0 and killed or nil
end

local retries = 0
function Tracker.Refresh(reason)
	wipe(dbg)
	local instanceType = readDifficulty()
	dbg.instanceType = instanceType
	dbg.difficultyID = state.difficultyID
	dbg.reason = reason
	-- "party" is a dungeon, "raid" a raid. This once accepted only "party"
	-- and silently dropped every raid, so Siege of Orgrimmar showed "No
	-- dungeon notes here" while standing inside it (Josh 2026-09-08).
	if instanceType ~= "party" and instanceType ~= "raid" then
		state.inDungeon = false
		if state.preview then return end
		state.dungeon = nil
		state.boss = nil
		Tracker.Render()
		return
	end
	state.preview = false
	local def, instanceID = resolveDungeon(instanceType)
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
		-- the lock data arrives on UPDATE_INSTANCE_INFO, which re-reads
		if def then pcall(RequestRaidInfo) end
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
	readForces()
	if def and not state.manualLeg then
		local k = savedKills(def)
		if k and k > state.killed then state.killed = k end
	end
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
	local boss, idx = findDataBoss(name)
	state.boss = boss
	state.journalBoss = findJournalBoss(name)
	if not state.boss and name then
		state.boss = { name = name, notes = {} }
	end
	-- The pull is ground truth for where the group is: a raid joined in
	-- progress, or a reload, has `killed` at zero and would otherwise
	-- name boss 1 "next" after a wipe on boss 5 (Josh 2026-09-10).
	if idx and ordered(state.dungeon) then
		state.killed = idx - 1
		state.manualLeg = nil
		state.leg = idx
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
	-- nothing to page in a raid with wings: no trash, no fixed boss order
	if state.dungeon.kind == "raid" and not state.dungeon.linear then return end
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
		-- a previewed boss must not survive into the live instance: the
		-- same dungeon resolving again keeps state.boss, and the panel would
		-- open on a boss nobody is pulling
		state.boss, state.journalBoss, state.manualLeg = nil, nil, nil
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
	-- a dungeon previews at its top rank ("k": a keystone, or a Challenge
	-- Mode on Mists); a raid has no "k" and previews at the client's top raid
	-- difficulty instead
	local fallback = def.kind == "raid" and KN.RAID_DEFAULT or "k"
	state.diff = KN.DIFF_RANK[diff or ""] and diff or fallback
	state.bosses = nil
	state.killed = 0
	state.manualLeg = nil
	state.leg = 1
	state.boss = nil
	state.keyLevel = nil
	state.affixes = nil
	state.forces = nil -- a preview is not a run in progress
	state.criteria = nil
	-- a level and affixes are a keystone's, so a Mists Challenge Mode
	-- preview invents neither
	if KN.KEYSTONES and state.diff == "k" then
		state.keyLevel = level or 10
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

-- /tp notes check [instance]: where the hand-written lines and the ranked-
-- run data disagree. For every boss and every spec the data holds:
--   ADDS      the line the panel would add from the data for that spec,
--             which is also the line a hand-written note could replace
--   DOUBTFUL  the spec sees a line for a kind fewer than one in ten of
--             them ever cast
-- Each spec is tried on through the override, then the override is put
-- back. Diagnostic only; prints nothing for a boss that agrees.
function Tracker.CheckLines(query)
	local out = {}
	if not TP.BossCasts then return { "no ranked-run data loaded (Data/BossCasts*.lua)" } end
	local q = (query or ""):lower()
	local keepDungeon, keepBoss, keepOverride = state.dungeon, state.boss, KN.Player.state.override
	local missing, doubtful, bosses = 0, 0, 0
	for _, d in ipairs(KN.instances) do
		if q == "" or d.name:lower():find(q, 1, true) then
			state.dungeon = d
			for _, b in ipairs(d.bosses) do
				local entry = castsFor(b.name)
				if entry and entry.specs then
					bosses = bosses + 1
					for sid, spec in pairs(entry.specs) do
						local row = KN.CLASSES[sid]
						if row then
							KN.Player.state.override = { label = row.name, caps = row, role = row.role, range = row.range, class = row.class }
							local seen = {}
							for _, x in ipairs(visibleNotes(b, nil)) do
								local r = yoursRow(x)
								if r.tag and TAG_KIND[r.tag] then seen[TAG_KIND[r.tag]] = true end
							end
							for _, r in ipairs(dataRows(b, seen)) do
								if r.tag ~= "LUST" then
									missing = missing + 1
									out[#out + 1] = ("ADDS     %s / %s: %s"):format(d.name, b.name, r.text)
								end
							end
							local cast = {}
							for _, s in ipairs(spec.s or {}) do
								cast[s[2]] = math.max(cast[s[2]] or 0, s[4])
							end
							for kind in pairs(seen) do
								if kind ~= "defensive" and kind ~= "healercd" and (cast[kind] or 0) < 0.1 then
									doubtful = doubtful + 1
									out[#out + 1] = ("DOUBTFUL %s / %s: %s %s sees a %s line, %d%% cast one")
										:format(d.name, b.name, row.name, row.class, kind, math.floor((cast[kind] or 0) * 100 + 0.5))
								end
							end
						end
					end
				end
			end
		end
	end
	state.dungeon, state.boss, KN.Player.state.override = keepDungeon, keepBoss, keepOverride
	table.insert(out, 1, ("check: %d bosses with data, %d lines the data adds, %d doubtful"):format(bosses, missing, doubtful))
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
	out[#out + 1] = "forces=" .. v(state.forces)
		.. " (stepInfo=" .. tostring(C_ScenarioInfo and C_ScenarioInfo.GetScenarioStepInfo ~= nil)
		.. " legacyStep=" .. tostring(C_Scenario and C_Scenario.GetStepInfo ~= nil)
		.. " widgets=" .. tostring(C_UIWidgetManager and C_UIWidgetManager.GetAllWidgetsBySetID ~= nil) .. ")"
	-- escape codes shown literally, so a colour code or texture in a
	-- widget's text is visible rather than swallowed by the chat frame
	local function raw(s)
		if s == nil then return "nil" end
		if IsSecret(s) then return "SECRET" end
		s = tostring(s):gsub("|", "||"):gsub("\n", "\\n")
		return "[" .. s .. "] len=" .. #tostring(s)
	end
	for _, c in ipairs(state.criteria or {}) do
		out[#out + 1] = "  criterion: " .. raw(c.description) .. " = " .. raw(c.quantity)
	end
	-- every widget in the top-centre set, raw: which getter answered and
	-- what it said, so a count that never arrives shows why
	local W = C_UIWidgetManager
	if W and W.GetTopCenterWidgetSetID and W.GetAllWidgetsBySetID then
		local okS, setID = pcall(W.GetTopCenterWidgetSetID)
		local widgets
		if okS then
			local okA, list = pcall(W.GetAllWidgetsBySetID, setID)
			if okA and type(list) == "table" then widgets = list end
		end
		out[#out + 1] = "  top-centre widget set " .. v(setID) .. ": " .. tostring(widgets and #widgets or "?") .. " widgets"
		for _, w in ipairs(widgets or {}) do
			local line = "    widget " .. v(w.widgetID) .. " type " .. v(w.widgetType)
			for name, fn in pairs(W) do
				if type(fn) == "function" and name:find("VisualizationInfo", 1, true) and not IsSecret(w.widgetID) then
					local ok, info = pcall(fn, w.widgetID)
					if ok and type(info) == "table" and (info.text ~= nil or info.overrideBarText ~= nil) then
						line = line .. " " .. name:gsub("WidgetVisualizationInfo", "") .. " text=" .. raw(info.text or info.overrideBarText)
						break
					end
				end
			end
			out[#out + 1] = line
		end
	end
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
	elseif event == "SCENARIO_CRITERIA_UPDATE" or event == "CRITERIA_UPDATE" or event == "UPDATE_UI_WIDGET" then
		-- enemy forces or an objective count moved. UPDATE_UI_WIDGET fires
		-- every second in a dungeon (a timer widget ticks), so the re-read
		-- is coalesced to one per half second, and the panel re-renders only
		-- when a value actually changed.
		if state.dungeon and not state.preview and not Tracker.criteriaPending then
			Tracker.criteriaPending = true
			C_Timer.After(0.5, function()
				Tracker.criteriaPending = false
				if not state.dungeon or state.preview then return end
				local function key()
					local parts = { tostring(state.forces) }
					for _, c in ipairs(state.criteria or {}) do parts[#parts + 1] = c.description .. "=" .. c.quantity end
					return table.concat(parts, "|")
				end
				local before = key()
				readForces()
				if key() ~= before then Tracker.Render() end
			end)
		end
	else
		-- map data can lag the zone event by a frame
		C_Timer.After(0.5, function() Tracker.Refresh(event) end)
	end
end)

function Tracker.OnEnable()
	for _, e in ipairs({ "PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA", "CHALLENGE_MODE_START", "UPDATE_INSTANCE_INFO",
		"ENCOUNTER_START", "ENCOUNTER_END", "SCENARIO_CRITERIA_UPDATE", "CRITERIA_UPDATE", "UPDATE_UI_WIDGET" }) do
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
		-- /tp notes show siege of orgrimmar h
		--
		-- Names are several words ("Siege of Orgrimmar", "Ruby Life Pools"),
		-- so the name is the leading run of words up to the first modifier:
		-- a difficulty letter, a level, or an affix the client knows. Every
		-- word after that first modifier is a modifier too, and an unknown
		-- one is taken as an affix name, as before. Taking only the first
		-- word made "siege of orgrimmar" a search for "siege", which matches
		-- two instances and was refused (Josh 2026-09-08).
		local function modifier(lw)
			if KN.DIFF_RANK[lw] then return "diff" end
			if tonumber((lw:gsub("^%+", ""))) then return "level" end
			if KN.AffixDef and KN.AffixDef((lw:gsub("^%l", string.upper))) then return "affix" end
			return nil
		end
		local nameWords, diff, level, affixes = {}, nil, nil, {}
		local inModifiers = false
		for w in rest:gmatch("%S+") do
			local lw = w:lower()
			local kind = modifier(lw)
			if not inModifiers and not kind then
				nameWords[#nameWords + 1] = w
			else
				inModifiers = true
				if kind == "diff" then diff = lw
				elseif kind == "level" then level = tonumber((lw:gsub("^%+", "")))
				else affixes[#affixes + 1] = (lw:gsub("^%l", string.upper)) end
			end
		end
		local name = #nameWords > 0 and table.concat(nameWords, " ") or nil
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
		if not KN.LadderLines then
			KN.Print("No keystone ladder on this client: Mists has Challenge Modes, not Mythic+.")
			return true
		end
		local level = tonumber(rest) or state.keyLevel
		KN.Print("Season 2 keystone ladder" .. (level and (" (at +" .. level .. ")") or ""))
		for _, row in ipairs(KN.LadderLines(level)) do
			local mark = row.active and "|cffffd36e> |r" or "  "
			KN.Print(mark .. row.range .. ": " .. row.text)
		end
	elseif cmd == "debug" then
		for _, line in ipairs(Tracker.DebugLines()) do KN.Print(line) end
	elseif cmd == "check" then
		for _, line in ipairs(Tracker.CheckLines(rest)) do KN.Print(line) end
	elseif cmd == "spec" then
		-- just the player line, re-read now: the first line of `debug`
		-- scrolls away behind the journal dump
		KN.Player.Refresh()
		KN.Print(KN.Player.DebugLine())
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
