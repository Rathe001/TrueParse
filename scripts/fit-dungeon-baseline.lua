-- Fits Weights.dungeonKeyBaseline.factor from real captures: where Normal,
-- Heroic and Mythic 0 damagers land against the same dungeon's lowest key
-- band, next to where real +2 to +4 damagers land, with gear taken out of
-- both. factor = (+2 median) / (difficulty median). Read-only.
-- Usage: lua scripts/fit-dungeon-baseline.lua <path to SavedVariables\TrueParse.lua>
local SV = assert(arg[1], "usage: lua scripts/fit-dungeon-baseline.lua <TrueParse.lua>")
local TP = {}
for _, f in ipairs({ "Data/Percentiles.lua", "Data/Percentiles_Dungeons.lua",
	"Data/Percentiles_Keys.lua", "Data/Benchmarks.lua", "Scoring/Weights.lua" }) do
	assert(loadfile(f))("TrueParse", TP)
end
local KB = TP.Scoring.Weights.dungeonKeyBaseline
local SLOPE, REF, TARGET, STEP = TP.Benchmarks.ilvlSlopePct, KB.refIlvl, KB.band, KB.stepPct
local E = TP.Percentiles.encounters

local env = {}
assert(loadfile(SV, "t", env))()
local fights = {}
for _, c in pairs(env.TrueParseDB.char or {}) do
	for _, f in ipairs(c.recentFights or {}) do fights[#fights + 1] = f end
end

local function p50(curve)
	for _, pt in ipairs(curve) do if pt[1] == 50 then return pt[2] end end
end
-- the lowest crawled key band at or above the target level
local function lowestBand(enc)
	local best
	for k in pairs(enc) do
		local n = type(k) == "string" and tonumber(k:match("^k(%d+)$"))
		if n and n >= TARGET and (not best or n < best) then best = n end
	end
	return best
end

local rows = {}
for _, f in ipairs(fights) do
	local g
	if KB.factor[f.difficultyID or 0] then
		g = f.difficultyID
	elseif f.difficultyID == 8 and f.keystoneLevel and f.keystoneLevel >= 2 and f.keystoneLevel <= 4 then
		g = "key"
	end
	local enc = g and f.isBoss and not f.wipe and (f.duration or 0) >= 20 and E[f.zone or ""]
	local level = enc and lowestBand(enc)
	if level then
		local band = enc["k" .. level]
		for guid, p in pairs(f.players or {}) do
			local e = p.role == "DAMAGER" and p.specID and band.dps[p.specID]
			local med = e and p50(e.curve)
			local dmg = p.metrics and p.metrics.damage or 0
			-- below 240 is a levelling character in a level-scaled dungeon
			if med and p.ilvl and p.ilvl >= 240 and dmg > 0 then
				local toBand = (1 + STEP / 100) ^ (level - TARGET)
				local r = dmg / f.duration * toBand / med * (1 + SLOPE / 100) ^ (REF - p.ilvl)
				rows[g] = rows[g] or {}
				table.insert(rows[g], { guid = guid, r = r })
			end
		end
	end
end

local function summary(g)
	local list, who, n = {}, {}, 0
	for _, x in ipairs(rows[g] or {}) do
		list[#list + 1] = x.r
		if not who[x.guid] then who[x.guid] = true; n = n + 1 end
	end
	table.sort(list)
	return list[math.ceil(#list / 2)], #list, n
end

local keyMed, keyRows, keyPlayers = summary("key")
print(("+2 to +4 keys: %d rows from %d players, gear-adjusted rate over the band median %.2f")
	:format(keyRows, keyPlayers, keyMed or 0))
for _, id in ipairs({ 1, 2, 23 }) do
	local label = ({ [1] = "Normal", [2] = "Heroic", [23] = "Mythic 0" })[id]
	local m, n, pl = summary(id)
	if m and keyMed then
		print(("%-9s %3d rows from %2d players: %.2f  -> factor %.2f"):format(label, n, pl, m, keyMed / m))
	else
		print(("%-9s no rows in a dungeon that carries key bands"):format(label))
	end
end
print("Under about 40 rows a side the factor is noise: keep 1.0 until both sides grow.")
