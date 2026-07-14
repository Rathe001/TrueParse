-- Group-level takeaways from a set of score results: what the group did
-- well and what to work on. Feeds the one-line group chat summary.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Insights = {}
TP.Scoring.Insights = Insights

-- Metrics eligible as group strengths/weaknesses: shared by several
-- players. damageTaken is excluded — it's effectively a solo tank metric
-- and its average says nothing about the group.
local GROUP_METRICS = { damage = true, healing = true, interrupts = true, dispels = true }
local MIN_PLAYERS = 2

-- Returns { strength = key|nil, weakness = key|nil, deaths = playerCount,
-- avoidableHitters = playerCount, buffsMissing = bool }
function Insights.ForResults(results)
	local sums, counts = {}, {}
	local deaths, avoidableHitters = 0, 0
	local buffsMissing = false

	for _, r in ipairs(results) do
		for key, b in pairs(r.breakdown) do
			-- role-primary only: DPS off-healing entries averaged into
			-- "healing" made the summary scold the healer ("work on:
			-- healing" while the healer parsed fine, 2026-07-14). Demand-
			-- floored healing is neutral, not a weakness.
			local counts_ = b.applicable and GROUP_METRICS[key]
			if counts_ and key == "healing" then
				counts_ = r.role == "HEALER" and not b.lowDemand
			elseif counts_ and key == "damage" then
				counts_ = r.role ~= "HEALER"
			end
			if counts_ then
				sums[key] = (sums[key] or 0) + (b.normalized or 0)
				counts[key] = (counts[key] or 0) + 1
			end
		end
		local pd = r.penaltyDetail or {}
		if (pd.deaths or 0) > 0 then
			deaths = deaths + 1
		end
		if (pd.avoidable or 0) > 0 then
			avoidableHitters = avoidableHitters + 1
		end
		if (pd.buffs or 0) > 0 then
			buffsMissing = true
		end
	end

	local best, bestAvg, worst, worstAvg
	for key, sum in pairs(sums) do
		if counts[key] >= MIN_PLAYERS then
			local avg = sum / counts[key]
			if not best or avg > bestAvg then
				best, bestAvg = key, avg
			end
			if not worst or avg < worstAvg then
				worst, worstAvg = key, avg
			end
		end
	end

	return {
		strength = (best and bestAvg >= 65) and best or nil,
		strengthAvg = bestAvg,
		weakness = (worst and worst ~= best and worstAvg < 55) and worst or nil,
		weaknessAvg = worstAvg,
		deaths = deaths,
		avoidableHitters = avoidableHitters,
		buffsMissing = buffsMissing,
	}
end

-- The whole vs the sum of the parts (2026-07-13): individual output
-- percentiles are the parts; the kill-speed percentile is the whole.
-- Killing faster than the parses say means the group executed —
-- target discipline, mechanics, cooldown timing. Big parses with slow
-- kills mean output went somewhere other than winning. facts carries
-- run-level tallies the results array can't see: { kickOpps,
-- kicksLanded, deaths }. killPct = kill-speed percentile (0-99).
function Insights.GroupAnalysis(results, facts, killPct)
	facts = facts or {}
	local outSum, outN = 0, 0
	for _, r in ipairs(results) do
		local key = (r.role == "HEALER") and "healing" or "damage"
		local b = r.breakdown and r.breakdown[key]
		-- percentile-backed entries only: the parts must be measured on
		-- the same WCL scale as the whole
		if b and b.applicable and b.pctile and not b.lowDemand then
			outSum = outSum + b.pctile
			outN = outN + 1
		end
	end
	local a = {
		outputPct = outN > 0 and (outSum / outN) or nil,
		outputN = outN,
		killPct = killPct,
		deaths = facts.deaths,
		flawless = facts.deaths == 0 or nil,
	}
	if a.outputPct and killPct and outN >= 2 then
		a.executionGap = killPct - a.outputPct
	end
	if (facts.kickOpps or 0) > 0 then
		a.kickOpps = facts.kickOpps
		a.kicksLanded = facts.kicksLanded or 0
		a.kickCoverage = a.kicksLanded / facts.kickOpps
	end
	return a
end

-- Specific, actionable run pointers (2026-07-14): "do more healing"
-- feels bad and teaches nothing. Every pointer below names a concrete
-- behavior with the run's own numbers behind it, ordered by what most
-- plausibly cost the run. Works from raw fight records (pure Lua).
-- Returns { "text", ... } best-first; empty when the run was clean.
function Insights.RunAdvice(fights)
	local advice = {}
	local function add(priority, text)
		advice[#advice + 1] = { p = priority, text = text }
	end

	local kickOpps, kicksLanded = 0, 0
	local gWindows, gCovered = 0, 0
	local tWindows, tCovered = 0, 0
	local deaths, deathsAfterAvoidable, deathsWithDefsReady = 0, 0, 0
	local drained, lustWasted, earlyPulls = 0, 0, 0
	local avoidable, taken = 0, 0

	for _, f in ipairs(fights) do
		local t = f.totals or {}
		kickOpps = kickOpps + (t.kickOpportunities or 0)
		kicksLanded = kicksLanded + (t.kicksLanded or 0)
		avoidable = avoidable + (t.avoidableTaken or 0)
		taken = taken + (t.damageTaken or 0)
		local countedGroupSpikes = false
		for _, p in pairs(f.players or {}) do
			local m = p.metrics or {}
			local role = TP.Scoring.Capabilities.EffectiveRole(p.role, p.specIconID, p.specID)
			if role == "HEALER" then
				if not countedGroupSpikes and (m.groupSpikeWindows or 0) > 0 then
					-- group windows are shared; count once per fight
					gWindows = gWindows + m.groupSpikeWindows
					gCovered = gCovered + (m.groupSpikeCovered or 0)
					countedGroupSpikes = true
				end
				if m.dryAt or (m.manaMinPct or 100) <= 5 then
					drained = drained + 1
				end
			elseif role == "TANK" then
				tWindows = tWindows + (m.spikeWindows or 0)
				tCovered = tCovered + (m.spikeCovered or 0)
			end
			if (m.deaths or 0) > 0 then
				deaths = deaths + m.deaths
				if p.deathRecap then
					for _, hit in ipairs(p.deathRecap) do
						if hit.avoidable then
							deathsAfterAvoidable = deathsAfterAvoidable + 1
							break
						end
					end
				end
				if (p.deathReadyDefensives or 0) >= 2 then
					deathsWithDefsReady = deathsWithDefsReady + 1
				end
			end
			if role == "DAMAGER" and m.lustCasts ~= nil and m.lustCasts == 0 then
				lustWasted = lustWasted + 1
			end
			if p.aggroPulled then
				earlyPulls = earlyPulls + 1
			end
		end
	end

	-- deaths first: nothing costs a run more
	if deathsAfterAvoidable > 0 and deaths > 0 then
		add(100, deaths == deathsAfterAvoidable
			and (deaths == 1 and "The death followed avoidable damage - the recap on the death bullet names the spell."
				or ("All %d deaths followed avoidable damage - the recaps name the spells."):format(deaths))
			or ("%d of %d deaths followed avoidable damage - the recaps name the spells."):format(deathsAfterAvoidable, deaths))
	end
	if deathsWithDefsReady > 0 then
		add(90, deathsWithDefsReady == 1
			and "A death happened with 2+ defensives sitting ready - big hits are what they're for."
			or ("%d deaths happened with defensives sitting ready."):format(deathsWithDefsReady))
	end
	-- what the group ate
	if taken > 0 and avoidable / taken >= 0.10 then
		local worst
		local worstTotal = 0
		for id, e in pairs(TP.TakenSpells or {}) do
			if TP.AVOIDABLE and TP.AVOIDABLE[id] and (e.total or 0) > worstTotal then
				worst, worstTotal = e.name, e.total
			end
		end
		add(80, worst
			and ("%.0f%% of all damage taken was avoidable - %s did the most of it, and it's dodgeable."):format(avoidable / taken * 100, worst)
			or ("%.0f%% of all damage taken was avoidable."):format(avoidable / taken * 100))
	end
	-- coverage stats
	if kickOpps >= 6 and kicksLanded / kickOpps < 0.6 then
		add(70, ("%d interruptible casts got through (%d of %d kicked) - every one hit somebody."):format(
			kickOpps - kicksLanded, kicksLanded, kickOpps))
	end
	if gWindows >= 3 and gCovered / gWindows < 0.5 then
		add(60, ("%d of %d heavy group-damage moments had no healing cooldown - spreading them out covers more."):format(
			gWindows - gCovered, gWindows))
	end
	if tWindows >= 3 and tCovered / tWindows < 0.5 then
		add(55, ("Tank damage spikes went unmitigated %d of %d times - a defensive INSIDE the hit beats one after."):format(
			tWindows - tCovered, tWindows))
	end
	if drained >= 2 then
		add(50, ("The healer hit empty mana in %d fights - a drink between pulls beats a wipe."):format(drained))
	end
	if lustWasted >= 2 then
		add(40, ("%d DPS let Bloodlust pass without cooldowns - stack everything into those 40 seconds."):format(lustWasted))
	end
	if earlyPulls >= 2 then
		add(35, ("%d pulls started before the tank - a breath saves a scramble."):format(earlyPulls))
	end

	table.sort(advice, function(a, b)
		return a.p > b.p
	end)
	local out = {}
	for i = 1, #advice do
		out[i] = advice[i].text
	end
	return out
end
