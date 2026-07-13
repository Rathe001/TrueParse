-- Deep analysis of every shipped WCL dataset: quantifies the error the
-- evidence ladder introduces at each rung, curve shapes, populations,
-- kill times, and the distortion of quantile-averaged pooling.
-- Headless: lua scripts/analyze-data.lua   (run from the repo root)

local REPO = arg[0]:match("^(.*)[/\\]scripts[/\\]") or "."

local function loadData(files)
	local TP = {}
	for _, f in ipairs(files) do
		local chunk, err = loadfile(REPO .. "/" .. f)
		assert(chunk, err)
		chunk("TrueParse", TP)
	end
	return TP
end

-- SPEC_ROLES (and nothing else) from Constants
local CONST = loadData({ "Core/Constants.lua" })
local SPEC_ROLES = CONST.SPEC_ROLES

local DATASETS = {
	{ key = "retail_raid", label = "Retail raids (N/H/M + LFR)", files = {
		"Data/Percentiles.lua", "Data/Percentiles_LFR.lua",
		"Data/KillTimes.lua", "Data/KillTimes_LFR.lua" },
		brackets = { "1", "3", "4", "5" },
		bracketPairs = { { "1", "3" }, { "3", "4" }, { "4", "5" }, { "3", "5" }, { "1", "4" } } },
	{ key = "retail_mplus", label = "Retail M+ dungeons", files = {
		"Data/Percentiles_Dungeons.lua" },
		brackets = { "all" }, bracketPairs = {} },
	{ key = "sporefall", label = "Sporefall outdoor raid", files = {
		"Data/Percentiles_Sporefall.lua", "Data/KillTimes_Sporefall.lua" },
		brackets = { "1", "3", "4", "5" },
		bracketPairs = { { "3", "4" }, { "4", "5" }, { "1", "3" } } },
	{ key = "mists", label = "MoP Classic SoO", files = {
		"Data/Percentiles_Mists.lua", "Data/KillTimes_Mists.lua" },
		brackets = { "3x10", "3x25", "4x10", "4x25" },
		bracketPairs = { { "3x10", "3x25" }, { "4x10", "4x25" }, { "3x10", "4x10" }, { "3x25", "4x25" } } },
}

-- ===================== engine-identical math =====================

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

-- metric value AT a sampled percentile (exact at sample points)
local function valueAt(curve, pct)
	for _, pt in ipairs(curve) do
		if pt[1] == pct then
			return pt[2]
		end
	end
end

-- engine-style pool: sample-weighted average of curve values per point
local function poolCurves(entries)
	local sums, total = {}, 0
	for _, e in ipairs(entries) do
		local w = e.n or 1
		total = total + w
		for i, pt in ipairs(e.curve) do
			sums[i] = sums[i] or { pt[1], 0 }
			sums[i][2] = sums[i][2] + pt[2] * w
		end
	end
	if total == 0 then
		return nil
	end
	local curve = {}
	for i, s in ipairs(sums) do
		curve[i] = { s[1], s[2] / total }
	end
	for i = 2, #curve do
		if curve[i][2] > curve[i - 1][2] then
			curve[i][2] = curve[i - 1][2]
		end
	end
	return { n = total, curve = curve }
end

-- TRUE mixture quantile: piecewise-linear CDF per spec (linear to 0
-- below p10, clamped above p99), population-weighted, bisected.
local function mixtureCDF(entries, v)
	-- WCL percentiles: pX means you beat X% -> fraction below = X/100
	local acc, total = 0, 0
	for _, e in ipairs(entries) do
		local w = e.n or 1
		total = total + w
		acc = acc + w * (percentileFor(e.curve, v) / 100)
	end
	return acc / total
end

local function mixtureValueAt(entries, pct)
	-- find v such that pct/100 of the mixture is below v
	local lo, hi = math.huge, 0
	for _, e in ipairs(entries) do
		lo = math.min(lo, e.curve[#e.curve][2])
		hi = math.max(hi, e.curve[1][2])
	end
	lo = lo * 0.1
	local target = pct / 100
	for _ = 1, 60 do
		local mid = (lo + hi) / 2
		if mixtureCDF(entries, mid) > target then
			hi = mid
		else
			lo = mid
		end
	end
	return (lo + hi) / 2
end

-- ===================== stats helpers =====================

local function quantile(sorted, q)
	if #sorted == 0 then
		return nil
	end
	local idx = 1 + q * (#sorted - 1)
	local lo, hi = math.floor(idx), math.ceil(idx)
	return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo)
end

local function summarize(list)
	if #list == 0 then
		return nil
	end
	table.sort(list)
	local absList = {}
	for i, v in ipairs(list) do
		absList[i] = math.abs(v)
	end
	table.sort(absList)
	return {
		n = #list,
		median = quantile(list, 0.5),
		p25 = quantile(list, 0.25),
		p75 = quantile(list, 0.75),
		medianAbs = quantile(absList, 0.5),
		p90Abs = quantile(absList, 0.9),
	}
end

local function fmt(s, label)
	if not s then
		return label .. ": (no data)"
	end
	return ("%s: n=%d  bias=%+.1f  IQR[%+.1f..%+.1f]  |err| med=%.1f p90=%.1f"):format(
		label, s.n, s.median, s.p25, s.p75, s.medianAbs, s.p90Abs)
end

local TEST_PCTS = { 90, 75, 50, 25 }

-- ===================== analyses =====================

local function eachCurve(P, fn)
	for encName, enc in pairs(P.encounters or {}) do
		for bk, bracket in pairs(enc) do
			if type(bracket) == "table" then
				for _, kind in ipairs({ "dps", "hps" }) do
					for specID, entry in pairs(bracket[kind] or {}) do
						if entry.curve and #entry.curve > 1 then
							fn(encName, bk, kind, specID, entry)
						end
					end
				end
			end
		end
	end
end

local function inventory(P, label)
	local curves, totalN, thin, capped = 0, 0, 0, 0
	local ns = {}
	eachCurve(P, function(_, _, _, _, e)
		curves = curves + 1
		totalN = totalN + (e.n or 0)
		ns[#ns + 1] = e.n or 0
		if (e.n or 0) < 100 then
			thin = thin + 1
		end
		if e.n == 1000 or e.n == 2000 then
			capped = capped + 1
		end
	end)
	table.sort(ns)
	print(("  %s: %d curves, %s ranked parses, median n=%.0f, thin(<100)=%d, at-cap=%d"):format(
		label, curves, tostring(totalN), quantile(ns, 0.5) or 0, thin, capped))
end

local function crossBracket(P, pairsList)
	for _, pair in ipairs(pairsList) do
		local a, b = pair[1], pair[2]
		for _, kind in ipairs({ "dps", "hps" }) do
			local errs, ratios = {}, {}
			for _, enc in pairs(P.encounters or {}) do
				local ba, bb = enc[a], enc[b]
				if type(ba) == "table" and type(bb) == "table" then
					for specID, ea in pairs(ba[kind] or {}) do
						local eb = bb[kind] and bb[kind][specID]
						if eb and ea.curve and eb.curve and #ea.curve > 1 and #eb.curve > 1 then
							for _, p in ipairs(TEST_PCTS) do
								local v = valueAt(ea.curve, p)
								if v then
									errs[#errs + 1] = percentileFor(eb.curve, v) - p
								end
							end
							local m5a, m5b = valueAt(ea.curve, 50), valueAt(eb.curve, 50)
							if m5a and m5b and m5a > 0 then
								ratios[#ratios + 1] = m5b / m5a
							end
						end
					end
				end
			end
			local s = summarize(errs)
			if s then
				table.sort(ratios)
				print(("    %s->%s %s  %s   p50-ratio=%.2f"):format(
					a, b, kind, fmt(s, ""):gsub("^: ", ""), quantile(ratios, 0.5)))
			end
		end
	end
end

local function rolePoolError(P)
	local byRole = { TANK = {}, HEALER = {}, DAMAGER = {} }
	for _, enc in pairs(P.encounters or {}) do
		for bk, bracket in pairs(enc) do
			if type(bracket) == "table" then
				for _, kind in ipairs({ "dps", "hps" }) do
					local roleEntries = { TANK = {}, HEALER = {}, DAMAGER = {} }
					for specID, e in pairs(bracket[kind] or {}) do
						local role = SPEC_ROLES[specID]
						if role and roleEntries[role] and e.curve and #e.curve > 1 then
							table.insert(roleEntries[role], e)
						end
					end
					for role, entries in pairs(roleEntries) do
						if #entries > 1 then
							local pooled = poolCurves(entries)
							for _, e in ipairs(entries) do
								for _, p in ipairs(TEST_PCTS) do
									local v = valueAt(e.curve, p)
									if v then
										table.insert(byRole[role],
											percentileFor(pooled.curve, v) - p)
									end
								end
							end
						end
					end
				end
			end
		end
	end
	for role, errs in pairs(byRole) do
		print("    " .. fmt(summarize(errs), "role-pool " .. role))
	end
end

local function crossEncounterError(P, brackets)
	for _, kind in ipairs({ "dps", "hps" }) do
		local errs = {}
		for _, bk in ipairs(brackets) do
			-- global spec pool for this bracket across all encounters
			local bySpec = {}
			for _, enc in pairs(P.encounters or {}) do
				local bracket = enc[bk]
				if type(bracket) == "table" then
					for specID, e in pairs(bracket[kind] or {}) do
						if e.curve and #e.curve > 1 then
							bySpec[specID] = bySpec[specID] or {}
							table.insert(bySpec[specID], e)
						end
					end
				end
			end
			for _, entries in pairs(bySpec) do
				if #entries > 1 then
					local pooled = poolCurves(entries)
					for _, e in ipairs(entries) do
						for _, p in ipairs(TEST_PCTS) do
							local v = valueAt(e.curve, p)
							if v then
								errs[#errs + 1] = percentileFor(pooled.curve, v) - p
							end
						end
					end
				end
			end
		end
		print("    " .. fmt(summarize(errs), "cross-encounter " .. kind))
	end
end

local function everyonePoolError(P, brackets)
	-- the forbidden rung, quantified: each ROLE's curves vs the
	-- everyone-pool of the same metric
	for _, kind in ipairs({ "dps", "hps" }) do
		local byRole = { TANK = {}, HEALER = {}, DAMAGER = {} }
		for _, bk in ipairs(brackets) do
			local all = {}
			for _, enc in pairs(P.encounters or {}) do
				local bracket = enc[bk]
				if type(bracket) == "table" then
					for specID, e in pairs(bracket[kind] or {}) do
						if SPEC_ROLES[specID] and e.curve and #e.curve > 1 then
							table.insert(all, e)
						end
					end
				end
			end
			if #all > 2 then
				local pooled = poolCurves(all)
				for _, enc in pairs(P.encounters or {}) do
					local bracket = enc[bk]
					if type(bracket) == "table" then
						for specID, e in pairs(bracket[kind] or {}) do
							local role = SPEC_ROLES[specID]
							if role and byRole[role] and e.curve and #e.curve > 1 then
								local v = valueAt(e.curve, 50)
								if v then
									table.insert(byRole[role],
										percentileFor(pooled.curve, v) - 50)
								end
							end
						end
					end
				end
			end
		end
		for role, errs in pairs(byRole) do
			print("    " .. fmt(summarize(errs), ("everyone-pool %s @p50 %s"):format(kind, role)))
		end
	end
end

local function shapes(P, label)
	for _, kind in ipairs({ "dps", "hps" }) do
		local r99, r10, r95gap = {}, {}, {}
		eachCurve(P, function(_, _, k, _, e)
			if k == kind then
				local v99, v95, v90, v50, v10 =
					valueAt(e.curve, 99), valueAt(e.curve, 95), valueAt(e.curve, 90),
					valueAt(e.curve, 50), valueAt(e.curve, 10)
				if v50 and v50 > 0 then
					if v99 then
						r99[#r99 + 1] = v99 / v50
					end
					if v10 then
						r10[#r10 + 1] = v10 / v50
					end
					if v95 and v90 and v90 > 0 then
						r95gap[#r95gap + 1] = v95 / v90
					end
				end
			end
		end)
		table.sort(r99)
		table.sort(r10)
		table.sort(r95gap)
		if #r99 > 0 then
			print(("    %s %s shape: p99/p50 med=%.2f IQR[%.2f..%.2f]  p10/p50 med=%.2f  p95/p90 med=%.3f"):format(
				label, kind,
				quantile(r99, 0.5), quantile(r99, 0.25), quantile(r99, 0.75),
				quantile(r10, 0.5) or 0, quantile(r95gap, 0.5) or 0))
		end
	end
end

local function killTimes(P, label)
	local spreads, entries = {}, 0
	for encName, enc in pairs(P.encounters or {}) do
		for bk, bracket in pairs(enc) do
			if type(bracket) == "table" and bracket.killTime and bracket.killTime.curve then
				entries = entries + 1
				local c = bracket.killTime.curve
				local fast, slow, med = valueAt(c, 99), valueAt(c, 10), valueAt(c, 50)
				if fast and slow and fast > 0 then
					spreads[#spreads + 1] = slow / fast
				end
			end
		end
	end
	table.sort(spreads)
	if entries > 0 then
		print(("    %s kill times: %d encounter-brackets, slow/fast spread med=%.2fx IQR[%.2f..%.2f]"):format(
			label, entries, quantile(spreads, 0.5) or 0,
			quantile(spreads, 0.25) or 0, quantile(spreads, 0.75) or 0))
	end
end

local function mixtureDistortion(P)
	-- engine pools by averaging quantiles; a real pooled population has
	-- different quantiles. Sample role pools and measure the shift.
	local shifts = {}
	for _, enc in pairs(P.encounters or {}) do
		for bk, bracket in pairs(enc) do
			if type(bracket) == "table" then
				for _, kind in ipairs({ "dps", "hps" }) do
					local entries = {}
					for specID, e in pairs(bracket[kind] or {}) do
						if SPEC_ROLES[specID] == "DAMAGER" and e.curve and #e.curve > 1 then
							entries[#entries + 1] = e
						end
					end
					if #entries >= 4 then
						local avg = poolCurves(entries)
						for _, p in ipairs({ 90, 50, 25 }) do
							local vAvg = valueAt(avg.curve, p)
							local vTrue = mixtureValueAt(entries, p)
							if vAvg and vTrue and vTrue > 0 then
								-- what percentile does the engine's pooled curve
								-- hand to a player who is EXACTLY pX of the
								-- true mixture?
								shifts[#shifts + 1] = percentileFor(avg.curve, vTrue) - p
							end
						end
					end
				end
			end
		end
	end
	print("    " .. fmt(summarize(shifts), "quantile-avg vs true mixture"))
end

local function bracketCensus(P)
	local counts = {}
	eachCurve(P, function(_, bk)
		counts[bk] = (counts[bk] or 0) + 1
	end)
	local parts = {}
	for bk, c in pairs(counts) do
		parts[#parts + 1] = ("%s=%d"):format(bk, c)
	end
	table.sort(parts)
	print("    curves per bracket: " .. table.concat(parts, "  "))
end

-- If the neighbor-bracket rung rescaled values by the bracket-pair's
-- median p50 ratio before scoring, how much error would remain?
local function correctedTransfer(P, pairsList)
	for _, pair in ipairs(pairsList) do
		local a, b = pair[1], pair[2]
		for _, kind in ipairs({ "dps", "hps" }) do
			-- pass 1: the correction factor (median p50 ratio, one number
			-- per bracket-pair x metric - cheap to ship)
			local ratios = {}
			for _, enc in pairs(P.encounters or {}) do
				local ba, bb = enc[a], enc[b]
				if type(ba) == "table" and type(bb) == "table" then
					for specID, ea in pairs(ba[kind] or {}) do
						local eb = bb[kind] and bb[kind][specID]
						if eb and ea.curve and eb.curve then
							local m5a, m5b = valueAt(ea.curve, 50), valueAt(eb.curve, 50)
							if m5a and m5b and m5a > 0 then
								ratios[#ratios + 1] = m5b / m5a
							end
						end
					end
				end
			end
			if #ratios > 3 then
				table.sort(ratios)
				local r = quantile(ratios, 0.5)
				-- pass 2: residual error with the correction applied
				local errs = {}
				for _, enc in pairs(P.encounters or {}) do
					local ba, bb = enc[a], enc[b]
					if type(ba) == "table" and type(bb) == "table" then
						for specID, ea in pairs(ba[kind] or {}) do
							local eb = bb[kind] and bb[kind][specID]
							if eb and ea.curve and eb.curve and #ea.curve > 1 and #eb.curve > 1 then
								for _, p in ipairs(TEST_PCTS) do
									local v = valueAt(ea.curve, p)
									if v then
										errs[#errs + 1] = percentileFor(eb.curve, v * r) - p
									end
								end
							end
						end
					end
				end
				print(("    %s->%s %s corrected by %.2fx  %s"):format(
					a, b, kind, r, fmt(summarize(errs), ""):gsub("^: ", "")))
			end
		end
	end
end

-- ===================== run =====================

for _, ds in ipairs(DATASETS) do
	local ok, P = pcall(function()
		return loadData(ds.files).Percentiles
	end)
	if not ok or not P then
		print(("== %s: LOAD FAILED (%s)"):format(ds.label, tostring(P)))
	else
		print("== " .. ds.label)
		inventory(P, "inventory")
		bracketCensus(P)
		shapes(P, "")
		if #ds.bracketPairs > 0 then
			print("  cross-bracket transfer error (score a pX player of A on B's curve):")
			crossBracket(P, ds.bracketPairs)
			print("  ...with a single median-ratio correction per pair:")
			correctedTransfer(P, ds.bracketPairs)
		end
		print("  role-pool error (spec scored on its role's pooled curve):")
		rolePoolError(P)
		print("  cross-encounter pool error (spec scored on its all-bosses pool):")
		crossEncounterError(P, ds.brackets)
		print("  everyone-pool error at p50, by role (the forbidden rung):")
		everyonePoolError(P, ds.brackets)
		print("  pooling-method distortion:")
		mixtureDistortion(P)
		killTimes(P, "")
		print("")
	end
end
