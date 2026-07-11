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
	[Awards.LABELS.kickKing] = "Most interrupts this fight (at least 2, no tie).",
	[Awards.LABELS.cleanser] = "Most dispels this fight (at least 2, no tie).",
	[Awards.LABELS.untouchable] = "Avoidable damage went out and you dodged every bit of it.",
	[Awards.LABELS.lifesaver] = "A non-healer who covered 15%+ of the group's healing - on other people.",
	[Awards.LABELS.unbreakable] = "A non-healer who covered 15%+ of the group's healing by keeping themselves alive. Nobody heals this one.",
	[Awards.LABELS.survivalist] = "Most self-rescue healing (potion or Healthstone) - and lived to tell about it.",
	[Awards.LABELS.ironWall] = "Most defensive cooldowns used (reported by their own TrueParse).",
	[Awards.LABELS.notOnMyWatch] = "Healer award: the boss went down and nobody died.",
	[Awards.LABELS.toppedOff] = "Healer award: nobody dropped below half health for the entire boss fight.",
	[Awards.LABELS.healedStupid] = "Healer award: the group ate a pile of avoidable damage and nobody died. You know what you did.",
	[Awards.LABELS.giantSlayer] = "Top damage on a boss fight (no tie).",
	[Awards.LABELS.lawnmower] = "Top damage on a trash pull (no tie).",
	[Awards.LABELS.virtuoso] = "Top-10% of their spec in the category that ISN'T their job: a healer parsing like a DPS, a tank out-healing expectations.",
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

	-- Non-healer covering a meaningful slice of group healing (effective
	-- role: the assigned one calls a solo Mistweaver a DAMAGER).
	-- "Saving lives" requires healing OTHER people: mostly-self healing
	-- earns Unbreakable instead (split only known on Classic captures;
	-- without it the healing is assumed outward).
	local totalHeal = (fight.totals.healing or 0) + (fight.totals.absorbs or 0)
	if totalHeal > 0 then
		for guid, p in pairs(fight.players) do
			if TP.Scoring.Capabilities.EffectiveRole(p.role, p.specIconID, p.specID) ~= "HEALER" then
				local heal = (p.metrics.healing or 0) + (p.metrics.absorbs or 0)
				if heal / totalHeal >= 0.15 then
					local selfShare = (p.metrics.selfHealing and (p.metrics.healing or 0) > 0)
						and (p.metrics.selfHealing / p.metrics.healing) or nil
					if selfShare and selfShare >= 0.8 then
						grant(guid, "unbreakable")
					else
						grant(guid, "lifesaver")
					end
				end
			end
		end
	end

	-- Top damage, flavored by what died to it (no trophy for a wipe)
	local damageKing = (not fight.wipe) and topUnique(fight, "damage", 1) or nil
	if damageKing then
		grant(damageKing, fight.isBoss and "giantSlayer" or "lawnmower")
	end

	-- Healer awards: shared by every healer on the card (usually one)
	local function grantHealers(key)
		for guid, p in pairs(fight.players) do
			if TP.Scoring.Capabilities.EffectiveRole(p.role, p.specIconID, p.specID) == "HEALER" then
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

	computeCache[fight] = byGuid
	return byGuid
end
