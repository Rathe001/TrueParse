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
	-- fall back to the throughput gap: the role's PRIMARY metric only.
	-- Healers are judged on healing, everyone else on damage — coaching a
	-- healer to pad damage (or a DPS to heal more) is noise (Josh 2026-07-26:
	-- a 99 healing parse got told "your damage has room to grow"). A top
	-- parse leaves a gap too small to clear the bar, so nothing fires.
	local primary = (result.role == "HEALER" and "healing")
		or (result.role == "TANK" and "mitigation") or "damage"
	local b = (result.breakdown or {})[primary]
	if b and b.applicable then
		-- only coach throughput when the parse is genuinely BELOW AVERAGE
		-- (Josh 2026-07-26: a 93 parse was told "your damage was low, tighten
		-- the rotation" because the old gain*weight test caught high parses -
		-- (100-93)*0.86 cleared the bar). Above the median there's nothing to
		-- nag about, so stay quiet.
		local parse = b.pctile or b.normalized or 100
		if parse < 50 then
			return { kind = "throughput", key = primary, gain = 100 - parse, normalized = parse }
		end
	end
	-- nothing cleared the bar (no mistake >= MIN_CONCRETE, no real
	-- throughput gap): stay silent rather than nag about a -1. A clean
	-- fight deserves no coach line.
	return nil
end

local function pctOf(a, b)
	return (a and b and b > 0) and math.floor(a / b * 100 + 0.5) or nil
end

-- Deterministic phrasing, same idea as the reports (Josh 2026-07-26: the
-- coach should read differently player to player, not the same sentence
-- every card). The seed folds in the player's identity as well as the
-- fight, so two people with the same problem get different wordings while
-- each stays stable for a given fight. PURE: djb2 over a string, no RNG.
local function hashOf(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 2147483647
	end
	return h
end

local function seedFor(fight, player)
	local id = (player and (player.guid or player.name)) or ""
	return hashOf(((fight and fight.name) or "fight") .. "#"
		.. math.floor((fight and fight.duration) or 0) .. "#" .. id)
end

local function pick(seed, salt, options)
	return options[(seed + salt) % #options + 1]
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
	local seed = seedFor(fight, player)
	local function say(salt, options)
		return { kind = k, text = pick(seed, salt, options) }
	end

	if k == "avoidable" then
		-- name the specific mechanic when we can (MoP/CLEU for everyone;
		-- retail for the local player's spike hits): far more actionable than
		-- "the bad" (Josh 2026-07-26). Measured against the crawled field.
		local mech = TP.Scoring.Insights and TP.Scoring.Insights.MechanicGaps
			and TP.Scoring.Insights.MechanicGaps(player, fight)
		if mech and mech.spell then
			local field = math.floor((mech.hitRate or 0) * 100 + 0.5)
			-- impact context from the crawled field: "~240k each" (avgDmg is
			-- per-taker, from the table). Degrades cleanly when absent.
			local dmg = (mech.avgDmg and mech.avgDmg > 0 and TP.FormatNumber)
				and TP.FormatNumber(mech.avgDmg) or nil
			local hits = mech.hits or 1
			local lead
			if hits > 1 then
				lead = dmg and ("You took %s %d times (~%s each)"):format(mech.spell, hits, dmg)
					or ("You took %s %d times"):format(mech.spell, hits)
			else
				lead = dmg and ("You took %s (~%s)"):format(mech.spell, dmg)
					or ("You took %s"):format(mech.spell)
			end
			return say(30, {
				("%s - only %d%% of players get hit by it. Sidestep it."):format(lead, field),
				("%s; most players avoid it (%d%% take it). Watch for it."):format(lead, field),
			})
		end
		local s = pctOf(m.avoidableTaken, m.damageTaken)
		if s and s > 0 then
			return say(1, {
				("You took avoidable damage, %d%% of your intake. Move out of the bad."):format(s),
				("Roughly %d%% of the damage you took was avoidable. Watch your feet."):format(s),
				("You ate %d%% of your damage from things you could sidestep. Mind the ground."):format(s),
			})
		end
		return say(2, {
			"You took avoidable damage. Watch where you're standing.",
			"You're standing in mechanics you can dodge. Keep an eye on the ground.",
		})
	elseif k == "deaths" then
		local DC = TP.Scoring.DeathCause
		local c = DC and player and player.deathRecap
			and DC.Classify(player.deathRecap, player.maxHP, DC.ProfilesFor(fight)) or nil
		if c and c.category == "avoidable" and c.spell then
			return say(3, {
				("You died to %s, an avoidable hit. Sidestep it next time."):format(c.spell),
				("%s killed you, and it was dodgeable. Move out of it."):format(c.spell),
			})
		elseif c and c.category == "tankbuster" and c.spell then
			return say(4, {
				("%s killed you, a tankbuster. Pre-mitigate the big hits."):format(c.spell),
				("%s hit you for the kill. Have a defensive up for that one."):format(c.spell),
			})
		elseif c and c.category == "chip" then
			return say(5, {
				"You were chipped down. A defensive buys the healers time to catch up.",
				"No single hit killed you, it was accumulated damage. Pop something to ease the healers.",
			})
		end
		return say(6, {
			"Staying alive is your biggest gain here.",
			"The most points on the table are simply not dying.",
		})
	elseif k == "aggroLoss" then
		return say(7, {
			"You're losing threat as the tank. Snap aggro on the pull and keep your rotation up.",
			"Threat is slipping off you. Open hard and don't drop your rotation.",
		})
	elseif k == "aggro" then
		return say(8, {
			"You pulled threat off the tank. Give them a couple seconds before opening up.",
			"You grabbed aggro early. Let the tank settle in first.",
		})
	elseif k == "pull" then
		return say(9, {
			"You started the pull before the tank had threat. Let them go first.",
			"You opened before the tank. Hold for a beat so they can grab it.",
		})
	elseif k == "buffs" then
		return say(10, {
			"Your group buff wasn't up at the pull. Buff before you engage.",
			"You went in without your raid buff up. Cast it before the pull.",
		})
	elseif k == "cdTiming" then
		return say(11, {
			"Your cooldowns missed the heavy-damage windows. Spend them into the spikes, not after.",
			"You're using cooldowns off the big moments. Line them up with the damage.",
		})
	elseif k == "activity" then
		if m.activityPct then
			return say(12, {
				("Too much downtime, you were active %d%% of the fight. Keep the rotation rolling."):format(m.activityPct),
				("You were active only %d%% of the fight. Trim the gaps between casts."):format(m.activityPct),
				("%d%% activity leaves points on the table. Keep pressing buttons."):format(m.activityPct),
			})
		end
		return say(13, {
			"Too much downtime. Cut the gaps between casts.",
			"You had idle stretches. Keep the rotation moving.",
		})
	elseif k == "manaDry" then
		return say(14, {
			"You ran out of mana mid-fight. Pace your big heals and top off between pulls.",
			"You went dry on mana. Ease off the expensive heals and refill between fights.",
		})
	elseif k == "overheal" then
		if m.overhealPct then
			return say(15, {
				("%d%% of your healing was overheal. Aim heals where the damage is, not at topped-off bars."):format(m.overhealPct),
				("You overhealed %d%% of your output. Hold casts for real damage instead of full bars."):format(m.overhealPct),
			})
		end
		return say(16, {
			"Heavy overhealing. Cast into real damage.",
			"A lot of your healing landed on full health. Wait for the damage.",
		})
	elseif k == "overkill" then
		if m.overkillPct then
			return say(17, {
				("%d%% of your damage was overkill. Swap off targets that are already dying."):format(m.overkillPct),
				("You overkilled %d%% of your damage. Move to fresh targets sooner."):format(m.overkillPct),
			})
		end
		return say(18, {
			"You're overkilling. Move to fresh targets sooner.",
			"Too much damage into dying targets. Switch earlier.",
		})
	elseif k == "lust" then
		return say(19, {
			"You didn't stack cooldowns into Bloodlust. Line your burst up with it.",
			"Your burst missed Bloodlust. Save cooldowns for the Lust window.",
		})
	elseif k == "dispelReact" then
		if m.dispelReactAvg then
			return say(20, {
				("Your dispels are slow, %.1fs on average. Clear debuffs the moment they land."):format(m.dispelReactAvg),
				("You're averaging %.1fs to dispel. React the instant the debuff shows."):format(m.dispelReactAvg),
			})
		end
		return say(21, {
			"Your dispels are slow. React faster.",
			"You're late on dispels. Clear them sooner.",
		})
	elseif k == "deathReady" or k == "deathNoDefensives" then
		return say(22, {
			"You died with defensives unused. Big hits are exactly what they're for.",
			"You had a defensive ready when you died. Use it on the spike.",
		})
	elseif k == "kicks" then
		return say(23, {
			"You're missing interrupts. Watch for the casts you can kick.",
			"There were kicks available you didn't take. Watch the enemy casts.",
		})
	elseif k == "dispels" then
		return say(24, {
			"There were debuffs to dispel that you didn't get. Keep an eye out.",
			"You left debuffs up that you could have cleared. Watch for them.",
		})
	elseif k == "throughput" then
		-- a tank's throughput gap is mitigation uptime, not damage
		if opp.key == "mitigation" then
			return say(26, m.mitigationPct and {
				("You held active mitigation up %d%%. Keep it rolling more of the fight."):format(m.mitigationPct),
				("Mitigation uptime was %d%%, under your spec's field. Press it more often."):format(m.mitigationPct),
			} or {
				"Your active mitigation uptime is low. Keep it rolling through the fight.",
				"You're letting active mitigation drop. Hold it up more of the fight.",
			})
		end
		-- the rotation gap: ParseGap names the signature spell top parses
		-- lean on, so it's already personalized; a varied plain line covers
		-- the no-profile case
		local gap = TP.Scoring.Insights and TP.Scoring.Insights.ParseGap
			and TP.Scoring.Insights.ParseGap(player and player.specID, m, fight and fight.duration)
		if gap then
			return { kind = k, text = gap.text }
		end
		local label = opp.key == "healing" and "healing" or "damage"
		return say(25, {
			("Your %s was low this fight. Tighten the rotation."):format(label),
			("Your %s has room to grow. Work the rotation."):format(label),
		})
	end
	return nil
end
