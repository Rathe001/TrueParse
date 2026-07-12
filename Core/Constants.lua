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
	buffUptime = "Buff Uptime",
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
