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
	local diedPF = 0 -- player-fights with a death (recaps are per-player)
	local drained, lustWasted, earlyPulls = 0, 0, 0
	local avoidable, taken = 0, 0
	local healerHeavy, healerFieldMode, healerRan = 0, nil, nil
	local callTails, callTailSum = 0, 0

	for _, f in ipairs(fights) do
		local t = f.totals or {}
		local fHealers, fSize = 0, 0
		kickOpps = kickOpps + (t.kickOpportunities or 0)
		kicksLanded = kicksLanded + (t.kicksLanded or 0)
		avoidable = avoidable + (t.avoidableTaken or 0)
		taken = taken + (t.damageTaken or 0)
		local countedGroupSpikes = false
		for _, p in pairs(f.players or {}) do
			local m = p.metrics or {}
			local role = TP.Scoring.Capabilities.EffectiveRole(p.role, p.specIconID, p.specID)
			fSize = fSize + 1
			if role == "HEALER" then
				fHealers = fHealers + 1
				if not countedGroupSpikes and (m.groupSpikeWindows or 0) > 0 then
					-- group windows are shared; count once per fight.
					-- Capacity-capped like the engine: windows beyond what
					-- the team's raid CDs could cover aren't advice material
					local w, c = m.groupSpikeWindows, m.groupSpikeCovered or 0
					if (m.groupCdCasts or 0) > 0 then
						w = math.min(w, math.max(m.groupCdCasts, c) + 1)
					end
					gWindows = gWindows + w
					gCovered = gCovered + math.min(c, w)
					countedGroupSpikes = true
				end
				if m.dryAt or (m.manaMinPct or 100) <= 5 then
					drained = drained + 1
				end
			elseif role == "TANK" then
				local w, c = m.spikeWindows or 0, m.spikeCovered or 0
				if w > 0 and (m.defensiveUses or 0) > 0 then
					w = math.min(w, math.max(m.defensiveUses, c) + 1)
				end
				tWindows = tWindows + w
				tCovered = tCovered + math.min(c, w)
			end
			if (m.deaths or 0) > 0 then
				deaths = deaths + m.deaths
				diedPF = diedPF + 1
				-- post-wipe-call deaths are the plan: their recaps show
				-- deliberate resets (standing in bad on purpose), and
				-- unspent defensives were correctly saved — neither is
				-- advice material (audit 2026-07-18)
				local forgiven = f.calledWipeAt and p.deathTime
					and p.deathTime >= f.calledWipeAt
				if p.deathRecap and not forgiven then
					for _, hit in ipairs(p.deathRecap) do
						if hit.avoidable then
							deathsAfterAvoidable = deathsAfterAvoidable + 1
							break
						end
					end
				end
				if (p.deathReadyDefensives or 0) >= 2 and not forgiven then
					deathsWithDefsReady = deathsWithDefsReady + 1
				end
			end
			-- dead before the window opened = excused, same as the engine
			if role == "DAMAGER" and m.lustCasts ~= nil and m.lustCasts == 0
				and not (f.lustAt and p.deathTime and p.deathTime <= f.lustAt) then
				lustWasted = lustWasted + 1
			end
			if p.aggroPulled then
				earlyPulls = earlyPulls + 1
			end
		end
		-- wipe-call crispness: how long the group kept fighting past the
		-- call (dying fast IS the reset)
		if f.wipe and f.calledWipeAt and (f.duration or 0) > f.calledWipeAt then
			callTails = callTails + 1
			callTailSum = callTailSum + (f.duration - f.calledWipeAt)
		end
		-- comp vs the field: count kills where the group ran more healers
		-- than ranked kills' dominant comp (same-size comps only)
		if f.isBoss and not f.wipe and fSize > 0 then
			local field, fieldSize = TP.Scoring.Engine.HealerCountField(f)
			if field and field.mode and (field.modePct or 0) >= 50
				and fHealers > field.mode and fieldSize
				and math.abs(fSize - fieldSize) <= 2 then
				healerHeavy = healerHeavy + 1
				healerFieldMode = field.mode
				healerRan = fHealers
			end
		end
	end

	-- deaths first: nothing costs a run more. Recaps are per-PLAYER
	-- (last death only), so the denominator is players who died, not
	-- total deaths (audit 2026-07-16 unit mismatch).
	if deathsAfterAvoidable > 0 and diedPF > 0 then
		add(100, diedPF == deathsAfterAvoidable
			and (diedPF == 1 and "The death followed avoidable damage - the recap on the death bullet names the spell."
				or ("Every player who died took avoidable damage in their final seconds - the recaps name the spells."))
			or ("%d of the %d players who died took avoidable damage in their final seconds - the recaps name the spells."):format(deathsAfterAvoidable, diedPF))
	end
	if deathsWithDefsReady > 0 then
		add(90, deathsWithDefsReady == 1
			and "A death happened with 2+ defensives sitting ready - big hits are what they're for."
			or ("%d deaths happened with defensives sitting ready."):format(deathsWithDefsReady))
	end
	-- what the group ate
	if taken > 0 and avoidable / taken >= 0.10 then
		-- no spell name here: TakenSpells is an account-LIFETIME tally,
		-- and naming last week's raid mechanic as tonight's culprit was
		-- wrong (audit 2026-07-16). /tp baddies still names names with
		-- its scope labeled.
		add(80, ("%.0f%% of all damage taken was avoidable - the death recaps and /tp baddies name the spells."):format(avoidable / taken * 100))
	end
	-- coverage stats
	if kickOpps >= 6 and kicksLanded / kickOpps < 0.6 then
		-- counterfactual, from the engine's own kick formula: what would
		-- 80% coverage have been worth? (kicksMax x intensity x the
		-- coverage gap — approximate, so it says "roughly")
		local A2 = TP.Scoring.Weights.adjustments
		local intensity = math.min(1, kickOpps / (math.max(1, #fights) * (A2.kicksFullIntensity or 6)))
		local worth = (0.8 - kicksLanded / kickOpps) * (A2.kicksMax or 6) * intensity
		local tail = worth >= 1
			and (" Kicking 80%% would be worth roughly +%.0f points to the kickers."):format(worth)
			or ""
		add(70, ("%d interruptible casts got through (%d of %d kicked) - every one hit somebody.%s"):format(
			kickOpps - kicksLanded, kicksLanded, kickOpps, tail))
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
		add(40, ("Bloodlust went by unused %d times - stack cooldowns into those 40 seconds."):format(lustWasted))
	end
	if earlyPulls >= 2 then
		add(35, ("%d pulls started before the tank - a breath saves a scramble."):format(earlyPulls))
	end
	if callTails >= 2 and callTailSum / callTails >= 25 then
		add(33, ("Wipes drag %ds past the call on average - once it's called, dying fast IS the reset."):format(
			math.floor(callTailSum / callTails + 0.5)))
	end
	-- comp advice last: it's a choice, not a mistake — but if the group
	-- runs heavier than the field all night, say what it's trading away
	if healerHeavy >= 2 and healerFieldMode and healerRan then
		add(30, ("Ranked kills of these bosses mostly run %d healers; your %d-heal comp trades kill speed for safety - a healer swapped to DPS is the cheapest speed upgrade."):format(
			healerFieldMode, healerRan))
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
