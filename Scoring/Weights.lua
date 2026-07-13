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

-- BASE weights per role; each row sums to 1.0 (asserted by tests).
-- 2026-07-13 redesign: the base holds ONLY evidence available for every
-- player regardless of the addon — WCL percentile curves for damage and
-- healing (split per spec by its population's own median mix) and the
-- meter's damage-taken share for tanks. Kicks, dispels, and every
-- addon-reported metric moved to Weights.adjustments: signed nudges on
-- top of the base, so a player without the addon still grades
-- accurately on what we can verify. Ratios preserve the old
-- damage:healing:taken proportions per role.
Weights.roleWeights = {
	TANK    = { damage = 0.36, healing = 0.14, damageTaken = 0.50 },
	HEALER  = { damage = 0.21, healing = 0.79 },
	DAMAGER = { damage = 0.86, healing = 0.14 },
	-- Augmentation & friends: personal damage is a small, expected slice
	-- (their real output lives in allies' numbers). Their defining metric
	-- is buff uptime, self-reported over Sync when the Aug runs
	-- TrueParse; when absent it redistributes.
	SUPPORT = { damage = 0.36, healing = 0.14, buffUptime = 0.50 },
}

-- Signed adjustments on TOP of the base. Bounded so a score never
-- drifts far from its verifiable core, and context-scaled: kicks on a
-- 12-kick fight swing the full range, on a 1-kick fight they barely
-- move. Reference intensities and ramps come from the 2026-07-13
-- fight-history distributions (123 real boss fights).
Weights.adjustments = {
	totalCap = 15, -- |net adjustment| ceiling
	-- count metrics (meter data, everyone): share-vs-even-share lean,
	-- scaled by the fight's own volume of that mechanic
	kicksMax = 6,
	kicksFullIntensity = 6, -- group kicks at which a fight is "kick-heavy" (p90)
	dispelsMax = 4,
	dispelsFullIntensity = 8,
	shareCenter = 55, -- smoothed share score that reads as "did your part"
	-- avoidable damage (meter data, everyone): clean play earns a little,
	-- standing in bad costs up to the old penalty cap
	avoidableCleanBonus = 3,
	avoidablePressureRef = 0.10, -- avoidable/taken share = full pressure (p95)
	-- addon-reported extras (absence is neutral, never a penalty)
	activityMax = 4,
	activityLow = 70, -- real p25
	activityHigh = 89, -- real p75
	mitigationMax = 4,
	mitigationLow = 40,
	mitigationHigh = 70,
	preparedBonus = 1, -- flask + food at the pull
	defensivesBonus = 2, -- used 2+ defensives (real p90 behavior)
	readyAtDeathPenalty = 3, -- died with 2+ defensives sitting unused
	-- cooldown timing (Classic CLEU for everyone; retail self-reports):
	-- fraction of danger windows a cooldown actually covered
	cdTimingMax = 5,
	cdTimingLow = 0.25,
	cdTimingHigh = 0.75,
	lustMax = 3, -- DPS cooldown+potion alignment inside lust windows
	rezBonus = 2, -- per combat rez cast
	rezCap = 4,
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
-- FALLBACK ONLY where percentile curves exist (see below): stacked with the
-- ilvl extrapolation this bar collapsed ~30 ilvls below elite gear, capping
-- p9 parses at 100 (Malkorok forensics, 2026-07-09).
Weights.absoluteAnchor = 0.75

-- When a bracket percentile curve covers the fight+spec, True's WCL
-- component is floor + slope * percentile: the population average (p50)
-- lands at 65 — the same target mean as every other True bar — and elite
-- approaches 100. Percentile-within-your-own-bracket also prices gear far
-- better than exponential ilvl extrapolation from elite parses.
Weights.trueAbsFloor = 30
Weights.trueAbsSlope = 0.7

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
	-- Threat penalties only score in small groups: raid encounters fixate,
	-- charge, and mind-control on purpose (2026-07-09 raid data: every Thok
	-- attempt penalized both tanks; Spoils marked the whole raid), so above
	-- this player count the data stays informational.
	threatMaxPlayers = 5,
	totalCap = 25,
}
