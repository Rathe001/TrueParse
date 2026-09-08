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

local TP = {}
local invalidated = 0
TP.Addon = {
	db = { profile = { window = { view = "notes" }, notes = { autoSwitch = false } }, global = {} },
	Print = function() end,
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
for _, f in ipairs({ "Notes/Core.lua", "Notes/Classes.lua", "Notes/Player.lua", "Notes/Journal.lua",
	"Notes/View.lua", "Notes/Tracker.lua", "Notes/Season2.lua", "Notes/Affixes.lua" }) do
	load(f)
end
local KN = TP.Notes
KN:OnEnable()

local fails = 0
local function check(cond, label)
	if cond then
		print("ok   " .. label)
	else
		fails = fails + 1
		print("FAIL " .. label)
	end
end

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
local function isLust(r) return r.icon == KN.ICONS.LUST end

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
					if isLust(r) and not row.lust then why = "lust"
					elseif r.icon == KN.ICONS.TANK and row.role ~= "tank" then why = "tank"
					elseif r.icon == KN.ICONS.CD and row.role ~= "healer" then why = "cooldown"
					elseif r.icon == KN.ICONS.KICK and not row.kick then why = "kick"
					elseif r.icon == KN.ICONS.PURGE and not row.purge then why = "purge"
					elseif r.icon == KN.ICONS.POISON and not row.poison then why = "poison"
					elseif r.icon == KN.ICONS.MAGIC and not row.magic then why = "magic"
					elseif r.icon == KN.ICONS.CURSE and not row.curse then why = "curse"
					elseif r.icon == KN.ICONS.FEAR and not row.fear then why = "fear"
					elseif r.icon == KN.ICONS.MASSDISP and not row.massdispel then why = "mass dispel"
					elseif r.icon == KN.ICONS.BUILD and row.class ~= "SHAMAN" then why = "talents"
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
check(has(KN.Tracker.Rows(), function(x) return isLust(x) and x.text == "on the first Creeper" end), "Tyrannical: Atroxus carries the lust")
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
local sections = 0
for _, r in ipairs(KN.Tracker.Rows()) do if r.type == "section" then sections = sections + 1 end end
check(sections == 2, "boss view has a boss heading and a Yours heading")
KN.Tracker.Preview("Murder", "k")
local labels = {}
for _, r in ipairs(KN.Tracker.Rows()) do if r.type == "section" then labels[#labels + 1] = r.label end end
check(labels[1] == "Trash" and labels[2] == "Next · Boss 1 of 4", "trash view headings: " .. table.concat(labels, " | "))
check(KN.Tracker.Rows()[1].role == "Healer · Ranged", "role line reads Healer · Ranged")
KN.View:Hide()

-- 6. Commands route
check(KN:Command("show altar k 12 tyrannical fortified guile") and KN.Tracker.state.keyLevel == 12, "/tp notes show parses level and affixes")
check(#KN.Tracker.Rows()[1].affixes == 3, "three affixes in the header")
check(KN:Command("ladder 12") and KN:Command("list") and KN:Command("as tank") and not KN:Command("bogus"), "command routing")
check(KN:Command("journal"), "/tp notes journal routes without the journal API present")
check(invalidated > 0, "state changes invalidate the meter window")

-- 7. Trash is a Mythic+ feature (Josh 2026-09-08). Below a key the stretch
--    between bosses carries no trash section, but the next boss still previews.
--    Test 6 left an "as tank" override in place, and Player.Caps() answers
--    from the override, not the spec - so every capability test below would
--    read the spec that was current back then. Clear it first.
KN.Player.SetOverride("")

local function sectionLabels(rows)
	local out = {}
	for _, r in ipairs(rows) do if r.type == "section" then out[#out + 1] = r.label end end
	return out
end
local function hasSection(rows, label)
	for _, l in ipairs(sectionLabels(rows)) do if l == label then return true end end
	return false
end
local function hasIcon(rows, icon)
	for _, r in ipairs(rows) do if r.icon == icon then return true end end
	return false
end

become(264)
KN.Tracker.Preview("Voidscar", "k", 9, { "Fortified", "Xal'atath's Bargain: Pulsar" })
check(hasSection(KN.Tracker.Rows(), "Trash"), "keystone still shows the trash section")
local belowKey = true
for _, d in ipairs({ "m", "h", "n" }) do
	KN.Tracker.Preview("Voidscar", d)
	if hasSection(KN.Tracker.Rows(), "Trash") then belowKey = false end
end
check(belowKey, "no trash section on Mythic, Heroic or Normal")
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
check(hasSection(raidRows, "Bosses"), "a raid lists its bosses instead of guessing which is next")
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

if fails > 0 then
	print(fails .. " FAILED")
	os.exit(1)
end
print("ALL OK")
