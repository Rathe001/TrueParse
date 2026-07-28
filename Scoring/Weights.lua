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
	-- TANK (Josh 2026-07-26): survival is a tank's job, so it leads. The
	-- Mitigation metric = active-mitigation UPTIME scored against the spec's
	-- real WCL field (Data/TankAnchors, crawled from the Buffs table), the
	-- one survival stat WCL exposes - WCL-relative, not the old arbitrary
	-- anchors (avoidance/block/soak are passive, gear, or double-count the
	-- mit buffs, so they're context, not scored). Damage + healing
	-- (self-heal) are the other WCL parses. Named "Mitigation", not the old
	-- "Tanking" composite, because that IS what it measures now.
	TANK    = { mitigation = 0.55, damage = 0.31, healing = 0.14 },
	HEALER  = { damage = 0.21, healing = 0.79 },
	DAMAGER = { damage = 0.86, healing = 0.14 },
	-- Augmentation & friends: personal damage is a small, expected slice
	-- (their real output lives in allies' numbers). Their defining metric
	-- is buff uptime, self-reported over Sync when the Aug runs
	-- TrueParse; when absent it redistributes.
	SUPPORT = { damage = 0.36, healing = 0.14, prescience = 0.50 },
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
	-- dispel REACTION time (Classic CLEU): small ± for how fast debuffs
	-- get cleared, on top of the volume adjustment above. Field: p25
	-- 2.4s, med 3.7s, p75 5.8s.
	dispelReactBonus = 1, dispelReactFast = 2.5,
	dispelReactPenalty = 1, dispelReactSlow = 6,
	shareCenter = 55, -- smoothed share score that reads as "did your part"
	-- avoidable damage (meter data, everyone): clean play earns a little,
	-- standing in bad costs up to the old penalty cap
	avoidableCleanBonus = 3,
	avoidablePressureRef = 0.10, -- avoidable/taken share = full pressure (p95)
	-- addon-reported extras (absence is neutral, never a penalty)
	activityMax = 4,
	activityLow = 70, -- real p25
	activityHigh = 89, -- real p75
	preparedBonus = 1, -- flask + food at the pull
	healthstoneBonus = 1, -- ate a healthstone (warlock in group only)
	healthstonePenalty = 1, -- sat on it (warlock in group only)
	defensivesBonus = 2, -- used 2+ defensives (real p90 behavior)
	readyAtDeathPenalty = 3, -- died with 2+ defensives sitting unused
	-- cooldown timing (Classic CLEU for everyone; retail self-reports):
	-- fraction of danger windows a cooldown actually covered
	cdTimingMax = 5,
	cdTimingLow = 0.25,
	cdTimingHigh = 0.75,
	lustMax = 3, -- DPS cooldown+potion alignment inside lust windows
	rezBonus = 2, -- per combat rez cast
	-- every-metric-scores pass (2026-07-15); all data-gated, absent = 0.
	-- Overheal thresholds below are the FALLBACK; per-spec crawled
	-- curves (TP.OverhealCurves, v1.4.5) take precedence when present.
	overhealHigh = 2, overhealHighAt = 60,
	overhealMid = 1, overhealMidAt = 45,
	overhealLowBonus = 1, overhealLowAt = 20,
	overkillPenalty = 1, overkillAt = 10,
	manaDryPenalty = 1, -- dry before 80% of the fight (dry at the kill is fine)
	deathNoDefensives = 2, -- died having never used a defensive
	rezCap = 4,
}

-- Augmentation damage attribution. An Aug's personal damage massively
-- understates their contribution — their output lands in allies' bars,
-- and no C_DamageMeter support-damage attribute exists. WCL credits them
-- the damage their buffs ENABLED; we approximate it from the self-reported
-- Ebon Might uptime applied to the buffed allies (Ebon Might auto-targets
-- the highest-damage players). CALIBRATED against Drayke's real fights
-- (2026-07-14): transfer 0.12 on the top-4 buffed allies landed within
-- ~5% of WCL's attributed DPS both fights (ours 31.9k/45.9k vs WCL
-- 31.5k/48.0k). Recalibrate as more Aug fights land.
-- NOTE (Josh 2026-07-26): Ebon Might uptime feeds THIS attribution ONLY,
-- it is no longer a separate scored metric. Higher uptime already means a
-- higher Amplified score, so scoring uptime again double-counted it.
Weights.ebonTransfer = 0.12 -- fraction of a buffed ally's damage credited per point of uptime
Weights.ebonTargets = 4 -- Ebon Might's target count (the top damage dealers)

-- Prescience cadence that earns a SUPPORT player 100 points (Josh
-- 2026-07-26). True Prescience uptime isn't readable from the Aug's own
-- client (it lives on allies, whose auras are secret on Midnight, and the
-- Evoker carries no personal aura), so we score how close they kept to
-- casting it on cooldown. Two Prescience buffs held up is ~5 casts/min
-- (roughly a 12s buff, 2 targets). Calibrate as real Aug reports land.
Weights.prescienceCadenceAnchor = 5 -- casts/min for a full score

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

-- True's WCL component IS the percentile (Josh 2026-07-25: "True = your
-- WCL percentile + your earned adjustments"). The old 30 + 0.7x transform
-- predated the adjustments architecture — softening low parses was its
-- job, and adjustments do that job now, honestly, through earned points.
-- Floor/slope kept as knobs but neutral: identity transform.
Weights.trueAbsFloor = 0
Weights.trueAbsSlope = 1

-- === Derived scoring (Engine's three tiers, Josh 2026-07-28) ===
-- Content WCL doesn't rank at the difficulty you played it (a Normal or
-- leveling run of a dungeon only ranked at M+, a Timewalking dungeon with no
-- curves at all) used to fall through to a group comparison, where the
-- room's best is a 99 by definition. Instead the shipped curves are reused
-- as a DERIVED comparison: the player's rate is scaled into the curve
-- population's terms before it's interpolated, so 50 still means "an average
-- player at YOUR item level".
--
-- Reference gear is resolved per client in Engine (percentileRefIlvl): the
-- data file's own P.refIlvl, else the median ilvlMedian of that client's
-- Benchmarks encounters — retail 291, MoP Classic 563. It MUST stay
-- data-driven; a hardcoded retail number scaled every MoP player's rate down
-- by two thirds. This constant is only the last-resort fallback for a client
-- shipping neither. (An independent fit of Josh's own captures — regressing
-- ln(rate / curve p50) on ilvl — put retail at 274, close enough to the
-- crawl's stated 291 to trust the crawl's.)
Weights.derivedRefIlvl = 291

-- Anti-collapse guard. Benchmarks' 1.489%/ilvl slope is fitted inside a
-- narrow max-level band; run it raw across a 170-ilvl leveling gap and it
-- compounds to 15x+, which pegs a whole leveling group at 99. Capping the
-- extrapolated gap is what keeps the off-difficulty populations consistent
-- with each other — uncapped, Josh's Normal-dungeon and Heroic-dungeon
-- medians land at 0.58x and 0.29x of the curve median respectively; capped
-- they agree, so a single lift can serve both.
--
-- BOTH knobs below were tuned empirically, not derived: scored against all
-- 183 of Josh's captures, swept, and picked for the pair whose T2/T3 score
-- distributions track TIER 1's — the direct-comparison baseline he already
-- accepts — across every quantile (2026-07-28, 674/81/535 player-scores):
--   T1 direct   p5 6  p25 24  median 43  p75 66  p95 89
--   T2 derived  p5 8  p25 24  median 46  p75 69  p95 92
--   T3 derived  p5 7  p25 21  median 38  p75 66  p95 96
-- Deriving them analytically instead overshot badly (median 72): the dungeon
-- curves are compressed (p99/p50 = 1.26 vs 2.09 in raids), so a small change
-- in the rate ratio swings the percentile hard. Retune the same way — sweep
-- against real captures, match T1's quantiles — if the curves are recrawled.
-- LEVEL-SCALED content (Timewalking) already flattens everyone, so item
-- level barely predicts output there and the normal gear correction
-- massively overshoots. Measured on Josh's captures (2026-07-28), slope of
-- ln(rate) on item level by content:
--   raid                        2.01 %/ilvl   (corr 0.58)
--   dungeon, not scaled         1.06 %/ilvl   (corr 0.77)
--   Timewalking, level-scaled   0.23 %/ilvl   (corr 0.22)
-- Applying the shipped 1.489 there over-corrects ~6.5x - a 3.8x boost where
-- reality is 1.23x - which is exactly why Timewalking scores read high.
Weights.derivedIlvlSlopeScaled = 0.23

Weights.derivedIlvlCap = 90

-- Off-difficulty lift. Even at equal gear, players running content BELOW the
-- difficulty WCL ranks put out less than the ranked population (smaller
-- pulls, no consumables, no coordination) — and the dungeon curves are
-- top-runs-skewed on top of that. See the tuning note above.
-- Tier II and tier III need DIFFERENT lifts and used to share one knob,
-- which is why no single value fit either (validation pass 2026-07-28).
-- Tier II is a real difficulty of real content: once gear-scaled against the
-- raid pool it needs no lift at all. Tier III is mostly Timewalking, where
-- the content itself rescales players, so it needs a large one.
Weights.derivedOffDifficulty = 1.0    -- tier II
Weights.derivedOffDifficultyT3 = 3.0  -- tier III, normal-power content
-- Tier III in LEVEL-SCALED content needs its own, much larger correction.
-- Timewalking squashes every character's power to the old expansion's
-- level, so the gap to a max-level raid population is content scaling, not
-- gear - and with the gear slope now honest (0.23%/ilvl) nothing else was
-- accounting for it. Tuned the same way as the others: swept until the
-- Timewalking distribution tracked tier 1's (2026-07-28).
Weights.derivedOffDifficultyScaled = 4.0

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
