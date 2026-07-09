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
	ironWall = "Iron Wall",
	-- healer-only
	notOnMyWatch = "Not on My Watch",
	toppedOff = "Topped Off",
	healedStupid = "Healed Through Stupid",
	-- boss/trash flavored
	giantSlayer = "Giant Slayer",
	lawnmower = "Lawnmower",
}

-- Why each award is given, keyed by its display label (what the UI has)
Awards.DESCRIPTIONS = {
	[Awards.LABELS.kickKing] = "Most interrupts this fight (at least 2, no tie).",
	[Awards.LABELS.cleanser] = "Most dispels this fight (at least 2, no tie).",
	[Awards.LABELS.untouchable] = "Avoidable damage went out and you dodged every bit of it.",
	[Awards.LABELS.lifesaver] = "A non-healer who covered 15%+ of the group's healing.",
	[Awards.LABELS.survivalist] = "Most self-rescue healing (potion or Healthstone) - and lived to tell about it.",
	[Awards.LABELS.ironWall] = "Most defensive cooldowns used (reported by their own TrueParse).",
	[Awards.LABELS.notOnMyWatch] = "Healer award: the boss went down and nobody died.",
	[Awards.LABELS.toppedOff] = "Healer award: nobody dropped below half health for the entire boss fight.",
	[Awards.LABELS.healedStupid] = "Healer award: the group ate a pile of avoidable damage and nobody died. You know what you did.",
	[Awards.LABELS.giantSlayer] = "Top damage on a boss fight (no tie).",
	[Awards.LABELS.lawnmower] = "Top damage on a trash pull (no tie).",
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

	-- Most peer-reported defensive cooldowns (TrueParse users only)
	local wall = topUnique(fight, "defensives", 2)
	if wall then
		grant(wall, "ironWall")
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

	-- Top damage, flavored by what died to it
	local damageKing = topUnique(fight, "damage", 1)
	if damageKing then
		grant(damageKing, fight.isBoss and "giantSlayer" or "lawnmower")
	end

	-- Healer awards: shared by every healer on the card (usually one)
	local function grantHealers(key)
		for guid, p in pairs(fight.players) do
			if p.role == "HEALER" then
				grant(guid, key)
			end
		end
	end
	local noDeaths = (fight.totals.deaths or 0) == 0

	if fight.isBoss and noDeaths then
		grantHealers("notOnMyWatch")

		-- Nobody under 50% the whole boss: needs the Classic health sampler's
		-- data on EVERY player (Midnight secrets friendly health, so retail
		-- fights simply never carry minHealthPct)
		local worst
		for _, p in pairs(fight.players) do
			local pct = p.minHealthPct
			if not pct then
				worst = nil
				break
			end
			if not worst or pct < worst then
				worst = pct
			end
		end
		if worst and worst >= 0.5 then
			grantHealers("toppedOff")
		end
	end

	-- Deathless despite the group standing in everything
	local avoidable = fight.totals.avoidableTaken or 0
	local taken = fight.totals.damageTaken or 0
	if noDeaths and avoidable > 0 and taken > 0 and avoidable / taken >= 0.15 then
		grantHealers("healedStupid")
	end

	return byGuid
end
