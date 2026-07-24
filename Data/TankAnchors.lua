-- Per-spec anchors for the composite Tanking gauge: { p25, p75, top }.
-- Tank classes route their survival budget through different pipes (DK
-- self-healing, warrior block, bear/monk avoidance), so the same skill
-- produces different raw composites per spec. Anchoring each spec
-- against ITS OWN field population makes "equally skilled tanks parse
-- similarly" true by construction — the same way damage parses already
-- work (Josh 2026-07-24).
--
-- Entries are emitted by scripts/analyze-history.lua once enough field
-- captures accumulate; until a spec has one, the global provisional
-- default applies. NEVER hand-tune these — quantiles come from data.
local _, TP = ...

TP.TANK_ANCHORS = {
	default = { 30, 55, 75 }, -- provisional, all specs, pre-calibration
	-- [250] = { lo, hi, top },  -- Blood DK       (emit from field data)
	-- [73]  = { lo, hi, top },  -- Prot Warrior
	-- [66]  = { lo, hi, top },  -- Prot Paladin
	-- [104] = { lo, hi, top },  -- Guardian Druid
	-- [268] = { lo, hi, top },  -- Brewmaster
}
