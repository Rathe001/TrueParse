-- The contribution score. Consumes one FightHistory record (plain data) and
-- returns 0-100 scores with full per-metric breakdowns.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
--
-- Model (user-approved design):
--  1. Every metric normalizes to 0-100 first:
--     - damage / healing / damageTaken: relative to the best of your ROLE
--       cohort; when you're the only one of your role, your group share is
--       scored against Weights.expectedShare instead.
--     - interrupts / dispels: your count vs an equal share of the group's
--       total (opportunity data isn't exposed on Midnight clients).
--  2. Inapplicable metrics (no kick on your spec, nothing dispelled this
--     fight, not a tank) drop out and remaining weights renormalize — this
--     keeps 100 reachable for every role on every fight.
--  3. Penalties (avoidable damage excess, deaths) subtract; clamp [0,100].
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Engine = {}
TP.Scoring.Engine = Engine

local function effHealing(m)
	return (m.healing or 0) + (m.absorbs or 0)
end

local function metricValue(p, key)
	if key == "healing" then
		-- tanks included: plain WCL-comparable healing (Josh 2026-07-25 —
		-- the Off-healing split is retired; the Tanking composite is the
		-- stat that reads self-healing directly)
		return effHealing(p.metrics)
	end
	return p.metrics[key] or 0
end

local function normalizeRole(p)
	return TP.Scoring.Capabilities.EffectiveRole(p.role, p.specIconID, p.specID)
end

-- Map a raw value to a 0-100 percentile-like score against a spec's
-- crawled {p25, p50, p75} field: the anchors land on 25/50/75, linear
-- between, extrapolated and clamped past the ends. This is how the tank
-- mitigation-uptime metric stays WCL-relative instead of arbitrary (Josh
-- 2026-07-26). Guards degenerate/uncalibrated anchors against div-by-zero.
local function anchorScore(v, p25, p50, p75)
	if v <= p25 then
		return math.max(0, 25 * v / math.max(p25, 1))
	elseif v <= p50 then
		return 25 + (v - p25) / math.max(p50 - p25, 1) * 25
	elseif v <= p75 then
		return 50 + (v - p50) / math.max(p75 - p50, 1) * 25
	end
	return math.min(100, 75 + (v - p75) / math.max(p75 - p50, 1) * 25)
end

-- Difficulties whose runs actually populate the WCL dungeon rankings
local DUNGEON_ABSOLUTE_DIFFICULTY = {
	["Mythic Keystone"] = true,
	["Challenge Mode"] = true, -- MoP Classic
}
-- dungeon difficultyIDs (1 Normal, 2 Heroic, 8 Keystone, 23 Mythic 0,
-- 24 Timewalking): fights on these never borrow raid populations
local DUNGEON_DIFF_IDS = {
	[1] = true, [2] = true, [8] = true, [23] = true, [24] = true,
	[237] = true, -- MoP Classic "Celestial" (verified via /dump 2026-07-24)
}

-- Fight-specific spec expectations: boss fights match a WCL encounter table
-- by name (retail prefixes encounters with "(!) "), anything inside a
-- dungeon matches the dungeon's table by zone name. This is the per-fight
-- handicap curve — a spec that underperforms on THIS fight (movement,
-- cleave, ...) is measured against that fight's medians, not global ones.
local function resolveFightFactors(fight)
	local B = TP.Benchmarks
	if not B then
		return nil
	end
	if fight.isBoss and fight.name and B.encounters then
		local plainName = fight.name:gsub("^%(!%)%s*", "")
		local set = B.encounters[plainName]
		if set then
			return set
		end
	end
	if fight.zone and B.dungeons then
		local set = B.dungeons[fight.zone]
		if set then
			-- Dungeon benchmarks are sampled from M+/Challenge Mode logs.
			-- On other difficulties (Heroic, Timewalking scale-down) the
			-- spec factors still apply RELATIVELY, but comparing absolute
			-- output against top-key medians would grade the content, not
			-- the player.
			if DUNGEON_ABSOLUTE_DIFFICULTY[fight.difficulty or ""] then
				return set
			end
			return {
				damageFactor = set.damageFactor,
				healingFactor = set.healingFactor,
				ilvlMedian = set.ilvlMedian,
			}
		end
	end
	return nil
end

-- Combined spec + item-level output factor (from Data/Benchmarks.lua, WCL
-- statistics). A player's throughput is divided by this before comparison,
-- so a low-output spec or low-ilvl player is graded on performance relative
-- to what their spec and gear can produce. Fight-specific factors take
-- precedence over global ones. SUPPORT keeps its hand-calibrated
-- expectations (WCL aug numbers include support damage we can't see).
local function outputFactor(p, role, key, ctx)
	local B = TP.Benchmarks
	if not B or role == "SUPPORT" then
		return 1
	end
	local factor = 1
	local wantHealing = (key == "healing")
	local specFactor
	if ctx.fightFactors then
		-- explicit branch, not and-or: a factor set missing healingFactor
		-- would silently divide healing by the DAMAGE factor (latent,
		-- audit 2026-07-16)
		local t
		if wantHealing then
			t = ctx.fightFactors.healingFactor
		else
			t = ctx.fightFactors.damageFactor
		end
		specFactor = t and p.specID and t[p.specID]
	end
	if not specFactor then
		local t
		if wantHealing then
			t = B.healingFactor
		else
			t = B.damageFactor
		end
		specFactor = t and p.specID and t[p.specID]
	end
	if specFactor and specFactor > 0 then
		factor = factor * specFactor
	end
	if ctx.normalizeIlvl and B.ilvlSlopePct and p.ilvl and ctx.meanIlvl then
		factor = factor * (1 + B.ilvlSlopePct / 100) ^ (p.ilvl - ctx.meanIlvl)
	end
	return factor
end

local function adjustedValue(p, role, key, ctx)
	return metricValue(p, key) / outputFactor(p, role, key, ctx)
end

-- Percentile curves (Data/Percentiles*.lua): the metric value at fixed
-- population percentiles per encounter+spec. When present, Raw scores are
-- TRUE percentiles — matching WCL's parse numbers — instead of the linear
-- %-of-elite-median fallback (which reads far too generous mid-pack:
-- logged populations bunch high, so 60% of elite output can be p12).
-- WoW difficultyID -> WCL ranking bracket. Classic raid sizes rank
-- separately (a 10N raider measured against 25H parses reads absurdly
-- low); retail raids are flex-sized so difficulty alone brackets them.
local WCL_BRACKET = {
	[3] = "3x10", [4] = "3x25", [5] = "4x10", [6] = "4x25", -- classic 10/25 N/H
	[7] = "1x25", -- classic LFR
	[14] = "3", [15] = "4", [16] = "5", -- retail Normal/Heroic/Mythic
	[17] = "1", -- retail LFR (WCL difficulty 1, ranked like the rest)
}

-- WCL encounter names don't always match in-game ENCOUNTER_START names
-- ("Chimaerus, the Undreamt God" vs "Chimaerus the Undreamt God" cost a
-- live boss its curves): fall back to a punctuation-insensitive match.
local nameIndexCache = setmetatable({}, { __mode = "k" })

local function normalizeName(s)
	return (s:gsub("[,%.:;!]", ""):gsub("%s+", " "):lower())
end

local function encounterByName(P, name)
	local enc = P.encounters[name]
	if enc then
		return enc
	end
	local key = normalizeName(name)
	local idx = nameIndexCache[P]
	if not idx then
		idx = {}
		for k, v in pairs(P.encounters) do
			idx[normalizeName(k)] = v
		end
		nameIndexCache[P] = idx
	end
	-- misses stay misses (run aggregates query "Run" on every score);
	-- the encounters table never changes at runtime
	return idx[key]
end

-- Tests mutate the encounters table; runtime never does.
-- (Defined below findCurve, where every per-file cache is in scope.)

-- WCL orders DUNGEON rankings by keystone score, not by the requested
-- throughput metric, so sampled curves come back shuffled (583 of the 592
-- shipped M+ curves were non-monotonic) — and percentileFor assumes
-- descending values. Sorting the sampled values restores a usable curve.
local function sanitizeEncounter(enc)
	if enc._mono then
		return enc
	end
	enc._mono = true
	local scratch = {}
	for bk, bracket in pairs(enc) do
		if bk ~= "_mono" and type(bracket) == "table" then
			for _, kind in ipairs({ "dps", "hps" }) do
				for _, entry in pairs(bracket[kind] or {}) do
					local curve = entry.curve
					local sorted = true
					for i = 2, #curve do
						if curve[i][2] > curve[i - 1][2] then
							sorted = false
							break
						end
					end
					if not sorted then
						for i = 1, #curve do
							scratch[i] = curve[i][2]
						end
						table.sort(scratch, function(a, b)
							return a > b
						end)
						for i = 1, #curve do
							curve[i][2] = scratch[i]
							scratch[i] = nil
						end
					end
				end
			end
		end
	end
	return enc
end

-- Raid curves key by BOSS name; dungeon curves key by DUNGEON name (WCL
-- ranks M+ as whole runs) and only apply on difficulties that actually
-- populate those rankings — a Timewalking healer measured against the M+
-- population would read F on content nobody ranks.
local function encounterCurvesFor(P, fight)
	if not (fight.isBoss or fight.isRun) or not P.encounters then
		return nil
	end
	-- practice-dummy sessions score against the tier's patchwerk anchor
	-- (the fight parses are compared on); the record's difficultyID
	-- already carries the anchor's bracket
	if fight.practice and TP.PRACTICE_ANCHOR then
		local enc = encounterByName(P, TP.PRACTICE_ANCHOR.name)
		if enc then
			return sanitizeEncounter(enc)
		end
		return nil
	end
	-- encounterID first: locale-proof. A non-English client's
	-- ENCOUNTER_START name can never string-match the English WCL keys,
	-- but the numeric id is identical on every locale. P.ids is emitted
	-- by the crawlers (data refreshed monthly); absent on older files.
	if fight.encounterID and P.ids then
		local keyed = P.ids[fight.encounterID]
		local enc = keyed and P.encounters[keyed]
		if enc then
			return sanitizeEncounter(enc)
		end
	end
	if fight.name then
		local enc = encounterByName(P, fight.name:gsub("^%(!%)%s*", ""))
		if enc then
			return sanitizeEncounter(enc)
		end
	end
	-- difficultyID 8 = Mythic Keystone on any locale; the localized-name
	-- check keeps working for English and MoP Challenge Modes. Normal and
	-- heroic dungeons (2026-07-13, Josh's call) also compare against the
	-- dungeon's curves — a labeled comparison vs timed top runs beats
	-- falling back to cross-encounter RAID pools, and Raw lights up on
	-- seasonal heroics. The "timed top runs" label carries the caveat.
	if fight.zone and (fight.difficultyID == 8
		or DUNGEON_ABSOLUTE_DIFFICULTY[fight.difficulty or ""] or fight.keystoneLevel
		or fight.instanceType == "party") then
		local enc = P.encounters[fight.zone]
		-- second return: this entry is DUNGEON-keyed, so its killTime curve
		-- measures FULL RUNS — callers comparing a single fight's duration
		-- against it must not (a 90s CM boss "beat" every 274s+ run: p99)
		return enc and sanitizeEncounter(enc) or nil, true
	end
	return nil
end

local function resolvePercentiles(fight)
	local P = TP.Percentiles
	if not P then
		return nil
	end
	local enc = encounterCurvesFor(P, fight)
	if not enc then
		return nil
	end
	local key = fight.difficultyID and WCL_BRACKET[fight.difficultyID]
	return (key and enc[key]) or enc.all
end

-- The evidence ladder never jumps from "no curve for this exact
-- spec+bracket" straight to a group comparison. It zooms out through
-- progressively rougher WCL populations first: neighboring brackets, the
-- role's pooled curve, then the whole data file. A rough population
-- comparison still beats swapping the comparison model entirely
-- (best-in-group "99 parses" were pure noise).
local BRACKET_NEIGHBORS = {
	-- same difficulty first: a 10N raider reads closer to 25N than to 10H
	["1x25"] = { "3x25", "3x10", "4x25", "4x10" },
	["3x10"] = { "3x25", "4x10", "4x25", "1x25" },
	["3x25"] = { "3x10", "4x25", "4x10", "1x25" },
	["4x10"] = { "4x25", "3x10", "3x25", "1x25" },
	["4x25"] = { "4x10", "3x25", "3x10", "1x25" },
	["1"] = { "3", "4", "5" },
	["3"] = { "4", "5", "1" },
	["4"] = { "3", "5", "1" },
	["5"] = { "4", "3", "1" },
}
local BRACKET_LABELS = {
	["3x10"] = "10N", ["3x25"] = "25N", ["4x10"] = "10H", ["4x25"] = "25H",
	["1x25"] = "LFR",
	["1"] = "LFR", ["3"] = "Normal", ["4"] = "Heroic", ["5"] = "Mythic",
}
local ALL_BRACKETS = { "1x25", "3x10", "3x25", "4x10", "4x25", "1", "3", "4", "5" }
-- What a derived tier's pooled reference actually IS, for the score tooltip.
-- Keyed by poolAllCurves' `want`.
local POOL_LABELS = { raid = "pooled raid logs", dungeon = "pooled dungeon logs" }

local function bracketSearchOrder(bracketKey)
	local order = {}
	if bracketKey then
		order[#order + 1] = bracketKey
		for _, nb in ipairs(BRACKET_NEIGHBORS[bracketKey] or {}) do
			order[#order + 1] = nb
		end
	else
		for _, key in ipairs(ALL_BRACKETS) do
			order[#order + 1] = key
		end
	end
	order[#order + 1] = "all" -- legacy unbracketed data files
	return order
end

-- Role-pooled fallback curves: when a spec has no curve for a metric,
-- score against the aggregated population of its ROLE in the same bracket
-- (sample-size-weighted average of the spec curves). Still real bracket
-- population data — the group-relative comparison becomes the LAST resort,
-- not the second (best-in-group=100 distorted scores badly).
local QUANTS = { 99, 95, 90, 75, 50, 25, 10 }
local poolCache = {} -- [bracketTable] = { dps = { [role] = entry|false }, hps = ... }

local function rolePooledEntry(bracket, kind, role)
	local roles = TP.SPEC_ROLES
	if not roles or not bracket then
		return nil
	end
	local cache = poolCache[bracket]
	if not cache then
		cache = { dps = {}, hps = {} }
		poolCache[bracket] = cache
	end
	local hit = cache[kind][role]
	if hit ~= nil then
		return hit or nil
	end
	local tbl = bracket[kind]
	local sums, total = {}, 0
	if tbl then
		for specID, entry in pairs(tbl) do
			if roles[specID] == role and entry.curve then
				local n = entry.n or 0
				total = total + n
				for _, pt in ipairs(entry.curve) do
					sums[pt[1]] = (sums[pt[1]] or 0) + pt[2] * n
				end
			end
		end
	end
	if total < 100 then
		cache[kind][role] = false
		return nil
	end
	local curve = {}
	for _, pct in ipairs(QUANTS) do
		if sums[pct] then
			curve[#curve + 1] = { pct, sums[pct] / total }
		end
	end
	-- pooled points are computed per-quantile independently; keep the
	-- curve descending (percentileFor's contract)
	for i = 2, #curve do
		if curve[i][2] > curve[i - 1][2] then
			curve[i][2] = curve[i - 1][2]
		end
	end
	local pooled = { n = total, curve = curve }
	cache[kind][role] = pooled
	return pooled
end

-- Whole-data-file pools: every encounter's curves for one bracket (or all
-- of them), filtered by spec or role, sample-weighted like rolePooledEntry.
-- Cached per data file; ~1k curves collapse into a handful of entries.
local globalPoolCache = setmetatable({}, { __mode = "k" })

local function globalPool(P, bracketKey, kind, accept, cacheKey)
	local cache = globalPoolCache[P]
	if not cache then
		cache = {}
		globalPoolCache[P] = cache
	end
	local hit = cache[cacheKey]
	if hit ~= nil then
		return hit or nil
	end
	local sums, total = {}, 0
	for _, enc in pairs(P.encounters) do
		local brackets
		if bracketKey then
			brackets = { enc[bracketKey] }
		else
			brackets = {}
			for k, b in pairs(enc) do
				-- skip the _mono sanitize marker and any non-bracket field
				if type(b) == "table" then
					brackets[#brackets + 1] = b
				end
			end
		end
		for _, bracket in ipairs(brackets) do
			local tbl = bracket[kind]
			if tbl then
				for specID, entry in pairs(tbl) do
					if entry.curve and (not accept or accept(specID)) then
						local n = entry.n or 0
						total = total + n
						for _, pt in ipairs(entry.curve) do
							sums[pt[1]] = (sums[pt[1]] or 0) + pt[2] * n
						end
					end
				end
			end
		end
	end
	if total < 100 then
		cache[cacheKey] = false
		return nil
	end
	local curve = {}
	for _, pct in ipairs(QUANTS) do
		if sums[pct] then
			curve[#curve + 1] = { pct, sums[pct] / total }
		end
	end
	for i = 2, #curve do
		if curve[i][2] > curve[i - 1][2] then
			curve[i][2] = curve[i - 1][2]
		end
	end
	local pooled = { n = total, curve = curve }
	cache[cacheKey] = pooled
	return pooled
end

-- Hoisted above poolAllCurves, which normalises each curve by its own
-- median (2026-07-28): a later definition would compile that call as a
-- nil global, exactly the trap this file already warns about elsewhere.
local function curveP50(curve)
	if not curve then
		return nil
	end
	for _, point in ipairs(curve) do
		if point[1] == 50 then
			return point[2]
		end
	end
	return nil
end

-- === Derived tiers (Josh 2026-07-28) ===================================
-- T1 DIRECT   the fight's difficulty matches the population the curves were
--             sampled from: a Normal raid against the Normal curve, ANY M+
--             key against the M+ dungeon curve (Josh chose the BRACKET, not
--             per-key). Scored 1:1 — unchanged behaviour.
-- T2 DERIVED  curves exist for this encounter, sampled at a difficulty the
--             player didn't run (a Normal or leveling clear of a dungeon
--             WCL only ranks at M+).
-- T3 DERIVED  no curves at all (Timewalking, an old-expansion dungeon, a
--             capture that lost its instance context) -> the AVERAGE
--             SEASONAL DUNGEON, pooled from the M+ curves already shipped.
--             No extra crawl.
-- T2/T3 scale the player's rate INTO the curve population's terms before
-- interpolating (the `scale` argument normalizeMetric already threads into
-- entryPercentileFor), so 50 keeps meaning "average player at your gear"
-- instead of the group comparison's "whoever topped the meter is a 99".

-- Dungeon-keyed data: the dungeon crawls run with no -Brackets filter, so
-- their encounters carry exactly one unfiltered "all" bracket, while raid
-- crawls key by difficulty. Newer files say so outright (P.kinds, emitted by
-- fetch-percentiles-v2.ps1); the shape check reads already-shipped ones.
local function isDungeonKeyed(P, name, enc)
	local kinds = P.kinds
	if kinds and kinds[name] then
		return kinds[name] == "dungeon"
	end
	if type(enc.all) ~= "table" then
		return false
	end
	for k, v in pairs(enc) do
		if k ~= "all" and k ~= "_mono" and type(v) == "table" then
			return false -- has real difficulty brackets: a raid encounter
		end
	end
	return true
end

-- The T3 reference population: every shipped curve for a spec, pooled
-- sample-weighted into one synthetic encounter — "what does this spec put
-- out, across everything we have data for". Same construction as
-- rolePooledEntry/globalPool.
--
-- Prefers RAID-keyed curves, because only they carry a real population's
-- LOWER TAIL. WCL serves dungeon rankings as the top 2000 BY KEYSTONE SCORE,
-- so a dungeon curve describes an elite slice and is narrow by construction.
-- Measured across the shipped retail data (2026-07-29), p10/p50 -> p99/p50:
--   raid-keyed curves     0.577 -> 2.068   (2.84x)  a real population
--   dungeon-keyed curves  0.863 -> 1.255   (1.47x)  the top of one
-- A reference whose bottom stops at 0.86x its own median cannot score anyone
-- below it: percentileFor exhausts the curve and its fade-to-zero crushes the
-- whole lower half of the field into single digits. That is exactly what ate
-- Josh's Botanica Timewalking run — the same five players scored 88/86/80 on
-- a fast opening pull and 1-21 on the next four bosses, purely because the
-- later fights sat below 0.81x the median and fell off the end of the curve.
-- Timewalking's gray parses (p50 29, 32% under 10) are the same defect.
--
-- Pooling raid curves for a dungeon fight is only safe BECAUSE the derived
-- path gear-scales and labels the result; the 2026-07-16 cross-instance-type
-- bug was the unscaled, unlabelled version of it. The dungeon-only pool
-- remains as a fallback for a client that ships no raid curves at all.
-- MoP Classic never reaches it: Percentiles_Mists is SoO raid data only, so
-- its Celestial dungeons pool that raid data (Josh 2026-07-28: "find the
-- median for ALL WCL data for that spec, then scale for ilvl").
--
-- `want` is "raid" | "dungeon" | "all". It was a wantDungeon BOOLEAN, which
-- could not express the three cases the comment above claimed — false meant
-- "every encounter", not "raid", so the pool that shipped mixed both kinds
-- and was labelled "raid" regardless (see averageSeasonalDungeon).
-- Returns the encounter and the pool's kind.
local avgDungeonCache = setmetatable({}, { __mode = "k" })

local function poolAllCurves(P, want)
	local out = { dps = {}, hps = {} }
	local sums, weights, totals, levels = {}, {}, {}, {}
	for name, enc in pairs(P.encounters or {}) do
		local dungeon = isDungeonKeyed(P, name, enc)
		if want == "all" or (want == "dungeon") == dungeon then
			for bk, bracket in pairs(enc) do
				if bk ~= "_mono" and type(bracket) == "table" then
					for _, kind in ipairs({ "dps", "hps" }) do
						for specID, entry in pairs(bracket[kind] or {}) do
							if entry.curve then
								local n = entry.n or 0
								sums[kind] = sums[kind] or {}
								weights[kind] = weights[kind] or {}
								totals[kind] = totals[kind] or {}
								levels[kind] = levels[kind] or {}
								sums[kind][specID] = sums[kind][specID] or {}
								weights[kind][specID] = (weights[kind][specID] or 0) + n
								-- entry.total is the real population behind
								-- the sample; entryPercentileFor needs it to
								-- undo the 2000-char sampling cap
								totals[kind][specID] = (totals[kind][specID] or 0) + (entry.total or n)
								-- Pool the SHAPE, not the raw values. Specs sit at very
								-- different absolute levels, so averaging quantile by
								-- quantile pulls the low end up and the high end down and
								-- the pooled curve comes out far tighter than any curve
								-- that went into it - measured 1.79x p90/p10 against 2.77x
								-- for the individual curves (2026-07-28). A reference
								-- narrower than the population it scores makes everyone
								-- above the median peg at 99, which is exactly what Josh
								-- was seeing. Normalising each curve by its own median
								-- first preserves the dispersion; the level is carried
								-- separately and multiplied back on.
								local own50 = curveP50(entry.curve)
								if own50 and own50 > 0 then
									levels[kind][specID] = (levels[kind][specID] or 0) + own50 * n
									for _, pt in ipairs(entry.curve) do
										sums[kind][specID][pt[1]] =
											(sums[kind][specID][pt[1]] or 0) + (pt[2] / own50) * n
									end
								end
							end
						end
					end
				end
			end
		end
	end
	local any = false
	for _, kind in ipairs({ "dps", "hps" }) do
		for specID, byPct in pairs(sums[kind] or {}) do
			local n = weights[kind][specID]
			local level = (levels[kind] and levels[kind][specID] or 0)
			if n and n > 0 and level > 0 then
				-- shape (normalised, averaged) x the sample-weighted median level
				local avgLevel = level / n
				local curve = {}
				for _, pct in ipairs(QUANTS) do
					if byPct[pct] then
						curve[#curve + 1] = { pct, (byPct[pct] / n) * avgLevel }
					end
				end
				-- per-quantile averages can cross; percentileFor's contract
				-- is a descending curve
				for i = 2, #curve do
					if curve[i][2] > curve[i - 1][2] then
						curve[i][2] = curve[i - 1][2]
					end
				end
				if #curve > 1 then
					out[kind][specID] = { n = n, total = totals[kind][specID], curve = curve }
					any = true
				end
			end
		end
	end
	if not any then
		return nil
	end
	-- shaped like a sanitized encounter so findCurve can walk it unchanged.
	-- _pooled names the population for the UI label: this synthetic encounter
	-- keys its curves under "all", which findCurve would otherwise report as
	-- "timed top runs" — true of a real dungeon entry, a lie about a raid pool.
	return { _mono = true, _pooled = want, all = out }
end

local function averageSeasonalDungeon(P)
	local hit = avgDungeonCache[P]
	if hit ~= nil then
		if not hit then
			return nil
		end
		return hit.enc, hit.kind
	end
	local enc, kind = poolAllCurves(P, "raid"), "raid"
	if not enc then
		enc, kind = poolAllCurves(P, "dungeon"), "dungeon"
	end
	if not enc then
		avgDungeonCache[P] = false
		return nil
	end
	avgDungeonCache[P] = { enc = enc, kind = kind }
	return enc, kind
end

-- Gear the shipped curves were sampled at. Data-driven, because this is
-- per-client: retail's curves sit near ilvl 274, MoP Classic's SoO
-- population near 563 — a hardcoded retail constant would have scaled every
-- MoP player's rate down by two thirds. Order of preference:
--   1. the data file's own statement (P.refIlvl), once the crawler emits it
--   2. the median ilvlMedian across the Benchmarks encounters for THIS
--      client (retail 291, MoP 563) — same crawl, same population
--   3. the fitted constant in Weights (retail-derived; last resort)
local refIlvlCache = setmetatable({}, { __mode = "k" })

local function percentileRefIlvl(P)
	if P and P.refIlvl then
		return P.refIlvl
	end
	local B = TP.Benchmarks
	if B then
		local hit = refIlvlCache[B]
		if hit == nil then
			local ils = {}
			for _, set in pairs(B.encounters or {}) do
				if set.ilvlMedian then
					ils[#ils + 1] = set.ilvlMedian
				end
			end
			table.sort(ils)
			hit = ils[math.ceil(#ils / 2)] or false
			refIlvlCache[B] = hit
		end
		if hit then
			return hit
		end
	end
	return TP.Scoring.Weights.derivedRefIlvl or 274
end

-- Multiplier that carries a player's rate from the content they actually ran
-- into the population the curve was sampled from. Two parts:
--   * gear: the Benchmarks ilvl slope over the gap to the curve's reference
--     item level, with the gap CAPPED — the slope is fitted in a narrow
--     max-level band and compounds absurdly across a leveling gap.
--   * difficulty: a flat lift for running below the ranked difficulty.
-- Applied regardless of the /tp ilvl toggle: for a derived tier the gear
-- scale isn't an optional normalization, it's what makes the comparison mean
-- anything (uncapped OR unapplied, a leveling group reads straight 0s).
-- A derived tier can approximate a good score, never certify an elite one —
-- but SQUEEZE the top rather than clamping it, or a third of the field lands
-- on the same number (measured: a hard clamp put 38% of tier-3 scores on
-- exactly 90). Below the knee is untouched; knee..99 compresses into
-- knee..ceiling, so the ordering survives.
-- Applies to EVERY scored metric on a derived tier, mitigation included: its
-- anchors are crawled from raid tanks, and holding 99% uptime in Timewalking
-- is not the same achievement as holding it in Mythic.
-- Median activityPct across everyone scored this fight, memoised on ctx.
-- Used as a floor on the activity PENALTY: structural downtime (and our
-- proxy's undercount) hits the whole group, individual slacking does not.
local function groupActivityMedian(ctx)
	if ctx.activityMedian ~= nil then
		return ctx.activityMedian or nil
	end
	local vals = {}
	for _, cohort in pairs(ctx.cohorts or {}) do
		for _, pl in ipairs(cohort) do
			local a = pl.metrics and pl.metrics.activityPct
			if a then
				vals[#vals + 1] = a
			end
		end
	end
	if #vals < 3 then
		ctx.activityMedian = false -- too few to say anything
		return nil
	end
	table.sort(vals)
	ctx.activityMedian = vals[math.ceil(#vals / 2)]
	return ctx.activityMedian
end

local function derivedCeil(ctx, v)
	if not v or not ctx.derived then
		return v
	end
	local W = TP.Scoring.Weights
	local ceiling = W.derivedCeiling and W.derivedCeiling[ctx.derived.tier]
	if not ceiling then
		return v
	end
	local knee = W.derivedCeilingKnee or 70
	if knee >= ceiling or ceiling >= 99 then
		return math.min(v, ceiling)
	end
	if v <= knee then
		return v
	end
	-- The ramp maps 99 -> ceiling, so an input ABOVE 99 lands above it.
	-- Per-metric that never happened; the composite it now guards is
	-- base + adjustments, which overshoots 99 before the outer clamp
	-- (measured: 9 tier-3 scores up to 92.3 against a 90 ceiling).
	return math.min(ceiling, knee + (v - knee) * (ceiling - knee) / (99 - knee))
end

local function derivedScale(ctx, p)
	local d = ctx.derived
	if not d then
		return 1
	end
	local W = TP.Scoring.Weights
	local scale = d.offDifficulty or 1
	local B = TP.Benchmarks
	-- Timewalking scales every character to a common power level, so gear
	-- has almost no purchase there (measured 0.23%/ilvl against the shipped
	-- 1.489). Correcting at the normal slope inflates those scores badly.
	local slopePct = d.levelScaled and (W.derivedIlvlSlopeScaled or 0.23)
		or (B and B.ilvlSlopePct)
	if B and slopePct and d.refIlvl and p.ilvl and p.ilvl > 0 then
		local cap = W.derivedIlvlCap or 90
		local gap = d.refIlvl - p.ilvl
		if gap > cap then
			gap = cap
		elseif gap < -cap then
			gap = -cap
		end
		scale = scale * (1 + slopePct / 100) ^ gap
	end
	return scale
end

-- curve: { {99, value}, {95, value}, ... } descending. Linear interpolation
-- between sampled points; above p99 pins at 99, below the lowest sample
-- fades linearly to 0 at zero output.
local function percentileFor(curve, rate)
	if not rate or rate <= 0 then
		return 0
	end
	if rate >= curve[1][2] then
		return 99
	end
	local prev = curve[1]
	for i = 2, #curve do
		local point = curve[i]
		if rate >= point[2] then
			local span = prev[2] - point[2]
			if span <= 0 then
				return point[1]
			end
			return point[1] + (prev[1] - point[1]) * (rate - point[2]) / span
		end
		prev = point
	end
	local last = curve[#curve]
	if last[2] <= 0 then
		return last[1]
	end
	return last[1] * rate / last[2]
end

-- Capped-curve correction: characterRankings serves at most 2000 chars per
-- spec, so a popular spec's curve samples only the population's top slice
-- and plain interpolation under-rates everyone mid-pack (validated
-- 2026-07-22: Elemental read 10-27 points below WCL's own rankPercents).
-- When the totals crawl recorded the real population (entry.total), a
-- sample percentile converts to an exact in-sample rank, and the true
-- population turns that rank into an honest percentile — same construction
-- as the kill-speed rescale. Below the sampled tail only a ceiling is
-- known, so the fade-to-zero anchors there instead of at p10.
-- sampleIsMetricOrdered = false disables the correction entirely. It rests on
-- the sample being the TOP n of the population BY THIS METRIC — only then does
-- "rank n of total" mean anything. WCL orders DUNGEON rankings by keystone
-- score instead (see sanitizeEncounter, which exists to unshuffle them), so a
-- dungeon's 2000 samples are a slice of good KEYS, not of high damage.
-- Correcting them anyway mapped the entire sampled range onto p99: with
-- total/n = 114, every probe from p10 to p90 came back 99 (validation pass,
-- 2026-07-28). Straight interpolation against the sample is the honest read,
-- and "timed top runs" already labels what that population is.
local function entryPercentileFor(entry, rate, sampleIsMetricOrdered)
	local curve, n, total = entry.curve, entry.n, entry.total
	if sampleIsMetricOrdered == false or not (n and total and total > n) then
		return percentileFor(curve, rate)
	end
	local last = curve[#curve]
	if rate and rate > 0 and rate < last[2] then
		local ceiling = 100 * (1 - (1 - last[1] / 100) * n / total)
		return ceiling * rate / last[2]
	end
	local samplePct = percentileFor(curve, rate)
	local rank = (100 - samplePct) / 100 * n
	local pct = 100 * (1 - rank / total)
	if pct < 0 then
		pct = 0
	elseif pct > 99 then
		pct = 99
	end
	return pct
end

-- Cross-bracket correction: difficulty shifts the whole population by a
-- stable factor (2026-07-13 audit: median p50 ratios run 1.3-3.0x on
-- retail; applying them cuts neighbor-bracket transfer error from 20-48
-- percentile points to 6-15). Computed lazily from the shipped curves —
-- the median over encounter x spec of p50(to)/p50(from) — cached per
-- data file. Returns nil when the brackets don't overlap enough to
-- measure (score uncorrected in that case, as before).
local ratioCache = setmetatable({}, { __mode = "k" })

local function bracketRatio(P, fromBk, toBk, kind)
	if fromBk == toBk then
		return 1
	end
	local cache = ratioCache[P]
	if not cache then
		cache = {}
		ratioCache[P] = cache
	end
	local key = fromBk .. ">" .. toBk .. ":" .. kind
	local hit = cache[key]
	if hit ~= nil then
		return hit or nil
	end
	local ratios = {}
	for _, enc in pairs(P.encounters or {}) do
		local a, b = enc[fromBk], enc[toBk]
		if type(a) == "table" and type(b) == "table" and a[kind] and b[kind] then
			for specID, ea in pairs(a[kind]) do
				local eb = b[kind][specID]
				local m5a = ea.curve and curveP50(ea.curve)
				local m5b = eb and eb.curve and curveP50(eb.curve)
				if m5a and m5b and m5a > 0 then
					ratios[#ratios + 1] = m5b / m5a
				end
			end
		end
	end
	if #ratios < 4 then
		cache[key] = false
		return nil
	end
	table.sort(ratios)
	local mid = (#ratios + 1) / 2
	local r = (ratios[math.floor(mid)] + ratios[math.ceil(mid)]) / 2
	cache[key] = r
	return r
end

-- Walk the ladder for one spec+metric, in MEASURED-accuracy order
-- (2026-07-13 audit, median displacement in percentile points):
--   exact spec+bracket 0 -> spec all-bosses pool 8.6 -> ratio-corrected
--   neighbor bracket 6-15 -> role pool 13 -> stop.
-- The old "everyone" rung is gone: +-29-49 points of systematic error in
-- BOTH directions (a median healer's hps read p99 against it).
-- specOnly stops after the spec steps (the throughput-mix profile must
-- not inherit a role's generic mix). encounterOnly stops before the
-- cross-encounter pools: a "parse" must be evidence from THIS fight.
-- Returns entry, sourceLabel (nil = exact spec+bracket), rolePooledFlag,
-- scale (multiply the player's rate by this before interpolating; the
-- shown median divides by it). Never returns a curve under 2 points.
local function usable(entry)
	return entry and entry.curve and #entry.curve > 1
end

local function findCurve(ctx, kind, specID, role, specOnly, encounterOnly)
	local L = ctx.curves
	if not L then
		return nil
	end
	-- dungeon fights never borrow cross-encounter pools (raid-dominated
	-- populations): this dungeon's own curves or nothing
	if L.dungeonOnly then
		encounterOnly = true
	end
	local enc, order, exact = L.enc, L.order, L.exact
	local function scaleFor(i, bk)
		if i == 1 or not exact or bk == exact or bk == "all" then
			return 1
		end
		return bracketRatio(L.P, exact, bk, kind) or 1
	end
	local function specEntry(i, bk)
		local tbl = enc and enc[bk] and enc[bk][kind]
		local entry = tbl and tbl[specID]
		if usable(entry) then
			-- dungeon curves ("all") sample WCL's score-ordered top runs,
			-- not a population (2026-07-13 audit: p99/p50 = 1.26 vs 2.09 in
			-- raids) — name the comparison honestly
			local label
			if enc and enc._pooled then
				-- the derived tiers' synthetic pool, also keyed "all"
				label = POOL_LABELS[enc._pooled] or "pooled logs"
			elseif bk == "all" then
				label = "timed top runs"
			elseif i > 1 then
				label = "spec · " .. (BRACKET_LABELS[bk] or bk)
			end
			return entry, label, nil, scaleFor(i, bk)
		end
	end
	local function specPool(i, bk)
		if bk == "all" then
			return nil
		end
		local e = globalPool(L.P, bk, kind, function(id) return id == specID end,
			"spec:" .. specID .. ":" .. kind .. ":" .. bk)
		if usable(e) then
			-- bracket suffix only when the fight HAS a bracket to differ
			-- from — without one the bracket picked is arbitrary
			return e, (i > 1 and exact) and ("spec · all bosses · " .. (BRACKET_LABELS[bk] or bk))
				or "spec · all bosses", nil, scaleFor(i, bk)
		end
	end
	-- 1. this encounter, this spec, own bracket
	if specID then
		local e, l, rp, s = specEntry(1, order[1])
		if e then
			return e, l, rp, s
		end
		-- 2. this spec across every boss, own bracket (spec identity
		-- transfers better than encounter identity)
		if not encounterOnly then
			local e2, l2, rp2, s2 = specPool(1, order[1])
			if e2 then
				return e2, l2, rp2, s2
			end
		end
		-- 3. neighbor brackets, ratio-corrected: spec curve here, then
		-- the spec's all-bosses pool there
		for i = 2, #order do
			local e3, l3, rp3, s3 = specEntry(i, order[i])
			if e3 then
				return e3, l3, rp3, s3
			end
			if not encounterOnly then
				local e4, l4, rp4, s4 = specPool(i, order[i])
				if e4 then
					return e4, l4, rp4, s4
				end
			end
		end
	end
	if specOnly then
		return nil
	end
	-- 4. this encounter's role pool, own bracket then corrected neighbors
	if enc then
		for i, bk in ipairs(order) do
			local entry = enc[bk] and rolePooledEntry(enc[bk], kind, role)
			if usable(entry) then
				return entry, (i > 1) and ("role · " .. (BRACKET_LABELS[bk] or bk)) or "role",
					true, scaleFor(i, bk)
			end
		end
	end
	if encounterOnly then
		return nil
	end
	-- 5. the role across every boss
	local roles = TP.SPEC_ROLES
	if roles then
		for i, bk in ipairs(order) do
			if bk ~= "all" then
				local e = globalPool(L.P, bk, kind, function(id) return roles[id] == role end,
					"role:" .. role .. ":" .. kind .. ":" .. bk)
				if usable(e) then
					return e, "role · all bosses", true, scaleFor(i, bk)
				end
			end
		end
	end
	return nil
end

-- Tests mutate the encounters table; runtime never does. Every cache
-- keyed by the data file must drop together or a stale miss poisons
-- later lookups.
function Engine.InvalidateNameIndex(P)
	local key = P or TP.Percentiles
	nameIndexCache[key] = nil
	globalPoolCache[key] = nil
	ratioCache[key] = nil
	-- the derived T3 pool is built from the whole encounters table: it must
	-- drop with the rest or a stale pool outlives the data it summarised
	avgDungeonCache[key] = nil
	-- poolCache is keyed by BRACKET tables inside the data file; wipe it
	-- whole (drop-together invariant, audit 2026-07-16)
	for k in pairs(poolCache) do
		poolCache[k] = nil
	end
end

-- Returns normalizedScore (0-100), applicable, absolute, relative,
-- specMedian (the p50 rate for this spec+fight+bracket, when curve-scored)
local function normalizeMetric(p, role, key, ctx)
	local specMedian, pctile, rolePooled, curveFrom
	local W = TP.Scoring.Weights
	local value = metricValue(p, key)

	-- Count metrics use Laplace smoothing (+0.5): when a whole fight has
	-- one or two kicks, raw fair-share scoring is winner-take-all — the
	-- kicker gets 100, everyone else 0, pure noise (2026-07-09 audit: DPS
	-- averaged 30/100 on interrupts, dispel-capable DPS 1/100 on dispels).
	-- Smoothed, a non-kicker on a 1-kick fight scores ~43; on a 10-kick
	-- fight still ~12. Signal survives, coin-flips don't.
	-- Zero participation can never grade "good" no matter how forgiving the
	-- smoothing gets on a 1-kick fight: cap it in neutral territory.
	if key == "interrupts" then
		if not TP.Scoring.Capabilities.CanInterrupt(p.class, role) then
			return 0, false
		end
		if ctx.totals.interrupts <= 0 or ctx.kickCapable <= 0 then
			return 0, false -- nothing was kicked this fight: not scoreable
		end
		local fairShare = ctx.totals.interrupts / ctx.kickCapable
		local smoothed = math.min(100, 100 * (value + 0.5) / (fairShare + 0.5))
		if value <= 0 then
			smoothed = math.min(smoothed, 55)
		end
		return smoothed, true
	end

	if key == "dispels" then
		if not TP.Scoring.Capabilities.CanDispel(p.class, p.specID,
			ctx.totals.dispelTypes, role) then
			return 0, false -- can't cleanse what this fight presented
		end
		if ctx.totals.dispels <= 0 then
			return 0, false -- nothing dispellable happened
		end
		local fairShare = ctx.totals.dispels / ctx.playerCount
		local smoothed = math.min(100, 100 * (value + 0.5) / (fairShare + 0.5))
		if value <= 0 then
			smoothed = math.min(smoothed, 55)
		end
		return smoothed, true
	end

	if key == "prescience" then
		-- Self-reported Prescience casts (retail Aug), scored as CADENCE:
		-- keeping two Prescience buffs up means casting near on-cooldown.
		-- True uptime isn't readable (ally auras are secret, the Evoker has
		-- no personal aura), so casts/min vs an expected rate is the honest
		-- proxy. Ebon Might is deliberately NOT scored here (Josh
		-- 2026-07-26): its contribution already lands in the Amplified
		-- (effective-damage) metric via the attribution below, so scoring
		-- its uptime too would double-count it. Absent -> weight
		-- redistributes, exactly like a missing capability.
		local casts = p.metrics and p.metrics.prescience
		if not casts or not ctx.duration or ctx.duration <= 0 then
			return 0, false
		end
		local perMin = casts / (ctx.duration / 60)
		return math.min(100, 100 * perMin / (W.prescienceCadenceAnchor or 5)), true
	end

	if key == "mitigation" then
		-- A tank's primary metric (Josh 2026-07-26): active-mitigation
		-- UPTIME scored as a percentile against the spec's real WCL field
		-- (Data/TankAnchors, crawled) - "you held mitigation up 57%, the
		-- average Guardian holds 66%". WCL-relative, not arbitrary: the one
		-- survival stat WCL actually exposes (its Buffs table).
		if role ~= "TANK" then
			return 0, false
		end
		local up = p.metrics and p.metrics.mitigationPct
		-- A flat 0% is treated as "not measured", not "never pressed the
		-- button" (Josh 2026-07-29: his retail Prot Paladin showed
		-- "Mitigation up 0%; the spec median holds 89%", score 0, on 55% of
		-- the grade). A tank who goes a whole fight without one active
		-- mitigation cast is vanishingly rare; a buff id we don't watch is
		-- not - the retail list is still the provisional seed from Classic
		-- and any spec it misses gets its grade zeroed silently. Wrong-way
		-- risk is wildly asymmetric here, so a hard zero has to earn its
		-- keep and it can't. Genuine negligence still shows up in damage
		-- taken, deaths and the defensive-cooldown timing metric.
		if not up or up <= 0 then
			-- IMPUTED, not redistributed (Josh 2026-07-28). Redistribution
			-- is only sound for a SMALL weight; this one is 0.55, so
			-- spreading it doesn't fill a gap - it replaces the tank's
			-- grade with their damage meter, and silently certifies elite
			-- mitigation on zero evidence. Worse, it inverted the
			-- incentive: reporting beat not-reporting only when your
			-- mitigation percentile exceeded your OWN throughput
			-- percentile (the 0.55 cancels), so measured against real
			-- history a reporting tank was never ahead - 4 worse, 2 tied,
			-- 0 better, worst case -44 points.
			-- Pin neutral instead: "we did not measure this, assume
			-- average". Same treatment an Aug with no uptime report gets
			-- further down, for the same reason. Now reporting gains above
			-- median uptime and loses below it, symmetrically.
			return 50, true
		end
		local AN = TP.TANK_ANCHORS or {}
		local a = (p.specID and AN[p.specID]) or AN.default or { 30, 55, 75 }
		return anchorScore(up, a[1], a[2], a[3]), true
	end

	-- Damage soaked: no external population exists (WCL doesn't rank damage
	-- taken), so it's your share of the group's damage taken against the
	-- expected tank share SPLIT BY TANK COUNT. Co-tanks splitting duty both
	-- score well; the old cohort comparison handed the bigger soaker a
	-- structural 100 every fight.
	if key == "damageTaken" then
		if role ~= "TANK" then
			return 0, false
		end
		local groupTotal = ctx.totals.damageTaken
		if not groupTotal or groupTotal <= 0 then
			return 0, false
		end
		local tankCount = math.max(1, #(ctx.cohorts.TANK or {}))
		local expected = ((TP.Scoring.Weights.expectedShare.TANK.damageTaken) or 0.58) / tankCount
		local share = (p.metrics.damageTaken or 0) / groupTotal
		local score = math.min(TP.Scoring.Weights.soloCohortCap or 100, 100 * share / expected)
		return score, true, nil, score
	end

	-- TANK DAMAGE against the field of tanks, not the field of damage-ranked
	-- tanks (Josh 2026-07-28, measured on 219 real MoP fights): on the SAME
	-- fights the damage metric's median was 59.5 for DPS and 59.8 for
	-- healers - and 26.0 for tanks. Healers score fine against a damage
	-- curve, so a 34-point tank-only collapse is the reference population,
	-- not the players: the ranked curves are built from tanks who turn up in
	-- damage rankings, a self-selected damage-pushing slice. Data/TankDamage
	-- crawls every tank in a log instead, as a SHARE of the raid's damage so
	-- one anchor per spec holds across encounters, brackets and gear.
	-- Needs the group's damage to take a share of, so the retail
	-- self-report path (no group) keeps the curve; Raw is throughput-only
	-- and never re-anchored.
	-- RAID-SIZED GROUPS ONLY. The anchors are a share of the raid's damage,
	-- crawled from 20-player logs where a tank contributes ~4%. In a 5-man
	-- the same tank is naturally ~25% of the group's damage, which sails
	-- past p75 and pegs the metric at 99 (Josh 2026-07-29: damage read 99
	-- on all five bosses of a Timewalking run). A share anchor only means
	-- anything against the roster size it was measured on.
	local scoredCount = ctx.cohorts and
		(#(ctx.cohorts.TANK or {}) + #(ctx.cohorts.HEALER or {})
			+ #(ctx.cohorts.DAMAGER or {}) + #(ctx.cohorts.SUPPORT or {}))
	if role == "TANK" and key == "damage" and not ctx.parseMode
		and scoredCount and scoredCount > 5 then
		local AN = TP.TANK_DAMAGE_ANCHORS
		local a = AN and ((p.specID and AN[p.specID]) or AN.default)
		local groupTotal = ctx.totals and ctx.totals.damage
		if a and groupTotal and groupTotal > 0 then
			local share = (p.metrics.damage or 0) / groupTotal * 100
			local score = anchorScore(share, a[1], a[2], a[3])
			return score, true, score
		end
	end

	-- Throughput family. Two views, blended when both exist:
	--  * ABSOLUTE: preferred source is the bracket percentile curve mapped
	--    through the contribution transform (p50 -> 65, elite -> ~100);
	--    fallback is the elite-median anchor (whose ilvl extrapolation
	--    collapses far below elite gear — see Weights).
	--  * RELATIVE: cohort comparison (spec/ilvl-adjusted), expected-share
	--    fallback for solo-role slots — differentiates the room.
	-- Augmentation: score EFFECTIVE damage (own + buff-attributed) against
	-- the DPS population, not the tiny personal number. Attribution is
	-- computed in ScoreFight when the Aug self-reports Ebon Might uptime;
	-- absent it, SUPPORT damage stays out of the curve path as before.
	local curveRole, curveVal = role, metricValue(p, key)
	if role == "SUPPORT" and key == "damage"
		and ctx.effectiveDamage and ctx.effectiveDamage[p.guid] then
		curveRole, curveVal = "DAMAGER", ctx.effectiveDamage[p.guid]
	end

	local absolute, fromCurve
	if curveRole ~= "SUPPORT" and ctx.duration and ctx.duration > 0 then
		local kind = (key == "healing") and "hps" or (key == "damage") and "dps"
		-- True mode only: the full cross-encounter ladder must not leak
		-- into Raw's fallback chain (parse curves resolve encounter-local
		-- in the parse branch below)
		if kind and not ctx.parseMode then
			local entry, label, pooled, scale = findCurve(ctx, kind, p.specID, curveRole)
			if entry then
				rolePooled = pooled
				curveFrom = label
				-- scale converts the player's rate INTO the borrowed
				-- bracket's population before interpolating; on a derived
				-- tier it also carries the gear + off-difficulty lift
				scale = (scale or 1) * derivedScale(ctx, p)
				-- dungeon samples are keystone-ordered, not metric-ordered
				local metricOrdered = not (ctx.curves and ctx.curves.dungeonOnly)
				local pct = entryPercentileFor(entry,
					scale * curveVal / ctx.duration, metricOrdered)
				-- True's base IS the percentile (Josh 2026-07-25); the old
				-- 30 + 0.7x softener predated adjustments, which now do the
				-- earning-back honestly. Knobs neutral in Weights.
				absolute = math.min(100, (W.trueAbsFloor or 0) + (W.trueAbsSlope or 1) * pct)
				-- A derived tier can approximate a good parse, never certify an
				-- elite one — but SQUEEZE the top rather than clamping it, or a
				-- third of the field lands on the same number (see Weights).
				-- (the derived ceiling used to compress HERE, per metric.
				-- Moved to the composite 2026-07-28: capping each metric
				-- pegged them individually - a tank showed Damage 90 and
				-- Healing 90, both sitting exactly on the tier-III ceiling,
				-- which threw away the difference between a raw 92 and a
				-- raw 99 - while adjustments still added on top afterwards,
				-- so the FINAL score reached 98 on the roughest evidence
				-- tier. The ceiling has to bound the thing it is about.)
				fromCurve = true
				pctile = pct -- raw percentile, for the tooltip gauge
				-- surfaced in tooltips: "the median of your spec does Y/s
				-- here" — answers every 'but I topped the meter?!'
				-- (converted back into the fight's own bracket terms).
				-- curveP50 is nil for a curve with no p50 sample (a future
				-- sparse crawl) — guard the divide (Josh 2026-07-26 audit)
				local p50 = curveP50(entry.curve)
				specMedian = p50 and p50 / (scale or 1) or nil
			end
		end
		if not absolute and ctx.fightFactors then
			local medians = (key == "healing") and ctx.fightFactors.healingMedian
				or (key == "damage") and ctx.fightFactors.damageMedian
			local bench = medians and p.specID and medians[p.specID]
			if bench and bench > 0 then
				local B = TP.Benchmarks
				if ctx.normalizeIlvl and B.ilvlSlopePct and p.ilvl and ctx.fightFactors.ilvlMedian then
					bench = bench * (1 + B.ilvlSlopePct / 100) ^ (p.ilvl - ctx.fightFactors.ilvlMedian)
				end
				bench = bench * (W.absoluteAnchor or 1)
				absolute = math.min(100, 100 * (curveVal / ctx.duration) / bench)
			end
		end
	end

	-- A per-spec, per-fight, per-bracket population percentile is complete
	-- evidence: blending in the cohort comparison only re-introduces the
	-- structural spec biases it exists to paper over (Blood DK self-healing
	-- vs other tanks, Disc/Mistweaver damage vs other healers). Curves for
	-- EVERY spec x metric make cross-metric contributions spec-fair.
	if absolute and fromCurve and not ctx.parseMode then
		return absolute, true, absolute, nil, specMedian, pctile, rolePooled, curveFrom
	end

	local relative, applicable
	local adjusted = adjustedValue(p, role, key, ctx)
	local cohort = ctx.cohorts[role]
	if #cohort > 1 then
		local best = 0
		for _, member in ipairs(cohort) do
			local v = adjustedValue(member, role, key, ctx)
			if v > best then
				best = v
			end
		end
		if best > 0 then
			relative, applicable = math.min(100, 100 * adjusted / best), true
		end
	else
		local expected = W.expectedShare[role] and W.expectedShare[role][key]
		local groupTotal = ctx.totals[key]
		if expected and groupTotal and groupTotal > 0 then
			relative = math.min(W.soloCohortCap or 100, 100 * (adjusted / groupTotal) / expected)
			applicable = true
		end
	end

	if ctx.parseMode then
		-- Best evidence first: a true population percentile when a curve
		-- covers this fight+spec (raw per-second output, no ilvl adjustment
		-- — WCL's headline parse doesn't bracket by gear either), then the
		-- %-of-elite-median, then the group comparison.
		local kind = (key == "healing") and "hps" or (key == "damage") and "dps"
		if kind and curveRole ~= "SUPPORT" and ctx.duration and ctx.duration > 0 then
			-- encounterOnly: a parse never borrows other bosses' populations.
			-- Aug scores its effective damage against the DPS population.
			local entry, label, pooled, scale = findCurve(ctx, kind, p.specID, curveRole, false, true)
			if entry then
				rolePooled = pooled
				curveFrom = label
				local metricOrdered = not (ctx.curves and ctx.curves.dungeonOnly)
				local pct = entryPercentileFor(entry,
					(scale or 1) * curveVal / ctx.duration, metricOrdered)
				local p50 = curveP50(entry.curve) -- nil-safe divide (audit)
				specMedian = p50 and p50 / (scale or 1) or nil
				return pct, true, pct, nil, specMedian, pct, rolePooled, curveFrom
			end
		end
		-- WCL semantics: 100 doesn't exist. And a relative-only fallback
		-- (no benchmark for this fight) makes the group's best a 99 "parse"
		-- by definition — the UI marks those scores as approximations.
		if absolute then
			return math.min(absolute, 99), true, math.min(absolute, 99), nil
		elseif relative then
			return math.min(relative, 99), applicable, nil, math.min(relative, 99)
		end
		return 0, false
	end

	if absolute and relative then
		local blend = W.absoluteBlend or 0
		return blend * absolute + (1 - blend) * relative, true, absolute, relative
	elseif absolute then
		return absolute, true, absolute, nil
	elseif relative then
		return relative, applicable, nil, relative
	end
	return 0, false
end

-- Parse mode: the WCL-style lens. One metric CARRIES the score; the other
-- big-3 metrics compute at zero weight so the breakdown can always show
-- them (a healer's p92 damage deserves a line even when it isn't graded).
local PARSE_WEIGHTS = {
	TANK = { damage = 1, healing = 0, damageTaken = 0 },
	HEALER = { healing = 1, damage = 0, damageTaken = 0 },
	DAMAGER = { damage = 1, healing = 0, damageTaken = 0 },
	SUPPORT = { damage = 1, healing = 0 },
}

-- Public for Awards (Virtuoso needs off-metric percentiles) and tooling
Engine.ResolvePercentiles = resolvePercentiles
Engine.PercentileFor = percentileFor
Engine.EntryPercentileFor = entryPercentileFor

-- Group kill speed vs WCL's ranked kills for this encounter+bracket.
-- killTime curves hold durations in seconds, ascending from p99 (fastest)
-- to p10; smaller is better, so this mirrors percentileFor reversed.
local function speedPercentile(curve, duration)
	if duration <= curve[1][2] then
		return 99
	end
	local prev = curve[1]
	for i = 2, #curve do
		local pt = curve[i]
		if duration <= pt[2] then
			local span = pt[2] - prev[2]
			if span <= 0 then
				return pt[1]
			end
			return prev[1] - (prev[1] - pt[1]) * (duration - prev[2]) / span
		end
		prev = pt
	end
	-- slower than the slowest sample: fade to 0 by twice its duration
	local last = curve[#curve]
	if last[2] <= 0 or duration >= last[2] * 2 then
		return 0
	end
	return last[1] * (1 - (duration - last[2]) / last[2])
end

-- WCL's fightRankings endpoint hard-caps at 1000 results (20 pages of 50),
-- ordered fastest-first (verified live 2026-07-18: page 20 full with
-- hasMorePages=true, page 21 empty). So any boss with more than 1000 logged
-- kills gives us only the FASTEST 1000, and the slow tail is never served.
local SPEED_RANK_CAP = 1000

-- Returns pct, populationSize, medianSeconds, bounded — or nil (wipe, no
-- data, or a capped field we can't size). When the sample is capped, pct is
-- rescaled against the TRUE field size crawled from report rankings
-- (killTime.total): the raw sample percentile reads every real kill as
-- bottom-decile against a fastest-1000 leaderboard. The old estimator
-- (sum of per-spec parse counts / raid size) is gone — validated 2026-07-22
-- against WCL's own speed rankPercents, it overestimated the field ~3x
-- (parse counts tally distinct characters ever, not ranked kills), which
-- inflated the share line badly (announced 81, truth 41). Capped data
-- without a crawled total now reports nothing rather than guessing.
-- bounded=true means the kill was slower than the 1000th-fastest: its true
-- rank is past the served data, so pct is only a ceiling.
function Engine.KillSpeedPercentile(fight)
	-- a dummy session's duration is attention span, not a kill time
	if fight.wipe or fight.practice or not fight.duration or fight.duration <= 0 then
		return nil
	end
	local P = TP.Percentiles
	if not P then
		return nil
	end
	local enc, runScoped = encounterCurvesFor(P, fight)
	if not enc or runScoped then
		-- dungeon-keyed killTime curves measure full runs; neither a single
		-- boss fight nor a RUN aggregate (trash time excluded) can honestly
		-- compare against them (audit 2026-07-24: CM bosses always read p99)
		return nil
	end
	local key = fight.difficultyID and WCL_BRACKET[fight.difficultyID]
	local bracket = (key and enc[key]) or enc.all
	local kt = bracket and bracket.killTime
	if not (kt and kt.curve and #kt.curve > 1) then
		return nil
	end
	local curve = kt.curve
	local sampleN = kt.n or SPEED_RANK_CAP

	-- Uncapped: WCL served the whole field, so the sample percentile IS the
	-- true percentile (e.g. retail Midnight Falls Normal, n=676).
	if sampleN < SPEED_RANK_CAP then
		return speedPercentile(curve, fight.duration), sampleN, curveP50(curve), false
	end

	-- Capped: rescale the fastest-1000 sample by the crawled true field.
	local N = kt.total
	if not N or N <= sampleN then
		-- no totals crawled for this bracket — nothing honest to give
		return nil
	end
	if fight.duration > curve[#curve][2] then
		-- slower than the 1000th-fastest kill: rank is beyond the served
		-- data and the tail shape is unknown. Report the field ceiling.
		return 100 * (1 - sampleN / N), N, nil, true
	end
	-- within the served field: the sample percentile gives an exact rank,
	-- which the true field size turns into an accurate percentile
	local samplePct = speedPercentile(curve, fight.duration)
	local rank = (100 - samplePct) / 100 * sampleN
	local truePct = 100 * (1 - rank / N)
	if truePct < 0 then
		truePct = 0
	elseif truePct > 99 then
		truePct = 99
	end
	return truePct, N, nil, false
end

-- Field comp for this fight's bracket: how many healers ranked kills of
-- this boss actually bring (crawled healer-count distribution stored on
-- killTime by fetch-killtimes.ps1; raid zones only). Returns the healers
-- table { avg, mode, modePct } and the field's average raid size — nil
-- when the data (or the fight's bracket) is absent.
function Engine.HealerCountField(fight)
	local P = TP.Percentiles
	if not P or fight.practice then
		return nil -- nobody comps for a dummy
	end
	local enc = encounterCurvesFor(P, fight)
	if not enc then
		return nil
	end
	local key = fight.difficultyID and WCL_BRACKET[fight.difficultyID]
	local bracket = (key and enc[key]) or enc.all
	local kt = bracket and bracket.killTime
	if not (kt and kt.healers) then
		return nil
	end
	return kt.healers, kt.avgSize
end

-- Where this encounter's median kill time ranks among the tier's bosses
-- (same data file, same bracket): 0 = the tier's fastest-killed boss,
-- 1 = the slowest. Group-card context, so a rough score on a rough boss
-- reads fairly. Returns rank, bossesCompared — nil without enough peers.
function Engine.EncounterToughness(fight)
	local P = TP.Percentiles
	if not (P and P.encounters and fight.isBoss) or fight.practice then
		return nil
	end
	local enc = encounterCurvesFor(P, fight)
	local key = fight.difficultyID and WCL_BRACKET[fight.difficultyID]
	local kt = enc and key and enc[key] and enc[key].killTime
	local mine = kt and kt.curve and curveP50(kt.curve)
	if not mine then
		return nil
	end
	local atOrBelow, total = 0, 0
	for _, e in pairs(P.encounters) do
		local okt = type(e) == "table" and e[key] and e[key].killTime
		local med = okt and okt.curve and curveP50(okt.curve)
		if med then
			total = total + 1
			if med <= mine then
				atOrBelow = atOrBelow + 1
			end
		end
	end
	if total < 4 then
		return nil
	end
	return atOrBelow / total, total
end

-- fight: a FightHistory record. opts.normalizeIlvl (default true) grades
-- throughput relative to gear. Returns an array sorted by score desc:
-- { guid, name, class, role, score, base, penalty, breakdown }, where
-- breakdown[metric] = { weight, effectiveWeight, normalized, contribution,
-- applicable, value }.
function Engine.ScoreFight(fight, opts)
	local W = TP.Scoring.Weights
	local Cap = TP.Scoring.Capabilities
	opts = opts or {}

	local players = {}
	for _, p in pairs(fight.players) do
		players[#players + 1] = p
	end
	if #players == 0 then
		return {}
	end

	local ctx = {
		playerCount = #players,
		cohorts = {},
		kickCapable = 0,
		normalizeIlvl = opts.normalizeIlvl ~= false,
		parseMode = (opts.mode == "parse"),
		percentiles = resolvePercentiles(fight), -- raw pct in parse; transformed in True
		fightFactors = resolveFightFactors(fight),
		curves = nil, -- widening WCL evidence ladder, set below
		duration = fight.duration,
		totals = { damage = 0, healing = 0, damageTaken = 0, interrupts = 0, dispels = 0, avoidable = 0,
			-- debuff types actually dispelled this fight (learned at
			-- capture): gates who is ELIGIBLE for dispel scoring
			dispelTypes = fight.totals and fight.totals.dispelTypes or nil },
	}

	-- The ladder covers every boss fight the moment ANY percentile data is
	-- loaded — an unlisted encounter or unknown bracket zooms out to the
	-- populations we do have instead of dropping to a group comparison
	do
		local P = TP.Percentiles
		if P and P.encounters and (fight.isBoss or fight.isRun) then
			local enc = encounterCurvesFor(P, fight)
			local bracketKey = fight.difficultyID and WCL_BRACKET[fight.difficultyID]
			-- the ladder must never cross instance types (2026-07-16):
			-- a Timewalking dungeon with no curves zoomed out to the RAID
			-- all-bosses pool and scored ilvl-119-scaled players p3 while
			-- Raw went group-relative and said p99. Dungeon fights use
			-- THIS dungeon's curves or none — both lenses then agree.
			local isDungeon = fight.instanceType == "party"
				or fight.keystoneLevel ~= nil
				or (fight.difficultyID and DUNGEON_DIFF_IDS[fight.difficultyID])
				or DUNGEON_ABSOLUTE_DIFFICULTY[fight.difficulty or ""] or false
			-- backstop (Josh 2026-07-25): a fight with NO matched curves
			-- and NO recognizable bracket has no business on the ladder —
			-- a bulk-unlocked TW dungeon lost its instance context, read
			-- as "not a dungeon", and its level-scaled mage was laddered
			-- into max-level raid pools (parsed 9 while topping Details)
			-- M+ ranks as ONE population regardless of key level (Josh
			-- 2026-07-28: the bracket, not the key) — any key is a direct
			-- comparison against the dungeon's curves.
			--
			-- ...but only DOWN TO A POINT (Josh 2026-07-29). Those curves are
			-- WCL's top 2000 BY KEYSTONE SCORE, so the ranked population is
			-- high-key, high-gear players. Measured on his +2/+3 night: 42 DPS
			-- scores, ratio to the reference p25 0.103 / median 0.186 / max
			-- 0.402 — a 5.4x gap at the median — and 97.6% landed under 10.
			-- Item level ran 195-270 against a reference near 291. Tier 1
			-- applies NO gear normalization (correct for a raw parse: better
			-- gear should parse higher), so nothing absorbed that gap.
			-- A low key is exactly the tier-II case — "the curves cover this
			-- encounter, sampled at a difficulty the player didn't run" — so
			-- treat it as derived: keep THIS dungeon's own curves (real
			-- encounter evidence, no pooling), but gear-scale, lift, ceiling
			-- and LABEL the comparison. At or above the threshold nothing
			-- changes, so a genuine high-key parse can still certify 99.
			-- An M+ fight whose key level went MISSING counts as low too: two
			-- of Josh's Saprish pulls came back with keystoneLevel nil and
			-- stayed on the direct path, scoring ~0 while their siblings from
			-- the same run were rescued. Unknown key cannot claim to be the
			-- ranked population, and the derived path is the labelled,
			-- conservative read — the same backstop logic the ladder uses
			-- above for a capture that lost its instance context.
			local isKeyed = fight.keystoneLevel ~= nil or fight.difficultyID == 8
			local lowKey = isKeyed
				and ((fight.keystoneLevel or 0) < (W.mplusDirectKey or 0)) or false
			local isMplus = (fight.keystoneLevel ~= nil or fight.difficultyID == 8
				or DUNGEON_ABSOLUTE_DIFFICULTY[fight.difficulty or ""] or false)
				and not lowKey
			if (enc or bracketKey) and not (isDungeon and not enc) then
				local useEnc, dOnly = enc, isDungeon or nil
				-- A low key POOLS like any other derived fight. Keeping this
				-- dungeon's own curves looks like better evidence — same
				-- encounter, only the key band differs — but measured, it is
				-- not: those curves span just 1.45x p10->p99 (top-2000-by-
				-- keystone-score has no lower tail) while a real low-key group
				-- spans 7x internally, so no shift of them can place both ends
				-- (swept: DAMAGER median jumped 16.6 -> 89.4 between lift 2.5
				-- and 3.0 while under-10 barely moved). The pooled raid
				-- reference spans 2.84x and can.
				if isDungeon and enc and not isMplus then
					local pooled = averageSeasonalDungeon(P)
					if pooled then useEnc, dOnly = pooled, nil end
				end
				ctx.curves = { P = P, enc = useEnc,
					order = (useEnc ~= enc) and { "all" } or bracketSearchOrder(bracketKey),
					exact = (useEnc == enc) and bracketKey or nil, dungeonOnly = dOnly }
				-- T2: the curves cover this encounter but not the difficulty
				-- that was actually played. Dungeons only — a raid missing
				-- its own bracket already gets the measured bracketRatio
				-- correction walking BRACKET_NEIGHBORS, which is strictly
				-- better evidence than a flat lift.
				if isDungeon and enc and not isMplus then
					ctx.derived = {
						tier = 2,
						refIlvl = percentileRefIlvl(P),
						levelScaled = (fight.difficultyID == 24) or nil,
						-- a low key needs its OWN lift: derivedOffDifficulty was
						-- fitted for a Normal/Heroic clear of a dungeon WCL
						-- only ranks at M+, a far smaller gap than +2 against
						-- the top-key population
						offDifficulty = (lowKey and W.mplusLowKeyLift)
							or W.derivedOffDifficulty or 1,
						lowKey = lowKey or nil,
						label = fight.zone,
					}
				elseif fight.practice and enc then
					-- A DUMMY IS ALWAYS DERIVED (Josh 2026-07-30: "shouldn't
					-- that be a tier II?"). It scores against the tier's
					-- patchwerk anchor — a REAL WCL curve, for a DIFFERENT
					-- fight — which is the tier-II idea exactly. The stamp
					-- above never fired for it because a dummy is not a
					-- dungeon, so practice inherited no tier and the chip
					-- read DIRECT: "ranked at the difficulty you played",
					-- which is the one thing it certainly wasn't.
					-- No lift: a dummy stands still and never phases, so if
					-- anything it should read HARSHER than the anchor, and
					-- inventing a discount here would be a guess. The tier-II
					-- ceiling (95) already stops a rehearsal certifying 99.
					ctx.derived = {
						tier = 2,
						refIlvl = percentileRefIlvl(P),
						offDifficulty = W.derivedOffDifficulty or 1,
						practice = true,
						label = TP.PRACTICE_ANCHOR and TP.PRACTICE_ANCHOR.name or nil,
					}
				end
			elseif fight.duration and fight.duration > 0 then
				-- T3: nothing covers this fight. Rather than hand the room's
				-- best a 99 by definition, compare against the pooled average
				-- of every seasonal dungeon we ship.
				local avg, poolKind = averageSeasonalDungeon(P)
				if avg then
					-- The DERIVED comparison is True's alone. Raw means "your
					-- actual WCL parse", and there is no parse to show on
					-- content nobody ranks — so Raw keeps the old
					-- group-relative approximation and the panel disables the
					-- lens. The tier itself is still recorded in both modes:
					-- that flag is exactly what tells the UI to disable Raw.
					if not ctx.parseMode then
						ctx.curves = { P = P, enc = avg, order = { "all" },
							exact = nil, dungeonOnly = true }
					end
					ctx.derived = {
						tier = 3,
						refIlvl = percentileRefIlvl(P),
						levelScaled = (fight.difficultyID == 24) or nil,
						-- the off-difficulty lift corrects for the DUNGEON
						-- curves being top-runs-skewed. A raid-pooled
						-- fallback (a client with no dungeon data, e.g. MoP
						-- Celestials) is already a real population spread —
						-- lifting it too would just inflate the scores.
						offDifficulty = ((fight.difficultyID == 24)
							and W.derivedOffDifficultyScaled
							or W.derivedOffDifficultyT3) or 1,
						pool = poolKind,
					}
				end
			end
		end
	end

	-- Reference ilvl for gear normalization: group mean of known ilvls
	local ilvlSum, ilvlCount = 0, 0
	for _, p in ipairs(players) do
		if p.ilvl and p.ilvl > 0 then
			ilvlSum = ilvlSum + p.ilvl
			ilvlCount = ilvlCount + 1
		end
	end
	if ilvlCount >= 2 then
		ctx.meanIlvl = ilvlSum / ilvlCount
	end
	for _, p in ipairs(players) do
		local m = p.metrics
		ctx.totals.damage = ctx.totals.damage + (m.damage or 0)
		ctx.totals.healing = ctx.totals.healing + effHealing(m)
		ctx.totals.damageTaken = ctx.totals.damageTaken + (m.damageTaken or 0)
		ctx.totals.interrupts = ctx.totals.interrupts + (m.interrupts or 0)
		ctx.totals.dispels = ctx.totals.dispels + (m.dispels or 0)
		ctx.totals.avoidable = ctx.totals.avoidable + (m.avoidableTaken or 0)

		local role = normalizeRole(p)
		ctx.cohorts[role] = ctx.cohorts[role] or {}
		table.insert(ctx.cohorts[role], p)
		if Cap.CanInterrupt(p.class, role) then
			ctx.kickCapable = ctx.kickCapable + 1
		end
	end

	-- Augmentation buff attribution (see Weights.ebonTransfer): credit the
	-- Aug the damage their buffs enabled, approximated from the self-
	-- reported Ebon Might uptime applied to the top-N buffed allies. Runs
	-- after cohorts so the buffed set (highest-damage non-supports) is
	-- known; scored as DPS in normalizeMetric via ctx.effectiveDamage.
	-- Ebon Might uptime (buffUptime) feeds THIS and nothing else now: it is
	-- the Amplified metric's input, not a separately scored metric.
	do
		local transfer = W.ebonTransfer or 0.12
		local nTargets = W.ebonTargets or 4
		for _, p in ipairs(players) do
			if normalizeRole(p) == "SUPPORT" and p.metrics and p.metrics.buffUptime then
				local allyDmg = {}
				for _, o in ipairs(players) do
					if o ~= p and normalizeRole(o) ~= "SUPPORT" then
						allyDmg[#allyDmg + 1] = o.metrics and o.metrics.damage or 0
					end
				end
				table.sort(allyDmg, function(a, b) return a > b end)
				local buffed = 0
				for i = 1, math.min(nTargets, #allyDmg) do
					buffed = buffed + allyDmg[i]
				end
				local attributed = buffed * p.metrics.buffUptime * transfer
				if attributed > 0 then
					ctx.effectiveDamage = ctx.effectiveDamage or {}
					ctx.attribution = ctx.attribution or {}
					ctx.effectiveDamage[p.guid] = (p.metrics.damage or 0) + attributed
					ctx.attribution[p.guid] = { own = p.metrics.damage or 0, attributed = attributed }
				end
			end
		end
	end

	-- Healing demand: when nobody died and nobody even dipped (Classic
	-- health sampler), share-based healing comparisons are noise — passive
	-- DPS self-healing outweighs real healing when there's nothing to heal.
	-- Healers get a neutral floor instead of a "low healing" slap.
	do
		local deaths = 0
		for _, p in ipairs(players) do
			deaths = deaths + (p.metrics.deaths or 0)
		end
		ctx.noDeaths = deaths == 0
		if ctx.noDeaths then
			local sampled, worst = 0, 1
			for _, p in ipairs(players) do
				if p.minHealthPct then
					sampled = sampled + 1
					if p.minHealthPct < worst then
						worst = p.minHealthPct
					end
				end
			end
			ctx.lowHealingDemand = (sampled > 0 and worst >= 0.70) or nil
		end
	end

	local results = {}
	for _, p in ipairs(players) do
		local role = normalizeRole(p)
		local weights = ctx.parseMode and PARSE_WEIGHTS[role] or W.roleWeights[role]

		-- Per-spec throughput profile ("the TrueParse profile"): the role's
		-- damage+healing weight BUDGET is split by this spec's population
		-- median mix on this exact fight+bracket. A spec whose median player
		-- heals 5% of their throughput carries ~5% of the budget as healing
		-- weight; a Blood DK's fat self-healing median earns a real healing
		-- slice; Disc damage earns damage weight other healers don't get.
		-- Data-derived, per-fight, refreshed weekly — no hand-tuned table.
		if not ctx.parseMode and ctx.curves and p.specID and role ~= "SUPPORT" then
			-- specOnly ladder: the mix may zoom to other brackets or the
			-- spec's all-boss pool, but never to a role's generic mix
			local dEntry, _, _, dScale = findCurve(ctx, "dps", p.specID, role, true)
			local hEntry, _, _, hScale = findCurve(ctx, "hps", p.specID, role, true)
			-- and-or precedence made this `dEntry and (curveP50()/scale)`,
			-- which crashed when the curve had no p50 (Josh 2026-07-26
			-- audit); split so the divide only runs on a real median
			local d50 = dEntry and curveP50(dEntry.curve)
			local h50 = hEntry and curveP50(hEntry.curve)
			d50 = d50 and d50 / (dScale or 1)
			h50 = h50 and h50 / (hScale or 1)
			local budget = (weights.damage or 0) + (weights.healing or 0)
			-- BOTH medians required: a missing curve means "no data", not
			-- "zero output" — one-sided evidence must not zero a weight
			if d50 and h50 and budget > 0 then
				local mix = h50 / math.max(1, d50 + h50)
				mix = math.min(0.95, mix)
				-- HEALING DEMAND (Josh 2026-07-28): with nothing to heal, a
				-- healer should be judged on the thing they could still
				-- control - their damage - rather than on healing that was
				-- never needed. Demand is the group's incoming damage per
				-- healer measured against THIS spec's own median HPS, so 1.0
				-- means "a normal fight for this spec" and the mix above
				-- stands unchanged. At zero it slides all the way to the
				-- DAMAGER mix and the healer is graded like a DPS.
				-- Complements the low-demand FLOOR further down: the floor
				-- stops a needless healing score from hurting, this decides
				-- how much that score should have counted in the first place.
				if role == "HEALER" and h50 > 0 and ctx.duration and ctx.duration > 0 then
					local healerN = math.max(1, #(ctx.cohorts.HEALER or {}))
					local demand = (ctx.totals.damageTaken or 0) / ctx.duration / healerN
					local ratio = demand / h50
					if ratio < 0 then ratio = 0 elseif ratio > 1 then ratio = 1 end
					local dw = W.roleWeights.DAMAGER or {}
					local dTotal = (dw.damage or 0) + (dw.healing or 0)
					local dpsMix = (dTotal > 0) and ((dw.healing or 0) / dTotal) or mix
					mix = dpsMix + (mix - dpsMix) * ratio
				end
				local specWeights = {}
				for k, v in pairs(weights) do
					specWeights[k] = v
				end
				specWeights.damage = budget * (1 - mix)
				specWeights.healing = budget * mix
				weights = specWeights
			end
		end

		local breakdown = {}
		local activeWeight = 0
		for key, weight in pairs(weights) do
			local normalized, applicable, absolute, relative, specMedian, pctile, rolePooled, curveFrom = normalizeMetric(p, role, key, ctx)
			-- Trivial-demand floors, True mode only (a raw parse SHOULD
			-- read low on a fight with nothing to heal):
			-- 1) share-based healing when nobody dipped (Classic vitals);
			-- 2) demand cap: you can't heal damage that never went out.
			--    When the fight's per-healer incoming damage is below the
			--    spec's own median output AND this healer covered most of
			--    their share of it, a low percentile is physics, not
			--    performance. Exact-encounter curves price demand
			--    (their population healed the same fight) — ZOOMED pools
			--    don't (a dungeon healer measured against raid volumes).
			local lowDemand, demandMet
			if key == "healing" and role == "HEALER" and applicable
				and not ctx.parseMode and normalized < 75 then
				if not absolute and ctx.lowHealingDemand then
					normalized = 75
					lowDemand = true
				elseif (not absolute or curveFrom ~= nil)
					and ctx.noDeaths
					and ctx.duration and ctx.duration > 0 then
					local healerN = math.max(1, #(ctx.cohorts.HEALER or {}))
					local demandShare = (ctx.totals.damageTaken or 0) / ctx.duration / healerN
					local healed = metricValue(p, key)
					local covered = healed >= demandShare * ctx.duration * 0.7
					-- WHY the floor fired, which is not one story (Josh
					-- 2026-07-29: "'little to heal' is wrong too", on a
					-- dungeon where he healed 4.67M in 107s). The floor
					-- triggers whenever per-healer intake is under the spec's
					-- median OUTPUT — and a raid spec's median HPS routinely
					-- exceeds a 5-man's whole intake, so it fires on fights
					-- that were plenty busy. Compare intake against what this
					-- healer actually put out instead: only when the fight
					-- asked for far less than they delivered was there truly
					-- "little to heal". Otherwise demand was real and they
					-- MET it, and the label has to say that instead.
					local rate = healed / ctx.duration
					demandMet = (demandShare >= rate * 0.5) or nil
					if specMedian then
						if demandShare < specMedian and covered then
							normalized = 75
							lowDemand = true
						end
					elseif covered and (ctx.totals.healing or 0) >= (ctx.totals.damageTaken or 0) * 0.7 then
						-- no curve to define "real demand" (unranked
						-- content): nobody died and the group's healing
						-- covered its intake — demand was met by
						-- definition, "healing struggled" is wrong
						-- (retail dungeon, 2026-07-15)
						normalized = 75
						lowDemand = true
					end
				end
				-- only meaningful as a reason for the floor
				if not lowDemand then demandMet = nil end
			end
			breakdown[key] = {
				weight = weight,
				normalized = normalized,
				applicable = applicable,
				absolute = absolute, -- vs WCL top-logs median, when available
				relative = relative, -- vs the group, when available
				lowDemand = lowDemand, -- floored: nothing to heal this fight
				demandMet = demandMet, -- ...because they COVERED real intake,
				-- not because the fight was quiet (changes only the wording)
				specMedian = specMedian, -- p50 rate for this spec+fight+bracket
				pctile = pctile, -- raw population percentile (tooltip gauge)
				rolePooled = rolePooled, -- scored vs the ROLE's pooled curve
				curveFrom = curveFrom, -- comparison population when zoomed out
				-- derived tier: this percentile came from WCL data sampled on
				-- OTHER content, gear- and difficulty-scaled to fit (tier 2 =
				-- this dungeon's M+ curves, tier 3 = the pooled curves).
				-- pctile is set only where a curve produced the score — the
				-- fightFactors/cohort fallbacks aren't derived, they're just
				-- the old approximations.
				derived = (pctile and ctx.derived) and ctx.derived.tier or nil,
				value = metricValue(p, key),
			}
			if key == "interrupts" or key == "dispels" then
				-- the tooltip phrases these as "Kicked 2 of the group's 7"
				breakdown[key].groupTotal = ctx.totals[key] > 0 and ctx.totals[key] or nil
			end
			-- Mitigation: the row's number is the uptime percentile; the
			-- tooltip shows the raw uptime vs the spec's WCL median
			if key == "mitigation" then
				breakdown[key].value = (p.metrics and p.metrics.mitigationPct) or 0
				local AN = TP.TANK_ANCHORS or {}
				breakdown[key].anchors = (p.specID and AN[p.specID]) or AN.default
				-- matches the imputation above: a flat 0 is unmeasured, so
				-- the row must show "?" and not a measured mid-pack 50
				if ((p.metrics and p.metrics.mitigationPct) or 0) <= 0 then
					-- the 50 above is an assumption; never let it render as
					-- a measured mid-pack result
					breakdown[key].noInput = true
				end
			end
			-- Aug damage: the row's number is EFFECTIVE (own + buffs
			-- enabled); the tooltip shows the split
			if key == "damage" and ctx.attribution and ctx.attribution[p.guid] then
				local a = ctx.attribution[p.guid]
				breakdown[key].value = a.own + a.attributed
				breakdown[key].attribution = a
			elseif key == "damage" and role == "SUPPORT" and not ctx.parseMode then
				-- No uptime report = the attribution input is missing, and
				-- personal damage is a MISLEADING proxy for an Aug. Pin
				-- neutral (the demand-cap pattern): an unmeasurable number
				-- must not be 72% of a damning grade (2026-07-14).
				breakdown[key].normalized = 50
				breakdown[key].noInput = true
			end
			if applicable then
				activeWeight = activeWeight + weight
			end
		end

		local base = 0
		local conc = 0
		for _, b in pairs(breakdown) do
			if b.applicable and activeWeight > 0 then
				b.effectiveWeight = b.weight / activeWeight
				b.contribution = b.normalized * b.effectiveWeight
				base = base + b.contribution
				conc = conc + b.effectiveWeight * b.effectiveWeight
			else
				b.effectiveWeight = 0
				b.contribution = 0
			end
		end
		-- Restore the spread that blending removed (see Weights.spreadReference).
		-- Uses EFFECTIVE weights, so a role whose metric redistributed - a tank
		-- with no mitigation report, say - is measured on the blend it actually
		-- got, not the one on paper. Only ever expands: a role more concentrated
		-- than a DPS is already at full spread and must not be squashed.
		conc = math.sqrt(conc)
		local ref = W.spreadReference or 0.87
		if conc > 0 and conc < ref then
			base = 50 + (base - 50) * (ref / conc)
			if base < 0 then base = 0 elseif base > 99 then base = 99 end
		end

		-- Count metrics live OUTSIDE the base (2026-07-13 redesign): the
		-- breakdown still carries them for bullets and tooltips, at zero
		-- weight; their influence flows through the adjustments below.
		-- Raw is throughput-only and never carries them.
		if not ctx.parseMode then
			for _, key in ipairs({ "interrupts", "dispels" }) do
				if not breakdown[key] then
					local normalized, applicable = normalizeMetric(p, role, key, ctx)
					breakdown[key] = {
						weight = 0, effectiveWeight = 0, contribution = 0,
						normalized = normalized, applicable = applicable,
						value = metricValue(p, key),
						groupTotal = ctx.totals[key] > 0 and ctx.totals[key] or nil,
					}
				end
			end
			-- tooltip depth (UX rule: new data deepens existing lines, it
			-- never adds new ones)
			local pm = p.metrics
			if breakdown.interrupts and fight.totals and fight.totals.kickOpportunities then
				-- a landed kick proves an opportunity existed: the 10s
				-- post-kick grace can under-count them, and 13/12 is
				-- nonsense — the denominator floors at landed
				breakdown.interrupts.opportunities = math.max(
					fight.totals.kickOpportunities, fight.totals.kicksLanded or 0)
				breakdown.interrupts.landed = fight.totals.kicksLanded
			end
			if breakdown.dispels and pm.dispelReactAvg then
				breakdown.dispels.reactAvg = pm.dispelReactAvg
			end
			if breakdown.damage and pm.overkillPct then
				breakdown.damage.overkillPct = pm.overkillPct
			end
			if breakdown.healing and pm.manaMinPct then
				breakdown.healing.manaMinPct = pm.manaMinPct
				breakdown.healing.dryAt = pm.dryAt
			end
		end

		-- ============ signed adjustments on top of the base ============
		-- The base is the WCL-verifiable story; everything else nudges it.
		-- Positive and negative, context-scaled, absence always neutral,
		-- net clamped so a score never drifts far from its evidence.
		local m = p.metrics
		local A = W.adjustments or {}
		local adj = {}
		local function put(key, pts)
			if pts and math.abs(pts) >= 0.5 then
				adj[key] = pts
			end
		end
		-- linear ramp: lo -> -maxPts, midpoint -> 0, hi -> +maxPts
		local function ramp(v, lo, hi, maxPts)
			local half = (hi - lo) / 2
			if half <= 0 then
				return 0
			end
			local t = (v - (lo + half)) / half
			return math.max(-1, math.min(1, t)) * maxPts
		end

		if not ctx.parseMode then
			-- kicks / dispels: lean vs an even share, scaled by how much of
			-- the mechanic THIS fight had (a kick-heavy fight swings the
			-- full range; a 1-kick fight barely registers)
			local function countAdj(key, maxPts, fullIntensity, volume)
				local b = breakdown[key]
				if not (b and b.applicable) then
					return
				end
				local intensity = math.min(1, (volume or ctx.totals[key] or 0) / fullIntensity)
				local center = A.shareCenter or 55
				local lean = math.max(-1, math.min(1, (b.normalized - center) / (100 - center)))
				-- a player dead for most of the fight couldn't kick or
				-- dispel while dead: scale the below-share penalty by the
				-- fraction of the fight they were alive for (the death is
				-- already charged once — audit 2026-07-18)
				if lean < 0 and (m.deaths or 0) > 0 and p.deathTime
					and ctx.duration and ctx.duration > 0 then
					lean = lean * math.max(0, math.min(1, p.deathTime / ctx.duration))
				end
				-- healers and interrupts (Josh 2026-07-24): kicking is not
				-- the healer's job, so a healer's kicks are bonus-only —
				-- landing them signals a higher level of play, missing
				-- them signals nothing
				if lean < 0 and key == "interrupts" and role == "HEALER" then
					lean = 0
				end
				b.intensity = intensity
				put(key == "interrupts" and "kicks" or key, intensity * maxPts * lean)
				b.adjust = adj[key == "interrupts" and "kicks" or key]
			end
			-- kick intensity prefers TRUE opportunities (kicked + known-
			-- kickable casts that got through) over the landed count: a
			-- fight where 6 casts got away is exactly as kick-heavy as one
			-- where all 6 were stopped
			countAdj("interrupts", A.kicksMax or 6, A.kicksFullIntensity or 6,
				fight.totals and fight.totals.kickOpportunities)
			countAdj("dispels", A.dispelsMax or 4, A.dispelsFullIntensity or 8)

			-- avoidable damage: standing in bad costs (up to the old cap);
			-- staying clean while bad was actually flying earns a little
			if ctx.totals.avoidable > 0 then
				local share = (m.avoidableTaken or 0) / ctx.totals.avoidable
				local excess = share - (1 / ctx.playerCount)
				if excess > 0 then
					put("avoidable", -math.min(W.penalties.avoidableCap,
						excess * W.penalties.avoidablePerExcessShare))
				elseif (ctx.totals.damageTaken or 0) > 0 then
					local pressure = math.min(1, (ctx.totals.avoidable / ctx.totals.damageTaken)
						/ (A.avoidablePressureRef or 0.10))
					put("avoidable", (A.avoidableCleanBonus or 0) * pressure)
				end
			end

			-- deaths: negative only (staying alive is the base's job).
			-- Post-call deaths are dropped from the charged count entirely
			-- (audit 2026-07-18: forgiving only the LAST death meant a
			-- brez + forgiven re-death promoted the earlier death to full
			-- price — accepting the rez cost more than staying dead).
			local deathCount = m.deaths or 0
			local chargedTime = p.deathTime -- timing relief anchor
			if fight.calledWipeAt and p.deathTimes then
				deathCount, chargedTime = 0, nil
				for _, t in ipairs(p.deathTimes) do
					if t < fight.calledWipeAt then
						deathCount = deathCount + 1
						chargedTime = t
					end
				end
			end
			if deathCount > 0 then
				local lastDeathCost = W.penalties.perDeath
				if chargedTime and ctx.duration and ctx.duration > 0 then
					local fraction = math.max(0, math.min(1, chargedTime / ctx.duration))
					lastDeathCost = W.penalties.perDeath * (1 - (W.penalties.deathTimingRelief or 0) * fraction)
				end
				-- legacy records (no deathTimes): forgive the last death by
				-- zeroing its cost, as before
				if fight.calledWipeAt and not p.deathTimes
					and p.deathTime and p.deathTime >= fight.calledWipeAt then
					lastDeathCost = 0
				end
				local pts = math.min(W.penalties.deathsCap,
					(deathCount - 1) * W.penalties.perDeath + lastDeathCost)
				if fight.wipe then
					pts = pts * (W.penalties.wipeDeathScale or 1)
				end
				put("deaths", -pts)
			end
			-- shared context for every death-adjacent penalty below: a
			-- death that happened after the wipe call judges nothing, and
			-- a one-shot (single recap hit >= ~90% of max HP) is a death
			-- no defensive would have changed (audit 2026-07-18)
			local deathForgiven = fight.calledWipeAt and p.deathTime
				and p.deathTime >= fight.calledWipeAt
			local oneShot = false
			if p.maxHP and p.maxHP > 0 and p.deathRecap then
				for _, hit in ipairs(p.deathRecap) do
					if (hit.amount or 0) >= p.maxHP * 0.9 then
						oneShot = true
						break
					end
				end
			end

			-- pre-pull raid buff coverage (providers only)
			local buffFloor = W.penalties.buffCoverageFloor or 1
			if p.buffCoverage and p.buffCoverage < buffFloor then
				put("buffs", -((buffFloor - p.buffCoverage) / buffFloor) * (W.penalties.missingBuffMax or 0))
			end

			-- threat discipline (5-mans; raids are fixate noise)
			if ctx.playerCount <= (W.penalties.threatMaxPlayers or math.huge) then
				if role == "TANK" then
					if (p.aggroLostTime or 0) > 0 then
						put("aggroLoss", -math.min(W.penalties.aggroLossCap or 0,
							p.aggroLostTime * (W.penalties.aggroLossPerSecond or 0)))
					end
				else
					if p.aggroPulled then
						put("pull", -(W.penalties.pulledPack or 0))
					end
					if (p.aggroRips or 0) > 0 then
						local perRip = W.penalties.perAggroRip or 0
						if role == "HEALER" then
							-- healing aggro chasing a slacking tank isn't
							-- the healer's crime; charge it at half price
							perRip = perRip * (W.penalties.healerRipScale or 1)
						end
						put("aggro", -math.min(W.penalties.aggroRipsCap or 0, p.aggroRips * perRip))
					end
				end
			end

			-- ---- addon-reported extras: absence is always neutral ----
			if m.activityPct then
				-- per-spec calibration (Josh 2026-07-25): a caster's top
				-- parses idle near 99% while a melee's sit ~92%, so judging
				-- both on a fixed 70/89 curve was wrong. When the spell
				-- profile carries this spec's top-parse activity, anchor the
				-- HIGH there and keep the same 19-point spread; fall back to
				-- the fixed anchors otherwise.
				local lo, hi = A.activityLow or 70, A.activityHigh or 89
				local prof = TP.SpellProfiles and p.specID and TP.SpellProfiles[p.specID]
				if prof and prof.activity and prof.activity > 0 then
					hi = prof.activity
					lo = hi - ((A.activityHigh or 89) - (A.activityLow or 70))
				end
				-- Per-ENCOUNTER shift (Josh 2026-07-28: "many fights have a
				-- lot of downtime and the coach is talking about it"). The
				-- spec anchor above pools every boss, so a fight that FORCES
				-- downtime read as bad play - measured on real MoP history,
				-- 100% of players were penalised on Immerseus, Galakras and
				-- Wing Leader Ner'onok. WCL's own ranked players only reach
				-- 76% activity on Immerseus against 99% on Malkorok, so the
				-- bar moves with the fight. factor = this boss's median over
				-- the median across all bosses; absent -> 1, unchanged.
				local ap = TP.ActivityProfiles and fight.name and TP.ActivityProfiles[fight.name]
				if ap and ap.factor and ap.factor > 0 and ap.factor < 1 then
					-- only ever LOWERS the bar: a boss that allows more
					-- uptime than average shouldn't invent a stricter one
					hi = hi * ap.factor
					lo = lo * ap.factor
				end
				-- GROUP FLOOR on the penalty side. Metrics/Activity used to
				-- measure GCD occupancy while the anchor above measures
				-- WCL's activeTime (idle stretches), which charged healers
				-- and channelers ~25 points for a definition mismatch. The
				-- collector now matches the anchor, but that is capture-time
				-- work: every fight recorded before it still carries the old
				-- scale, and scores are recomputed from stored metrics on
				-- every render. The floor keeps those honest - a player at or
				-- above their own group's median is not the outlier and must
				-- not be charged for a shortfall everyone shared. Bonuses
				-- still use the absolute anchor, so this only ever forgives.
				local pts = ramp(m.activityPct, lo, hi, A.activityMax or 4)
				if pts < 0 then
					local med = groupActivityMedian(ctx)
					if med and m.activityPct >= med then
						pts = 0
					end
				end
				-- dead time reads as inactivity, and the death already
				-- cost: don't charge the same corpse-minutes twice
				if pts < 0 and (m.deaths or 0) > 0 then
					pts = 0
				end
				put("activity", pts)
			end
			-- (the mitigation adjustment retired 2026-07-25: uptime lives
			-- inside the Tanking composite now — scoring it separately
			-- double-dipped, and points without a row are forbidden)
			-- Flask + food: +1 for both up, and each one MISSING now costs a
			-- point (Josh 2026-07-26: -1 for one short, -2 for both). Only
			-- when the count was actually reported - consumables is
			-- self-report only (Collect/Sync), so non-reporters stay neutral.
			if m.consumables ~= nil then
				if m.consumables >= 2 then
					put("prepared", A.preparedBonus or 1)
				else
					put("prepared", -(2 - m.consumables)) -- 0 -> -2, 1 -> -1
				end
			end
			if (m.defensives or 0) >= 2 then
				put("defensives", A.defensivesBonus or 0)
			end
			-- (the Tanking bonus-adjustment retired 2026-07-26: survival is
			-- now the tank's PRIMARY weighted metric, mitigation uptime vs
			-- the spec's WCL field - see normalizeMetric "tanking". Scoring
			-- it as a bonus on top would double-count.)
			-- healthstone discipline (Josh 2026-07-25): +1 for eating one,
			-- -1 for sitting on it — judged only when a warlock was in the
			-- group to provide them. Retail leaves the metric nil (other
			-- players' casts are secret): neutral, like every absence.
			if m.healthstones ~= nil then
				local hasWarlock
				for _, wp in pairs(fight.players or {}) do
					if wp.class == "WARLOCK" then
						hasWarlock = true
						break
					end
				end
				if hasWarlock then
					if m.healthstones > 0 then
						put("healthstone", A.healthstoneBonus or 1)
					else
						-- Only a penalty if the fight justified pressing it.
						-- A personal spike window or a death is direct
						-- evidence of danger; otherwise fall back to total
						-- intake against the player's own health pool. No
						-- evidence either way -> no penalty, the same way
						-- every other absence stays neutral here.
						local danger = (m.spikeWindows or 0) > 0 or (m.deaths or 0) > 0
						if not danger and p.maxHP and p.maxHP > 0 then
							danger = (m.damageTaken or 0)
								>= p.maxHP * (A.healthstoneMinIntake or 1.0)
						end
						if danger then
							put("healthstone", -(A.healthstonePenalty or 1))
						end
					end
				end
			end
			-- forgiven post-call deaths and one-shots judge nothing: the
			-- player did what the raid asked / nothing they pressed mattered
			if (m.deaths or 0) > 0 and (p.deathReadyDefensives or 0) >= 2
				and not deathForgiven and not oneShot then
				put("deathReady", -(A.readyAtDeathPenalty or 0))
			end
			-- every metric moves the score or stays silent (2026-07-15):
			-- all four below default to 0 when the data is absent, so
			-- addon-less/retail players are never touched.
			-- Overheal: healers with real demand. Fixed thresholds until a
			-- WCL per-spec overheal crawl exists (rankings API lacks it).
			-- ctx.lowHealingDemand checked directly: breakdown.lowDemand is
			-- only computed on the <75-score floor path, so a healer who
			-- scored WELL on a trivial fight never got the exemption while
			-- a weaker one did (audit 2026-07-18)
			if role == "HEALER" and m.overhealPct and breakdown.healing
				and breakdown.healing.applicable and not breakdown.healing.lowDemand
				and not ctx.lowHealingDemand then
				-- per-spec population quantiles when the overheal crawl has
				-- data for this spec (a Disc priest's normal overheal is
				-- nothing like a Resto druid's): above p90 = -2, above
				-- p75 = -1, leaner than p25 = +1. Fixed thresholds are the
				-- fallback until Data/Overheal_*.lua ships.
				local oc = TP.OverhealCurves and p.specID and TP.OverhealCurves[p.specID]
				if m.overhealPct >= (oc and oc.p90 or A.overhealHighAt or 60) then
					put("overheal", -(A.overhealHigh or 2))
				elseif m.overhealPct >= (oc and oc.p75 or A.overhealMidAt or 45) then
					put("overheal", -(A.overhealMid or 1))
				elseif m.overhealPct <= (oc and oc.p25 or A.overhealLowAt or 20) then
					put("overheal", A.overhealLowBonus or 1)
				end
			end
			-- Overkill: damage wasted on dead targets. Short segments are a
			-- couple of killing blows — and SOMEONE must land every final
			-- blow — so only sustained fights can show a real pattern
			if role == "DAMAGER" and (m.overkillPct or 0) >= (A.overkillAt or 10)
				and (ctx.duration or 0) >= (A.overkillMinDuration or 60) then
				put("overkill", -(A.overkillPenalty or 1))
			end
			-- Running dry mid-fight (dry at the kill is optimal, not a
			-- fault; dry after the wipe call is spam-healing the doomed,
			-- which the addon declines to judge — audit 2026-07-18)
			if role == "HEALER" and m.dryAt and ctx.duration and ctx.duration > 0 then
				local judged = math.min(ctx.duration, fight.calledWipeAt or ctx.duration)
				if m.dryAt < judged * 0.8 then
					put("manaDry", -(A.manaDryPenalty or 1))
				end
			end
			-- Dispel REACTION time (Josh 2026-07-25): clearing a debuff fast
			-- is a real skill the data separates cleanly (field p25 2.4s /
			-- med 3.7s / p75 5.8s; 34% average >5s). Orthogonal to the
			-- dispel COUNT adjustment (volume vs speed), so no double-count.
			-- Needs 2+ dispels for the average to mean something.
			if m.dispelReactAvg and (m.dispels or 0) >= 2 then
				if m.dispelReactAvg <= (A.dispelReactFast or 2.5) then
					put("dispelReact", A.dispelReactBonus or 1)
				elseif m.dispelReactAvg >= (A.dispelReactSlow or 6) then
					put("dispelReact", -(A.dispelReactPenalty or 1))
				end
			end
			-- Dying without ever using a defensive (counted, not inferred;
			-- forgiven post-call deaths and one-shots judge nothing).
			-- Availability: a self/peer readiness report of ZERO defensives
			-- off cooldown at death means there was nothing to press —
			-- spent pre-pull or the spec has none (Josh 2026-07-23)
			if (m.deaths or 0) > 0 and m.defensives == 0
				and p.deathReadyDefensives ~= 0
				and not deathForgiven and not oneShot then
				put("deathNoDefensives", -(A.deathNoDefensives or 2))
			end
			-- cooldown timing: share of danger windows a cooldown covered
			-- (Classic CLEU computes it for everyone; retail self-reports).
			-- Needs 2+ windows: one window is a coin flip, not a pattern.
			-- AVAILABILITY CAP (Josh 2026-07-23): only judge windows the
			-- player COULD have covered. Without per-spell cooldown tables,
			-- demonstrated capacity (uses actually made, +1 headroom for one
			-- more they might have held) is the honest bound — a healer team
			-- with 2 raid-CD casts in a 6-window fight ran out of buttons,
			-- not discipline. Judged still needs 2+ coverable windows.
			-- (zero uses gets NO cap: nothing was ever on cooldown, so every
			-- window was coverable — that's maximum culpability, not physics)
			if role == "TANK" and (m.spikeWindows or 0) >= 2 then
				local judged = m.spikeWindows
				if (m.defensiveUses or 0) > 0 then
					judged = math.min(judged, math.max(m.defensiveUses, m.spikeCovered or 0) + 1)
				end
				if judged >= 2 then
					put("cdTiming", ramp((m.spikeCovered or 0) / judged,
						A.cdTimingLow or 0.25, A.cdTimingHigh or 0.75, A.cdTimingMax or 5))
				end
			elseif role == "HEALER" then
				-- one pool, one cap, every healer spec (Josh 2026-07-24):
				-- group spikes answered by raid CDs, PLUS tank spikes
				-- answered by single-target externals — but tank windows
				-- only judge specs that OWN an external (resto shaman has
				-- none in MoP; their extra raid CDs are the kit's answer)
				local extW, extC = 0, 0
				if TP.EXTERNALS_BY_SPEC and p.specID and TP.EXTERNALS_BY_SPEC[p.specID] then
					extW, extC = m.extWindows or 0, m.extCovered or 0
				end
				local windows = (m.groupSpikeWindows or 0) + extW
				if windows >= 2 then
					local covered = (m.groupSpikeCovered or 0) + extC
					local judged = windows
					if (m.groupCdCasts or 0) > 0 then
						judged = math.min(judged, math.max(m.groupCdCasts, covered) + 1)
					end
					if judged >= 2 then
						put("cdTiming", ramp(covered / judged,
							A.cdTimingLow or 0.25, A.cdTimingHigh or 0.75, A.cdTimingMax or 5))
					end
				end
			end
			-- combat rezzes: casting one is group contribution, full stop
			if (m.combatRezzes or 0) > 0 then
				put("rez", math.min(A.rezCap or 4, m.combatRezzes * (A.rezBonus or 2)))
			end
			-- lust alignment (DPS): windows happened and we saw their casts
			if role == "DAMAGER" and m.lustCasts ~= nil then
				if m.lustCasts > 0 and (m.lustPotion or 0) > 0 then
					put("lust", A.lustMax or 3)
				elseif m.lustCasts > 0 then
					put("lust", (A.lustMax or 3) * 0.5)
				-- a corpse can't press cooldowns: dead before the window
				-- opened is not "wasted" (the twin of the pre-grace fix)
				elseif not (fight.lustAt and p.deathTime and p.deathTime <= fight.lustAt) then
					-- availability (Josh 2026-07-23): a CD spent in the
					-- ~90s before the window was still on cooldown DURING
					-- it — no penalty for a button that wasn't there
					local shadow = A.lustCdShadow or 90
					local spentRecently = fight.lustAt and m.lastOffensiveAt
						and m.lastOffensiveAt < fight.lustAt
						and (fight.lustAt - m.lastOffensiveAt) < shadow
					if not spentRecently then
						-- CDs spent earlier in the fight (forced by the boss
						-- timeline) soften the miss: they pressed buttons,
						-- just not in the window
						local scale = (m.offensiveCDs or 0) > 0 and 0.5 or 1
						put("lust", -(A.lustMax or 3) * scale)
					end
				end
			end
		end

		local totalAdj = 0
		for _, v in pairs(adj) do
			totalAdj = totalAdj + v
		end
		local cap = A.totalCap or 15
		totalAdj = math.max(-cap, math.min(cap, totalAdj))
		-- legacy "penalty" = the classic did-something-wrong categories
		-- only (UI columns and bullets read the signed adjust instead)
		local negSum = 0
		for _, key in ipairs({ "avoidable", "deaths", "buffs", "pull", "aggro", "aggroLoss" }) do
			if (adj[key] or 0) < 0 then
				negSum = negSum - adj[key]
			end
		end

		results[#results + 1] = {
			guid = p.guid,
			name = p.name,
			class = p.class,
			role = role,
			-- Raw-mode results say so: the card strips to throughput only
			parse = ctx.parseMode or nil,
			-- 2 or 3 when this fight's score is DERIVED from WCL data
			-- sampled on other content (see the derived tiers above). The
			-- panel badges it and hides the Raw lens — there is no real
			-- parse to show on content nobody ranks.
			derived = ctx.derived and ctx.derived.tier or nil,
			derivedFrom = ctx.derived and ctx.derived.label or nil,
			-- 99 cap, WCL semantics: 100 doesn't exist. The base already
			-- tops at 99.3; without the cap the positive adjustments were
			-- minting routine 100s (and overflowing the run column).
			-- Derived tiers compress HERE, not per metric: adjustments are
			-- earned on directly observed play (kicks, deaths, defensives)
			-- and still move you, they just cannot launch the total past
			-- what the evidence supports. Tier 1 passes through untouched.
			score = math.max(0, math.min(99, derivedCeil(ctx, base + totalAdj))),
			unclamped = base + totalAdj, -- rank ties above the cap honestly
			base = base,
			adjust = totalAdj, -- net signed adjustment (what the card shows)
			adjustDetail = adj, -- [key] = signed points
			-- legacy consumers (penalty column math, penalty bullets)
			penalty = negSum,
			penaltyDetail = {
				avoidable = math.max(0, -(adj.avoidable or 0)),
				deaths = math.max(0, -(adj.deaths or 0)),
				buffs = math.max(0, -(adj.buffs or 0)),
				pull = math.max(0, -(adj.pull or 0)),
				aggro = math.max(0, -(adj.aggro or 0)),
				aggroLoss = math.max(0, -(adj.aggroLoss or 0)),
			},
			breakdown = breakdown,
		}
	end

	table.sort(results, function(a, b)
		if a.score ~= b.score then
			return a.score > b.score
		end
		-- two 99s aren't equal: a 99 with +6 on top outranks a bare one
		return (a.unclamped or a.score) > (b.unclamped or b.score)
	end)
	return results
end
