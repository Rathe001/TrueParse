-- Post-fight coaching: the single change that would raise this player's
-- score most, phrased as specific, actionable advice. Every scored
-- adjustment lives signed in result.adjustDetail, so the biggest NEGATIVE
-- one is the biggest recoverable mistake — that leads, not the generic
-- "cast X more often" (Josh 2026-07-26: the coach said the same throughput
-- line every fight while ignoring a -15 avoidable or a -8 lost-aggro).
-- Throughput/rotation coaching is the fallback, for when nothing concrete
-- went wrong.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Coach = {}
TP.Scoring.Coach = Coach

-- adjustment keys we coach, ordered by how actionable/severe they are
-- (used only to break exact point ties)
local PRIORITY = {}
for i, k in ipairs({
	"avoidable", "deaths", "aggroLoss", "aggro", "pull", "buffs",
	"cdTiming", "manaDry", "activity", "overheal", "overkill", "lust",
	"deathReady", "deathNoDefensives", "dispelReact", "kicks", "dispels",
}) do
	PRIORITY[k] = i
end

local MIN_CONCRETE = 3 -- points a mistake must cost to preempt "do more"

-- Returns { kind, gain, key?, normalized? }: the biggest negative
-- adjustment (kind = its key), or kind = "throughput" for the weakest
-- base metric, or nil when there's nothing worth coaching.
function Coach.BiggestOpportunity(result)
	local ad = result.adjustDetail or {}
	local bestKey, bestGain
	for key, v in pairs(ad) do
		if v and v < 0 and PRIORITY[key] then
			local gain = -v
			if not bestKey or gain > bestGain
				or (gain == bestGain and PRIORITY[key] < PRIORITY[bestKey]) then
				bestKey, bestGain = key, gain
			end
		end
	end
	if bestKey and bestGain >= MIN_CONCRETE then
		return { kind = bestKey, gain = bestGain }
	end
	-- fall back to the throughput gap: the weakest weighted BASE metric
	-- (damage/healing only — the parse the fight is really about)
	local tKey, tGain, tNorm
	for key, b in pairs(result.breakdown or {}) do
		if b.applicable and (key == "damage" or key == "healing") then
			local gain = (100 - (b.normalized or 0)) * (b.effectiveWeight or 0)
			if not tKey or gain > tGain then
				tKey, tGain, tNorm = key, gain, b.normalized
			end
		end
	end
	if tKey and tGain >= 5 then
		return { kind = "throughput", key = tKey, gain = tGain, normalized = tNorm }
	end
	-- a small concrete issue still beats silence
	if bestKey then
		return { kind = bestKey, gain = bestGain }
	end
	return nil
end

local function pctOf(a, b)
	return (a and b and b > 0) and math.floor(a / b * 100 + 0.5) or nil
end

-- Fights shorter than this give too little signal to coach, and their
-- mechanics vary too much (a burst window, a boss that barely melees) -
-- a -4 activity or a missed aggro on a 1-minute pull is the fight's
-- nature, not a habit (Josh 2026-07-26: Raigonn's phases have almost no
-- aggro to judge). Below the bar, stay quiet.
Coach.MIN_DURATION = 90

-- Only encounters ranked on Warcraft Logs are worth coaching (Josh
-- 2026-07-26): Celestial and Timewalking are so chaotic and group-
-- dependent that "advice" would be noise. WCL percentiles only exist
-- for ranked content, so the player's primary throughput metric carrying
-- a pctile IS the ranked signal (the same test Reports uses to say
-- "parse" vs "score"). Unranked content scores normalized-only, pctile nil.
local function isWclBacked(result)
	local bd = result and result.breakdown
	if not bd then
		return false
	end
	local key = result.role == "HEALER" and "healing" or "damage"
	local b = bd[key]
	return (b and b.applicable and b.pctile ~= nil) or false
end

-- The phrased, specific coaching sentence for the card + chat. Uses the
-- player's own metrics (and DeathCause / ParseGap) to make each kind
-- concrete. Returns { kind, text } or nil.
function Coach.Advise(result, fight, player)
	if not fight or (fight.duration or 0) < Coach.MIN_DURATION then
		return nil
	end
	if not isWclBacked(result) then
		return nil
	end
	local opp = Coach.BiggestOpportunity(result)
	if not opp then
		return nil
	end
	local k, m = opp.kind, (player and player.metrics) or {}

	if k == "avoidable" then
		local s = pctOf(m.avoidableTaken, m.damageTaken)
		return { kind = k, text = s and s > 0
			and ("You took avoidable damage - %d%% of your intake. Move out of the bad."):format(s)
			or "You took avoidable damage. Watch where you're standing." }
	elseif k == "deaths" then
		local DC = TP.Scoring.DeathCause
		local c = DC and player and player.deathRecap
			and DC.Classify(player.deathRecap, player.maxHP, DC.ProfilesFor(fight)) or nil
		if c and c.category == "avoidable" and c.spell then
			return { kind = k, text = ("You died to %s, an avoidable hit. Sidestep it."):format(c.spell) }
		elseif c and c.category == "tankbuster" and c.spell then
			return { kind = k, text = ("%s killed you - a tankbuster. Pre-mitigate the big hits."):format(c.spell) }
		elseif c and c.category == "chip" then
			return { kind = k, text = "You were chipped down. A defensive buys the healers time to catch up." }
		end
		return { kind = k, text = "Staying alive is your biggest gain here." }
	elseif k == "aggroLoss" then
		return { kind = k, text = "You're losing threat as the tank. Snap aggro on the pull and keep your rotation up." }
	elseif k == "aggro" then
		return { kind = k, text = "You pulled threat off the tank. Give them a couple seconds before opening up." }
	elseif k == "pull" then
		return { kind = k, text = "You started the pull before the tank had threat. Let them go first." }
	elseif k == "buffs" then
		return { kind = k, text = "Your group buff wasn't up at the pull. Buff before you engage." }
	elseif k == "cdTiming" then
		return { kind = k, text = "Your cooldowns missed the heavy-damage windows. Spend them INTO the spikes, not after." }
	elseif k == "activity" then
		return { kind = k, text = m.activityPct
			and ("Too much downtime - you were active %d%% of the fight. Keep the rotation rolling."):format(m.activityPct)
			or "Too much downtime. Cut the gaps between casts." }
	elseif k == "manaDry" then
		return { kind = k, text = "You ran out of mana mid-fight. Pace your big heals and top off between pulls." }
	elseif k == "overheal" then
		return { kind = k, text = m.overhealPct
			and ("%d%% of your healing was overheal. Aim heals where the damage is, not at topped-off bars."):format(m.overhealPct)
			or "Heavy overhealing. Cast into real damage." }
	elseif k == "overkill" then
		return { kind = k, text = m.overkillPct
			and ("%d%% of your damage was overkill. Swap off targets that are already dying."):format(m.overkillPct)
			or "You're overkilling. Move to fresh targets sooner." }
	elseif k == "lust" then
		return { kind = k, text = "You didn't stack cooldowns into Bloodlust. Line your burst up with it." }
	elseif k == "dispelReact" then
		return { kind = k, text = m.dispelReactAvg
			and ("Your dispels are slow - %.1fs on average. Clear debuffs the moment they land."):format(m.dispelReactAvg)
			or "Your dispels are slow. React faster." }
	elseif k == "deathReady" or k == "deathNoDefensives" then
		return { kind = k, text = "You died with defensives unused. Big hits are exactly what they're for." }
	elseif k == "kicks" then
		return { kind = k, text = "You're missing interrupts. Watch for the casts you can kick." }
	elseif k == "dispels" then
		return { kind = k, text = "There were debuffs to dispel that you didn't get. Keep an eye out." }
	elseif k == "throughput" then
		-- the rotation gap: ParseGap's "cast X more often" is the specific
		-- form; a plain line when there's no profile
		local gap = TP.Scoring.Insights and TP.Scoring.Insights.ParseGap
			and TP.Scoring.Insights.ParseGap(player and player.specID, m, fight and fight.duration)
		if gap then
			return { kind = k, text = gap.text }
		end
		local label = opp.key == "healing" and "healing" or "damage"
		return { kind = k, text = ("Your %s was low this fight - tighten the rotation."):format(label) }
	end
	return nil
end
