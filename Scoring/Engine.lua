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
		return effHealing(p.metrics)
	end
	return p.metrics[key] or 0
end

local function normalizeRole(p)
	return TP.Scoring.Capabilities.EffectiveRole(p.role, p.specIconID, p.specID)
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
		return enc and sanitizeEncounter(enc) or nil
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
local function entryPercentileFor(entry, rate)
	local curve, n, total = entry.curve, entry.n, entry.total
	if not (n and total and total > n) then
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
			if bk == "all" then
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
			ctx.totals.dispelTypes) then
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

	if key == "buffUptime" then
		-- Self-reported Ebon Might uptime (fraction of the fight), only
		-- present when the support player runs TrueParse. Absent -> weight
		-- redistributes, exactly like a missing capability.
		local uptime = p.metrics and p.metrics.buffUptime
		if not uptime then
			return 0, false
		end
		return math.min(100, 100 * uptime / (W.supportUptimeAnchor or 1)), true
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
				-- bracket's population before interpolating
				local pct = entryPercentileFor(entry, (scale or 1) * curveVal / ctx.duration)
				absolute = math.min(100, (W.trueAbsFloor or 0) + (W.trueAbsSlope or 1) * pct)
				fromCurve = true
				pctile = pct -- raw percentile, for the tooltip gauge
				-- surfaced in tooltips: "the median of your spec does Y/s
				-- here" — answers every 'but I topped the meter?!'
				-- (converted back into the fight's own bracket terms)
				specMedian = curveP50(entry.curve) / (scale or 1)
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
				local pct = entryPercentileFor(entry, (scale or 1) * curveVal / ctx.duration)
				specMedian = curveP50(entry.curve) / (scale or 1)
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
	if fight.wipe or not fight.duration or fight.duration <= 0 then
		return nil
	end
	local P = TP.Percentiles
	if not P then
		return nil
	end
	local enc = encounterCurvesFor(P, fight)
	if not enc then
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

-- Where this encounter's median kill time ranks among the tier's bosses
-- (same data file, same bracket): 0 = the tier's fastest-killed boss,
-- 1 = the slowest. Group-card context, so a rough score on a rough boss
-- reads fairly. Returns rank, bossesCompared — nil without enough peers.
function Engine.EncounterToughness(fight)
	local P = TP.Percentiles
	if not (P and P.encounters and fight.isBoss) then
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
			if not (isDungeon and not enc) then
				ctx.curves = { P = P, enc = enc, order = bracketSearchOrder(bracketKey),
					exact = bracketKey, dungeonOnly = isDungeon or nil }
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
			local d50 = dEntry and curveP50(dEntry.curve) / (dScale or 1)
			local h50 = hEntry and curveP50(hEntry.curve) / (hScale or 1)
			local budget = (weights.damage or 0) + (weights.healing or 0)
			-- BOTH medians required: a missing curve means "no data", not
			-- "zero output" — one-sided evidence must not zero a weight
			if d50 and h50 and budget > 0 then
				local mix = h50 / math.max(1, d50 + h50)
				mix = math.min(0.95, mix)
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
			local lowDemand
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
			end
			breakdown[key] = {
				weight = weight,
				normalized = normalized,
				applicable = applicable,
				absolute = absolute, -- vs WCL top-logs median, when available
				relative = relative, -- vs the group, when available
				lowDemand = lowDemand, -- floored: nothing to heal this fight
				specMedian = specMedian, -- p50 rate for this spec+fight+bracket
				pctile = pctile, -- raw population percentile (tooltip gauge)
				rolePooled = rolePooled, -- scored vs the ROLE's pooled curve
				curveFrom = curveFrom, -- comparison population when zoomed out
				value = metricValue(p, key),
			}
			if key == "interrupts" or key == "dispels" then
				-- the tooltip phrases these as "Kicked 2 of the group's 7"
				breakdown[key].groupTotal = ctx.totals[key] > 0 and ctx.totals[key] or nil
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
		for _, b in pairs(breakdown) do
			if b.applicable and activeWeight > 0 then
				b.effectiveWeight = b.weight / activeWeight
				b.contribution = b.normalized * b.effectiveWeight
				base = base + b.contribution
			else
				b.effectiveWeight = 0
				b.contribution = 0
			end
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
				breakdown.interrupts.opportunities = fight.totals.kickOpportunities
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
				local pts = ramp(m.activityPct, A.activityLow or 70, A.activityHigh or 89,
					A.activityMax or 4)
				-- dead time reads as inactivity, and the death already
				-- cost: don't charge the same corpse-minutes twice
				if pts < 0 and (m.deaths or 0) > 0 then
					pts = 0
				end
				put("activity", pts)
			end
			if role == "TANK" and m.mitigationPct then
				local pts = ramp(m.mitigationPct, A.mitigationLow or 40, A.mitigationHigh or 70,
					A.mitigationMax or 4)
				-- the uptime ratio has no idea about dead time or the
				-- post-call AFK tail (its numerator can't be clipped after
				-- the fact): suppress the penalty when either contaminates
				-- it; the bonus side still stands
				if pts < 0 and ((m.deaths or 0) > 0 or fight.calledWipeAt) then
					pts = 0
				end
				put("mitigation", pts)
			end
			if (m.consumables or 0) >= 2 then
				put("prepared", A.preparedBonus or 0)
			end
			if (m.defensives or 0) >= 2 then
				put("defensives", A.defensivesBonus or 0)
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
			-- Dying without ever using a defensive (counted, not inferred;
			-- forgiven post-call deaths and one-shots judge nothing)
			if (m.deaths or 0) > 0 and m.defensives == 0
				and not deathForgiven and not oneShot then
				put("deathNoDefensives", -(A.deathNoDefensives or 2))
			end
			-- cooldown timing: share of danger windows a cooldown covered
			-- (Classic CLEU computes it for everyone; retail self-reports).
			-- Needs 2+ windows: one window is a coin flip, not a pattern.
			if role == "TANK" and (m.spikeWindows or 0) >= 2 then
				put("cdTiming", ramp((m.spikeCovered or 0) / m.spikeWindows,
					A.cdTimingLow or 0.25, A.cdTimingHigh or 0.75, A.cdTimingMax or 5))
			elseif role == "HEALER" and (m.groupSpikeWindows or 0) >= 2 then
				put("cdTiming", ramp((m.groupSpikeCovered or 0) / m.groupSpikeWindows,
					A.cdTimingLow or 0.25, A.cdTimingHigh or 0.75, A.cdTimingMax or 5))
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
					-- CDs spent earlier in the fight (forced by the boss
					-- timeline) soften the miss: they pressed buttons,
					-- just not in the window
					local scale = (m.offensiveCDs or 0) > 0 and 0.5 or 1
					put("lust", -(A.lustMax or 3) * scale)
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
			-- 99 cap, WCL semantics: 100 doesn't exist. The base already
			-- tops at 99.3; without the cap the positive adjustments were
			-- minting routine 100s (and overflowing the run column).
			score = math.max(0, math.min(99, base + totalAdj)),
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
