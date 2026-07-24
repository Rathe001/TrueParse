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

-- Coverage math shared with GroupAverages: judged windows are capped at
-- demonstrated capacity (uses+1); zero uses judges everything
local function coverageOf(windows, covered, uses)
	local judged = windows
	if (uses or 0) > 0 then
		judged = math.min(windows, math.max(uses, covered) + 1)
	end
	return covered, judged
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
			-- bracket colors are for PARSES only: a group-relative share
			-- wears neutral, not purple
			out[#out].raw = not (b.pctile or b.absolute) or nil
		end
	end

	-- 2) activity (everyone reporting it)
	if m.activityPct then
		out[#out + 1] = barRow("activity", ICONS.activity, "Active", m.activityPct, ad.activity)
		out[#out].raw = true -- a raw %, judged by anchors, not a parse
	end

	-- 3) mitigation (tanks)
	if role == "TANK" and m.mitigationPct then
		out[#out + 1] = barRow("mitigation", ICONS.mitigation, "Mitigation up", m.mitigationPct, ad.mitigation)
		out[#out].raw = true
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
		local c, judged = coverageOf(windows, covered, uses)
		-- labels must survive an ~86px column: verdicts stay short.
		-- ONE denominator everywhere (Josh 2026-07-26: mixed counts
		-- created dissonance): bar fill AND the count use judged windows;
		-- the raw total lives in the tooltip detail.
		local cdLabel = c >= judged and "Spikes met" or "Uncovered"
		local row = barRow("cdTiming", icon, cdLabel,
			judged > 0 and c / judged * 100 or 0, ad.cdTiming)
		row.num = ("%d/%d"):format(c, judged)
		if windows > judged then
			row.detail = ("%d spikes this fight; your cooldowns could reach %d."):format(windows, judged)
		end
		out[#out + 1] = row
	end

	-- 5) kicks: landed = good squares, got-through = bad (they hit
	-- somebody); only when the fight offered opportunity data. Healers
	-- are bonus-only, so they only get the row when they landed some.
	local bi = result.breakdown.interrupts
	if bi and bi.applicable and bi.opportunities and bi.opportunities > 0
		and (role ~= "HEALER" or (bi.value or 0) > 0) then
		local landed = bi.value or 0
		local row = barRow("interrupts", ICONS.interrupts, "Kicks",
			landed / bi.opportunities * 100, ad.kicks)
		row.num = ("%d/%d"):format(landed, bi.opportunities)
		out[#out + 1] = row
	end

	-- 6) dispels: share bar (volleys, not per-event quality)
	local bd = result.breakdown.dispels
	if bd and bd.applicable and (bd.value or 0) > 0 then
		out[#out + 1] = barRow("dispels", ICONS.dispels, "Dispels", bd.normalized or 0, ad.dispels)
		out[#out].count = bd.value
		out[#out].raw = true -- share score, not a percentile
	end

	-- 7-9) everything WITHOUT a visualization rolls into one "Other" row
	-- (Josh 2026-07-24): the net points ride the row, the itemized
	-- breakdown lives in its tooltip. Collect first, emit after.
	local others = {}
	local function other(label, pts, count)
		if pts and math.abs(pts) < 0.5 then
			pts = nil
		end
		others[#others + 1] = { label = label, points = pts, count = count }
	end
	if (m.defensives or 0) > 0 then
		other(("Defensives x%d"):format(m.defensives), ad.defensives)
	end
	if (m.combatRezzes or 0) > 0 then
		other(m.combatRezzes > 1 and ("Combat rez x%d"):format(m.combatRezzes)
			or "Combat rez", ad.rez)
	end
	if role == "DAMAGER" and m.lustCasts ~= nil then
		local aligned = m.lustCasts > 0
		other(aligned and ((m.lustPotion or 0) > 0 and "Lust + potion" or "Lust aligned")
			or ((ad.lust or 0) == 0 and "Lust excused" or "Lust missed"), ad.lust)
	end
	if (ad.avoidable or 0) > 0 then
		other("Stayed clean", ad.avoidable)
	elseif (pd.avoidable or 0) > 0 then
		other("Stood in bad", -pd.avoidable)
	end

	-- 9b) every remaining scored adjustment gets a verdict glyph — the
	-- card must account for every point (nothing silently vanishes just
	-- because it has no dedicated mark kind)
	local REMAINDER = {
		{ key = "overheal", up = "Lean healing", down = "Overhealed", icon = ICONS.healing },
		{ key = "overkill", up = nil, down = "Overkill heavy", icon = ICONS.damage },
		{ key = "manaDry", up = nil, down = "Mana ran dry", icon = ICONS.activity },
		{ key = "prepared", up = "Flask + food", down = nil, icon = ICONS.buffUptime },
		{ key = "buffs", up = nil, down = "Buff missing", icon = ICONS.buffUptime },
		{ key = "pull", up = nil, down = "Pulled early", icon = ICONS.avoidable },
		{ key = "aggro", up = nil, down = "Ripped aggro", icon = ICONS.avoidable },
		{ key = "aggroLoss", up = nil, down = "Lost aggro", icon = ICONS.avoidable },
		{ key = "kicks", up = "Kicked anyway", down = nil, icon = ICONS.interrupts, healerOnly = true },
	}
	local shown = {}
	for _, row in ipairs(out) do
		shown[row.key] = true
	end
	shown.kicks = shown.interrupts
	for _, def in ipairs(REMAINDER) do
		local v = ad[def.key] or 0
		if v ~= 0 and not shown[def.key] and (not def.healerOnly or role == "HEALER") then
			local label = v > 0 and def.up or v < 0 and def.down
			if label then
				other(label, v)
			end
		end
	end
	if #others > 0 then
		local net = 0
		for _, it in ipairs(others) do
			net = net + (it.points or 0)
		end
		out[#out + 1] = { key = "other", kind = "other", icon = ICON .. "INV_Misc_Note_01",
			label = "Other", points = net, items = others }
	end

	-- 10) deaths: red pips, capped at 5 shown (the count rides the row)
	local deaths = m.deaths or 0
	if deaths > 0 then
		local dLabel = "Died"
		if (player and player.deathReadyDefensives or 0) >= 2 and (ad.deathReady or 0) < 0 then
			dLabel = "CDs unused"
		elseif (ad.deathNoDefensives or 0) < 0 then
			dLabel = "No defensive"
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
			-- coverage bars tick against the other players holding the
			-- same job (tanks vs tanks, healers share team coverage)
			local w, c, u
			if r.role == "TANK" and (m.spikeWindows or 0) >= 2 then
				w, c, u = m.spikeWindows, m.spikeCovered or 0, m.defensiveUses
			elseif r.role == "HEALER" and (m.groupSpikeWindows or 0) >= 2 then
				w, c, u = m.groupSpikeWindows, m.groupSpikeCovered or 0, m.groupCdCasts
			end
			if w then
				local cov, judged = coverageOf(w, c, u)
				if judged > 0 then
					add("cdTiming", cov / judged * 100)
				end
			end
		end
		local bi = r.breakdown.interrupts
		if bi and bi.applicable and bi.opportunities and bi.opportunities > 0 then
			add("interrupts", (bi.value or 0) / bi.opportunities * 100)
		end
	end
	local avg = {}
	for key, sum in pairs(sums) do
		avg[key] = sum / counts[key]
	end
	return avg
end
