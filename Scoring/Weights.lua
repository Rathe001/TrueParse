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
	-- healing 0.15 -> 0.10 (2026-07-07 field data: 47% of DPS log zero
	-- off-healing, dragging DPS ~18 pts below healers; the incentive stays,
	-- the drag shrinks). interrupts 0.25 -> 0.18 (2026-07-09 audit: DPS
	-- averaged 30/100 on kicks - a noisy winner-take-all metric was a
	-- quarter of their grade and the main reason DPS trailed other roles).
	DAMAGER = { damage = 0.60, healing = 0.10, interrupts = 0.18, dispels = 0.12 },
	-- Augmentation & friends: personal damage is a small, expected slice
	-- (their real output lives in allies' numbers). Their defining metric is
	-- buff uptime, self-reported over Sync when the Aug runs TrueParse; when
	-- absent it redistributes to roughly the old utility-heavy split.
	SUPPORT = { damage = 0.25, healing = 0.10, buffUptime = 0.35, interrupts = 0.20, dispels = 0.10 },
}

-- Buff uptime that earns a SUPPORT player 100 points: elite Augs hold Ebon
-- Might around 55-70% of a fight, so 100 at 60% keeps S-tier honest without
-- demanding perfection. Calibrate as real Aug reports land.
Weights.supportUptimeAnchor = 0.60

-- Solo-role-cohort fallback: when you're the only one of your role, your
-- share of the group total is scored against these expectations.
-- CALIBRATION RULE: expected = observed-average share / 0.65, so an average
-- performance scores ~65 — matching what the competitive cohort path
-- produces for DPS (2026-07-09 audit: the old /0.75 rule floated tanks and
-- healers ~10 points above DPS purely because their bars had a softer
-- target mean, not because they played better).
Weights.expectedShare = {
	TANK    = { damage = 0.23,  healing = 0.23, damageTaken = 0.58 },
	HEALER  = { damage = 0.063, healing = 0.75 },
	DAMAGER = { damage = 0.33,  healing = 0.17 },
	SUPPORT = { damage = 0.21,  healing = 0.17 },
}

-- The expected-share fallback is the weakest evidence path (no cohort, no
-- benchmark to beat), so it can never award a perfect score by itself —
-- 100s must be earned against actual competition.
Weights.soloCohortCap = 92

-- When a WCL absolute benchmark exists for the fight+spec, throughput
-- scores blend "fraction of the top-logs median you produced" (consistent
-- across groups) with the within-group comparison (differentiates the
-- room, absorbs content-difficulty mismatch). 0 = pure group-relative,
-- 1 = pure absolute.
Weights.absoluteBlend = 0.6

-- WCL rankings pages are ELITE parses; their median sits near the top of
-- the population. Anchoring 100 points at this fraction of that median
-- keeps S-tier meaning "near-elite" without grading a competent pug C.
Weights.absoluteAnchor = 0.75

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
	-- On a wipe everyone dies by definition; grading the attempt shouldn't
	-- mean the deaths cap flattens the whole card. Death penalties scale by
	-- this on fights marked as wipes.
	wipeDeathScale = 0.4,
	-- Providers whose raid buff wasn't fully up at the pull lose up to this
	-- many points, scaled linearly BELOW the coverage threshold. The
	-- threshold absorbs scan noise (2026-07-09 audit: 52% of provider-fights
	-- showed partial coverage, average 0.58 - range/visibility noise at that
	-- rate, not half the raid forgetting buffs).
	missingBuffMax = 3,
	buffCoverageFloor = 0.75, -- coverage above this is treated as full
	-- Threat discipline (Classic clients only; Midnight hides group threat —
	-- see Collect/Threat.lua). Kept light until field data calibrates them:
	-- fixate mechanics and healing aggro can look like rips.
	pulledPack = 5,           -- non-tank started the pull and held the aggro
	perAggroRip = 2.5,        -- each time a non-tank took a mob off the tank
	healerRipScale = 0.5,     -- healing aggro is mostly the tank's slack
	aggroRipsCap = 8,
	aggroLossPerSecond = 0.4, -- tank: per second a mob chewed on a non-tank
	aggroLossCap = 8,
	totalCap = 25,
}
