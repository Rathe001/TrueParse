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
loadModule("Data/HealerCDs_Mists.lua", TP) -- RAID_CDS feeds the assignment line
loadModule("Data/TankAnchors_Mists.lua", TP) -- per-spec mit-uptime baselines
loadModule("Scoring/Awards.lua", TP)
loadModule("Scoring/Coach.lua", TP)
loadModule("Scoring/Runs.lua", TP)
loadModule("Scoring/Insights.lua", TP)
loadModule("Scoring/Bullets.lua", TP)
loadModule("Scoring/Signals.lua", TP)
loadModule("Scoring/Reports.lua", TP)
loadModule("Scoring/DeathCause.lua", TP)
loadModule("Metrics/Registry.lua", TP)
loadModule("Metrics/Spikes.lua", TP) -- FindWindows/Compute are pure at capture time

-- Default to the Classic feature set (CLEU present): death counts are
-- authoritative there. Retail-specific tests flip HAS_CLEU locally.
TP.Compat = TP.Compat or { HAS_CLEU = true, IS_RETAIL = false }

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

-- 0. Display helpers
check(TP.ShortName("Beautzibub-Undermine") == "Beautzibub", "ShortName drops the realm")
check(TP.ShortName("Vlora-AltarofStorms") == "Vlora", "ShortName drops a spaced-out realm")
check(TP.ShortName("Nu") == "Nu", "ShortName leaves a bare name alone")
-- names arrive secret/nil often enough that every string helper must survive one
check(TP.ShortName(nil) == nil, "ShortName survives a non-string")

-- 0b. Tooltip doctrine, enforced (Josh 2026-07-28). One concise line;
-- anything that genuinely needs more splits into a larger TL;DR plus a
-- detail line rather than growing into a paragraph. This walks the UI
-- sources because the copy lives in table literals, not behind an API.
;(function()
	local LIMIT = 100
	local long = {}
	for _, path in ipairs({ "UI/BreakdownPanel.lua", "UI/MeterWindow.lua" }) do
		local fh = io.open(path)
		if fh then
			local n = 0
			for line in fh:lines() do
				n = n + 1
				-- tooltip copy only: help tables and AddLine/summary strings.
				-- Skip comments and the empty-state body text, which is prose
				-- in the window itself, not a hover.
				if not line:match("^%s*%-%-") and (line:match("^%s*%w+ = \"")
					or line:match("tooltip = ") or line:match("AddLine%(\"")) then
					for str in line:gmatch('"([^"]*)"') do
						local _, spaces = str:gsub("%s+", "")
						if #str > LIMIT and spaces >= 8 then
							long[#long + 1] = ("%s:%d (%d chars) %s"):format(path, n, #str, str:sub(1, 60))
						end
					end
				end
			end
			fh:close()
		end
	end
	check(#long == 0, ("tooltip copy stays under %d chars (%s)"):format(
		LIMIT, #long == 0 and "all clear" or table.concat(long, " | ")))
end)()

-- 0c. UI/Tooltip.lua against a WoW widget stub (tests/uistub.lua). The
-- scoring engine is pure Lua and always testable; the UI was not, and three
-- separate render bugs shipped to Josh in one day because of it — a SetFont
-- type error, first-hover line overlap, and a frame drawn under its own
-- backdrop. The stub enforces the argument types WoW actually enforces, so
-- those fail here instead of in his combat log.
;(function()
	local ok, failures = pcall(dofile, "tests/tooltip.lua")
	check(ok and failures == 0,
		("tooltip renders against the widget stub (%s)"):format(
			ok and (failures .. " failures") or tostring(failures)))
end)()

-- 0d. Score validation across every scenario (tests/validate.lua): the
-- percentile round trip for damage and healing, the mitigation anchors for
-- tanks, and gear invariance for the derived tiers. Its known-open items
-- (Timewalking's bimodal spread, the unbuildable Celestial fixture) are
-- listed in its own output; this gate only fails on NEW breakage.
;(function()
	local KNOWN = 2 -- see tests/validate.lua's printed problem list
	local ok, count = pcall(dofile, "tests/validate.lua")
	check(ok and type(count) == "number" and count <= KNOWN,
		("score validation finds no new problems (%s)"):format(
			ok and (tostring(count) .. " vs " .. KNOWN .. " known") or tostring(count)))
end)()

-- 1. Every role's weights sum to 1.0
for role, weights in pairs(TP.Scoring.Weights.roleWeights) do
	local sum = 0
	for _, w in pairs(weights) do
		sum = sum + w
	end
	check(math.abs(sum - 1.0) < 1e-9, ("weights sum to 1.0 for %s (got %.4f)"):format(role, sum))
end

-- 1b. Grade mapping: 16 tiers, correct boundaries
-- Score COLORS are WCL parse brackets, straight off the number (Josh
-- 2026-07-28: "the score colors should simply match the same scale WCL
-- uses"). The LETTER ladder is the part that changed: F is reserved for a
-- hard zero and S+ has to be earned past 99, so an ordinary low parse now
-- reads D- instead of failing.
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
	-- the colour is the SCORE's, never the letter's: a 20 is grey whether or
	-- not its letter happens to be a D
	check(select(1, G.ColorForScore(20)) == 0.40, "colour ignores the letter ladder")
	check(G.ColoredScore(87.4):find("87", 1, true) ~= nil, "ColoredScore embeds the rounded number")

	-- letter ladder: F is a hard zero ONLY - the old ladder failed everything
	-- under 25, which is the complaint this fixes
	check(G.LetterFor(0) == "F", "a hard zero is the only F")
	check(G.LetterFor(0.5) == "D-", "a bad parse is a D-, not an F")
	check(G.LetterFor(10) == "D" and G.LetterFor(20) == "D+",
		"low grey parses get real letters")
	check(G.LetterFor(24.9) ~= "F", "nothing under 25 fails any more")
	check(G.LetterFor(50) == "B", "a median score sits mid-ladder (50 -> B)")
	check(G.LetterFor(99) == "S", "99 alone is an S, not an S+")
	check(G.LetterFor(99, 104) == "S+", "S+ needs the unclamped total over 99")
	check(G.LetterFor(99, 99) == "S", "a bare 99 with no bonus stays S")

	-- monotone: more score never means a worse letter
	local prevIdx = -1
	for score = 0, 99 do
		local idx = G.LetterIndex(score)
		check(idx >= prevIdx, ("letter ladder is monotone at %d"):format(score))
		prevIdx = idx
	end

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
-- Skull Bash needs Bear/Cat form: a resto would have to stop healing
-- to kick, which is no assignment at all (Josh 2026-07-23)
check(not Cap.CanInterrupt("DRUID", "HEALER"), "MoP resto druid cannot interrupt")
check(Cap.CanInterrupt("DRUID", "DAMAGER"), "MoP balance druid can interrupt (Solar Beam)")
check(Cap.CanInterrupt("DRUID", "TANK"), "MoP guardian can interrupt (Skull Bash)")
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
			{ damage = 600000, healing = 80000, damageTaken = 500000, interrupts = 2, mitigationPct = 50 }),
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
check(byName.DpsB.penaltyDetail.avoidable == 9, "avoidable penalty capped at 9")
check(byName.DpsB.penaltyDetail.deaths == 10, "one death costs 10")

-- 6. Cross-role fairness (Josh 2026-07-26): a tank's PRIMARY metric is
-- survival - active-mitigation UPTIME scored vs the spec's WCL field - not
-- damage. The old soak-share metric is gone; tanking leads at 55%.
check(byName.Tank.breakdown.damageTaken == nil,
	"soak share is no longer a scored tank metric")
check(byName.Tank.breakdown.mitigation and byName.Tank.breakdown.mitigation.applicable,
	"tank's mitigation uptime is the scored Tanking metric")
check(math.abs((byName.Tank.breakdown.mitigation.effectiveWeight or 0) - 0.55) < 1e-9,
	("tanking is the tank's biggest weight, 55%% (%.2f)"):format(byName.Tank.breakdown.mitigation.effectiveWeight or 0))
check(byName.Tank.score >= 40, ("well-played tank still competes (%.1f)"):format(byName.Tank.score))
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
check(augByName.Auggy.breakdown.prescience and not augByName.Auggy.breakdown.prescience.applicable,
	"no self-reported prescience -> inapplicable, weight redistributes")

-- 6b2. Prescience cadence is the SUPPORT-defining metric now (Ebon Might is
-- attribution-only, folded into Amplified). Duration is 60s so casts equal
-- casts/min; the anchor is 5 casts/min for a full score.
augFight.players.aug.metrics.prescience = 5 -- exactly the anchor
local upResults = TP.Scoring.Engine.ScoreFight(augFight)
local upAug
for _, r in ipairs(upResults) do
	if r.name == "Auggy" then upAug = r end
end
check(upAug.breakdown.prescience.applicable, "reported prescience is scored")
check(upAug.breakdown.prescience.normalized == 100, "5 casts/min hits the anchor: 100")
check(math.abs(upAug.breakdown.prescience.effectiveWeight - 0.50) < 1e-9,
	"prescience is the biggest SUPPORT weight (50% of the base)")
check(upAug.score > augByName.Auggy.score, "a high-cadence aug outscores the no-data version")
augFight.players.aug.metrics.prescience = 3
local halfResults = TP.Scoring.Engine.ScoreFight(augFight)
for _, r in ipairs(halfResults) do
	if r.name == "Auggy" then
		check(r.breakdown.prescience.normalized == 60, "3 casts/min scores 60")
	end
end
check(TP.Scoring.Weights.roleWeights.DAMAGER.prescience == nil, "non-support roles never score prescience")
augFight.players.aug.metrics.prescience = nil

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
-- avoidableCap dropped to 9, so the DEATH (10) is now the larger loss here
-- and the coach leads with it. Ranking is by cost, which is the point.
check(advice ~= nil and advice.kind == "deaths",
	("coach leads with the biggest loss (%s)"):format(tostring(advice and advice.kind)))
local adviceA = TP.Scoring.Coach.BiggestOpportunity(coachByName.DpsA)
check(adviceA == nil or adviceA.kind == "throughput", "clean player gets throughput advice or none")

-- 9b. Coach.Advise: specific, actionable text; ranked + long fights only.
-- Wrapped in an IIFE so its locals don't count against the main chunk's
-- 200-local ceiling (same pattern as the file's other sections).
;(function()
	local function advResult(role, adjustDetail, pctile)
		return {
			role = role,
			adjustDetail = adjustDetail,
			breakdown = { [role == "HEALER" and "healing" or "damage"] =
				{ applicable = true, pctile = pctile, normalized = pctile, effectiveWeight = 1 } },
		}
	end
	local rankedFight, shortFight = { duration = 200 }, { duration = 60 }
	local advPlayer = { metrics = { avoidableTaken = 340000, damageTaken = 1000000, activityPct = 55 } }
	local av = TP.Scoring.Coach.Advise(advResult("DAMAGER", { avoidable = -15, activity = -4 }, 70), rankedFight, advPlayer)
	check(av and av.kind == "avoidable" and av.text:find("avoidable"), "advise leads with the biggest mistake (avoidable)")
	check(av and av.text:find("34"), "advise quantifies the avoidable share")
	check(TP.Scoring.Coach.Advise(advResult("DAMAGER", { avoidable = -15 }, 70), shortFight, advPlayer) == nil,
		"no coaching on fights under 90s (too little signal)")
	check(TP.Scoring.Coach.Advise(advResult("DAMAGER", { avoidable = -15 }, nil), rankedFight, advPlayer) == nil,
		"no coaching on unranked content (Celestial/Timewalking have no pctile)")
	local act = TP.Scoring.Coach.Advise(advResult("DAMAGER", { activity = -6, overkill = -2 }, 70), rankedFight, advPlayer)
	check(act and act.kind == "activity" and act.text:find("55"), "advise coaches downtime with the active percent")
	local dh = TP.Scoring.Coach.Advise(advResult("DAMAGER", { deaths = -10 }, 70), rankedFight, { metrics = {} })
	check(dh and dh.kind == "deaths", "advise coaches staying alive when deaths dominate")
	local tpAdv = TP.Scoring.Coach.Advise(advResult("DAMAGER", {}, 20), rankedFight, { metrics = {} })
	check(tpAdv and tpAdv.kind == "throughput", "clean ranked player falls to throughput coaching")

	-- throughput coaches the ROLE's primary metric only (Josh 2026-07-26: a
	-- 99 healing parse was told "your damage has room to grow")
	local topHealer = { role = "HEALER", adjustDetail = {}, breakdown = {
		healing = { applicable = true, pctile = 99, normalized = 99, effectiveWeight = 0.75 },
		damage = { applicable = true, pctile = 37, normalized = 37, effectiveWeight = 0.10 } } }
	check(TP.Scoring.Coach.Advise(topHealer, rankedFight, { metrics = {} }) == nil,
		"a topped-out healer is never coached to pad damage")
	local lowHealer = { role = "HEALER", adjustDetail = {}, breakdown = {
		healing = { applicable = true, pctile = 40, normalized = 40, effectiveWeight = 0.75 },
		damage = { applicable = true, pctile = 90, normalized = 90, effectiveWeight = 0.10 } } }
	local lh = TP.Scoring.Coach.Advise(lowHealer, rankedFight, { metrics = {} })
	check(lh and lh.kind == "throughput" and lh.text:find("healing"), "a low healer is coached on healing, not damage")

	-- throughput only fires BELOW the median parse (Josh 2026-07-26: a 93
	-- damage parse and an 86 healing parse were told "tighten the rotation")
	check(TP.Scoring.Coach.Advise(advResult("DAMAGER", {}, 93), rankedFight, { metrics = {} }) == nil,
		"a 93 damage parse gets no rotation nag")
	local hiHealer = { role = "HEALER", adjustDetail = {}, breakdown = {
		healing = { applicable = true, pctile = 86, normalized = 86, effectiveWeight = 0.79 } } }
	check(TP.Scoring.Coach.Advise(hiHealer, rankedFight, { metrics = {} }) == nil,
		"an 86 healing parse gets no rotation nag")
	local midDps = TP.Scoring.Coach.Advise(advResult("DAMAGER", {}, 45), rankedFight, { metrics = {} })
	check(midDps and midDps.kind == "throughput", "a below-median parse still gets rotation coaching")

	-- phrasing is deterministic per player+fight but varies between players
	-- (Josh 2026-07-26: the coach shouldn't read the same on every card)
	local res = advResult("DAMAGER", { avoidable = -15 }, 70)
	local nf = { name = "Some Boss", duration = 200 }
	local p1 = { guid = "aaa", metrics = { avoidableTaken = 340000, damageTaken = 1000000 } }
	check(TP.Scoring.Coach.Advise(res, nf, p1).text == TP.Scoring.Coach.Advise(res, nf, p1).text,
		"same player+fight always reads the same")
	local seen = {}
	for i = 1, 12 do
		local p = { guid = "player" .. i, metrics = { avoidableTaken = 340000, damageTaken = 1000000 } }
		seen[TP.Scoring.Coach.Advise(res, nf, p).text] = true
	end
	local variants = 0
	for _ in pairs(seen) do variants = variants + 1 end
	check(variants >= 2, ("coach phrasing varies between players (%d distinct)"):format(variants))
end)()

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
check(run.startedAt == 70, ("run clock = earliest pull start (%s)"):format(tostring(run.startedAt)))
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
	adjustDetail = { buffs = -4 }, breakdown = {},
})
check(buffAdvice and buffAdvice.kind == "buffs", "coach flags buff coverage")

-- 12b. Flask + food: +1 for both up, -1 per one missing, neutral when the
-- count was never reported (Josh 2026-07-26)
local prepFight = { name = "Prep", duration = 60, players = {
	both = mkPlayer("both", "Both", "MAGE", "DAMAGER", { damage = 1000000, consumables = 2 }),
	one = mkPlayer("one", "One", "MAGE", "DAMAGER", { damage = 1000000, consumables = 1 }),
	none = mkPlayer("none", "None", "MAGE", "DAMAGER", { damage = 1000000, consumables = 0 }),
	unk = mkPlayer("unk", "Unk", "MAGE", "DAMAGER", { damage = 1000000 }),
} }
local prepBy = {}
for _, r in ipairs(TP.Scoring.Engine.ScoreFight(prepFight, { normalizeIlvl = false })) do
	prepBy[r.name] = r
end
check((prepBy.Both.adjustDetail.prepared or 0) == 1, "both flask + food earns +1")
check((prepBy.One.adjustDetail.prepared or 0) == -1, "one consumable short costs -1")
check((prepBy.None.adjustDetail.prepared or 0) == -2, "no flask/food costs -2")
check(prepBy.Unk.adjustDetail.prepared == nil, "unreported consumables stay neutral")

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
-- mitigation reports through the Tanking composite now (2026-07-25):
-- no standalone bullet, even when the metric is present
check(infoText({ mitigationPct = 82 }, "TANK", "mitigation", { mitigation = 4 }) == nil,
	"mitigation has no standalone bullet")

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

-- flask + food scores both ways for everyone now (Josh 2026-07-26): praise
-- for both up, a penalty for each one missing, any role or client
local function consBulletFor(role, count, isRetail, ad)
	local res = { role = role, adjustDetail = ad, breakdown = { damage = { applicable = true, normalized = 60, effectiveWeight = 1, value = 100 } }, penaltyDetail = {} }
	for _, b in ipairs(TP.Scoring.Bullets.ForResult(res, nil, { consumables = count, isRetail = isRetail })) do
		if b.key == "consumables" then return b.text end
	end
	return nil
end
check(consBulletFor("DAMAGER", 0, false, { prepared = -2 }) == "No flask or food at the pull (-2)",
	"missing both flask and food nags with the -2")
check(consBulletFor("HEALER", 1, true, { prepared = -1 }) == "Flask or food missing (-1)",
	"one short costs -1 for any role or client")
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
-- 18d1b. DERIVED TIERS (Josh 2026-07-28). Off-difficulty and unranked
-- content used to fall through to a group comparison, where the room's best
-- is a 99 by definition. Now the shipped curves are reused as a derived
-- comparison, gear- and difficulty-scaled.
;(function()
	local Engine = TP.Scoring.Engine
	local W = TP.Scoring.Weights
	Engine.InvalidateNameIndex(TP.Percentiles)
	-- refIlvl resolves from Benchmarks; pin the knobs so the assertions
	-- don't move when the constants are retuned
	local savedCap, savedOff, savedRef = W.derivedIlvlCap, W.derivedOffDifficulty, W.derivedRefIlvl
	W.derivedIlvlCap, W.derivedOffDifficulty = 90, 1.4
	TP.Percentiles.refIlvl = 300 -- explicit: the data file's own statement wins

	local function mk(over)
		local f = {
			name = "(!) Some Boss", isBoss = true, duration = 100,
			zone = "Pool Dungeon", instanceType = "party",
			players = {
				d = { guid = "d", name = "Deeps", class = "MAGE", role = "DAMAGER",
					specID = 63, ilvl = 200,
					metrics = { damage = 20000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } },
				d2 = { guid = "d2", name = "Deeps2", class = "MAGE", role = "DAMAGER",
					specID = 63, ilvl = 200,
					metrics = { damage = 10000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } },
			},
		}
		for k, v in pairs(over or {}) do f[k] = v end
		return f
	end
	local function deeps(f, opts)
		for _, r in ipairs(Engine.ScoreFight(f, opts or { normalizeIlvl = false })) do
			if r.name == "Deeps" then return r end
		end
	end

	TP.Percentiles.encounters["Pool Dungeon"] = { ["all"] = {
		dps = { [63] = { n = 800, curve = { { 99, 1000 }, { 95, 900 }, { 90, 800 },
			{ 75, 650 }, { 50, 500 }, { 25, 380 }, { 10, 300 } } } },
		hps = {},
	} }

	-- T1: ANY M+ key compares 1:1 against the dungeon's curve (Josh chose the
	-- BRACKET, not per-key), so no derived flag and no scaling.
	local t1 = deeps(mk({ difficulty = "Mythic Keystone", keystoneLevel = 10 }))
	check(t1.derived == nil, "M+ at any key level is a DIRECT comparison (tier 1)")
	check(math.abs(t1.breakdown.damage.pctile
		- Engine.EntryPercentileFor(TP.Percentiles.encounters["Pool Dungeon"].all.dps[63], 200)) < 0.001,
		("T1 reads the curve unscaled - 200/s straight in (%.1f)"):format(t1.breakdown.damage.pctile))

	-- T2: same dungeon on Normal. The curve exists but the difficulty was
	-- never ranked, so the rate is scaled into the population's terms.
	local t2 = deeps(mk({ difficulty = "Normal", difficultyID = 1 }))
	check(t2.derived == 2, ("off-difficulty dungeon is derived tier 2 (%s)"):format(tostring(t2.derived)))
	check(t2.breakdown.damage.derived == 2, "the breakdown entry carries the tier for the UI")
	check(t2.breakdown.damage.pctile > t1.breakdown.damage.pctile,
		("T2 scales the rate UP toward the ranked population (%.1f > %.1f)"):format(
			t2.breakdown.damage.pctile, t1.breakdown.damage.pctile))
	-- The reference population is an implementation detail (it moved from
	-- this dungeon's own curves to the pooled raid curves once dungeon
	-- curves proved too flat to scale against - median p99/p50 1.25). What
	-- must hold is the CONTRACT: a bigger gear gap scales you further up.
	local nearer = deeps(mk({ difficulty = "Normal", difficultyID = 1,
		players = { d = { guid = "d", name = "Deeps", class = "MAGE", role = "DAMAGER",
			specID = 63, ilvl = 290,
			metrics = { damage = 20000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } } } }))
	check(t2.breakdown.damage.pctile > nearer.breakdown.damage.pctile,
		("a wider gear gap scales further up (%.1f at ilvl 200 > %.1f at ilvl 290)"):format(
			t2.breakdown.damage.pctile, nearer.breakdown.damage.pctile))
	-- the median shown is converted back into the player's own gear terms
	check(t2.breakdown.damage.specMedian < 500,
		("derived median is restated at the player's item level (%.0f)"):format(
			t2.breakdown.damage.specMedian))

	-- The cap bounds how far the gear extrapolation can carry a player up
	-- the curve. Asserted on the OBSERVABLE contract - a tighter cap must
	-- never score higher - across a range of rates, rather than on one
	-- synthetic fixture whose reference population has moved twice.
	local savedCeiling = W.derivedCeiling
	W.derivedCeiling = nil -- the ceiling clamps both sides and hides the cap
	local function atCap(rate, cap)
		W.derivedIlvlCap = cap
		local r = deeps(mk({ difficulty = "Normal", difficultyID = 1,
			players = { d = { guid = "d", name = "Deeps", class = "MAGE",
				role = "DAMAGER", specID = 63, ilvl = 120,
				metrics = { damage = rate * 100, healing = 0, interrupts = 0,
					dispels = 0, deaths = 0 } } } }))
		return r.breakdown.damage.pctile or 0
	end
	local capMonotone, capBinds = true, false
	for _, rate in ipairs({ 50, 200, 500, 1200, 2500 }) do
		local tight, loose = atCap(rate, 20), atCap(rate, 10000)
		if tight > loose + 0.01 then capMonotone = false end
		if loose > tight + 10 then capBinds = true end
	end
	check(capMonotone, "a tighter ilvl cap never scores higher")
	check(capBinds, "the cap actually binds - uncapped runs away up the curve")
	W.derivedCeiling = savedCeiling
	W.derivedIlvlCap = 90
	W.derivedIlvlCap = 90
	-- T3: a dungeon with NO curves of its own falls back to the pooled
	-- average of every dungeon-keyed encounter we ship.
	local t3 = deeps(mk({ zone = "Unranked Dungeon", difficulty = "Timewalking", difficultyID = 24 }))
	check(t3.derived == 3, ("unranked content is derived tier 3 (%s)"):format(tostring(t3.derived)))
	check(t3.breakdown.damage.pctile ~= nil, "T3 scores against a real curve, not the group")

	-- Raw is NOT derived: a parse means a parse. T3 keeps the old
	-- group-relative approximation, but still reports the tier so the panel
	-- can disable the lens.
	local raw3 = deeps(mk({ zone = "Unranked Dungeon", difficulty = "Timewalking", difficultyID = 24 }),
		{ mode = "parse", normalizeIlvl = false })
	check(raw3.derived == 3, "Raw still reports the tier (the UI disables the lens off it)")
	check(raw3.breakdown.damage.pctile == nil,
		"Raw never borrows the derived pool - there is no parse to show")

	-- A client with NO dungeon-keyed data at all (MoP Classic ships SoO raid
	-- curves only, so Celestial dungeons had nothing) pools the RAID curves
	-- rather than giving up — Josh 2026-07-28.
	local savedDungeon = TP.Percentiles.encounters["Pool Dungeon"]
	TP.Percentiles.encounters["Pool Dungeon"] = nil
	Engine.InvalidateNameIndex(TP.Percentiles)
	local raidOnly = deeps(mk({ zone = "Unranked Dungeon", difficulty = "Timewalking", difficultyID = 24 }))
	check(raidOnly.derived == 3 and raidOnly.breakdown.damage.pctile ~= nil,
		"no dungeon data anywhere: tier 3 pools the raid curves instead")
	TP.Percentiles.encounters["Pool Dungeon"] = savedDungeon

	TP.Percentiles.encounters["Pool Dungeon"] = nil
	TP.Percentiles.refIlvl = nil
	W.derivedIlvlCap, W.derivedOffDifficulty, W.derivedRefIlvl = savedCap, savedOff, savedRef
	Engine.InvalidateNameIndex(TP.Percentiles)
end)()

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
-- reads every real kill as bottom-decile. Rescale by the TRUE field size
-- crawled from report rankings (killTime.total); without it, nothing honest
-- can be said, so the percentile is suppressed entirely.
TP.Percentiles.encounters["Capped Boss"] = { ["3x10"] = {
	dps = {}, hps = {},
	killTime = { n = 1000, total = 4000, curve = { { 99, 60 }, { 95, 80 }, { 90, 100 }, { 75, 140 }, { 50, 200 }, { 25, 280 }, { 10, 400 } } },
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
-- capped bracket with NO crawled total: suppressed (the old parse-count
-- estimator overestimated the field ~3x — validated against WCL 2026-07-22)
TP.Percentiles.encounters["Capped Boss"]["3x10"].killTime.total = nil
capFight.duration = 200
check(TP.Scoring.Engine.KillSpeedPercentile(capFight) == nil,
	"capped bracket without a crawled total yields no percentile")
TP.Percentiles.encounters["Capped Boss"] = nil
TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)

-- 18d3c. Capped THROUGHPUT curves rescale the same way: characterRankings
-- serves at most 2000 chars per spec, so a popular spec's curve is the
-- population's top slice and plain interpolation under-rates mid-pack
-- players (Elemental read 10-27 points under WCL's own rankPercents).
;(function()
	local entry = {
		n = 2000, total = 4000,
		curve = { { 99, 400 }, { 95, 350 }, { 90, 320 }, { 75, 280 }, { 50, 240 }, { 25, 200 }, { 10, 160 } },
	}
	-- sample p50 (240/s) = in-sample rank 1000 of 4000 true chars -> p75
	local p = TP.Scoring.Engine.EntryPercentileFor(entry, 240)
	check(math.abs(p - 75) < 0.5, ("capped spec curve rescales p50->p75 (%s)"):format(tostring(p)))
	-- below the sampled tail only a ceiling is known: anchor the fade there
	-- (ceiling = 1 - 0.9*2000/4000 = 55; half the tail value reads 27.5)
	local q = TP.Scoring.Engine.EntryPercentileFor(entry, 80)
	check(math.abs(q - 27.5) < 0.5, ("below-tail fade anchors at the ceiling (%s)"):format(tostring(q)))
	-- top of the sample can't exceed WCL's no-100 convention
	check(TP.Scoring.Engine.EntryPercentileFor(entry, 500) == 99, "rescaled top still pins at 99")
	-- without a crawled total the plain interpolation stands (status quo)
	local plain = TP.Scoring.Engine.EntryPercentileFor({ n = 2000, curve = entry.curve }, 240)
	check(math.abs(plain - 50) < 0.5, ("uncrawled capped curve keeps sample percentile (%s)"):format(tostring(plain)))
end)()

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

-- True mode's base IS the percentile (2026-07-25: floor/slope neutral),
-- standing ALONE (no cohort blend: that re-imports spec bias)
pctFight.difficultyID = 3
pctFight.players.d.metrics.damage = 50000 -- 500/s = the p50 sample
local trueCurve = TP.Scoring.Engine.ScoreFight(pctFight, { normalizeIlvl = false })
for _, r in ipairs(trueCurve) do
	if r.name == "Deeps" then
		check(math.abs(r.breakdown.damage.absolute - 50) < 0.001,
			("True absolute from curve: p50 -> 50 (%.1f)"):format(r.breakdown.damage.absolute))
		check(math.abs(r.breakdown.damage.normalized - 50) < 0.001,
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
-- pooled p50 = (500*300 + 260*100)/400 = 440; 440/s rate = exactly p50 -> 50
check(bear.breakdown.healing.rolePooled == true, "spec without a curve pools to its role")
check(math.abs(bear.breakdown.healing.absolute - 50) < 1.5,
	("pooled tank healing at pooled p50 ~50 (%.1f)"):format(bear.breakdown.healing.absolute))
-- (the co-tank soak-share test retired 2026-07-26: soak is no longer a
-- scored metric - the Tanking metric is mitigation uptime vs WCL)
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
check(groupBullets[1].tooltip and groupBullets[1].tooltip.lines[1][1]:find("2 damage players") ~= nil, "group tooltip carries the numbers")

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
check(math.abs((adjByName.Slacker.adjustDetail.avoidable or 0) + 9) < 0.1,
	("ate the whole group's avoidable: its own cap applies (%.1f)"):format(adjByName.Slacker.adjustDetail.avoidable or 0))
-- one mistake no longer spends the whole budget: -9 of the -15 total
check(adjByName.Slacker.adjust > -15,
	("one metric alone cannot max the total cap (%.1f)"):format(adjByName.Slacker.adjust))
check(adjByName.Slacker.penaltyDetail.avoidable == 9, "legacy penaltyDetail mirrors the negative side")
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

	-- 23a3. CONTEXTLESS fights stay off the ladder too (Josh 2026-07-25:
	-- a bulk-unlocked TW run lost its instance context entirely — no
	-- difficultyID, no instanceType — read as "not a dungeon", and the
	-- level-scaled mage laddered into max-level raid pools at p9)
	local lost = {
		isBoss = true, name = "Some TW Boss Nobody Ranked", zone = "Eastern Kingdoms",
		duration = 60,
		players = {
			a = { guid = "a", name = "Lost1", class = "MAGE", role = "DAMAGER", specID = 63,
				metrics = { damage = 200000, healing = 0, damageTaken = 1000, interrupts = 0, dispels = 0, deaths = 0 } },
		},
		totals = { damage = 200000, healing = 0, damageTaken = 1000, interrupts = 0, dispels = 0, deaths = 0 },
	}
	local lr = TP.Scoring.Engine.ScoreFight(lost, { normalizeIlvl = false })
	check(lr[1] and lr[1].breakdown.damage.pctile == nil and lr[1].breakdown.damage.curveFrom == nil,
		("no curves + no bracket = no ladder (pct=%s curve=%s)"):format(
			tostring(lr[1] and lr[1].breakdown.damage.pctile),
			tostring(lr[1] and lr[1].breakdown.damage.curveFrom)))
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

-- 25. Whole-fight context gates (audit 2026-07-18): adjustments must not
-- judge windows the player couldn't act in or behavior a wipe call excuses
-- (IIFE: the main chunk is at Lua's 200-local ceiling)
;(function()
	local function ctxFight(over)
		local f = {
			name = "Context Boss", isBoss = true, duration = 300,
			players = {},
		}
		for k, v in pairs(over or {}) do
			f[k] = v
		end
		return f
	end
	local function dps(guid, over)
		local p = { guid = guid, name = guid, class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 50000, healing = 0, interrupts = 0, dispels = 0, deaths = 0 } }
		for k, v in pairs(over or {}) do
			if k == "metrics" then
				for mk, mv in pairs(v) do
					p.metrics[mk] = mv
				end
			else
				p[k] = v
			end
		end
		return p
	end
	local function adFor(fight, guid)
		for _, r in ipairs(TP.Scoring.Engine.ScoreFight(fight, { normalizeIlvl = false })) do
			if r.name == guid then
				return r.adjustDetail or {}
			end
		end
		return {}
	end

	-- 25a. post-call deaths: deathReady + deathNoDefensives forgiven
	local f = ctxFight({ wipe = true, calledWipeAt = 200 })
	f.players.a = dps("PostCall", { deathTime = 250, deathTimes = { 250 }, deathReadyDefensives = 3,
		metrics = { deaths = 1, defensives = 0 } })
	f.players.b = dps("PreCall", { deathTime = 100, deathTimes = { 100 }, deathReadyDefensives = 3,
		metrics = { deaths = 1, defensives = 0 } })
	local adA, adB = adFor(f, "PostCall"), adFor(f, "PreCall")
	check((adA.deathReady or 0) == 0 and (adA.deathNoDefensives or 0) == 0 and (adA.deaths or 0) == 0,
		("post-call death forgiven everywhere (ready=%s nodef=%s deaths=%s)"):format(
			tostring(adA.deathReady), tostring(adA.deathNoDefensives), tostring(adA.deaths)))
	check((adB.deathReady or 0) < 0 and (adB.deathNoDefensives or 0) < 0 and (adB.deaths or 0) < 0,
		"pre-call death still charged in full")

	-- 25b. brez double-charge: pre-call death charged once, post-call
	-- re-death dropped from the count (not promoted to full price)
	f.players.c = dps("Brezzed", { deathTime = 250, deathTimes = { 100, 250 },
		metrics = { deaths = 2, defensives = 1 } })
	local adC = adFor(f, "Brezzed")
	check((adC.deaths or 0) < 0 and adC.deaths > -4.5,
		("brezzed re-death not promoted to full price (%s)"):format(tostring(adC.deaths)))

	-- 25c. one-shot death: no defensive would have mattered
	local f2 = ctxFight({})
	f2.players.a = dps("Oneshot", { deathTime = 150, maxHP = 400000, deathReadyDefensives = 2,
		deathRecap = { { t = 149, spell = "Buster", amount = 4000000 } },
		metrics = { deaths = 1, defensives = 0 } })
	f2.players.b = dps("Rotted", { deathTime = 150, maxHP = 400000, deathReadyDefensives = 2,
		deathRecap = { { t = 148, spell = "Rot", amount = 90000 }, { t = 149, spell = "Rot", amount = 95000 } },
		metrics = { deaths = 1, defensives = 0 } })
	local ad1, ad2 = adFor(f2, "Oneshot"), adFor(f2, "Rotted")
	check((ad1.deathReady or 0) == 0 and (ad1.deathNoDefensives or 0) == 0,
		"one-shot death skips the defensive penalties")
	check((ad2.deathReady or 0) < 0 and (ad2.deathNoDefensives or 0) < 0,
		"sustained death with defensives ready still charged")

	-- 25d. lust: dead before the window opened is not "wasted"; CDs spent
	-- earlier in the fight soften the miss
	local f3 = ctxFight({ lustAt = 200 })
	f3.players.a = dps("DeadFirst", { deathTime = 100, metrics = { deaths = 1, lustCasts = 0 } })
	f3.players.b = dps("SpentEarly", { metrics = { lustCasts = 0, offensiveCDs = 3 } })
	f3.players.c = dps("NoButtons", { metrics = { lustCasts = 0 } })
	local la, lb, lc = adFor(f3, "DeadFirst"), adFor(f3, "SpentEarly"), adFor(f3, "NoButtons")
	check((la.lust or 0) == 0, ("dead before lust window: no penalty (%s)"):format(tostring(la.lust)))
	check((lb.lust or 0) == -1.5, ("early CDs halve the lust miss (%s)"):format(tostring(lb.lust)))
	check((lc.lust or 0) == -3, ("no buttons at all keeps the full miss (%s)"):format(tostring(lc.lust)))

	-- 25e. manaDry judged against the trying phase, not the doomed tail
	local f4 = ctxFight({ wipe = true, calledWipeAt = 150 })
	f4.players.a = dps("DryLate", { role = "HEALER",
		metrics = { healing = 50000, dryAt = 200, deaths = 0 } })
	f4.players.a.role = "HEALER"
	local adDry = adFor(f4, "DryLate")
	check((adDry.manaDry or 0) == 0,
		("dry after the wipe call: no penalty (%s)"):format(tostring(adDry.manaDry)))

	-- 25f. overkill needs a sustained fight (someone must land every blow)
	local f5 = ctxFight({ duration = 30 })
	f5.players.a = dps("Finisher", { metrics = { overkillPct = 15 } })
	check((adFor(f5, "Finisher").overkill or 0) == 0, "short-fight overkill not judged")
	local f6 = ctxFight({ duration = 300 })
	f6.players.a = dps("Padder", { metrics = { overkillPct = 15 } })
	check((adFor(f6, "Padder").overkill or 0) < 0, "sustained overkill still charged")

	-- 25g. activity: dead time isn't inactivity (the death already cost)
	local f7 = ctxFight({})
	f7.players.a = dps("DiedEarly", { deathTime = 60, metrics = { deaths = 1, activityPct = 40 } })
	f7.players.b = dps("Afk", { metrics = { activityPct = 40 } })
	check((adFor(f7, "DiedEarly").activity or 0) == 0, "dead time doesn't double as inactivity")
	check((adFor(f7, "Afk").activity or 0) < 0, "living low activity still charged")

	-- 25g2. per-spec activity calibration (2026-07-25): a caster whose
	-- top parses idle at 99% is judged against 80-99, not the fixed
	-- 70-89. 88% activity is +4 on the fixed curve but negative for a
	-- 99-anchored caster.
	local savedAP = TP.SpellProfiles
	TP.SpellProfiles = { [64] = { activity = 99 } } -- mage, top parses idle ~99
	local fac = ctxFight({})
	fac.players.a = dps("Caster", { specID = 64, metrics = { activityPct = 88 } })
	check((adFor(fac, "Caster").activity or 0) < 0,
		("88%% reads negative against a 99-anchored spec (%s)"):format(tostring(adFor(fac, "Caster").activity)))
	TP.SpellProfiles = nil -- no profile: fixed 70/89, 88% is strongly positive
	check((adFor(fac, "Caster").activity or 0) > 0, "no profile falls back to fixed anchors")
	TP.SpellProfiles = savedAP

	-- 25h. kick share scaled by alive fraction: a player dead at 10%
	-- couldn't kick for the other 90%
	local f8 = ctxFight({ totals = nil })
	f8.players.a = dps("DeadKicker", { deathTime = 30, metrics = { deaths = 1, interrupts = 0 } })
	f8.players.b = dps("LazyKicker", { metrics = { interrupts = 0 } })
	f8.players.c = dps("Kicker", { metrics = { interrupts = 8 } })
	local ka, kb = adFor(f8, "DeadKicker"), adFor(f8, "LazyKicker")
	check((ka.kicks or 0) > (kb.kicks or 0) * 0.2 and (kb.kicks or 0) < 0,
		("dead kicker's share penalty scaled way down (%s vs %s)"):format(
			tostring(ka.kicks), tostring(kb.kicks)))

	-- 25h2. healthstones (2026-07-25): +1 eaten, -1 sat on it — judged
	-- only when a warlock was in the group to provide them; nil metric
	-- (retail: casts are secret) stays neutral either way
	-- ...and the PENALTY needs a reason to have pressed it (Josh
	-- 2026-07-29): a personal spike window, a death, or intake worth at
	-- least the player's own health pool. The bonus stays unconditional.
	local fhs = ctxFight({})
	fhs.players.a = dps("Ate", { metrics = { healthstones = 1 } })
	fhs.players.b = dps("Hoarder", { metrics = { healthstones = 0, spikeWindows = 1 } })
	fhs.players.c = dps("NoData", { metrics = {} })
	fhs.players.d = dps("Safe", { metrics = { healthstones = 0 } })
	fhs.players.e = dps("Chunked", { metrics = { healthstones = 0, damageTaken = 500000 } })
	fhs.players.e.maxHP = 400000
	fhs.players.a.class = "WARLOCK"
	check((adFor(fhs, "Ate").healthstone or 0) == 1, "healthstone eaten: +1")
	check((adFor(fhs, "Hoarder").healthstone or 0) == -1,
		"healthstone unused THROUGH danger: -1")
	check(adFor(fhs, "NoData").healthstone == nil, "no cast data: healthstone neutral")
	check(adFor(fhs, "Safe").healthstone == nil,
		"no danger, no damage: healthstone not penalised")
	check((adFor(fhs, "Chunked").healthstone or 0) == -1,
		"intake past own max HP counts as danger: -1")
	local fnl = ctxFight({})
	fnl.players.a = dps("NoLock", { metrics = { healthstones = 0 } })
	check(adFor(fnl, "NoLock").healthstone == nil, "no warlock in group: healthstone ignored")

	-- 25h2b. dispel reaction (2026-07-25): fast +1, slow -1, needs 2+
	-- dispels; orthogonal to the dispel-count adjustment
	local fdr = ctxFight({})
	fdr.players.a = dps("Snappy", { metrics = { dispels = 4, dispelReactAvg = 1.8 } })
	fdr.players.b = dps("Sluggish", { metrics = { dispels = 4, dispelReactAvg = 7.5 } })
	fdr.players.c = dps("Middling", { metrics = { dispels = 4, dispelReactAvg = 3.7 } })
	fdr.players.d = dps("OneOff", { metrics = { dispels = 1, dispelReactAvg = 1.0 } })
	check((adFor(fdr, "Snappy").dispelReact or 0) == 1, "fast dispels earn +1")
	check((adFor(fdr, "Sluggish").dispelReact or 0) == -1, "slow dispels cost -1")
	check(adFor(fdr, "Middling").dispelReact == nil, "mid-pace dispels: neutral")
	check(adFor(fdr, "OneOff").dispelReact == nil, "one dispel: not enough to judge reaction")

	-- 25h3. tanking = mitigation-uptime percentile vs the spec's WCL field
	-- (Josh 2026-07-26): a base metric now, high uptime scores high, low
	-- scores low - no longer a bonus-only adjustment.
	local ftk = ctxFight({})
	ftk.players.a = dps("Wall", { role = "TANK", specID = 250, metrics = { damageTaken = 1000000,
		swingsLanded = 40, swingsAvoided = 160, swingDamageTaken = 400000,
		mitigationPct = 95, selfHealing = 1500000, absorbedTaken = 800000, selfAbsorbs = 0 } })
	ftk.players.b = dps("Paper", { role = "TANK", specID = 250, metrics = { damageTaken = 1000000,
		swingsLanded = 190, swingsAvoided = 10, swingDamageTaken = 900000,
		mitigationPct = 15, selfHealing = 50000, absorbedTaken = 20000, selfAbsorbs = 0 } })
	local function tankMetric(name)
		for _, r in ipairs(TP.Scoring.Engine.ScoreFight(ftk, { normalizeIlvl = false })) do
			if r.name == name then return r.breakdown.mitigation end
		end
	end
	local wallT, paperT = tankMetric("Wall"), tankMetric("Paper")
	check(wallT and wallT.applicable and (wallT.normalized or 0) > 60,
		("high mitigation uptime scores high (%s)"):format(tostring(wallT and wallT.normalized)))
	check(paperT and (paperT.normalized or 100) < 30,
		("low mitigation uptime scores low (%s)"):format(tostring(paperT and paperT.normalized)))

	-- 25i. per-spec overheal thresholds: a shield-heavy spec's population
	-- runs high overheal; its p75 exempts what the fixed 45 would charge
	local f9 = ctxFight({})
	f9.players.a = dps("Discy", { specID = 256, metrics = { healing = 500000, overhealPct = 50 } })
	f9.players.a.role = "HEALER"
	f9.players.b = dps("Tank", { role = "TANK", metrics = { damageTaken = 900000 } })
	f9.players.b.role = "TANK"
	TP.OverhealCurves = { [256] = { p25 = 30, p75 = 55, p90 = 70, n = 100 } }
	local oh = adFor(f9, "Discy")
	check((oh.overheal or 0) == 0,
		("spec p75=55 exempts 50%% overheal that fixed-45 would charge (%s)"):format(tostring(oh.overheal)))
	TP.OverhealCurves[256] = { p25 = 30, p75 = 45, p90 = 48, n = 100 }
	oh = adFor(f9, "Discy")
	check((oh.overheal or 0) < -1.5,
		("above spec p90 hits the -2 tier (%s)"):format(tostring(oh.overheal)))
	TP.OverhealCurves = nil
	oh = adFor(f9, "Discy")
	check((oh.overheal or 0) == -1,
		("no curves: fixed thresholds unchanged (%s)"):format(tostring(oh.overheal)))
end)()

-- 26. Spikes.Compute team coverage (audit 2026-07-18): group windows are
-- the healer TEAM's job; proactive pre-casts count; corpses aren't judged
;(function()
	local seg = {
		players = {
			h1 = { name = "Hone", spikes = { maxHP = 100000, taken = {}, casts = { 24 },
				castNames = { "Healing Tide Totem" } } }, -- 6s early: pre-slop credits it
			h2 = { spikes = { maxHP = 100000, taken = { [30] = 60000 },
				top = { [30] = { 60000, "Empowered Whirling Corruption" } }, casts = {} } },
			h3 = { spikes = { maxHP = 100000, taken = {}, casts = {} },
				deaths = { total = 1, lastTime = 20 } },
		},
	}
	local out = TP.Spikes.Compute(seg, 120)
	check(out.h1 and out.h1.groupSpikeCovered == 1, "pre-cast raid CD covers the window (pre-slop)")
	check(out.h2 and out.h2.groupSpikeCovered == 1,
		"team coverage credits every healer (rotation isn't punished)")
	-- personal attribution rides the map's 4th field: h1 cast it, h2
	-- didn't — their tapes must differ even though the score is shared
	check(out.h1.groupSpikeMap and out.h1.groupSpikeMap[1][4] == true,
		"the caster's tape marks the window as theirs")
	check(out.h2.groupSpikeMap and out.h2.groupSpikeMap[1][3] and not out.h2.groupSpikeMap[1][4],
		"the non-caster sees teammate coverage, not their own")
	-- band tooltips: the window carries its damage, hardest hit, and the
	-- player's answer (fields 5-7)
	local e1 = out.h1.groupSpikeMap[1]
	check(e1[5] == 60000 and e1[6] == "Empowered Whirling Corruption",
		("window carries amount + hardest hit (%s, %s)"):format(tostring(e1[5]), tostring(e1[6])))
	check(e1[7] == "Healing Tide Totem",
		("the covering cast is named (%s)"):format(tostring(e1[7])))
	check(out.h2.groupSpikeMap[1][7] == nil, "no personal cover, no answer named")
	-- the TEAM strip names the coverer (fields 8-9, on every player's map)
	check(out.h2.groupSpikeMap[1][8] == "Hone" and out.h2.groupSpikeMap[1][9] == "Healing Tide Totem",
		("the covering teammate is named on everyone's map (%s, %s)"):format(
			tostring(out.h2.groupSpikeMap[1][8]), tostring(out.h2.groupSpikeMap[1][9])))

	-- a DPS defensive AURA riding the window also counts as personal
	-- coverage (all roles get a consistent personal strip)
	local dseg = {
		players = {
			d1 = { spikes = { maxHP = 100000, taken = { [30] = 60000 }, casts = {},
				spans = { { 28, 35 } } } },
			d2 = { spikes = { maxHP = 100000, taken = {}, casts = {}, spans = {} } },
			d3 = { spikes = { maxHP = 100000, taken = {}, casts = {}, spans = {} } },
		},
	}
	local dout = TP.Spikes.Compute(dseg, 120)
	check(dout.d1 and dout.d1.groupSpikeMap and dout.d1.groupSpikeMap[1][4] == true,
		"a defensive span covering the window marks the DPS tape as theirs")
	check(dout.d2 and dout.d2.groupSpikeMap and not dout.d2.groupSpikeMap[1][4],
		"no span, no personal coverage")
	check(not (out.h3 and out.h3.groupSpikeWindows),
		"windows after a player's death don't judge them")
end)()

-- 27. v1.5.0 group lines: Bloodlust discipline rollup + healer-count
-- advisor (field comp crawled onto killTime.healers)
;(function()
	local savedP = TP.Percentiles
	TP.Percentiles = { encounters = {} }
	local E = TP.Percentiles.encounters
	E["Comp Boss"] = { ["3x10"] = {
		killTime = { n = 500, curve = { { 99, 100 }, { 75, 150 }, { 50, 200 }, { 10, 300 } },
			avgSize = 10, healers = { avg = 2.2, mode = 2, modePct = 64 } },
	} }
	TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
	local function mkFight()
		return {
			name = "Comp Boss", isBoss = true, duration = 220, difficultyID = 3, lustAt = 20,
			players = {
				t = { role = "TANK", specID = 268, metrics = {} },
				h1 = { role = "HEALER", specID = 270, metrics = {} },
				h2 = { role = "HEALER", specID = 105, metrics = {} },
				h3 = { role = "HEALER", specID = 65, metrics = {} },
				d1 = { role = "DAMAGER", specID = 63, metrics = { lustCasts = 2, lustPotion = 1 } },
				d2 = { role = "DAMAGER", specID = 64, metrics = { lustCasts = 1, lustPotion = 0 } },
				d3 = { role = "DAMAGER", specID = 62, metrics = { lustCasts = 0, lustPotion = 0 } },
				-- dead before the lust window opened: excused entirely
				d4 = { role = "DAMAGER", specID = 72, metrics = { lustCasts = 0 }, deathTime = 10 },
			},
		}
	end
	local function lines(fight)
		local lust, comp
		for _, b in ipairs(TP.Scoring.Bullets.ForGroup({}, fight)) do
			if b.key == "lust" then lust = b.text end
			if b.key == "healerComp" then comp = b.text end
		end
		return lust, comp
	end
	local hf, hs = TP.Scoring.Engine.HealerCountField(mkFight())
	check(hf and hf.mode == 2 and hf.modePct == 64 and hs == 10,
		"HealerCountField reads the crawled comp distribution")
	local lust, comp = lines(mkFight())
	check(lust and lust:find("2 of 3 DPS", 1, true) and lust:find("1 potioned", 1, true),
		("group lust line counts aligned+potioned, excuses the dead (%s)"):format(tostring(lust)))
	check(comp and comp:find("Ran 3 healers", 1, true) and comp:find("mostly run 2", 1, true),
		("healer advisor fires when heavier than the field (%s)"):format(tostring(comp)))
	-- field mode not dominant -> the advisor holds its tongue
	E["Comp Boss"]["3x10"].killTime.healers.modePct = 40
	local _, quiet = lines(mkFight())
	check(quiet == nil, "advisor quiet when no comp dominates the field")
	E["Comp Boss"]["3x10"].killTime.healers.modePct = 64
	-- comp matches the field -> quiet (it never advises ADDING healers)
	E["Comp Boss"]["3x10"].killTime.healers.mode = 3
	local _, match = lines(mkFight())
	check(match == nil, "advisor quiet when the comp matches (or is leaner)")
	E["Comp Boss"]["3x10"].killTime.healers.mode = 2
	-- flex guard: a comp much smaller than the field's size isn't compared
	E["Comp Boss"]["3x10"].killTime.avgSize = 22
	local _, flex = lines(mkFight())
	check(flex == nil, "advisor quiet across mismatched raid sizes")
	E["Comp Boss"]["3x10"].killTime.avgSize = 10
	-- wipes carry no comp advice
	local wf = mkFight()
	wf.wipe = true
	local _, wiped = lines(wf)
	check(wiped == nil, "advisor quiet on wipes")
	-- the group card's Signal rows transform ForGroup's tested output
	local grows = TP.Scoring.Signals.GroupRows({}, mkFight())
	local g = {}
	for _, r in ipairs(grows) do
		g[r.key] = r
	end
	check(g.lust and g.lust.kind == "bar" and g.lust.num == "2/3",
		("group lust becomes a coverage bar (%s)"):format(tostring(g.lust and g.lust.num)))
	check(g.healerComp and g.healerComp.kind == "glyph" and g.healerComp.count == "3v2",
		("comp advisor becomes a verdict glyph (%s)"):format(tostring(g.healerComp and g.healerComp.count)))
	-- run-level pointer needs the pattern across 2+ kills
	local tips = TP.Scoring.Insights.RunAdvice({ mkFight(), mkFight() })
	local saw = false
	for _, t in ipairs(tips) do
		if t:find("healer swapped to DPS", 1, true) then saw = true end
	end
	check(saw, "run advice names the comp trade after repeated heavy kills")
	check(#TP.Scoring.Insights.RunAdvice({ mkFight() }) == 0,
		"one heavy kill is not a pattern")

	-- raid-CD assignment line: uncovered moments + unused raid-wide CDs
	local function cdFight(used, coveredN)
		local f = mkFight()
		f.totals = { raidCdsUsed = used }
		-- resto druid owns Tranquility; class field feeds Rallying Cry
		f.players.h2.class = "DRUID"
		f.players.d4.class = "WARRIOR"
		f.players.h1.metrics.groupSpikeWindows = 4
		f.players.h1.metrics.groupSpikeCovered = coveredN
		return f
	end
	local function cdLine(f)
		for _, b in ipairs(TP.Scoring.Bullets.ForGroup({}, f)) do
			if b.key == "raidCds" then
				return b.text
			end
		end
	end
	-- the comp owns: Revival (h1 MW), Tranquility (h2 resto), Devotion
	-- Aura (h3 HPal), Avert Harm (t brew), Rallying Cry (d4 warrior)
	local line = cdLine(cdFight({ [115310] = true }, 2))
	check(line and line:find("2 of 4", 1, true)
		and line:find("Avert Harm, Devotion Aura, Rallying Cry", 1, true),
		("assignment line names owned-but-unused raid CDs, capped at 3 (%s)"):format(tostring(line)))
	check(line and not line:find("Revival", 1, true),
		"a raid CD that was pressed is never listed")
	check(cdLine(cdFight({ [115310] = true, [740] = true, [97462] = true,
		[31821] = true, [115213] = true }, 2)) == nil,
		"all owned raid CDs used -> no assignment line")
	check(cdLine(cdFight({}, 4)) == nil,
		"full coverage -> no assignment line")

	-- the group card's raidCds glyph: names go in the TOOLTIP (the 30px
	-- number column clipped them — audit 2026-07-24), the count on the row
	local cdRows = TP.Scoring.Signals.GroupRows({}, cdFight({ [115310] = true }, 2))
	local cdRow
	for _, r in ipairs(cdRows) do
		if r.key == "raidCds" then
			cdRow = r
		end
	end
	check(cdRow and cdRow.count == "3",
		("raidCds glyph carries the count, not the names (%s)"):format(tostring(cdRow and cdRow.count)))
	check(cdRow and cdRow.tooltip and cdRow.tooltip.lines[1]
		and cdRow.tooltip.lines[1][1]:find("Avert Harm, Devotion Aura, Rallying Cry", 1, true) ~= nil,
		"raidCds tooltip names the unused cooldowns")
	TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
	TP.Percentiles = savedP
end)()

-- 28. v1.5.2: kill-speed trend line + wipe-call crispness
;(function()
	local savedP = TP.Percentiles
	TP.Percentiles = { encounters = {
		["Trend Boss"] = { ["3x10"] = {
			-- uncapped killTime: sample pct IS the true pct
			killTime = { n = 600, curve = { { 99, 100 }, { 90, 140 }, { 75, 170 }, { 50, 200 }, { 25, 240 }, { 10, 280 } } },
		} },
	} }
	TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
	local function lineFor(fight, key)
		for _, b in ipairs(TP.Scoring.Bullets.ForGroup({}, fight)) do
			if b.key == key then
				return b.text
			end
		end
	end
	-- faster kill with curve coverage: seconds + percentile move
	local kill = { name = "Trend Boss", isBoss = true, difficultyID = 3,
		duration = 170, prevKillDuration = 200, players = {} }
	local t = lineFor(kill, "speedTrend")
	check(t and t:find("30s faster", 1, true) and t:find("(p50 -> p75)", 1, true),
		("speed trend shows seconds and percentile move (%s)"):format(tostring(t)))
	-- slower reads neutral, not scolding
	kill.duration = 240
	kill.prevKillDuration = 200
	t = lineFor(kill, "speedTrend")
	check(t and t:find("40s slower", 1, true), ("slower kill reads neutral (%s)"):format(tostring(t)))
	-- within 5s = variance, no line; no prior kill = no line
	kill.duration = 202
	check(lineFor(kill, "speedTrend") == nil, "a 2s delta is variance, not a trend")
	kill.prevKillDuration = nil
	kill.duration = 170
	check(lineFor(kill, "speedTrend") == nil, "first kill has no trend line")
	-- wipe-call crispness tiers
	local wipe = { name = "Trend Boss", isBoss = true, difficultyID = 3, wipe = true,
		duration = 130, calledWipeAt = 120, players = {} }
	t = lineFor(wipe, "wipeWrap")
	check(t and t:find("wrapped 10s later - crisp", 1, true),
		("crisp wrap earns the label (%s)"):format(tostring(t)))
	wipe.duration = 165
	t = lineFor(wipe, "wipeWrap")
	check(t and t:find("wrapped 45s later", 1, true) and not t:find("crisp", 1, true),
		("slow wrap shown without the label (%s)"):format(tostring(t)))
	wipe.calledWipeAt = nil
	check(lineFor(wipe, "wipeWrap") == nil, "uncalled wipes carry no wrap line")
	-- chronic slow wraps become run advice
	local slow = { name = "Trend Boss", isBoss = true, wipe = true, duration = 165,
		calledWipeAt = 120, players = {}, totals = {} }
	local tips = TP.Scoring.Insights.RunAdvice({ slow, slow })
	local saw = false
	for _, tip in ipairs(tips) do
		if tip:find("dying fast IS the reset", 1, true) then
			saw = true
		end
	end
	check(saw, "chronic slow wraps get the run pointer")
	check(#TP.Scoring.Insights.RunAdvice({ slow }) == 0, "one slow wrap is not a pattern")
	TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
	TP.Percentiles = savedP
end)()

-- 29. Availability awareness (2026-07-23): "could have, but didn't"
-- requires could-have. Capacity caps the judged danger windows; a CD
-- spent just before Bloodlust is no lust miss; a reported zero-ready
-- death had nothing to press.
;(function()
	local PLAYER_KEYS = { deathReadyDefensives = true, deathTime = true, class = true, specID = true }
	local function score(patches)
		local fight = {
			name = "(!) Avail Boss", isBoss = true, duration = 300,
			players = {
				h = { guid = "h", name = "Healer", class = "MONK", role = "HEALER", specID = 270,
					metrics = { damage = 0, healing = 900000, interrupts = 0, dispels = 0,
						deaths = 0, avoidableTaken = 0, damageTaken = 10000 } },
				t = { guid = "t", name = "Tank", class = "WARRIOR", role = "TANK", specID = 73,
					metrics = { damage = 200000, healing = 0, interrupts = 0, dispels = 0,
						deaths = 0, avoidableTaken = 0, damageTaken = 500000 } },
				d = { guid = "d", name = "Dps", class = "MAGE", role = "DAMAGER", specID = 63,
					metrics = { damage = 900000, healing = 0, interrupts = 0, dispels = 0,
						deaths = 0, avoidableTaken = 0, damageTaken = 10000 } },
			},
		}
		for guid, patch in pairs(patches or {}) do
			if guid == "fight" then
				for k, v in pairs(patch) do
					fight[k] = v
				end
			else
				for k, v in pairs(patch) do
					if PLAYER_KEYS[k] then
						fight.players[guid][k] = v
					else
						fight.players[guid].metrics[k] = v
					end
				end
			end
		end
		local by = {}
		for _, r in ipairs(TP.Scoring.Engine.ScoreFight(fight, { normalizeIlvl = false })) do
			by[r.name] = r
		end
		return by
	end
	-- healer team: 6 windows but only 2 raid-CD casts (both landed well).
	-- 3 coverable, 2 covered -> positive, where the old math said -3
	local by = score({ h = { groupSpikeWindows = 6, groupSpikeCovered = 2, groupCdCasts = 2 } })
	check((by.Healer.adjustDetail.cdTiming or 0) > 0,
		("out of buttons, not discipline: capped coverage reads positive (%.1f)"):format(by.Healer.adjustDetail.cdTiming or 0))
	-- zero uses gets NO cap: nothing was ever on cooldown
	by = score({ h = { groupSpikeWindows = 6, groupSpikeCovered = 0, groupCdCasts = 0 } })
	check((by.Healer.adjustDetail.cdTiming or 0) < 0,
		"zero uses is maximum culpability, not an exemption")
	-- pre-capacity records: unchanged judgment
	by = score({ h = { groupSpikeWindows = 6, groupSpikeCovered = 2 } })
	check((by.Healer.adjustDetail.cdTiming or 0) < 0,
		"records without capacity data keep the old judgment")
	-- tank personal defensives cap the same way
	by = score({ t = { spikeWindows = 5, spikeCovered = 2, defensiveUses = 2 } })
	check((by.Tank.adjustDetail.cdTiming or 0) > 0,
		("tank capacity cap (%.1f)"):format(by.Tank.adjustDetail.cdTiming or 0))
	-- lust cooldown shadow: a CD spent 60s before the window was still
	-- down during it -> no penalty at all (was: halved)
	by = score({ fight = { lustAt = 100 }, d = { lustCasts = 0, offensiveCDs = 2, lastOffensiveAt = 40 } })
	check((by.Dps.adjustDetail.lust or 0) == 0,
		"a CD inside the pre-lust shadow is no alibi-free miss")
	-- a cast long before the shadow is no alibi: softened penalty stands
	by = score({ fight = { lustAt = 200 }, d = { lustCasts = 0, offensiveCDs = 2, lastOffensiveAt = 40 } })
	check((by.Dps.adjustDetail.lust or 0) < 0, "an old cast is no alibi")
	-- reported ZERO defensives ready at death = nothing to press
	by = score({ d = { deaths = 1, defensives = 0, deathReadyDefensives = 0 } })
	check((by.Dps.adjustDetail.deathNoDefensives or 0) == 0,
		"all-on-cooldown death skips the no-defensive penalty")
	by = score({ d = { deaths = 1, defensives = 0 } })
	check((by.Dps.adjustDetail.deathNoDefensives or 0) < 0,
		"unreported readiness keeps the penalty (counted, not inferred)")

	-- healer interrupts are bonus-only (Josh 2026-07-24): kicking is not
	-- the healer's job — landing one signals a higher level of play,
	-- missing them signals nothing
	by = score({ h = { class = "SHAMAN", specID = 264 }, d = { interrupts = 6 } })
	check((by.Healer.adjustDetail.kicks or 0) == 0,
		("kick-capable healer, zero kicks, kick-heavy fight: no penalty (%.1f)"):format(by.Healer.adjustDetail.kicks or 0))
	check((by.Dps.adjustDetail.kicks or 0) > 0, "the kicker still earns")
	by = score({ h = { class = "SHAMAN", specID = 264, interrupts = 3 }, d = { interrupts = 3 } })
	check((by.Healer.adjustDetail.kicks or 0) > 0,
		("a healer who kicks anyway still gains (%.1f)"):format(by.Healer.adjustDetail.kicks or 0))
end)()

-- 30. Parse coach: own signature-spell rate vs top parses (one targeted
-- line; Josh 2026-07-24)
;(function()
	local savedProf = TP.SpellProfiles
	TP.SpellProfiles = {
		[105] = { n = 38, activity = 98.5, spells = {
			{ ids = { 774 }, name = "Rejuvenation", cpm = 20.8 },
			{ ids = { 33763 }, name = "Lifebloom", cpm = 4.4 },
			-- multi-id morph (Jab-style): player casts land on ANY id
			{ ids = { 100, 200 }, name = "Splitspell", cpm = 6.0 },
		} },
	}
	local PG = TP.Scoring.Insights.ParseGap
	-- big Rejuvenation shortfall wins over the smaller Lifebloom one
	local gap = PG(105, { profCasts = { [774] = 18, [33763] = 6, [100] = 9, [200] = 9 } }, 180)
	check(gap and gap.spell == "Rejuvenation" and gap.text:find("top parses 21", 1, true)
		and gap.text:find("you average 6/min", 1, true),
		("biggest shortfall wins, phrased human (%s)"):format(tostring(gap and gap.text)))
	-- multi-id casts SUM before comparing (9+9 over 3min = 6/min = at profile)
	local m2 = { profCasts = { [774] = 63, [33763] = 14, [100] = 9, [200] = 9 } }
	check(PG(105, m2, 180) == nil, "close to profile on every spell -> no coaching")
	-- short fights are noise, absent profiles are silence
	check(PG(105, { profCasts = {} }, 45) == nil, "sub-minute fights aren't coached")
	check(PG(63, { profCasts = {} }, 180) == nil, "no profile for the spec -> nil")
	check(PG(105, nil, 180) == nil, "no metrics -> nil")
	-- zero casts of everything still coaches (the biggest gap of all)
	local zero = PG(105, { profCasts = {} }, 180)
	check(zero and zero.spell == "Rejuvenation", "an empty fight coaches the top spell")
	-- RotationGaps: the FULL comparison, worst-shortfall first, deltas signed
	local RG = TP.Scoring.Insights.RotationGaps
	local rot = RG(105, { profCasts = { [774] = 18, [33763] = 6, [100] = 27, [200] = 30 } }, 180)
	check(rot and #rot == 3, ("rotation lists every signature spell (%s)"):format(rot and #rot or "nil"))
	check(rot and rot[1].spell == "Rejuvenation" and rot[1].delta < 0,
		"worst shortfall leads the rotation list")
	-- over-casting shows too: [200] at 30 casts over 3min = 10/min, above profile
	local over
	for _, r in ipairs(rot or {}) do
		if r.delta > 0 then over = r end
	end
	check(over ~= nil, "over-casting a spell surfaces as a positive delta")
	check(RG(63, { profCasts = {} }, 180) == nil, "no profile -> no rotation")
	check(RG(105, nil, 180) == nil, "no metrics -> no rotation")
	-- profCasts NIL = the fight predates the cast counter: silence, not
	-- "you 0" (Josh's card 2026-07-24 was such a fight)
	check(PG(105, {}, 180) == nil, "pre-counter fights are never coached")
	-- practice-dummy fights (Josh 2026-07-26) score against the tier's
	-- patchwerk anchor and suppress everything kill-shaped
	local savedP2 = TP.Percentiles
	TP.Percentiles = { encounters = { ["Iron Juggernaut"] = { ["3x10"] = {
		dps = { [63] = { n = 500, curve = { { 99, 400000 }, { 75, 300000 }, { 50, 250000 }, { 10, 150000 } } } },
		hps = {},
		killTime = { n = 500, curve = { { 99, 100 }, { 50, 200 }, { 10, 300 } } },
	} } } }
	TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
	local dummyFight = {
		name = "Raider's Training Dummy", isBoss = true, practice = true,
		duration = 180, difficultyID = 3,
		players = { d = { guid = "d", name = "Dps", class = "MAGE", role = "DAMAGER", specID = 63,
			metrics = { damage = 45000000, healing = 0, interrupts = 0, dispels = 0,
				deaths = 0, avoidableTaken = 0, damageTaken = 0 } } },
	}
	local rs = TP.Scoring.Engine.ScoreFight(dummyFight, { normalizeIlvl = false, mode = "parse" })
	check(rs[1] and rs[1].breakdown.damage and rs[1].breakdown.damage.pctile
		and math.abs(rs[1].breakdown.damage.pctile - 50) < 3,
		("practice fight parses against the anchor's curves (%s)"):format(
			tostring(rs[1] and rs[1].breakdown.damage and rs[1].breakdown.damage.pctile)))
	check(TP.Scoring.Engine.KillSpeedPercentile(dummyFight) == nil,
		"practice sessions have no kill speed")
	check(TP.Scoring.Engine.HealerCountField(dummyFight) == nil,
		"practice sessions get no comp advice")
	TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
	TP.Percentiles = savedP2

	-- the coach reaches the CARD as a visible bullet (tooltip-only was
	-- undiscoverable)
	local res = { role = "HEALER", adjustDetail = {}, penaltyDetail = {},
		breakdown = { healing = { applicable = true, normalized = 55, effectiveWeight = 0.79, value = 100000 } } }
	local found
	for _, b in ipairs(TP.Scoring.Bullets.ForResult(res, nil,
		{ profCasts = { [774] = 18 }, specID = 105, duration = 180 })) do
		if b.key == "coach" then
			found = b.text
		end
	end
	check(found and found:find("Cast Rejuvenation more often", 1, true),
		("coach bullet survives the impact filter (%s)"):format(tostring(found)))
	TP.SpellProfiles = savedProf
end)()

-- 31. Signal Column model (2026-07-26 redesign): rows carry verdict
-- labels, capacity ghosts, and honest kinds per signal
;(function()
	local S = TP.Scoring.Signals
	local result = {
		role = "HEALER",
		adjustDetail = { cdTiming = 3, dispels = 3, defensives = 2, activity = -4 },
		penaltyDetail = { deaths = 6 },
		breakdown = {
			healing = { applicable = true, pctile = 38, value = 35600000 },
			damage = { applicable = true, pctile = 52, value = 8000000 },
			dispels = { applicable = true, normalized = 72, value = 5 },
		},
	}
	local player = {
		metrics = { activityPct = 69, groupSpikeWindows = 6, groupSpikeCovered = 2,
			groupCdCasts = 2, defensives = 2, deaths = 1, lustCasts = 0 },
	}
	local rows = S.ForResult(result, { isBoss = true }, player)
	local byKey = {}
	for _, r in ipairs(rows) do
		byKey[r.key] = r
	end
	check(rows[1].key == "healing" and rows[1].kind == "bar" and rows[1].label == "Healing"
		and rows[1].value == 38, "healer's primary bar leads with its percentile")
	check(byKey.activity and byKey.activity.points == -4 and byKey.activity.value == 69,
		"activity bar carries its points")
	-- activity is a chip now (Josh 2026-07-25): "Active 69% -4" in the
	-- grid — num routes it there, and no tier means no gauge
	check(byKey.activity.num == "69%" and byKey.activity.tier == nil,
		("activity is a num chip, not a gauge (%s)"):format(tostring(byKey.activity.num)))
	local hot = S.ForResult({ role = "DAMAGER", adjustDetail = { activity = 4 }, penaltyDetail = {},
		breakdown = { damage = { applicable = true, pctile = 80 } } }, {},
		{ metrics = { activityPct = 97 } })
	local act
	for _, r in ipairs(hot) do
		if r.key == "activity" then
			act = r
		end
	end
	check(act and act.num == "97%" and act.points == 4 and act.tier == nil,
		("97%% activity chips with its +4 (%s)"):format(tostring(act and act.num)))
	local cd = byKey.cdTiming
	check(cd and cd.kind == "bar" and cd.num == "2/3" and math.abs(cd.value - 66.7) < 0.5
		and cd.label == "Covered" and cd.detail and cd.detail:find("6 spikes", 1, true),
		("coverage bar: one denominator everywhere, capacity in the tooltip (%s, %s)"):format(
			tostring(cd and cd.num), tostring(cd and cd.value)))
	check(byKey.deaths and byKey.deaths.kind == "pips" and byKey.deaths.count == 1
		and byKey.deaths.label == "Died", "deaths are pips with a verdict label")
	check(byKey.lust == nil, "healers get no lust row")
	-- unvisualized signals are their OWN markless rows now (the Other
	-- rollup retired 2026-07-25: per-item hovers beat a nested list)
	check(byKey.other == nil, "no Other rollup remains")
	check(byKey.defensives and byKey.defensives.kind == "glyph"
		and byKey.defensives.count == 2 and byKey.defensives.points == 2,
		("defensives get their own verdict row (%s)"):format(tostring(byKey.defensives and byKey.defensives.count)))
	local function otherItem(rows2, want)
		for _, r in ipairs(rows2) do
			if r.label == want then
				return r
			end
		end
	end
	-- DPS lust verdicts spell out the finding (Josh: never make the
	-- user compute "missed the window")
	local dps = { role = "DAMAGER", adjustDetail = { lust = -3 }, penaltyDetail = {},
		breakdown = { damage = { applicable = true, pctile = 80 } } }
	local drows = S.ForResult(dps, {}, { metrics = { lustCasts = 0 } })
	local missed = otherItem(drows, "Lust missed")
	check(missed and missed.points == -3,
		"a missed window says so in words, on its own row")
	drows = S.ForResult({ role = "DAMAGER", adjustDetail = { lust = 3 }, penaltyDetail = {},
		breakdown = { damage = { applicable = true, pctile = 80 } } }, {},
		{ metrics = { lustCasts = 2, lustPotion = 1 } })
	check(otherItem(drows, "Lust + potion") ~= nil, "full alignment reads as the best verdict")
	-- retail shapes (no CLEU): kicks without opportunity data keep a
	-- share bar with the landed count; SUPPORT keeps Prescience + the
	-- amplification label (cross-scenario audit 2026-07-24)
	local retail = S.ForResult({ role = "DAMAGER", adjustDetail = { kicks = 2 }, penaltyDetail = {},
		breakdown = { damage = { applicable = true, pctile = 60 },
			interrupts = { applicable = true, value = 3, normalized = 80 } } }, {}, { metrics = {} })
	local rk
	for _, r in ipairs(retail) do
		if r.key == "interrupts" then
			rk = r
		end
	end
	check(rk and rk.raw and rk.num == "3" and rk.value == 80,
		("retail kicks: share bar + landed count (%s)"):format(tostring(rk and rk.num)))
	local aug = S.ForResult({ role = "SUPPORT", adjustDetail = {}, penaltyDetail = {},
		breakdown = { damage = { applicable = true, normalized = 70, attribution = { own = 1, attributed = 2 } },
			prescience = { applicable = true, normalized = 85, value = 22 } } }, {}, { metrics = {} })
	local byK = {}
	for _, r in ipairs(aug) do
		byK[r.key] = r
	end
	check(byK.damage and byK.damage.label == "Amplified",
		"Aug damage row reads Amplified")
	check(byK.prescience and byK.prescience.value == 85 and byK.prescience.raw,
		"Prescience keeps its row")

	-- group averages feed the comparison ticks
	local avg = S.GroupAverages({ result, dps }, { players = {} })
	check(avg.damage and math.abs(avg.damage - 66) < 0.5,
		("group average per key ((52+80)/2 = %s)"):format(tostring(avg.damage)))
	-- fight-shape downsampler: sparse seconds -> n cells, values summed
	local cells = S.Downsample({ [0] = 100, [1] = 100, [59] = 300, [60] = 0 }, 60, 6)
	check(cells and #cells == 6 and cells[1] == 200 and cells[6] == 300,
		("downsample sums into the right cells (%s, %s)"):format(
			tostring(cells and cells[1]), tostring(cells and cells[6])))
	check(S.Downsample({}, 60, 6) == nil, "an all-zero series downsamples to nil")
	check(S.Downsample(nil, 60, 6) == nil, "no series, no shape")
end)()

-- 32. Activity tracker (2026-07-24): a completed hardcast credits its full
-- cast time, not one GCD. Chain-casting 1.9s Wraths must read ~100%, not
-- 84% (the field bug: 83 on a dummy while casting nonstop).
;(function()
	local clock = 0
	GetTime = function()
		return clock
	end
	loadModule("Metrics/Activity.lua", TP)
	local tracker
	for _, t in ipairs(TP.Metrics.trackers) do
		if t.subevents and t.subevents.SPELL_CAST_START then
			tracker = t
		end
	end
	check(tracker ~= nil, "activity tracker registers a cast-start handler")
	local start = tracker.subevents.SPELL_CAST_START
	local success = tracker.subevents.SPELL_CAST_SUCCESS
	local swing = tracker.subevents.SWING_DAMAGE
	local swingMiss = tracker.subevents.SWING_MISSED

	local WRATH, MOONFIRE, MIND_FLAY = 5176, 8921, 15407
	local function freshSeg()
		local acc = {}
		tracker.InitPlayer(acc)
		return { players = { me = acc }, startTime = 0 }, acc
	end

	-- chain-hardcast: 10 back-to-back 1.9s Wraths = 19s active over 19s
	local seg, acc = freshSeg()
	for i = 0, 9 do
		clock = i * 1.9
		start(seg, "me", nil, nil, nil, WRATH)
		clock = (i + 1) * 1.9
		success(seg, "me", nil, nil, nil, WRATH)
	end
	check(math.abs(acc.activity.active - 19) < 0.01,
		("chain-cast credits full cast time (%.1f/19)"):format(acc.activity.active))

	-- the first action of a fight can't credit more than has actually
	-- elapsed, or a 5s window lands on a pull one second old
	seg, acc = freshSeg()
	clock = 1
	success(seg, "me", nil, nil, nil, MOONFIRE)
	check(math.abs(acc.activity.active - 1) < 0.01,
		("opening action credits only elapsed time (%.1f)"):format(acc.activity.active))

	-- instants credit the real gap between them: a caster waiting 1.5s for
	-- the next GCD was never idle
	seg, acc = freshSeg()
	clock = 0
	success(seg, "me", nil, nil, nil, MOONFIRE)
	clock = 1.5
	success(seg, "me", nil, nil, nil, MOONFIRE)
	clock = 3
	success(seg, "me", nil, nil, nil, MOONFIRE)
	check(math.abs(acc.activity.active - 3) < 0.01,
		("instants credit the gap, not a GCD (%.1f)"):format(acc.activity.active))

	-- a channel is one SPELL_CAST_SUCCESS and then silence: the 4s Mind
	-- Flay must not read as 4s of standing still (the old proxy gave 1.6)
	seg, acc = freshSeg()
	clock = 0
	success(seg, "me", nil, nil, nil, MIND_FLAY)
	clock = 4
	success(seg, "me", nil, nil, nil, MOONFIRE)
	check(math.abs(acc.activity.active - 4) < 0.01,
		("a 4s channel counts as 4s active (%.1f)"):format(acc.activity.active))

	-- a dodged swing produces no damage event; it's still an attack
	seg, acc = freshSeg()
	clock = 0
	swing(seg, "me")
	clock = 2.6
	swingMiss(seg, "me")
	clock = 5.2
	swing(seg, "me")
	check(math.abs(acc.activity.active - 5.2) < 0.01,
		("whiffed swings still count (%.1f)"):format(acc.activity.active))

	-- real downtime is still downtime: only the first 5s of a gap counts
	seg, acc = freshSeg()
	clock = 0
	success(seg, "me", nil, nil, nil, WRATH)
	clock = 0.5
	start(seg, "me", nil, nil, nil, WRATH) -- cancelled, never succeeds
	clock = 20
	success(seg, "me", nil, nil, nil, MOONFIRE)
	check(math.abs(acc.activity.active - 5) < 0.01,
		("a 20s gap credits 5s, not 20 (%.1f)"):format(acc.activity.active))

	-- absurd cast spans fall back to the idle window (stale-start guard)
	seg, acc = freshSeg()
	clock = 0
	start(seg, "me", nil, nil, nil, WRATH)
	clock = 30
	success(seg, "me", nil, nil, nil, WRATH)
	check(math.abs(acc.activity.active - 5) < 0.01,
		("a 30s 'cast' is a stale start, not activity (%.1f)"):format(acc.activity.active))

	-- a long legitimate hardcast still credits its full length even when it
	-- runs past the idle window
	seg, acc = freshSeg()
	clock = 0
	start(seg, "me", nil, nil, nil, WRATH)
	clock = 8
	success(seg, "me", nil, nil, nil, WRATH)
	check(math.abs(acc.activity.active - 8) < 0.01,
		("an 8s hardcast credits all 8s (%.1f)"):format(acc.activity.active))

	-- melee chaining reads as continuous
	seg, acc = freshSeg()
	clock = 0
	swing(seg, "me")
	clock = 1
	swing(seg, "me")
	check(math.abs(acc.activity.active - 1) < 0.01,
		("swings credit the gap (%.1f)"):format(acc.activity.active))
end)()

-- 33. Cross-scenario audit fixes (2026-07-24): dungeon-keyed kill-time
-- curves, run-aggregate raid CDs, and the card accounting for every point.
;(function()
	local S = TP.Scoring.Signals

	-- (1) a CM/dungeon boss fight must NOT compare its duration against
	-- the dungeon's FULL-RUN curve (every ~90s boss beat every 274s+ run)
	local savedP = TP.Percentiles
	TP.Percentiles = { encounters = { ["Gate of the Setting Sun"] = { all = {
		killTime = { n = 60, curve = { { 99, 274.8 }, { 50, 420 }, { 10, 700 } } },
	} } } }
	local cmFight = { name = "Raigonn", zone = "Gate of the Setting Sun",
		isBoss = true, duration = 90, difficultyID = 8, players = {} }
	check(TP.Scoring.Engine.KillSpeedPercentile(cmFight) == nil,
		"CM boss fight gets no kill-speed from the run-duration curve")
	TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
	TP.Percentiles = savedP

	-- (3) run aggregation unions raidCdsUsed so the run card stops calling
	-- pressed cooldowns "sat unused"
	local runF = function(cds)
		return { duration = 100, players = {}, totals = { raidCdsUsed = cds } }
	end
	local agg = TP.Scoring.Runs.Aggregate({ runF({ [740] = true }), runF({ [115310] = true }) }, "Run")
	check(agg.totals.raidCdsUsed and agg.totals.raidCdsUsed[740] and agg.totals.raidCdsUsed[115310],
		"run aggregate unions raidCdsUsed across fights")

	-- (4)/(5) charged-but-invisible: a capable player at zero kicks or
	-- dispels still shows the charge as its own verdict row (the Other
	-- rollup retired 2026-07-25)
	local function rowLabeled(sigs, label)
		for _, r in ipairs(sigs) do
			if r.label == label then
				return r
			end
		end
	end
	local zeroKicks = S.ForResult({ role = "DAMAGER",
		adjustDetail = { kicks = -2 }, penaltyDetail = {},
		breakdown = { interrupts = { applicable = true, value = 0 } } },
		{}, { metrics = {} })
	local ki = rowLabeled(zeroKicks, "No interrupts")
	check(ki and ki.points == -2 and ki.kind == "glyph" and ki.key == "kicks",
		"zero kicks with a charge gets its own verdict row")
	local zeroDispels = S.ForResult({ role = "DAMAGER",
		adjustDetail = { dispels = -3 }, penaltyDetail = {},
		breakdown = { dispels = { applicable = true, value = 0 } } },
		{}, { metrics = {} })
	check(rowLabeled(zeroDispels, "No dispels") ~= nil,
		"zero dispels with a charge gets its own verdict row")

	-- (6) a low-demand healer keeps their primary metric as a verdict
	local lowD = S.ForResult({ role = "HEALER", adjustDetail = {}, penaltyDetail = {},
		breakdown = { healing = { applicable = true, lowDemand = true, normalized = 75 } } },
		{}, { metrics = {} })
	local hRow
	for _, r in ipairs(lowD) do
		if r.key == "healing" then
			hRow = r
		end
	end
	check(hRow and hRow.kind == "glyph" and hRow.label == "Little to heal"
		and hRow.b ~= nil and hRow.base,
		"low-demand healer keeps a Healing verdict row with its tooltip")

	-- (8) kicks/dispels rows carry the breakdown for numeric tooltips, and
	-- the dispel COUNT rides the row, not the share score
	local counted = S.ForResult({ role = "DAMAGER", adjustDetail = {}, penaltyDetail = {},
		breakdown = {
			interrupts = { applicable = true, value = 2, opportunities = 4 },
			dispels = { applicable = true, value = 3, normalized = 60 },
		} }, {}, { metrics = {} })
	local kRow, dRow
	for _, r in ipairs(counted) do
		if r.key == "interrupts" then
			kRow = r
		elseif r.key == "dispels" then
			dRow = r
		end
	end
	check(kRow and kRow.b ~= nil and not kRow.base,
		"kicks row carries its breakdown but never joins the Raw view")
	check(dRow and dRow.b ~= nil and dRow.num == "3" and not dRow.base,
		("dispels row shows the count (%s)"):format(tostring(dRow and dRow.num)))

	-- (9) an Aug with no Ebon Might report reads unmeasured, not mid-pack
	local mute = S.ForResult({ role = "SUPPORT", adjustDetail = {}, penaltyDetail = {},
		breakdown = { damage = { applicable = true, normalized = 50, noInput = true, relative = true } } },
		{}, { metrics = {} })
	check(mute[1] and mute[1].label == "Amplified" and mute[1].num == "?",
		("no-input Aug bar wears the '?' (%s %s)"):format(
			tostring(mute[1] and mute[1].label), tostring(mute[1] and mute[1].num)))

	-- base flags: throughput bars join the Raw view, everything else doesn't
	local based = S.ForResult({ role = "DAMAGER", adjustDetail = {}, penaltyDetail = {},
		breakdown = { damage = { applicable = true, pctile = 60, normalized = 60 } } },
		{}, { metrics = { activityPct = 90 } })
	local dmgRow, actRow
	for _, r in ipairs(based) do
		if r.key == "damage" then
			dmgRow = r
		elseif r.key == "activity" then
			actRow = r
		end
	end
	check(dmgRow and dmgRow.base and actRow and not actRow.base,
		"Raw view keeps throughput, drops activity")

	-- Raw GROUP view (Josh 2026-07-24): the group card filters the same
	-- way — group-averaged WCL bars survive, advisors/pips don't
	local gRows = S.GroupRows({
		{ breakdown = { damage = { applicable = true, normalized = 80, value = 100 } },
			penaltyDetail = { deaths = 10 } },
		{ breakdown = { damage = { applicable = true, normalized = 76, value = 100 } },
			penaltyDetail = { deaths = 10 } },
	}, {})
	local gd, gDeaths
	for _, r in ipairs(gRows) do
		if r.key == "damage" then
			gd = r
		elseif r.key == "deaths" then
			gDeaths = r
		end
	end
	check(gd and gd.base, "group damage bar joins the Raw view")
	check(gDeaths and not gDeaths.base, "group deaths pips stay out of Raw")

	-- flask+food left the footer (2026-07-25): a no-point chip counting
	-- only the players whose install reported
	local consRows = S.GroupRows({
		{ guid = "a", breakdown = {} }, { guid = "b", breakdown = {} },
		{ guid = "c", breakdown = {} },
	}, { players = {
		a = { metrics = { consumables = 2 } },
		b = { metrics = { consumables = 1 } },
		c = { metrics = {} }, -- no report: stays out of the denominator
	} })
	local cons
	for _, r in ipairs(consRows) do
		if r.key == "consumables" then
			cons = r
		end
	end
	check(cons and cons.kind == "glyph" and cons.count == "1/2"
		and cons.points == nil and not cons.base,
		("flask+food chip counts reporters only (%s)"):format(tostring(cons and cons.count)))
	local noneRows = S.GroupRows({ { guid = "c", breakdown = {} } },
		{ players = { c = { metrics = {} } } })
	for _, r in ipairs(noneRows) do
		check(r.key ~= "consumables", "no reporters, no flask+food chip")
	end
end)()

-- 34. Single-target externals (2026-07-24): Guardian Spirit / Ironbark
-- answering TANK spikes joins the healer cdTiming pool — gated to specs
-- that own an external, so shamans are never judged on a missing button.
;(function()
	local S = TP.Scoring.Signals

	-- (a) Compute: tank windows + external casts -> per-healer ext fields,
	-- and the tank's band learns who saved them ([8])
	local seg = { startTime = 0, players = {
		tank = { guid = "tank", name = "Pickledrot", role = "TANK", spikes = {
			maxHP = 100000, n = 0, spans = {}, casts = {},
			taken = { [10] = 46000, [40] = 46000 },
			extCasts = { { 11, "Guardian Spirit", "hpriest" } },
		} },
		hpriest = { guid = "hpriest", name = "Beebcat", role = "HEALER", spikes = {
			maxHP = 900000, n = 0, spans = {}, taken = {},
			casts = { 11 }, castNames = { "Guardian Spirit" },
		} },
	} }
	local out = TP.Spikes.Compute(seg, 60)
	local t, h = out.tank, out.hpriest
	check(t and t.spikeWindows == 2 and (t.spikeCovered or 0) == 0,
		("tank fixture: 2 windows, none self-covered (%s/%s)"):format(
			tostring(t and t.spikeWindows), tostring(t and t.spikeCovered)))
	check(t and t.spikeMap[1][8] == "Beebcat's Guardian Spirit" and t.spikeMap[2][8] == nil,
		("tank band [8] names the external (%s)"):format(tostring(t and t.spikeMap[1][8])))
	check(h and h.extWindows == 2 and h.extCovered == 1,
		("healer ext pool: 2 windows, 1 covered (%s/%s)"):format(
			tostring(h and h.extWindows), tostring(h and h.extCovered)))
	check(h and h.groupCdCasts == 1,
		"capacity stamps even without group-wide spikes")

	-- (b) engine gate: same metrics, opposite verdicts by kit — a holy
	-- priest (owns GS) scores the ext pool, a resto shaman (owns none)
	-- is never judged on it
	local function healerFight(specID)
		return { name = "F", isBoss = true, duration = 120, players = {
			h = { guid = "h", name = "H", class = "PRIEST", role = "HEALER", specID = specID,
				metrics = { healing = 1000, extWindows = 4, extCovered = 4, groupCdCasts = 4 } },
			d = { guid = "d", name = "D", class = "MAGE", role = "DAMAGER",
				metrics = { damage = 1000 } },
		} }
	end
	local function cdAdj(specID)
		for _, r in ipairs(TP.Scoring.Engine.ScoreFight(healerFight(specID), {})) do
			if r.guid == "h" then
				return (r.adjustDetail or {}).cdTiming
			end
		end
	end
	check((cdAdj(257) or 0) > 0, "holy priest scores the external pool")
	check(cdAdj(264) == nil, "resto shaman is never judged on a button they lack")

	-- (c) the card row shows the combined pool with one denominator and
	-- names the externals part in the detail
	local sigs = S.ForResult({ role = "HEALER", adjustDetail = { cdTiming = 3 },
		penaltyDetail = {}, breakdown = {} }, {},
		{ specID = 257, metrics = { extWindows = 4, extCovered = 3,
			groupSpikeWindows = 2, groupSpikeCovered = 1, groupCdCasts = 4 } })
	local cdRow
	for _, r in ipairs(sigs) do
		if r.key == "cdTiming" then
			cdRow = r
		end
	end
	check(cdRow and cdRow.num == "4/5",
		("healer row pools group + tank windows (%s)"):format(tostring(cdRow and cdRow.num)))
	check(cdRow and cdRow.detail and cdRow.detail:find("Guardian Spirit", 1, true) ~= nil,
		"detail names the spec's external")
end)()

-- 35. /tp mock: the synthetic raid night must flow through the whole
-- pipeline clean — if the schema drifts, this catches it before Josh
-- clicks a broken card in-game.
;(function()
	loadModule("Data/SpellProfiles_Mists.lua", TP)
	loadModule("Core/MockFight.lua", TP)
	local pulls = TP.MockFight.Build(1000000)
	check(#pulls == 5 and pulls[4].wipe == nil and pulls[5].wipe,
		"mock night: 4 wipes + a kill, called wipe newest")
	local kill = pulls[4]
	local ok, results = pcall(TP.Scoring.Engine.ScoreFight, kill, {})
	check(ok and results and #results == 10,
		("mock kill scores all 10 players (%s)"):format(ok and #results or tostring(results)))
	if ok then
		local byName = {}
		for _, r in ipairs(results) do
			byName[r.name] = r
			local sok, sigs = pcall(TP.Scoring.Signals.ForResult, r, kill, kill.players[r.guid])
			check(sok and #sigs > 0, ("mock signals render for %s"):format(r.name))
		end
		-- the healer external pool and the rogue's death treatment survive
		local h = byName.Grimshade
		check(h and (h.adjustDetail or {}).cdTiming ~= nil,
			"mock holy priest scores cooldown timing")
		local rog = byName.Nightbriar
		check(rog and (rog.penaltyDetail or {}).deaths and rog.penaltyDetail.deaths > 0,
			"mock rogue death is charged")
		local gok, grows = pcall(TP.Scoring.Signals.GroupRows, results, kill)
		check(gok and #grows > 0, "mock group card rows build")
		local cok, gap = pcall(TP.Scoring.Insights.ParseGap, 64,
			kill.players["MOCK-d1"].metrics, kill.duration)
		check(cok and gap and gap.spell == "Ice Lance",
			("mock coach names Ice Lance (%s)"):format(tostring(gap and gap.spell)))
	end
	check(pulls[5].shape and #pulls[5].shape == 40 and pulls[5].calledWipeAt == 330
		and pulls[5].wipeCalledBy == "Thornveil",
		"newest mock record is the called wipe (collapse view by default)")

	-- the RETAIL night: meter + self-report surfaces only, incl. the Aug
	local rp = TP.MockFight.BuildRetail(1000000)
	check(#rp == 4 and rp[4].wipe == nil and rp[1].wipe, "retail mock: 3 wipes + a kill")
	local rkill = rp[4]
	check(rkill.shape == nil and rkill.totals.kickOpportunities == nil,
		"retail mock carries no CLEU-only surfaces")
	local rok, rres = pcall(TP.Scoring.Engine.ScoreFight, rkill, {})
	check(rok and rres and #rres == 12,
		("retail mock kill scores all 12 (%s)"):format(rok and #rres or tostring(rres)))
	if rok then
		local aug, augSigs
		for _, r in ipairs(rres) do
			if r.name == "Emberweave" then
				aug = r
			end
			local sok, sigs = pcall(TP.Scoring.Signals.ForResult, r, rkill, rkill.players[r.guid])
			check(sok and #sigs > 0, ("retail mock signals render for %s"):format(r.name))
			if r.name == "Emberweave" and sok then
				augSigs = sigs
			end
		end
		check(aug and aug.role == "SUPPORT" and aug.breakdown.prescience
			and aug.breakdown.prescience.applicable,
			"retail mock Aug scores Prescience")
		local sawPrescience = false
		for _, s in ipairs(augSigs or {}) do
			if s.key == "prescience" then
				sawPrescience = true
			end
		end
		check(sawPrescience, "retail mock Aug card shows the Prescience row")
		local gok2, grows2 = pcall(TP.Scoring.Signals.GroupRows, rres, rkill)
		check(gok2 and #grows2 > 0, "retail mock group rows build")
	end
	-- wipe pulls withhold the Aug report: the "Amplified ?" pin path
	local wok, wres = pcall(TP.Scoring.Engine.ScoreFight, rp[1], {})
	if wok then
		for _, r in ipairs(wres) do
			if r.name == "Emberweave" then
				check(r.breakdown.damage and r.breakdown.damage.noInput,
					"retail mock wipe Aug pins no-input")
			end
		end
	end
end)()

-- 36. The extrapolated Tanking gauge (2026-07-24): soak + avoidance +
-- shielded + recovery, equal-weighted, provisional population anchors.
;(function()
	local S = TP.Scoring.Signals
	local m = {
		damageTaken = 1000000,
		swingsLanded = 60, swingsAvoided = 40, -- 40% avoidance
		blockedTaken = 100000, absorbedTaken = 200000, selfAbsorbs = 50000,
		-- shielded = 100k + (200k-50k) = 250k -> 250/(1000+250) = 20%
		selfHealing = 350000, -- recovery = (350k+50k)/1000k = 40%
	}
	local sigs = S.ForResult({ role = "TANK", adjustDetail = {}, penaltyDetail = {},
		breakdown = { mitigation = { applicable = true, normalized = 52, value = 57, anchors = { 20, 40, 60 } } } },
		{}, { metrics = m })
	local row
	for _, r in ipairs(sigs) do
		if r.key == "mitigation" then
			row = r
		end
	end
	-- `tier` not `raw` since 2026-07-28: the anchors are crawled WCL
	-- quantiles, so the score is a population percentile and wears the
	-- bracket gauge like damage and healing rather than flat verdict colours
	check(row and row.label == "Mitigation" and row.b and row.base and row.tier,
		("mitigation row reads breakdown.mitigation, base + gauge tier (%s)"):format(
			tostring(row and row.label)))
	check(row and row.tier == row.value,
		("the gauge marker sits at the score (%s vs %s)"):format(
			tostring(row and row.tier), tostring(row and row.value)))
	check(row and row.value == 52,
		("the row's number is the uptime percentile (%s)"):format(tostring(row and row.value)))
	check(row and row.tipText and row.tipText:find("Mitigation up 57%%") ~= nil
		and row.tipText:find("median") ~= nil
		and row.tipText:find("avoided 40%% of 100 attacks") ~= nil,
		("tanking tip leads with WCL uptime, then context (%s)"):format(tostring(row and row.tipText)))

	-- no mitigation data reported: the Tanking row doesn't render at all
	-- (its weight redistributes to damage/healing, like any absence)
	local none = S.ForResult({ role = "TANK", adjustDetail = {}, penaltyDetail = {},
		breakdown = { damage = { applicable = true, pctile = 60 } } }, {}, { metrics = {} })
	local hasT
	for _, r in ipairs(none) do
		if r.key == "mitigation" then hasT = true end
	end
	check(not hasT, "no mitigation data -> no Tanking row")

	-- avoidance no longer double-credits: recovery is judged against
	-- would-have-taken damage (avoided swings priced at the average hit)
	local dc = {
		damageTaken = 1000000,
		swingsLanded = 50, swingsAvoided = 50, -- avg hit 20k -> +1M avoided
		swingDamageTaken = 1000000,
		selfHealing = 500000, -- 500k / (1M + 1M) = 25%, not 50%
		absorbedTaken = 300000, selfAbsorbs = 0,
	}
	local dv = S.TankingComposite(dc, nil)
	-- avoidance 50 + shielded 300/(1000+300)=23.1 + recovery 25 -> /3
	check(dv and math.abs(dv - (50 + 300 / 13 + 25) / 3) < 0.5,
		("recovery prices avoided swings into the denominator (%.1f)"):format(dv or -1))

	-- mitigation uptime is a composite ingredient now (2026-07-25), not
	-- its own row/adjustment: same fixture + 80% uptime lifts the average
	dc.mitigationPct = 80
	local mv, mparts = S.TankingComposite(dc, nil)
	check(mv and math.abs(mv - (50 + 300 / 13 + 25 + 80) / 4) < 0.5,
		("mitigation uptime averages into the composite (%.1f)"):format(mv or -1))
	local mfound
	for _, part in ipairs(mparts or {}) do
		if part:find("mitigation up 80%%") then
			mfound = true
		end
	end
	check(mfound, "the tooltip itemizes the mitigation ingredient")
	dc.mitigationPct = nil

	-- per-spec anchors: the SAME mitigation uptime scores differently by
	-- the spec's own WCL field. 45% uptime is well above a Guardian's field
	-- (median ~24) but below a Blood DK's (median ~56), so the bear ranks
	-- higher for the same number - "equally skilled tanks parse similarly".
	local function tScore(specID)
		local f = { name = "F", duration = 120, players = {
			a = { guid = "a", name = "A", class = "WARRIOR", role = "TANK", specID = specID,
				metrics = { damage = 1000, healing = 1000, mitigationPct = 45 } },
			d = { guid = "d", name = "D", class = "MAGE", role = "DAMAGER", metrics = { damage = 1000 } },
		} }
		for _, r in ipairs(TP.Scoring.Engine.ScoreFight(f, {})) do
			if r.guid == "a" then return r.breakdown.mitigation and r.breakdown.mitigation.normalized end
		end
	end
	local bearS, dkS = tScore(104), tScore(250)
	check(bearS and dkS and bearS > dkS,
		("same uptime ranks by the spec's own field (bear %.0f > DK %.0f)"):format(bearS or -1, dkS or -1))

	-- a tank's Healing is the PLAIN WCL parse again (Josh 2026-07-25 —
	-- the Off-healing split lied in the field; self-sustain is the
	-- Tanking composite's job)
	local thFight = { name = "F", isBoss = true, duration = 120, players = {
		t = { guid = "t", name = "T", class = "DRUID", role = "TANK", specID = 104,
			metrics = { damage = 1000, healing = 900000, selfHealing = 600000,
				selfAbsorbs = 100000, damageTaken = 500000 } },
		d = { guid = "d", name = "D", class = "MAGE", role = "DAMAGER",
			metrics = { damage = 1000, healing = 0 } },
	} }
	for _, r in ipairs(TP.Scoring.Engine.ScoreFight(thFight, {})) do
		if r.guid == "t" then
			check(r.breakdown.healing and r.breakdown.healing.value == 900000,
				("tank healing keeps the WCL-comparable total (%s)"):format(
					tostring(r.breakdown.healing and r.breakdown.healing.value)))
		end
	end
	local function tankHealRow(metrics)
		local sigs2 = S.ForResult({ role = "TANK", adjustDetail = {}, penaltyDetail = {},
			breakdown = { healing = { applicable = true, normalized = 40, pctile = 30, value = 900000 } } },
			{}, { metrics = metrics })
		for _, r in ipairs(sigs2) do
			if r.key == "healing" then
				return r
			end
		end
	end
	for _, metrics in ipairs({ { selfHealing = 600000 }, {} }) do
		local hrow = tankHealRow(metrics)
		check(hrow and hrow.label == "Healing" and not hrow.raw,
			("tank healing reads Healing with brackets, split or not (%s)"):format(
				tostring(hrow and hrow.label)))
	end

	-- stagger purified counts toward recovery in the composite (which feeds
	-- the Tanking tip's context), Josh 2026-07-24
	local mm2 = {
		damageTaken = 1000000,
		swingsLanded = 60, swingsAvoided = 40,
		absorbedTaken = 250000, selfAbsorbs = 0,
		selfHealing = 200000, staggerPurified = 200000, -- recovery = 40%
	}
	local _, bparts = S.TankingComposite(mm2, nil)
	local rec, pur
	for _, part in ipairs(bparts or {}) do
		if part:find("400.0k self%-recovered") then rec = true end
		if part:find("stagger purified") then pur = true end
	end
	check(rec and pur, ("purifies join recovery with the ~ mark (%s / %s)"):format(tostring(rec), tostring(pur)))

	-- the purify estimator: fresh tick x 10 credits, stale ticks don't
	;(function()
		local clock = 100
		GetTime = function()
			return clock
		end
		loadModule("Metrics/Taken.lua", TP)
		local tk
		for _, t in ipairs(TP.Metrics.trackers) do
			if t.subevents and t.subevents.SWING_MISSED then
				tk = t
			end
		end
		check(tk ~= nil, "taken tracker registers miss handlers")
		local acc = { guid = "bm" }
		tk.InitPlayer(acc)
		local seg = { players = { bm = acc }, startTime = 90 }
		-- stagger tick (35k) then an immediate purify: pool ~ 350k
		tk.subevents.SPELL_PERIODIC_DAMAGE(seg, "boss", "bm", nil, nil, 124255, "Stagger", 1, 35000)
		clock = 101
		tk.subevents.SPELL_CAST_SUCCESS(seg, "bm", nil, nil, nil, 119582)
		check(acc.taken.staggerPurified == 350000,
			("fresh purify credits tick x 10 (%s)"):format(tostring(acc.taken.staggerPurified)))
		-- a second purify with no new tick credits nothing
		clock = 102
		tk.subevents.SPELL_CAST_SUCCESS(seg, "bm", nil, nil, nil, 119582)
		check(acc.taken.staggerPurified == 350000, "no fresh tick, no double credit")
		-- a stale tick (pool long empty) credits nothing
		tk.subevents.SPELL_PERIODIC_DAMAGE(seg, "boss", "bm", nil, nil, 124255, "Stagger", 1, 20000)
		clock = 110
		tk.subevents.SPELL_CAST_SUCCESS(seg, "bm", nil, nil, nil, 119582)
		check(acc.taken.staggerPurified == 350000, "stale ticks never credit")
		-- avoided-swing counting rides the same tracker
		tk.subevents.SWING_MISSED(seg, "boss", "bm", nil, nil, "DODGE")
		tk.subevents.SWING_MISSED(seg, "boss", "bm", nil, nil, "ABSORB")
		check(acc.taken.avoided == 1, "dodge counts, full absorb doesn't")
	end)()

	-- the coach speaks human now
	local savedProf2 = TP.SpellProfiles
	TP.SpellProfiles = { [105] = { spells = { { ids = { 774 }, name = "Rejuvenation", cpm = 20 } } } }
	local gap = TP.Scoring.Insights.ParseGap(105, { profCasts = { [774] = 18 } }, 180)
	check(gap and gap.text == "Cast Rejuvenation more often - you average 6/min, top parses 20.",
		("coach text is human (%s)"):format(tostring(gap and gap.text)))
	TP.SpellProfiles = savedProf2
end)()

-- 37. True = WCL percentile + earned adjustments (Josh 2026-07-25): the
-- 30 + 0.7x softener is gone. Zero clamps the bottom; a clamped zero
-- whose unclamped total went NEGATIVE is flagged for the shame-red.
;(function()
	local savedP = TP.Percentiles
	TP.Percentiles = { encounters = { ["Floor Boss"] = { ["3x10"] = {
		dps = { [64] = { n = 500, curve = { { 99, 400000 }, { 50, 200000 }, { 10, 100000 } } } },
		hps = {},
	} } } }
	TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
	local fight = { name = "Floor Boss", isBoss = true, duration = 200, difficultyID = 3,
		players = {
			afk = { guid = "afk", name = "Afk", class = "MAGE", role = "DAMAGER", specID = 64,
				metrics = { damage = 0, healing = 0, deaths = 1 } },
			low = { guid = "low", name = "Low", class = "MAGE", role = "DAMAGER", specID = 64,
				metrics = { damage = 2000000, healing = 0 } }, -- 10k/s: deep below p10
			mid = { guid = "mid", name = "Mid", class = "MAGE", role = "DAMAGER", specID = 64,
				metrics = { damage = 40000000, healing = 0 } }, -- 200k/s = p50
		} }
	local byName = {}
	for _, r in ipairs(TP.Scoring.Engine.ScoreFight(fight, {})) do
		byName[r.name] = r
	end
	check(byName.Mid and math.abs(byName.Mid.base - 50) < 8,
		("p50 base reads ~50, not 65 (%.0f)"):format(byName.Mid and byName.Mid.base or -1))
	check(byName.Low and byName.Low.breakdown.damage.normalized < 15,
		("low output reads its real percentile, no floor (%.0f)"):format(
			byName.Low and byName.Low.breakdown.damage.normalized or -1))
	check(byName.Afk and byName.Afk.score == 0 and (byName.Afk.unclamped or 0) < 0
		and TP.Scoring.Grades.IsShamed(byName.Afk),
		("zero parse + penalties clamps to 0 and wears the shame flag (%.0f/%.1f)"):format(
			byName.Afk and byName.Afk.score or -1, byName.Afk and byName.Afk.unclamped or 0))
	check(not TP.Scoring.Grades.IsShamed(byName.Low),
		"a real (if low) fight is never shamed")
	TP.Scoring.Engine.InvalidateNameIndex(TP.Percentiles)
	TP.Percentiles = savedP
end)()

-- 38. Retail self-coach (2026-07-25): the crawled retail profiles load
-- and drive ParseGap exactly like the MoP ones — structure-only checks,
-- since the cpm values refresh monthly.
;(function()
	local savedProf = TP.SpellProfiles
	TP.SpellProfiles = {}
	loadModule("Data/SpellProfiles.lua", TP)
	local n = 0
	for _ in pairs(TP.SpellProfiles) do
		n = n + 1
	end
	check(n >= 25, ("retail profiles cover the roster (%d specs)"):format(n))
	local mw = TP.SpellProfiles[270]
	check(mw and mw.spells and #mw.spells >= 3, "Mistweaver has a retail profile")
	if mw then
		-- pressing NONE of the watched buttons enough: the coach fires
		local gap = TP.Scoring.Insights.ParseGap(270,
			{ profCasts = { [mw.spells[1].ids[1]] = 1 } }, 300)
		check(gap ~= nil and gap.text:find("more often", 1, true) ~= nil,
			("retail MW coach fires (%s)"):format(tostring(gap and gap.text)))
	end
	TP.SpellProfiles = savedProf
end)()

-- 39. Shareable chat reports (2026-07-25): narrated debriefs, not
-- stat dumps. Phrasing varies by fight seed, so tests assert stable
-- facts and invariants: no player names, no em/en dashes, chat-sized.
;(function()
	local R = TP.Scoring.Reports
	local function alltext(lines)
		return table.concat(lines or {}, " ")
	end
	local wipeFight = {
		name = "Garrosh Hellscream", isBoss = true, wipe = true,
		bossPct = 27, duration = 343, calledWipeAt = 330, wipeCalledBy = "Thornveil",
		totals = { kickOpportunities = 16, kicksLanded = 13, dispels = 14 },
		players = {
			a = { name = "Nightbriar", deathTime = 161, deathTimes = { 161 },
				deathReadyDefensives = 2,
				deathRecap = { { t = 160, spell = "Whirling Corruption", amount = 300000, avoidable = true } },
				metrics = { deaths = 1, groupSpikeWindows = 6, groupSpikeCovered = 4,
					avoidableTaken = 300000, damageTaken = 1000000 } },
			b = { name = "Farshot", deathTimes = { 335 },
				metrics = { deaths = 1, damageTaken = 2000000 } },
			c = { name = "Willowmend", metrics = { deaths = 0, damageTaken = 1000000 } },
		},
	}
	local olderWipe = { name = "Garrosh Hellscream", isBoss = true, wipe = true, bossPct = 41 }
	local wl = R.Run("fight", { fight = wipeFight, runFights = { wipeFight, olderWipe } })
	local wt = alltext(wl)
	check(wt:find("to 27%%", 1, false) ~= nil and (wt:find("Best pull") or wt:find("Deepest push")),
		("wipe opener leads with the best-pull story (%s)"):format(wt))
	check(wt:find("2 died getting there, 1 before the call, the first at 2:41 to avoidable damage", 1, true) ~= nil,
		"deaths and the call read as one sentence")
	check(wt:find("reset just 13 seconds after the call", 1, true) ~= nil, "fast reset praised")
	check(wt:find("damage spikes had no cooldown answer", 1, true) ~= nil
		and wt:find("died with defensives still ready", 1, true) ~= nil,
		("top two concerns picked by salience (%s)"):format(wt))
	check(wt:find("The 27% is real progress", 1, true) ~= nil, "best pull closes encouraging")

	-- a deeper prior pull flips the opener to the honest comparison
	local deeper = { name = "Garrosh Hellscream", isBoss = true, wipe = true, bossPct = 21 }
	local wt2 = alltext(R.Run("fight", { fight = wipeFight, runFights = { wipeFight, deeper } }))
	check(wt2:find("at 27%% this time; the last pull reached 21%%", 1, false) ~= nil,
		("regressed opener (%s)"):format(wt2))

	local killFight = {
		name = "Garrosh Hellscream", isBoss = true,
		duration = 380, prevKillDuration = 392,
		players = { a = { name = "Emberfall", metrics = { deaths = 0 } } },
	}
	local kl = R.Run("fight", {
		fight = killFight,
		runFights = { killFight, wipeFight, wipeFight },
		results = { { name = "Baddchi", score = 99 }, { name = "Beebcat", score = 40 } },
	})
	local kt = alltext(kl)
	check(kt:find("in 6:20", 1, true) ~= nil, ("kill opener carries the time (%s)"):format(kt))
	check(kt:find("It took 3 pulls, the best prior attempt reaching 27%%", 1, false) ~= nil,
		("pulls read as a sentence (%s)"):format(kt))
	check(kt:find("70 out of 100", 1, true) ~= nil, ("score carries its scale (%s)"):format(kt))
	check(kt:find("12 seconds faster than the last kill", 1, true) ~= nil, "speed-up celebrated")

	local one = alltext(R.Run("fight", { fight = killFight, runFights = { killFight } }))
	check(one:find("one pull", 1, true) ~= nil, ("one-pull brag in the opener (%s)"):format(one))

	-- farm-speed one-shots read short and varied, and the defensive nag
	-- never interrupts them (Josh 2026-07-25: five TW bosses read
	-- identically, each closing on "1 player never pressed a defensive")
	local tw = { name = "Mr. Smite", isBoss = true, duration = 62,
		totals = { damage = 2000000 },
		players = {
			a = { name = "TwTank", metrics = { deaths = 0, defensives = 0, damage = 2000000 } },
		} }
	local twt = alltext(R.Run("fight", { fight = tw, runFights = { tw },
		results = { { name = "TwTank", score = 61 } } }))
	check(twt:find("Mr. Smite", 1, true) ~= nil
		and (twt:find("folded", 1, true) or twt:find("Quick work", 1, true)
			or twt:find("barely slowed", 1, true) or twt:find("without much drama", 1, true)),
		("trivial kill reads short and varied (%s)"):format(twt))
	check(twt:find("defensive", 1, true) == nil, "no prep nag on a farm one-shot")
	check(twt:find("61", 1, true) ~= nil and twt:find("score", 1, true) ~= nil
		and twt:find("parse", 1, true) == nil,
		("unranked content says score, not parse (%s)"):format(twt))

	local rl = R.Run("run", {
		zone = "Siege of Orgrimmar",
		runFights = { killFight, wipeFight,
			{ name = "Sha of Pride", isBoss = true, duration = 182, players = {} } },
		results = { { name = "Baddchi", score = 99 } },
	})
	local rt = alltext(rl)
	check(rt:find("Siege of Orgrimmar: 2 kills, 1 wipe, 15:05 of fighting for a run score of 99 out of 100", 1, true) ~= nil,
		("run headline (%s)"):format(rt))
	check(rt:find("2 deaths across the run, and 8%% of the damage taken was avoidable", 1, false) ~= nil,
		("run deaths sentence (%s)"):format(rt))
	check(rt:find("Kicks landed 13 of 16", 1, true) ~= nil, "run kicks sentence")
	check(rt:find("Fastest kill: Sha of Pride at 3:02", 1, true) ~= nil, "fastest kill named")

	local dt = alltext(R.Run("deaths", { fight = wipeFight }))
	check(dt:find("2 deaths on Garrosh Hellscream, the first at 2:41 and the last at 5:35", 1, true) ~= nil,
		("death report header (%s)"):format(dt))
	check(dt:find("One of the killing blows was an avoidable hit", 1, true) ~= nil, "avoidable blow line")
	check(dt:find("1 player died with 2 or more defensives unused", 1, true) ~= nil, "ready-defensives line")

	local pt = alltext(R.Run("prep", { fight = {
		name = "Garrosh Hellscream",
		players = {
			a = { name = "Ready", metrics = { consumables = 2, healthstones = 1 } },
			b = { name = "Naked", metrics = { consumables = 0, healthstones = 0 } },
			c = { name = "NoAddon", metrics = {} },
		},
	} }))
	check(pt:find("1 of 2 brought flask and food, 1 player short", 1, true) ~= nil,
		("prep sentence (%s)"):format(pt))
	check(pt:find("Healthstones eaten: 1 of 2", 1, true) ~= nil, "healthstone sentence")

	-- retail records stamped deathTime=0 on players who never died: the
	-- deaths counter is the authority
	local ghost = alltext(R.Run("deaths", { fight = {
		name = "Edwin VanCleef",
		players = {
			a = { name = "Alive1", deathTime = 0, metrics = { deaths = 0 } },
			b = { name = "Alive2", deathTime = 0, metrics = { deaths = 0 } },
		},
	} }))
	check(ghost == "Nobody died on Edwin VanCleef.",
		("zero-stamped survivors are not deaths (%s)"):format(ghost))

	-- house rules, every report: no names, no em/en dashes, chat-sized
	for _, key in ipairs({ "fight", "run", "deaths", "prep" }) do
		local lines = R.Run(key, { fight = wipeFight, zone = "Siege of Orgrimmar",
			runFights = { wipeFight, olderWipe },
			results = { { name = "Baddchi", score = 99 } } })
		for _, line in ipairs(lines or {}) do
			for _, banned in ipairs({ "Nightbriar", "Farshot", "Willowmend", "Thornveil", "Baddchi" }) do
				check(not line:find(banned, 1, true),
					("report '%s' names nobody (%s)"):format(key, line))
			end
			local EM = string.char(226, 128, 148)
			local EN = string.char(226, 128, 147)
			check(not line:find(EM, 1, true) and not line:find(EN, 1, true),
				("no em/en dashes (%s)"):format(line))
			check(#line < 255 and not line:find("|c", 1, true), "chat-safe line")
		end
	end

	-- determinism: the same fight always reads the same
	local again = alltext(R.Run("fight", { fight = wipeFight, runFights = { wipeFight, olderWipe } }))
	check(again == wt, "same fight, same words")

	check(R.Run("fight", {}) == nil, "no fight, no report")
	check(R.Run("nope", { fight = wipeFight }) == nil, "unknown report key returns nil")

	-- retail can't see brez'd deaths of non-addon players, so a KILL's
	-- zero count proves only "everyone standing at the end" and a
	-- nonzero count is a floor (Josh 2026-07-25). Wipes stay certain.
	TP.Compat.HAS_CLEU = false
	local rk = alltext(R.Run("fight", { fight = killFight, runFights = { killFight },
		results = { { name = "A", score = 61 } } }))
	check(rk:find("everyone standing at the end", 1, true) ~= nil
		and rk:find("deathless", 1, true) == nil,
		("retail kill hedges the deathless claim (%s)"):format(rk))
	local rd = alltext(R.Run("deaths", { fight = killFight }))
	check(rd:find("Everyone was standing when", 1, true) ~= nil,
		("retail death report hedges zero (%s)"):format(rd))
	-- a wipe stays certain even on retail (the dead stay dead)
	local rw = alltext(R.Run("deaths", { fight = { name = "Boss", wipe = true, players = {
		a = { name = "D", deathTime = 30, deathTimes = { 30 }, metrics = { deaths = 1 } } } } }))
	check(rw:find("1 death on Boss", 1, true) ~= nil and rw:find("At least", 1, true) == nil,
		("wipe deaths stay certain on retail (%s)"):format(rw))
	TP.Compat.HAS_CLEU = true
end)()

-- 40. Retail group-spike aggregation from self-reports (2026-07-25):
-- 2+ non-tank reporters spiking at once is a raid mechanic; any
-- reporter's raid-CD cast covers it team-wide
;(function()
	local G = TP.Spikes.GroupWindowsFromReports
	-- one tank spiking steadily + one dps: not enough non-tank voters
	check(G({
		{ role = "TANK", windows = { { 10, 12 }, { 40, 42 } } },
		{ role = "DAMAGER", windows = { { 40, 42 } } },
	}) == nil, "one non-tank voter is not a group spike")

	-- two dps spike together at 40 and 120; a healer CD covers only the
	-- first (cast at 38)
	local win, cds = G({
		{ role = "TANK", windows = { { 5, 7 }, { 40, 42 }, { 120, 122 } } },
		{ role = "DAMAGER", windows = { { 40, 42 }, { 120, 122 } } },
		{ role = "DAMAGER", windows = { { 41, 43 }, { 121, 123 } } },
		{ role = "HEALER", windows = {}, cdCasts = { 38 } },
	})
	check(win and #win == 2, ("two overlapping non-tank spikes = 2 group windows (%s)"):format(
		win and #win or "nil"))
	check(win and win[1][3] == true and win[2][3] == nil,
		"the pre-cast raid CD covers the first window only")
	check(cds == 1, ("raid-CD cast count aggregates (%s)"):format(tostring(cds)))

	-- non-overlapping personal spikes (different mechanics per player)
	-- never form a group window
	check(G({
		{ role = "DAMAGER", windows = { { 10, 12 } } },
		{ role = "HEALER", windows = { { 80, 82 } } },
	}) == nil, "non-overlapping personal spikes are not group spikes")
end)()

-- 41. Death-cause classification (2026-07-25): name the cause so the
-- coach can be constructive. Accuracy scales with crawled profiles;
-- degrades cleanly to one-shot + avoidable-flag without them.
;(function()
	local DC = TP.Scoring.DeathCause
	local profiles = {
		["Annihilate"] = { tankOnly = true, hitRate = 0.1 },
		["Whirling Corruption"] = { hitRate = 0.31 },
		["Melee"] = { hitRate = 1.0 },
		["Desecrated"] = { hitRate = 0.9 },
	}
	-- one-shot outranks everything and is forgiven
	local os = DC.Classify({ { spell = "Iron Star Impact", amount = 1200000 } }, 500000, profiles)
	check(os.category == "oneShot" and os.forgive, ("one-shot forgiven (%s)"):format(os.category))
	-- tankbuster: tank-only hard hit, dominant, NOT forgiven
	local tb = DC.Classify({ { spell = "Melee", amount = 200000 },
		{ spell = "Annihilate", amount = 1900000 } }, 3000000, profiles)
	check(tb.category == "tankbuster" and not tb.forgive and tb.spell == "Annihilate",
		("tankbuster named, not forgiven (%s)"):format(tb.category))
	-- avoidable by low hitRate profile
	local av = DC.Classify({ { spell = "Melee", amount = 80000 },
		{ spell = "Whirling Corruption", amount = 300000 } }, 400000, profiles)
	check(av.category == "avoidable" and av.spell == "Whirling Corruption",
		("avoidable by profile hitRate (%s)"):format(av.category))
	-- avoidable by the per-hit flag, NO profiles (the fallback)
	local avf = DC.Classify({ { spell = "Bad Stuff", amount = 300000, avoidable = true } }, 400000, nil)
	check(avf.category == "avoidable", ("avoidable by flag, no profile (%s)"):format(avf.category))
	-- chip: pile-on, no dominant hit (the 84%-of-deaths case)
	local chip = DC.Classify({ { spell = "Melee", amount = 100000 },
		{ spell = "Desecrated", amount = 110000 }, { spell = "Melee", amount = 95000 },
		{ spell = "Desecrated", amount = 105000 } }, 500000, profiles)
	check(chip.category == "chip", ("pile-on reads as chip (%s)"):format(chip.category))
	-- unknown: a dominant unprofiled non-avoidable hit
	local unk = DC.Classify({ { spell = "Mystery Beam", amount = 400000 },
		{ spell = "Melee", amount = 50000 } }, 900000, profiles)
	check(unk.category == "unknown" and unk.spell == "Mystery Beam",
		("dominant unprofiled hit = unknown (%s)"):format(unk.category))
	check(DC.Classify(nil, 500000, profiles).category == "unknown", "no recap = unknown")

	-- Summarize counts per category
	local sum = DC.Summarize({ { category = "avoidable" }, { category = "avoidable" },
		{ category = "chip" }, { category = "oneShot" } })
	check(sum.total == 4 and sum.avoidable == 2 and sum.chip == 1 and sum.oneShot == 1,
		"Summarize tallies each category")

	-- thresholds table present (a retune must be deliberate)
	check(DC.THRESHOLDS and DC.THRESHOLDS.oneShotHP == 0.9
		and DC.THRESHOLDS.avoidableHitRate == 0.4 and DC.THRESHOLDS.tankbusterHitPct == nil, "threshold constants pinned")

	-- ProfilesFor: encounterID first, then stripped name
	TP.DAMAGE_PROFILES = { ids = { [1623] = "Garrosh Hellscream" },
		["Garrosh Hellscream"] = profiles }
	check(DC.ProfilesFor({ encounterID = 1623 }) == profiles, "profiles resolve by encounterID")
	check(DC.ProfilesFor({ name = "(!) Garrosh Hellscream" }) == profiles, "profiles resolve by stripped name")
	check(DC.ProfilesFor({ name = "Unknown Boss" }) == nil, "no profile for an unknown boss")
	TP.DAMAGE_PROFILES = nil

	-- mechanic coaching (Josh 2026-07-26): name the avoidable ability a
	-- player ate, measured against the crawled field hitRate
	TP.DAMAGE_PROFILES = { ids = { [777] = "Mech Boss" }, ["Mech Boss"] = {
		["Whirling Corruption"] = { hitRate = 0.98 },              -- everyone eats it: not coachable
		["Iron Star"] = { hitRate = 0.20, avgDmg = 240000 },       -- avoidable, most dodge it
	} }
	local mFight = { name = "Mech Boss", duration = 200, encounterID = 777 }
	local mPlayer = { metrics = { avoidableTaken = 300000, damageTaken = 900000, takenByAbility = {
		["Whirling Corruption"] = { amount = 500000, hits = 3 },
		["Iron Star"] = { amount = 300000, hits = 2 },
	} } }
	local mg = TP.Scoring.Insights.MechanicGaps(mPlayer, mFight)
	check(mg and mg.spell == "Iron Star" and mg.hits == 2 and mg.avgDmg == 240000,
		("mechanic coaching names the avoidable hit + carries impact (%s, %s)"):format(
			tostring(mg and mg.spell), tostring(mg and mg.avgDmg)))
	check(TP.Scoring.Insights.MechanicGaps(mPlayer, { name = "Nowhere", duration = 200 }) == nil,
		"no crawled profiles for the encounter -> no mechanic coaching")
	local rmg = TP.Scoring.Insights.MechanicGaps(
		{ metrics = { spikeMap = { { 10, 16, true, nil, 250000, "Iron Star" } } } }, mFight)
	check(rmg and rmg.spell == "Iron Star",
		("retail spike-map fallback names the mechanic (%s)"):format(tostring(rmg and rmg.spell)))
	local mAdv = TP.Scoring.Coach.Advise(
		{ role = "DAMAGER", adjustDetail = { avoidable = -8 },
			breakdown = { damage = { applicable = true, pctile = 55 } } }, mFight, mPlayer)
	check(mAdv and mAdv.text:find("Iron Star", 1, true) and mAdv.text:find("2 times", 1, true)
		and mAdv.text:find("~", 1, true),
		("coach names the mechanic + hits + impact (%s)"):format(tostring(mAdv and mAdv.text)))
	TP.DAMAGE_PROFILES = nil

	-- the raid report names the death CAUSE, not just the count
	local R = TP.Scoring.Reports
	local function avoidableDeath(name, t)
		return { name = name, deathTimes = { t },
			deathRecap = { { t = t - 1, spell = "Bad Puddle", amount = 300000, avoidable = true } },
			metrics = { deaths = 1, damageTaken = 400000 } }
	end
	local avoidWipe = { name = "Boss", isBoss = true, wipe = true, bossPct = 20, duration = 200,
		players = { a = avoidableDeath("A", 60), b = avoidableDeath("B", 90),
			c = avoidableDeath("C", 120) } }
	local at = table.concat(R.Run("fight", { fight = avoidWipe, runFights = { avoidWipe } }) or {}, " ")
	check(at:find("avoidable mechanics", 1, true) ~= nil,
		("avoidable-dominant deaths get named (%s)"):format(at))

	local function chipDeath(name, t)
		return { name = name, deathTimes = { t },
			deathRecap = { { t = t - 3, spell = "Melee", amount = 90000 },
				{ t = t - 2, spell = "Rot", amount = 95000 }, { t = t, spell = "Melee", amount = 88000 } },
			metrics = { deaths = 1, damageTaken = 400000 } }
	end
	local chipWipe = { name = "Boss", isBoss = true, wipe = true, bossPct = 20, duration = 200,
		players = { a = chipDeath("A", 60), b = chipDeath("B", 90), c = chipDeath("C", 120) } }
	local ct = table.concat(R.Run("fight", { fight = chipWipe, runFights = { chipWipe } }) or {}, " ")
	check(ct:find("chip damage", 1, true) ~= nil,
		("chip-dominant deaths read as a healing-gap signal (%s)"):format(ct))
end)()

-- 42. Career epoch reset (Josh 2026-07-28: "reset them on login and let
-- them reaccumulate"). Career totals accumulate at capture, so a scoring
-- change leaves them averaging retired numbers against current ones. The
-- reset must fire ONCE per epoch: a version that re-fires every login would
-- silently keep the player's stats empty forever, which looks identical to
-- the feature simply not working.
;(function()
	local CTP = { Addon = { db = { char = {} }, Print = function() end },
		Events = { Register = function() end } }
	assert(loadfile("Core/Career.lua"))("TrueParse", CTP)
	local db, C = CTP.Addon.db, CTP.Career

	check(C.ResetIfStale() == false, "fresh install announces no reset (nothing to retire)")

	db.char.career = { fights = 99, sumScore = 8000, recent = { 1, 2, 3 } }
	check(C.ResetIfStale() == true, "a store from an older epoch is retired")
	check((db.char.career.fights or -1) == 0, "retired career starts from zero")

	db.char.career.fights, db.char.career.sumScore = 7, 500
	check(C.ResetIfStale() == false, "second login does NOT reset again")
	check(C.ResetIfStale() == false, "nor does the third")
	check(db.char.career.fights == 7, "re-accumulated stats survive later logins")

	db.char.career.epoch = "older-epoch"
	check(C.ResetIfStale() == true, "bumping the epoch retires the store again")
end)()

-- 43. Tank damage scores against the field of TANKS (Josh 2026-07-29). On
-- 219 real MoP fights the damage metric's median was 59.5 for DPS, 59.8 for
-- healers and 26.0 for tanks; the ranked curves are built from tanks who
-- turn up in damage rankings. Data/TankDamage anchors on a share of the
-- raid's damage instead.
;(function()
	local saved = TP.TANK_DAMAGE_ANCHORS
	-- a median tank of this spec does 6% of the raid's damage
	TP.TANK_DAMAGE_ANCHORS = { [73] = { 4, 6, 8 }, default = { 3, 5, 7 } }

	-- The anchors are a SHARE of a raid's damage, so the metric only
	-- applies to raid-sized groups: six players here, five of them DPS
	-- splitting the remainder, with the raid total pinned at 1000 so the
	-- tank's share stays exact.
	local function fightWith(tankDamage, specID)
		local players = {
			t1 = { guid = "t1", name = "Tank", class = "WARRIOR", role = "TANK",
				specID = specID,
				metrics = { damage = tankDamage, healing = 0, damageTaken = 500,
					interrupts = 0, dispels = 0 } },
		}
		for i = 1, 5 do
			local id = "d" .. i
			players[id] = { guid = id, name = (i == 1) and "Dps" or ("Dps" .. i),
				class = "MAGE", role = "DAMAGER",
				metrics = { damage = (1000 - tankDamage) / 5, healing = 0,
					damageTaken = 50, interrupts = 0, dispels = 0 } }
		end
		return { name = "Anchor Test", duration = 300, players = players }
	end
	local function tankDamageScore(f)
		for _, r in ipairs(TP.Scoring.Engine.ScoreFight(f)) do
			if r.name == "Tank" then return r.breakdown and r.breakdown.damage end
		end
	end

	-- 60 of 1000 = 6% = exactly this spec's median
	local mid = tankDamageScore(fightWith(60, 73))
	check(mid and math.abs(mid.normalized - 50) < 0.5,
		("a median tank share scores 50 (%.1f)"):format(mid and mid.normalized or -1))

	-- the same tank doing more, and less
	local hi = tankDamageScore(fightWith(80, 73))
	local lo = tankDamageScore(fightWith(40, 73))
	check(hi.normalized > mid.normalized and mid.normalized > lo.normalized,
		"more damage still scores higher")
	check(math.abs(hi.normalized - 75) < 0.5,
		("p75 share scores 75 (%.1f)"):format(hi.normalized))
	check(math.abs(lo.normalized - 25) < 0.5,
		("p25 share scores 25 (%.1f)"):format(lo.normalized))

	-- an uncrawled spec falls back to the median of the crawled ones
	local unk = tankDamageScore(fightWith(50, 999))
	check(unk and math.abs(unk.normalized - 50) < 0.5,
		("an uncrawled tank spec uses the default anchor (%.1f)"):format(unk and unk.normalized or -1))

	-- no crawled data at all: the ranked curve path is untouched
	TP.TANK_DAMAGE_ANCHORS = {}
	local none = tankDamageScore(fightWith(60, 73))
	check(none and none.normalized ~= nil and math.abs(none.normalized - 50) > 0.5,
		"with no anchors the tank falls back to the old curve path")

	-- DPS are never re-anchored
	TP.TANK_DAMAGE_ANCHORS = { [73] = { 4, 6, 8 }, default = { 3, 5, 7 } }
	local f = fightWith(60, 73)
	local dps
	for _, r in ipairs(TP.Scoring.Engine.ScoreFight(f)) do
		if r.name == "Dps" then dps = r.breakdown.damage end
	end
	check(dps and dps.normalized > 40,
		("a DPS is scored on the curve, not the tank anchor (%.1f)"):format(dps and dps.normalized or -1))

	TP.TANK_DAMAGE_ANCHORS = saved
end)()

print("")
if failures == 0 then
	print("ALL TESTS PASSED")
else
	print(failures .. " FAILURES")
	os.exit(1)
end
