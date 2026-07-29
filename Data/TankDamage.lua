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
-- actually playing.
--
-- RETAIL: not crawled yet. An empty table is the correct placeholder - the
-- engine falls straight back to the ranked curve, exactly as before.
local _, TP = ...

TP.TANK_DAMAGE_ANCHORS = {}
