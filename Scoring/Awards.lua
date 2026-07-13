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
	unbreakable = "Unbreakable",
	survivalist = "Survivalist",
	ironWall = "Iron Wall",
	-- healer-only
	notOnMyWatch = "Not on My Watch",
	toppedOff = "Topped Off",
	healedStupid = "Healed Through Stupid",
	-- boss/trash flavored
	giantSlayer = "Giant Slayer",
	lawnmower = "Lawnmower",
	-- cross-role excellence
	virtuoso = "Virtuoso",
}

-- Why each award is given, keyed by its display label (what the UI has)
Awards.DESCRIPTIONS = {
	[Awards.LABELS.kickKing] = "Most interrupts this fight (at least 3, no tie).",
	[Awards.LABELS.cleanser] = "Most dispels this fight (at least 3, no tie).",
	[Awards.LABELS.untouchable] = "Avoidable damage hit the rest of the group - one player dodged every bit of it.",
	[Awards.LABELS.lifesaver] = "The top non-healer healer: covered 15%+ of the group's healing - on other people.",
	[Awards.LABELS.unbreakable] = "The top non-healer healer: covered 15%+ of the group's healing by keeping themselves alive. Nobody heals this one.",
	[Awards.LABELS.survivalist] = "Most self-rescue healing (potion or Healthstone) - and lived to tell about it.",
	[Awards.LABELS.ironWall] = "Most defensive cooldowns used (reported by their own TrueParse, at least 3).",
	[Awards.LABELS.notOnMyWatch] = "Healer award: a real boss fight (90s+) ended with nobody dying.",
	[Awards.LABELS.toppedOff] = "Healer award: nobody dropped below half health for the entire boss fight.",
	[Awards.LABELS.healedStupid] = "Healer award: the group ate a pile of avoidable damage and nobody died. You know what you did.",
	[Awards.LABELS.giantSlayer] = "Top damage on a boss fight, and it wasn't close (25%+ over second place).",
	[Awards.LABELS.lawnmower] = "Top damage on a trash pull, and it wasn't close (25%+ over second place).",
	[Awards.LABELS.virtuoso] = "Top-10% of their spec in the category that ISN'T their job: a healer parsing like a DPS, a tank out-healing expectations.",
}

-- One award per player, rarest first: a card where everyone wears two
-- ribbons makes ribbons worthless (Josh, 2026-07-12). Lower = rarer.
local PRIORITY = {
	virtuoso = 1, toppedOff = 2, healedStupid = 3, untouchable = 4,
	lifesaver = 5, unbreakable = 6, notOnMyWatch = 7, survivalist = 8,
	ironWall = 9, kickKing = 10, cleanser = 11,
	giantSlayer = 12, lawnmower = 13,
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

-- Awards are deterministic per fight record; hovering a 25-row card was
-- recomputing them 25 times. Weak-keyed so released fights free the memo.
local computeCache = setmetatable({}, { __mode = "k" })

-- Late-arriving peer reports change award inputs (Iron Wall reads
-- defensives): Sync invalidates after attaching.
function Awards.Invalidate(fight)
	computeCache[fight] = nil
end

-- Returns [guid] = { "Kick King", ... } for every player who earned one.
function Awards.Compute(fight)
	local cached = computeCache[fight]
	if cached then
		return cached
	end
	local byGuid = {} -- [guid] = { key, ... } until the priority pass
	local function grant(guid, key)
		byGuid[guid] = byGuid[guid] or {}
		byGuid[guid][#byGuid[guid] + 1] = key
	end

	local kicker = topUnique(fight, "interrupts", 3)
	if kicker then
		grant(kicker, "kickKing")
	end

	local cleanser = topUnique(fight, "dispels", 3)
	if cleanser then
		grant(cleanser, "cleanser")
	end

	-- Untouchable: avoidable damage hit the group and exactly ONE player
	-- dodged every bit of it. Dodging what nobody else managed is an
	-- award; standing in nothing on a clean fight is Tuesday.
	if (fight.totals.avoidableTaken or 0) > 0 then
		local clean, cleanGuid, total = 0, nil, 0
		for guid, p in pairs(fight.players) do
			total = total + 1
			if (p.metrics.avoidableTaken or 0) == 0 then
				clean = clean + 1
				cleanGuid = guid
			end
		end
		if clean == 1 and total >= 3 then
			grant(cleanGuid, "untouchable")
		end
	end

	-- Most peer-reported defensive cooldowns (TrueParse users only)
	local wall = topUnique(fight, "defensives", 3)
	if wall then
		grant(wall, "ironWall")
	end

	-- Saved themselves with a potion/Healthstone and didn't die
	local survivor = topUnique(fight, "potionHealing", 1)
	if survivor and (fight.players[survivor].metrics.deaths or 0) == 0 then
		grant(survivor, "survivalist")
	end

	-- Non-healer covering a meaningful slice of group healing (effective
	-- role: the assigned one calls a solo Mistweaver a DAMAGER).
	-- "Saving lives" requires healing OTHER people: mostly-self healing
	-- earns Unbreakable instead (split only known on Classic captures;
	-- without it the healing is assumed outward).
	local totalHeal = (fight.totals.healing or 0) + (fight.totals.absorbs or 0)
	if totalHeal > 0 then
		-- only the TOP qualifying off-healer: three DPS each over the bar
		-- used to mean three ribbons
		local bestGuid, bestShare
		for guid, p in pairs(fight.players) do
			if TP.Scoring.Capabilities.EffectiveRole(p.role, p.specIconID, p.specID) ~= "HEALER" then
				local share = ((p.metrics.healing or 0) + (p.metrics.absorbs or 0)) / totalHeal
				if share >= 0.15 and (not bestShare or share > bestShare) then
					bestGuid, bestShare = guid, share
				end
			end
		end
		if bestGuid then
			local p = fight.players[bestGuid]
			local selfShare = (p.metrics.selfHealing and (p.metrics.healing or 0) > 0)
				and (p.metrics.selfHealing / p.metrics.healing) or nil
			grant(bestGuid, (selfShare and selfShare >= 0.8) and "unbreakable" or "lifesaver")
		end
	end

	-- Top damage, flavored by what died to it — but only a DOMINANT top:
	-- somebody always wins the meter, and that's already the score's job.
	-- No trophy for a wipe.
	if not fight.wipe then
		local best, second = 0, 0
		local bestGuid
		for guid, p in pairs(fight.players) do
			local v = p.metrics.damage or 0
			if v > best then
				bestGuid, best, second = guid, v, best
			elseif v > second then
				second = v
			end
		end
		if bestGuid and best > 0 and best >= second * 1.25 then
			grant(bestGuid, fight.isBoss and "giantSlayer" or "lawnmower")
		end
	end

	-- Healer awards: shared by every healer on the card (usually one)
	local function grantHealers(key)
		for guid, p in pairs(fight.players) do
			if TP.Scoring.Capabilities.EffectiveRole(p.role, p.specIconID, p.specID) == "HEALER" then
				grant(guid, key)
			end
		end
	end
	-- nil means the deaths data never arrived (secret or missing session):
	-- unknown is not the same as flawless
	local noDeaths = fight.totals.deaths == 0

	-- 90s+ only: a deathless 20-second heroic steamroll is not a save
	if fight.isBoss and noDeaths and (fight.duration or 0) >= 90 then
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

	-- Virtuoso: top-10% of your spec's population in the category that
	-- isn't your job (needs the off-metric percentile curves)
	local Engine = TP.Scoring.Engine
	local pcts = Engine.ResolvePercentiles and Engine.ResolvePercentiles(fight)
	if pcts and (fight.duration or 0) > 0 then
		for guid, p in pairs(fight.players) do
			local role = TP.Scoring.Capabilities.EffectiveRole(p.role, p.specIconID, p.specID)
			local offTbl, rate
			if role == "HEALER" then
				offTbl = pcts.dps
				rate = (p.metrics.damage or 0) / fight.duration
			elseif role ~= "SUPPORT" then
				offTbl = pcts.hps
				rate = ((p.metrics.healing or 0) + (p.metrics.absorbs or 0)) / fight.duration
			end
			local entry = offTbl and p.specID and offTbl[p.specID]
			if entry and entry.curve and #entry.curve > 1
				and Engine.PercentileFor(entry.curve, rate) >= 90 then
				grant(guid, "virtuoso")
			end
		end
	end

	-- The scarcity rule: one award per player, rarest wins
	for guid, keys in pairs(byGuid) do
		local best = keys[1]
		for i = 2, #keys do
			if PRIORITY[keys[i]] < PRIORITY[best] then
				best = keys[i]
			end
		end
		byGuid[guid] = { Awards.LABELS[best] }
	end

	computeCache[fight] = byGuid
	return byGuid
end
