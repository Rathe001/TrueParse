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
-- Blending several metrics SHRINKS a role's score spread, which decides who
-- can reach the top of a meter at all. A DPS is 0.86 damage - essentially one
-- number, full spread. A tank is 0.55/0.31/0.14, so their grade is an average
-- of three, and averaging pulls toward the middle. Measured on 190 real MoP
-- boss fights: DPS std-dev 31.6, tank 22.3 - and tanks topped the meter on 2%
-- of fights against a 20% fair share by cohort size (Josh 2026-07-29: "I want
-- everyone to have an equal chance to top the meters, regardless of role").
--
-- The shrinkage factor for independent metrics is sqrt(sum of squared
-- weights): DPS 0.87, healer 0.817, tank 0.647. Predicted tank/DPS spread
-- ratio 0.74 against 0.71 observed, so the model holds and the metrics are
-- close enough to independent to invert it. Deviations from 50 are rescaled
-- by reference/concentration, which restores the spread WITHOUT moving the
-- role's centre - a role that genuinely sits below average still does.
--
-- Note this is not the same claim as "p75 in, 75 out". Being simultaneously
-- p75 on three semi-independent dimensions is far rarer than p75 on one, so
-- a tank who holds p75 across all three IS better than a p75 DPS. Expanding
-- the blend is what makes the two comparable.
Weights.spreadReference = 0.87 -- DAMAGER's concentration: the yardstick

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
	-- ...but ONLY when the fight gave a reason to press it (Josh 2026-07-29:
	-- "healthstones should only be a penalty if there was significant damage
	-- taken to justify using it"). Danger is a personal spike window or a
	-- death; failing those, having taken at least this multiple of your own
	-- max HP. Measured on real fights, intake/maxHP runs p25 0.65, p50 1.93,
	-- so 1.0 keeps the genuinely dangerous fights and drops the trivial ones.
	-- The BONUS stays unconditional: eating one is never wrong.
	healthstoneMinIntake = 1.0,
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
-- How much of a tank's EXPECTED intake share still counts as a real tanking
-- fight. Mitigation keeps its full weight at or above this fraction of
-- expectedShare.TANK.damageTaken; below it the weight slides to zero and
-- moves to damage/healing (Josh 2026-07-30: "if there is very little damage
-- intake, the ratio should move more towards doing damage instead of
-- tanking"). Half, because a tank taking half their usual share is still
-- tanking - the shift is for pulls that barely touched them, not for a
-- fight where the damage was merely light. A test fixture's tank at 50% of
-- group intake (0.86 of expected) must come out completely unshifted.
Weights.tankIntakeFull = 0.5

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
-- A DERIVED tier cannot certify an elite parse (Josh 2026-07-28: "players
-- shouldn't consistently hit a 99, let alone multiple"). Tier II and III
-- compare against a population that never played this content, and no amount
-- of correction makes that evidence strong enough to say "top 1%". The
-- reference is also measurably tighter than the rooms we score - pooled
-- spread 1.97x against 2.48x observed in real 5-mans - so everyone above
-- average lands at the top of a curve that has no top left. Ceilings say
-- what the tier labels already say: approximate, and rough.
Weights.derivedCeiling = { [2] = 95, [3] = 90 }
-- COMPRESSED, not clamped (Josh 2026-07-28: "doesn't that mean we'll see a
-- bunch of players pegged at 90 instead of 99?" - measured, and a hard clamp
-- put 38% of tier-3 scores on exactly 90, which is a worse failure than the
-- 99s it replaced). Everything below the knee is untouched; the range above
-- it is squeezed into knee..ceiling, so the ordering survives and nobody
-- piles up except players the curve genuinely cannot separate.
Weights.derivedCeilingKnee = 70

-- Dispersion between the reference curve and the rooms we score does NOT
-- line up (2.48x observed against 1.97x pooled), and damping the
-- deviation to match was tried and REVERTED 2026-07-28: measured against
-- real fights it moved score ORDERING by 1 point in 215 pairs. The
-- inversions it was meant to fix are mostly legitimate - two specs are
-- held to different bars, and tier 1 shows the same 6% rate on curves we
-- know are right. Do not re-add without a measurement that moves.

Weights.derivedIlvlSlopeScaled = 0.23

-- REFIT 90 -> 150 (2026-07-29), on the trigger this file names above: the
-- reference population changed. The T3/T2 pool is raid-keyed now, because
-- WCL's dungeon rankings are the top 2000 by keystone score and their curves
-- have no lower tail (p10/p50 0.86 against 0.58 in raids) — see
-- Engine.averageSeasonalDungeon. The old narrow pool SATURATED, which hid how
-- badly a 90-ilvl cap under-corrects: with refIlvl ~270-291, an ilvl-120
-- character has a real gap of ~150-171, so a third of it went uncorrected
-- (~3.3x) and the score simply pegged instead of showing it.
--
-- Swept against all three criteria; 150 is where they agree:
--   cap   validate gear drift   T1-tracking maxdev (T2/T3)   residual %/ilvl (T2)
--    90   62  FAIL             18.6 / 14.2                  +0.575
--   120   43  FAIL             14.3 / 12.3                  +0.223
--   140   20  FAIL (marginal)  11.8 / 11.2                  ~0
--   150   pass                 13.1 / 10.6                  -0.117
--   171   pass                 15.1 / 11.0                  -0.301
--   180   pass                 15.3 / 11.3                  -0.328
-- 140 tracks T1 marginally better but still misses the gear-invariance gate,
-- which is the promise the derived tier makes out loud ("50 means an average
-- player at YOUR item level"). Past 150 the tracking decays and the residual
-- goes NEGATIVE — over-correcting the under-geared, i.e. handing out generous
-- scores for gear you do not have, the worse of the two failure modes.
-- Residual slope = ln(rate/specMedian) regressed on item level across Josh's
-- captures after correction; 0 means gear is fully accounted for. Expect it
-- slightly POSITIVE at the ideal, since better-geared players also play
-- better, which argues for the low end of the passing range.
Weights.derivedIlvlCap = 150

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

-- === Mythic+ key level ===============================================
-- Key level below which the comparison stops being DIRECT. The dungeon curves
-- are WCL's top 2000 BY KEYSTONE SCORE, so they describe high-key play, and
-- tier 1 applies no gear normalization to absorb the gap. Measured on Josh's
-- +2/+3 night (42 DPS scores): 97.6% under 10, median ratio to the reference
-- 0.186 — a 5.4x gap — at item level 195-270 against a reference near 291.
-- At or above this key the comparison stays tier 1 and a genuine high-key
-- parse can still certify 99.
--
-- 10 is the weakest number in this file: nothing here knows what key band the
-- crawl actually sampled, because the dungeon crawl records no key level at
-- all. Pin it down by crawling per-key-band curves (or by recording the
-- sampled keys) rather than by tuning this.
-- KEPT AT 10 BY JOSH, 2026-07-30, after he questioned the tier-II label on a
-- +2 ("keep mplusDirectKey at 10"). It does override his earlier 2026-07-28
-- call of "the BRACKET, not per-key" — that was decided before the +2/+3
-- measurement above existed. Settled; don't reopen it without new data.
-- How far below a fight's key a crawled keystone band may sit before it stops
-- being a fair comparison. The bands are crawled a few keys apart so 1-2 is
-- the intended approximation; a larger gap means the band that SHOULD have
-- covered this key is missing from the data, and scoring a +15 against a +5
-- population inflates wildly. The highest crawled band is exempt - it stands
-- for "this key and up" by design.
-- How much of its spec profile's expected cast volume a player must actually
-- produce before the rotation coach will judge them on it. Below this the
-- profile is not describing them - either a different build (a Fistweaver
-- Mistweaver runs 1-7% of the caster rotation) or a self-report that never
-- attached (a rogue at 74-86% on most fights read 3.1% on one). Those are
-- indistinguishable from one fight and want the same answer: say nothing.
-- Players on the profiled build measured 50-86%, so the gap is wide.
Weights.profileFitMin = 0.25

Weights.mplusBandMaxGap = 3

Weights.mplusDirectKey = 10

-- Lift for a below-threshold key, replacing derivedOffDifficulty (fitted for
-- a Normal/Heroic clear of an M+-only dungeon, a far smaller gap).
-- Held at 1.0 = NO key lift; gear scaling alone does the work. Measured, that
-- is right, and it matters that the reference is the POOLED one:
--   pooled reference (shipping), DAMAGER median / under-10:
--     lift 1.0 -> 70.0 / 14.3%      2.0 -> 92.1 / 14.3%
--     lift 1.5 -> 87.3 / 14.3%      2.5 -> 93.3 / 14.3%
-- Every lift above 1.0 just pushes the pack into the ceiling without
-- rescuing the tail, so 1.0 it is. (Against the dungeon's OWN narrow curves
-- the same sweep was hopeless in both directions — median 16.6 -> 89.4
-- between 2.5 and 3.0 — which is why the low-key path pools; see Engine.)
Weights.mplusLowKeyLift = 1.0

Weights.penalties = {
	-- Avoidable damage: penalize taking MORE than your equal share of the
	-- group's avoidable damage. Eating ~40% above your share = full cap.
	avoidablePerExcessShare = 37.5,
	-- 9, not the old 15 (Josh 2026-07-28: "+/-15 seems like too much
	-- reward/penalty"). Measured before changing anything: the typical
	-- adjustment is 1.8 points and only 2.7% of scores reach the total cap,
	-- so the TOTAL was not the problem. The problem was that this one cap
	-- EQUALLED the total, so avoidable damage alone could max the whole
	-- budget - 22 of the 31 capped scores were this metric by itself.
	-- Reaching the full 15 should take more than a single mistake.
	avoidableCap = 9,
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
