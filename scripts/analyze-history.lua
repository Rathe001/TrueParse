-- Distributions from REAL captured fights (SavedVariables), to ground
-- the hand-set constants: kick/dispel count tiers, activity thresholds,
-- defensive-cooldown expectations, death rates.
-- Usage: lua scripts/analyze-history.lua <TrueParse.lua SV path> [...]

local function quantile(sorted, q)
	if #sorted == 0 then
		return nil
	end
	local idx = 1 + q * (#sorted - 1)
	local lo, hi = math.floor(idx), math.ceil(idx)
	return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo)
end

local function dist(label, list, pct)
	if #list == 0 then
		print(("  %s: (no data)"):format(label))
		return
	end
	table.sort(list)
	local mul = pct and 100 or 1
	print(("  %s: n=%d  p10=%.1f p25=%.1f p50=%.1f p75=%.1f p90=%.1f p99=%.1f"):format(
		label, #list,
		quantile(list, 0.10) * mul, quantile(list, 0.25) * mul,
		quantile(list, 0.50) * mul, quantile(list, 0.75) * mul,
		quantile(list, 0.90) * mul, quantile(list, 0.99) * mul))
end

for _, path in ipairs(arg) do
	TrueParseDB = nil
	local chunk, err = loadfile(path)
	if not chunk then
		print("LOAD FAILED: " .. tostring(err))
	else
		chunk()
		local db = TrueParseDB or {}
		local fights, players = 0, 0
		local durations, groupKicks, groupDispels, deathsPerFight = {}, {}, {}, {}
		local pKicks, pDispels, pKicksNonzero, pDispelsNonzero = {}, {}, {}, {}
		local activity, defensives, overheal, mitigation = {}, {}, {}, {}
		local avoidShare, wipes, sizes = {}, 0, {}
		for charKey, char in pairs(db.char or {}) do
			for _, f in ipairs(char.recentFights or {}) do
				if f.isBoss and (f.duration or 0) >= 30 then
					fights = fights + 1
					durations[#durations + 1] = f.duration or 0
					if f.wipe then
						wipes = wipes + 1
					end
					local gk, gd, deaths, n = 0, 0, 0, 0
					for _, p in pairs(f.players or {}) do
						n = n + 1
						players = players + 1
						local m = p.metrics or {}
						gk = gk + (m.interrupts or 0)
						gd = gd + (m.dispels or 0)
						deaths = deaths + (m.deaths or 0)
						pKicks[#pKicks + 1] = m.interrupts or 0
						pDispels[#pDispels + 1] = m.dispels or 0
						if (m.interrupts or 0) > 0 then
							pKicksNonzero[#pKicksNonzero + 1] = m.interrupts
						end
						if (m.dispels or 0) > 0 then
							pDispelsNonzero[#pDispelsNonzero + 1] = m.dispels
						end
						if m.activityPct then
							activity[#activity + 1] = m.activityPct
						end
						if m.defensives then
							defensives[#defensives + 1] = m.defensives
						end
						if m.overhealPct then
							overheal[#overheal + 1] = m.overhealPct
						end
						if m.mitigationPct then
							mitigation[#mitigation + 1] = m.mitigationPct
						end
					end
					sizes[#sizes + 1] = n
					groupKicks[#groupKicks + 1] = gk
					groupDispels[#groupDispels + 1] = gd
					deathsPerFight[#deathsPerFight + 1] = deaths
					local tot = f.totals or {}
					if (tot.damageTaken or 0) > 0 then
						avoidShare[#avoidShare + 1] = (tot.avoidableTaken or 0) / tot.damageTaken
					end
				end
			end
		end
		print(("== %s"):format(path:match("(_[a-z]+_)") or path))
		print(("  boss fights=%d (%d wipes), player-fights=%d"):format(fights, wipes, players))
		dist("fight duration (s)", durations)
		dist("group size", sizes)
		dist("group kicks / fight", groupKicks)
		dist("group dispels / fight", groupDispels)
		dist("deaths / fight", deathsPerFight)
		dist("per-player kicks (all)", pKicks)
		dist("per-player kicks (kickers only)", pKicksNonzero)
		dist("per-player dispels (dispellers only)", pDispelsNonzero)
		dist("activity %", activity, true)
		dist("defensive CDs used", defensives)
		dist("overheal %", overheal, true)
		dist("tank mitigation uptime %", mitigation, true)
		dist("avoidable share of damage taken %", avoidShare, true)
		print("")
	end
end
