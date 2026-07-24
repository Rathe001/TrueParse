-- /tp mock — inject a fully-loaded synthetic raid night so every card
-- surface is testable without a raid: a Garrosh kill (kill speed, lust
-- window sparkline, coverage strip, coach, externals, spike hovers) on
-- top of four wipe pulls (progression staircase, call collapse, wipe %).
-- Records are flagged mock=true: run/prev-kill stamping skips them, and
-- /tp mock clear removes them. Nothing is broadcast or synced.
local _, TP = ...

local MockFight = {}
TP.MockFight = MockFight

local BOSS = "Garrosh Hellscream"
local ZONE = "Siege of Orgrimmar"

-- one player record; over = per-fight metric overrides
local function player(guid, name, class, role, specID, ilvl, m)
	m = m or {}
	return {
		guid = guid, name = name, class = class, role = role,
		specID = specID, ilvl = ilvl, metrics = m,
	}
end

-- the shared team spike map for a fight (9-field group windows) and the
-- per-second output shape (40 cells)
local function groupMap(mineSet, whoName, whoSpell)
	-- {s, e, met, mine, amt, hitName, used, whoName, whoSpell}
	local wins = {
		{ 42, 49, true, nil, 1650000, "Whirling Corruption", nil, whoName, whoSpell },
		{ 96, 102, true, nil, 1480000, "Annihilate", nil, "Kaelstrom", "Spirit Link Totem" },
		{ 158, 164, nil, nil, 1720000, "Empowered Whirling Corruption" },
		{ 233, 241, true, nil, 1590000, "Whirling Corruption", nil, "Willowmend", "Tranquility" },
		{ 318, 325, true, nil, 1610000, "Annihilate", nil, whoName, whoSpell },
		{ 415, 423, true, nil, 1880000, "Empowered Whirling Corruption", nil, "Kaelstrom", "Healing Tide Totem" },
	}
	for i, win in ipairs(wins) do
		if mineSet and mineSet[i] then
			win[4] = true
			win[7] = mineSet[i]
		end
	end
	return wins
end

local function shape(duration, lustAt, collapseAt)
	local cells = {}
	for i = 1, 40 do
		local t = (i - 0.5) / 40 * duration
		local v = 420 + 40 * math.sin(i * 1.7) + (i % 3) * 25
		if t < 8 then
			v = v * (t / 8) -- opener ramp
		end
		if lustAt and t >= lustAt and t <= lustAt + 40 then
			v = v * 1.55 -- the burst
		end
		if collapseAt and t >= collapseAt then
			v = v * 0.06 -- everyone stopped trying
		elseif not collapseAt and t > duration * 0.85 then
			v = v * 1.25 -- execute push on the kill
		end
		cells[i] = math.floor(v * 1000)
	end
	return cells
end

-- the roster for one pull. scale stretches throughput to the duration;
-- full = the kill (all bells and whistles); wipe pulls stay lighter
local function roster(duration, full)
	local k = duration -- totals are rates x duration
	local team = groupMap
	local p = {}

	p["MOCK-t1"] = player("MOCK-t1", "Thornveil", "DRUID", "TANK", 104, 566, {
		damage = 112000 * k, healing = 30000 * k, damageTaken = 340000 * k,
		activityPct = 90, mitigationPct = 57, deaths = 0, defensives = 5,
		consumables = 2, interrupts = 1,
		spikeWindows = 4, spikeCovered = 3, defensiveUses = 5,
		spikeMap = {
			{ 40, 47, true, nil, 2350000, "Annihilate", "Savage Defense" },
			{ 118, 126, true, nil, 2600000, "Empowered Annihilate", "Survival Instincts" },
			{ 236, 243, nil, nil, 2480000, "Annihilate", nil, "Grimshade's Guardian Spirit" },
			{ 384, 391, true, nil, 2210000, "Annihilate", "Barkskin" },
		},
		groupSpikeWindows = 6, groupSpikeCovered = 5, groupCdCasts = 9,
		groupSpikeMap = team(nil),
	})
	p["MOCK-t2"] = player("MOCK-t2", "Ironvale", "WARRIOR", "TANK", 73, 563, {
		damage = 98000 * k, healing = 8000 * k, damageTaken = 300000 * k,
		activityPct = 86, mitigationPct = 44, deaths = 0, defensives = 4,
		consumables = 2, interrupts = 2,
		spikeWindows = 3, spikeCovered = 2, defensiveUses = 4,
		spikeMap = {
			{ 75, 82, true, nil, 2100000, "Annihilate", "Shield Block" },
			{ 190, 198, nil, nil, 2540000, "Empowered Annihilate", nil, "Willowmend's Ironbark" },
			{ 300, 307, true, nil, 2260000, "Annihilate", "Shield Wall" },
		},
		groupSpikeWindows = 6, groupSpikeCovered = 5, groupCdCasts = 9,
		groupSpikeMap = team(nil),
	})

	p["MOCK-h1"] = player("MOCK-h1", "Willowmend", "DRUID", "HEALER", 105, 565, {
		damage = 9000 * k, healing = 205000 * k,
		activityPct = 93, deaths = 0, defensives = 2, consumables = 2,
		overhealPct = 31, manaMinPct = 18, dispels = 6, dispelReactAvg = 1.9,
		combatRezzes = full and 1 or nil, interrupts = 0,
		groupSpikeWindows = 6, groupSpikeCovered = 5, groupCdCasts = 9,
		groupSpikeMap = team({ [4] = "Tranquility" }),
		extWindows = 7, extCovered = 4,
		profCasts = full and { [774] = 95, [48438] = 22, [33763] = 35, [18562] = 21 } or nil,
	})
	p["MOCK-h2"] = player("MOCK-h2", "Grimshade", "PRIEST", "HEALER", 257, 561, {
		damage = 7000 * k, healing = 188000 * k,
		activityPct = 89, deaths = 0, defensives = 1, consumables = 2,
		overhealPct = 44, manaMinPct = 6, dryAt = full and math.floor(duration * 0.55) or nil,
		dispels = 5, dispelReactAvg = 2.4, interrupts = 0,
		groupSpikeWindows = 6, groupSpikeCovered = 5, groupCdCasts = 9,
		groupSpikeMap = team({ [1] = "Guardian Spirit", [5] = "Guardian Spirit" }),
		extWindows = 7, extCovered = 4,
	})
	p["MOCK-h3"] = player("MOCK-h3", "Kaelstrom", "SHAMAN", "HEALER", 264, 562, {
		damage = 11000 * k, healing = 214000 * k,
		activityPct = 95, deaths = 0, defensives = 2, consumables = 2,
		overhealPct = 22, manaMinPct = 34, dispels = 3, dispelReactAvg = 1.4,
		interrupts = 1,
		groupSpikeWindows = 6, groupSpikeCovered = 5, groupCdCasts = 9,
		groupSpikeMap = team({ [2] = "Spirit Link Totem", [6] = "Healing Tide Totem" }),
		-- resto shaman: NO external in MoP — ext fields stay, the engine's
		-- spec gate must ignore them (that's part of what this tests)
		extWindows = 7, extCovered = 4,
	})

	local function dps(guid, name, class, specID, ilvl, dmgRate, m)
		m = m or {}
		m.damage = dmgRate * k
		m.healing = (m.healingRate or 2500) * k
		m.healingRate = nil
		m.damageTaken = 42000 * k
		m.groupSpikeWindows, m.groupSpikeCovered, m.groupCdCasts = 6, 5, 9
		m.groupSpikeMap = team(nil)
		p[guid] = player(guid, name, class, "DAMAGER", specID, ilvl, m)
	end
	dps("MOCK-d1", "Emberfall", "MAGE", 64, 567, 258000, {
		activityPct = 96, deaths = 0, defensives = 3, consumables = 2,
		lustCasts = 2, lustPotion = 1, interrupts = 3,
		profCasts = full and { [116] = 160, [30455] = 45, [44614] = 45, [44457] = 48 } or nil,
	})
	dps("MOCK-d2", "Vexmourn", "WARLOCK", 267, 564, 244000, {
		activityPct = 91, deaths = 0, defensives = 2,
		lustCasts = 1, lustPotion = 0, interrupts = 0,
	})
	dps("MOCK-d3", "Nightbriar", "ROGUE", 261, 560, 231000, {
		activityPct = 82, deaths = 1, defensives = 0, consumables = 1,
		lustCasts = 1, lustPotion = 0, interrupts = 3,
	})
	dps("MOCK-d4", "Farshot", "HUNTER", 254, 565, 249000, {
		activityPct = 94, deaths = 0, defensives = 2, consumables = 2,
		lustCasts = 2, lustPotion = 1, interrupts = 2,
	})
	dps("MOCK-d5", "Sunspire", "PALADIN", 70, 563, 226000, {
		activityPct = 88, deaths = 0, defensives = 1, consumables = 2,
		lustCasts = 1, lustPotion = 1, interrupts = 1,
	})

	-- the rogue's death gets the full treatment: recap hover + "CDs
	-- unused" (2 defensives sat ready at the moment of death)
	if full then
		local d = p["MOCK-d3"]
		d.deathTime = 412
		d.deathReadyDefensives = 2
		d.deathRecap = {
			{ t = 404, spell = "Whirling Corruption", amount = 210000, avoidable = true },
			{ t = 408, spell = "Melee", amount = 260000 },
			{ t = 411, spell = "Empowered Whirling Corruption", amount = 385000, avoidable = true },
		}
	end
	return p
end

local function totalsOf(players, duration)
	local t = { damage = 0, healing = 0, interrupts = 0, dispels = 0 }
	for _, pl in pairs(players) do
		local m = pl.metrics
		t.damage = t.damage + (m.damage or 0)
		t.healing = t.healing + (m.healing or 0)
		t.interrupts = t.interrupts + (m.interrupts or 0)
		t.dispels = t.dispels + (m.dispels or 0)
	end
	t.dispelTypes = { Magic = true }
	t.kickOpportunities = 12
	t.kicksLanded = t.interrupts
	t.kicksThrough = math.max(0, 12 - t.interrupts)
	-- pressed CDs: Healing Tide (owned by the shaman) stays unpressed so
	-- the assignment line has something to name
	t.raidCdsUsed = { [740] = true, [98008] = true, [47788] = true, [102342] = true }
	return t
end

local function mockFight(at, duration, over)
	local full = not over.wipe
	local players = roster(duration, full)
	local f = {
		mock = true,
		name = BOSS, zone = ZONE, isBoss = true, hadVerdict = true,
		encounterID = 1623, difficultyID = 3,
		sessionID = "MOCK", runID = "MOCK",
		duration = duration, capturedAt = at,
		players = players,
		totals = totalsOf(players, duration),
		lustAt = 14,
		shape = shape(duration, 14, over.calledWipeAt),
	}
	for key, value in pairs(over) do
		f[key] = value
	end
	return f
end

-- ===== retail night (Midnight / C_DamageMeter) =====
-- Only what retail can actually capture: meter metrics (damage, healing,
-- taken, avoidable, interrupt/dispel COUNTS) plus self-reports (activity,
-- defensives, consumables, death readiness, Aug uptime). Deliberately NO
-- spike maps, kick opportunities, coach casts, lust tracking, raid-CD
-- attribution, or fight shape — testing retail means seeing what retail
-- really shows. Manual wipe calls and boss % survive (both retail-legit).
local RBOSS = "Belo'ren, Child of Al'ar" -- uncapped Normal curve (n=921)
local RZONE = "Sunfall Spire"

local function rplayer(guid, name, class, role, specID, dmgRate, healRate, k, m)
	m = m or {}
	m.damage = dmgRate * k
	m.healing = healRate * k
	m.damageTaken = m.damageTaken or 90000 * k
	return {
		guid = guid, name = name, class = class, role = role,
		specID = specID, ilvl = 720, metrics = m,
	}
end

local function retailRoster(duration, full)
	local k = duration
	local p = {}
	local function add(...)
		local pl = rplayer(...)
		p[pl.guid] = pl
	end
	add("MOCK-t1", "Bramblehold", "PALADIN", "TANK", 66, 2100000, 480000, k,
		{ damageTaken = 340000 * k, avoidableTaken = 9000 * k,
			activityPct = 92, defensives = 6, consumables = 2, interrupts = 4, deaths = 0 })
	add("MOCK-t2", "Gravemarch", "DEATHKNIGHT", "TANK", 250, 1950000, 610000, k,
		{ damageTaken = 310000 * k, avoidableTaken = 26000 * k,
			activityPct = 88, defensives = 5, consumables = 2, interrupts = 3, deaths = 0 })
	add("MOCK-h1", "Dawnmere", "PRIEST", "HEALER", 257, 260000, 3300000, k,
		{ activityPct = 94, defensives = 2, consumables = 2, dispels = 5, deaths = 0 })
	add("MOCK-h2", "Rootsong", "DRUID", "HEALER", 105, 310000, 3100000, k,
		{ activityPct = 90, defensives = 1, consumables = 2, dispels = 7, deaths = 0 })
	add("MOCK-h3", "Tidebound", "EVOKER", "HEALER", 1468, 420000, 3500000, k,
		{ activityPct = 96, defensives = 2, consumables = 1, dispels = 3, deaths = 0 })
	-- the Aug: their "damage" is what their buffs enabled; buffUptime is
	-- the self-reported Ebon Might ratio (35% of the grade). On wipe
	-- pulls the report is withheld so the "Amplified ?" pin shows too.
	add("MOCK-s1", "Emberweave", "EVOKER", "SUPPORT", 1473, 1400000, 300000, k,
		{ activityPct = 91, defensives = 1, consumables = 2, deaths = 0,
			buffUptime = full and 0.68 or nil })
	add("MOCK-d1", "Starveil", "MAGE", "DAMAGER", 63, 4300000, 90000, k,
		{ avoidableTaken = 4000 * k, activityPct = 97, defensives = 3, consumables = 2,
			interrupts = 2, deaths = 0 })
	add("MOCK-d2", "Duskfang", "ROGUE", "DAMAGER", 259, 4100000, 80000, k,
		{ avoidableTaken = 48000 * k, activityPct = 84, defensives = 0, consumables = 1,
			interrupts = 5, deaths = full and 1 or 0 })
	add("MOCK-d3", "Stormsower", "SHAMAN", "DAMAGER", 262, 3900000, 240000, k,
		{ avoidableTaken = 7000 * k, activityPct = 93, defensives = 2, consumables = 2,
			interrupts = 1, dispels = 2, deaths = 0 })
	add("MOCK-d4", "Ashwhisper", "WARLOCK", "DAMAGER", 267, 4450000, 110000, k,
		{ avoidableTaken = 11000 * k, activityPct = 95, defensives = 2, consumables = 2,
			interrupts = 0, deaths = 0 })
	add("MOCK-d5", "Wildmark", "HUNTER", "DAMAGER", 253, 4000000, 70000, k,
		{ avoidableTaken = 6000 * k, activityPct = 89, defensives = 1, consumables = 2,
			interrupts = 2, deaths = 0 })
	add("MOCK-d6", "Moonscribe", "DRUID", "DAMAGER", 102, 3750000, 260000, k,
		{ avoidableTaken = 9000 * k, activityPct = 87, defensives = 1,
			interrupts = 0, deaths = 0 }) -- no consumables report: not running TrueParse
	if full then
		local d = p["MOCK-d2"]
		d.deathTime = math.floor(duration * 0.8)
		d.deathReadyDefensives = 2
	end
	return p
end

local function retailTotals(players)
	local t = { damage = 0, healing = 0, interrupts = 0, dispels = 0 }
	for _, pl in pairs(players) do
		local m = pl.metrics
		t.damage = t.damage + (m.damage or 0)
		t.healing = t.healing + (m.healing or 0)
		t.interrupts = t.interrupts + (m.interrupts or 0)
		t.dispels = t.dispels + (m.dispels or 0)
	end
	t.dispelTypes = { Magic = true }
	return t
end

local function retailFight(at, duration, over)
	local full = not over.wipe
	local players = retailRoster(duration, full)
	local f = {
		mock = true,
		name = RBOSS, zone = RZONE, isBoss = true, hadVerdict = true,
		encounterID = 3001, difficultyID = 14,
		sessionID = "MOCK", runID = "MOCK",
		duration = duration, capturedAt = at,
		players = players,
		totals = retailTotals(players),
	}
	for key, value in pairs(over) do
		f[key] = value
	end
	return f
end

function MockFight.BuildRetail(now)
	return {
		retailFight(now - 5400, 55, { wipe = true, bossPct = 64 }),
		retailFight(now - 4700, 88, { wipe = true, bossPct = 31 }),
		retailFight(now - 3900, 104, { wipe = true, bossPct = 12, calledWipeAt = 92, wipeCalledBy = "Bramblehold" }),
		retailFight(now - 3100, 122, { prevKillDuration = 141, prevKillAt = now - 7 * 86400 }),
	}
end

-- oldest first; pure (headless tests validate the whole night scores)
function MockFight.Build(now)
	return {
		mockFight(now - 5400, 190, { wipe = true, bossPct = 72 }),
		mockFight(now - 4700, 300, { wipe = true, bossPct = 43 }),
		mockFight(now - 3900, 465, { wipe = true, bossPct = 18, calledWipeAt = 420 }),
		mockFight(now - 3100, 380, { wipe = true, bossPct = 27, calledWipeAt = 330, wipeCalledBy = "Thornveil" }),
		mockFight(now - 2400, 499, { prevKillDuration = 533, prevKillAt = now - 7 * 86400 }),
	}
end

function MockFight:Inject()
	local FH = TP.FightHistory
	if not (FH and FH.fights) then
		TP.Addon:Print("Fight history isn't ready yet.")
		return
	end
	self:Clear(true)
	-- each client gets ITS OWN shape of night: injecting CLEU-only
	-- surfaces on retail would show cards retail can never produce
	local retail = TP.Compat and TP.Compat.IS_RETAIL
	local pulls = retail and MockFight.BuildRetail(time()) or MockFight.Build(time())
	for _, f in ipairs(pulls) do
		-- inserted at index 1 each time = newest ends on top
		table.insert(FH.fights, 1, f)
	end
	FH:Persist()
	TP.MeterWindow:Refresh(true)
	TP.Addon:Print(retail
		and "Injected a mock retail night: 3 Belo'ren wipes + a kill (12 players, meter + self-report surfaces incl. the Aug). '/tp mock clear' removes it."
		or "Injected a mock raid night: 4 Garrosh wipes + a kill (10 players, every card surface loaded). Click the group row for the graphs; '/tp mock clear' removes it.")
end

function MockFight:Clear(silent)
	local FH = TP.FightHistory
	if not (FH and FH.fights) then
		return
	end
	local removed = 0
	for i = #FH.fights, 1, -1 do
		if FH.fights[i].mock then
			table.remove(FH.fights, i)
			removed = removed + 1
		end
	end
	if removed > 0 then
		FH:Persist()
		if TP.MeterWindow and TP.MeterWindow.Refresh then
			TP.MeterWindow:Refresh(true)
		end
	end
	if not silent then
		TP.Addon:Print(removed > 0 and ("Cleared %d mock fights."):format(removed)
			or "No mock fights to clear.")
	end
end
