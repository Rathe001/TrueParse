-- Headless test runner for the pure-Lua scoring engine.
-- Usage (from the repo root):
--   lua tests/run.lua [optional-path-to-TrueParse-SavedVariables.lua]
-- With an SV path, also scores the captured real fights as a smoke test.

local function loadModule(path, TP)
	local chunk = assert(loadfile(path), "cannot load " .. path)
	chunk("TrueParse", TP)
end

local TP = {}
loadModule("Scoring/Capabilities.lua", TP)
loadModule("Scoring/Weights.lua", TP)
loadModule("Scoring/Engine.lua", TP)
loadModule("Scoring/Grades.lua", TP)
loadModule("Data/Benchmarks.lua", TP)

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
local G = TP.Scoring.Grades
check(#G.ORDER == 16, "16 grade tiers")
check(G.ForScore(0) == "F", "0 -> F")
check(G.ForScore(24.9) == "F", "24.9 -> F")
check(G.ForScore(25) == "D-", "25 -> D-")
check(G.ForScore(49) == "C", "49 -> C")
check(G.ForScore(62) == "B", "62 -> B")
check(G.ForScore(77) == "A", "77 -> A")
check(G.ForScore(80) == "A+", "80 -> A+")
check(G.ForScore(94.9) == "S", "94.9 -> S")
check(G.ForScore(95) == "S+", "95 -> S+")
check(G.ForScore(100) == "S+", "100 -> S+")
do
	local r, gr, b = G.Color("S+")
	check(r and gr and b, "grade color returns rgb")
end

-- 2. Capability gating
local Cap = TP.Scoring.Capabilities
check(not Cap.CanInterrupt("PRIEST", "HEALER"), "priest healer cannot interrupt")
check(not Cap.CanInterrupt("PRIEST", "DAMAGER"), "shadow priest cannot interrupt")
check(not Cap.CanInterrupt("MONK", "HEALER"), "mistweaver cannot interrupt")
check(Cap.CanInterrupt("MONK", "TANK"), "brewmaster can interrupt")
check(Cap.CanInterrupt("SHAMAN", "HEALER"), "resto shaman can interrupt")

-- Synthetic 5-man modeled on observed real shares
local function mkPlayer(guid, name, class, role, m)
	local defaults = {
		damage = 0, healing = 0, absorbs = 0, damageTaken = 0,
		interrupts = 0, dispels = 0, deaths = 0, avoidableTaken = 0,
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
check(byName.Tank.score >= 80, ("well-played tank scores high (%.1f)"):format(byName.Tank.score))
check(byName.Heal.score >= 80, ("well-played healer scores high (%.1f)"):format(byName.Heal.score))

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
check(augByName.Auggy.breakdown.damage.normalized >= 90,
	("aug damage share ~13%% scores high (%.0f)"):format(augByName.Auggy.breakdown.damage.normalized))
check(augByName.Auggy.score >= 70, ("well-played aug scores high (%.1f)"):format(augByName.Auggy.score))
check(augByName.DpsB.breakdown.damage.normalized == 50, "DPS cohort unaffected by aug (B vs A = 50)")

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
