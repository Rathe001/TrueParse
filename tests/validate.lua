-- Score validation across every scenario the addon can meet.
--
-- The method is a ROUND TRIP. For a given encounter+bracket+spec we know the
-- shipped curve exactly, so we can synthesise a player whose per-second
-- output IS the curve's p75 value — and then ask the engine what percentile
-- it thinks that player hit. Anything other than ~75 is calibration error we
-- can measure instead of argue about.
--
-- Raw mode is the honest test of the percentile machinery (it reports the
-- percentile directly). True mode is reported alongside so the two lenses can
-- be compared, but its number legitimately differs — it carries adjustments.
--
-- Usage (from the repo root):  lua tests/validate.lua [--verbose]
local VERBOSE = (arg and arg[1] == "--verbose")

local function build(files, compat)
	local TP = {}
	for _, f in ipairs(files) do
		local chunk = assert(loadfile(f), "cannot load " .. f)
		chunk("TrueParse", TP)
	end
	TP.Compat = compat
	return TP
end

local CORE = { "Core/Constants.lua", "Core/Utils.lua" }
local SCORING = { "Scoring/Capabilities.lua", "Scoring/Weights.lua",
	"Scoring/Engine.lua", "Scoring/Grades.lua" }

local function files(dataFiles)
	local out = {}
	for _, f in ipairs(CORE) do out[#out + 1] = f end
	for _, f in ipairs(dataFiles) do out[#out + 1] = f end
	for _, f in ipairs(SCORING) do out[#out + 1] = f end
	return out
end

local CLIENTS = {
	retail = build(files({
		"Data/Benchmarks.lua", "Data/Percentiles.lua", "Data/Percentiles_Dungeons.lua",
		"Data/Percentiles_LFR.lua", "Data/Percentiles_Sporefall.lua",
		"Data/Totals.lua", "Data/Totals_Dungeons.lua", "Data/Totals_Sporefall.lua",
		"Data/TankAnchors.lua",
	}), { HAS_CLEU = false, IS_RETAIL = true }),
	mists = build(files({
		"Data/Benchmarks_Mists.lua", "Data/Percentiles_Mists.lua",
		"Data/Percentiles_Mists_25.lua", "Data/Totals_Mists.lua",
		"Data/TankAnchors_Mists.lua",
	}), { HAS_CLEU = true, IS_RETAIL = false }),
}

-- ---------------------------------------------------------------- scenarios
-- Each names real shipped data, so a scenario that stops existing after a
-- recrawl fails loudly rather than silently testing nothing.
local SCENARIOS = {
	{ client = "retail", label = "Raid · LFR",          bracket = "1",   difficultyID = 17, itype = "raid",  tier = 1 },
	{ client = "retail", label = "Raid · Normal",       bracket = "3",   difficultyID = 14, itype = "raid",  tier = 1 },
	{ client = "retail", label = "Raid · Heroic",       bracket = "4",   difficultyID = 15, itype = "raid",  tier = 1 },
	{ client = "retail", label = "Raid · Mythic",       bracket = "5",   difficultyID = 16, itype = "raid",  tier = 1 },
	{ client = "retail", label = "Dungeon · M+ key",    bracket = "all", difficultyID = 8,  itype = "party", tier = 1, dungeon = true, keystone = 10 },
	{ client = "retail", label = "Dungeon · Heroic",    bracket = "all", difficultyID = 2,  itype = "party", tier = 2, dungeon = true },
	{ client = "retail", label = "Dungeon · Normal",    bracket = "all", difficultyID = 1,  itype = "party", tier = 2, dungeon = true },
	{ client = "retail", label = "Dungeon · Timewalk",  bracket = "all", difficultyID = 24, itype = "party", tier = 3, dungeon = true, unranked = true },
	{ client = "mists",  label = "SoO · 10 Normal",     bracket = "3x10", difficultyID = 3, itype = "raid",  tier = 1 },
	{ client = "mists",  label = "SoO · 25 Normal",     bracket = "3x25", difficultyID = 4, itype = "raid",  tier = 1 },
	{ client = "mists",  label = "SoO · 10 Heroic",     bracket = "4x10", difficultyID = 5, itype = "raid",  tier = 1 },
	{ client = "mists",  label = "SoO · 25 Heroic",     bracket = "4x25", difficultyID = 6, itype = "raid",  tier = 1 },
	{ client = "mists",  label = "Celestial dungeon",   bracket = "3x10", difficultyID = 237, itype = "party", tier = 3, dungeon = true, unranked = true },
}

-- ------------------------------------------------------------------ helpers
local function curveValueAt(curve, pct)
	for _, pt in ipairs(curve) do
		if pt[1] == pct then return pt[2] end
	end
end

-- Find a real encounter+spec in this client's data for the wanted bracket.
local function pickCurve(TP, bracket, dungeon, wantRole)
	local P = TP.Percentiles
	local roles = TP.SPEC_ROLES or {}
	local names = {}
	for name in pairs(P.encounters) do names[#names + 1] = name end
	table.sort(names) -- deterministic pick
	for _, name in ipairs(names) do
		local enc = P.encounters[name]
		local isDungeonKeyed = type(enc.all) == "table"
		for k, v in pairs(enc) do
			if k ~= "all" and k ~= "_mono" and type(v) == "table" then
				isDungeonKeyed = false
			end
		end
		if dungeon == nil or dungeon == isDungeonKeyed then
			local b = enc[bracket or "all"]
			if type(b) == "table" and b.dps and b.hps then
				local specs = {}
				for id in pairs(b.dps) do specs[#specs + 1] = id end
				table.sort(specs)
				for _, id in ipairs(specs) do
					local d, h = b.dps[id], b.hps[id]
					if (not wantRole or roles[id] == wantRole)
						and d and d.curve and curveValueAt(d.curve, 50)
						and h and h.curve and curveValueAt(h.curve, 50) then
						return name, id, d, h, enc
					end
				end
			end
		end
	end
end

-- A group whose members sit at KNOWN percentiles of their own spec curve.
local PROBE_PCTS = { 90, 75, 50, 25, 10 }

local function makeFight(TP, sc, encName, specID, dpsEntry, duration)
	local roles = TP.SPEC_ROLES or {}
	local players, expect = {}, {}
	local refIlvl = 200
	if sc.client == "mists" then refIlvl = 550 end
	for i, pct in ipairs(PROBE_PCTS) do
		local rate = curveValueAt(dpsEntry.curve, pct)
		local guid = "p" .. i
		players[guid] = {
			guid = guid, name = "Probe" .. pct, class = "MAGE",
			role = roles[specID] or "DAMAGER", specID = specID, ilvl = refIlvl,
			isLocalPlayer = (i == 1) or nil,
			metrics = { damage = rate * duration, healing = 0, damageTaken = 0,
				interrupts = 0, dispels = 0, deaths = 0, avoidableTaken = 0 },
		}
		expect[guid] = pct
	end
	local fight = {
		name = encName, isBoss = true, duration = duration,
		zone = sc.dungeon and encName or "Test Raid",
		instanceType = sc.itype, difficultyID = sc.difficultyID,
		keystoneLevel = sc.keystone,
		difficulty = (sc.difficultyID == 8 and "Mythic Keystone")
			or (sc.difficultyID == 237 and "Celestial") or nil,
		players = players,
		totals = { damage = 0, healing = 0, damageTaken = 0, interrupts = 0, dispels = 0 },
	}
	if sc.unranked then
		-- content with no curves of its own: rename off the data entirely
		fight.name = "Unranked Boss"
		fight.zone = "Unranked Dungeon"
	end
	return fight, expect
end

-- ------------------------------------------------------------------- report
local rows, problems = {}, {}

local function median(t)
	table.sort(t)
	if #t == 0 then return 0 end
	return t[math.ceil(#t / 2)]
end

for _, sc in ipairs(SCENARIOS) do
	local TP = CLIENTS[sc.client]
	local encName, specID, dpsEntry, hpsEntry = pickCurve(TP, sc.bracket, (not sc.unranked) and sc.dungeon or nil)
	if not encName then
		problems[#problems + 1] = ("%s: no shipped curve matches this scenario"):format(sc.label)
	else
		local duration = 300
		local fight, expect = makeFight(TP, sc, encName, specID, dpsEntry, duration)

		local parseOpts = { mode = "parse", normalizeIlvl = false }
		local trueOpts = { normalizeIlvl = false }
		local parsed = TP.Scoring.Engine.ScoreFight(fight, parseOpts)
		local trued = TP.Scoring.Engine.ScoreFight(fight, trueOpts)

		local byGuid, trueByGuid = {}, {}
		for _, r in ipairs(parsed) do byGuid[r.guid] = r end
		for _, r in ipairs(trued) do trueByGuid[r.guid] = r end

		local errs, detail = {}, {}
		local lastReported, monotone = nil, true
		for _, pct in ipairs(PROBE_PCTS) do
			for guid, want in pairs(expect) do
				if want == pct then
					local r = byGuid[guid]
					local got = r and r.breakdown and r.breakdown.damage
						and r.breakdown.damage.pctile
					if got then
						errs[#errs + 1] = math.abs(got - want)
						if lastReported and got > lastReported + 0.01 then monotone = false end
						lastReported = got
						detail[#detail + 1] = ("p%d->%.0f"):format(want, got)
					else
						detail[#detail + 1] = ("p%d->none"):format(want)
						errs[#errs + 1] = 99
					end
				end
			end
		end

		local tier = trued[1] and trued[1].derived or 1
		local trueScores = {}
		for _, r in ipairs(trued) do trueScores[#trueScores + 1] = r.score end
		table.sort(trueScores)

		local medErr = median(errs)
		rows[#rows + 1] = {
			label = sc.label, enc = encName, spec = specID,
			medErr = medErr, tier = tier, wantTier = sc.tier,
			detail = table.concat(detail, " "),
			trueLo = trueScores[1] or 0, trueHi = trueScores[#trueScores] or 0,
			monotone = monotone,
		}
		if tier ~= sc.tier then
			problems[#problems + 1] = ("%s: expected tier %d, engine said %s")
				:format(sc.label, sc.tier, tostring(tier))
		end
		if not monotone then
			problems[#problems + 1] = ("%s: NOT MONOTONE - more output scored lower"):format(sc.label)
		end
		-- The round trip only MEANS anything for tier 1, where the curve the
		-- player was built from IS the curve they are scored against. A
		-- derived tier deliberately scores against a different population,
		-- so "error" here would just be measuring the correction. Gear
		-- invariance below is the test that applies to those.
		if medErr > 10 and sc.tier == 1 then
			problems[#problems + 1] = ("%s: tier-1 median percentile error %.0f points")
				:format(sc.label, medErr)
		end
	end
end

print(("%-22s %-5s %-6s %-9s %-7s %s"):format(
	"SCENARIO", "TIER", "MEDERR", "TRUE lo-hi", "MONO", "reported percentile per probe"))
for _, r in ipairs(rows) do
	local direct = (r.wantTier == 1)
	print(("%-22s %-5s %-6s %3.0f-%-5.0f %-7s %s"):format(
		r.label, ("%s%s"):format(r.tier, r.tier == r.wantTier and "" or "!"),
		direct and ("%.0f"):format(r.medErr) or "n/a",
		r.trueLo, r.trueHi, r.monotone and "ok" or "BROKEN",
		direct and r.detail or "(derived: see gear invariance below)"))
end


-- ============================================================ gear invariance
-- The derived tiers claim "50 means an average player at YOUR item level".
-- That is a testable invariant: a player of FIXED relative skill must score
-- the SAME at any gear level. Model their output with the engine's own ilvl
-- slope, sweep the gear, and any drift is calibration error — this is Josh's
-- original complaint ("my skill hasn't changed, the score shouldn't swing")
-- expressed as a measurement.
-- Swept per client: MoP's population sits near ilvl 563, so retail's range
-- would model every MoP player as producing essentially nothing.
local ILVL_SWEEP = {
	retail = { 120, 160, 200, 240, 280 },
	mists  = { 440, 480, 520, 560, 600 },
}

local function refIlvlOf(TP)
	local ils = {}
	for _, set in pairs((TP.Benchmarks or {}).encounters or {}) do
		if set.ilvlMedian then ils[#ils + 1] = set.ilvlMedian end
	end
	table.sort(ils)
	return ils[math.ceil(#ils / 2)] or 291
end

print("\n=== gear invariance: one fixed-skill player, swept across item level ===")
print(("%-22s %-5s %-38s %s"):format("SCENARIO", "TIER", "score at ilvl 120/160/200/240/280", "DRIFT"))

local invProblems = 0
for _, sc in ipairs(SCENARIOS) do
	local TP = CLIENTS[sc.client]
	local encName, specID, dpsEntry = pickCurve(TP, sc.bracket, (not sc.unranked) and sc.dungeon or nil)
	if encName then
		local slope = (TP.Benchmarks and TP.Benchmarks.ilvlSlopePct or 1.489) / 100
		local ref = refIlvlOf(TP)
		local p50 = curveValueAt(dpsEntry.curve, 50)
		local duration, out, tier = 300, {}, nil
		for _, ilvl in ipairs(ILVL_SWEEP[sc.client]) do
			-- a MEDIAN player for this gear level, per the engine's own model
			local rate = p50 * (1 + slope) ^ (ilvl - ref)
			local fight = makeFight(TP, sc, encName, specID, dpsEntry, duration)
			for guid, pl in pairs(fight.players) do
				pl.ilvl = ilvl
				pl.metrics.damage = rate * duration
				if guid ~= "p1" then fight.players[guid] = nil end
			end
			-- keep a plausible room around them so cohort paths behave
			for i = 2, 5 do
				local g = "f" .. i
				fight.players[g] = { guid = g, name = "Filler" .. i, class = "MAGE",
					role = "DAMAGER", specID = specID, ilvl = ilvl,
					metrics = { damage = rate * duration * (0.7 + i * 0.1), healing = 0,
						damageTaken = 0, interrupts = 0, dispels = 0, deaths = 0,
						avoidableTaken = 0 } }
			end
			local rs = TP.Scoring.Engine.ScoreFight(fight, { normalizeIlvl = false })
			for _, r in ipairs(rs) do
				if r.guid == "p1" then
					out[#out + 1] = r.score
					tier = r.derived or 1
				end
			end
		end
		local lo, hi = math.huge, -math.huge
		local parts = {}
		for _, v in ipairs(out) do
			lo, hi = math.min(lo, v), math.max(hi, v)
			parts[#parts + 1] = ("%2.0f"):format(v)
		end
		local drift = hi - lo
		local derived = (tier or 1) > 1
		print(("%-22s %-5s %-38s %3.0f %s"):format(sc.label, tostring(tier),
			table.concat(parts, " / "), drift,
			not derived and "(tier 1: gear SHOULD move a parse)"
				or (drift > 20 and "<-- DERIVED TIER, should be flat" or "ok")))
		-- Only DERIVED tiers promise gear independence. A tier-1 parse is
		-- raw output against the population, and better gear genuinely
		-- parses higher — WCL's headline percentile works the same way.
		if drift > 20 and (tier or 1) > 1 then
			invProblems = invProblems + 1
			problems[#problems + 1] = ("%s: same skill scores %.0f-%.0f across gear (drift %.0f)")
				:format(sc.label, lo, hi, drift)
		end
	end
end

-- =============================================================== healers
-- Same round trip, against the hps curves. Parse mode, because True's
-- low-demand floor deliberately overrides a low healing score on fights with
-- nothing to heal — that floor is a feature, not a calibration error, and it
-- would mask what this is measuring.
print("\n=== healers: hps round trip ===")
print(("%-22s %-6s %-6s %s"):format("SCENARIO", "SPEC", "MEDERR", "reported percentile per probe"))
for _, sc in ipairs(SCENARIOS) do
	if sc.tier == 1 then -- derived tiers are covered by gear invariance
		local TP = CLIENTS[sc.client]
		local encName, specID, _, hpsEntry = pickCurve(TP, sc.bracket, sc.dungeon, "HEALER")
		if not encName then
			problems[#problems + 1] = ("%s: no HEALER curve in this bracket"):format(sc.label)
		else
			local duration = 300
			local players, expect = {}, {}
			for i, pct in ipairs(PROBE_PCTS) do
				local rate = curveValueAt(hpsEntry.curve, pct)
				local guid = "h" .. i
				players[guid] = { guid = guid, name = "Heal" .. pct, class = "PRIEST",
					role = "HEALER", specID = specID, ilvl = 250,
					metrics = { damage = 0, healing = rate * duration, damageTaken = 0,
						interrupts = 0, dispels = 0, deaths = 0, avoidableTaken = 0 } }
				expect[guid] = pct
			end
			local fight = {
				name = encName, isBoss = true, duration = duration,
				zone = sc.dungeon and encName or "Test Raid",
				instanceType = sc.itype, difficultyID = sc.difficultyID,
				keystoneLevel = sc.keystone,
				difficulty = (sc.difficultyID == 8 and "Mythic Keystone") or nil,
				players = players,
				totals = { damage = 0, healing = 0, damageTaken = 0, interrupts = 0, dispels = 0 },
			}
			local errs, detail = {}, {}
			local byGuid = {}
			for _, r in ipairs(TP.Scoring.Engine.ScoreFight(fight,
				{ mode = "parse", normalizeIlvl = false })) do byGuid[r.guid] = r end
			for i, pct in ipairs(PROBE_PCTS) do
				local r = byGuid["h" .. i]
				local got = r and r.breakdown and r.breakdown.healing and r.breakdown.healing.pctile
				errs[#errs + 1] = got and math.abs(got - pct) or 99
				detail[#detail + 1] = got and ("p%d->%.0f"):format(pct, got) or ("p%d->none"):format(pct)
			end
			local medErr = median(errs)
			print(("%-22s %-6d %-6.0f %s"):format(sc.label, specID, medErr, table.concat(detail, " ")))
			if medErr > 10 then
				problems[#problems + 1] = ("%s healers: median percentile error %.0f points")
					:format(sc.label, medErr)
			end
		end
	end
end

-- ================================================================== tanks
-- Mitigation is not a curve — it is active-mitigation UPTIME scored against
-- the spec's crawled { p25, p50, p75 } field (Data/TankAnchors). The contract
-- is exact: feeding an anchor back must return that percentile.
print("\n=== tanks: mitigation uptime vs the crawled anchors ===")
print(("%-10s %-6s %-18s %s"):format("CLIENT", "SPEC", "anchors p25/50/75", "score at each anchor"))
for clientName, TP in pairs(CLIENTS) do
	local anchors = TP.TANK_ANCHORS or {}
	local specs = {}
	for id in pairs(anchors) do specs[#specs + 1] = id end
	table.sort(specs, function(a, b) return tostring(a) < tostring(b) end)
	for _, id in ipairs(specs) do
		local a = anchors[id]
		if type(a) == "table" and #a == 3 then
			local duration = 300
			local got, errs = {}, {}
			local prev = -1
			local monotone = true
			for _, want in ipairs({ 25, 50, 75 }) do
				local uptime = a[want == 25 and 1 or want == 50 and 2 or 3]
				local players = {
					t1 = { guid = "t1", name = "Tank", class = "WARRIOR", role = "TANK",
						specID = (type(id) == "number") and id or 999999, ilvl = 250,
						metrics = { damage = 1000 * duration, healing = 0, damageTaken = 5e6,
							mitigationPct = uptime, interrupts = 0, dispels = 0,
							deaths = 0, avoidableTaken = 0 } },
					d1 = { guid = "d1", name = "Dps", class = "MAGE", role = "DAMAGER",
						specID = 63, ilvl = 250,
						metrics = { damage = 2000 * duration, healing = 0, damageTaken = 1e6,
							interrupts = 0, dispels = 0, deaths = 0, avoidableTaken = 0 } },
					h1 = { guid = "h1", name = "Heal", class = "PRIEST", role = "HEALER",
						specID = 257, ilvl = 250,
						metrics = { damage = 0, healing = 3000 * duration, damageTaken = 5e5,
							interrupts = 0, dispels = 0, deaths = 0, avoidableTaken = 0 } },
				}
				local fight = { name = "Anchor Boss", isBoss = true, duration = duration,
					zone = "Test Raid", instanceType = "raid", difficultyID = 14,
					players = players,
					totals = { damage = 0, healing = 0, damageTaken = 0, interrupts = 0, dispels = 0 } }
				for _, r in ipairs(TP.Scoring.Engine.ScoreFight(fight, { normalizeIlvl = false })) do
					if r.guid == "t1" then
						local m = r.breakdown and r.breakdown.mitigation
						local v = m and m.normalized
						got[#got + 1] = v and ("%.0f"):format(v) or "none"
						errs[#errs + 1] = v and math.abs(v - want) or 99
						if v then
							if v < prev then monotone = false end
							prev = v
						end
					end
				end
			end
			print(("%-10s %-6s %-18s %s%s"):format(clientName, tostring(id),
				("%.1f/%.1f/%.1f"):format(a[1], a[2], a[3]), table.concat(got, " / "),
				monotone and "" or "  <-- NOT MONOTONE"))
			local medErr = median(errs)
			if medErr > 2 then
				problems[#problems + 1] = ("%s tank spec %s: uptime anchors return %s, expected 25/50/75")
					:format(clientName, tostring(id), table.concat(got, "/"))
			end
			if not monotone then
				problems[#problems + 1] = ("%s tank spec %s: mitigation not monotone")
					:format(clientName, tostring(id))
			end
		end
	end
end

-- ========================================================== role fairness
-- The founding promise: a tank or healer can top the meter as easily as a
-- DPS. Every role's weights sum to 1.0, so a player sitting at percentile P
-- on EVERY metric their role is graded on must score P — whatever the role.
-- Any spread between roles here is bias, in points.
print("\n=== role fairness: everyone at the same percentile of their own role ===")

-- anchorScore inverted: what uptime does a tank need to score exactly P?
local function uptimeForPct(a, pct)
	local p25, p50, p75 = a[1], a[2], a[3]
	if pct <= 25 then return pct * p25 / 25 end
	if pct <= 50 then return p25 + (pct - 25) / 25 * (p50 - p25) end
	if pct <= 75 then return p50 + (pct - 50) / 25 * (p75 - p50) end
	return p75 + (pct - 75) / 25 * (p75 - p50)
end

local function specWithRole(TP, bracket, role)
	local _, id, d, h = pickCurve(TP, bracket, false, role)
	return id, d, h
end

for _, sc in ipairs({ SCENARIOS[2], SCENARIOS[3], SCENARIOS[10] }) do -- Normal, Heroic, SoO 25N
	local TP = CLIENTS[sc.client]
	local encName = pickCurve(TP, sc.bracket, false)
	local tankID, tankD, tankH = specWithRole(TP, sc.bracket, "TANK")
	local healID, healD, healH = specWithRole(TP, sc.bracket, "HEALER")
	local dpsID,  dpsD,  dpsH  = specWithRole(TP, sc.bracket, "DAMAGER")
	-- * SUPPORT is informational: see the note at the parity check below
	if not (encName and tankID and healID and dpsID) then
		problems[#problems + 1] = ("%s: could not build a full role set"):format(sc.label)
	else
		print(("\n%s  (tank %d, healer %d, dps %d)"):format(sc.label, tankID, healID, dpsID))
		print(("  %-6s %-8s %-8s %-8s %-8s %s"):format(
			"at pP", "TANK", "HEALER", "DPS", "SUPPORT*", "spread"))
		for _, pct in ipairs({ 25, 50, 75, 90 }) do
			local duration = 300
			local players = {}
			local function add(guid, role, id, dEntry, hEntry, mitAnchors)
				local p = { guid = guid, name = guid, class = "WARRIOR", role = role,
					specID = id, ilvl = 250,
					metrics = { damage = curveValueAt(dEntry.curve, pct) * duration,
						healing = curveValueAt(hEntry.curve, pct) * duration,
						damageTaken = (role == "TANK") and 6e6 or 1e6,
						interrupts = 0, dispels = 0, deaths = 0, avoidableTaken = 0 } }
				if mitAnchors then
					p.metrics.mitigationPct = uptimeForPct(mitAnchors, pct)
				end
				players[guid] = p
			end
			local AN = TP.TANK_ANCHORS or {}
			local anchors = AN[tankID] or AN.default
			for i = 1, 2 do add("t" .. i, "TANK", tankID, tankD, tankH, anchors) end
			for i = 1, 4 do add("h" .. i, "HEALER", healID, healD, healH) end
			for i = 1, 13 do add("d" .. i, "DAMAGER", dpsID, dpsD, dpsH) end

			-- SUPPORT (Augmentation): scored on Prescience CADENCE plus the
			-- damage its buffs ENABLED, not its own tiny number. Both have to
			-- be built backwards from the target percentile.
			local W = TP.Scoring.Weights
			local sup = { guid = "s1", name = "s1", class = "EVOKER", role = "SUPPORT",
				specID = 1473, ilvl = 250,
				metrics = { damage = 0, healing = curveValueAt(healH.curve, pct) * duration,
					damageTaken = 1e6, interrupts = 0, dispels = 0, deaths = 0,
					avoidableTaken = 0 } }
			-- prescience: score is casts-per-minute against the cadence anchor
			local perMin = pct / 100 * (W.prescienceCadenceAnchor or 5)
			sup.metrics.prescience = perMin * duration / 60
			-- effective damage must land on the DPS curve's p-value; solve the
			-- Ebon Might uptime that gets it there (own damage is a small slice)
			local target = curveValueAt(dpsD.curve, pct) * duration
			sup.metrics.damage = target * 0.3
			local allyDmg = curveValueAt(dpsD.curve, pct) * duration
			local buffedTop4 = 4 * allyDmg
			sup.metrics.buffUptime =
				(target * 0.7) / (buffedTop4 * (W.ebonTransfer or 0.12))
			players.s1 = sup

			local fight = { name = encName, isBoss = true, duration = duration,
				zone = "Test Raid", instanceType = "raid", difficultyID = sc.difficultyID,
				players = players,
				totals = { damage = 0, healing = 0, damageTaken = 0, interrupts = 0, dispels = 0 } }
			local byRole = {}
			for _, r in ipairs(TP.Scoring.Engine.ScoreFight(fight, { normalizeIlvl = false })) do
				byRole[r.role] = byRole[r.role] or r.base -- base isolates the weighted metrics
			end
			local t, h, d = byRole.TANK or 0, byRole.HEALER or 0, byRole.DAMAGER or 0
			local sp = byRole.SUPPORT or 0
			-- SUPPORT is printed but NOT held to the parity bar: Augmentation
			-- is deliberately absent from the curve data (0 of 27 brackets —
			-- WCL's Aug numbers already contain invisible support damage), so
			-- its attributed damage is read off the POOLED damager curve
			-- rather than its own spec's. It inherits pooled-curve error by
			-- design and cannot be spec-exact the way the other roles are.
			local lo = math.min(t, h, d)
			local hi = math.max(t, h, d)
			local spread = hi - lo
			print(("  %-6d %-8.1f %-8.1f %-8.1f %-8.1f %.1f%s"):format(pct, t, h, d, sp, spread,
				spread > 10 and "  <-- ROLE BIAS" or ""))
			if spread > 10 then
				problems[#problems + 1] = ("%s at p%d: roles score %.0f-%.0f (spread %.0f)")
					:format(sc.label, pct, lo, hi, spread)
			end
		end
	end
end

-- ===================================================== adjustment bounds
-- The base is provably exact (role fairness above). Adjustments are what
-- move it, and they are the part with no natural ceiling — so fuzz them.
-- Randomised metrics across many fights, asserting the invariants that must
-- hold no matter what the inputs are. Fixed seed: a failure must reproduce.
print("\n=== adjustment bounds: randomised fights, invariants that must always hold ===")
math.randomseed(20260728)

local A = CLIENTS.retail.Scoring.Weights.adjustments
local TOTAL_CAP = A.totalCap or 15
local viol = { cap = 0, range = 0, detail = 0, nan = 0 }
local worstAdj, worstScore = 0, 0
local FIGHTS = 400

for n = 1, FIGHTS do
	local TP = CLIENTS.retail
	local encName, specID, dEntry, hEntry = pickCurve(TP, "3", false)
	local duration = 60 + math.random(600)
	local players = {}
	local roles = { "TANK", "HEALER", "DAMAGER", "DAMAGER", "DAMAGER" }
	for i, role in ipairs(roles) do
		local guid = "p" .. i
		-- deliberately extreme and contradictory inputs, including zero and
		-- absurd values: the caps must hold at the edges, not just the middle
		players[guid] = { guid = guid, name = guid, class = "WARRIOR", role = role,
			specID = specID, ilvl = 150 + math.random(150),
			metrics = {
				damage = curveValueAt(dEntry.curve, 50) * duration * (math.random() * 3),
				healing = curveValueAt(hEntry.curve, 50) * duration * (math.random() * 3),
				damageTaken = math.random(0, 20) * 1e6,
				avoidableTaken = math.random(0, 20) * 1e6,
				interrupts = math.random(0, 12),
				dispels = math.random(0, 10),
				deaths = math.random(0, 4),
				activityPct = math.random(0, 100),
				defensives = math.random(0, 8),
				consumables = math.random(0, 2),
				mitigationPct = math.random(0, 100),
				readyAtDeath = math.random(-1, 4),
				overhealPct = math.random(0, 90),
			} }
	end
	local fight = { name = encName, isBoss = true, duration = duration,
		zone = "Test Raid", instanceType = "raid", difficultyID = 14,
		players = players, wipe = (math.random() < 0.3) or nil,
		totals = { damage = 0, healing = 0, damageTaken = 0, interrupts = 0,
			dispels = 0, dispelTypes = { Magic = true, Curse = true } } }

	local ok, results = pcall(TP.Scoring.Engine.ScoreFight, fight, { normalizeIlvl = false })
	if not ok then
		viol.nan = viol.nan + 1
	else
		for _, r in ipairs(results) do
			local adj = r.adjust or 0
			-- NaN is its own failure mode and compares false to everything
			if adj ~= adj or (r.score or 0) ~= (r.score or 0) then
				viol.nan = viol.nan + 1
			end
			if math.abs(adj) > TOTAL_CAP + 0.01 then
				viol.cap = viol.cap + 1
			end
			if (r.score or -1) < 0 or (r.score or 100) > 99 then
				viol.range = viol.range + 1
			end
			worstAdj = math.max(worstAdj, math.abs(adj))
			worstScore = math.max(worstScore, r.score or 0)
			-- every named adjustment must respect its own documented max
			for key, v in pairs(r.adjustDetail or {}) do
				local max = ({ kicks = A.kicksMax, dispels = A.dispelsMax,
					activity = A.activityMax, cdTiming = A.cdTimingMax,
					lust = A.lustMax, rez = A.rezCap })[key]
				if max and v > max + 0.01 then
					viol.detail = viol.detail + 1
				end
			end
		end
	end
end

print(("  %d fights x 5 players scored"):format(FIGHTS))
print(("  |net adjustment| never exceeded %.1f (cap %d)"):format(worstAdj, TOTAL_CAP))
print(("  highest score seen %.1f (ceiling 99)"):format(worstScore))
local bad = viol.cap + viol.range + viol.detail + viol.nan
print(("  violations: total-cap %d | score range %d | per-adjustment max %d | nan/error %d")
	:format(viol.cap, viol.range, viol.detail, viol.nan))
if bad > 0 then
	problems[#problems + 1] = ("adjustment fuzz: %d invariant violations across %d fights")
		:format(bad, FIGHTS)
end

print("")
if #problems == 0 then
	print("VALIDATION CLEAN")
else
	print(("%d PROBLEMS"):format(#problems))
	for _, p in ipairs(problems) do print("  - " .. p) end
end
return #problems
