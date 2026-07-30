local _, TP = ...

TP.ROLE = {
	TANK = "TANK",
	HEALER = "HEALER",
	DAMAGER = "DAMAGER",
}

-- Segment kinds
TP.SEGMENT = {
	FIGHT = "fight",
	OVERALL = "overall",
	MPLUS = "mplus",
}

-- Gold star for awards. A texture escape, not a Unicode ★: Classic fonts
-- lack the glyph and render a tofu box.
TP.STAR = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t"

-- Companion-driven difficulties that never rank on Warcraft Logs and pad
-- the party with NPCs (an NPC bodyguard must never get a scorecard row).
-- Captures skip these and the window explains why.
TP.UNSUPPORTED_DIFFICULTY = {
	[205] = true, -- Follower Dungeon
	[208] = true, -- Delve
	[220] = true, -- Story Raid
}

-- Display names for scored metrics (breakdown panel, coach line)
TP.METRIC_LABELS = {
	damage = "Damage",
	healing = "Healing + Absorbs",
	damageTaken = "Damage Soaked",
	interrupts = "Interrupts",
	dispels = "Dispels",
	prescience = "Prescience",
}

-- Global specID -> role, for pooling percentile curves by role when a spec
-- lacks its own curve. Static across seasons.
TP.SPEC_ROLES = {
	[62] = "DAMAGER", [63] = "DAMAGER", [64] = "DAMAGER", -- mage
	[65] = "HEALER", [66] = "TANK", [70] = "DAMAGER", -- paladin
	[71] = "DAMAGER", [72] = "DAMAGER", [73] = "TANK", -- warrior
	[102] = "DAMAGER", [103] = "DAMAGER", [104] = "TANK", [105] = "HEALER", -- druid
	[250] = "TANK", [251] = "DAMAGER", [252] = "DAMAGER", -- dk
	[253] = "DAMAGER", [254] = "DAMAGER", [255] = "DAMAGER", -- hunter
	[256] = "HEALER", [257] = "HEALER", [258] = "DAMAGER", -- priest
	[259] = "DAMAGER", [260] = "DAMAGER", [261] = "DAMAGER", -- rogue
	[262] = "DAMAGER", [263] = "DAMAGER", [264] = "HEALER", -- shaman
	[265] = "DAMAGER", [266] = "DAMAGER", [267] = "DAMAGER", -- warlock
	[268] = "TANK", [269] = "DAMAGER", [270] = "HEALER", -- monk
	[577] = "DAMAGER", [581] = "TANK", -- dh
	-- Midnight third DH spec, observed live (2026-07-10 field data:
	-- 1.08M damage / 960 healing, queued as DPS)
	[1480] = "DAMAGER",
	[1467] = "DAMAGER", [1468] = "HEALER", [1473] = "SUPPORT", -- evoker
}

-- The C_DamageMeter attributes captured per fight (Midnight+ clients).
-- `enum` names a key in Enum.DamageMeterType, resolved at runtime so a
-- missing attribute on some client just drops that metric.
-- EnemyDamageTaken is skipped: its sources are enemies, not group members.
TP.METRIC_DEFS = {
	{ key = "damage",         enum = "DamageDone" },
	{ key = "dps",            enum = "Dps" },
	{ key = "healing",        enum = "HealingDone" },
	-- Speculative: only captured if the client's enum actually has it.
	-- If real data shows up we can subtract it from healer scoring the way
	-- Classic's CLEU path already does (its healing is effective-only).
	{ key = "overhealing",    enum = "Overhealing" },
	{ key = "hps",            enum = "Hps" },
	{ key = "absorbs",        enum = "Absorbs" },
	{ key = "damageTaken",    enum = "DamageTaken" },
	{ key = "avoidableTaken", enum = "AvoidableDamageTaken" },
	{ key = "interrupts",     enum = "Interrupts" },
	{ key = "dispels",        enum = "Dispels" },
	{ key = "deaths",         enum = "Deaths" },
}

-- Practice-dummy scoring (Josh 2026-07-26): raider's-training-dummy
-- sessions capture as labeled practice fights and score against this
-- boss's curves — the tier's "patchwerk" (pure single-target, the fight
-- parses are compared on). SoO: Iron Juggernaut, the community's
-- stand-and-hit fight; Malkorok's absorb phase and Thok's frenzy skew
-- rates. difficultyID picks the anchor bracket (3 = 10 Normal, the
-- most-parsed). Update per tier alongside the zone ids.
-- PRACTICE TARGETS. Blizzard's dummies share no naming scheme, so matching
-- "Training Dummy" missed several (Josh 2026-07-30 sent all ten tooltips):
--   Training Dummy / Cleave Training Dummy / Dungeoneer's Training Dummy  ok
--   Normal Tank Dummy                       - no "Training"
--   Heavyweight Golem  = Raider's Tanking Dummy   - no "Dummy" at all
--   Reinforced Golem   = Raider's Training Dummy  - no "Dummy" at all
-- The last two are the boss-level raider's dummies this feature exists for.
-- Their dummy type lives in the tooltip SUBTITLE, which an addon cannot read
-- off a unit - only the NPC name, which is a golem. So: substring "Dummy"
-- covers every actual dummy, and the golems are listed by name. If a new one
-- ever fails to capture, adding one string here is the whole fix.
TP.PRACTICE_TARGETS = { "Dummy", "Reinforced Golem", "Heavyweight Golem" }

function TP.IsPracticeTarget(name)
	if type(name) ~= "string" or name == "" then
		return false
	end
	for _, needle in ipairs(TP.PRACTICE_TARGETS) do
		if name:find(needle, 1, true) then
			return true
		end
	end
	return false
end

-- Does this fight belong in numbers that ACCUMULATE — career GPA, run
-- averages, the personal trend, personal bests? Practice does not (Josh
-- 2026-07-30: "we need to make sure practice sessions (target dummy) aren't
-- counted towards any averages or careers"). A dummy parse is a rehearsal
-- against a target that doesn't fight back; it is graded on its own card and
-- goes no further. One named rule rather than a `not f.practice` at each
-- site, so a new aggregate has something to ask.
function TP.CountsInAggregates(fight)
	return not (fight and fight.practice)
end

-- Per client: the anchor names a boss in THAT client's percentile file, and
-- borrows its bracket. Nothing on retail yet (which Midnight boss the
-- community treats as the patchwerk isn't settled, and naming the wrong one
-- would score every dummy session against a fight with a different damage
-- profile) - so retail practice records and displays, it just carries no
-- curve rather than a wrong one. Constants loads before Compat, hence the
-- raw project check. Update per tier alongside the zone ids.
-- the MAINLINE ~= nil guard matters: headless tests define neither global,
-- and a bare equality would make nil == nil read as retail
TP.PRACTICE_ANCHOR = (WOW_PROJECT_MAINLINE ~= nil and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)
	and nil or { name = "Iron Juggernaut", difficultyID = 3 }
