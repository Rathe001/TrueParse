-- Fixed role weights and calibration constants. NOT user-configurable by
-- design: every player's score has to mean the same thing.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
--
-- expectedShare values are calibrated from real captured runs (first pass:
-- Shrine of the Storm TW, 14 fights, 2026-07-07):
--   damage share  — DPS 29.2%, tank 10.3%, healer 4.1%
--   healing share — healer 46.6%, tank 14.8%, DPS 13.2% (self-healing is big)
--   dmgTaken share — tank 40.4%
-- Recalibrate as more runs land in TrueParseDB.global.recentFights.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Weights = {}
TP.Scoring.Weights = Weights

-- Positive metric weights per role; each row sums to 1.0 (asserted by
-- tests). Metrics a player can't act on (no kicks possible, nothing to
-- dispel, not a tank) go inapplicable and renormalize.
Weights.roleWeights = {
	TANK    = { damage = 0.25, healing = 0.10, damageTaken = 0.35, interrupts = 0.20, dispels = 0.10 },
	HEALER  = { damage = 0.15, healing = 0.55, interrupts = 0.15, dispels = 0.15 },
	DAMAGER = { damage = 0.50, healing = 0.15, interrupts = 0.25, dispels = 0.10 },
	-- Augmentation & friends: personal damage is a small, expected slice
	-- (their real output lives in allies' numbers), so utility weighs more.
	SUPPORT = { damage = 0.40, healing = 0.20, interrupts = 0.25, dispels = 0.15 },
}

-- Solo-role-cohort fallback: when you're the only one of your role, your
-- share of the group total is scored against these expectations.
Weights.expectedShare = {
	TANK    = { damage = 0.105, healing = 0.15, damageTaken = 0.40 },
	HEALER  = { damage = 0.04,  healing = 0.50 },
	DAMAGER = { damage = 0.29,  healing = 0.15 },
	-- Calibrated from a real aug run (King Dazar TW, 2026-07-07): aug did
	-- ~13-16% of group damage while fully buffing.
	SUPPORT = { damage = 0.14,  healing = 0.15 },
}

-- When a WCL absolute benchmark exists for the fight+spec, throughput
-- scores blend "fraction of the top-logs median you produced" (consistent
-- across groups) with the within-group comparison (differentiates the
-- room, absorbs content-difficulty mismatch). 0 = pure group-relative,
-- 1 = pure absolute.
Weights.absoluteBlend = 0.6

Weights.penalties = {
	-- Avoidable damage: penalize taking MORE than your equal share of the
	-- group's avoidable damage. Eating ~40% above your share = full cap.
	avoidablePerExcessShare = 37.5,
	avoidableCap = 15,
	perDeath = 10,
	deathsCap = 20,
	-- Deaths hurt less the later they happen: a death at the very end of
	-- the fight keeps (1 - relief) of the penalty. Applies to the most
	-- recent death when its timing is known; earlier deaths cost full price.
	deathTimingRelief = 0.7,
	totalCap = 25,
}
