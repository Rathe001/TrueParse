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
check(augByName.Auggy.breakdown.damage.normalized >= 70,
	("aug damage share ~15%% scores well (%.0f)"):format(augByName.Auggy.breakdown.damage.normalized))
check(augByName.Auggy.score >= 62, ("well-played aug scores well (%.1f)"):format(augByName.Auggy.score))
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
check(math.abs(upAug.breakdown.buffUptime.effectiveWeight - 0.35) < 1e-9,
	"uptime is the biggest SUPPORT weight (35%)")
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
specFight.players.a.specID = 581
specFight.players.b.specID = 64
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
check(untouchableCount == 3, ("everyone who dodged all avoidable damage is Untouchable (%d)"):format(untouchableCount))

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
local insightResults = {
	{ breakdown = { damage = { applicable = true, normalized = 90 }, interrupts = { applicable = true, normalized = 85 },
			healing = { applicable = true, normalized = 40 } },
		penaltyDetail = { deaths = 10 } },
	{ breakdown = { damage = { applicable = true, normalized = 80 }, interrupts = { applicable = true, normalized = 95 },
			-- damageTaken must never surface as a group strength (solo metric)
			damageTaken = { applicable = true, normalized = 100 } },
		penaltyDetail = { deaths = 10, avoidable = 5 } },
	{ breakdown = { damage = { applicable = true, normalized = 70 }, healing = { applicable = true, normalized = 30 } },
		penaltyDetail = { deaths = 10, avoidable = 3, buffs = 2 } },
}
local insights = TP.Scoring.Insights.ForResults(insightResults)
check(insights.strength == "interrupts", ("group strength is interrupts (%s)"):format(tostring(insights.strength)))
check(insights.weakness == "healing", ("group weakness is healing (%s)"):format(tostring(insights.weakness)))
check(insights.deaths == 3, "counts players who died")
check(insights.avoidableHitters == 2, "counts avoidable-damage eaters")
check(insights.buffsMissing == true, "flags missing raid buffs")

-- 14. Bullets: plain-language score explanation, sorted by weight
local bulletResult = {
	breakdown = {
		damage = { applicable = true, normalized = 85, contribution = 46.8, effectiveWeight = 0.55, value = 5000000 },
		healing = { applicable = true, normalized = 20, contribution = 2.0, effectiveWeight = 0.10, value = 50000 },
		interrupts = { applicable = true, normalized = 60, contribution = 15.0, effectiveWeight = 0.25, value = 1 },
		dispels = { applicable = false },
	},
	penaltyDetail = { deaths = 6.5 },
}
bulletResult.role = "DAMAGER"
local bullets = TP.Scoring.Bullets.ForResult(bulletResult, { "Kick King" })
check(#bullets == 5, ("5 bullets: award + 3 metrics + penalty (%d)"):format(#bullets))
check(bullets[1].kind == "award" and bullets[1].text == "Kick King", "award bullet first, gold")
check(bullets[2].text == "Excellent damage" and bullets[2].symbol == "+", "biggest weight first, human phrase, green +")
check(bullets[3].text == "Good interrupting" and bullets[3].symbol == "+", "good tier at 60")
check(bullets[4].text == "Little off-healing" and bullets[4].symbol == "-", "weak DPS healing phrased as off-healing")
check(bullets[5].kind == "penalty" and bullets[5].text == "Died", "penalty bullet human")
bulletResult.breakdown.interrupts.normalized = 0
bulletResult.breakdown.interrupts.value = 0
local zeroBullets = TP.Scoring.Bullets.ForResult(bulletResult, nil)
local kickText
for _, b in ipairs(zeroBullets) do
	if b.key == "interrupts" then kickText = b.text end
end
check(kickText == "Did not interrupt", ("zero kicks phrased plainly (%s)"):format(tostring(kickText)))
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
-- Bloodlust window bullets: DPS-only, informational
local lustResult = { role = "DAMAGER", penaltyDetail = {}, breakdown = {
	damage = { applicable = true, normalized = 60, effectiveWeight = 1, value = 100 },
} }
local function lustText(extra, role)
	lustResult.role = role or "DAMAGER"
	for _, b in ipairs(TP.Scoring.Bullets.ForResult(lustResult, nil, extra)) do
		if b.key == "lust" then return b.text end
	end
end
check(lustText({ lustCasts = 2, lustPotion = 1 }) == "Made the most of Bloodlust (cooldowns + potion)",
	"lust with CDs and potion gets full credit")
check(lustText({ lustCasts = 1, lustPotion = 0 }) == "Used cooldowns during Bloodlust",
	"lust with CDs only gets partial credit")
check(lustText({ lustCasts = 0, lustPotion = 0 }) == "Wasted Bloodlust - no cooldowns used",
	"lust with nothing used is called out")
check(lustText({}) == nil, "no lust this fight, no bullet")
check(lustText({ lustCasts = 0 }, "HEALER") == nil, "healers never get lust bullets")

-- 14a. Every award has a description
for _, label in pairs(TP.Scoring.Awards.LABELS) do
	check(type(TP.Scoring.Awards.DESCRIPTIONS[label]) == "string",
		("award '%s' has a description"):format(label))
end

-- 14a2. Peer-reported defensives: info bullets and the Iron Wall award
local defBullets = TP.Scoring.Bullets.ForResult(bulletResult, nil, { defensives = 3 })
local defText
for _, b in ipairs(defBullets) do
	if b.kind == "info" then defText = b.text end
end
check(defText == "Used 3 defensive cooldowns", ("defensive info bullet (%s)"):format(tostring(defText)))
local zeroDefBullets = TP.Scoring.Bullets.ForResult(bulletResult, nil, { defensives = 0 })
local zeroDefOk = false
for _, b in ipairs(zeroDefBullets) do
	if b.kind == "info" and b.text == "No defensive cooldowns used" and b.symbol ~= "-" then
		zeroDefOk = true
	end
end
check(zeroDefOk, "zero defensives is neutral, not red")
local noDefBullets = TP.Scoring.Bullets.ForResult(bulletResult, nil, nil)
for _, b in ipairs(noDefBullets) do
	check(b.kind ~= "info", "no report -> no defensives bullet")
end

-- consumables and death-readiness info bullets
local consBullets = TP.Scoring.Bullets.ForResult(bulletResult, nil, { consumables = 2, deathReady = 2 })
local consText, readyText
for _, b in ipairs(consBullets) do
	if b.key == "consumables" then consText = b.text end
	if b.key == "deathReady" then readyText = b.text end
end
check(consText == "Came prepared (flask/food up)", ("prepared bullet (%s)"):format(tostring(consText)))
check(readyText == "Died with 2 defensives ready", ("death-ready bullet (%s)"):format(tostring(readyText)))

-- consumable EXPECTATIONS: Classic DPS only; praise is universal
local function consBulletFor(role, count, isRetail)
	local res = { role = role, breakdown = { damage = { applicable = true, normalized = 60, effectiveWeight = 1, value = 100 } }, penaltyDetail = {} }
	for _, b in ipairs(TP.Scoring.Bullets.ForResult(res, nil, { consumables = count, isRetail = isRetail })) do
		if b.key == "consumables" then return b.text end
	end
	return nil
end
check(consBulletFor("DAMAGER", 0, false) == "No consumables at the pull", "Classic DPS still nagged")
check(consBulletFor("HEALER", 0, false) == nil, "Classic healer never nagged about consumables")
check(consBulletFor("TANK", 1, false) == nil, "Classic tank never nagged about consumables")
check(consBulletFor("DAMAGER", 0, true) == nil, "retail killed the pre-pot: nobody nagged")
check(consBulletFor("HEALER", 2, true) == "Came prepared (flask/food up)", "praise is universal")
local exculpBullets = TP.Scoring.Bullets.ForResult(bulletResult, nil, { deathReady = 0 })
local exculpText
for _, b in ipairs(exculpBullets) do
	if b.key == "deathReady" then exculpText = b.text end
end
check(exculpText == "Died with everything on cooldown", "death with no CDs available is exculpatory")

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
check(groupBullets[2].text == "Nobody interrupted", "group zero-kick phrase")
local deathsBullet
for _, b in ipairs(groupBullets) do
	if b.kind == "penalty" and b.key == "deaths" then deathsBullet = b.text end
end
check(deathsBullet == "2 players died", ("group deaths phrase (%s)"):format(tostring(deathsBullet)))

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
	if b.kind == "penalty" and b.key == "pull" then sawPull = (b.text == "Pulled before the tank") end
	if b.kind == "penalty" and b.key == "aggro" then sawRip = (b.text == "Ripped aggro off the tank") end
end
check(sawPull, "pull penalty bullet phrased")
check(sawRip, "rip penalty bullet phrased")
local groupThreatBullets = TP.Scoring.Bullets.ForGroup(threatResults)
local sawGroupAggro, sawGroupLoss = false, false
for _, b in ipairs(groupThreatBullets) do
	if b.key == "aggro" then sawGroupAggro = (b.text == "2 players pulled aggro") end
	if b.key == "aggroLoss" then sawGroupLoss = (b.text == "Aggro slipped off the tank") end
end
check(sawGroupAggro, "group aggro phrase counts offenders")
check(sawGroupLoss, "group tank-loss phrase present")

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
check(hasAward("h1", "Not on My Watch"), "deathless boss grants the healer Not on My Watch")
check(hasAward("h1", "Topped Off"), "nobody under 50% grants Topped Off")
check(hasAward("h1", "Healed Through Stupid"), "heavy avoidable + no deaths grants Healed Through Stupid")
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
check(hasAward("h1", "Not on My Watch"), "the dip still leaves Not on My Watch")
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
-- a sub-70% dip also disables it
calmFight.players.d.minHealthPct = 0.40
calm = TP.Scoring.Engine.ScoreFight(calmFight, { normalizeIlvl = false })
for _, r in ipairs(calm) do
	if r.name == "Heals" then
		check(not r.breakdown.healing.lowDemand, "a health dip disables the demand floor")
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
check(mystByName.Wall.breakdown.damage.curveFrom == "all players",
	("role with no curves at all compares vs everyone (%s)"):format(tostring(mystByName.Wall.breakdown.damage.curveFrom)))
check(mystByName.Deeps.breakdown.damage.absolute and mystByName.OffMeta.breakdown.healing.absolute
	and mystByName.Wall.breakdown.damage.absolute,
	"True never falls back to a group comparison while data is loaded")
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
-- DAMAGER budget (.60 + .10 = .70): healing ~ .0333, damage ~ .6667
local profiled = TP.Scoring.Engine.ScoreFight(pctFight, { normalizeIlvl = false })
for _, r in ipairs(profiled) do
	if r.name == "Deeps" then
		check(math.abs(r.breakdown.damage.weight - 0.6667) < 0.001,
			("spec profile: damage weight from median mix (%.4f)"):format(r.breakdown.damage.weight))
		check(math.abs(r.breakdown.healing.weight - 0.0333) < 0.001,
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
check(groupBullets[1].tooltip and groupBullets[1].tooltip.lines[1][1]:find("2 players") ~= nil, "group tooltip carries the numbers")

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

print("")
if failures == 0 then
	print("ALL TESTS PASSED")
else
	print(failures .. " FAILURES")
	os.exit(1)
end
