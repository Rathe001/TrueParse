-- Emits a CSV of curve entries that hit WCL's server caps and therefore
-- need true-population totals (see fetch-totals.ps1):
--   characterRankings caps at 2000 characters per spec, fightRankings at
--   1000 kills (both verified live 2026-07-18). A capped curve is a
--   top-slice sample, so interpolating into it under-rates everyone
--   mid-pack unless the engine knows the real population size.
-- Usage: lua dump-capped.lua <data-file> [<data-file> ...]
-- Lines: SPEC,boss,bracket,kind,specID,n | KT,boss,bracket,n
--        ANCHOR,boss,bracket,kind,specID   (biggest-n spec: a guaranteed
--        populous rankings page to pull report codes from)
local SPEC_CAP, KT_CAP = 2000, 1000

local TP = {}
for i = 1, #arg do
	local chunk = assert(loadfile(arg[i]))
	chunk("TrueParse", TP)
end

local E = TP.Percentiles and TP.Percentiles.encounters
if not E then
	error("no percentile data loaded")
end

local function sortedKeys(t)
	local keys = {}
	for k in pairs(t) do
		keys[#keys + 1] = k
	end
	table.sort(keys, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return keys
end

for _, boss in ipairs(sortedKeys(E)) do
	local enc = E[boss]
	if type(enc) == "table" then
		for _, bk in ipairs(sortedKeys(enc)) do
			local bracket = enc[bk]
			if type(bracket) == "table" then
				local anyCapped = false
				local bestN, bestKind, bestSpec = 0, nil, nil
				for _, kind in ipairs({ "dps", "hps" }) do
					for _, sid in ipairs(sortedKeys(bracket[kind] or {})) do
						local e = bracket[kind][sid]
						local n = e and e.n or 0
						if n > bestN then
							bestN, bestKind, bestSpec = n, kind, sid
						end
						if n >= SPEC_CAP then
							anyCapped = true
							print(("SPEC|%s|%s|%s|%d|%d"):format(boss, bk, kind, sid, n))
						end
					end
				end
				local kt = bracket.killTime
				if kt and (kt.n or 0) >= KT_CAP then
					anyCapped = true
					print(("KT|%s|%s|%d"):format(boss, bk, kt.n))
				end
				if anyCapped and bestSpec then
					print(("ANCHOR|%s|%s|%s|%d"):format(boss, bk, bestKind, bestSpec))
				end
			end
		end
	end
end
