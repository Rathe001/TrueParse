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
	-- The figure is the boss's REMAINING health and now says so. "P2 0%" read
	-- as a kill, and "91%" outranked "47%" while being the worse pull.
	check(mop.WipeLabel(P1) == "wipe 5% left",
		("a single-phase boss labels plainly (%s)"):format(tostring(mop.WipeLabel(P1))))
	check(mop.WipeLabel(P3) == "wipe P3 · 80% left",
		("a refilling boss names the phase (%s)"):format(tostring(mop.WipeLabel(P3))))
	-- PullProgress is the same text without the word, for lines that supply
	-- their own ("boss at ..."). RunSummary used to strip it with a gsub.
	check(mop.PullProgress(P1) == "5% left", "PullProgress drops the wipe word")
	check(mop.PullProgress({}) == nil, "no bossPct, no progress text")

	-- Difficulty labels are derived from difficultyID, because the localized
	-- NAME is nil on every Mists capture. The ids collide across clients, so
	-- the same id must resolve differently per client.
	do
		local h, c = mop.DifficultyParts({ difficultyID = 5 })
		check(h == "10 Heroic" and c == "10H", ("Mists 5 is 10 Heroic (%s/%s)"):format(tostring(h), tostring(c)))
		h, c = mop.DifficultyParts({ difficultyID = 237 })
		check(h == "Celestial" and c == "C", "Mists 237 is Celestial")
		-- id 15 is retail Heroic and means nothing on Mists: no guess
		check(mop.DifficultyParts({ difficultyID = 15 }) == nil, "an id from the other client is not guessed at")
		check(mop.DifficultyParts({}) == nil, "no difficultyID, no label")
		check(mop.DifficultyChip({ difficultyID = 5 }) == "|cff3d8ee010H|r", "the chip carries its colour")
		-- PRACTICE_ANCHOR stamps difficultyID 3 on a dummy session so it can
		-- borrow Iron Juggernaut's bracket to score against. That is a
		-- scoring detail; rendering it claimed Josh had been in a 10-player
		-- Normal raid while he was hitting a dummy in a city.
		check(mop.DifficultyParts({ difficultyID = 3, practice = true }) == nil,
			"a training dummy shows no difficulty, borrowed bracket or not")
		check(mop.DifficultyChip({ difficultyID = 3, practice = true }) == nil,
			"...and no chip either")

		-- PER-DUMMY ANCHORS. A Dungeoneer's dummy is a dungeon rehearsal and a
		-- Raider's golem a raid one; scoring both against a raid patchwerk
		-- measured five-man practice against raiders (Josh 2026-08-08).
		-- Keyed by NPC ID because dummy names are localized and "Training
		-- Dummy" is three different creatures on retail alone.
		local A = mop.PRACTICE_ANCHORS
		check(A and A.raid and A.dungeon, "both practice anchors exist")
		check(mop.PracticeAnchorFor(31146) == A.raid, "a Raider's dummy is raid practice")
		check(mop.PracticeAnchorFor(67127) == A.dungeon, "a plain dummy is dungeon practice")
		-- an unknown dummy must keep the anchor it always had, not move
		check(mop.PracticeAnchorFor(999999) == A.raid, "an unknown dummy keeps the raid anchor")
		check(mop.PracticeAnchorFor(nil) == A.raid, "...and so does a missing id")
		check(mop.PRACTICE_ANCHOR == A.raid, "PRACTICE_ANCHOR still names the raid anchor")
		-- every anchor must exist in THIS client's curve file, or the session
		-- silently scores against nothing
		for tier, anc in pairs(A) do
			local enc = mop.Percentiles and mop.Percentiles.encounters
				and mop.Percentiles.encounters[anc.name]
			check(enc ~= nil, ("the %s anchor (%s) exists in the Mists curves"):format(tier, anc.name))
		end
	end
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
			-- a TOKEN amount of the profiled rotation - a different build, or a
			-- self-report that never attached. Indistinguishable, same answer.
			local token = { profCasts = { [prof.spells[1].ids[1]] = 1 } }
			check(I.ParseGap(specID, token, 300) == nil,
				"no rotation advice when the profile's volume isn't there")
			check(I.RotationGaps(specID, token, 300) == nil,
				"...and no rotation table either")
			-- most of the profile's volume, short on its top spell: coach fires
			local casts = {}
			for i, sp in ipairs(prof.spells) do
				casts[sp.ids[1]] = math.floor((sp.cpm or 0) * 5 * (i == 1 and 0.4 or 0.85))
			end
			local gap = I.ParseGap(specID, { profCasts = casts }, 300)
			check(gap ~= nil,
				("a player running the profiled build still gets advice (%s)")
					:format(gap and gap.spell or "nil"))
		end
	end
end


-- SECRET-VALUE LINT. Midnight returns many values as "secret": comparing one
-- throws, and Lua evaluates `and` left to right, so an IsSecret() guard placed
-- AFTER a comparison never runs. That shipped and crashed a Delve four times
-- (Josh 2026-07-31, FightHistory.lua:882 - `tn ~= "" and not IsSecret(tn)`),
-- and the same shape was sitting in three more places waiting for a secret
-- zone name. This is a source lint because it cannot be exercised headlessly:
-- the crash needs a live client that actually secrets the value.
do
	local files = {
		"Collect/FightHistory.lua", "Collect/SelfCasts.lua", "Collect/Segments.lua",
		"Collect/Sync.lua", "Collect/Threat.lua", "Collect/BlizzardMeter.lua",
		"Core/Compat.lua", "UI/MeterWindow.lua", "UI/BreakdownPanel.lua",
	}
	local bad = {}
	for _, path in ipairs(files) do
		local fh = io.open(path)
		if fh then
			local n = 0
			for line in fh:lines() do
				n = n + 1
				-- the guard's position in the line, and any comparison of the
				-- SAME variable earlier in it
				local at, var = line:find("IsSecret%s*%(%s*([%w_%.]+)%s*%)")
				local name = line:match("IsSecret%s*%(%s*([%w_%.]+)%s*%)")
				if at and name and not line:match("^%s*%-%-") then
					local before = line:sub(1, at - 1)
					local esc = name:gsub("%.", "%%.")
					if before:match(esc .. "%s*[=~<>]=") or before:match(esc .. "%s*[<>]%s") then
						bad[#bad + 1] = ("%s:%d  %s"):format(path, n, line:gsub("^%s+", ""))
					end
				end
			end
			fh:close()
		end
	end
	check(#bad == 0, ("no value is compared before its IsSecret guard%s"):format(
		#bad > 0 and ("\n       " .. table.concat(bad, "\n       ")) or ""))
end

-- Every wire message is built by one format string and read by one pattern,
-- in different halves of Sync.lua, and nothing connects them: a field added
-- to the sender and not the parser is silently dropped forever, on a path no
-- headless test exercises. So take BOTH out of the real source, build a
-- sample message from the sender's format, and require the parser to accept
-- it. (This is how the I: init message is covered - see Sync.lua.)
do
	local src = io.open("Collect/Sync.lua")
	local text = src and src:read("*a") or ""
	if src then src:close() end
	-- plausible values IN ORDER, so the sample looks like real traffic
	local cases = {
		{ letter = "I", desc = "init details (client, interface version)",
			args = { "Player-1-0A8463DA", "retail", "110207" } },
	}
	for _, c in ipairs(cases) do
		local fmt = text:match('%("(' .. c.letter .. ':[^"]+)"%):format')
		local pat = text:match('message:match%("(%^' .. c.letter .. ':[^"]+)"%)')
		if not fmt or not pat then
			check(false, ("%s: wire format sent=%s parsed=%s"):format(
				c.letter, tostring(fmt), tostring(pat)))
		else
			-- "I:1:%s:%s:%d" -> "I:1:Player-...:retail:110207"
			local i = 0
			local msg = fmt:gsub("%%[sd]", function()
				i = i + 1
				return c.args[i] or "?"
			end)
			check(msg:match(pat) ~= nil and i == #c.args,
				("%s wire round-trips: %s"):format(c.letter, c.desc))
		end
	end
end


-- The retail healer-coverage anchors must NOT be listed in the Mists TOC.
-- They are crawled from retail logs; MoP has no coverage crawl yet, so its
-- five-man healers stay on the healing curve. Loading the wrong client's
-- anchors would score MoP healers against a population they never played.
do
	local mists = io.open("TrueParse_Mists.toc")
	local text = mists and mists:read("*a") or ""
	if mists then mists:close() end
	check(not text:find("HealerCoverage"),
		"MoP does not load the retail healer-coverage anchors")
end

-- FIGHT WINDOW. Every per-second rate in the addon divides by this, so an
-- error here moves every score at once and looks like a calibration problem.
-- It shipped exactly that way: Josh's Norushen Heroic kill was stored as 545s
-- against WCL's 360s, because the segment opened when the previous wipe ended
-- and stayed open through the run-back. 191 of those seconds carried zero
-- group damage. The group scored a mean 28.9 points UNDER their real WCL
-- parses at corr 0.27; on the corrected clock, +2.6 at corr 0.86.
do
	local TP = {}
	local chunk = assert(loadfile("Collect/FightHistory.lua"))
	-- FightHistory registers frames at file scope; stub just enough to let it
	-- load, and put the globals back so nothing after this sees them.
	local saved = { CreateFrame = _G.CreateFrame, UnitGUID = _G.UnitGUID,
		GetTime = _G.GetTime, C_Timer = _G.C_Timer, wipe = _G.wipe }
	local stub = setmetatable({}, { __index = function() return function() end end })
	_G.CreateFrame = function()
		return setmetatable({}, { __index = function() return function() return stub end end })
	end
	_G.UnitGUID = _G.UnitGUID or function() return "Player-1-0001" end
	_G.GetTime = _G.GetTime or function() return 1000 end
	_G.C_Timer = _G.C_Timer or { After = function() end, NewTicker = function() return stub end }
	_G.wipe = _G.wipe or function(t) for k in pairs(t) do t[k] = nil end return t end
	local ok, err = pcall(chunk, "TrueParse", TP)
	for k, v in pairs(saved) do _G[k] = v end
	if not ok then print("     load error: " .. tostring(err)) end
	local pick = ok and TP.FightHistory and TP.FightHistory.ChooseFightWindow
	check(type(pick) == "function", "the fight-window chooser is reachable for tests")
	if type(pick) == "function" then
		-- WCL counts the RP intro, so a short lead-in stays on the encounter
		-- window. Norushen Normal really is ~27 dead seconds long.
		local f, t = pick(0, 271, 27, 244)
		check(f == 0 and t == 271, "a short RP intro keeps the encounter window")

		-- 191s of dead air is not an intro. Damage bounds win.
		f, t = pick(0, 545, 191, 355)
		check(f == 191 and t == 355, "a run-back inside the segment is trimmed away")

		-- no encounter events (celestial dungeons): damage bounds are all we have
		f, t = pick(nil, nil, 12, 300)
		check(f == 12 and t == 300, "without encounter events the damage window is used")

		-- no damage buckets at all: never invent a window
		f, t = pick(5, 200, nil, nil)
		check(f == 5 and t == 200, "a missing damage window leaves the encounter window alone")
		f, t = pick(nil, nil, nil, nil)
		check(f == nil and t == nil, "with neither window the segment is left untrimmed")

		-- the boundary is a threshold, not a slope: 60s of dead air is still
		-- an intro, 61 is not. Pinned so a future tweak has to be deliberate.
		f, t = pick(0, 300, 60, 240)
		check(t == 300, "60s of dead air is still treated as an intro")
		f, t = pick(0, 301, 61, 240)
		check(t == 240, "61s of dead air is treated as a run-back")
	end

	-- PLACELESS-vs-PLACELESS re-reads (Josh 2026-08-08). His Spiritflayer
	-- Jin'ma sat in history three times - 08-04, 08-05, 08-07, every copy
	-- placeless, so hasPlacedTwin had nothing to match and the 6-hour resume
	-- replacement was days out of range. The tell is that a re-read reports
	-- IDENTICAL totals; two real kills never do.
	local dup = ok and TP.FightHistory and TP.FightHistory.DuplicatesEarlierCapture
	check(type(dup) == "function", "the placeless dedupe predicate is reachable for tests")
	if type(dup) == "function" then
		local function fight(t)
			return { name = t.name or "Spiritflayer Jin'ma", duration = t.duration or 152,
				capturedAt = t.capturedAt, totals = t.totals or
					{ damage = 20053198, healing = 4682992, damageTaken = 4531303,
						absorbs = 866199, avoidableTaken = 910811 } }
		end
		local original = fight({ capturedAt = 1785896809 }) -- 08-04
		local reread = fight({ capturedAt = 1785982191 }) -- 08-05, same numbers
		check(dup({ original }, reread), "a later capture with identical totals is a re-read")
		check(not dup({ reread }, original),
			"the EARLIEST capture survives - the original is never the duplicate")

		-- the retraction that cost a session: totals CLUSTER because a boss has
		-- a fixed health pool, so near-equal is not equal. And Halkias/Nalthor
		-- really do repeat at the same duration on consecutive days.
		local nearly = fight({ capturedAt = 1785982191,
			totals = { damage = 20049200, healing = 4682992, damageTaken = 4531303,
				absorbs = 866199, avoidableTaken = 910811 } })
		check(not dup({ original }, nearly),
			"totals 0.02% apart are a different kill, not a duplicate")

		-- a bulk-unlocked LFR fight is placeless with no twin and must survive
		local otherBoss = fight({ name = "Someone Else", capturedAt = 1785982191 })
		check(not dup({ original }, otherBoss), "a different boss is never a duplicate")
		local otherLength = fight({ duration = 151, capturedAt = 1785982191 })
		check(not dup({ original }, otherLength), "a different duration is never a duplicate")

		-- an unread session must not look like a duplicate of another unread one
		local zeroA = fight({ capturedAt = 1785896809, totals = {} })
		local zeroB = fight({ capturedAt = 1785982191, totals = {} })
		check(not dup({ zeroA }, zeroB), "two empty captures do not match each other")
	end
end

-- KILL/WIPE VERDICT. ENCOUNTER_END's success flag is a REPORT; a dead boss is
-- the event itself. MoP Celestial dungeons disagree: Josh killed Rattlegore
-- (2026-08-08), ENCOUNTER_END said success=0, and it filed as a wipe at 8.7%
-- because the corpse detector was gated on seg.bossEngaged - which the
-- boss-frame fallback only sets when there is NO encounterID. Real encounter
-- events therefore silenced the one signal that could contradict the flag.
do
	-- mirrors Collect/FightHistory.lua's `wiped`
	local function wiped(encounterWipe, bossKilled)
		return (encounterWipe and not bossKilled) or nil
	end
	check(wiped(nil, nil) == nil, "a clean kill is not a wipe")
	check(wiped(true, nil) == true, "success=0 with no corpse is a wipe")
	check(wiped(true, true) == nil, "a dead boss outranks success=0")
	check(wiped(nil, true) == nil, "success=1 with a corpse is still a kill")

	-- the gate that caused it: boss deaths must be tracked whenever the boss
	-- GUIDs are known, NOT only on boss-frame-fallback fights
	local src = io.open("Metrics/Utility.lua")
	local text = src and src:read("*a") or ""
	if src then src:close() end
	check(not text:find("seg%.bossEngaged and seg%.bossGUIDs"),
		"boss deaths are tracked on encounter fights too, not just fallback ones")

	-- and a bogus wipe flag must not hand a KILL the avoidable-damage
	-- forgiveness a real collapse earns
	local fh = io.open("Collect/FightHistory.lua")
	local ftext = fh and fh:read("*a") or ""
	if fh then fh:close() end
	check(not ftext:find("seg%.encounterWipe and seg%.manualWipeAt"),
		"the wipe-call path respects the corpse, so a kill forgives nothing")
end

print("")
if failures > 0 then
	print(("%d/%d CHECKS FAILED"):format(failures, checks))
	os.exit(1)
end
print(("ALL %d MOCK CHECKS PASSED"):format(checks))
