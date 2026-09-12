-- Headless test for the Notes view: every spec sees the same core rows, only
-- its own tools, only its role's lines, and the lust call follows the week.
-- Renders through tests/uistub.lua so the row builders run against a strict
-- widget stub (wrong SetFont/SetText argument types fail here, not in game).
--
--   lua tests/notes.lua
package.path = "tests/?.lua;" .. package.path
local stub = require("uistub")
stub.install(_G)

_G.WOW_PROJECT_ID, _G.WOW_PROJECT_MAINLINE, _G.WOW_PROJECT_MISTS_CLASSIC = 1, 1, 5
_G.issecretvalue = function() return false end
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.C_Timer = { After = function(_, fn) fn() end }
_G.SlashCmdList = {}
_G.LibStub = function() return nil end
_G.GetInstanceInfo = function() return "Nowhere", "none", 0 end
_G.C_Map = { GetBestMapForUnit = function() return nil end }
local FAKE = { class = "SHAMAN", specID = 264, role = "HEALER" }
_G.UnitClass = function() return "Shaman", FAKE.class end
_G.GetSpecialization = function() return 1 end
_G.GetSpecializationInfo = function() return FAKE.specID, "x", "", 0, FAKE.role end

local fails = 0
local function check(cond, label)
	if cond then
		print("ok   " .. label)
	else
		fails = fails + 1
		print("FAIL " .. label)
	end
end

-- The Notes\ lines of a TOC, in order. The test boots from the TOC rather
-- than a hand-kept list so that what it proves is what the client loads:
-- the file set, the order, and (for Mists) the absence of Season2.lua.
local function notesFiles(toc)
	local out = {}
	for line in io.lines(toc) do
		line = line:gsub("^\239\187\191", ""):gsub("%s+$", "")
		if line:match("^Notes\\") then out[#out + 1] = (line:gsub("\\", "/")) end
	end
	return out
end

local invalidated = 0
local printed = {}
-- A fresh addon namespace per client, exactly as tests/load.lua does: the
-- two TOCs load different Notes files and must not inherit each other's
-- tables. WOW_PROJECT_ID is read by Core/Compat.lua at load, so it is set
-- before anything is loaded.
local function boot(project, toc)
	_G.WOW_PROJECT_ID = project
	local TP = {}
	TP.Addon = {
		db = { profile = { window = { view = "notes" }, notes = { autoSwitch = false } }, global = {} },
		Print = function(_, msg) printed[#printed + 1] = tostring(msg) end,
		HandleSlash = function() end,
	}
	TP.MeterWindow = {
		Invalidate = function() invalidated = invalidated + 1 end,
		SetView = function(_, v) TP.Addon.db.profile.window.view = v end,
		ResetNotesScroll = function() end,
	}
	local function load(path)
		assert(loadfile(path), "cannot load " .. path)("TrueParse", TP)
	end
	load("Core/Compat.lua")
	for _, f in ipairs(notesFiles(toc)) do load(f) end
	TP.Notes:OnEnable()
	return TP, TP.Notes
end

local TP, KN = boot(1, "TrueParse.toc")
local retailKN = KN

local function become(specID)
	local row = KN.CLASSES[specID]
	FAKE.class, FAKE.specID = row.class, specID
	FAKE.role = ({ tank = "TANK", healer = "HEALER", dps = "DAMAGER" })[row.role]
	KN.Player.Refresh()
end
local function has(rows, pred)
	for _, r in ipairs(rows) do if pred(r) then return true end end
	return false
end
-- a row's family icon: mob/note rows carry it; a boss line that is yours
-- carries only its tag, the icon having been dropped from the design
local function iconOf(r) return r.icon or (r.tag and KN.ICONS[r.tag]) end
local function isLust(r) return iconOf(r) == KN.ICONS.LUST end

-- 1. Every spec, every dungeon, boss and trash, on both weeks: nothing for a
--    tool the spec lacks, nothing for another role, core rows for everyone.
local specs, audited, bad = 0, 0, nil
for specID, row in pairs(KN.CLASSES) do
	become(specID)
	specs = specs + 1
	for _, d in ipairs(KN.instances) do
		local dname = d.name
		for _, week in ipairs({ { "Tyrannical", "Xal'atath's Bargain: Devour" }, { "Fortified", "Xal'atath's Bargain: Pulsar" } }) do
			KN.Tracker.Preview(dname, "k", 9, week)
			local function audit(rs, where)
				for _, r in ipairs(rs) do
					local why
					local icon = iconOf(r)
					if isLust(r) and not row.lust then why = "lust"
					elseif icon == KN.ICONS.TANK and row.role ~= "tank" then why = "tank"
					elseif icon == KN.ICONS.CD and row.role ~= "healer" then why = "cooldown"
					elseif icon == KN.ICONS.KICK and not row.kick then why = "kick"
					elseif icon == KN.ICONS.PURGE and not row.purge then why = "purge"
					elseif icon == KN.ICONS.POISON and not row.poison then why = "poison"
					elseif icon == KN.ICONS.MAGIC and not row.magic then why = "magic"
					elseif icon == KN.ICONS.CURSE and not row.curse then why = "curse"
					elseif icon == KN.ICONS.FEAR and not row.fear then why = "fear"
					elseif icon == KN.ICONS.MASSDISP and not row.massdispel then why = "mass dispel"
					elseif icon == KN.ICONS.BUILD and row.class ~= "SHAMAN" then why = "talents"
					end
					if why and not bad then bad = row.name .. " saw a " .. why .. " line at " .. where end
					audited = audited + 1
				end
			end
			local rows = KN.Tracker.Rows()
			if not (rows[1].type == "header" and #rows[1].affixes == 2 and rows[1].level == 9) and not bad then
				bad = dname .. ": header missing affixes or level"
			end
			audit(rows, dname .. " trash " .. week[1])
			for i, b in ipairs(d.bosses) do
				KN.Tracker.PreviewBoss(b.name)
				local br = KN.Tracker.Rows()
				audit(br, dname .. "/" .. b.name .. " " .. week[1])
				if not (br[2].type == "section" and br[2].label == ("Boss " .. i .. " of " .. #d.bosses) and br[3].type == "core" and br[3].num == 1) and not bad then
					bad = dname .. "/" .. b.name .. ": boss title or first core row wrong"
				end
			end
		end
	end
end
check(bad == nil, "every spec sees only its own lines (" .. specs .. " specs, " .. audited .. " rows)" .. (bad and (": " .. bad) or ""))

-- 2. Lust follows the week on a lust class
become(264)
KN.Tracker.Preview("Voidscar", "k", 9, { "Tyrannical", "Xal'atath's Bargain: Devour" })
check(not has(KN.Tracker.Rows(), isLust), "Tyrannical: no lust on the opening stretch")
KN.Tracker.PreviewBoss("Atroxus")
check(has(KN.Tracker.Rows(), function(x) return isLust(x) and x.text:find("on the first Creeper", 1, true) end), "Tyrannical: Atroxus carries the lust")
KN.Tracker.Preview("Voidscar", "k", 8, { "Fortified", "Xal'atath's Bargain: Pulsar" })
check(has(KN.Tracker.Rows(), function(x) return isLust(x) and x.text == "the opening pack" end), "Fortified: the opening pack carries the lust")
KN.Tracker.PreviewBoss("Atroxus")
check(not has(KN.Tracker.Rows(), isLust), "Fortified: Atroxus has no lust line")
KN.Tracker.Preview("Voidscar", "n")
check(not has(KN.Tracker.Rows(), isLust), "Normal: no Fortified trash lust")
KN.Tracker.PreviewBoss("Atroxus")
check(has(KN.Tracker.Rows(), isLust), "Normal: boss lust shows")
check(KN.Tracker.Rows()[1].affixes == nil and KN.Tracker.Rows()[1].level == nil, "Normal header has no affixes or level")

-- 3. Labels are the player's spell; a hunter on Curse of Doom sees KICK
become(257)
KN.Tracker.Preview("Murder", "k"); KN.Tracker.PreviewBoss("Kystia")
check(KN.Player.Label("MAGIC") == "Purify", "Holy Priest magic label is Purify")
become(253)
KN.Tracker.Preview("Murder", "k")
local warlockLine
for _, r in ipairs(KN.Tracker.Rows()) do if r.name == "Corrupted Warlock" then warlockLine = r end end
check(warlockLine and warlockLine.icon == KN.ICONS.KICK, "hunter sees the Curse of Doom line as a kick")

-- 4. Override
check(KN.Player.SetOverride("brewmaster"):find("Brewmaster"), "override to brewmaster")
check(KN.Player.Role() == "tank" and KN.Player.Label("POISON") == "Detox", "override role and label")
KN.Player.SetOverride("")

-- 5. Render through the strict widget stub: heights positive, overflow caps
become(264)
KN.Tracker.Preview("Voidscar", "k", 9, { "Tyrannical", "Xal'atath's Bargain: Devour" }); KN.Tracker.PreviewBoss("Charonus")
local parent = CreateFrame("Frame", "TrueParseWindowStub")
local used = KN.View:Render(parent, KN.Tracker.Rows(), 6, -28, 368)
check(used > 100, ("render has height: %d"):format(used))
local sections, yours = 0, 0
for _, r in ipairs(KN.Tracker.Rows()) do
	if r.type == "section" then sections = sections + 1 end
	if r.type == "yours" then yours = yours + 1 end
end
check(sections == 1 and yours > 0, "boss view has one boss heading, the lines that are yours under it with no heading of their own")
KN.Tracker.Preview("Murder", "k")
local labels = {}
for _, r in ipairs(KN.Tracker.Rows()) do
	if r.type == "section" then labels[#labels + 1] = (r.pre and (r.pre .. " · ") or "") .. r.label end
end
check(labels[1] == "Trash" and labels[2] == "Next · Boss 1 of 4", "trash view headings: " .. table.concat(labels, " | "))
do -- the objective sits above the trash heading, first under the band
	local rs = KN.Tracker.Rows()
	check(rs[2].type == "task" and rs[3].type == "section" and rs[3].label == "Trash", "the objective callout comes before the Trash heading")
end
check(has(KN.Tracker.Rows(), function(r) return r.type == "yours" end), "the preview carries the lines that are yours")
check(has(KN.Tracker.Rows(), function(r) return r.type == "task" and r.icon == KN.ICONS.TASK end), "the objective is a callout row")
check(not has(KN.Tracker.Rows(), function(r) return r.type == "section" and r.right ~= nil end), "the stretch heading carries no counter")

-- the lines that are yours: your spec's icon in the numeral column, then
-- one full sentence with the family's generic verb folded in; no tag
-- word, no spec spell name, no heading
local realInfoFn = _G.GetSpecializationInfo
_G.GetSpecializationInfo = function() return FAKE.specID, "x", "", 135893, FAKE.role end
become(66) -- Protection Paladin
KN.Tracker.Preview("Murder", "k"); KN.Tracker.PreviewBoss("Kystia")
check(has(KN.Tracker.Rows(), function(r) return r.type == "subhead" and r.label == "Protection Paladin" and r.icon == 135893 end),
	"a small heading carries the spec's name and icon")
check(has(KN.Tracker.Rows(), function(r) return r.type == "yours" and r.tag == "TANK" and r.icon == nil and r.label == nil and r.text:find("^Defensive for Envenom") end),
	"a tank line is a bare sentence under it")
become(65) -- Holy Paladin
KN.Tracker.Preview("Murder", "k"); KN.Tracker.PreviewBoss("Kystia")
check(has(KN.Tracker.Rows(), function(r) return r.type == "yours" and r.tag == "MAGIC" and r.icon == nil and r.label == nil
		and r.text == "Dispel Corroding Spittle off immediately" end),
	"a dispel line reads 'Dispel Corroding Spittle off immediately', not the spec's spell name")
check(has(KN.Tracker.Rows(), function(r) return r.type == "yours" and r.tag == "CD" and r.text == "Cooldown for every Chaotic Burst phase" end),
	"a healer cooldown line reads 'Cooldown for every ...' with the leading Every lowered")
KN.Tracker.Preview("Ruby", "k"); KN.Tracker.PreviewBoss("Melidrussa")
check(has(KN.Tracker.Rows(), function(r) return r.tag == "CD" and r.text:find("^Cooldown for Frost Overload") end),
	"a leading ability name keeps its capital")
KN.Player.SetOverride("tank")
KN.Tracker.Preview("Murder", "k"); KN.Tracker.PreviewBoss("Kystia")
check(has(KN.Tracker.Rows(), function(r) return r.type == "subhead" and r.label == "as tank" and r.icon == nil end),
	"under an override the heading names the override and carries no icon, since it is not your spec")
KN.Player.SetOverride("")
_G.GetSpecializationInfo = realInfoFn
become(264)
check(KN.Tracker.Rows()[1].role == "Healer · Ranged", "role line reads Healer · Ranged")
KN.View:Hide()

-- 6. Commands route
check(KN:Command("show altar k 12 tyrannical fortified guile") and KN.Tracker.state.keyLevel == 12, "/tp notes show parses level and affixes")
check(#KN.Tracker.Rows()[1].affixes == 3, "three affixes in the header")
-- multi-word names: the name runs up to the first difficulty, level or
-- known affix, so "ruby life pools" is one instance, not "ruby" plus two
-- affixes called Life and Pools
check(KN:Command("show ruby life pools k 9 tyrannical devour") and KN.Tracker.state.dungeon.name == "Ruby Life Pools"
	and KN.Tracker.state.keyLevel == 9 and #KN.Tracker.state.affixes == 2, "/tp notes show takes a multi-word name")
check(KN:Command("show den of nalorakk") and KN.Tracker.state.dungeon.name == "Den of Nalorakk",
	"a multi-word name with no modifiers previews")
check(KN:Command("ladder 12") and KN:Command("list") and KN:Command("as tank") and not KN:Command("bogus"), "command routing")
check(KN:Command("journal"), "/tp notes journal routes without the journal API present")
check(invalidated > 0, "state changes invalidate the meter window")

-- 7. Trash is a Mythic+ feature (Josh 2026-09-08). Below a key the stretch
--    between bosses carries no trash section, but the next boss still previews.
--    Test 6 left an "as tank" override in place, and Player.Caps() answers
--    from the override, not the spec - so every capability test below would
--    read the spec that was current back then. Clear it first.
KN.Player.SetOverride("")

-- a section's full reading: "Next · Boss 1 of 4" when the heading carries
-- the small NEXT prefix, else the label alone
local function sectionLabels(rows)
	local out = {}
	for _, r in ipairs(rows) do
		if r.type == "section" then out[#out + 1] = (r.pre and (r.pre .. " · ") or "") .. r.label end
	end
	return out
end
local function hasSection(rows, label)
	for _, l in ipairs(sectionLabels(rows)) do if l == label then return true end end
	return false
end
local function hasIcon(rows, icon)
	for _, r in ipairs(rows) do if iconOf(r) == icon then return true end end
	return false
end

become(264)
KN.Tracker.Preview("Voidscar", "k", 9, { "Fortified", "Xal'atath's Bargain: Pulsar" })
check(hasSection(KN.Tracker.Rows(), "Trash"), "keystone still shows the trash section")
-- Mythic 0 is the same route as the key (Josh 2026-09-09): trash shows
KN.Tracker.Preview("Murder", "m")
check(hasSection(KN.Tracker.Rows(), "Trash")
	and has(KN.Tracker.Rows(), function(r) return r.icon == KN.ICONS.TASK and r.text:lower():find("snitch", 1, true) end),
	"Mythic 0 shows the trash section, snitches included")
local belowMythic = true
for _, d in ipairs({ "h", "n" }) do
	KN.Tracker.Preview("Voidscar", d)
	if hasSection(KN.Tracker.Rows(), "Trash") then belowMythic = false end
end
check(belowMythic, "no trash section on Heroic or Normal")
-- objectives are the same gate at every difficulty (Josh 2026-09-09): on
-- Normal the snitch line shows under its own heading, with no mob rows
KN.Tracker.Preview("Murder", "n")
local normalRows = KN.Tracker.Rows()
check(not hasSection(normalRows, "Objectives") and not hasSection(normalRows, "Trash")
	and normalRows[2].type == "task" and normalRows[2].text:lower():find("snitch", 1, true)
	and not has(normalRows, function(r) return r.type == "mob" end),
	"Normal shows the snitch objective first under the band, no heading, no mob lines")
KN.Tracker.Preview("Voidscar", "n")
KN.Tracker.Step(1) -- the second stretch: no objective there
check(not hasSection(KN.Tracker.Rows(), "Objectives") and hasSection(KN.Tracker.Rows(), "Next · Boss 2 of 3"),
	"a stretch with no objective gets no Objectives heading")
KN.Tracker.Preview("Voidscar", "n")
check(hasSection(KN.Tracker.Rows(), "Next · Boss 1 of 3"), "the next boss still previews below a key")

-- 8. Raids are boss-only: no trash accepted, none rendered, no leg paging.
KN.RegisterRaid({
	name = "Test Raid",
	bosses = {
		{ name = "Shielded One", core = { "stack behind it" }, notes = {
			{ tag = "MASSDISP", need = "massdispel", text = "the bubble, nothing else takes it off" },
			{ tag = "FEAR", need = "fear", text = "the fear it puts on the group" },
		} },
		{ name = "Second One", core = { "spread" } },
	},
})
check(KN.Find("Test Raid").kind == "raid", "RegisterRaid marks the instance as a raid")
check(KN.Find("Voidscar Arena").kind == "dungeon", "RegisterDungeon marks the instance as a dungeon")
check(not pcall(KN.RegisterRaid, { name = "Bad Raid", bosses = {}, trash = {} }),
	"RegisterRaid refuses a trash table outright")

KN.Tracker.Preview("Test Raid", "h")
local raidRows = KN.Tracker.Rows()
check(not hasSection(raidRows, "Trash"), "a raid never renders a trash section")
check(hasSection(raidRows, "Bosses"), "a raid with wings lists its bosses instead of guessing which is next")
local listed = 0
for _, r in ipairs(raidRows) do if r.type == "core" and r.num then listed = listed + 1 end end
check(listed == 2, "the list is numbered rows, flush left")
local legBefore = KN.Tracker.state.leg
KN.Tracker.Step(1)
check(KN.Tracker.state.leg == legBefore, "leg paging is inert in a raid")

-- 9. The two new capabilities reach only the specs that hold them.
become(257) -- Holy Priest: Mass Dispel and Fear Ward
KN.Tracker.Preview("Test Raid", "h"); KN.Tracker.PreviewBoss("Shielded One")
check(hasIcon(KN.Tracker.Rows(), KN.ICONS.MASSDISP), "a Priest sees the Mass Dispel line")
become(264) -- Restoration Shaman: Tremor Totem, but no Mass Dispel
KN.Tracker.Preview("Test Raid", "h"); KN.Tracker.PreviewBoss("Shielded One")
check(not hasIcon(KN.Tracker.Rows(), KN.ICONS.MASSDISP), "a Shaman does NOT see the Mass Dispel line")
check(hasIcon(KN.Tracker.Rows(), KN.ICONS.FEAR), "a Shaman does see the fear line")
become(62) -- Arcane Mage: neither tool
KN.Tracker.Preview("Test Raid", "h"); KN.Tracker.PreviewBoss("Shielded One")
check(not hasIcon(KN.Tracker.Rows(), KN.ICONS.MASSDISP) and not hasIcon(KN.Tracker.Rows(), KN.ICONS.FEAR),
	"a Mage sees neither line")

-- 10. Fear Ward was removed in 7.0.3, so a Priest has no dedicated fear
--     answer: only the Shaman's Tremor Totem carries `fear`.
become(257)
KN.Tracker.Preview("Test Raid", "h"); KN.Tracker.PreviewBoss("Shielded One")
check(not hasIcon(KN.Tracker.Rows(), KN.ICONS.FEAR), "a Priest does NOT see the fear line (no Fear Ward)")

-- 11. The registry is keyed by journal instanceID, because names collide.
local before = #KN.instances
check(not pcall(KN.RegisterDungeon, { name = "Voidscar Arena", bosses = {} }),
	"a duplicate name with no instanceID is refused")
check(#KN.instances == before, "a refused registration leaves the registry untouched")

KN.RegisterDungeon({ name = "Twin Halls", instanceID = 9001,
	bosses = { { name = "Alpha", core = { "left" } } } })
KN.RegisterDungeon({ name = "Twin Halls", instanceID = 9002,
	bosses = { { name = "Beta", core = { "right" } } } })
check(KN.byInstanceID[9001].bosses[1].name == "Alpha"
	and KN.byInstanceID[9002].bosses[1].name == "Beta",
	"two instances may share a name when both declare an instanceID")
check(KN.Find("Twin Halls", 9002).bosses[1].name == "Beta",
	"the journal instanceID picks the right one")
local _, why = KN.Find("Twin Halls")
check(why == "ambiguous", "a colliding name on its own resolves to nothing, not a guess")
check(not pcall(KN.RegisterRaid, { name = "Somewhere Else", instanceID = 9001, bosses = {} }),
	"a reused instanceID is refused")
check(KN.Find("Voidscar Arena").kind == "dungeon", "an unambiguous name still resolves")
check(KN.Find("necrotic wake") == nil, "an unknown name resolves to nothing")

-- previewing an ambiguous name must refuse rather than pick one
KN.Tracker.Preview("Voidscar", "k")
local keep = KN.Tracker.state.dungeon
KN.Tracker.Preview("Twin Halls")
check(KN.Tracker.state.dungeon == keep, "preview refuses an ambiguous name instead of guessing")

-- 11b. Ranked-run casts (Data/BossCasts*.lua shape) add a line only for a
--      kind no hand-written line covers, phrased per spec; lust timing
--      reaches lust specs; /tp notes check reports the disagreements.
do
	TP.BossCasts = {
		["Murder Row"] = {
			["Kystia Manaheart"] = { n = 40, lust = { n = 12, on = 10, before = 2 }, specs = {
				[70] = { n = 9, s = { { "Rebuke", "kick", 4, 0.89 }, { "Divine Shield", "defensive", 1, 0.56 }, { "Hammer of Justice", "stun", 1, 0.7 }, { "Blessing of Freedom", "utility", 0, 0.2 } } },
				[66] = { n = 6, s = { { "Rebuke", "kick", 3, 0.83 }, { "Ardent Defender", "defensive", 2, 0.67 } } },
				[65] = { n = 7, s = { { "Cleanse", "dispel", 3, 0.86 }, { "Aura Mastery", "healercd", 1, 0.71 } } },
				[258] = { n = 8, s = { { "Silence", "kick", 2, 0.75 }, { "Dispel Magic", "purge", 2, 0.8 } } },
				[64] = { n = 11, s = { { "Time Warp", "lust", 1, 0.91 }, { "Counterspell", "kick", 3, 0.82 } } },
				[262] = { n = 6, s = { { "Ascendance", "healercd", 2, 1 }, { "Astral Shift", "defensive", 1, 0.8 } } },
			} },
			-- a second boss, so a defensive's usual share is knowable; most
			-- groups lust on the way to it, which is a stretch note
			["Zaen Bladesorrow"] = { n = 20, lust = { n = 8, on = 1, before = 7 }, specs = {
				[70] = { n = 8, s = { { "Divine Shield", "defensive", 1, 0.9 }, { "Divine Protection", "defensive", 1, 0.9 } } },
				[262] = { n = 6, s = { { "Astral Shift", "defensive", 1, 0.9 } } },
			} },
		},
	}
	become(70) -- Retribution: no hand-written Kystia line at all
	KN.Tracker.Preview("Murder", "k"); KN.Tracker.PreviewBoss("Kystia")
	local rr = KN.Tracker.Rows()
	check(not has(rr, function(r) return r.type == "section" and r.label ~= "Boss 1 of 4" end)
		and has(rr, function(r) return r.type == "subhead" and r.label == "Retribution Paladin" end),
		"data lines sit under the spec heading, with no heading of their own")
	check(has(rr, function(r) return r.type == "yours" and r.tag == "STUN" and r.text == "Hammer of Justice works well on Mirror Images" end),
		"a situational tool most of the spec uses names what it is for, read from the boss's own lines")
	check(not has(rr, function(r) return r.tag == "KICK" end),
		"no kick line: the boss's core line already says to kick")
	check(not has(rr, function(r) return r.tag == "DEF" end),
		"a defensive the spec pops on every boss is not a line for this one")
	check(not has(rr, function(r) return r.text and r.text:find("Blessing of Freedom", 1, true) end), "a spell cast by one in five is not")
	KN.Tracker.Preview("Murder", "k"); KN.Tracker.PreviewBoss("Zaen")
	rr = KN.Tracker.Rows()
	check(has(rr, function(r) return r.tag == "DEF" and r.text == "Divine Protection for Envenom" end),
		"a defensive unusual here names the ability the boss's tank line answers, though the reader never sees that line")
	check(not has(rr, function(r) return r.text and r.text:find("Divine Shield", 1, true) end),
		"a defensive the spec pops on the other boss too still is not a line")
	become(66) -- Protection with a poison dispel: the tank line and the poison line share Envenom
	KN.Tracker.Preview("Murder", "k"); KN.Tracker.PreviewBoss("Zaen")
	rr = KN.Tracker.Rows()
	local envenom = 0
	for _, r in ipairs(rr) do if r.type == "yours" and r.text:find("Envenom", 1, true) then envenom = envenom + 1 end end
	check(envenom == 1 and has(rr, function(r) return r.tag == "TANK" end),
		"two lines on one ability and one kind of action fold into the line written for the reader's seat")
	become(262) -- Elemental: Ascendance is a DPS cooldown sharing a healer cooldown's name
	KN.Tracker.Preview("Murder", "k"); KN.Tracker.PreviewBoss("Kystia")
	check(not has(KN.Tracker.Rows(), function(r) return r.text and r.text:find("Ascendance", 1, true) end),
		"a healer-cooldown name on a non-healer is ignored")
	become(66) -- Protection: hand-written tank line covers "defensive"
	KN.Tracker.Preview("Murder", "k"); KN.Tracker.PreviewBoss("Kystia")
	rr = KN.Tracker.Rows()
	check(has(rr, function(r) return r.tag == "TANK" end) and not has(rr, function(r) return r.tag == "KICK" end)
		and not has(rr, function(r) return r.tag == "DEF" end),
		"a tank keeps the hand-written line and gains nothing the boss already covers")
	become(65) -- Holy: hand-written MAGIC and CD lines cover dispel and healercd
	KN.Tracker.Preview("Murder", "k"); KN.Tracker.PreviewBoss("Kystia")
	rr = KN.Tracker.Rows()
	check(not has(rr, function(r) return r.tag == "DISPEL" or (r.text and r.text:find("Aura Mastery", 1, true)) end), "covered kinds add nothing")
	become(64) -- Frost Mage: lust timing
	KN.Tracker.Preview("Murder", "k"); KN.Tracker.PreviewBoss("Kystia")
	rr = KN.Tracker.Rows()
	check(has(rr, function(r) return r.tag == "LUST" and r.text == "Most groups lust on this boss" end),
		"a lust spec sees where ranked runs lust")
	KN.Tracker.Preview("Murder", "k"); KN.Tracker.PreviewBoss("Zaen")
	check(not has(KN.Tracker.Rows(), function(r) return r.tag == "LUST" end), "a lust on the way to the boss is not a boss line")
	KN.Tracker.Preview("Murder", "k"); KN.Tracker.Step(1)
	check(has(KN.Tracker.Rows(), function(r) return r.type == "note" and r.tag == "LUST" and r.text == "Most groups lust on this stretch" end),
		"it is a note on the stretch before that boss")
	KN.Tracker.Preview("Murder", "n"); KN.Tracker.Step(1)
	check(not has(KN.Tracker.Rows(), function(r) return r.tag == "LUST" end), "and only where the trash section shows")
	wipe(printed)
	check(KN:Command("check murder"), "/tp notes check routes")
	local joined = table.concat(printed, "\n")
	check(joined:find("ADDS     Murder Row / Zaen Bladesorrow: Divine Protection for Envenom", 1, true) ~= nil,
		"check reports the line the data would add for a spec")
	check(not joined:find("Dispel Magic", 1, true),
		"a tool with nothing on the boss naming what it answers adds no line")
	check(not joined:find("Silence", 1, true), "check does not report a kick the boss's core line covers")
	check(joined:find("2 bosses with data", 1, true) ~= nil and KN.Player.state.override == nil,
		"check summarises and restores the override")
	TP.BossCasts = nil
	become(264)
end

-- 11c. Enemy Forces in a keystone, from the scenario criteria; absent in a
--      preview and outside a key; refreshed on the criteria event.
do
	local saved = { GetInstanceInfo = _G.GetInstanceInfo, C_Map = _G.C_Map }
	_G.GetInstanceInfo = function() return "Murder Row", "party", 8, "Mythic Keystone", 5 end
	_G.C_Map = { GetBestMapForUnit = function() return nil end }
	local forces = "45%"
	_G.C_Scenario = { GetStepInfo = function() return "Murder Row", "", 2 end }
	local snitches = "0/4"
	-- the scenario's own criteria are the boss kills; the snitch count is a
	-- UI widget at the top of the screen, as in game
	_G.C_ScenarioInfo = { GetScenarioStepInfo = function() return { numCriteria = 2 } end, GetCriteriaInfo = function(i)
		if i == 1 then return { description = "Kystia Manaheart defeated", quantityString = "0", isWeightedProgress = false } end
		return { description = "Enemy Forces", quantityString = forces, isWeightedProgress = true }
	end }
	_G.C_UIWidgetManager = {
		GetTopCenterWidgetSetID = function() return 7 end,
		GetAllWidgetsBySetID = function(id) if id == 7 then return { { widgetID = 501, widgetType = 8 } } end return {} end,
		-- dressed exactly as the game sends it: a texture escape with its own
		-- colon, then the label, then a colour code on the count
		GetTextWithStateWidgetVisualizationInfo = function(id) if id == 501 then return { text = "|TInterface\\ICONS\\UI_Chat.BLP:20|t Snitches interrogated: |cffFFFFFF" .. snitches } end end,
	}
	KN.Tracker.Preview(nil)
	KN.Tracker.Refresh("forces walk-in")
	check(KN.Tracker.state.dungeon and KN.Tracker.state.dungeon.name == "Murder Row" and KN.Tracker.state.diff == "k",
		"a keystone resolves from the instance name at difficulty 8")
	check(KN.Tracker.Rows()[1].forces == 45, "the header carries Enemy Forces at 45%")
	check(has(KN.Tracker.Rows(), function(r) return r.type == "task" and r.text:find("^0/4 Interrogate Silvermoon Snitches") end),
		"the snitch objective leads with the group's count from the scenario")
	snitches = "3/4"
	KN.Tracker.Refresh("criteria moved")
	check(has(KN.Tracker.Rows(), function(r) return r.type == "task" and r.text:find("^3/4 ") end), "the count follows the scenario")
	forces = "62.5%"
	KN.Tracker.OnEncounterEnd(0, 0) -- any render; the event path re-reads
	local fr = CreateFrame("Frame", "TrueParseForcesStub")
	check(KN.View:Render(fr, KN.Tracker.Rows(), 6, -28, 368) > 50, "a header with forces renders")
	_G.C_ScenarioInfo = nil
	_G.C_Scenario = { GetStepInfo = function() return "Murder Row", "", 1 end,
		GetCriteriaInfo = function() return "Enemy Forces", 0, false, 62, 100, 0, 0, "62.5%", 1, 0, 0, false, true end }
	KN.Tracker.Refresh("forces old api")
	check(KN.Tracker.Rows()[1].forces == 62.5, "the older list-style criteria API reads too")
	-- Josh's key, 2026-09-11: "522% forces". The string carried the raw
	-- kill count with a percent sign; the count over the requirement is
	-- the real fraction. A sane string still wins (the 62.5 above).
	_G.C_ScenarioInfo = { GetScenarioStepInfo = function() return { numCriteria = 1 } end,
		GetCriteriaInfo = function()
			return { description = "Enemy Forces", quantityString = "522%", quantity = 522,
				totalQuantity = 1000, isWeightedProgress = true }
		end }
	KN.Tracker.Refresh("forces raw count")
	local f522 = KN.Tracker.Rows()[1].forces
	check(f522 and math.abs(f522 - 52.2) < 0.01,
		("a count dressed as a percentage reads as the fraction (%s)"):format(tostring(f522)))
	_G.C_ScenarioInfo = { GetScenarioStepInfo = function() return { numCriteria = 1 } end,
		GetCriteriaInfo = function()
			return { description = "Enemy Forces", quantityString = "", quantity = 30,
				totalQuantity = 100, isWeightedProgress = true }
		end }
	KN.Tracker.Refresh("forces no string")
	check(KN.Tracker.Rows()[1].forces == 30, "no string at all: the numbers alone read")
	_G.C_ScenarioInfo = nil
	KN.Tracker.Preview("Murder", "k")
	check(KN.Tracker.Rows()[1].forces == nil, "a preview shows no forces")
	_G.GetInstanceInfo, _G.C_Map, _G.C_Scenario, _G.C_UIWidgetManager = saved.GetInstanceInfo, saved.C_Map, nil, nil
	KN.Tracker.Preview(nil)
end

-- 12. Retail raid difficulty ids exist now, and Raid Finder ranks below
--     Normal (research/INVENTORY.md, raid prerequisite 1).
check(KN.DIFF_BY_ID[17] == "l" and KN.DIFF_BY_ID[14] == "n" and KN.DIFF_BY_ID[15] == "h" and KN.DIFF_BY_ID[16] == "m",
	"retail raid ids 17/14/15/16 map to l/n/h/m")
check(KN.DIFF_RANK.l < KN.DIFF_RANK.n and KN.DIFF_LABEL.l == "Raid Finder", "Raid Finder ranks below Normal")
check(KN.DIFF_LABEL.k == "Keystone" and KN.KEYSTONES == true, "retail calls k a Keystone and has keystones")

-- 13. A place nothing hand-written covers falls back to the Adventure
--     Guide: bosses from the journal, one note per role bullet, the
--     difficulty-filtered bullet dropped, no core lines, and the Yours
--     heading says where the lines came from.
do
	local sections = {
		[100] = { title = "Overview", headerType = 3, description = "Scene-setting prose.", firstChildSectionID = 101 },
		[101] = { title = "Damage Dealers", headerType = 3, description = "Avoid the [Big Swing]$bullet;Interrupt [Mending]", siblingSectionID = 102, flags = { 1 } },
		[102] = { title = "Healers", headerType = 3, description = "Heavy damage during [Roar]", siblingSectionID = 103, flags = { 2 } },
		[103] = { title = "Tank", headerType = 3, description = "Face the boss away$bullet;Swap at three stacks", siblingSectionID = 104, flags = { 0 } },
		[104] = { title = "Tank", headerType = 3, description = "Mythic-only soak", filteredByDifficulty = true, flags = { 0 } },
		[200] = { title = "Overview", headerType = 3, description = "More prose.", firstChildSectionID = 201 },
		[201] = { title = "Healers", headerType = 3, description = "Dispel [Curse of Ages]", flags = { 2 } },
	}
	local saved = { GetInstanceInfo = _G.GetInstanceInfo, C_Map = _G.C_Map, C_EncounterJournal = _G.C_EncounterJournal }
	_G.GetInstanceInfo = function() return "Test Keep", "party", 23, "Mythic", 5 end
	_G.C_Map = { GetBestMapForUnit = function() return 4242 end }
	_G.EJ_GetInstanceForMap = function(mapID) if mapID == 4242 then return 777 end end
	_G.EJ_GetInstanceInfo = function(id) if id == 777 then return "Test Keep" end end
	_G.EJ_SelectInstance = function() end
	_G.EJ_SelectEncounter = function() end
	_G.EJ_GetEncounterInfoByIndex = function(i)
		if i == 1 then return "Warden Ashvale", "", 3001, 100, nil, nil, 9101 end
		if i == 2 then return "The Curator", "", 3002, 200, nil, nil, 9102 end
	end
	_G.C_EncounterJournal = {
		GetSectionInfo = function(id) return sections[id] end,
		GetSectionIconFlags = function(id) return sections[id] and sections[id].flags or {} end,
	}

	become(66) -- Protection Paladin: tank
	KN.Tracker.Preview(nil)
	KN.Tracker.Refresh("journal walk-in")
	local d = KN.Tracker.state.dungeon
	check(d and d.journal and d.name == "Test Keep" and #d.bosses == 2 and d.kind == "dungeon",
		"an uncovered dungeon resolves from the Adventure Guide with its two bosses")
	check(KN.Find("Test Keep") == nil, "the journal-built instance is not registered alongside the hand-written ones")
	check(hasSection(KN.Tracker.Rows(), "Next · Boss 1 of 2") and not hasSection(KN.Tracker.Rows(), "Trash"),
		"the stretch view previews the journal's first boss with no trash")
	KN.Tracker.OnEncounterStart(9101, "Warden Ashvale")
	local jr = KN.Tracker.Rows()
	local texts = {}
	for _, r in ipairs(jr) do if r.type == "yours" then texts[#texts + 1] = r.text end end
	check(not has(jr, function(r) return r.type == "core" end), "a journal boss has no core lines")
	check(#texts == 2 and texts[1] == "Face the boss away" and texts[2] == "Swap at three stacks",
		"a tank sees the two Tank bullets and nothing from the other roles (" .. table.concat(texts, " | ") .. ")")
	check(not has(jr, function(r) return r.text == "Mythic-only soak" end), "a bullet the journal filters at this difficulty is dropped")
	check(has(jr, function(r) return r.type == "subhead" and r.text == "Adventure Guide" end),
		"journal lines name the Adventure Guide beside the spec heading")
	become(65) -- Holy Paladin
	KN.Tracker.OnEncounterStart(9101, "Warden Ashvale")
	check(has(KN.Tracker.Rows(), function(r) return r.text == "Heavy damage during [Roar]" end)
		and not has(KN.Tracker.Rows(), function(r) return r.text == "Face the boss away" end),
		"a healer sees the Healers bullet and not the tank's")
	KN.Tracker.OnEncounterEnd(9101, 1)
	check(hasSection(KN.Tracker.Rows(), "Next · Boss 2 of 2"), "a kill advances through the journal's boss list")

	_G.GetInstanceInfo, _G.C_Map, _G.C_EncounterJournal = saved.GetInstanceInfo, saved.C_Map, saved.C_EncounterJournal
	_G.EJ_GetInstanceForMap, _G.EJ_GetInstanceInfo, _G.EJ_SelectInstance, _G.EJ_SelectEncounter, _G.EJ_GetEncounterInfoByIndex = nil, nil, nil, nil, nil
	KN.Tracker.Refresh("journal walk-out")
	check(KN.Tracker.state.dungeon == nil, "leaving clears the journal-built instance")
	become(264)
end

---------------------------------------------------------------------------
-- MISTS OF PANDARIA CLASSIC: a second boot from TrueParse_Mists.toc with a
-- fresh namespace. Everything above was retail; nothing below may touch it.
---------------------------------------------------------------------------
local mistsList = table.concat(notesFiles("TrueParse_Mists.toc"), " ")
local retailList = table.concat(notesFiles("TrueParse.toc"), " ")
check(mistsList:find("Notes/Mists.lua", 1, true) and mistsList:find("Notes/Classes_Mists.lua", 1, true),
	"the Mists TOC loads Mists.lua and Classes_Mists.lua")
check(not mistsList:find("Season2", 1, true) and not mistsList:find("Notes/Classes.lua", 1, true)
	and not mistsList:find("Affixes", 1, true),
	"the Mists TOC loads neither Season2.lua, the retail Classes.lua nor Affixes.lua")
check(retailList:find("Season2", 1, true) and not retailList:find("Mists", 1, true),
	"the retail TOC loads Season2.lua and nothing Mists")

TP, KN = boot(_G.WOW_PROJECT_MISTS_CLASSIC, "TrueParse_Mists.toc")
check(KN ~= retailKN and KN.IS_RETAIL == false, "Mists boots its own namespace as non-retail")

-- 13. The Mists content: 9 dungeons, 5 raids, nothing from Season 2.
local dungeons, raids, bosses = 0, 0, 0
for _, d in ipairs(KN.instances) do
	if d.kind == "raid" then raids = raids + 1 else dungeons = dungeons + 1 end
	bosses = bosses + #d.bosses
	check(d.trash == nil, d.name .. " is boss-only")
end
check(dungeons == 9 and raids == 5, ("9 dungeons and 5 raids registered (%d/%d, %d bosses)"):format(dungeons, raids, bosses))
check(KN.Find("Voidscar Arena") == nil and KN.Find("Siege of Orgrimmar").kind == "raid"
	and KN.Find("Scholomance").kind == "dungeon", "Season 2 is absent; Pandaria is present")
local sooNames = { "Immerseus", "Fallen Protectors", "Norushen", "Sha of Pride", "Galakras", "Iron Juggernaut",
	"Kor'kron Dark Shaman", "General Nazgrim", "Malkorok", "Spoils of Pandaria", "Thok the Bloodthirsty",
	"Siegecrafter Blackfuse", "Paragons of the Klaxxi", "Garrosh Hellscream" }
local soo = KN.Find("Siege of Orgrimmar")
local sooOK = #soo.bosses == #sooNames
for i, n in ipairs(sooNames) do
	if sooOK and not soo.bosses[i].name:find(n, 1, true) then sooOK = false end
end
check(sooOK, "Siege of Orgrimmar's 14 bosses are in the crawled order")
local coreOK = true
for _, d in ipairs(KN.instances) do
	for _, b in ipairs(d.bosses) do
		local n = type(b.core) == "table" and #b.core or (b.core and 1 or 0)
		if n < 1 or n > 3 then coreOK = false end
	end
end
check(coreOK, "every Mists boss carries one to three core lines")

-- 14. The Mists capability table is its own: no retail-only classes, and
--     the tools that differ between clients differ here.
local rows, retailOnly = 0, false
for _, row in pairs(KN.CLASSES) do
	rows = rows + 1
	if row.class == "DEMONHUNTER" or row.class == "EVOKER" then retailOnly = true end
end
check(rows == 34 and not retailOnly, ("34 Mists specs, no Demon Hunter, no Evoker (%d)"):format(rows))
check(KN.CLASSES[105].kick and KN.CLASSES[65].kick and KN.CLASSES[270].kick and KN.CLASSES[264].kick,
	"Mists healers keep their interrupts (Resto Druid, Holy Paladin, Mistweaver, Resto Shaman)")
check(not KN.CLASSES[256].kick and not KN.CLASSES[257].kick and KN.CLASSES[258].kick,
	"Priest healers have no interrupt; Shadow has Silence")
check(KN.CLASSES[256].fear and KN.CLASSES[257].fear and KN.CLASSES[258].fear,
	"Fear Ward exists on Mists: every Priest carries fear")
check(KN.CLASSES[253].lust and not KN.CLASSES[254].lust and not KN.CLASSES[255].lust,
	"only Beast Mastery brings lust (Core Hound is exotic)")
check(not KN.CLASSES[264].poison and not KN.CLASSES[262].poison, "Mists Shamans cleanse no poison")
check(KN.CLASSES[64].stun and not KN.CLASSES[62].stun, "Deep Freeze is Frost's stun; Arcane has none")
check(KN.CLASSES[260].name == "Combat", "the second Rogue spec is Combat, not Outlaw")

-- 15. Every Mists spec, every instance, every boss, at Challenge Mode,
--     Heroic and Normal: nothing for a tool the spec lacks, nothing for
--     another role, no trash anywhere, never an affix or a key level.
local mSpecs, mAudited, mBad = 0, 0, nil
for specID, row in pairs(KN.CLASSES) do
	become(specID)
	mSpecs = mSpecs + 1
	for _, d in ipairs(KN.instances) do
		for _, diff in ipairs({ "k", "h", "n" }) do
			KN.Tracker.Preview(d.name, diff)
			local function audit(rs, where)
				for _, r in ipairs(rs) do
					local why
					local icon = iconOf(r)
					if isLust(r) and not row.lust then why = "lust"
					elseif icon == KN.ICONS.TANK and row.role ~= "tank" then why = "tank"
					elseif icon == KN.ICONS.CD and row.role ~= "healer" then why = "cooldown"
					elseif icon == KN.ICONS.KICK and not row.kick then why = "kick"
					elseif icon == KN.ICONS.PURGE and not row.purge then why = "purge"
					elseif icon == KN.ICONS.POISON and not row.poison then why = "poison"
					elseif icon == KN.ICONS.DISEASE and not row.disease then why = "disease"
					elseif icon == KN.ICONS.MAGIC and not row.magic then why = "magic"
					elseif icon == KN.ICONS.CURSE and not row.curse then why = "curse"
					elseif icon == KN.ICONS.SOOTHE and not row.soothe then why = "soothe"
					elseif icon == KN.ICONS.STUN and not row.stun then why = "stun"
					elseif icon == KN.ICONS.FEAR and not row.fear then why = "fear"
					elseif icon == KN.ICONS.MASSDISP and not row.massdispel then why = "mass dispel"
					elseif icon == KN.ICONS.BUILD then why = "talents"
					elseif r.type == "section" and r.label == "Trash" then why = "trash"
					elseif r.type == "header" and (r.affixes ~= nil or r.level ~= nil) then why = "affix/level"
					end
					if why and not mBad then mBad = row.name .. " saw a " .. why .. " line at " .. where end
					mAudited = mAudited + 1
				end
			end
			audit(KN.Tracker.Rows(), d.name .. " stretch " .. diff)
			for i, b in ipairs(d.bosses) do
				KN.Tracker.PreviewBoss(b.name)
				local br = KN.Tracker.Rows()
				audit(br, d.name .. "/" .. b.name .. " " .. diff)
				local gated = b.coreMin and KN.DIFF_RANK[diff] < KN.DIFF_RANK[b.coreMin]
				if not (br[2].type == "section" and br[2].label == ("Boss " .. i .. " of " .. #d.bosses)) and not mBad then
					mBad = d.name .. "/" .. b.name .. ": boss title wrong"
				elseif not gated and not (br[3] and br[3].type == "core" and br[3].num == 1) and not mBad then
					mBad = d.name .. "/" .. b.name .. ": first core row missing at " .. diff
				end
			end
		end
	end
end
check(mBad == nil, "every Mists spec sees only its own lines (" .. mSpecs .. " specs, " .. mAudited .. " rows)" .. (mBad and (": " .. mBad) or ""))

-- 16. Mists difficulty ids: Challenge Mode is the top dungeon rank with no
--     key; raid sizes fold to n/h; 7 is Raid Finder; nothing is Mythic.
check(KN.DIFF_BY_ID[8] == "k" and KN.DIFF_LABEL.k == "Challenge" and KN.KEYSTONES == false,
	"id 8 is a Challenge Mode: k, labelled Challenge, no keystone")
check(KN.DIFF_BY_ID[3] == "n" and KN.DIFF_BY_ID[4] == "n" and KN.DIFF_BY_ID[5] == "h" and KN.DIFF_BY_ID[6] == "h",
	"10/25 Normal fold to n, 10/25 Heroic to h")
check(KN.DIFF_BY_ID[7] == "l" and KN.DIFF_BY_ID[14] == "n" and KN.DIFF_BY_ID[23] == nil and KN.DIFF_BY_ID[16] == nil,
	"7 is Raid Finder, 14 is Flex; retail's 23 and 16 mean nothing here")
check(KN.DIFF_DEFAULT == "h" and KN.RAID_DEFAULT == "h", "an unknown id and a raid preview both fall to Heroic")

-- 17. The header on Mists: never a level, never affixes, even when the
--     command hands it both; a raid previews at Heroic by default.
become(264)
check(KN:Command("show scholomance k 12 tyrannical") and KN.Tracker.state.diff == "k", "/tp notes show accepts k on Mists")
local mh = KN.Tracker.Rows()[1]
check(mh.type == "header" and mh.level == nil and mh.affixes == nil, "a Challenge Mode header has no level and no affixes")
KN.Tracker.Preview("Siege of Orgrimmar")
check(KN.Tracker.state.diff == "h" and KN.Tracker.state.keyLevel == nil, "a raid previews at Heroic with no key level")
KN.Tracker.Preview("Scholomance")
check(KN.Tracker.state.diff == "k" and KN.Tracker.state.keyLevel == nil and KN.Tracker.state.affixes == nil,
	"a dungeon previews at Challenge Mode with nothing invented")
check(not hasSection(KN.Tracker.Rows(), "Trash") and hasSection(KN.Tracker.Rows(), "Next · Boss 1 of 5"),
	"a Mists dungeon stretch previews the next boss and never a trash section")

-- 18. Difficulty gating on a raid: Ra-den is Heroic-only, so at Normal his
--     core lines vanish; at Raid Finder a `min = "h"` line hides and a line
--     with no `min` still shows.
KN.Tracker.Preview("Throne of Thunder", "n"); KN.Tracker.PreviewBoss("Ra-den")
local raNormal = KN.Tracker.Rows()
check(not has(raNormal, function(r) return r.type == "core" end)
	and has(raNormal, function(r) return r.text == "nothing extra at this difficulty" end),
	"Ra-den at Normal: no core lines, nothing extra")
KN.Tracker.Preview("Throne of Thunder", "h"); KN.Tracker.PreviewBoss("Ra-den")
check(has(KN.Tracker.Rows(), function(r) return r.type == "core" end) and has(KN.Tracker.Rows(), isLust),
	"Ra-den at Heroic: core lines and the Shaman's lust call")
check(KN:Command("show vaults l") and KN.Tracker.state.diff == "l", "/tp notes show parses l for Raid Finder")
-- the report that found the parser bug: two instances start with "siege"
check(KN:Command("show siege of orgrimmar") and KN.Tracker.state.dungeon.name == "Siege of Orgrimmar"
	and KN.Tracker.state.diff == "h", "/tp notes show siege of orgrimmar previews the raid")
check(KN:Command("show temple of the jade serpent n") and KN.Tracker.state.dungeon.name == "Temple of the Jade Serpent"
	and KN.Tracker.state.diff == "n", "a multi-word dungeon name with a difficulty after it")
KN:Command("show vaults l")
KN.Tracker.PreviewBoss("Feng")
check(not has(KN.Tracker.Rows(), function(r) return r.text and r.text:find("Siphoning Shield", 1, true) end),
	"Raid Finder hides a min = h line")
KN.Tracker.PreviewBoss("Stone Guard")
check(has(KN.Tracker.Rows(), function(r) return r.text and r.text:find("Jasper Chains", 1, true) end),
	"Raid Finder shows a line with no min")
check(KN.Tracker.Rows()[1].diff == "l", "the header carries the Raid Finder rank")

-- 19. The two special capabilities on Mists: Priests hold both (Fear Ward
--     is alive), Shamans hold fear only, Mages neither.
become(257)
KN.Tracker.Preview("Mogu'shan Vaults", "h"); KN.Tracker.PreviewBoss("Spirit Kings")
check(hasIcon(KN.Tracker.Rows(), KN.ICONS.MASSDISP), "a Holy Priest sees Qiang's Mass Dispel line")
KN.Tracker.Preview("Heart of Fear", "h"); KN.Tracker.PreviewBoss("Shek'zeer")
check(hasIcon(KN.Tracker.Rows(), KN.ICONS.FEAR), "a Holy Priest sees the fear line (Fear Ward)")
become(264)
KN.Tracker.Preview("Mogu'shan Vaults", "h"); KN.Tracker.PreviewBoss("Spirit Kings")
check(not hasIcon(KN.Tracker.Rows(), KN.ICONS.MASSDISP), "a Shaman does NOT see the Mass Dispel line")
check(hasIcon(KN.Tracker.Rows(), KN.ICONS.MAGIC), "a Resto Shaman sees Zian's ordinary magic dispel")
KN.Tracker.Preview("Heart of Fear", "h"); KN.Tracker.PreviewBoss("Shek'zeer")
check(hasIcon(KN.Tracker.Rows(), KN.ICONS.FEAR), "a Shaman sees the fear line (Tremor Totem)")
become(62)
KN.Tracker.Preview("Heart of Fear", "h"); KN.Tracker.PreviewBoss("Shek'zeer")
check(not hasIcon(KN.Tracker.Rows(), KN.ICONS.FEAR), "a Mage sees no fear line")
KN.Tracker.Preview("Mogu'shan Vaults", "n"); KN.Tracker.PreviewBoss("Spirit Kings")
become(257)
check(not hasIcon(KN.Tracker.Rows(), KN.ICONS.MASSDISP), "Impervious Shield is Heroic-only: hidden at Normal")

-- 20. The journal on a client with no C_EncounterJournal: bosses still
--     read (names, ids), abilities come back empty, nothing errors. This is
--     the `pcall(C_X.Y)` trap: the namespace is indexed before pcall runs.
_G.C_EncounterJournal = nil
_G.EJ_SelectInstance = function() end
_G.EJ_SelectEncounter = function() end
_G.EJ_GetEncounterInfoByIndex = function(i)
	if i == 1 then return "Wise Mari", "", 1000, 2000, nil, nil, 1418 end
	if i == 2 then return "Lorewalker Stonestep", "", 1001, 2001, nil, nil, 1417 end
	return nil
end
local okJ, jb = pcall(KN.Journal.Bosses, 5, 2)
check(okJ and jb and #jb == 2 and jb[1].dungeonEncounterID == 1418 and next(jb[1].abilities) == nil,
	"Journal.Bosses reads two bosses with no abilities and no C_EncounterJournal")
local okO, ov = pcall(KN.Journal.Overview, 2000)
local okD, dump = pcall(KN.Journal.DumpSections, 2000)
check(okO and #ov == 0 and okD and dump[1]:find("unavailable", 1, true),
	"Overview and DumpSections degrade to nothing rather than erroring")
check(KN:Command("journal") and KN:Command("debug"), "/tp notes journal and debug route on Mists")
_G.EJ_SelectInstance, _G.EJ_SelectEncounter, _G.EJ_GetEncounterInfoByIndex = nil, nil, nil

-- 21. Commands that are retail-shaped answer sensibly instead of erroring.
wipe(printed)
check(KN:Command("ladder"), "/tp notes ladder routes on Mists")
check(printed[1] and printed[1]:find("Challenge Modes", 1, true), "and says there is no keystone ladder here")
check(KN:Command("list") and KN:Command("as tank") and KN:Command("spec") and not KN:Command("bogus"), "Mists command routing")
KN.Player.SetOverride("")
check(KN.EMPTY_HINT == "Enter a dungeon or raid to view notes." and retailKN.EMPTY_HINT == KN.EMPTY_HINT,
	"the empty-state hint is one sentence on both clients")

-- 22. A spec the API cannot answer yet is retried by the next reader, not
--     frozen as "Unknown spec" for the session (the Classic timing gap).
local realGetSpec = _G.GetSpecialization
_G.GetSpecialization = function() return nil end
become(268) -- Refresh runs while the API answers nil
check(KN.Player.SpecName():find("Unknown spec", 1, true) ~= nil, "a nil spec read shows as Unknown spec")
_G.GetSpecialization = realGetSpec
check(KN.Player.Caps().id == 268 and KN.Player.SpecName() == "Brewmaster Monk",
	"the next read recovers the real spec without an explicit refresh")
-- the direct read answers, but with nothing usable: the per-class table
-- and then the roster's read of the player stand in
local realInfo = _G.GetSpecializationInfo
_G.GetSpecializationInfo = function() return nil end
_G.GetSpecializationInfoForClassID = function(classID, idx) if classID == 10 and idx == 1 then return 270, "Mistweaver", "", 0, "HEALER" end end
_G.UnitClass = function() return "Monk", "MONK", 10 end
KN.Player.Refresh()
check(KN.Player.Caps().id == 270 and KN.Player.Role() == "healer", "GetSpecializationInfoForClassID stands in for a nil direct read")
_G.GetSpecializationInfoForClassID = nil
_G.UnitGUID = function() return "Player-1-0001" end
TP.Roster = { players = { ["Player-1-0001"] = { specID = 269 } } }
KN.Player.Refresh()
check(KN.Player.Caps().id == 269 and KN.Player.Role() == "dps", "the roster's own read stands in when both API entry points fail")
check(KN.Player.DebugLine():find("roster=269", 1, true) ~= nil, "the debug line shows the raw reads")
TP.Roster = nil
_G.GetSpecializationInfo = realInfo
_G.UnitClass = function() return "Shaman", FAKE.class end
become(268)
check(KN.Player.Caps().id == 268, "the direct read wins again once it answers")
KN.Tracker.Preview("Siege of Orgrimmar", "h")
check(KN.Tracker.Rows()[1].spec == "Brewmaster Monk", "and the header names it")

-- A linear raid (every Mists raid) previews its next boss and pages, as a
-- dungeon does; the boss list is only for raids with wings.
check(hasSection(KN.Tracker.Rows(), "Next · Boss 1 of 14") and not hasSection(KN.Tracker.Rows(), "Bosses"),
	"a linear raid previews its first boss instead of listing all fourteen")
check(has(KN.Tracker.Rows(), function(r) return r.type == "section" and r.name == "Immerseus" end), "and names Immerseus")
KN.Tracker.Step(1)
check(hasSection(KN.Tracker.Rows(), "Next · Boss 2 of 14"), "next/prev pages a linear raid")
KN.Tracker.Step(-1)

-- Walking in: the live path. GetInstanceInfo says "raid", which the
-- tracker used to reject outright (it accepted only "party").
local realGII = _G.GetInstanceInfo
_G.GetInstanceInfo = function() return "Siege of Orgrimmar", "raid", 5, "10 Player (Heroic)", 10 end
KN.Tracker.Refresh("test walk-in")
check(KN.Tracker.state.dungeon and KN.Tracker.state.dungeon.name == "Siege of Orgrimmar" and not KN.Tracker.state.preview,
	"standing in Siege of Orgrimmar resolves the raid from GetInstanceInfo")
check(KN.Tracker.state.diff == "h" and hasSection(KN.Tracker.Rows(), "Next · Boss 1 of 14"),
	"10 Heroic reads as h and the first boss previews")
KN.Tracker.OnEncounterStart(1602, "Immerseus")
check(hasSection(KN.Tracker.Rows(), "Boss 1 of 14"), "ENCOUNTER_START opens the boss view")
KN.Tracker.OnEncounterEnd(1602, 1)
check(hasSection(KN.Tracker.Rows(), "Next · Boss 2 of 14"), "a kill advances to the next boss")
-- Joining a raid in progress (Josh 2026-09-10: on Galakras, the panel said
-- Immerseus): the pull is ground truth for the position, a wipe keeps the
-- pulled boss as next, and a kill advances from it, not from boss 1.
KN.Tracker.OnEncounterStart(1622, "Galakras")
check(hasSection(KN.Tracker.Rows(), "Boss 5 of 14"), "a pull on boss 5 opens boss 5")
KN.Tracker.OnEncounterEnd(1622, 0)
check(hasSection(KN.Tracker.Rows(), "Next · Boss 5 of 14")
	and has(KN.Tracker.Rows(), function(r) return r.type == "section" and r.name == "Galakras" end),
	"a wipe keeps the pulled boss as next")
KN.Tracker.OnEncounterStart(1622, "Galakras")
KN.Tracker.OnEncounterEnd(1622, 1)
check(hasSection(KN.Tracker.Rows(), "Next · Boss 6 of 14"), "and the kill advances from there")
_G.GetInstanceInfo = realGII
KN.Tracker.Refresh("test walk-out")
check(KN.Tracker.state.dungeon == nil, "leaving clears the instance")
-- Walking in with a lock that already holds kills previews the first boss
-- the lock does not mark defeated, before any pull. Two locks share the
-- name (10 Player, and 10 Player (Heroic) with four down); the one for the
-- difficulty we stand in wins, and its names are the lock's own.
local savedRaid = { GetNumSavedInstances = _G.GetNumSavedInstances, GetSavedInstanceInfo = _G.GetSavedInstanceInfo,
	GetSavedInstanceEncounterInfo = _G.GetSavedInstanceEncounterInfo }
_G.GetNumSavedInstances = function() return 2 end
_G.GetSavedInstanceInfo = function(i)
	if i == 1 then return "Siege of Orgrimmar", 7, 0, 4, true, false, 0, true, 10, "10 Player", 14, 14 end
	return "Siege of Orgrimmar", 9, 0, 5, true, false, 0, true, 10, "10 Player (Heroic)", 14, 4
end
_G.GetSavedInstanceEncounterInfo = function(i, j)
	local names = { "Immerseus", "Fallen Protectors", "Norushen", "Sha of Pride", "Galakras", "Iron Juggernaut",
		"Kor'kron Dark Shaman", "General Nazgrim", "Malkorok", "Spoils of Pandaria", "Thok the Bloodthirsty",
		"Siegecrafter Blackfuse", "Paragons of the Klaxxi", "Garrosh Hellscream" }
	return names[j], 0, i == 1 or j <= 4
end
_G.GetInstanceInfo = function() return "Siege of Orgrimmar", "raid", 5, "10 Player (Heroic)", 10 end
KN.Tracker.Refresh("test walk-in saved")
check(hasSection(KN.Tracker.Rows(), "Next · Boss 5 of 14")
	and has(KN.Tracker.Rows(), function(r) return r.type == "section" and r.name == "Galakras" end),
	"the heroic lock seeds the kills: boss 5 previews on the way in, not the normal lock's clear")
KN.Tracker.Step(-1)
check(hasSection(KN.Tracker.Rows(), "Next · Boss 4 of 14"), "paging back still works from the seeded position")
KN.Tracker.Refresh("UPDATE_INSTANCE_INFO")
check(hasSection(KN.Tracker.Rows(), "Next · Boss 4 of 14"), "and a lock re-read does not undo the paging")
_G.GetInstanceInfo = realGII
KN.Tracker.Refresh("test walk-out")
for k, v in pairs(savedRaid) do _G[k] = v end
check(KN.Tracker.state.dungeon == nil, "leaving clears the instance again")

-- 23. Mists rows render through the strict widget stub.
become(270)
KN.Tracker.Preview("Siege of Orgrimmar", "h"); KN.Tracker.PreviewBoss("Garrosh")
local mParent = CreateFrame("Frame", "TrueParseWindowStubMists")
local mUsed = KN.View:Render(mParent, KN.Tracker.Rows(), 6, -28, 368)
check(mUsed > 100, ("Mists render has height: %d"):format(mUsed))
KN.Tracker.Preview("Siege of Orgrimmar", "h")
local sUsed = KN.View:Render(mParent, KN.Tracker.Rows(), 6, -28, 368)
check(sUsed > 60, ("the raid stretch view renders: %d"):format(sUsed))
KN.View:Hide()

if fails > 0 then
	print(fails .. " FAILED")
	os.exit(1)
end
print("ALL OK")
