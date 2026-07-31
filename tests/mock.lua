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
	"KillTimes_Sporefall", "KillTimes_Mists", "KillTimes_Mists_Dungeons",
	"Benchmarks_Mists", "Totals", "Totals_Sporefall",
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


-- Celestial proc exclusions, and the name collision in them. "Earthquake" is
-- both Niuzao's dungeon proc and Elemental Shaman's AoE, so the name rule
-- must NOT strip the Shaman spell (Josh 2026-07-30).
do
	local TPm = { Compat = { HAS_CLEU = true, IS_RETAIL = false } }
	local f = loadfile("Data/ProcExclusions_Mists.lua")
	if f then
		f("TrueParse", TPm)
		for _, n in ipairs({ "Serpent's Jadefire", "Xuen's Ferocity", "Blazing Song",
			"Burning Song" }) do
			check(TPm.IsExcludedProc(nil, n) == true,
				("celestial proc excluded by name: %s"):format(n))
		end
		-- Niuzao's proc is off until its id is confirmed: a name rule cannot
		-- tell it from Elemental Shaman's Earthquake, and SoO is where that
		-- spell earns real damage.
		check(TPm.IsExcludedProc(nil, "Earthquake") == false,
			"Earthquake is NOT excluded by name (Shaman collision)")
		check(TPm.IsExcludedProc(nil, "Fireball") == false,
			"an ordinary spell is not excluded")
		check(TPm.IsExcludedProc(148008, "Essence of Yu'lon") == false,
			"the legendary cloak proc is still counted")
	end
end


-- A kill-times-only encounter entry is NOT "this dungeon's curves". The
-- KillTimes_*_Dungeons files merge run durations into TP.Percentiles.encounters,
-- which made MoP Challenge Modes read as tier II "this dungeon's real curves"
-- while actually scoring against pooled raid logs (Josh 2026-07-30).
do
	local E = mop.Percentiles and mop.Percentiles.encounters
	if E then
		local zone = "Gate of the Setting Sun"
		check(E[zone] ~= nil, "the dungeon zone has an encounter entry (kill times)")
		local f = { name = "Raigonn", isBoss = true, duration = 113, zone = zone,
			instanceType = "party", difficultyID = 237,
			players = { d = { guid = "d", name = "D", class = "MAGE", role = "DAMAGER",
				specID = 62, ilvl = 511, metrics = { damage = 5e6, healing = 0,
					damageTaken = 1e5, interrupts = 0, dispels = 0, deaths = 0 } } } }
		local r = mop.Scoring.Engine.ScoreFight(f, { mode = "true" })[1]
		check(r and r.derived == 3,
			("a kill-times-only dungeon is tier III, not II (%s)"):format(tostring(r and r.derived)))
		check(r == nil or r.derivedFrom == nil,
			("...and does not claim the dungeon's own curves (%s)"):format(tostring(r and r.derivedFrom)))
	end
end


-- THREAT RULES, simulated. Collect/Threat.lua creates frames at load and
-- cannot run headlessly, so this replays its rip decision over synthetic
-- sample streams. It MIRRORS the source - change one, change both - and the
-- constants are read back out of the file so at least those cannot drift.
-- It exists because adding rip tolerance quietly broke two boundary cases
-- (2026-07-30): a streak that began inside the grace, or inside the pull
-- window, was never a rip before and briefly became one afterwards.
do
	local fh = io.open("Collect/Threat.lua")
	local src = fh and fh:read("a") or ""
	if fh then fh:close() end
	local RIP_TICKS = tonumber(src:match("local RIP_TICKS%s*=%s*(%d+)")) or -1
	local GRACE = tonumber(src:match("local TANK_PICKUP_GRACE%s*=%s*(%d+)")) or -1
	local PULL_WINDOW = tonumber(src:match("local PULL_WINDOW%s*=%s*(%d+)")) or -1
	check(RIP_TICKS == 2, ("threat: RIP_TICKS is 2 (%d)"):format(RIP_TICKS))
	check(GRACE == 3, ("threat: TANK_PICKUP_GRACE is 3 (%d)"):format(GRACE))
	check(PULL_WINDOW == 4, ("threat: PULL_WINDOW is 4 (%d)"):format(PULL_WINDOW))

	local function run(samples)
		local a = { rips = 0, has = false, ripTicks = 0 }
		for _, s in ipairs(samples) do
			if s.earned then
				if not a.has then
					a.ripTicks = 0
					a.ripFree = (s.inGrace
						or (s.elapsed <= PULL_WINDOW and not s.tankOpened)) or nil
				end
				if s.elapsed <= PULL_WINDOW and not s.tankOpened then -- pull branch
				elseif not s.inGrace then
					a.ripTicks = a.ripTicks + 1
					if a.ripTicks == RIP_TICKS and not a.ripFree then
						a.rips = a.rips + 1
					end
				end
			end
			if not s.earned then a.ripTicks = 0 end
			a.has = s.earned or false
		end
		return a.rips
	end
	local function S(n, t)
		local o = {}
		for i = 1, n do
			local c = {}
			for k, v in pairs(t) do c[k] = v end
			c.elapsed = (t.elapsed or 10) + i - 1
			o[i] = c
		end
		return o
	end
	local function cat(...)
		local o = {}
		for _, l in ipairs({ ... }) do for _, e in ipairs(l) do o[#o + 1] = e end end
		return o
	end
	local function ck(got, want, msg)
		check(got == want, ("threat: %s (got %d, want %d)"):format(msg, got, want))
	end
	local OPEN = { earned = true, elapsed = 10, tankOpened = true }
	ck(run(S(1, OPEN)), 0, "one sample of aggro is a hand-off, not a rip")
	ck(run(S(2, OPEN)), 1, "two consecutive samples IS a rip")
	ck(run(S(9, OPEN)), 1, "a long hold charges exactly one rip")
	ck(run(cat(S(3, OPEN), S(1, { earned = false, elapsed = 13, tankOpened = true }),
		S(3, { earned = true, elapsed = 14, tankOpened = true }))), 2,
		"two separate episodes = two rips")
	ck(run(S(6, { earned = true, inGrace = true, elapsed = 10, tankOpened = true })), 0,
		"aggro entirely inside grace is never a rip")
	ck(run(cat(S(2, { earned = true, inGrace = true, elapsed = 10, tankOpened = true }),
		S(6, { earned = true, elapsed = 12, tankOpened = true }))), 0,
		"a streak begun in grace stays free after grace ends")
	ck(run(cat(S(2, { earned = false, inGrace = true, elapsed = 10, tankOpened = true }),
		S(6, { earned = true, elapsed = 12, tankOpened = true }))), 1,
		"a NEW streak after grace is charged")
	ck(run(S(6, { earned = true, elapsed = 1, tankOpened = false })), 0,
		"aggro during the pull window is a pull, not a rip")
	ck(run(cat(S(4, { earned = true, elapsed = 1, tankOpened = false }),
		S(6, { earned = true, elapsed = 5, tankOpened = false }))), 0,
		"holding ACROSS the pull-window boundary is not a rip")
end


-- PHASE-AWARE WIPE DEPTH. A boss whose health refills between phases reports
-- a percentage of the CURRENT phase, so raw percentages cannot be ranked: on
-- Garrosh a 207s wipe read 79.6% and a 481s wipe read 5.2%, and comparing the
-- numbers alone made the shorter pull look deeper (Josh 2026-07-30).
do
	local P1 = { bossPct = 5.2 }
	local P3 = { bossPct = 79.6, bossPhase = 3 }
	local P3deep = { bossPct = 5.2, bossPhase = 3 }
	check(mop.PullDepth(P1) ~= nil and mop.PullDepth(P3) ~= nil, "PullDepth reads both")
	check(mop.PullDepth(P3) > mop.PullDepth(P1),
		("phase 3 at 79.6%% is deeper than phase 1 at 5.2%% (%.0f > %.0f)")
			:format(mop.PullDepth(P3), mop.PullDepth(P1)))
	check(mop.PullDepth(P3deep) > mop.PullDepth(P3),
		"within a phase, lower health is still deeper")
	check(mop.PullDepth({}) == nil, "no bossPct, no depth")
	check(mop.WipeLabel(P1) == "wipe 5%",
		("a single-phase boss labels plainly (%s)"):format(tostring(mop.WipeLabel(P1))))
	check(mop.WipeLabel(P3) == "wipe P3 80%",
		("a refilling boss names the phase (%s)"):format(tostring(mop.WipeLabel(P3))))
	check(mop.WipeLabel({}) == nil, "no bossPct, no label")
end


-- A SPEC'S PROFILE MUST DESCRIBE THE BUILD BEING PLAYED. Some specs run two
-- rotations sharing almost no buttons: a Fistweaver Mistweaver melees to heal
-- and casts essentially none of the caster spells the profile is built from.
-- The card told Josh to press four spells more while scoring his healing 99
-- (2026-07-31). The nil-guard was meant to catch it but the cast watch set
-- spans EVERY spec, so his Windwalker-shared buttons kept profCasts non-nil.
do
	local I = mop.Scoring and mop.Scoring.Insights
	if I and mop.SpellProfiles then
		local specID, prof
		for id, pr in pairs(mop.SpellProfiles) do
			if pr.spells and #pr.spells >= 2 then specID, prof = id, pr break end
		end
		if specID then
			local mine = prof.spells[1].ids[1]
			-- casts ONLY spells from some other spec's profile
			local wrongBuild = { profCasts = { [999999] = 40 } }
			check(I.ParseGap(specID, wrongBuild, 300) == nil,
				"no rotation advice when none of the spec's own spells were cast")
			check(I.RotationGaps(specID, wrongBuild, 300) == nil,
				"...and no rotation table either")
			-- casts its own rotation, just not enough: advice IS appropriate
			local sameBuild = { profCasts = { [mine] = 1 } }
			local gap = I.ParseGap(specID, sameBuild, 300)
			check(gap ~= nil,
				("a player running the profiled build still gets advice (%s)")
					:format(gap and gap.spell or "nil"))
		end
	end
end


print("")
if failures > 0 then
	print(("%d/%d CHECKS FAILED"):format(failures, checks))
	os.exit(1)
end
print(("ALL %d MOCK CHECKS PASSED"):format(checks))
