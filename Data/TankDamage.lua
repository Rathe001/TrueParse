-- Per-spec tank DAMAGE baselines: { p25, p50, p75 } of a tank's damage as a
-- MULTIPLE OF THE GROUP'S PER-PLAYER MEAN, crawled from Warcraft Logs
-- (scripts/fetch-tank-mitigation.ps1, same query as the mitigation pass).
-- Read 0.78 as "this tank did 0.78x what the average raider did".
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
-- MULTIPLE OF THE GROUP MEAN rather than DPS: it pools across encounters,
-- brackets and gear, so one anchor per spec holds everywhere instead of
-- needing a curve per boss. A spec too rare to crawl falls back to
-- default, itself the median of the crawled specs.
--
-- It used to be a SHARE of raid damage (%), and that was WRONG: share is
-- inversely proportional to raid size, so one anchor could not cover the
-- sizes this crawl deliberately pools. Measured on real captures
-- 2026-07-31, 10-man tanks sat at a 6.62% median share against 2.85% for
-- 21-30 man - so 65 of 69 ten-man tank-fights cleared their own p75 and
-- auto-scored 100, while 25-man tanks fell below p25 for median play.
-- Normalising by group size collapses that 2.3x gap to 7% (0.662 vs 0.713).
-- TANK_DAMAGE_ANCHOR_UNIT exists so the engine can refuse to score against
-- a stale share-based file rather than silently mixing the two.
local _, TP = ...

TP.TANK_DAMAGE_ANCHOR_UNIT = "mean-multiple"

TP.TANK_DAMAGE_ANCHORS = {
	default = { 0.63, 0.73, 0.85 }, -- DERIVED: median of the 6 crawled specs
	[66] = { 0.62, 0.73, 0.85 }, -- Prot Paladin (n=69)
	[73] = { 0.67, 0.77, 0.92 }, -- Prot Warrior (n=56)
	[104] = { 0.63, 0.76, 0.87 }, -- Guardian Druid (n=57)
	[250] = { 0.53, 0.63, 0.73 }, -- Blood DK (n=148)
	[268] = { 0.64, 0.72, 0.84 }, -- Brewmaster (n=54)
	[581] = { 0.6, 0.71, 0.85 }, -- Vengeance DH (n=38)
}