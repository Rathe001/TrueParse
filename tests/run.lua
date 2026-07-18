-- Headless test runner for the pure-Lua scoring engine.
-- Usage (from the repo root):
--   lua tests/run.lua [optional-path-to-TrueParse-SavedVariables.lua]
-- With an SV path, also scores the captured real fights as a smoke test.

local function loadModule(path, TP)
	local chunk = assert(loadfile(path), "cannot load " .. path)
	chunk("TrueParse", TP)
end

local TP = {}
loadModule("Core/Constants.lua", TP)
loadModule("Core/Utils.lua", TP)
loadModule("Scoring/Capabilities.lua", TP)
loadModule("Scoring/Weights.lua", TP)
loadModule("Scoring/Engine.lua", TP)
loadModule("Scoring/Grades.lua", TP)
loadModule("Data/Benchmarks.lua", TP)
loadModule("Scoring/Awards.lua", TP)
loadModule("Scoring/Coach.lua", TP)
loadModule("Scoring/Runs.lua", TP)
loadModule("Scoring/Insights.lua", TP)
loadModule("Scoring/Bullets.lua", TP)
loadModule("Metrics/Registry.lua", TP)
loadModule("Metrics/Spikes.lua", TP) -- FindWindows/Compute are pure at capture time

-- Awards memoize per fight record; production fights never mutate after
-- capture (late reports invalidate explicitly), but test fixtures do —
-- bypass the memo so every Compute call reflects the current fixture.
do
	local realCompute = TP.Scoring.Awards.Compute
	TP.Scoring.Awards.Compute = function(fight)
		TP.Scoring.Awards.Invalidate(fight)
		return realCompute(fight)
	end
end

local failures = 0
local function check(cond, label)
	if cond then
		print("ok   " .. label)
	else
		failures = failures + 1
		print("FAIL " .. label)
	end
end

-- 1. Every role's weights sum to 1.0
for role, weights in pairs(TP.Scoring.Weights.roleWeights) do
	local sum = 0
	for _, w in pairs(weights) do
		sum = sum + w
	end
	check(math.abs(sum - 1.0) < 1e-9, ("weights sum to 1.0 for %s (got %.4f)"):format(role, sum))
end

-- 1b. Grade mapping: 16 tiers, correct boundaries
-- Score colors are WCL parse brackets; no letter tiers anymore
local G = TP.Scoring.Grades
do
	local r, gr, b = G.ColorForScore(80)
	check(r and gr and b, "score color returns rgb")
	check(select(1, G.ColorForScore(0)) == 0.40, "under 25 is WCL grey")
	check(select(1, G.ColorForScore(24.9)) == 0.40, "24.9 still grey")
	local cr, cg = G.ColorForScore(25)
	check(cg == 1.00 and cr == 0.12, "25 crosses into WCL green")
	local br, bg = G.ColorForScore(50)
	check(br == 0.00 and bg == 0.44, "50 crosses into WCL blue")
	check(select(1, G.ColorForScore(74.9)) == 0.00, "74.9 still blue")
	check(select(1, G.ColorForScore(75)) == 0.64, "75 crosses into WCL purple")
	check(select(1, G.ColorForScore(95)) == 1.00, "95 crosses into WCL orange")
	check(select(1, G.ColorForScore(99.2)) == 0.89, "99+ is WCL pink")
	check(select(1, G.ColorForScore(100)) == 0.90, "100 is WCL gold")
	check(select(1, G.ColorForScore(97)) == 1.00, "97 stays orange")
	check(G.ColoredScore(87.4):find("87", 1, true) ~= nil, "ColoredScore embeds the rounded number")
	-- optional letter ladder: F below 25, five-point steps to S+
	check(G.LetterFor(0) == "F" and G.LetterFor(24.9) == "F", "below 25 is an F")
	check(G.LetterFor(25) == "D-", "25 is a D-")
	check(G.LetterFor(50) == "C+", "50 is a C+")
	check(G.LetterFor(65) == "B+", "65 is a B+")
	check(G.LetterFor(70) == "A-" and G.LetterFor(75) == "A", "70 is an A-, 75 an A")
	check(G.LetterFor(90) == "S", "90 is an S")
	check(G.LetterFor(95) == "S+" and G.LetterFor(100) == "S+", "95+ caps at S+")
	check(G.ScoreLabel(87.4) == "87", "ScoreLabel defaults to numbers without an options DB")
end

-- 1b. Effective role: the spec outranks the assigned group role (solo and
-- open-world content assign none, defaulting everyone to DAMAGER — which
-- graded a Mistweaver as DPS and gave them the non-healer Lifesaver)
do
	local Cap = TP.Scoring.Capabilities
	check(Cap.EffectiveRole("DAMAGER", nil, 270) == "HEALER", "Mistweaver specID overrides DAMAGER fallback")
	check(Cap.EffectiveRole(nil, nil, 66) == "TANK", "Prot paladin specID supplies role with none assigned")
	check(Cap.EffectiveRole("HEALER", nil, nil) == "HEALER", "assigned role stands without a specID")
	check(Cap.EffectiveRole("DAMAGER", 5198700, 1467) == "SUPPORT", "Aug icon still wins over everything")
end

-- 2. Capability gating
local Cap = TP.Scoring.Capabilities
check(not Cap.CanInterrupt("PRIEST", "HEALER"), "priest healer cannot interrupt")
check(not Cap.CanInterrupt("PRIEST", "DAMAGER"), "shadow priest cannot interrupt")
check(not Cap.CanInterrupt("MONK", "HEALER"), "mistweaver cannot interrupt")
check(Cap.CanInterrupt("MONK", "TANK"), "brewmaster can interrupt")
check(Cap.CanInterrupt("SHAMAN", "HEALER"), "resto shaman can interrupt")
Cap.SetMoPRules(true)
check(Cap.CanInterrupt("PALADIN", "HEALER"), "MoP holy paladin can interrupt (Rebuke)")
check(Cap.CanInterrupt("MONK", "HEALER"), "MoP mistweaver can interrupt")
check(not Cap.CanInterrupt("PRIEST", "HEALER"), "MoP priest still cannot interrupt")
Cap.SetMoPRules(false)

-- Synthetic 5-man modeled on observed real shares
local function mkPlayer(guid, name, class, role, m)
	local defaults = {
		damage = 0, healing = 0, absorbs = 0, damageTaken = 0,
		interrupts = 0, dispels = 0, deaths = 0, avoidableTaken = 0,
		potionHealing = 0,
	}
	for k, v in pairs(m) do
		defaults[k] = v
	end
	return { guid = guid, name = name, class = class, role = role, metrics = defaults }
end

local fight = {
	name = "Synthetic Boss", duration = 60,
	players = {
		t = mkPlayer("t", "Tank", "WARRIOR", "TANK",
			{ damage = 600000, healing = 80000, damageTaken = 500000, interrupts = 2 }),
		h = mkPlayer("h", "Heal", "PRIEST", "HEALER",
			{ damage = 60000, healing = 700000, damageTaken = 100000, dispels = 3 }),
		d1 = mkPlayer("d1", "DpsA", "MAGE", "DAMAGER",
			{ damage = 2000000, healing = 100000, damageTaken = 150000, interrupts = 2 }),
		d2 = mkPlayer("d2", "DpsB", "ROGUE", "DAMAGER",
			{ damage = 1500000, healing = 150000, damageTaken = 120000, interrupts = 0, avoidableTaken = 90000, deaths = 1 }),
		d3 = mkPlayer("d3", "DpsC", "EVOKER", "DAMAGER",
			{ damage = 1800000, healing = 300000, damageTaken = 130000, interrupts = 1, dispels = 1 }),
	},
}

local results = TP.Scoring.Engine.ScoreFight(fight)
check(#results == 5, "five results returned")

local byName = {}
for _, r in ipairs(results) do
	byName[r.name] = r
	check(r.score >= 0 and r.score <= 100, ("score in [0,100] for %s (%.1f)"):format(r.name, r.score))
end

-- 3. Capability redistribution: priest healer's interrupt metric inapplicable
check(byName.Heal.breakdown.interrupts.applicable == false, "healer interrupt metric inapplicable (priest)")
check(byName.Heal.breakdown.healing.applicable == true, "healer healing metric applicable")
check(byName.DpsB.breakdown.dispels.applicable == false, "rogue not scored on dispels (no cleanse)")
check(byName.Heal.breakdown.dispels.applicable == true, "priest scored on dispels")

-- 4. Effective weights renormalize to 1.0 over applicable metrics
for _, r in ipairs(results) do
	local sum = 0
	for _, b in pairs(r.breakdown) do
		sum = sum + (b.effectiveWeight or 0)
	end
	check(math.abs(sum - 1.0) < 1e-9, ("effective weights renormalize for %s"):format(r.name))
end

-- 5. Penalties: DpsB ate all avoidable damage and died once
check(byName.DpsB.penalty > 10, ("DpsB penalized (%.1f)"):format(byName.DpsB.penalty))
check(byName.DpsA.penalty == 0, "DpsA not penalized")
check(byName.DpsB.penaltyDetail.avoidable == 15, "avoidable penalty capped at 15")
check(byName.DpsB.penaltyDetail.deaths == 10, "one death costs 10")

-- 6. Cross-role fairness: tank and healer playing well can compete with DPS
-- (expected-share bars target mean ~65, matching what cohort competition
-- produces for DPS - 2026-07-09 recalibration)
check(byName.Tank.score >= 68, ("well-played tank scores high (%.1f)"):format(byName.Tank.score))
check(byName.Heal.score >= 62, ("well-played healer scores high (%.1f)"):format(byName.Heal.score))

-- 6b. Augmentation: detected by spec icon, scored as SUPPORT with its own
-- expectations instead of being crushed by the DPS cohort comparison.
local augFight = {
	name = "Aug Test", duration = 60,
	players = {
		t = mkPlayer("t", "Tank", "WARRIOR", "TANK",
			{ damage = 900000, healing = 80000, damageTaken = 500000, interrupts = 1 }),
		h = mkPlayer("h", "Heal", "PRIEST", "HEALER",
			{ damage = 60000, healing = 700000, damageTaken = 100000, dispels = 1 }),
		d1 = mkPlayer("d1", "DpsA", "MAGE", "DAMAGER",
			{ damage = 4000000, healing = 100000, interrupts = 1 }),
		d2 = mkPlayer("d2", "DpsB", "ROGUE", "DAMAGER",
			{ damage = 2000000, healing = 150000, interrupts = 1 }),
	},
}
augFight.players.aug = mkPlayer("aug", "Auggy", "EVOKER", "DAMAGER",
	{ damage = 1250000, healing = 120000, interrupts = 1 })
augFight.players.aug.specIconID = 5198700

local augResults = TP.Scoring.Engine.ScoreFight(augFight)
local augByName = {}
for _, r in ipairs(augResults) do
	augByName[r.name] = r
end
check(augByName.Auggy.role == "SUPPORT", "aug detected as SUPPORT via spec icon")
-- 2026-07-14: without an uptime report, Aug damage pins NEUTRAL (their
-- amplification is invisible; personal damage is a misleading proxy)
check(augByName.Auggy.breakdown.damage.normalized == 50 and augByName.Auggy.breakdown.damage.noInput,
	("no-data aug damage pins neutral (%.0f)"):format(augByName.Auggy.breakdown.damage.normalized))
check(augByName.Auggy.score >= 40, ("no-data aug grades neutral, not damning (%.1f)"):format(augByName.Auggy.score))
check(augByName.DpsB.breakdown.damage.normalized == 50, "DPS cohort unaffected by aug (B vs A = 50)")
check(augByName.Auggy.breakdown.buffUptime and not augByName.Auggy.breakdown.buffUptime.applicable,
	"no self-reported uptime -> buffUptime inapplicable, weight redistributes")

-- 6b2. Self-reported Ebon Might uptime becomes the SUPPORT-defining metric
augFight.players.aug.metrics.buffUptime = 0.60 -- exactly the anchor
local upResults = TP.Scoring.Engine.ScoreFight(augFight)
local upAug
for _, r in ipairs(upResults) do
	if r.name == "Auggy" then upAug = r end
end
check(upAug.breakdown.buffUptime.applicable, "reported uptime is scored")
check(upAug.breakdown.buffUptime.normalized == 100, "60% uptime hits the anchor: 100")
check(math.abs(upAug.breakdown.buffUptime.effectiveWeight - 0.50) < 1e-9,
	"uptime is the biggest SUPPORT weight (50% of the base)")
check(upAug.score > augByName.Auggy.score, "a high-uptime aug outscores the no-data version")
augFight.players.aug.metrics.buffUptime = 0.30
local halfResults = TP.Scoring.Engine.ScoreFight(augFight)
for _, r in ipairs(halfResults) do
	if r.name == "Auggy" then
		check(r.breakdown.buffUptime.normalized == 50, "30% uptime scores 50")
	end
end
check(TP.Scoring.Weights.roleWeights.DAMAGER.buffUptime == nil, "non-support roles never score uptime")
augFight.players.aug.metrics.buffUptime = nil

-- 6c. Benchmarks: spec factors and ilvl normalization
check(TP.Benchmarks and TP.Benchmarks.ilvlSlopePct > 0, "benchmarks loaded with ilvl slope")
check(TP.Benchmarks.damageFactor[1473] == nil, "no WCL damage factor for Augmentation (SUPPORT path)")

-- Same raw damage: Vengeance DH (factor ~0.5) should normalize far above a
-- Frost mage (factor ~1.1), because it did the same damage on a low-output spec.
local specFight = {
	name = "Spec Test", duration = 60,
	players = {
		a = mkPlayer("a", "VDH", "DEMONHUNTER", "DAMAGER", { damage = 1000000 }),
		b = mkPlayer("b", "FrostMage", "MAGE", "DAMAGER", { damage = 1000000 }),
		c = mkPlayer("c", "Heal", "SHAMAN", "HEALER", { healing = 500000 }),
	},
}
-- synthetic spec factors: real tank-spec IDs would get reroled TANK by
-- spec-first EffectiveRole; the point here is factor math inside a cohort
specFight.players.a.specID = 99991
specFight.players.b.specID = 99992
TP.Benchmarks.damageFactor[99991] = 0.5
TP.Benchmarks.damageFactor[99992] = 1.1
local specResults = TP.Scoring.Engine.ScoreFight(specFight, { normalizeIlvl = false })
local specByName = {}
for _, r in ipairs(specResults) do
	specByName[r.name] = r
end
check(math.abs(specByName.VDH.breakdown.damage.normalized - 100) < 0.001, "low-output spec tops the adjusted cohort")
check(specByName.FrostMage.breakdown.damage.normalized < 60,
	("high-output spec graded against its own ceiling (%.0f)"):format(specByName.FrostMage.breakdown.damage.normalized))

-- Same spec, same damage, different gear: the lower-ilvl player scores
-- higher with normalization on, and identically with it off.
local ilvlFight = {
	name = "Ilvl Test", duration = 60,
	players = {
		a = mkPlayer("a", "LowGear", "MAGE", "DAMAGER", { damage = 1000000 }),
		b = mkPlayer("b", "HighGear", "MAGE", "DAMAGER", { damage = 1000000 }),
		c = mkPlayer("c", "Heal", "SHAMAN", "HEALER", { healing = 500000 }),
	},
}
ilvlFight.players.a.specID = 64
ilvlFight.players.a.ilvl = 250
ilvlFight.players.b.specID = 64
ilvlFight.players.b.ilvl = 290
local onResults = TP.Scoring.Engine.ScoreFight(ilvlFight, { normalizeIlvl = true })
local onByName = {}
for _, r in ipairs(onResults) do
	onByName[r.name] = r
end
check(math.abs(onByName.LowGear.breakdown.damage.normalized - 100) < 0.001, "low-ilvl player tops gear-normalized cohort")
check(onByName.HighGear.breakdown.damage.normalized < 80,
	("high-ilvl same damage scores lower when normalized (%.0f)"):format(onByName.HighGear.breakdown.damage.normalized))
local offResults = TP.Scoring.Engine.ScoreFight(ilvlFight, { normalizeIlvl = false })
local offByName = {}
for _, r in ipairs(offResults) do
	offByName[r.name] = r
end
check(offByName.LowGear.breakdown.damage.normalized == offByName.HighGear.breakdown.damage.normalized,
	"normalization off: equal damage grades equally")

-- 6d. Fight-specific factors: an encounter table overrides global factors,
-- so a spec that struggles on THIS fight is judged against this fight's curve.
TP.Benchmarks.encounters = TP.Benchmarks.encounters or {}
TP.Benchmarks.encounters["Testy the Mover"] = {
	damageFactor = { [64] = 0.5 }, -- frost mage halved on this movement fight
	healingFactor = {},
}
local moveFight = {
	name = "(!) Testy the Mover", isBoss = true, duration = 60,
	players = {
		a = mkPlayer("a", "MoveMage", "MAGE", "DAMAGER", { damage = 500000 }),
		b = mkPlayer("b", "OtherRogue", "ROGUE", "DAMAGER", { damage = 1000000 }),
		c = mkPlayer("c", "Heal", "SHAMAN", "HEALER", { healing = 400000 }),
	},
}
moveFight.players.a.specID = 64
moveFight.players.b.specID = 260
local moveResults = TP.Scoring.Engine.ScoreFight(moveFight, { normalizeIlvl = false })
local moveByName = {}
for _, r in ipairs(moveResults) do
	moveByName[r.name] = r
end
check(moveByName.MoveMage.breakdown.damage.normalized > 90,
	("encounter curve rescues the handicapped spec (%.0f)"):format(moveByName.MoveMage.breakdown.damage.normalized))
-- Same fight scored as non-boss (no encounter match): global factor applies and the mage tanks
local plainFight = { name = "Testy the Mover", isBoss = false, duration = 60, players = moveFight.players }
local plainResults = TP.Scoring.Engine.ScoreFight(plainFight, { normalizeIlvl = false })
local plainByName = {}
for _, r in ipairs(plainResults) do
	plainByName[r.name] = r
end
check(plainByName.MoveMage.breakdown.damage.normalized < 60,
	("without the encounter curve the same play scores low (%.0f)"):format(plainByName.MoveMage.breakdown.damage.normalized))

-- 6e. Absolute blend: with a WCL median for the fight+spec, the score blends
-- "fraction of top-logs median produced" with the group-relative view.
TP.Benchmarks.encounters["Testy the Mover"].damageMedian = { [64] = 20000 } -- mage median dps here
TP.Benchmarks.encounters["Testy the Mover"].healingMedian = {}
local blendResults = TP.Scoring.Engine.ScoreFight(moveFight, { normalizeIlvl = false })
local blendByName = {}
for _, r in ipairs(blendResults) do
	blendByName[r.name] = r
end
-- mage: 500000 dmg / 60s = 8333 dps; anchor 0.75 x 20000 = 15000 -> ~55.6
local mageAbs = blendByName.MoveMage.breakdown.damage.absolute
check(mageAbs and math.abs(mageAbs - 55.6) < 1, ("absolute anchored at 75%% of elite median (%.1f)"):format(mageAbs or -1))
local mageNorm = blendByName.MoveMage.breakdown.damage.normalized
check(mageNorm > mageAbs and mageNorm < 100,
	("blended score sits between absolute and relative (%.1f)"):format(mageNorm))
-- rogue has no median entry on this fight: pure relative, unchanged shape
check(blendByName.OtherRogue.breakdown.damage.absolute == nil, "no benchmark -> no absolute component")
TP.Benchmarks.encounters["Testy the Mover"] = nil

-- 6f. Dungeon absolutes gate on difficulty: M+ logs shouldn't grade TW runs
TP.Benchmarks.dungeons = TP.Benchmarks.dungeons or {}
TP.Benchmarks.dungeons["Testy Halls"] = {
	damageFactor = { [64] = 1.0 },
	healingFactor = {},
	damageMedian = { [64] = 10000 },
	healingMedian = {},
}
local twFight = {
	name = "Trash Pack", isBoss = false, zone = "Testy Halls", difficulty = "Timewalking", duration = 60,
	players = {
		a = mkPlayer("a", "TwMage", "MAGE", "DAMAGER", { damage = 300000 }),
		b = mkPlayer("b", "TwRogue", "ROGUE", "DAMAGER", { damage = 200000 }),
		c = mkPlayer("c", "Heal", "SHAMAN", "HEALER", { healing = 100000 }),
	},
}
twFight.players.a.specID = 64
local twResults = TP.Scoring.Engine.ScoreFight(twFight, { normalizeIlvl = false })
local twByName = {}
for _, r in ipairs(twResults) do
	twByName[r.name] = r
end
check(twByName.TwMage.breakdown.damage.absolute == nil, "no absolute on Timewalking difficulty")
twFight.difficulty = "Mythic Keystone"
local keyResults = TP.Scoring.Engine.ScoreFight(twFight, { normalizeIlvl = false })
local keyByName = {}
for _, r in ipairs(keyResults) do
	keyByName[r.name] = r
end
check(keyByName.TwMage.breakdown.damage.absolute ~= nil, "absolute applies on Mythic Keystone")
TP.Benchmarks.dungeons["Testy Halls"] = nil

-- 7. Nothing-dispelled fight: dispels inapplicable for everyone
local noDispelFight = {
	name = "No dispels", duration = 30,
	players = {
		a = mkPlayer("a", "A", "WARRIOR", "TANK", { damage = 100, damageTaken = 400 }),
		b = mkPlayer("b", "B", "MAGE", "DAMAGER", { damage = 300 }),
		c = mkPlayer("c", "C", "SHAMAN", "HEALER", { healing = 500 }),
	},
}
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(noDispelFight)) do
	check(r.breakdown.dispels.applicable == false, ("dispels inapplicable when none happened (%s)"):format(r.name))
end

-- 8. Awards
local awardFight = {
	name = "Award Test", duration = 60,
	totals = { damage = 5000000, healing = 800000, absorbs = 0, avoidableTaken = 120000 },
	players = {
		t = mkPlayer("t", "Tank", "WARRIOR", "TANK",
			{ damage = 600000, healing = 50000, interrupts = 4, avoidableTaken = 0 }),
		h = mkPlayer("h", "Heal", "PRIEST", "HEALER",
			{ damage = 50000, healing = 500000, dispels = 3, avoidableTaken = 0 }),
		d1 = mkPlayer("d1", "OffHealer", "PALADIN", "DAMAGER",
			{ damage = 2000000, healing = 200000, interrupts = 1, avoidableTaken = 120000 }),
		d2 = mkPlayer("d2", "Tied", "MAGE", "DAMAGER",
			{ damage = 2350000, healing = 50000, interrupts = 4, avoidableTaken = 0 }),
	},
}
local awards = TP.Scoring.Awards.Compute(awardFight)
check(awards.h ~= nil and awards.h[1] == "Cleanser", "healer earns Cleanser (3 dispels)")
check(awards.t == nil or (function()
	for _, a in ipairs(awards.t) do
		if a == "Kick King" then
			return false
		end
	end
	return true
end)(), "tied kick counts award no Kick King")
local offHealerHasLifesaver = false
if awards.d1 then
	for _, a in ipairs(awards.d1) do
		if a == "Lifesaver" then
			offHealerHasLifesaver = true
		end
	end
end
check(offHealerHasLifesaver, "DPS with 25% of group healing earns Lifesaver")
-- ...but only when the healing lands on OTHER people: mostly-self
-- sustain earns Unbreakable instead
awardFight.players.d1.metrics.selfHealing = awardFight.players.d1.metrics.healing * 0.9
local selfAwards = TP.Scoring.Awards.Compute(awardFight)
local hasUnbreakable, stillLifesaver = false, false
for _, a in ipairs(selfAwards.d1 or {}) do
	if a == "Unbreakable" then hasUnbreakable = true end
	if a == "Lifesaver" then stillLifesaver = true end
end
check(hasUnbreakable and not stillLifesaver, "self-heavy healing earns Unbreakable, not Lifesaver")
awardFight.players.d1.metrics.selfHealing = nil
-- Survivalist: most self-rescue healing, and lived
awardFight.players.d2.metrics.potionHealing = 60000
local awards2 = TP.Scoring.Awards.Compute(awardFight)
local hasSurvivalist = false
if awards2.d2 then
	for _, a in ipairs(awards2.d2) do
		if a == "Survivalist" then
			hasSurvivalist = true
		end
	end
end
check(hasSurvivalist, "potion user who lived earns Survivalist")
awardFight.players.d2.metrics.deaths = 1
local awards3 = TP.Scoring.Awards.Compute(awardFight)
local deadSurvivalist = false
if awards3.d2 then
	for _, a in ipairs(awards3.d2) do
		if a == "Survivalist" then
			deadSurvivalist = true
		end
	end
end
check(not deadSurvivalist, "no Survivalist if you died anyway")
awardFight.players.d2.metrics.deaths = 0
awardFight.players.d2.metrics.potionHealing = 0

local untouchableCount = 0
for guid, list in pairs(awards) do
	for _, a in ipairs(list) do
		if a == "Untouchable" then
			untouchableCount = untouchableCount + 1
		end
	end
end
check(untouchableCount == 0, ("no Untouchable when several players dodged (%d)"):format(untouchableCount))
-- exactly one clean player: the sole dodger earns it, and it outranks
-- the Cleanser they also qualified for (one award per player)
awardFight.players.t.metrics.avoidableTaken = 30000
awardFight.players.d2.metrics.avoidableTaken = 40000
local soloDodge = TP.Scoring.Awards.Compute(awardFight)
check(soloDodge.h ~= nil and #soloDodge.h == 1 and soloDodge.h[1] == "Untouchable",
	"the sole dodger earns Untouchable, absorbing lesser awards")
awardFight.players.t.metrics.avoidableTaken = 0
awardFight.players.d2.metrics.avoidableTaken = 0

-- 9. Coach
local coachResults = TP.Scoring.Engine.ScoreFight(fight) -- the original synthetic fight
local coachByName = {}
for _, r in ipairs(coachResults) do
	coachByName[r.name] = r
end
local advice = TP.Scoring.Coach.BiggestOpportunity(coachByName.DpsB)
check(advice ~= nil and advice.kind == "avoidable", "penalized player coached about avoidable damage first")
local adviceA = TP.Scoring.Coach.BiggestOpportunity(coachByName.DpsA)
check(adviceA == nil or adviceA.kind == "metric", "clean player gets metric advice or none")

-- 10. Run aggregation
local runFights = {
	{
		name = "Pull 1", duration = 30, capturedAt = 100, zone = "Testhall",
		totals = { damage = 1000, healing = 200, interrupts = 1 },
		players = {
			a = { guid = "a", name = "A", class = "MAGE", role = "DAMAGER", specID = 64, isLocalPlayer = true,
				metrics = { damage = 700, healing = 0, interrupts = 1 } },
			b = { guid = "b", name = "B", class = "PRIEST", role = "HEALER",
				metrics = { damage = 300, healing = 200, interrupts = 0 } },
		},
	},
	{
		name = "Pull 2", duration = 45, capturedAt = 200, zone = "Testhall",
		totals = { damage = 2000, healing = 500, interrupts = 2 },
		players = {
			a = { guid = "a", name = "A", class = "MAGE", role = "DAMAGER", specID = 64, ilvl = 280,
				metrics = { damage = 1500, healing = 100, interrupts = 0 } },
			b = { guid = "b", name = "B", class = "PRIEST", role = "HEALER",
				metrics = { damage = 500, healing = 400, interrupts = 2 } },
		},
	},
}
local run = TP.Scoring.Runs.Aggregate(runFights, "Testhall Run")
check(run.duration == 75, "run duration sums")
check(run.capturedAt == 200, "run keeps latest capture time")
check(run.players.a.metrics.damage == 2200, "player damage sums across pulls")
check(run.players.a.ilvl == 280, "later fight fills in missing identity")
check(run.totals.interrupts == 3, "totals sum")
check(run.zone == "Testhall", "run keeps zone")
local runScored = TP.Scoring.Engine.ScoreFight(run, { normalizeIlvl = false })
check(#runScored == 2, "aggregated run is scoreable")

-- 11. Death timing: dying late in the fight costs less than dying early
local deathFight = {
	name = "Death Timing", duration = 100,
	players = {
		e = mkPlayer("e", "EarlyDeath", "MAGE", "DAMAGER", { damage = 1000000, deaths = 1 }),
		l = mkPlayer("l", "LateDeath", "ROGUE", "DAMAGER", { damage = 1000000, deaths = 1 }),
		u = mkPlayer("u", "UnknownDeath", "HUNTER", "DAMAGER", { damage = 1000000, deaths = 1 }),
		h = mkPlayer("h", "Heal", "SHAMAN", "HEALER", { healing = 500000 }),
	},
}
deathFight.players.e.deathTime = 5
deathFight.players.l.deathTime = 95
local deathResults = TP.Scoring.Engine.ScoreFight(deathFight, { normalizeIlvl = false })
local deathByName = {}
for _, r in ipairs(deathResults) do
	deathByName[r.name] = r
end
check(deathByName.EarlyDeath.penaltyDetail.deaths > 9,
	("early death costs nearly full price (%.2f)"):format(deathByName.EarlyDeath.penaltyDetail.deaths))
check(deathByName.LateDeath.penaltyDetail.deaths < 4,
	("death at the end costs a fraction (%.2f)"):format(deathByName.LateDeath.penaltyDetail.deaths))
check(deathByName.UnknownDeath.penaltyDetail.deaths == 10, "unknown timing keeps full penalty")

-- 12. Buff-coverage penalty: providers answer for uncovered group members
local buffFight = {
	name = "Buff Check", duration = 60,
	players = {
		p = mkPlayer("p", "SlackPriest", "PRIEST", "HEALER", { healing = 500000 }),
		d1 = mkPlayer("d1", "DpsA", "MAGE", "DAMAGER", { damage = 1000000 }),
		d2 = mkPlayer("d2", "DpsB", "ROGUE", "DAMAGER", { damage = 900000 }),
	},
}
buffFight.players.p.buffCoverage = 0.5 -- half the group missing Fortitude
local buffResults = TP.Scoring.Engine.ScoreFight(buffFight, { normalizeIlvl = false })
local buffByName = {}
for _, r in ipairs(buffResults) do
	buffByName[r.name] = r
end
-- coverage 0.5 against the 0.75 floor: (0.75-0.5)/0.75 * 3 = 1.0
check(math.abs(buffByName.SlackPriest.penaltyDetail.buffs - 1.0) < 0.01,
	("half-covered provider loses 1.0 (%.2f)"):format(buffByName.SlackPriest.penaltyDetail.buffs))
check(buffByName.DpsA.penaltyDetail.buffs == 0, "non-providers aren't penalized")
local buffAdvice = TP.Scoring.Coach.BiggestOpportunity({
	penaltyDetail = { buffs = 4 }, breakdown = {},
})
check(buffAdvice and buffAdvice.kind == "buffs", "coach flags buff coverage")

-- 13. Group insights: strengths/weaknesses derived from results
-- healing weakness needs 2+ HEALERS agreeing (role-primary counting,
-- 2026-07-14: off-heal averages scolded the healer)
local insightResults = {
	{ role = "HEALER", breakdown = { damage = { applicable = true, normalized = 90 }, interrupts = { applicable = true, normalized = 85 },
			healing = { applicable = true, normalized = 40 } },
		penaltyDetail = { deaths = 10 } },
	{ role = "DAMAGER", breakdown = { damage = { applicable = true, normalized = 80 }, interrupts = { applicable = true, normalized = 95 },
			-- damageTaken must never surface as a group strength (solo metric)
			damageTaken = { applicable = true, normalized = 100 } },
		penaltyDetail = { deaths = 10, avoidable = 5 } },
	{ role = "HEALER", breakdown = { damage = { applicable = true, normalized = 70 }, healing = { applicable = true, normalized = 30 } },
		penaltyDetail = { deaths = 10, avoidable = 3, buffs = 2 } },
}
local insights = TP.Scoring.Insights.ForResults(insightResults)
check(insights.strength == "interrupts", ("group strength is interrupts (%s)"):format(tostring(insights.strength)))
check(insights.weakness == "healing", ("two healers under the bar still flag healing (%s)"):format(tostring(insights.weakness)))
check(insights.deaths == 3, "counts players who died")
check(insights.avoidableHitters == 2, "counts avoidable-damage eaters")
check(insights.buffsMissing == true, "flags missing raid buffs")

-- 14. Bullets: plain-language score explanation, sorted by weight
local bulletResult = {
	breakdown = {
		damage = { applicable = true, normalized = 85, contribution = 46.8, effectiveWeight = 0.55, value = 5000000 },
		healing = { applicable = true, normalized = 20, contribution = 2.0, effectiveWeight = 0.10, value = 50000 },
		-- count metrics need a real adjustment to earn a line now
		-- (impact-only card, audit 2026-07-16)
		interrupts = { applicable = true, normalized = 60, contribution = 15.0, effectiveWeight = 0.25, value = 1, adjust = -2 },
		dispels = { applicable = false },
	},
	penaltyDetail = { deaths = 6.5 },
}
bulletResult.role = "DAMAGER"
local bullets = TP.Scoring.Bullets.ForResult(bulletResult, { "Kick King" })
check(#bullets == 5, ("5 bullets: award + 3 metrics + penalty (%d)"):format(#bullets))
check(bullets[1].kind == "award" and bullets[1].text == "Kick King", "award bullet first, gold")
check(bullets[2].text == "Excellent damage" and bullets[2].symbol == "+", "biggest weight first, human phrase, green +")
check(bullets[3].text == "Too few interrupts (-2)" and bullets[3].symbol == "-",
	"count metrics tier statically: 1 kick is grey when plenty happened")
bulletResult.breakdown.interrupts.normalized = 100
bulletResult.breakdown.interrupts.adjust = 1
local shareKick
for _, b in ipairs(TP.Scoring.Bullets.ForResult(bulletResult, nil)) do
	if b.key == "interrupts" then shareKick = b end
end
check(shareKick.text == "Did their share of kicks (+1)" and shareKick.symbol == "+",
	"1 kick covering the fight's whole demand is credited, not scolded")
bulletResult.breakdown.interrupts.normalized = 60
bulletResult.breakdown.interrupts.value = 3
local threeKick
for _, b in ipairs(TP.Scoring.Bullets.ForResult(bulletResult, nil)) do
	if b.key == "interrupts" then threeKick = b end
end
check(threeKick.text == "Good interrupting (+1)" and threeKick.symbol == "+", "3 kicks is blue")
bulletResult.breakdown.interrupts.value = 5
local fiveKick
for _, b in ipairs(TP.Scoring.Bullets.ForResult(bulletResult, nil)) do
	if b.key == "interrupts" then fiveKick = b end
end
check(fiveKick.text == "Godly interrupting (+1)", "5+ kicks is godly")
bulletResult.breakdown.interrupts.value = 1
check(bullets[4].text == "Little off-healing" and bullets[4].symbol == "-", "weak DPS healing phrased as off-healing")
check(bullets[5].kind == "penalty" and bullets[5].text:find("^Died"), "penalty bullet human (now with points)")
bulletResult.breakdown.interrupts.normalized = 0
bulletResult.breakdown.interrupts.value = 0
local zeroBullets = TP.Scoring.Bullets.ForResult(bulletResult, nil)
local kickText
for _, b in ipairs(zeroBullets) do
	if b.key == "interrupts" then kickText = b.text end
end
check(kickText == "Did not interrupt (+1)", ("zero kicks phrased plainly (%s)"):format(tostring(kickText)))
-- curve-scored metrics tier on the PERCENTILE the gauge shows, not the
-- transformed True score (p37 -> 55.9 called itself "Good" in blue while
-- the gauge marker sat in the green zone)
local pctResult = { role = "DAMAGER", penaltyDetail = {}, breakdown = {
	damage = { applicable = true, normalized = 55.9, pctile = 37, effectiveWeight = 0.85, value = 51920000 },
} }
local pctText
for _, b in ipairs(TP.Scoring.Bullets.ForResult(pctResult, nil)) do
	if b.key == "damage" then pctText = b.text end
end
check(pctText == "Average damage", ("bullet tier follows the gauge percentile (%s)"):format(tostring(pctText)))
-- Bloodlust window bullets: DPS-only, shown only when they score
-- (impact-only card, 2026-07-15)
local lustResult = { role = "DAMAGER", penaltyDetail = {}, breakdown = {
	damage = { applicable = true, normalized = 60, effectiveWeight = 1, value = 100 },
} }
local function lustText(extra, role, ad)
	lustResult.role = role or "DAMAGER"
	lustResult.adjustDetail = ad
	for _, b in ipairs(TP.Scoring.Bullets.ForResult(lustResult, nil, extra)) do
		if b.key == "lust" then return b.text end
	end
end
check(lustText({ lustCasts = 2, lustPotion = 1 }, nil, { lust = 3 }) == "Made the most of Bloodlust (cooldowns + potion) (+3)",
	"lust with CDs and potion gets full credit")
check(lustText({ lustCasts = 1, lustPotion = 0 }, nil, { lust = 2 }) == "Used cooldowns during Bloodlust (+2)",
	"lust with CDs only gets partial credit")
check(lustText({ lustCasts = 0, lustPotion = 0 }, nil, { lust = -3 }) == "Wasted Bloodlust - no cooldowns used (-3)",
	"lust with nothing used is called out")
check(lustText({}) == nil, "no lust this fight, no bullet")
check(lustText({ lustCasts = 0 }, "HEALER") == nil, "healers never get lust bullets")
-- WoWAnalyzer-style basics: only lines that moved the score appear
local function infoText(extra, role, wantKey, ad)
	lustResult.role = role or "DAMAGER"
	lustResult.adjustDetail = ad
	for _, b in ipairs(TP.Scoring.Bullets.ForResult(lustResult, nil, extra)) do
		if b.key == wantKey then return b.text, b.symbol end
	end
end
local aText, aSym = infoText({ activityPct = 93 }, "DAMAGER", "activity", { activity = 4 })
check(aText == "Active 93% of the fight (+4)" and aSym == "+", "high activity credited")
local _, aSym2 = infoText({ activityPct = 61 }, "DAMAGER", "activity", { activity = -4 })
check(aSym2 == "-", "low activity flagged")
check(infoText({ activityPct = 80 }, "DAMAGER", "activity") == nil, "neutral activity hidden")
check(infoText({ overhealPct = 62 }, "HEALER", "overheal", { overheal = -2 }) == "62% overhealing (-2)",
	"scored overheal shown")
check(infoText({ overhealPct = 18 }, "HEALER", "overheal", { overheal = 1 }) == "Lean healing - 18% overheal (+1)",
	"lean overheal credited")
check(infoText({ overhealPct = 30 }, "HEALER", "overheal") == nil, "unscored overheal hidden")
check(infoText({ overkillPct = 14 }, "DAMAGER", "overkill", { overkill = -1 }) == "14% of damage was overkill (-1)",
	"scored overkill shown")
check(infoText({}, "HEALER", "manaDry", { manaDry = -1 }) == "Ran out of mana mid-fight (-1)",
	"mana dry scored and shown")
check(infoText({ offensiveCDs = 3 }, "DAMAGER", "offensives") == nil, "unscored offensives hidden now")
local mText, mSym = infoText({ mitigationPct = 82 }, "TANK", "mitigation", { mitigation = 4 })
check(mText == "Active mitigation up 82% (+4)" and mSym == "+", "tank mitigation uptime credited")
check(infoText({ mitigationPct = 55 }, "TANK", "mitigation") == nil, "neutral mitigation hidden")

-- 14a. Every award has a description
for _, label in pairs(TP.Scoring.Awards.LABELS) do
	check(type(TP.Scoring.Awards.DESCRIPTIONS[label]) == "string",
		("award '%s' has a description"):format(label))
end

-- 14a2. Peer-reported defensives: shown when scored, silent otherwise
bulletResult.adjustDetail = { defensives = 2 }
local defBullets = TP.Scoring.Bullets.ForResult(bulletResult, nil, { defensives = 3 })
local defText
for _, b in ipairs(defBullets) do
	if b.kind == "info" then defText = b.text end
end
check(defText == "Used 3 defensive cooldowns (+2)", ("defensive info bullet (%s)"):format(tostring(defText)))
bulletResult.adjustDetail = nil
local zeroDefBullets = TP.Scoring.Bullets.ForResult(bulletResult, nil, { defensives = 0 })
local zeroDefShown = false
for _, b in ipairs(zeroDefBullets) do
	if b.key == "defensives" then
		zeroDefShown = true
	end
end
check(not zeroDefShown, "zero defensives says nothing when the player lived")
-- dying without ever using one is scored now, and red
bulletResult.adjustDetail = { deathNoDefensives = -2 }
local diedDefBullets = TP.Scoring.Bullets.ForResult(bulletResult, nil, { defensives = 0, died = true })
local zeroDefOk = false
for _, b in ipairs(diedDefBullets) do
	if b.kind == "info" and b.text == "Died without using a defensive (-2)" and b.symbol == "-" then
		zeroDefOk = true
	end
end
check(zeroDefOk, "dying without a defensive is scored and red")
bulletResult.adjustDetail = nil
local noDefBullets = TP.Scoring.Bullets.ForResult(bulletResult, nil, nil)
for _, b in ipairs(noDefBullets) do
	check(b.kind ~= "info", "no report -> no defensives bullet")
end

-- consumables and death-readiness: scored lines only
bulletResult.adjustDetail = { prepared = 1, deathReady = -3 }
local consBullets = TP.Scoring.Bullets.ForResult(bulletResult, nil, { consumables = 2, deathReady = 2 })
local consText, readyText
for _, b in ipairs(consBullets) do
	if b.key == "consumables" then consText = b.text end
	if b.key == "deathReady" then readyText = b.text end
end
check(consText == "Came prepared (flask/food up) (+1)", ("prepared bullet (%s)"):format(tostring(consText)))
check(readyText == "Died with 2 defensives ready (-3)", ("death-ready bullet (%s)"):format(tostring(readyText)))
bulletResult.adjustDetail = nil

-- unscored consumable nags are gone (impact-only card); praise still
-- shows because being prepared carries points
local function consBulletFor(role, count, isRetail, ad)
	local res = { role = role, adjustDetail = ad, breakdown = { damage = { applicable = true, normalized = 60, effectiveWeight = 1, value = 100 } }, penaltyDetail = {} }
	for _, b in ipairs(TP.Scoring.Bullets.ForResult(res, nil, { consumables = count, isRetail = isRetail })) do
		if b.key == "consumables" then return b.text end
	end
	return nil
end
check(consBulletFor("DAMAGER", 0, false) == nil, "unscored consumable nag hidden")
check(consBulletFor("HEALER", 2, true, { prepared = 1 }) == "Came prepared (flask/food up) (+1)", "praise is universal")
local exculpBullets = TP.Scoring.Bullets.ForResult(bulletResult, nil, { deathReady = 0 })
local exculpText
for _, b in ipairs(exculpBullets) do
	if b.key == "deathReady" then exculpText = b.text end
end
check(exculpText == nil, "no-impact death context stays off the card")

awardFight.players.d2.metrics.defensives = 3
local wallAwards = TP.Scoring.Awards.Compute(awardFight)
local hasWall = false
if wallAwards.d2 then
	for _, a in ipairs(wallAwards.d2) do
		if a == "Iron Wall" then hasWall = true end
	end
end
check(hasWall, "Iron Wall goes to the top reporter")
awardFight.players.d2.metrics.defensives = nil

-- 14b. Group bullets
local groupBullets = TP.Scoring.Bullets.ForGroup({
	{ breakdown = { damage = { applicable = true, normalized = 80, value = 100 }, interrupts = { applicable = true, normalized = 0, value = 0 } },
		penaltyDetail = { deaths = 10 } },
	{ breakdown = { damage = { applicable = true, normalized = 76, value = 100 }, interrupts = { applicable = true, normalized = 0, value = 0 } },
		penaltyDetail = { deaths = 10 } },
})
check(groupBullets[1].text == "Excellent group damage", "group damage phrase")
-- zero kicks state nothing: without opportunity data we can't know if
-- there was anything to kick, and a scold would misrepresent
local sawKickLine = false
for _, b in ipairs(groupBullets) do
	if b.key == "interrupts" then
		sawKickLine = true
	end
end
check(not sawKickLine, "zero group kicks say nothing (no opportunity data)")
local deathsBullet
for _, b in ipairs(groupBullets) do
	if b.kind == "penalty" and b.key == "deaths" then deathsBullet = b.text end
end
check(deathsBullet :find("^2 players died") ~= nil, ("group deaths phrase (%s)"):format(tostring(deathsBullet)))

-- 15. Threat discipline penalties (Classic-only fields on the fight record)
local threatFight = {
	name = "Threat Test", duration = 60,
	players = {
		t1 = { guid = "t1", name = "Tank", class = "WARRIOR", role = "TANK",
			aggroLostTime = 10, aggroPulled = true, -- tanks pulling is FINE
			metrics = { damage = 100, healing = 0, damageTaken = 500, interrupts = 0, dispels = 0 } },
		d1 = { guid = "d1", name = "Ripper", class = "MAGE", role = "DAMAGER",
			aggroRips = 2, aggroPulled = true,
			metrics = { damage = 400, healing = 0, damageTaken = 50, interrupts = 0, dispels = 0 } },
		d2 = { guid = "d2", name = "Chronic", class = "ROGUE", role = "DAMAGER",
			aggroRips = 10, -- caps at 8, not 25
			metrics = { damage = 300, healing = 0, damageTaken = 40, interrupts = 0, dispels = 0 } },
	},
}
local threatResults = TP.Scoring.Engine.ScoreFight(threatFight)
local byName = {}
for _, r in ipairs(threatResults) do byName[r.name] = r end
check(math.abs(byName.Ripper.penaltyDetail.aggro - 5) < 1e-9, "2 rips cost 5")
check(math.abs(byName.Ripper.penaltyDetail.pull - 5) < 1e-9, "body pull costs 5")
check(math.abs(byName.Chronic.penaltyDetail.aggro - 8) < 1e-9, "rip penalty caps at 8")
check(math.abs(byName.Tank.penaltyDetail.aggroLoss - 4) < 1e-9, "10s of lost aggro costs the tank 4")
check(byName.Tank.penaltyDetail.pull == 0, "tanks never pay for pulling")
check(byName.Tank.penaltyDetail.aggro == 0, "tanks never pay for rips")
check(byName.Ripper.penaltyDetail.aggroLoss == 0, "DPS never pay the tank-loss penalty")

-- threat penalty bullets are human phrases
local threatBullets = TP.Scoring.Bullets.ForResult(byName.Ripper, nil)
local sawPull, sawRip = false, false
for _, b in ipairs(threatBullets) do
	if b.kind == "penalty" and b.key == "pull" then sawPull = (b.text:find("^Pulled before the tank") ~= nil) end
	if b.kind == "penalty" and b.key == "aggro" then sawRip = (b.text:find("^Ripped aggro off the tank") ~= nil) end
end
check(sawPull, "pull penalty bullet phrased")
check(sawRip, "rip penalty bullet phrased")
local groupThreatBullets = TP.Scoring.Bullets.ForGroup(threatResults)
local sawGroupAggro, sawGroupLoss = false, false
for _, b in ipairs(groupThreatBullets) do
	if b.key == "aggro" then sawGroupAggro = (b.text == "2 players pulled aggro") end
	if b.key == "aggroLoss" then sawGroupLoss = true end
end
check(sawGroupAggro, "group aggro phrase counts offenders")
-- one story, not two: the culprit line supersedes the tank-side line
check(not sawGroupLoss, "tank-loss line yields when culprits are named")
local lossOnly = TP.Scoring.Bullets.ForGroup({
	{ role = "TANK", breakdown = {}, penaltyDetail = { aggroLoss = 4 } },
})
local lossLine = false
for _, b in ipairs(lossOnly) do
	if b.key == "aggroLoss" then lossLine = true end
end
check(lossLine, "tank-loss line shows when nobody specific got charged")

-- 16. Role- and fight-type-specific awards
local roleFight = {
	name = "(!) Boss", isBoss = true, duration = 120,
	totals = { deaths = 0, damageTaken = 100000, avoidableTaken = 20000, healing = 100, absorbs = 0, damage = 2000 },
	players = {
		h1 = { guid = "h1", role = "HEALER", minHealthPct = 0.90,
			metrics = { damage = 100, healing = 100, deaths = 0 } },
		t1 = { guid = "t1", role = "TANK", minHealthPct = 0.55,
			metrics = { damage = 800, healing = 0, deaths = 0 } },
		d1 = { guid = "d1", role = "DAMAGER", minHealthPct = 0.75,
			metrics = { damage = 1100, healing = 0, deaths = 0 } },
	},
}
local roleAwards = TP.Scoring.Awards.Compute(roleFight)
local function hasAward(guid, label)
	for _, x in ipairs(roleAwards[guid] or {}) do
		if x == label then return true end
	end
	return false
end
check(hasAward("h1", "Topped Off"), "healer's one award is the rarest earned (Topped Off)")
check(#(roleAwards.h1 or {}) == 1, "one award per player, rarest wins")
check(not hasAward("h1", "Not on My Watch"), "lesser awards absorbed by the rarer one")
check(not hasAward("d1", "Not on My Watch"), "DPS never get healer awards")
check(hasAward("d1", "Giant Slayer"), "top damage on a boss is Giant Slayer")
check(not hasAward("d1", "Lawnmower"), "boss top damage is not Lawnmower")

-- trash variant, a health dip, and a death each kill their award
roleFight.isBoss = false
roleFight.players.t1.minHealthPct = 0.30
roleAwards = TP.Scoring.Awards.Compute(roleFight)
check(hasAward("d1", "Lawnmower"), "top damage on trash is Lawnmower")
check(not hasAward("h1", "Not on My Watch"), "trash pulls never grant Not on My Watch")
roleFight.isBoss = true
roleAwards = TP.Scoring.Awards.Compute(roleFight)
check(not hasAward("h1", "Topped Off"), "a sub-50% dip kills Topped Off")
check(hasAward("h1", "Healed Through Stupid"), "the dip falls back to the next-rarest award")
roleFight.players.t1.minHealthPct = nil -- retail: no health data at all
roleAwards = TP.Scoring.Awards.Compute(roleFight)
check(not hasAward("h1", "Topped Off"), "missing health data never grants Topped Off")
roleFight.totals.deaths = 1
roleAwards = TP.Scoring.Awards.Compute(roleFight)
check(not hasAward("h1", "Not on My Watch"), "a death kills Not on My Watch")
check(not hasAward("h1", "Healed Through Stupid"), "a death kills Healed Through Stupid")
roleFight.wipe = true
roleAwards = TP.Scoring.Awards.Compute(roleFight)
check(not hasAward("d1", "Giant Slayer"), "no damage trophy on a wipe")
roleFight.wipe = nil

-- 17. Wipe-aware death penalties
local wipeFight = {
	name = "(!) Big Boss", isBoss = true, wipe = true, duration = 100,
	players = {
		d1 = { guid = "d1", name = "Dead", class = "MAGE", role = "DAMAGER",
			metrics = { damage = 100, healing = 0, interrupts = 0, dispels = 0, deaths = 1 } },
		d2 = { guid = "d2", name = "AlsoDead", class = "ROGUE", role = "DAMAGER",
			metrics = { damage = 100, healing = 0, interrupts = 0, dispels = 0, deaths = 1 } },
	},
}
local wipeResults = TP.Scoring.Engine.ScoreFight(wipeFight)
check(math.abs(wipeResults[1].penaltyDetail.deaths - 4) < 1e-9,
	("wipe scales a full death penalty 10 -> 4 (%.1f)"):format(wipeResults[1].penaltyDetail.deaths))
wipeFight.wipe = nil
local killResults = TP.Scoring.Engine.ScoreFight(wipeFight)
check(math.abs(killResults[1].penaltyDetail.deaths - 10) < 1e-9, "kill keeps the full death penalty")

-- 18. Parse mode: WCL-style throughput-only lens
local parseFight = {
	name = "Parse Test", duration = 60,
	players = {
		h = { guid = "h", name = "Heals", class = "PRIEST", role = "HEALER",
			metrics = { damage = 100, healing = 900, damageTaken = 0, interrupts = 0, dispels = 2, deaths = 1 } },
		d = { guid = "d", name = "Deeps", class = "MAGE", role = "DAMAGER",
			metrics = { damage = 1000, healing = 50, damageTaken = 0, interrupts = 2, dispels = 0, deaths = 2 } },
	},
}
local parseResults = TP.Scoring.Engine.ScoreFight(parseFight, { mode = "parse", normalizeIlvl = false })
local pByName = {}
for _, r in ipairs(parseResults) do pByName[r.name] = r end
check(pByName.Deeps.penalty == 0, "parse mode ignores deaths")
check(pByName.Deeps.breakdown.interrupts == nil, "parse mode carries no utility metrics")
check(pByName.Deeps.breakdown.damage.applicable, "DPS parse scores damage")
check(pByName.Heals.breakdown.healing.applicable
	and (pByName.Heals.breakdown.healing.effectiveWeight or 0) > 0,
	"healer parse weights healing only")
check(pByName.Heals.breakdown.damage ~= nil
	and (pByName.Heals.breakdown.damage.effectiveWeight or 0) == 0,
	"healer parse still shows damage at zero weight")
local contribResults = TP.Scoring.Engine.ScoreFight(parseFight, { normalizeIlvl = false })
for _, r in ipairs(contribResults) do
	if r.name == "Deeps" then
		check(r.penalty > 0, "contribution mode still penalizes deaths")
		check(r.breakdown.interrupts ~= nil, "contribution mode keeps utility metrics")
	end
end

-- relative fallback in Raw caps at 99: best-in-group is not a 100 parse
local twoDpsFight = {
	name = "No Benchmark Fight", duration = 60,
	players = {
		a = { guid = "a", name = "Best", class = "MAGE", role = "DAMAGER",
			metrics = { damage = 1000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } },
		b = { guid = "b", name = "Rest", class = "ROGUE", role = "DAMAGER",
			metrics = { damage = 500, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } },
	},
}
local twoDps = TP.Scoring.Engine.ScoreFight(twoDpsFight, { mode = "parse", normalizeIlvl = false })
check(twoDps[1].score == 99, ("raw relative fallback caps at 99 (%.0f)"):format(twoDps[1].score))
check(twoDps[1].breakdown.damage.absolute == nil, "fallback carries no absolute (UI marks it ~)")

-- zero kicks on a 1-kick fight: smoothing is forgiving but never "good"
local oneKickFight = {
	name = "One Kick", duration = 60,
	players = {
		a = { guid = "a", name = "Kicker", class = "MAGE", role = "DAMAGER",
			metrics = { damage = 500, healing = 0, interrupts = 1, dispels = 0, deaths = 0 } },
		b = { guid = "b", name = "Watcher", class = "ROGUE", role = "DAMAGER",
			metrics = { damage = 500, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } },
	},
}
local oneKick = TP.Scoring.Engine.ScoreFight(oneKickFight, { normalizeIlvl = false })
local watcher
for _, r in ipairs(oneKick) do
	if r.name == "Watcher" then watcher = r end
end
check(watcher.breakdown.interrupts.normalized <= 55,
	("zero kicks caps in neutral territory (%.0f)"):format(watcher.breakdown.interrupts.normalized))
local watcherBullets = TP.Scoring.Bullets.ForResult(watcher, nil)
for _, b in ipairs(watcherBullets) do
	if b.key == "interrupts" then
		check(b.text == "Did not interrupt", ("zero kicks phrased honestly at any score (%s)"):format(b.text))
	end
end

-- 19. Trivial healing demand: a healer isn't scolded for a fight with
-- nothing to heal (nobody died, nobody dipped below 70%)
local calmFight = {
	name = "Calm Fight", duration = 60,
	players = {
		h = { guid = "h", name = "Heals", class = "PRIEST", role = "HEALER", minHealthPct = 0.85,
			metrics = { damage = 50, healing = 100, damageTaken = 10, interrupts = 0, dispels = 0, deaths = 0 } },
		d = { guid = "d", name = "SelfSust", class = "HUNTER", role = "DAMAGER", minHealthPct = 0.90,
			metrics = { damage = 1000, healing = 400, damageTaken = 10, interrupts = 0, dispels = 0, deaths = 0 } },
	},
}
local calm = TP.Scoring.Engine.ScoreFight(calmFight, { normalizeIlvl = false })
local calmHealer
for _, r in ipairs(calm) do
	if r.name == "Heals" then calmHealer = r end
end
check(calmHealer.breakdown.healing.normalized == 75, ("trivial demand floors healer healing at 75 (%.0f)"):format(calmHealer.breakdown.healing.normalized))
check(calmHealer.breakdown.healing.lowDemand == true, "lowDemand flag set for the UI")
local calmBullets = TP.Scoring.Bullets.ForResult(calmHealer, nil)
local healBulletText
for _, b in ipairs(calmBullets) do
	if b.key == "healing" then healBulletText = b.text end
end
check(healBulletText == "Little healing needed - group stayed topped",
	("neutral phrase replaces 'Low healing' (%s)"):format(tostring(healBulletText)))
-- a death re-arms real grading
calmFight.players.d.metrics.deaths = 1
calm = TP.Scoring.Engine.ScoreFight(calmFight, { normalizeIlvl = false })
for _, r in ipairs(calm) do
	if r.name == "Heals" then
		check(not r.breakdown.healing.lowDemand, "a death disables the demand floor")
	end
end
calmFight.players.d.metrics.deaths = 0
-- a dip alone no longer disables it (a dip healed back IS met demand,
-- 2026-07-15) — UNCOVERED intake does: crank damage taken past what
-- the healing covered
calmFight.players.d.minHealthPct = 0.40
local savedTaken = calmFight.players.d.metrics.damageTaken
calmFight.players.d.metrics.damageTaken = 100000000
calm = TP.Scoring.Engine.ScoreFight(calmFight, { normalizeIlvl = false })
calmFight.players.d.metrics.damageTaken = savedTaken
for _, r in ipairs(calm) do
	if r.name == "Heals" then
		check(not r.breakdown.healing.lowDemand, "uncovered intake disables the demand floor")
	end
end
-- parse mode never floors: a raw parse on a calm fight SHOULD read low
calmFight.players.d.minHealthPct = 0.90
local calmRaw = TP.Scoring.Engine.ScoreFight(calmFight, { mode = "parse", normalizeIlvl = false })
for _, r in ipairs(calmRaw) do
	if r.name == "Heals" then
		check(not r.breakdown.healing.lowDemand, "raw mode keeps honest low parses")
	end
end

-- 18b. Raw mode percentile curves: true WCL-style percentiles when a curve
-- covers the fight+spec
TP.Percentiles = {
	encounters = {
		["Percentile Boss"] = {
			["3x10"] = {
				dps = { [63] = { n = 5000, curve = { { 99, 1000 }, { 95, 900 }, { 90, 800 }, { 75, 650 }, { 50, 500 }, { 25, 380 }, { 10, 300 } } } },
				hps = { [257] = { n = 2000, curve = { { 99, 500 }, { 95, 450 }, { 90, 400 }, { 75, 320 }, { 50, 250 }, { 25, 190 }, { 10, 150 } } } },
			},
			["3x25"] = {
				-- deliberately different: proves bracket selection matters
				dps = { [63] = { n = 5000, curve = { { 99, 2000 }, { 95, 1800 }, { 90, 1600 }, { 75, 1300 }, { 50, 1000 }, { 25, 760 }, { 10, 600 } } } },
				hps = {},
			},
		},
	},
}
local pctFight = {
	name = "(!) Percentile Boss", isBoss = true, duration = 100, difficultyID = 3, -- classic 10N
	players = {
		d = { guid = "d", name = "Deeps", class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 50000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } }, -- 500/s = p50
		d2 = { guid = "d2", name = "Wall", class = "ROGUE", role = "DAMAGER", specID = 259,
			metrics = { damage = 40000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } }, -- no curve for spec
		h = { guid = "h", name = "Heals", class = "PRIEST", role = "HEALER", specID = 257,
			metrics = { damage = 0, healing = 47500, interrupts = 0, dispels = 0, deaths = 0 } }, -- 475/s
	},
}
local pctResults = TP.Scoring.Engine.ScoreFight(pctFight, { mode = "parse", normalizeIlvl = false })
local pctByName = {}
for _, r in ipairs(pctResults) do pctByName[r.name] = r end
check(math.abs(pctByName.Deeps.breakdown.damage.normalized - 50) < 0.001,
	("output at the p50 sample scores exactly 50 (%.1f)"):format(pctByName.Deeps.breakdown.damage.normalized))
check(math.abs(pctByName.Heals.breakdown.healing.normalized - 97) < 0.01,
	("healer percentile interpolates between samples (%.2f)"):format(pctByName.Heals.breakdown.healing.normalized))
pctFight.players.d.metrics.damage = 200000 -- 2000/s, above p99
pctResults = TP.Scoring.Engine.ScoreFight(pctFight, { mode = "parse", normalizeIlvl = false })
for _, r in ipairs(pctResults) do
	if r.name == "Deeps" then
		check(r.breakdown.damage.normalized == 99, "above the p99 sample pins at 99")
	end
end
pctFight.players.d.metrics.damage = 15000 -- 150/s, below p10 (300/s): fades toward 0
pctResults = TP.Scoring.Engine.ScoreFight(pctFight, { mode = "parse", normalizeIlvl = false })
for _, r in ipairs(pctResults) do
	if r.name == "Deeps" then
		check(math.abs(r.breakdown.damage.normalized - 5) < 0.001,
			("below the lowest sample fades linearly (%.1f)"):format(r.breakdown.damage.normalized))
	end
end
-- bracket selection: the same output in the 25-player bracket scores lower
pctFight.difficultyID = 4 -- classic 25N -> the tougher "3x25" curve
pctFight.players.d.metrics.damage = 50000 -- 500/s: p50 in 10N, p10 in 25N... below
pctResults = TP.Scoring.Engine.ScoreFight(pctFight, { mode = "parse", normalizeIlvl = false })
for _, r in ipairs(pctResults) do
	if r.name == "Deeps" then
		check(r.breakdown.damage.normalized < 10,
			("same output in the 25-player bracket scores far lower (%.1f)"):format(r.breakdown.damage.normalized))
	end
end
-- 18c. Widening evidence ladder: a missing bracket zooms out through the
-- WCL data we DO have instead of dropping to a group comparison
pctFight.difficultyID = 5 -- 10H: no curve for this bracket
pctResults = TP.Scoring.Engine.ScoreFight(pctFight, { mode = "parse", normalizeIlvl = false })
for _, r in ipairs(pctResults) do
	if r.name == "Deeps" then
		check(r.breakdown.damage.absolute ~= nil, "missing bracket still curve-scored")
		check(math.abs(r.breakdown.damage.normalized - 50) < 0.001,
			("neighboring 10N bracket supplies the curve (%.1f)"):format(r.breakdown.damage.normalized))
		check(r.breakdown.damage.curveFrom == "spec \194\183 10N",
			("zoomed bracket is named (%s)"):format(tostring(r.breakdown.damage.curveFrom)))
	end
end
-- unknown encounter: the spec's all-boss pool takes over
local mysteryFight = {
	name = "(!) Mystery Boss", isBoss = true, duration = 100, difficultyID = 3,
	players = {
		d = { guid = "d", name = "Deeps", class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 50000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } },
		h = { guid = "h", name = "OffMeta", class = "MONK", role = "HEALER", specID = 270,
			metrics = { damage = 0, healing = 25000, interrupts = 0, dispels = 0, deaths = 0 } },
		t = { guid = "t", name = "Wall", class = "WARRIOR", role = "TANK", specID = 73,
			metrics = { damage = 30000, healing = 0, damageTaken = 900000, interrupts = 0, dispels = 0, deaths = 0 } },
	},
}
-- True mode zooms across encounters (fairness fallback)...
local mystByName = {}
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(mysteryFight, { normalizeIlvl = false })) do
	mystByName[r.name] = r
end
check(mystByName.Deeps.breakdown.damage.curveFrom == "spec \194\183 all bosses"
	and math.abs((mystByName.Deeps.breakdown.damage.pctile or 0) - 50) < 0.001,
	("unknown boss uses the spec's all-boss pool in True (%s, p%.1f)"):format(
		tostring(mystByName.Deeps.breakdown.damage.curveFrom), mystByName.Deeps.breakdown.damage.pctile or -1))
check(mystByName.OffMeta.breakdown.healing.curveFrom == "role \194\183 all bosses"
	and mystByName.OffMeta.breakdown.healing.rolePooled,
	("spec with no hps curve anywhere pools the role (%s)"):format(tostring(mystByName.OffMeta.breakdown.healing.curveFrom)))
-- The "everyone" rung is DELETED (2026-07-13 audit: ±29-49 points of
-- systematic error in both directions — a median healer's hps read p99
-- against it). A role absent from the whole data file now falls back to
-- the honest group comparison, and the tooltip says so.
check(mystByName.Wall.breakdown.damage.curveFrom == nil
	and mystByName.Wall.breakdown.damage.absolute == nil,
	("role with no curves anywhere never gets the everyone pool (%s)"):format(
		tostring(mystByName.Wall.breakdown.damage.curveFrom)))
check(mystByName.Wall.breakdown.damage.relative ~= nil,
	"curve-less role falls back to the group comparison, flagged as such")
check(mystByName.Deeps.breakdown.damage.absolute and mystByName.OffMeta.breakdown.healing.absolute,
	"specs with any pool evidence stay on WCL comparisons")
-- ...but the everyone-pool is PRIMARY-metric only: a healer's damage vs a
-- mostly-DPS population reads p2 where WCL says 92
check(mystByName.OffMeta.breakdown.damage.absolute == nil
	and mystByName.OffMeta.breakdown.damage.curveFrom == nil,
	"healer damage never compares vs the all-players pool")
-- ...and Raw never borrows other bosses' populations: a trivial dungeon
-- healer read F against raid healing demand. No encounter data = no parse.
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(mysteryFight, { mode = "parse", normalizeIlvl = false })) do
	if r.name == "Deeps" then
		check(r.breakdown.damage.absolute == nil,
			"Raw carries no cross-encounter evidence on an unknown boss")
	end
end

-- 18d. Dungeon curves key by DUNGEON name (whole-run M+ rankings) and only
-- apply on ranked difficulties: a Timewalking healer must not be parsed
-- against the M+ population
TP.Percentiles.encounters["Pool Dungeon"] = { ["all"] = {
	dps = { [63] = { n = 800, curve = { { 99, 1000 }, { 95, 900 }, { 90, 800 }, { 75, 650 }, { 50, 500 }, { 25, 380 }, { 10, 300 } } } },
	hps = {},
} }
local dungeonFight = {
	name = "(!) Some Boss", isBoss = true, duration = 100,
	zone = "Pool Dungeon", difficulty = "Mythic Keystone", keystoneLevel = 10,
	players = {
		d = { guid = "d", name = "Deeps", class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 50000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } },
		d2 = { guid = "d2", name = "Deeps2", class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 30000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } },
	},
}
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(dungeonFight, { mode = "parse", normalizeIlvl = false })) do
	if r.name == "Deeps" then
		check(math.abs(r.breakdown.damage.normalized - 50) < 0.001,
			("M+ boss parses against the dungeon's whole-run curve (%.1f)"):format(r.breakdown.damage.normalized))
	end
end
dungeonFight.difficulty = "Timewalking"
dungeonFight.keystoneLevel = nil
dungeonFight.instanceType = "party"
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(dungeonFight, { mode = "parse", normalizeIlvl = false })) do
	if r.name == "Deeps" then
		-- 2026-07-13: normal/heroic/TW dungeons DO parse against the
		-- dungeon curves now, labeled as timed top runs
		check(r.breakdown.damage.absolute ~= nil
			and r.breakdown.damage.curveFrom == "timed top runs",
			("unranked dungeon difficulties parse vs timed top runs (%s)"):format(
				tostring(r.breakdown.damage.curveFrom)))
	end
end
TP.Percentiles.encounters["Pool Dungeon"] = nil

-- 18d2. Punctuation-insensitive encounter matching: WCL says "Chimaerus,
-- the Undreamt God"; the in-game encounter has no comma
TP.Percentiles.encounters["Comma, Boss"] = { ["3x10"] = {
	dps = { [63] = { n = 500, curve = { { 99, 1000 }, { 95, 900 }, { 90, 800 }, { 75, 650 }, { 50, 500 }, { 25, 380 }, { 10, 300 } } } },
	hps = {},
} }
TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles) -- runtime never mutates encounters; tests do
local commaFight = {
	name = "(!) Comma Boss", isBoss = true, duration = 100, difficultyID = 3,
	players = {
		d = { guid = "d", name = "Deeps", class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 50000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } },
	},
}
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(commaFight, { mode = "parse", normalizeIlvl = false })) do
	check(math.abs(r.breakdown.damage.normalized - 50) < 0.001,
		("comma-mismatched boss name still finds its curve (%.1f)"):format(r.breakdown.damage.normalized))
end
TP.Percentiles.encounters["Comma, Boss"] = nil

-- 18d3. encounterID-keyed lookup: a localized client's boss name can't
-- string-match the English WCL keys, but the numeric id resolves via
-- the crawler-emitted TP.Percentiles.ids map
TP.Percentiles.encounters["ID Boss"] = { ["3x10"] = {
	dps = { [63] = { n = 500, curve = { { 99, 1000 }, { 95, 900 }, { 90, 800 }, { 75, 650 }, { 50, 500 }, { 25, 380 }, { 10, 300 } } } },
	hps = {},
} }
TP.Percentiles.ids = { [7777] = "ID Boss" }
TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
local localizedFight = {
	name = "Boss Localisé", isBoss = true, encounterID = 7777,
	duration = 100, difficultyID = 3,
	players = {
		d = { guid = "d", name = "Deeps", class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 50000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } },
	},
}
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(localizedFight, { mode = "parse", normalizeIlvl = false })) do
	check(math.abs(r.breakdown.damage.normalized - 50) < 0.001,
		("localized boss name finds its curve by encounterID (%.1f)"):format(r.breakdown.damage.normalized))
end
TP.Percentiles.encounters["ID Boss"] = nil
TP.Percentiles.ids = nil

-- 18d2b. LFR brackets map: retail difficultyID 17 -> "1", MoP 7 -> "1x25"
TP.Percentiles.encounters["Percentile Boss"]["1"] = {
	dps = { [63] = { n = 700, curve = { { 99, 500 }, { 95, 450 }, { 90, 400 }, { 75, 320 }, { 50, 250 }, { 25, 190 }, { 10, 150 } } } },
	hps = {},
}
local lfrFight = {
	name = "(!) Percentile Boss", isBoss = true, duration = 100, difficultyID = 17,
	players = {
		d = { guid = "d", name = "Deeps", class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 25000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } }, -- 250/s = LFR p50
	},
}
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(lfrFight, { mode = "parse", normalizeIlvl = false })) do
	check(math.abs(r.breakdown.damage.normalized - 50) < 0.001 and r.breakdown.damage.curveFrom == nil,
		("LFR fight parses against the LFR bracket exactly (%.1f)"):format(r.breakdown.damage.normalized))
end
-- 18d2c. Augmentation attribution: an Aug's effective damage (own +
-- buffs enabled) scores against the DPS population, not their tiny
-- personal number. Two top DPS at 400/s each, Aug at 40/s own, 50%
-- Ebon Might uptime: attributed = (40000+40000)*0.5*0.12 = 4800 over
-- 100s = +48/s, effective 88/s. Against the DPS LFR curve that reads a
-- real percentile instead of the group-relative ~p15.
TP.Percentiles.encounters["Percentile Boss"]["1"] = {
	dps = { [63] = { n = 700, curve = { { 99, 500 }, { 95, 450 }, { 90, 400 }, { 75, 320 }, { 50, 250 }, { 25, 190 }, { 10, 150 } } } },
	hps = {},
}
local augFight2 = {
	name = "(!) Percentile Boss", isBoss = true, duration = 100, difficultyID = 17,
	players = {
		a = { guid = "a", name = "Auggy", class = "EVOKER", role = "DAMAGER", specID = 1473,
			specIconID = 5198700,
			metrics = { damage = 4000, healing = 0, buffUptime = 0.5, interrupts = 0, dispels = 0, deaths = 0 } },
		d1 = { guid = "d1", name = "Top1", class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 40000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } },
		d2 = { guid = "d2", name = "Top2", class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 40000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } },
	},
}
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(augFight2, { mode = "parse", normalizeIlvl = false })) do
	if r.name == "Auggy" then
		local b = r.breakdown.damage
		check(b.attribution and math.abs(b.attribution.attributed - 4800) < 1,
			("Aug attribution = top-buffed x uptime x transfer (%s)"):format(tostring(b.attribution and b.attribution.attributed)))
		check(math.abs((b.value or 0) - 8800) < 1, "Aug damage value is effective (own + attributed)")
		-- 88/s on a curve where p10=150: below the sampled floor, but a real
		-- curve percentile, NOT nil (the ~ approximation is gone)
		check(b.absolute ~= nil and b.curveFrom ~= nil,
			("Aug parses against the DPS population, not a group estimate (%s)"):format(tostring(b.curveFrom)))
	end
end
-- with NO buff uptime reported, the Aug falls back to the old behavior
augFight2.players.a.metrics.buffUptime = nil
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(augFight2, { mode = "parse", normalizeIlvl = false })) do
	if r.name == "Auggy" then
		check(r.breakdown.damage.attribution == nil, "no reported uptime = no attribution")
	end
end
-- ...and in True mode the unmeasurable damage pins NEUTRAL instead of
-- dominating the grade with a misleading personal number (the score-6
-- Aug: 72% of the grade rode a proxy we know understates them)
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(augFight2, { normalizeIlvl = false })) do
	if r.name == "Auggy" then
		local b = r.breakdown.damage
		check(b.noInput and b.normalized == 50,
			("missing uptime pins Aug damage neutral (%s, %.0f)"):format(tostring(b.noInput), b.normalized or -1))
		check(r.score >= 35, ("no-input Aug grades neutral, not damning (%.0f)"):format(r.score))
	end
end
augFight2.players.a.metrics.buffUptime = 0.5
TP.Percentiles.encounters["Percentile Boss"]["1"] = nil

-- 18d3. Kill-speed percentile: group duration vs the encounter's ranked
-- kill-time curve (seconds, ascending from fastest). UNCAPPED sample
-- (n < 1000 = WCL served the whole field): the sample percentile is the
-- true percentile.
TP.Percentiles.encounters["Percentile Boss"]["3x10"].killTime = {
	n = 676, curve = { { 99, 60 }, { 95, 80 }, { 90, 100 }, { 75, 140 }, { 50, 200 }, { 25, 280 }, { 10, 400 } },
}
local speedFight = { name = "(!) Percentile Boss", isBoss = true, duration = 200, difficultyID = 3, players = {} }
local pct, n, median = TP.Scoring.Engine.KillSpeedPercentile(speedFight)
check(pct and math.abs(pct - 50) < 0.001 and n == 676 and median == 200,
	("uncapped median-speed kill reads p50 (%s, n=%s)"):format(tostring(pct), tostring(n)))
speedFight.duration = 55
check(TP.Scoring.Engine.KillSpeedPercentile(speedFight) == 99, "faster than the fastest sample pins at 99")
speedFight.duration = 900
check(TP.Scoring.Engine.KillSpeedPercentile(speedFight) == 0, "slower than 2x the slowest reads 0")
speedFight.duration = 200
speedFight.wipe = true
check(TP.Scoring.Engine.KillSpeedPercentile(speedFight) == nil, "wipes carry no speed percentile")
TP.Percentiles.encounters["Percentile Boss"]["3x10"].killTime = nil

-- 18d3b. CAPPED sample (n == 1000 = WCL's fightRankings ceiling): the sample
-- is only the fastest 1000 of a larger field, so the raw sample percentile
-- reads every real kill as bottom-decile. Rescale by the field size
-- estimated from per-spec parse counts (sum dps / raidSize = kills).
TP.Percentiles.encounters["Capped Boss"] = { ["3x10"] = {
	-- 40000 dps parses / 10-player raid = 4000 true kills
	dps = { [63] = { n = 20000, curve = {} }, [64] = { n = 20000, curve = {} } },
	hps = {},
	killTime = { n = 1000, curve = { { 99, 60 }, { 95, 80 }, { 90, 100 }, { 75, 140 }, { 50, 200 }, { 25, 280 }, { 10, 400 } } },
} }
TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
local capFight = { name = "(!) Capped Boss", isBoss = true, duration = 200, difficultyID = 3, players = {} }
-- 200s = sample p50 -> sample rank 500 of 1000 -> true pct = 1 - 500/4000 = 87.5
local cpct, cn, cmed, cbnd = TP.Scoring.Engine.KillSpeedPercentile(capFight)
check(cpct and math.abs(cpct - 87.5) < 0.5 and cn == 4000 and not cbnd,
	("capped sample rescales p50->p87.5 (%s, n=%s)"):format(tostring(cpct), tostring(cn)))
-- slower than the slowest sampled (400s) -> bounded, ceiling = 1 - 1000/4000 = 75
capFight.duration = 500
local bpct, _, _, bbnd = TP.Scoring.Engine.KillSpeedPercentile(capFight)
check(bbnd and bpct and math.abs(bpct - 75) < 0.5,
	("beyond-sample kill is bounded at the field ceiling (%s, bounded=%s)"):format(tostring(bpct), tostring(bbnd)))
-- flex retail bracket (no fixed raid size) capped -> can't rank -> nil
TP.Percentiles.encounters["Capped Boss"]["3"] = {
	dps = { [63] = { n = 20000, curve = {} } }, hps = {},
	killTime = { n = 1000, curve = { { 99, 60 }, { 95, 80 }, { 90, 100 }, { 75, 140 }, { 50, 200 }, { 25, 280 }, { 10, 400 } } },
}
TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
local flexFight = { name = "(!) Capped Boss", isBoss = true, duration = 200, difficultyID = 14, players = {} }
check(TP.Scoring.Engine.KillSpeedPercentile(flexFight) == nil,
	"capped flex-retail bracket (unknown raid size) yields no percentile")
TP.Percentiles.encounters["Capped Boss"] = nil
TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)

-- 18d4. Demand cap: you can't heal damage that never went out. A healer
-- on a trivial fight (per-healer incoming damage below the spec's median
-- output) who covered their share floors at 75 instead of parsing p5
-- against raid-boss healing volumes.
local calmZoom = {
	name = "(!) Tiny Boss", isBoss = true, duration = 100, difficultyID = 3,
	players = {
		h = { guid = "h", name = "Heals", class = "PRIEST", role = "HEALER", specID = 257,
			metrics = { damage = 0, healing = 4500, damageTaken = 2500, interrupts = 0, dispels = 0, deaths = 0 } },
		d = { guid = "d", name = "Deeps", class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 50000, healing = 0, damageTaken = 2500, interrupts = 0, dispels = 0, deaths = 0 } },
	},
}
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(calmZoom, { normalizeIlvl = false })) do
	if r.name == "Heals" then
		check(r.breakdown.healing.lowDemand and r.breakdown.healing.normalized == 75,
			("trivial-demand healer floors at 75 (%.0f, lowDemand=%s)"):format(
				r.breakdown.healing.normalized, tostring(r.breakdown.healing.lowDemand)))
	end
end
calmZoom.players.h.metrics.healing = 1000 -- covered under 70% of their share
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(calmZoom, { normalizeIlvl = false })) do
	if r.name == "Heals" then
		check(not r.breakdown.healing.lowDemand,
			"a healer who did NOT cover the little demand gets no floor")
	end
end
calmZoom.players.h.metrics.healing = 4500
calmZoom.players.d.metrics.deaths = 1
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(calmZoom, { normalizeIlvl = false })) do
	if r.name == "Heals" then
		check(not r.breakdown.healing.lowDemand, "a death disables the demand cap")
	end
end

-- 18e. Run aggregates score through the percentile ladder too: cohort-
-- relative run averages handed the best of each role a structural 100.
-- (Restore the bracket first: 18c left pctFight on 10H, and the ladder
-- now labels neighbor-bracket pools with the borrowed bracket.)
pctFight.difficultyID = 3
local runAgg = TP.Scoring.Runs.Aggregate({ pctFight, pctFight }, "Run")
check(runAgg.isRun and runAgg.difficultyID == pctFight.difficultyID,
	"run aggregate carries isRun and difficulty context")
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(runAgg, { normalizeIlvl = false })) do
	if r.name == "Deeps" then
		check(r.breakdown.damage.absolute ~= nil
			and r.breakdown.damage.curveFrom == "spec \194\183 all bosses",
			("run average scored vs population pools, not the cohort (%s)"):format(
				tostring(r.breakdown.damage.curveFrom)))
	end
end

-- 18f. Bracket correction: borrowing a neighbor bracket's curve rescales
-- the player's rate by the measured population shift (median p50 ratio
-- across specs both brackets cover). Four shared specs at exactly 2x
-- give ratio 0.5 going Heroic -> Normal; a heroic-median performer read
-- on the Normal curve must still land at p50.
do
	local function mk(p50)
		return { n = 500, curve = { { 99, p50 * 2 }, { 95, p50 * 1.8 }, { 90, p50 * 1.6 },
			{ 75, p50 * 1.3 }, { 50, p50 }, { 25, p50 * 0.75 }, { 10, p50 * 0.55 } } }
	end
	TP.Percentiles.encounters["Ratio Boss"] = {
		["3"] = { dps = { [62] = mk(100), [63] = mk(110), [64] = mk(120), [250] = mk(130), [71] = mk(200) }, hps = {} },
		["4"] = { dps = { [62] = mk(200), [63] = mk(220), [64] = mk(240), [250] = mk(260) }, hps = {} },
	}
	TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
	local heroicFight = {
		name = "(!) Ratio Boss", isBoss = true, duration = 100, difficultyID = 15, -- retail Heroic "4"
		players = {
			d = { guid = "d", name = "Deeps", class = "WARRIOR", role = "DAMAGER", specID = 71,
				metrics = { damage = 40000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } }, -- 400/s
		},
	}
	for _, r in ipairs(TP.Scoring.Engine.ScoreFight(heroicFight, { mode = "parse", normalizeIlvl = false })) do
		-- spec 71 has no Heroic curve; its Normal p50 is 200/s and the
		-- measured Normal->Heroic shift is 2x, so 400/s ~ heroic median
		check(r.breakdown.damage.curveFrom == "spec \194\183 Normal",
			("missing-bracket spec borrows the Normal curve (%s)"):format(tostring(r.breakdown.damage.curveFrom)))
		check(math.abs((r.breakdown.damage.pctile or 0) - 50) < 0.001,
			("bracket correction preserves the percentile (p%.1f)"):format(r.breakdown.damage.pctile or -1))
		check(math.abs((r.breakdown.damage.specMedian or 0) - 400) < 0.001,
			("shown median converts back into the fight's bracket (%.0f/s)"):format(r.breakdown.damage.specMedian or -1))
	end
	TP.Percentiles.encounters["Ratio Boss"] = nil
	TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
end

-- True mode uses the curve through the contribution transform: p50 -> 65,
-- standing ALONE (no cohort blend: that re-imports spec bias)
pctFight.difficultyID = 3
pctFight.players.d.metrics.damage = 50000 -- 500/s = the p50 sample
local trueCurve = TP.Scoring.Engine.ScoreFight(pctFight, { normalizeIlvl = false })
for _, r in ipairs(trueCurve) do
	if r.name == "Deeps" then
		check(math.abs(r.breakdown.damage.absolute - 65) < 0.001,
			("True absolute from curve: p50 -> 65 (%.1f)"):format(r.breakdown.damage.absolute))
		check(math.abs(r.breakdown.damage.normalized - 65) < 0.001,
			("curve evidence stands alone, unblended (%.1f)"):format(r.breakdown.damage.normalized))
		check(r.breakdown.damage.relative == nil, "no cohort component when a curve covers the metric")
	end
end

-- Spec throughput profile: the damage+healing budget splits by the spec's
-- population median mix (the "median boomkin heals 5%" rule, literally)
TP.Percentiles.encounters["Percentile Boss"]["3x10"].hps[63] =
	{ n = 1000, curve = { { 99, 60 }, { 95, 55 }, { 90, 50 }, { 75, 40 }, { 50, 25 }, { 25, 15 }, { 10, 10 } } }
-- mage 63: dps p50 = 500, hps p50 = 25 -> mix = 25/525 ~ 4.76% of the
-- DAMAGER budget (now the FULL base: .86 + .14 = 1.0 since count metrics
-- moved to adjustments): healing ~ .0476, damage ~ .9524
local profiled = TP.Scoring.Engine.ScoreFight(pctFight, { normalizeIlvl = false })
for _, r in ipairs(profiled) do
	if r.name == "Deeps" then
		check(math.abs(r.breakdown.damage.weight - 0.9524) < 0.001,
			("spec profile: damage weight from median mix (%.4f)"):format(r.breakdown.damage.weight))
		check(math.abs(r.breakdown.healing.weight - 0.0476) < 0.001,
			("spec profile: healing weight ~5%% of budget (%.4f)"):format(r.breakdown.healing.weight))
	end
end
TP.Percentiles.encounters["Percentile Boss"]["3x10"].hps[63] = nil

-- 20. Virtuoso: top-10% of your spec in the off-category
TP.Percentiles.encounters["Virt Boss"] = { ["3x10"] = {
	dps = { [257] = { n = 500, curve = { { 99, 1000 }, { 95, 900 }, { 90, 800 }, { 75, 650 }, { 50, 500 }, { 25, 380 }, { 10, 300 } } } },
	hps = {},
} }
local virtFight = {
	name = "(!) Virt Boss", isBoss = true, duration = 100, difficultyID = 3,
	totals = { deaths = 1, damageTaken = 1000, healing = 100, absorbs = 0, damage = 85000 },
	players = {
		h = { guid = "h", name = "Zapheal", role = "HEALER", specID = 257, class = "PRIEST",
			metrics = { damage = 85000, healing = 100, deaths = 0 } }, -- 850/s ~ p92 among holy priests
	},
}
local virtAwards = TP.Scoring.Awards.Compute(virtFight)
local hasVirt = false
for _, a in ipairs(virtAwards.h or {}) do
	if a == "Virtuoso" then hasVirt = true end
end
check(hasVirt, "healer parsing p90+ damage earns Virtuoso")
virtFight.players.h.metrics.damage = 60000 -- 600/s ~ p66: good, not virtuoso
virtAwards = TP.Scoring.Awards.Compute(virtFight)
local stillVirt = false
for _, a in ipairs(virtAwards.h or {}) do
	if a == "Virtuoso" then stillVirt = true end
end
check(not stillVirt, "p66 off-category is not Virtuoso")
TP.Percentiles = nil

-- 21. Role-pooled fallback + co-tank soak split
TP.Percentiles = { encounters = { ["Pool Boss"] = { ["3x10"] = {
	dps = {},
	hps = { -- two tank specs with curves; 104 (guardian) has none
		[250] = { n = 300, curve = { { 99, 900 }, { 95, 800 }, { 90, 700 }, { 75, 600 }, { 50, 500 }, { 25, 400 }, { 10, 300 } } },
		[73] = { n = 100, curve = { { 99, 500 }, { 95, 440 }, { 90, 380 }, { 75, 320 }, { 50, 260 }, { 25, 200 }, { 10, 140 } } },
	},
} } } }
local poolFight = {
	name = "(!) Pool Boss", isBoss = true, duration = 100, difficultyID = 3,
	players = {
		t1 = { guid = "t1", name = "Bear", class = "DRUID", role = "TANK", specID = 104,
			metrics = { damage = 100, healing = 44000, damageTaken = 5000, interrupts = 0, dispels = 0, deaths = 0 } },
		t2 = { guid = "t2", name = "Blood", class = "DEATHKNIGHT", role = "TANK", specID = 250,
			metrics = { damage = 100, healing = 50000, damageTaken = 5000, interrupts = 0, dispels = 0, deaths = 0 } },
	},
}
local pool = TP.Scoring.Engine.ScoreFight(poolFight, { normalizeIlvl = false })
local bear, blood
for _, r in ipairs(pool) do
	if r.name == "Bear" then bear = r end
	if r.name == "Blood" then blood = r end
end
-- Bear (no guardian hps curve) scores vs the pooled TANK curve:
-- pooled p50 = (500*300 + 260*100)/400 = 440; 440/s rate = exactly p50 -> 65
check(bear.breakdown.healing.rolePooled == true, "spec without a curve pools to its role")
check(math.abs(bear.breakdown.healing.absolute - 65) < 1.5,
	("pooled tank healing at pooled p50 ~65 (%.1f)"):format(bear.breakdown.healing.absolute))
-- co-tank soak: both split evenly -> both score the same capped-high value,
-- nobody gets a structural 100
check(math.abs(bear.breakdown.damageTaken.normalized - blood.breakdown.damageTaken.normalized) < 0.001,
	"even co-tank soak scores equally")
check(bear.breakdown.damageTaken.normalized < 100, "no structural 100 for the bigger soaker")
TP.Percentiles = nil

-- self-sustain phrasing: mostly-self healing reads as sustain, not off-heals
local sustainResult = { role = "DAMAGER", penaltyDetail = {}, breakdown = {
	healing = { applicable = true, normalized = 80, effectiveWeight = 0.1, value = 500 },
	damage = { applicable = true, normalized = 60, effectiveWeight = 0.9, value = 900 },
} }
local sustainText
for _, b in ipairs(TP.Scoring.Bullets.ForResult(sustainResult, nil, { selfShare = 0.95 })) do
	if b.key == "healing" then sustainText = b.text end
end
check(sustainText == "Excellent self-sustain", ("self-heavy healing phrased as sustain (%s)"):format(tostring(sustainText)))
local offText
for _, b in ipairs(TP.Scoring.Bullets.ForResult(sustainResult, nil, { selfShare = 0.3 })) do
	if b.key == "healing" then offText = b.text end
end
check(offText == "Excellent off-healing", ("outward healing keeps off-healing phrase (%s)"):format(tostring(offText)))
check(groupBullets[1].tooltip and groupBullets[1].tooltip.lines[1][1]:find("2 damage%-role players") ~= nil, "group tooltip carries the numbers")

-- group healing follows the same rules as the healer's own row: the
-- demand cap holds, and a DPS's self-heal percentile never drags the
-- group verdict (real bug: card said Healing struggled at avg 17 while
-- the healer's row said group stayed topped)
local demandGroup = TP.Scoring.Bullets.ForGroup({
	{ role = "HEALER", penaltyDetail = {}, breakdown = {
		healing = { applicable = true, normalized = 75, lowDemand = true, value = 5000 } } },
	{ role = "DAMAGER", penaltyDetail = {}, breakdown = {
		damage = { applicable = true, pctile = 80, normalized = 86, value = 90000 },
		healing = { applicable = true, pctile = 2, normalized = 31, value = 800 } } },
})
local healLine
for _, b in ipairs(demandGroup) do
	if b.key == "healing" then healLine = b end
end
check(healLine and healLine.text == "Little healing needed - group stayed topped",
	("group healing respects the demand cap (%s)"):format(tostring(healLine and healLine.text)))
check(healLine.avg == nil, "demand-capped group healing carries no gauge")

-- Optional: smoke-test against real captured fights from a SavedVariables file
local svPath = arg and arg[1]
if svPath then
	dofile(svPath)
	local fights = TrueParseDB and TrueParseDB.global and TrueParseDB.global.recentFights or {}
	print(("\nScoring %d real captured fights:"):format(#fights))
	for i, realFight in ipairs(fights) do
		local n = 0
		for _ in pairs(realFight.players) do
			n = n + 1
		end
		if (realFight.totals.damage or 0) > 0 and n >= 3 then
			local rs = TP.Scoring.Engine.ScoreFight(realFight)
			local parts = {}
			for _, r in ipairs(rs) do
				parts[#parts + 1] = ("%s(%s)=%.0f"):format(r.name, r.role:sub(1, 1), r.score)
			end
			print(("  %s [%ds]: %s"):format(realFight.name, realFight.duration, table.concat(parts, "  ")))
			for _, r in ipairs(rs) do
				check(r.score >= 0 and r.score <= 100, ("real fight %d score bounds (%s)"):format(i, r.name))
			end
		end
	end
end

-- 20. Base + adjustments (2026-07-13 redesign): the base is the WCL
-- story; everything else nudges it — signed, context-scaled, capped.
local adjFight = {
	name = "(!) Adjust Boss", isBoss = true, duration = 120,
	players = {
		k = { guid = "k", name = "Kicker", class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 50000, healing = 0, interrupts = 6, dispels = 0, deaths = 0,
				avoidableTaken = 0, damageTaken = 10000 } },
		s = { guid = "s", name = "Slacker", class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 50000, healing = 0, interrupts = 0, dispels = 0, deaths = 0,
				avoidableTaken = 30000, damageTaken = 40000 } },
	},
}
local adjByName = {}
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(adjFight, { normalizeIlvl = false })) do
	adjByName[r.name] = r
end
check(math.abs((adjByName.Kicker.adjustDetail.kicks or 0) - 6) < 0.1,
	("kick-heavy fight, every kick: full +6 (%.1f)"):format(adjByName.Kicker.adjustDetail.kicks or 0))
check(math.abs((adjByName.Kicker.adjustDetail.avoidable or 0) - 3) < 0.1,
	("clean under heavy avoidable pressure: +3 (%.1f)"):format(adjByName.Kicker.adjustDetail.avoidable or 0))
check((adjByName.Slacker.adjustDetail.kicks or 0) < -3,
	("kick-capable non-kicker on a kick-heavy fight loses points (%.1f)"):format(adjByName.Slacker.adjustDetail.kicks or 0))
check(math.abs((adjByName.Slacker.adjustDetail.avoidable or 0) + 15) < 0.1,
	("ate the whole group's avoidable: old cap applies (%.1f)"):format(adjByName.Slacker.adjustDetail.avoidable or 0))
check(adjByName.Slacker.adjust == -15, "net adjustment clamps at the total cap")
check(adjByName.Slacker.penaltyDetail.avoidable == 15, "legacy penaltyDetail mirrors the negative side")
check(math.abs(adjByName.Kicker.score - math.min(99, adjByName.Kicker.base + adjByName.Kicker.adjust)) < 0.001,
	"score = clamp(base + net adjustment), 99 ceiling")

-- a 1-kick fight barely moves the needle (Josh: interrupt-heavy fights
-- should swing more; low-kick fights shouldn't)
adjFight.players.k.metrics.interrupts = 1
adjFight.players.s.metrics.avoidableTaken = 0
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(adjFight, { normalizeIlvl = false })) do
	if r.name == "Kicker" then
		check(math.abs(r.adjustDetail.kicks or 0) <= 1.01,
			("1-kick fight: the kick adjustment stays tiny (%.1f)"):format(r.adjustDetail.kicks or 0))
	end
end
adjFight.players.k.metrics.interrupts = 6
adjFight.players.s.metrics.avoidableTaken = 30000

-- addon-reported extras: present nudges, absent stays neutral
adjFight.players.k.metrics.activityPct = 95
adjFight.players.k.metrics.lustCasts = 2
adjFight.players.k.metrics.lustPotion = 1
adjFight.players.s.metrics.lustCasts = 0
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(adjFight, { normalizeIlvl = false })) do
	if r.name == "Kicker" then
		check(math.abs((r.adjustDetail.activity or 0) - 4) < 0.1,
			("p95 activity: +4 (%.1f)"):format(r.adjustDetail.activity or 0))
		check(math.abs((r.adjustDetail.lust or 0) - 3) < 0.1,
			("cooldowns + potion in lust: +3 (%.1f)"):format(r.adjustDetail.lust or 0))
	elseif r.name == "Slacker" then
		check(r.adjustDetail.activity == nil, "no report = neutral, never a penalty")
		check(math.abs((r.adjustDetail.lust or 0) + 3) < 0.1,
			("wasted lust: -3 (%.1f)"):format(r.adjustDetail.lust or 0))
	end
end

-- interrupt OPPORTUNITIES drive intensity when known: one landed kick
-- plus five casts that got through is a kick-heavy fight, and the
-- non-kicker pays accordingly
adjFight.players.k.metrics.interrupts = 1
adjFight.totals = { kickOpportunities = 6, kicksLanded = 1, kicksThrough = 5 }
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(adjFight, { normalizeIlvl = false })) do
	if r.name == "Kicker" then
		check(math.abs(r.adjustDetail.kicks or 0) > 1.01,
			("opportunity data makes a 1-kick fight kick-heavy (%.1f)"):format(r.adjustDetail.kicks or 0))
	end
end
adjFight.totals = nil
adjFight.players.k.metrics.interrupts = 6

-- combat rezzes earn points
adjFight.players.k.metrics.combatRezzes = 1
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(adjFight, { normalizeIlvl = false })) do
	if r.name == "Kicker" then
		check(math.abs((r.adjustDetail.rez or 0) - 2) < 0.1,
			("a combat rez is worth +2 (%.1f)"):format(r.adjustDetail.rez or 0))
	end
end
adjFight.players.k.metrics.combatRezzes = nil

-- cooldown timing consumes the collector fields when present
adjFight.players.k.metrics.lustCasts = nil
adjFight.players.k.metrics.lustPotion = nil
adjFight.players.k.role = "TANK"
adjFight.players.k.specID = 73 -- spec outranks assigned role: must be a tank spec
adjFight.players.k.metrics.spikeCovered = 3
adjFight.players.k.metrics.spikeWindows = 3
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(adjFight, { normalizeIlvl = false })) do
	if r.name == "Kicker" then
		check(math.abs((r.adjustDetail.cdTiming or 0) - 5) < 0.1,
			("tank covered every spike window: +5 (%.1f)"):format(r.adjustDetail.cdTiming or 0))
	end
end
adjFight.players.k.metrics.spikeWindows = 1
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(adjFight, { normalizeIlvl = false })) do
	if r.name == "Kicker" then
		check(r.adjustDetail.cdTiming == nil, "one window is a coin flip, not a pattern: no adjustment")
	end
end
adjFight.players.k.role = "DAMAGER"
adjFight.players.k.specID = 63
adjFight.players.k.metrics.spikeCovered = nil
adjFight.players.k.metrics.spikeWindows = nil

-- Raw mode: pure percentile, zero adjustments, no count metrics
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(adjFight, { mode = "parse", normalizeIlvl = false })) do
	check(r.adjust == 0 and next(r.adjustDetail) == nil, "parse mode takes no adjustments")
	check(r.breakdown.interrupts == nil, "parse breakdown carries no count metrics")
end

-- 21. Danger-window detection (Metrics/Spikes.lua pure math)
if TP.Spikes and TP.Spikes.FindWindows then
	-- 100k HP tank, threshold 45k over 3s: two clear spikes, quiet middle
	local buckets = { [10] = 30000, [11] = 25000, [40] = 20000, [41] = 20000, [42] = 15000 }
	local w = TP.Spikes.FindWindows(buckets, 60, 45000)
	check(#w == 2, ("two separated spikes make two windows (%d)"):format(#w))
	check(w[1][1] <= 10 and w[1][2] >= 11, "first window brackets the burst seconds")
	-- adjacent bursts merge into one sustained window
	local merged = TP.Spikes.FindWindows({ [5] = 50000, [7] = 50000, [9] = 50000 }, 20, 45000)
	check(#merged == 1, ("bursts within the merge gap read as one window (%d)"):format(#merged))
	-- below threshold: nothing
	check(#TP.Spikes.FindWindows({ [5] = 10000 }, 20, 45000) == 0, "quiet fights have no windows")
end

-- 22. Version compare (announcer election)
check(TP.CompareVersions("1.2.10", "1.2.9") == 1, "1.2.10 beats 1.2.9 numerically")
check(TP.CompareVersions("1.2.8", "1.3.0") == -1, "minor beats patch")
check(TP.CompareVersions("1.2.8", "1.2.8") == 0, "equal versions tie")
check(TP.CompareVersions("1.3", "1.2.9") == 1, "short version still compares")

-- 23. Group analysis: the whole vs the sum of the parts
local gaResults = {
	{ role = "DAMAGER", breakdown = { damage = { applicable = true, pctile = 40 } } },
	{ role = "DAMAGER", breakdown = { damage = { applicable = true, pctile = 44 } } },
	{ role = "HEALER", breakdown = { healing = { applicable = true, pctile = 38 } } },
}
local ga = TP.Scoring.Insights.GroupAnalysis(gaResults,
	{ kickOpps = 9, kicksLanded = 7, deaths = 0 }, 70)
check(math.abs(ga.outputPct - (40 + 44 + 38) / 3) < 0.01, "output = mean of role-primary percentiles")
check(ga.executionGap and ga.executionGap > 25, "fast kill + modest parses = positive execution gap")
check(math.abs(ga.kickCoverage - 7 / 9) < 0.001 and ga.flawless, "coverage and flawless carried")
-- demand-floored healers are excluded: their 75 isn't a percentile
local gaLow = TP.Scoring.Insights.GroupAnalysis({
	{ role = "HEALER", breakdown = { healing = { applicable = true, pctile = 5, normalized = 75, lowDemand = true } } },
	{ role = "DAMAGER", breakdown = { damage = { applicable = true, pctile = 60 } } },
}, {}, 65)
check(gaLow.outputN == 1, "demand-floored healer excluded from the parts")
check(gaLow.executionGap == nil, "no gap verdict from a single measured player")

-- 23a2. The ladder never crosses instance types: a Timewalking dungeon
-- with no curves must NOT zoom out to raid pools (live: ilvl-119 TW
-- players read p3 in True while Raw said p99)
do
	local twFight = {
		isBoss = true, name = "Some TW Boss Nobody Ranked", zone = "Unranked TW Dungeon",
		difficultyID = 24, instanceType = "party", duration = 60,
		players = {
			a = { guid = "a", name = "Tw1", class = "ROGUE", role = "DAMAGER", specID = 261,
				metrics = { damage = 300000, healing = 0, damageTaken = 1000, interrupts = 0, dispels = 0, deaths = 0 } },
			b = { guid = "b", name = "Tw2", class = "MAGE", role = "DAMAGER", specID = 63,
				metrics = { damage = 200000, healing = 0, damageTaken = 1000, interrupts = 0, dispels = 0, deaths = 0 } },
		},
		totals = { damage = 500000, healing = 0, damageTaken = 2000, interrupts = 0, dispels = 0, deaths = 0 },
	}
	local twr = TP.Scoring.Engine.ScoreFight(twFight, { normalizeIlvl = false })
	for _, r in ipairs(twr) do
		local b = r.breakdown.damage
		check(b.pctile == nil and b.curveFrom == nil,
			("TW dungeon w/o curves stays group-relative (%s: pct=%s curve=%s)"):format(
				r.name, tostring(b.pctile), tostring(b.curveFrom)))
	end
	check(twr[1].name == "Tw1" and twr[1].score > twr[2].score,
		"group-relative still ranks the higher damage first")
end

-- 23b. Wipe-call detection: output collapse that never recovers marks
-- the moment the raid stopped trying; fought-to-the-end wipes detect
-- nothing and everything counts
if TP.Spikes and TP.Spikes.DetectWipeCall then
	local called = {}
	for t = 0, 59 do called[t] = 100000 end -- honest effort
	for t = 60, 89 do called[t] = (t % 7 == 0) and 4000 or 0 end -- gave up
	local at = TP.Spikes.DetectWipeCall(called, 90)
	check(at and at >= 58 and at <= 68, ("output collapse detected near the call (%s)"):format(tostring(at)))

	local fought = {}
	for t = 0, 89 do fought[t] = 90000 + (t % 10) * 1000 end
	check(TP.Spikes.DetectWipeCall(fought, 90) == nil, "fought-to-the-end wipe detects no call")
	check(TP.Spikes.DetectWipeCall(called, 25) == nil, "too-short fights never detect")
	local blip = {}
	for t = 0, 84 do blip[t] = 100000 end
	for t = 85, 89 do blip[t] = 0 end
	check(TP.Spikes.DetectWipeCall(blip, 90) == nil, "a 5s death-tail is not a called wipe")
end

-- 24. RunAdvice: specific pointers from raw fight records
do
	local advFights = {
		{ totals = { kickOpportunities = 10, kicksLanded = 3, avoidableTaken = 200000, damageTaken = 1000000 },
			players = {
				h = { role = "HEALER", specID = 270, metrics = { dryAt = 12, manaMinPct = 1,
					groupSpikeWindows = 4, groupSpikeCovered = 1 } },
				d = { role = "DAMAGER", specID = 63, deathRecap = { { spell = "Falling Ash", avoidable = true } },
					deathReadyDefensives = 2, metrics = { deaths = 1 } },
			} },
		{ totals = {},
			players = {
				h = { role = "HEALER", specID = 270, metrics = { manaMinPct = 3 } },
			} },
	}
	local tips = TP.Scoring.Insights.RunAdvice(advFights)
	check(#tips >= 4, ("run advice finds the run's stories (%d)"):format(#tips))
	check(tips[1]:find("avoidable damage"), ("deaths-after-avoidable leads (%s)"):format(tostring(tips[1])))
	local sawKicks, sawMana, sawSpikes = false, false, false
	for _, t in ipairs(tips) do
		if t:find("interruptible casts got through") then sawKicks = true end
		if t:find("empty mana in 2 fights") then sawMana = true end
		if t:find("heavy group%-damage moments") then sawSpikes = true end
	end
	check(sawKicks and sawMana and sawSpikes, "kick coverage, mana, and spike pointers all fire")
	check(#TP.Scoring.Insights.RunAdvice({ { totals = {}, players = {} } }) == 0,
		"a clean run gets no scolding")
end

-- weakness picker is role-primary: a card of low DPS off-heals must not
-- flag "healing" while the actual healer parsed fine
do
	local ins = TP.Scoring.Insights.ForResults({
		{ role = "HEALER", penaltyDetail = {}, breakdown = {
			healing = { applicable = true, normalized = 90 } } },
		{ role = "DAMAGER", penaltyDetail = {}, breakdown = {
			damage = { applicable = true, normalized = 70 },
			healing = { applicable = true, normalized = 10 } } },
		{ role = "DAMAGER", penaltyDetail = {}, breakdown = {
			damage = { applicable = true, normalized = 72 },
			healing = { applicable = true, normalized = 5 } } },
	})
	check(ins.weakness ~= "healing", ("off-heal averages never flag healing (%s)"):format(tostring(ins.weakness)))
end

print("")
if failures == 0 then
	print("ALL TESTS PASSED")
else
	print(failures .. " FAILURES")
	os.exit(1)
end
