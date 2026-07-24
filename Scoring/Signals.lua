-- The Signal Column model (2026-07-26 redesign, Josh-approved mockups):
-- turns one engine result + fight record into an ordered list of
-- MICRO-ROWS for the breakdown card. Each row is one signal in one of
-- four visual kinds — the card renders these with zero sentences:
--   bar    : continuous 0-100, tinted by its own WCL bracket
--   squares: per-event marks (good/bad/ghost — ghost = beyond capacity)
--   pips   : discrete danger counts (deaths), red
--   glyph  : binary verdicts (lust alignment, clean-of-avoidable)
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Signals = {}
TP.Scoring.Signals = Signals

local ICON = "Interface\\Icons\\"
local ICONS = {
	damage = ICON .. "Ability_DualWield",
	healing = ICON .. "Spell_Nature_HealingTouch",
	damageTaken = ICON .. "INV_Shield_06",
	activity = ICON .. "Ability_Hunter_Readiness",
	cdTimingHealer = ICON .. "Spell_Nature_Tranquility",
	cdTimingTank = ICON .. "Ability_Warrior_ShieldWall",
	interrupts = ICON .. "Ability_Kick",
	dispels = ICON .. "Spell_Holy_DispelMagic",
	defensives = ICON .. "Spell_Holy_PowerWordShield",
	rez = ICON .. "Spell_Nature_Reincarnation",
	deaths = ICON .. "Ability_Rogue_FeignDeath",
	lust = ICON .. "Spell_Nature_BloodLust",
	mitigation = ICON .. "Ability_Defend",
	avoidable = ICON .. "Spell_Fire_SelfDestruct",
	buffUptime = ICON .. "Spell_Nature_UnyieldingStamina",
}

-- Verdict labels (Josh 2026-07-26: marks alone hide findings like
-- "missed the Bloodlust window" — users must never have to compute the
-- verdict). Rules: state WHAT HAPPENED in <= 4 words, muted ink,
-- never an explanation — those stay in tooltips.
local function barRow(key, icon, label, value, points)
	return { key = key, kind = "bar", icon = icon, label = label,
		value = math.max(0, math.min(99, value)), points = points }
end

-- squares: good = well-used events, bad = missed/failed events,
-- ghost = events beyond demonstrated capacity (never judged)
local function squareRow(key, icon, label, good, bad, ghost, points)
	return { key = key, kind = "squares", icon = icon, label = label,
		good = good, bad = bad, ghost = ghost or 0, points = points }
end

-- One player's ordered signal list. result = engine row; player = the
-- fight's player record (metrics live here); fight for context gates.
function Signals.ForResult(result, fight, player)
	local out = {}
	local m = (player and player.metrics) or {}
	local ad = result.adjustDetail or {}
	local pd = result.penaltyDetail or {}
	local role = result.role

	-- 1) throughput bars, primary metric first (percentile when curve-
	-- backed, normalized otherwise — both are 0-100 by construction)
	local order = role == "HEALER" and { "healing", "damage" }
		or role == "TANK" and { "damage", "damageTaken", "healing" }
		or { "damage", "healing" }
	for _, key in ipairs(order) do
		local b = result.breakdown[key]
		if b and b.applicable and not b.lowDemand then
			local label = key == "damageTaken" and "Soaking"
				or key:sub(1, 1):upper() .. key:sub(2)
			out[#out + 1] = barRow(key, ICONS[key], label, b.pctile or b.normalized or 0, nil)
			out[#out].b = b -- the tooltip's gauge needs the full breakdown
		end
	end

	-- 2) activity (everyone reporting it)
	if m.activityPct then
		out[#out + 1] = barRow("activity", ICONS.activity, "Active", m.activityPct, ad.activity)
	end

	-- 3) mitigation (tanks)
	if role == "TANK" and m.mitigationPct then
		out[#out + 1] = barRow("mitigation", ICONS.mitigation, "Mitigation up", m.mitigationPct, ad.mitigation)
	end

	-- 4) cooldown timing as per-event squares with the availability cap
	-- drawn: judged windows get good/bad squares, the rest are ghosts
	local windows, covered, uses, icon
	if role == "TANK" and (m.spikeWindows or 0) >= 2 then
		windows, covered, uses, icon = m.spikeWindows, m.spikeCovered or 0, m.defensiveUses, ICONS.cdTimingTank
	elseif role == "HEALER" and (m.groupSpikeWindows or 0) >= 2 then
		windows, covered, uses, icon = m.groupSpikeWindows, m.groupSpikeCovered or 0, m.groupCdCasts, ICONS.cdTimingHealer
	end
	if windows then
		local judged = windows
		if (uses or 0) > 0 then
			judged = math.min(windows, math.max(uses, covered) + 1)
		end
		local cdLabel = covered >= judged and "Spikes covered" or "Spikes uncovered"
		out[#out + 1] = squareRow("cdTiming", icon, cdLabel,
			covered, math.max(0, judged - covered), windows - judged, ad.cdTiming)
	end

	-- 5) kicks: landed = good squares, got-through = bad (they hit
	-- somebody); only when the fight offered opportunity data. Healers
	-- are bonus-only, so they only get the row when they landed some.
	local bi = result.breakdown.interrupts
	if bi and bi.applicable and bi.opportunities and bi.opportunities > 0
		and (role ~= "HEALER" or (bi.value or 0) > 0) then
		local landed = bi.value or 0
		out[#out + 1] = squareRow("interrupts", ICONS.interrupts, "Kicks",
			landed, math.max(0, (bi.opportunities or 0) - (bi.landed or 0)), 0, ad.kicks)
		out[#out].capNote = bi.opportunities
	end

	-- 6) dispels: share bar (volleys, not per-event quality)
	local bd = result.breakdown.dispels
	if bd and bd.applicable and (bd.value or 0) > 0 then
		out[#out + 1] = barRow("dispels", ICONS.dispels, "Dispels", bd.normalized or 0, ad.dispels)
		out[#out].count = bd.value
	end

	-- 7) defensives + rez: plain good-square counts
	if (m.defensives or 0) > 0 then
		out[#out + 1] = squareRow("defensives", ICONS.defensives, "Defensives", m.defensives, 0, 0, ad.defensives)
	end
	if (m.combatRezzes or 0) > 0 then
		out[#out + 1] = squareRow("rez", ICONS.rez, "Combat rez", m.combatRezzes, 0, 0, ad.rez)
	end

	-- 8) lust alignment glyph (DPS with an observed window)
	if role == "DAMAGER" and m.lustCasts ~= nil then
		local aligned = m.lustCasts > 0
		local lustLabel = aligned
			and ((m.lustPotion or 0) > 0 and "Lust + potion" or "Lust aligned")
			or ((ad.lust or 0) == 0 and "Lust excused" or "Lust missed")
		out[#out + 1] = { key = "lust", kind = "glyph", icon = ICONS.lust,
			label = lustLabel, good = aligned, points = ad.lust }
	end

	-- 9) avoidable: a glyph when it moved the score either way
	if (ad.avoidable or 0) > 0 then
		out[#out + 1] = { key = "avoidable", kind = "glyph", icon = ICONS.avoidable,
			label = "Stayed clean", good = true, points = ad.avoidable }
	elseif (pd.avoidable or 0) > 0 then
		out[#out + 1] = { key = "avoidable", kind = "glyph", icon = ICONS.avoidable,
			label = "Stood in bad", good = false, points = -pd.avoidable }
	end

	-- 10) deaths: red pips, capped at 5 shown (the count rides the row)
	local deaths = m.deaths or 0
	if deaths > 0 then
		local dLabel = "Died"
		if (player and player.deathReadyDefensives or 0) >= 2 and (ad.deathReady or 0) < 0 then
			dLabel = "Died, CDs ready"
		elseif (ad.deathNoDefensives or 0) < 0 then
			dLabel = "Died, no defensive"
		end
		out[#out + 1] = { key = "deaths", kind = "pips", icon = ICONS.deaths,
			label = dLabel, count = deaths,
			points = -(pd.deaths or 0) + (ad.deathReady or 0) + (ad.deathNoDefensives or 0) }
	end

	return out
end

-- Group averages per bar key, for the comparison ticks: [key] = 0-100.
-- results = the whole fight's engine rows; fight supplies metrics.
function Signals.GroupAverages(results, fight)
	local sums, counts = {}, {}
	local function add(key, v)
		if v then
			sums[key] = (sums[key] or 0) + v
			counts[key] = (counts[key] or 0) + 1
		end
	end
	for _, r in ipairs(results or {}) do
		for _, key in ipairs({ "damage", "healing", "damageTaken", "dispels" }) do
			local b = r.breakdown[key]
			if b and b.applicable and not b.lowDemand then
				add(key, b.pctile or b.normalized)
			end
		end
		local p = fight and fight.players and fight.players[r.guid]
		local m = p and p.metrics
		if m then
			add("activity", m.activityPct)
			add("mitigation", m.mitigationPct)
		end
	end
	local avg = {}
	for key, sum in pairs(sums) do
		avg[key] = sum / counts[key]
	end
	return avg
end
