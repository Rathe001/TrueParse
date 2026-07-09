-- Plain-language bullets explaining a score: green + for what earned it,
-- red - for what cost it, a dim middle-dot for middling. Human phrases only;
-- the numbers live in hover tooltips.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Bullets = {}
TP.Scoring.Bullets = Bullets

local GOOD = { 0.30, 0.90, 0.40 }
local BAD = { 0.95, 0.35, 0.35 }
local MID = { 0.80, 0.80, 0.55 }
local GOLD = { 1.00, 0.82, 0.20 }
local MIDDOT = "\194\183"

local function sentimentOf(normalized)
	if normalized >= 70 then
		return "good", "+", GOOD
	elseif normalized <= 45 then
		return "bad", "-", BAD
	end
	return "mid", MIDDOT, MID
end

local PHRASES = {
	damage = { good = "Strong damage", mid = "Decent damage", bad = "Low damage", zero = "Did no damage" },
	healing = { good = "Strong healing", mid = "Decent healing", bad = "Low healing", zero = "No healing" },
	healingOff = { good = "Great off-healing", mid = "Some off-healing", bad = "Little off-healing", zero = "No off-healing" },
	damageTaken = { good = "Soaked the group's hits", mid = "Took a fair share of hits", bad = "Didn't soak much", zero = "Took no hits" },
	interrupts = { good = "Great interrupting", mid = "Some interrupts", bad = "Too few interrupts", zero = "Did not interrupt" },
	dispels = { good = "Great dispelling", mid = "Some dispels", bad = "Too few dispels", zero = "Did not dispel" },
	buffUptime = { good = "Kept the buffs rolling", mid = "Decent buff uptime", bad = "Low buff uptime", zero = "Buffs never up" },
}

local PENALTY_DEFS = {
	{ key = "deaths", label = "Died" },
	{ key = "avoidable", label = "Took avoidable damage" },
	{ key = "pull", label = "Pulled before the tank" },
	{ key = "aggro", label = "Ripped aggro off the tank" },
	{ key = "aggroLoss", label = "Lost aggro" },
	{ key = "buffs", label = "Raid buff missing at the pull" },
}

-- result: one engine score row; awards: array of award names (optional);
-- extra: optional { defensives = n } peer-reported data (unscored info).
-- Returns array of { kind = "metric"|"penalty"|"award"|"info", key, symbol,
-- color = {r,g,b}, text }
function Bullets.ForResult(result, awards, extra)
	local out = {}

	-- Trophies first
	for _, award in ipairs(awards or {}) do
		out[#out + 1] = { kind = "award", symbol = TP.STAR, color = GOLD, text = award }
	end

	local metrics = {}
	for key, b in pairs(result.breakdown) do
		if b.applicable then
			metrics[#metrics + 1] = { key = key, b = b }
		end
	end
	table.sort(metrics, function(x, y)
		return (x.b.effectiveWeight or 0) > (y.b.effectiveWeight or 0)
	end)

	for _, m in ipairs(metrics) do
		local b, key = m.b, m.key
		local sentiment, symbol, color = sentimentOf(b.normalized or 0)
		local phraseKey = key
		if key == "healing" and result.role ~= "HEALER" then
			phraseKey = "healingOff"
		end
		local phrases = PHRASES[phraseKey] or PHRASES.damage
		local text = phrases[sentiment]
		if sentiment == "bad" and (b.value or 0) == 0 and phrases.zero then
			text = phrases.zero
		end
		out[#out + 1] = { kind = "metric", key = key, symbol = symbol, color = color, text = text }
	end

	-- Peer-reported facts: informational, never scored
	if extra and extra.defensives ~= nil then
		if extra.defensives > 0 then
			out[#out + 1] = { kind = "info", key = "defensives", symbol = "+", color = GOOD,
				text = extra.defensives == 1 and "Used a defensive cooldown" or ("Used %d defensive cooldowns"):format(extra.defensives) }
		else
			out[#out + 1] = { kind = "info", key = "defensives", symbol = MIDDOT, color = MID,
				text = "No defensive cooldowns used" }
		end
	end
	if extra and extra.consumables ~= nil then
		if extra.consumables >= 2 then
			out[#out + 1] = { kind = "info", key = "consumables", symbol = "+", color = GOOD,
				text = "Came prepared (flask/food up)" }
		elseif extra.consumables == 1 then
			out[#out + 1] = { kind = "info", key = "consumables", symbol = MIDDOT, color = MID,
				text = "Partially prepared" }
		else
			out[#out + 1] = { kind = "info", key = "consumables", symbol = MIDDOT, color = MID,
				text = "No consumables at the pull" }
		end
	end
	if extra and extra.deathReady ~= nil then
		if extra.deathReady > 0 then
			out[#out + 1] = { kind = "info", key = "deathReady", symbol = "-", color = BAD,
				text = extra.deathReady == 1 and "Died with a defensive ready"
					or ("Died with %d defensives ready"):format(extra.deathReady) }
		else
			out[#out + 1] = { kind = "info", key = "deathReady", symbol = MIDDOT, color = MID,
				text = "Died with everything on cooldown" }
		end
	end

	local pd = result.penaltyDetail or {}
	for _, def in ipairs(PENALTY_DEFS) do
		local amount = pd[def.key] or 0
		if amount > 0 then
			out[#out + 1] = { kind = "penalty", key = def.key, symbol = "-", color = BAD, text = def.label }
		end
	end

	return out
end

local GROUP_PHRASES = {
	damage = { good = "Strong damage from the group", mid = "Group damage was okay", bad = "Group damage was low" },
	healing = { good = "Healing kept everyone up", mid = "Healing was okay", bad = "Healing struggled" },
	interrupts = { good = "Kicks were covered", mid = "Interrupts were spotty", bad = "Not enough interrupting", zero = "Nobody interrupted" },
	dispels = { good = "Dispels were handled", mid = "Dispels were spotty", bad = "Too few dispels", zero = "Nobody dispelled" },
}
local GROUP_ORDER = { "damage", "healing", "interrupts", "dispels" }

-- Group-level bullets from a full results array. Each carries its own
-- tooltip = { title, lines } since the caller has no per-player breakdown.
function Bullets.ForGroup(results)
	local out = {}
	local sums, counts, totals = {}, {}, {}
	local died, avoidable, buffsMissing = 0, 0, false
	local aggroed, tankLostAggro = 0, false

	for _, r in ipairs(results) do
		for key, b in pairs(r.breakdown) do
			if b.applicable and GROUP_PHRASES[key] then
				sums[key] = (sums[key] or 0) + (b.normalized or 0)
				counts[key] = (counts[key] or 0) + 1
				totals[key] = (totals[key] or 0) + (b.value or 0)
			end
		end
		local pd = r.penaltyDetail or {}
		if (pd.deaths or 0) > 0 then died = died + 1 end
		if (pd.avoidable or 0) > 0 then avoidable = avoidable + 1 end
		if (pd.buffs or 0) > 0 then buffsMissing = true end
		if (pd.aggro or 0) > 0 or (pd.pull or 0) > 0 then aggroed = aggroed + 1 end
		if (pd.aggroLoss or 0) > 0 then tankLostAggro = true end
	end

	for _, key in ipairs(GROUP_ORDER) do
		if counts[key] and counts[key] > 0 then
			local avg = sums[key] / counts[key]
			local sentiment, symbol, color = sentimentOf(avg)
			local phrases = GROUP_PHRASES[key]
			local text = phrases[sentiment]
			if sentiment == "bad" and (totals[key] or 0) == 0 and phrases.zero then
				text = phrases.zero
			end
			out[#out + 1] = {
				kind = "metric", key = key, symbol = symbol, color = color, text = text,
				tooltip = {
					title = TP.METRIC_LABELS[key] or key,
					lines = {
						{ ("Group average %.0f/100 across %d players."):format(avg, counts[key]), 1, 1, 1 },
					},
				},
			}
		end
	end

	if died > 0 then
		out[#out + 1] = { kind = "penalty", key = "deaths", symbol = "-", color = BAD,
			text = died == 1 and "1 player died" or ("%d players died"):format(died) }
	end
	if avoidable > 0 then
		out[#out + 1] = { kind = "penalty", key = "avoidable", symbol = "-", color = BAD,
			text = avoidable == 1 and "1 player took avoidable damage" or ("%d players took avoidable damage"):format(avoidable) }
	end
	if aggroed > 0 then
		out[#out + 1] = { kind = "penalty", key = "aggro", symbol = "-", color = BAD,
			text = aggroed == 1 and "1 player pulled aggro" or ("%d players pulled aggro"):format(aggroed) }
	end
	if tankLostAggro then
		out[#out + 1] = { kind = "penalty", key = "aggroLoss", symbol = "-", color = BAD,
			text = "Aggro slipped off the tank" }
	end
	if buffsMissing then
		out[#out + 1] = { kind = "penalty", key = "buffs", symbol = "-", color = BAD,
			text = "Raid buffs missing at the pull" }
	end

	return out
end
