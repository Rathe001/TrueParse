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

-- The C_DamageMeter attributes captured per fight (Midnight+ clients).
-- `enum` names a key in Enum.DamageMeterType, resolved at runtime so a
-- missing attribute on some client just drops that metric.
-- EnemyDamageTaken is skipped: its sources are enemies, not group members.
TP.METRIC_DEFS = {
	{ key = "damage",         enum = "DamageDone" },
	{ key = "dps",            enum = "Dps" },
	{ key = "healing",        enum = "HealingDone" },
	{ key = "hps",            enum = "Hps" },
	{ key = "absorbs",        enum = "Absorbs" },
	{ key = "damageTaken",    enum = "DamageTaken" },
	{ key = "avoidableTaken", enum = "AvoidableDamageTaken" },
	{ key = "interrupts",     enum = "Interrupts" },
	{ key = "dispels",        enum = "Dispels" },
	{ key = "deaths",         enum = "Deaths" },
}
