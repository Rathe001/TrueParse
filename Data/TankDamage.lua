-- Per-spec tank DAMAGE baselines: { p25, p50, p75 } of a tank's share of
-- the raid's total damage for a fight, crawled from Warcraft Logs
-- (scripts/fetch-tank-mitigation.ps1, same query as the mitigation pass).
--
-- Why this exists (Josh 2026-07-28, measured on 219 real MoP fights): on
-- the SAME fights, the damage metric's median was 59.5 for DPS and 59.8
-- for healers - and 26.0 for tanks. Healers score fine against a damage
-- curve; only tanks collapse. That is the reference population, not the
-- players. The ranked curves are built from tanks who show up in damage
-- rankings, which is a self-selected, damage-pushing slice of the tanks
-- actually playing. Scored against the field of every tank in a log, a
-- median tank lands on a median score, which is what the number means.
--
-- SHARE of raid damage rather than DPS: it pools across encounters,
-- brackets and gear, so one anchor per spec holds everywhere instead of
-- needing a curve per boss. A spec too rare to crawl falls back to
-- default, itself the median of the crawled specs.
local _, TP = ...

TP.TANK_DAMAGE_ANCHORS = {
	default = { 3.19, 3.89, 4.48 }, -- DERIVED: median of the 6 crawled specs
	[66] = { 3.19, 4.07, 4.76 }, -- Prot Paladin (n=51)
	[73] = { 3.17, 3.86, 4.28 }, -- Prot Warrior (n=84)
	[104] = { 3.35, 4.19, 4.83 }, -- Guardian Druid (n=69)
	[250] = { 2.92, 3.58, 4.37 }, -- Blood DK (n=99)
	[268] = { 3.19, 3.68, 4.33 }, -- Brewmaster (n=62)
	[581] = { 3.16, 3.89, 4.48 }, -- Vengeance DH (n=44)
}