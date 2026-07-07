-- Per-fight superlatives: positive, data-derived awards that make the
-- scorecard fun and reward exactly the behavior TrueParse exists to promote.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Awards = {}
TP.Scoring.Awards = Awards

Awards.LABELS = {
	kickKing = "Kick King",
	cleanser = "Cleanser",
	untouchable = "Untouchable",
	lifesaver = "Lifesaver",
	survivalist = "Survivalist",
}

-- Sole top performer for a metric, requiring a minimum and no tie.
local function topUnique(fight, metric, minValue)
	local bestGuid, best, tie
	for guid, p in pairs(fight.players) do
		local v = p.metrics[metric] or 0
		if not best or v > best then
			bestGuid, best, tie = guid, v, false
		elseif v == best then
			tie = true
		end
	end
	if bestGuid and not tie and best >= minValue then
		return bestGuid
	end
end

-- Returns [guid] = { "Kick King", ... } for every player who earned one.
function Awards.Compute(fight)
	local byGuid = {}
	local function grant(guid, key)
		byGuid[guid] = byGuid[guid] or {}
		byGuid[guid][#byGuid[guid] + 1] = Awards.LABELS[key]
	end

	local kicker = topUnique(fight, "interrupts", 2)
	if kicker then
		grant(kicker, "kickKing")
	end

	local cleanser = topUnique(fight, "dispels", 2)
	if cleanser then
		grant(cleanser, "cleanser")
	end

	-- Avoidable damage went out and you dodged all of it
	if (fight.totals.avoidableTaken or 0) > 0 then
		for guid, p in pairs(fight.players) do
			if (p.metrics.avoidableTaken or 0) == 0 then
				grant(guid, "untouchable")
			end
		end
	end

	-- Saved themselves with a potion/Healthstone and didn't die
	local survivor = topUnique(fight, "potionHealing", 1)
	if survivor and (fight.players[survivor].metrics.deaths or 0) == 0 then
		grant(survivor, "survivalist")
	end

	-- Non-healer covering a meaningful slice of group healing
	local totalHeal = (fight.totals.healing or 0) + (fight.totals.absorbs or 0)
	if totalHeal > 0 then
		for guid, p in pairs(fight.players) do
			if p.role ~= "HEALER" then
				local heal = (p.metrics.healing or 0) + (p.metrics.absorbs or 0)
				if heal / totalHeal >= 0.15 then
					grant(guid, "lifesaver")
				end
			end
		end
	end

	return byGuid
end
