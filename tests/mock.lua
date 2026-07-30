-- Score the synthetic raid nights /tp mock injects, on BOTH clients, and
-- assert the whole thing still holds together (Josh 2026-07-30: "we built out
-- a whole bunch of mock data before, can we run some tests to assert that all
-- of our scores are accurate still?").
--
-- MockFight.Build / BuildRetail are pure functions of `now`, which is what
-- makes this possible headlessly. The fixtures are hand-built to exercise
-- every card surface: a kill on top of wipes, a called collapse, lust
-- windows, coverage strips, an Augmentation Evoker, tanks with mitigation.
-- That breadth is the point - this catches a scoring change that quietly
-- breaks one role or one client, which the invariant fuzzer in validate.lua
-- cannot, because its fights are randomised rather than shaped.
--
-- Run: lua tests/mock.lua
local failures, checks = 0, 0
local function check(cond, msg)
	checks = checks + 1
	if cond then
		print("ok   " .. msg)
	else
		failures = failures + 1
		print("FAIL " .. msg)
	end
end

local DATA = { "Benchmarks", "Percentiles", "Percentiles_Dungeons", "Percentiles_LFR",
	"Percentiles_Sporefall", "Percentiles_Mists", "KillTimes", "KillTimes_LFR",
	"KillTimes_Sporefall", "KillTimes_Mists", "Totals", "Totals_Sporefall",
	"Totals_Dungeons", "Totals_Mists", "Potions", "GroupBuffs", "Defensives",
	"Mitigation", "Mitigation_Mists", "Lust", "HealerCDs", "SpellProfiles",
	"SpellProfiles_Mists", "Overheal", "Overheal_Mists", "DamageProfiles",
	"DamageProfiles_Mists", "TankAnchors", "TankAnchors_Mists", "TankDamage",
	"TankDamage_Mists", "ProcExclusions_Mists" }

-- one fully-loaded addon namespace per client
local function build(isRetail)
	local TP = { Compat = { HAS_CLEU = not isRetail, IS_RETAIL = isRetail,
		IsSecret = function() return false end } }
	local function load(path)
		local f = loadfile(path)
		if f then f("TrueParse", TP) end -- absent data files are optional
	end
	for _, m in ipairs({ "Core/Constants", "Core/Utils", "Scoring/Capabilities",
		"Scoring/Weights", "Scoring/Engine", "Scoring/Grades", "Scoring/Runs",
		"Scoring/Signals", "Scoring/Bullets", "Scoring/Insights", "Scoring/DeathCause",
		"Scoring/Awards", "Scoring/Coach" }) do
		load(m .. ".lua")
	end
	for _, d in ipairs(DATA) do load("Data/" .. d .. ".lua") end
	load("Core/MockFight.lua")
	return TP
end

local function scoreNight(TP, pulls, label)
	print("")
	print("=== " .. label .. " ===")
	local roleScores, everyScore = {}, {}
	local kill, worstWipe
	for _, f in ipairs(pulls) do
		local ok, results = pcall(TP.Scoring.Engine.ScoreFight, f, { mode = "true" })
		check(ok, ("%s scores without error (%s)"):format(f.name or "?", ok and "ok" or tostring(results)))
		if not ok then return end
		check(#results > 0, ("%s produced results (%d)"):format(f.name or "?", #results))
		local sum = 0
		for _, r in ipairs(results) do
			everyScore[#everyScore + 1] = r.score
			roleScores[r.role] = roleScores[r.role] or {}
			table.insert(roleScores[r.role], r.score)
			sum = sum + r.score
			-- a NaN compares false to itself; a nil would error above
			if r.score ~= r.score then
				check(false, ("%s: %s scored NaN"):format(f.name or "?", r.name or "?"))
			end
		end
		local avg = sum / #results
		print(("   %-26s %3ds  %-6s n=%-3d avg %5.1f"):format(
			(f.name or "?") .. (f.wipe and " (wipe)" or ""), f.duration or 0,
			f.wipe and "wipe" or "KILL", #results, avg))
		if f.wipe then
			if not worstWipe or avg < worstWipe then worstWipe = avg end
		else
			kill = avg
		end
	end

	local lo, hi = math.huge, -math.huge
	for _, s in ipairs(everyScore) do
		lo, hi = math.min(lo, s), math.max(hi, s)
	end
	check(lo >= 0 and hi <= 100, ("every score inside [0,100] (%.1f .. %.1f)"):format(lo, hi))
	check(hi > lo, ("scores actually spread, not all pinned (%.1f .. %.1f)"):format(lo, hi))
	-- a night where every single player lands mid-pack means the curves
	-- stopped resolving and everything fell to an imputed default
	local mid = 0
	for _, s in ipairs(everyScore) do
		if s > 45 and s < 55 then mid = mid + 1 end
	end
	check(mid < #everyScore * 0.6,
		("not everyone collapsed onto the neutral pin (%d of %d in 45-55)"):format(mid, #everyScore))
	-- NOT asserted: that the kill outscores the wipes. TrueParse grades what
	-- a player DID, not whether the pull succeeded, and the fixture gives
	-- every pull the same per-second rates - so they score alike by design.
	-- NOT asserted either: that no role sits at the ceiling. The mock healers
	-- are deliberately about twice their spec median (188-214k/s against
	-- 98-110k/s), because the fixture exists to light up card surfaces. They
	-- parse 99 correctly.
	for role, list in pairs(roleScores) do
		table.sort(list)
		local med = list[math.ceil(#list / 2)]
		print(("   %-8s n=%-3d min %5.1f  median %5.1f  max %5.1f"):format(
			role, #list, list[1], med, list[#list]))
		check(med > 5, ("%s median is not floored (%.1f)"):format(role, med))
	end
	return roleScores
end

-- THE accuracy check: within a role, ranking by the primary metric's raw rate
-- must agree with ranking by that metric's percentile. Adjustments (deaths,
-- flask, cooldowns) legitimately reorder FINAL scores, so this tests the
-- measurement rather than the grade. A curve that stopped resolving, an
-- inverted comparison, or a broken interpolation all break this and nothing
-- else in the suite would notice.
local function checkMonotone(TP, fight, label)
	local byRole = {}
	for _, r in ipairs(TP.Scoring.Engine.ScoreFight(fight, { mode = "true" })) do
		local p = fight.players[r.guid]
		local m = p and p.metrics or {}
		local key = (r.role == "HEALER") and "healing" or "damage"
		local b = r.breakdown[key]
		if b and b.pctile and (fight.duration or 0) > 0 then
			local rate = (key == "healing")
				and ((m.healing or 0) + (m.absorbs or 0)) / fight.duration
				or (m.damage or 0) / fight.duration
			byRole[r.role] = byRole[r.role] or {}
			table.insert(byRole[r.role], { name = r.name, rate = rate, pct = b.pctile,
				median = b.specMedian })
		end
	end
	for role, list in pairs(byRole) do
		if #list > 1 then
			table.sort(list, function(a, b) return a.rate > b.rate end)
			local bad, prev = nil, nil
			for _, e in ipairs(list) do
				-- same spec only: cross-spec percentiles are supposed to
				-- diverge from raw rate, that is the whole point of them
				if prev and e.median and prev.median
					and math.abs(e.median - prev.median) < 1 and e.pct > prev.pct + 0.001 then
					bad = ("%s (%.0f/s -> p%.1f) outranks %s (%.0f/s -> p%.1f)")
						:format(e.name, e.rate, e.pct, prev.name, prev.rate, prev.pct)
				end
				prev = e
			end
			check(bad == nil, ("%s %s: more output never scores lower%s"):format(
				label, role, bad and (" -- " .. bad) or ""))
		end
		-- a resolved curve is what makes the number a percentile at all
		local withMedian = 0
		for _, e in ipairs(list) do
			if e.median and e.median > 0 then withMedian = withMedian + 1 end
		end
		check(withMedian == #list,
			("%s %s: every scored player got a spec median (%d/%d)"):format(
				label, role, withMedian, #list))
	end
end

print("TrueParse mock-night scoring")

-- MoP / Classic: full CLEU night, 4 Garrosh wipes + a kill
local mop = build(false)
check(mop.MockFight ~= nil, "MockFight loads headlessly (Classic)")
local mopNight = mop.MockFight.Build(1785000000)
check(#mopNight == 5, ("Classic night has 5 pulls (%d)"):format(#mopNight))
scoreNight(mop, mopNight, "Classic: Garrosh night")
checkMonotone(mop, mopNight[4], "Classic")
-- a ranked raid boss at a real bracket is a DIRECT comparison; a derived tier
-- here would mean the curve lookup silently stopped finding Garrosh
for _, r in ipairs(mop.Scoring.Engine.ScoreFight(mopNight[4], { mode = "true" })) do
	check(r.derived == nil,
		("Classic: %s scores tier 1 DIRECT off the real curve (%s)"):format(
			r.name, tostring(r.derived)))
	break
end

-- Retail / Midnight: meter + self-report shapes, includes an Aug Evoker
local rt = build(true)
check(rt.MockFight ~= nil, "MockFight loads headlessly (retail)")
local rtNight = rt.MockFight.BuildRetail(1785000000)
check(#rtNight == 4, ("retail night has 4 pulls (%d)"):format(#rtNight))
scoreNight(rt, rtNight, "Retail: Belo'ren night")
checkMonotone(rt, rtNight[4], "Retail")

-- The run aggregate is what the scorecard's Run row shows; it must survive
-- the same fights it was built from.
do
	local ok, run = pcall(mop.Scoring.Runs.Aggregate, mopNight, "Siege of Orgrimmar")
	check(ok and run ~= nil, "the Classic night aggregates into a run")
	if ok and run then
		local ok2, res = pcall(mop.Scoring.Engine.ScoreFight, run, { mode = "true" })
		check(ok2 and #res > 0, ("the run aggregate scores (%d players)"):format(ok2 and #res or 0))
	end
end

-- Client-specific copy: Mists has no Mythic+ at all - Warcraft Logs ranks its
-- Challenge Modes - so tier text naming M+ was describing a system that does
-- not exist there (Josh 2026-07-30).
check(mop.RANKED_DUNGEON_TIER == "Challenge Mode",
	("Classic names Challenge Mode, not Mythic+ (%s)"):format(tostring(mop.RANKED_DUNGEON_TIER)))
check(rt.RANKED_DUNGEON_TIER == "Challenge Mode" or rt.RANKED_DUNGEON_TIER == "Mythic+",
	("retail names a ranked dungeon tier (%s)"):format(tostring(rt.RANKED_DUNGEON_TIER)))


print("")
if failures > 0 then
	print(("%d/%d CHECKS FAILED"):format(failures, checks))
	os.exit(1)
end
print(("ALL %d MOCK CHECKS PASSED"):format(checks))
