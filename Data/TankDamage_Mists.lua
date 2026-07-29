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
	default = { 4.21, 7.59, 11.45 }, -- DERIVED: median of the 5 crawled specs
	[66] = { 4.21, 6.9, 9.96 }, -- Prot Paladin (n=88)
	[73] = { 3.65, 6.95, 9.83 }, -- Prot Warrior (n=62)
	[104] = { 4.56, 8.47, 11.92 }, -- Guardian Druid (n=60)
	[250] = { 3.85, 7.59, 11.45 }, -- Blood DK (n=94)
	[268] = { 4.52, 9.04, 11.62 }, -- Brewmaster (n=71)
}