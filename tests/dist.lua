-- Distribution regression gate: rescore every real capture and compare the
-- SHAPE of the results against a checked-in baseline.
--
-- Why this exists. The other four gates catch crashes, invariant violations
-- and unit-level behaviour. Every scoring bug that actually reached a player
-- got past all of them, because each was plausible-but-wrong rather than
-- broken: tank damage pegging at 100 in 10-mans, the Mythic+ tier-1 collapse
-- (median 3.5, 97.6% under ten), Timewalking's grey parses, Paragons counting
-- damage Warcraft Logs does not. Every one was found by a human squinting at
-- output. This turns that squint into a diff.
--
-- Two views, because they fail differently:
--   BUCKETS  - p25/median/p75/under-10/over-90 per client+content+role+tier.
--              Catches calibration drift, which no synthetic fixture can:
--              the reference curves are only wrong RELATIVE to real players.
--   FIGHTS   - median score per captured fight. Localises a regression to
--              the pull that moved, which a bucket average hides.
--
--   lua tests/dist.lua <sv.lua> [<sv2.lua> ...]        compare to baseline
--   lua tests/dist.lua <sv.lua> [...] --write          regenerate baseline
--
-- The SavedVariables file is REWRITTEN WHILE THE GAME RUNS, so a baseline
-- taken from a live path silently describes a moving dataset (n went
-- 468 -> 493 -> 543 mid-analysis once). Only fights present in BOTH the
-- baseline and the current file are compared, so playing more does not
-- register as a regression - and neither does deleting history.
--
-- No player names are recorded. Fights are keyed by start time, name and
-- duration; buckets hold nothing but counts and percentiles.

local args = { ... }
local WRITE = false
local paths = {}
for _, a in ipairs(args) do
	if a == "--write" then
		WRITE = true
	else
		paths[#paths + 1] = a
	end
end
if #paths == 0 then
	print("usage: lua tests/dist.lua <SavedVariables.lua> [more...] [--write]")
	os.exit(2)
end

-- Tolerances. Deliberately not zero: scores are floating point and the
-- percentile pick moves by one sample when a bucket's n changes at the edge.
-- Wide enough not to cry wolf, tight enough that any of the four historical
-- bugs above would have blown straight through it.
local TOL = { p50 = 2.0, p25 = 2.5, p75 = 2.5, under10 = 3.0, over90 = 3.0, fight = 2.0 }
local MIN_N = 8 -- a bucket thinner than this is noise, reported but not gated

local function loadClient(isRetail)
	local TP = { Compat = { HAS_CLEU = not isRetail, IS_RETAIL = isRetail,
		IsSecret = function() return false end } }
	local function load(path)
		local f = loadfile(path)
		if f then f("TrueParse", TP) end -- absent data files are optional
	end
	for _, m in ipairs({ "Core/Constants", "Core/Utils", "Scoring/Capabilities",
		"Scoring/Weights", "Scoring/Engine", "Scoring/Grades", "Scoring/Runs",
		"Scoring/Coach", "Scoring/Insights", "Scoring/Bullets", "Scoring/Signals",
		"Scoring/Awards", "Scoring/Reports", "Scoring/DeathCause", "Metrics/Registry" }) do
		load(m .. ".lua")
	end
	local DATA = isRetail
		and { "Benchmarks", "Percentiles", "Percentiles_Dungeons", "Percentiles_Keys",
			"Percentiles_LFR", "Percentiles_Sporefall", "KillTimes", "KillTimes_LFR",
			"KillTimes_Sporefall", "Totals", "Totals_Sporefall", "Totals_Dungeons",
			"Potions", "GroupBuffs", "Defensives", "Mitigation", "Lust", "HealerCDs",
			"SpellProfiles", "Overheal", "DamageProfiles", "ActivityProfiles",
			"TankAnchors", "TankDamage", "HealerCoverage", "HealerDamage", "ProcExclusions" }
		or { "Benchmarks_Mists", "Percentiles_Mists", "Percentiles_Mists_25",
			"Overheal_Mists", "KillTimes_Mists", "KillTimes_Mists_Dungeons",
			"Totals_Mists", "SpellProfiles_Mists", "Potions", "Avoidable_Mists",
			"DamageProfiles_Mists", "ActivityProfiles_Mists", "ProcExclusions_Mists",
			"Lust_Mists", "Mitigation_Mists", "HealerCDs_Mists", "GroupBuffs",
			"Defensives", "TankAnchors_Mists", "TankDamage_Mists" }
	for _, d in ipairs(DATA) do
		load("Data/" .. d .. ".lua")
	end
	return TP
end

-- What KIND of content a capture is, coarsely enough that the buckets stay
-- populated but finely enough that a regression in one cannot hide in another.
-- MoP captures frequently carry NO instanceType (96 of 234 in Josh's file),
-- so difficultyID has to lead or two thirds of the raid data lands in a
-- catch-all bucket where a regression could hide.
local function contentOf(f)
	local d = f.difficultyID
	if d == 8 then
		return "mplus"
	elseif d == 24 then
		return "timewalk"
	elseif d == 237 then
		return "celestial" -- MoP Challenge Mode / celestial dungeon
	elseif d == 3 or d == 4 or d == 5 or d == 6 then
		return "raid" -- MoP 10/25 Normal and Heroic
	elseif d == 14 or d == 15 or d == 16 or d == 17 then
		return "raid" -- retail LFR/Normal/Heroic/Mythic
	elseif d == 1 or d == 2 or d == 23 then
		return "dungeon"
	end
	if f.instanceType == "raid" then
		return "raid"
	elseif f.instanceType == "party" then
		return "dungeon"
	end
	return "other"
end

local function pct(sorted, p)
	if #sorted == 0 then
		return 0
	end
	local i = math.max(1, math.min(#sorted, math.ceil(p / 100 * #sorted)))
	return sorted[i]
end

local function statsOf(list)
	table.sort(list)
	local lo, hi = 0, 0
	for _, v in ipairs(list) do
		if v < 10 then lo = lo + 1 end
		if v > 90 then hi = hi + 1 end
	end
	return {
		n = #list,
		p25 = pct(list, 25), p50 = pct(list, 50), p75 = pct(list, 75),
		under10 = #list > 0 and (lo / #list * 100) or 0,
		over90 = #list > 0 and (hi / #list * 100) or 0,
	}
end

-- ------------------------------------------------------------------ measure
local buckets, fights, errors = {}, {}, 0
for _, path in ipairs(paths) do
	local chunk = assert(loadfile(path), "cannot read " .. path)
	_G.TrueParseDB = nil
	chunk()
	local db = _G.TrueParseDB
	assert(db, path .. " has no TrueParseDB")
	-- the client is a property of the FILE, and mixing them would compare
	-- MoP scores against retail curves
	local isRetail = not tostring(path):lower():find("classic")
	local TP = loadClient(isRetail)
	local client = isRetail and "retail" or "mists"
	for _, cd in pairs(db["char"] or {}) do
		for _, f in ipairs(cd.recentFights or {}) do
			local ok, rows = pcall(TP.Scoring.Engine.ScoreFight, f)
			if not ok then
				errors = errors + 1
			else
				local fkey = ("%s|%s|%s|%s"):format(client,
					tostring(f.startedAt or "?"), tostring(f.name or "?"),
					tostring(f.duration or "?"))
				local all = {}
				for _, r in ipairs(rows) do
					local score = r.score
					if type(score) == "number" then
						all[#all + 1] = score
						-- `derived` is 2 or 3 when the score came from curves
						-- sampled on OTHER content; absent means tier 1,
						-- scored directly against this content's own curves
						local tier = r.derived or 1
						local key = ("%s/%s/%s/t%s"):format(client, contentOf(f),
							tostring(r.role or "?"), tostring(tier))
						buckets[key] = buckets[key] or {}
						local b = buckets[key]
						b[#b + 1] = score
					end
				end
				if #all > 0 then
					-- MERGE on collision, never overwrite. Two captures can
					-- share a key - same name and duration, both missing
					-- startedAt - and letting one win made the result depend
					-- on pairs() order, so the gate flapped between runs and
					-- reported two fights as "changed" immediately after
					-- writing its own baseline. Merging is order-independent.
					local acc = fights[fkey]
					if not acc then
						acc = {}
						fights[fkey] = acc
					end
					for _, v in ipairs(all) do
						acc[#acc + 1] = v
					end
				end
			end
		end
	end
end

local measured = {}
for k, list in pairs(buckets) do
	measured[k] = statsOf(list)
end
local fightStats = {}
for k, list in pairs(fights) do
	table.sort(list)
	fightStats[k] = { n = #list, p50 = pct(list, 50) }
end
fights = fightStats

-- -------------------------------------------------------------------- write
local function esc(s)
	return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'))
end

if WRITE then
	local keys, fkeys = {}, {}
	for k in pairs(measured) do keys[#keys + 1] = k end
	for k in pairs(fights) do fkeys[#fkeys + 1] = k end
	table.sort(keys)
	table.sort(fkeys)
	local out = {
		"-- GENERATED by tests/dist.lua --write. The expected SHAPE of scores",
		"-- over real captures; tests/dist.lua diffs against it.",
		"--",
		"-- Regenerate DELIBERATELY, never to make a red gate green: the diff is",
		"-- the review. If a scoring change is meant to move these numbers, say",
		"-- so in the commit and rewrite them in the same commit.",
		"--",
		"-- No player names here. Fights are keyed by client, start, name and",
		"-- duration; buckets hold only counts and percentiles.",
		"local _, TP = ...",
		"",
		"TP.SCORE_BASELINE = {",
		("\tbuckets = { -- %d"):format(#keys),
	}
	for _, k in ipairs(keys) do
		local s = measured[k]
		out[#out + 1] = ("\t\t[\"%s\"] = { n = %d, p25 = %.1f, p50 = %.1f, p75 = %.1f, under10 = %.1f, over90 = %.1f },")
			:format(esc(k), s.n, s.p25, s.p50, s.p75, s.under10, s.over90)
	end
	out[#out + 1] = "\t},"
	out[#out + 1] = ("\tfights = { -- %d"):format(#fkeys)
	for _, k in ipairs(fkeys) do
		out[#out + 1] = ("\t\t[\"%s\"] = { n = %d, p50 = %.1f },")
			:format(esc(k), fights[k].n, fights[k].p50)
	end
	out[#out + 1] = "\t},"
	out[#out + 1] = "}"
	local fh = assert(io.open("tests/baseline.lua", "w"))
	fh:write(table.concat(out, "\n"), "\n")
	fh:close()
	print(("wrote tests/baseline.lua: %d buckets, %d fights, %d scoring errors")
		:format(#keys, #fkeys, errors))
	os.exit(errors > 0 and 1 or 0)
end

-- --------------------------------------------------------------------- diff
local BL = {}
local blChunk = loadfile("tests/baseline.lua")
if not blChunk then
	print("no tests/baseline.lua - create it with:  lua tests/dist.lua <sv> --write")
	os.exit(2)
end
blChunk("TrueParse", BL)
local base = BL.SCORE_BASELINE or {}

local moved, gone, added = {}, 0, 0
for k, want in pairs(base.buckets or {}) do
	local got = measured[k]
	if not got then
		gone = gone + 1
	else
		for _, field in ipairs({ "p25", "p50", "p75", "under10", "over90" }) do
			local d = got[field] - want[field]
			if math.abs(d) > TOL[field] and want.n >= MIN_N and got.n >= MIN_N then
				moved[#moved + 1] = { key = k, field = field,
					from = want[field], to = got[field], d = d, n = got.n }
			end
		end
	end
end
for k in pairs(measured) do
	if not (base.buckets or {})[k] then
		added = added + 1
	end
end

local fightsMoved = {}
for k, want in pairs(base.fights or {}) do
	local got = fights[k]
	-- only fights present in BOTH: a capture that has since aged out of the
	-- history is not a regression
	if got and math.abs(got.p50 - want.p50) > TOL.fight then
		fightsMoved[#fightsMoved + 1] = { key = k, from = want.p50, to = got.p50 }
	end
end

print(("compared %d buckets and %d fights against the baseline")
	:format(#paths > 0 and (function()
		local c = 0
		for _ in pairs(measured) do c = c + 1 end
		return c
	end)() or 0, (function()
		local c = 0
		for _ in pairs(fights) do c = c + 1 end
		return c
	end)()))
if gone > 0 or added > 0 then
	print(("  %d baseline bucket(s) no longer present, %d new bucket(s) - not gated")
		:format(gone, added))
end
if errors > 0 then
	print(("  |WARN| %d fight(s) threw while scoring"):format(errors))
end

table.sort(moved, function(a, b) return math.abs(a.d) > math.abs(b.d) end)
table.sort(fightsMoved, function(a, b)
	return math.abs(a.to - a.from) > math.abs(b.to - b.from)
end)

if #moved == 0 and #fightsMoved == 0 and errors == 0 then
	print("")
	print("DISTRIBUTION UNCHANGED")
	os.exit(0)
end

if #moved > 0 then
	print("")
	print(("%d bucket statistic(s) moved:"):format(#moved))
	print(("  %-40s %-8s %8s %8s %8s"):format("BUCKET", "STAT", "WAS", "NOW", "DELTA"))
	for i = 1, math.min(25, #moved) do
		local m = moved[i]
		print(("  %-40s %-8s %8.1f %8.1f %+8.1f"):format(
			m.key:sub(1, 40), m.field, m.from, m.to, m.d))
	end
end
if #fightsMoved > 0 then
	print("")
	print(("%d captured fight(s) changed median score:"):format(#fightsMoved))
	for i = 1, math.min(15, #fightsMoved) do
		local m = fightsMoved[i]
		print(("  %-52s %5.1f -> %5.1f"):format(m.key:sub(1, 52), m.from, m.to))
	end
end
print("")
print("DISTRIBUTION CHANGED - review, then rewrite the baseline in the same")
print("commit if the change is intended (lua tests/dist.lua <sv> --write).")
os.exit(1)
