-- Per-spec HEALER DAMAGE baselines for five-man content: { p25, p50, p75 } of
-- a healer's damage as a MULTIPLE OF THE PARTY'S PER-PLAYER MEAN. Read 0.40 as
-- "this healer did 40% of what the average party member did".
--
-- Why this exists (Josh 2026-08-01, found by field-testing a heroic dungeon).
-- Healer damage was scored against WCL's ranked RAID healers, who barely DPS -
-- the reference for a Resto Druid is 955/s against a real dungeon healer's
-- 16-31k. 37% of healer damage scores came out above 90 on a metric carrying
-- 21% of the healing family's weight, so it was roughly ten free points. Same
-- shape as the M+ healer HPS problem: a reference from a population playing
-- different content.
--
-- A MULTIPLE of the party mean rather than a rate, for the same reason the
-- tank anchors use it: invariant to key level and party size, so one number
-- per spec covers every dungeon and every key instead of a curve per band.
local _, TP = ...

TP.HEALER_DAMAGE_UNIT = "party-mean-multiple"

TP.HEALER_DAMAGE_ANCHORS = {
	default = { 0.136, 0.186, 0.211 }, -- DERIVED: median of the 4 crawled specs
	[105] = { 0.085, 0.159, 0.169 }, -- Resto Druid (n=21)
	[256] = { 0.128, 0.174, 0.198 }, -- Disc Priest (n=24)
	[264] = { 0.136, 0.186, 0.211 }, -- Resto Shaman (n=54)
	[270] = { 0.304, 0.381, 0.431 }, -- Mistweaver (n=42)
}