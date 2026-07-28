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
	avoidable = ICON .. "Spell_Fire_SelfDestruct",
	-- NB: Blizzard's file really is spelled "Unyeilding" — the correctly
	-- spelled path renders as a blank square
	buffUptime = ICON .. "Spell_Nature_UnyeildingStamina",
	prescience = ICON .. "Ability_Evoker_Prescience",
	consumables = ICON .. "INV_Potion_92",
	healthstone = ICON .. "INV_Stone_04",
	speed = ICON .. "Ability_Rogue_Sprint",
}
Signals.ICONS = ICONS -- the panel constructs a few group rows itself

-- Verdict labels (Josh 2026-07-26: marks alone hide findings like
-- "missed the Bloodlust window" — users must never have to compute the
-- verdict). Rules: state WHAT HAPPENED in <= 4 words, muted ink,
-- never an explanation — those stay in tooltips.
local function barRow(key, icon, label, value, points)
	return { key = key, kind = "bar", icon = icon, label = label,
		value = math.max(0, math.min(99, value)), points = points }
end

-- Raw-percentage metrics whose scoring anchors ARE population quantiles
-- (activity 70/89 = the real p25/p75; top parses ~98) can wear bracket
-- colors honestly by mapping through those quantiles: 97% activity ≈
-- p95 (orange), 68% ≈ p24 (grey — bottom quartile, not danger red).
-- Josh 2026-07-24: "a 97% seems almost perfect / should 68 be red?"
local function anchorTier(pct, lo, hi, top)
	if pct <= lo then
		return math.max(0, pct / lo * 25)
	elseif pct <= hi then
		return 25 + (pct - lo) / (hi - lo) * 50
	elseif pct <= top then
		return 75 + (pct - hi) / (top - hi) * 20
	end
	return math.min(99, 95 + (pct - top))
end

-- The extrapolated tanking stat (Josh 2026-07-24): one number from four
-- honest ingredients, equal-weighted across whichever the record has —
--   soak    : share of the group's damage taken vs the expected tank share
--   avoided : dodge/parry/miss rate against attacks that judged it
--   shielded: blocked + external absorbs, as a share of what WOULD have hit
--   recovery: self-healing + own absorbs (both effective), vs damage taken
-- Needs 3+ ingredients (legacy records fall back to the plain Soaking
-- share bar). ANCHORS ARE PROVISIONAL until field data recalibrates
-- them — same road activity's anchors traveled.
-- Pure composite math, exported so scripts/analyze-history.lua can rank
-- field captures with EXACTLY the shipped formula when emitting the
-- per-spec anchors. Returns value, itemized parts — nil under 3
-- ingredients (legacy records).
function Signals.TankingComposite(m, soakNormalized)
	local taken = m.damageTaken or 0
	local sum, n, parts = 0, 0, {}
	if soakNormalized then
		sum = sum + math.min(100, soakNormalized)
		n = n + 1
		parts[#parts + 1] = ("soak %.0f%%"):format(soakNormalized)
	end
	local swings = (m.swingsLanded or 0) + (m.swingsAvoided or 0)
	if swings >= 20 then
		local avoid = (m.swingsAvoided or 0) / swings * 100
		sum = sum + avoid
		n = n + 1
		parts[#parts + 1] = ("avoided %.0f%% of %d attacks"):format(avoid, swings)
	end
	-- active-mitigation uptime joined the composite (Josh 2026-07-25:
	-- its own row double-dipped the survival story)
	if m.mitigationPct then
		sum = sum + m.mitigationPct
		n = n + 1
		parts[#parts + 1] = ("mitigation up %d%% of the fight"):format(m.mitigationPct)
	end
	local selfAbs = m.selfAbsorbs or 0
	local shielded = (m.blockedTaken or 0) + math.max(0, (m.absorbedTaken or 0) - selfAbs)
	if taken > 0 and shielded > 0 then
		local mitPct = shielded / (taken + shielded) * 100
		sum = sum + mitPct
		n = n + 1
		parts[#parts + 1] = ("%s blocked+shielded (%.0f%%)"):format(TP.FormatNumber(shielded), mitPct)
	end
	-- Brewmaster purifies are self-sufficiency too (Josh 2026-07-24);
	-- the amount is tick-x-10 estimated, so it wears the ~ estimate mark
	local purified = m.staggerPurified or 0
	local rec = (m.selfHealing or 0) + selfAbs + purified
	if taken > 0 and rec > 0 then
		-- recovery is judged against WOULD-HAVE-TAKEN damage: avoided
		-- swings priced at the average landed hit join the denominator,
		-- else high-avoidance tanks got credited twice (dodging made the
		-- same self-healing read as a bigger share — Josh 2026-07-24)
		local avgSwing = (m.swingsLanded or 0) > 0
			and (m.swingDamageTaken or 0) / m.swingsLanded or 0
		local wouldHave = taken + avgSwing * (m.swingsAvoided or 0)
		local recPct = math.min(100, rec / wouldHave * 100)
		sum = sum + recPct
		n = n + 1
		parts[#parts + 1] = ("%s self-recovered (%.0f%%)"):format(TP.FormatNumber(rec), recPct)
		if purified > 0 then
			parts[#parts + 1] = ("~%s of that was stagger purified"):format(TP.FormatNumber(purified))
		end
	end
	if n < 3 then
		return nil
	end
	return sum / n, parts
end

-- The Mitigation row reads breakdown.mitigation: the SCORE is active-
-- mitigation uptime as a percentile vs the spec's crawled WCL field (Josh
-- 2026-07-26 - the tank's primary metric, WCL-relative not arbitrary). The
-- tip leads with that headline, then shows the rest of the survival story
-- as context (soak/avoid/block aren't scored, just shown).
local function mitigationRow(m, b, specID)
	if not (b and b.applicable) then
		return nil -- metric not in play at all (non-tank, or no anchors)
	end
	local row = barRow("mitigation", ICONS.damageTaken, "Mitigation", b.normalized or 0, nil)
	row.b = b
	row.base = true -- the primary tank metric: part of the raw score
	-- Wears the bracket gauge like damage and healing do (Josh 2026-07-28:
	-- "is there a reason mitigation doesn't have the WCL colour bar?"). It
	-- used to be flagged `raw`, which routes to flat verdict colours - that
	-- was right when the anchors were a hand-picked { 30, 55, 75 }, but they
	-- are crawled WCL quantiles now, so the score IS a population percentile
	-- and has every right to the same gauge.
	row.tier = math.max(0, math.min(99, b.normalized or 0))
	row.tipTitle = "Mitigation"
	local up = b.value or 0
	local anc = b.anchors
	local lines = {}
	if b.noInput then
		-- nobody reported uptime for this tank: the 50 is an assumption, so
		-- it must not wear a percentile gauge or print a number it never
		-- measured (same "?" treatment as an unreported Aug)
		row.num = "?"
		row.tier = nil
		row.raw = true
		lines[#lines + 1] = "Mitigation not measured - assumed average."
		lines[#lines + 1] = "This tank isn't running TrueParse, so their active"
			.. " mitigation uptime is unknown and scored as middle-of-the-pack."
	else
		lines[#lines + 1] = anc
			and ("Mitigation up %.0f%%; the spec median holds %.0f%%"):format(up, anc[2])
			or ("Mitigation up %.0f%% of the fight"):format(up)
	end
	-- context: the rest of the survival story (shown, not scored)
	local _, parts = Signals.TankingComposite(m, nil)
	for _, pt in ipairs(parts or {}) do
		if not pt:find("mitigation up") then -- the headline already has it
			lines[#lines + 1] = pt
		end
	end
	row.tipText = table.concat(lines, "\n")
	return row
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
	-- damage and healing stay adjacent everywhere (they're the WCL base
	-- pair — Josh 2026-07-24); a tank's Tanking/Soaking follows them
	local order = role == "HEALER" and { "healing", "damage" }
		or { "damage", "healing" }
	local function emitThroughput(key)
		local b = result.breakdown[key]
		if b and b.applicable and not b.lowDemand then
			local label = key == "damageTaken" and "Soaking"
				or key:sub(1, 1):upper() .. key:sub(2)
			-- an Aug's "damage" is what their buffs enabled, not output
			if key == "damage" and role == "SUPPORT" and (b.attribution or b.noInput) then
				label = "Amplified"
			end
			-- (the Off-healing split retired 2026-07-25: a tank's
			-- Healing is the plain WCL parse again — the Tanking
			-- metric reads mitigation uptime directly)
			out[#out + 1] = barRow(key, ICONS[key], label, b.pctile or b.normalized or 0, nil)
			out[#out].b = b -- the tooltip's gauge needs the full breakdown
			out[#out].base = true -- makes the raw score; Raw mode keeps these
			-- bracket colors are for PARSES only: a group-relative share
			-- wears neutral, not purple
			out[#out].raw = not (b.pctile or b.absolute) or nil
			if b.noInput then
				-- an Aug with no Ebon Might report: the 50 is a PIN, not
				-- a measurement — "?" keeps it from reading as mid-pack
				out[#out].num = "?"
			end
		elseif b and b.applicable and b.lowDemand and key == "healing" and role == "HEALER" then
			-- a healer's primary metric can't just vanish: the base sits
			-- pinned at 75 because there was nothing to heal — say so
			local row = { key = key, kind = "glyph", icon = ICONS[key],
				label = "Little to heal", good = true }
			row.b = b -- the metric tooltip explains the neutral scoring
			row.base = true
			out[#out + 1] = row
		end
	end
	-- SUPPORT's signature metric LEADS (Josh 2026-07-25: it carries half
	-- the grade, so it belongs on top). Prescience cadence replaced the Ebon
	-- Might metric (2026-07-26): Ebon Might already shows through Amplified.
	local pr = result.breakdown.prescience
	if role == "SUPPORT" and pr and pr.applicable then
		local row = barRow("prescience", ICONS.prescience, "Prescience",
			pr.normalized or 0, nil)
		row.b = pr
		row.base = true -- half the Aug's grade: part of the raw score
		row.raw = true -- scored vs its own cadence anchor, not a population
		out[#out + 1] = row
	end

	for _, key in ipairs(order) do
		emitThroughput(key)
	end

	-- 2) activity: a chip like the other counted verdicts (Josh
	-- 2026-07-25 — the gauge moved out; "Active 89% +4" says it all)
	if m.activityPct then
		local row = barRow("activity", ICONS.activity, "Active", m.activityPct, ad.activity)
		row.num = m.activityPct .. "%"
		out[#out + 1] = row
	end

	-- 2b) the Mitigation gauge (active-mitigation uptime percentile vs the
	-- spec's WCL field): the tank's primary metric, closes the gauge zone
	if role == "TANK" then
		local trow = mitigationRow(m, result.breakdown.mitigation, player and player.specID)
		if trow then
			out[#out + 1] = trow
		end
	end

	-- 4) cooldown timing as per-event squares with the availability cap
	-- drawn: judged windows get good/bad squares, the rest are ghosts
	local windows, covered, uses, icon, extPart
	if role == "TANK" and (m.spikeWindows or 0) >= 2 then
		windows, covered, uses, icon = m.spikeWindows, m.spikeCovered or 0, m.defensiveUses, ICONS.cdTimingTank
	elseif role == "HEALER" then
		-- same pool the engine scores: group spikes (raid CDs) + tank
		-- spikes (single-target externals, specs that own one only)
		local extW, extC = 0, 0
		local extName = TP.EXTERNALS_BY_SPEC and player and player.specID
			and TP.EXTERNALS_BY_SPEC[player.specID]
		if extName then
			extW, extC = m.extWindows or 0, m.extCovered or 0
		end
		if (m.groupSpikeWindows or 0) + extW >= 2 then
			windows = (m.groupSpikeWindows or 0) + extW
			covered = (m.groupSpikeCovered or 0) + extC
			uses = m.groupCdCasts
			icon = ICONS.cdTimingHealer
			if extW > 0 then
				extPart = ("%d of the pool are tank spikes for your %s (%d covered)."):format(
					extW, extName, extC)
			end
		end
	end
	if windows then
		local c, judged = coverageOf(windows, covered, uses)
		-- ONE denominator everywhere, and the label names the COUNTING
		-- DIRECTION ("Uncovered 2/4" read as 2-of-4-missed — Josh
		-- 2026-07-24): "Covered 2/4" is unambiguous, color carries the
		-- verdict. The raw spike total lives in the tooltip detail.
		local row = barRow("cdTiming", icon, "Covered",
			judged > 0 and c / judged * 100 or 0, ad.cdTiming)
		row.num = ("%d/%d"):format(c, judged)
		if windows > judged then
			row.detail = ("%d spikes this fight; your cooldowns could reach %d."):format(windows, judged)
		end
		if extPart then
			row.detail = row.detail and (row.detail .. " " .. extPart) or extPart
		end
		out[#out + 1] = row
	end

	-- 5) kicks: landed = good squares, got-through = bad (they hit
	-- somebody); only when the fight offered opportunity data. Healers
	-- are bonus-only, so they only get the row when they landed some.
	local bi = result.breakdown.interrupts
	if bi and bi.applicable and (role ~= "HEALER" or (bi.value or 0) > 0) then
		if bi.opportunities and bi.opportunities > 0 then
			local landed = bi.value or 0
			local row = barRow("interrupts", ICONS.interrupts, "Kicks",
				landed / bi.opportunities * 100, ad.kicks)
			row.num = ("%d/%d"):format(landed, bi.opportunities)
			row.b = bi -- numeric tooltip ("Kicked N · group got L of O")
			out[#out + 1] = row
		elseif (bi.value or 0) > 0 then
			-- no opportunity data (retail hides enemy casts; Classic still
			-- learning the content): share bar with the landed count, like
			-- dispels — the old bullets showed this and the redesign lost it
			local row = barRow("interrupts", ICONS.interrupts, "Kicks",
				bi.normalized or 0, ad.kicks)
			row.num = tostring(bi.value)
			row.raw = true
			row.b = bi
			out[#out + 1] = row
		end
	end

	-- 6) dispels: share bar (volleys, not per-event quality)
	local bd = result.breakdown.dispels
	if bd and bd.applicable and (bd.value or 0) > 0 then
		out[#out + 1] = barRow("dispels", ICONS.dispels, "Dispels", bd.normalized or 0, ad.dispels)
		out[#out].num = tostring(bd.value) -- the count, not the share score
		out[#out].b = bd -- numeric tooltip (dispelled-of-group + reaction avg)
		out[#out].raw = true -- share score, not a percentile
	end

	-- 7-9) everything WITHOUT a visualization gets its OWN markless row
	-- (Josh 2026-07-25: the Other rollup hid the per-item hovers — every
	-- row hoverable, every point accounted for, in place)
	local function verdict(key, icon, label, pts, count)
		if pts and math.abs(pts) < 0.5 then
			pts = nil
		end
		out[#out + 1] = { key = key, kind = "glyph", icon = icon,
			label = label, points = pts, count = count, good = true }
	end
	if (m.defensives or 0) > 0 then
		verdict("defensives", ICONS.defensives, "Defensives", ad.defensives, m.defensives)
	end
	if (m.combatRezzes or 0) > 0 then
		verdict("rez", ICONS.rez, "Combat rez", ad.rez,
			m.combatRezzes > 1 and m.combatRezzes or nil)
	end
	if role == "DAMAGER" and m.lustCasts ~= nil then
		local aligned = m.lustCasts > 0
		verdict("lust", ICONS.lust,
			aligned and ((m.lustPotion or 0) > 0 and "Lust + potion" or "Lust aligned")
			or ((ad.lust or 0) == 0 and "Lust excused" or "Lust missed"), ad.lust)
	end
	if (ad.avoidable or 0) > 0 then
		verdict("avoidable", ICONS.avoidable, "Stayed clean", ad.avoidable)
	elseif (pd.avoidable or 0) > 0 then
		verdict("avoidable", ICONS.avoidable, "Stood in bad", -pd.avoidable)
	end
	-- prepared now scores BOTH ways (Josh 2026-07-26: -1 per missing
	-- flask/food), so the REMAINDER's "prepared" chip carries the whole
	-- story - the old unscored "No flask/food" info chip is gone.

	-- 9b) every remaining scored adjustment gets a verdict glyph — the
	-- card must account for every point (nothing silently vanishes just
	-- because it has no dedicated mark kind)
	local REMAINDER = {
		{ key = "overheal", up = "Lean healing", down = "Overhealed", icon = ICONS.healing },
		{ key = "overkill", up = nil, down = "Overkill heavy", icon = ICONS.damage },
		{ key = "manaDry", up = nil, down = "Mana ran dry", icon = ICONS.activity },
		{ key = "prepared", up = "Flask + food", down = "No flask/food", icon = ICONS.consumables },
		{ key = "healthstone", up = "Healthstone", down = "No healthstone", icon = ICONS.healthstone },
		-- (the tanking bonus chip retired 2026-07-26: mitigation is a scored
		-- base metric now, the gauge above carries it - no chip)
		{ key = "buffs", up = nil, down = "Buff missing", icon = ICONS.buffUptime },
		{ key = "pull", up = nil, down = "Pulled early", icon = ICONS.avoidable },
		{ key = "aggro", up = nil, down = "Ripped aggro", icon = ICONS.avoidable },
		{ key = "aggroLoss", up = nil, down = "Lost aggro", icon = ICONS.avoidable },
		-- kicks/dispels: the bar only renders when something landed, but a
		-- capable player at zero still gets charged — the charge must show
		-- (healers are bonus-only for kicks, so "down" never fires on them)
		{ key = "kicks", up = "Kicked anyway", down = "No interrupts", icon = ICONS.interrupts },
		{ key = "dispels", up = "Dispels", down = "No dispels", icon = ICONS.dispels },
		{ key = "dispelReact", up = "Fast dispels", down = "Slow dispels", icon = ICONS.dispels },
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
				verdict(def.key, def.icon, label, v)
			end
		end
	end

	-- 10) deaths: red pips, capped at 5 shown (the count rides the row)
	local deaths = m.deaths or 0
	if deaths > 0 then
		local dLabel = "Died"
		if (player and player.deathReadyDefensives or 0) >= 2 and (ad.deathReady or 0) < 0 then
			-- the approved mockup's phrasing: "CDs unused" read ambiguous
			-- (Josh 2026-07-25) and collided with the group card's raid-CD
			-- line
			dLabel = "Died, CDs ready"
		elseif (ad.deathNoDefensives or 0) < 0 then
			dLabel = "No defensive"
		end
		out[#out + 1] = { key = "deaths", kind = "pips", icon = ICONS.deaths,
			label = dLabel, count = deaths,
			points = -(pd.deaths or 0) + (ad.deathReady or 0) + (ad.deathNoDefensives or 0) }
	end

	return out
end

-- Group-card signal rows (the redesign's last surface): transforms
-- Bullets.ForGroup's TESTED output into the card's row model — bars
-- for coverage stories, glyph verdicts for the advisors, and full-width
-- TEXT rows for the sentence-shaped lines (each with its own hover —
-- the Other rollup hid them, Josh 2026-07-25). Parsing the strings
-- ForGroup already builds keeps a single source of truth.
function Signals.GroupRows(results, fight)
	local rows = {}
	local function ptsOf(text)
		return tonumber((text or ""):match("%(([%+%-]%d+)%)%s*$"))
	end
	local function stripPts(text)
		return (text or ""):gsub("%s*%([%+%-]%d+%)%s*$", "")
	end
	for _, bl in ipairs(TP.Scoring.Bullets.ForGroup(results, fight)) do
		local text = bl.text or ""
		local pts = ptsOf(text)
		if bl.kind == "metric" and (bl.key == "damage" or bl.key == "healing") and bl.avg then
			local row = barRow(bl.key, ICONS[bl.key],
				bl.key == "damage" and "Damage" or "Healing", bl.avg, nil)
			row.raw = not bl.wclBacked or nil
			row.base = true -- group-averaged WCL metric; Raw mode keeps these
			row.groupB = { value = bl.total, normalized = bl.avg, wclBacked = bl.wclBacked }
			row.players = bl.players
			rows[#rows + 1] = row
		elseif bl.key == "healing" then
			rows[#rows + 1] = { key = "healing", kind = "glyph", icon = ICONS.healing,
				label = "Little to heal", good = true, tooltip = bl.tooltip }
		elseif bl.key == "interrupts" then
			local landed, opps = text:match("(%d+) of (%d+)")
			if landed then
				local row = barRow("interrupts", ICONS.interrupts, "Kicks",
					tonumber(landed) / tonumber(opps) * 100, pts)
				row.num = landed .. "/" .. opps
				row.tooltip = bl.tooltip
				rows[#rows + 1] = row
			else
				-- no opportunity data: countable, so it's a CHIP, not a
				-- sentence — "(+2)" inline read as part of the count
				-- (Josh 2026-07-25)
				local n = text:match("^(%d+) interrupt")
				if n then
					rows[#rows + 1] = { key = "interrupts", kind = "glyph",
						icon = ICONS.interrupts, label = "Kicks", good = true,
						count = tonumber(n), points = pts, tooltip = bl.tooltip }
				else
					rows[#rows + 1] = { key = "interrupts", kind = "glyph", icon = ICONS.interrupts,
						label = stripPts(text), points = pts, good = (pts or 0) > 0 or nil, tooltip = bl.tooltip }
				end
			end
		elseif bl.key == "lust" then
			local a, b2 = text:match("(%d+) of (%d+)")
			if a then
				local row = barRow("lust", ICONS.lust, "Lust aligned",
					tonumber(a) / tonumber(b2) * 100, pts)
				row.num = a .. "/" .. b2
				row.tooltip = bl.tooltip
				rows[#rows + 1] = row
			end
		elseif bl.key == "healerComp" then
			local ran, mode = text:match("Ran (%d+) healers %- ranked kills mostly run (%d+)")
			rows[#rows + 1] = { key = "healerComp", kind = "glyph", icon = ICONS.healing,
				label = "Heavy comp", good = false,
				count = ran and (ran .. "v" .. mode) or nil, tooltip = bl.tooltip }
		elseif bl.key == "raidCds" then
			-- the names ARE the point of this line ("assign the raid CDs"
			-- stops being abstract) — the 30px number column clips them, so
			-- they go in the tooltip and the count rides the row
			local names = text:match("%- (.+) sat unused")
			local lines = {}
			if names then
				lines[#lines + 1] = { names, 1, 1, 1, true }
			end
			lines[#lines + 1] = { "Owned, never pressed. Assign one button per big moment.", 0.8, 0.8, 0.8, true }
			rows[#rows + 1] = { key = "raidCds", kind = "glyph", icon = ICONS.cdTimingHealer,
				label = "Unused raid CDs", good = false,
				count = names and tostring(select(2, names:gsub(",", ",")) + 1) or nil,
				tooltip = { title = "Raid cooldown assignment", lines = lines } }
		elseif bl.key == "speedTrend" then
			local fasterS = text:match("(%d+)s faster")
			local slowerS = text:match("(%d+)s slower")
			rows[#rows + 1] = { key = "speedTrend", kind = "glyph", icon = ICONS.activity,
				label = fasterS and "Faster kill" or "Slower kill",
				good = fasterS ~= nil,
				count = (fasterS or slowerS) and ((fasterS or slowerS) .. "s") or nil,
				tooltip = bl.tooltip }
		elseif bl.key == "wipeWrap" then
			-- "reset" is the raider's word for exactly this ("crisp wrap"
			-- sounded like a sandwich — Josh 2026-07-24)
			local tail = text:match("wrapped (%d+)s")
			rows[#rows + 1] = { key = "wipeWrap", kind = "glyph", icon = ICONS.deaths,
				label = text:find("crisp") and "Fast reset" or "Slow reset",
				good = text:find("crisp") ~= nil,
				count = tail and (tail .. "s") or nil, tooltip = bl.tooltip }
		elseif bl.key == "deaths" then
			local died = text:match("^(%d+) player")
				or (text:find("^1 player died") and "1")
			if text:find("Nobody died") then
				rows[#rows + 1] = { key = "deaths", kind = "glyph", icon = ICONS.deaths,
					label = "Nobody died", good = true, tooltip = bl.tooltip }
			elseif died then
				rows[#rows + 1] = { key = "deaths", kind = "pips", icon = ICONS.deaths,
					label = "Died", count = tonumber(died), points = pts }
			end
		elseif bl.key == "dispels" and text:match("^(%d+) dispel") then
			-- countable → a CHIP with the grid's own columns ("14 dispels
			-- (+1)" read as 14+1 dispels — Josh 2026-07-25)
			rows[#rows + 1] = { key = "dispels", kind = "glyph",
				icon = ICONS.dispels, label = "Dispels", good = true,
				count = tonumber(text:match("^(%d+) dispel")),
				points = pts, tooltip = bl.tooltip }
		else
			-- avoidable, aggro, buffs, anything future: CHIPS in the grid
			-- like the player card (Josh 2026-07-26) - terse uncolored label
			-- + colored points, the full sentence (its group nuance, "1
			-- player, 76% avoidable") riding the hover
			local CHIP = {
				avoidable = { icon = ICONS.avoidable, label = "Stood in bad" },
				aggro = { icon = ICONS.avoidable, label = "Ripped aggro" },
				aggroLoss = { icon = ICONS.avoidable, label = "Lost aggro" },
				pull = { icon = ICONS.avoidable, label = "Pulled early" },
				buffs = { icon = ICONS.buffUptime, label = "Buff missing" },
			}
			local c = CHIP[bl.key]
			local lines = { { stripPts(text), 1, 1, 1, true } }
			for _, ln in ipairs(bl.tooltip and bl.tooltip.lines or {}) do
				lines[#lines + 1] = ln
			end
			rows[#rows + 1] = { key = bl.key or "note", kind = "glyph",
				icon = (c and c.icon) or ICONS[bl.key],
				label = (c and c.label) or stripPts(text),
				good = (pts or 0) > 0 or nil, points = pts,
				tooltip = { title = (c and c.label) or "Group", lines = lines } }
		end
	end
	-- flask+food moved up from the footer (Josh 2026-07-25): a no-point
	-- chip — the group rollup never scores; individual prepared bonuses
	-- live on the player cards. Consumables are self-reported, so the
	-- denominator counts only installs that can vouch.
	local reporting, ready = 0, 0
	for _, r in ipairs(results or {}) do
		local p = fight and fight.players and fight.players[r.guid]
		local cons = p and p.metrics and p.metrics.consumables
		if cons ~= nil then
			reporting = reporting + 1
			if cons >= 2 then
				ready = ready + 1
			end
		end
	end
	if reporting > 0 then
		rows[#rows + 1] = { key = "consumables", kind = "glyph",
			icon = ICONS.consumables, label = "Flask + food",
			good = ready == reporting, count = ready .. "/" .. reporting,
			tooltip = { title = "Flask + food", lines = { {
				"Players with both up at the pull. Counts only players whose TrueParse reported.",
				0.8, 0.8, 0.8, true } } } }
	end
	return rows
end

-- Downsample a sparse per-second series ([second] = value) into n cells
-- for the group card's fight-shape sparkline. Pure; called at capture.
function Signals.Downsample(buckets, duration, n)
	if not buckets or not duration or duration <= 0 then
		return nil
	end
	local cells = {}
	for i = 1, n do
		cells[i] = 0
	end
	local any = false
	for t, v in pairs(buckets) do
		if type(t) == "number" and t >= 0 and t <= duration then
			local i = math.min(n, math.floor(t / duration * n) + 1)
			cells[i] = cells[i] + v
			any = v > 0 or any
		end
	end
	if not any then
		return nil
	end
	for i = 1, n do
		cells[i] = math.floor(cells[i] + 0.5)
	end
	return cells
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
			-- coverage bars tick against the other players holding the
			-- same job (tanks vs tanks, healers share team coverage)
			local w, c, u
			if r.role == "TANK" and (m.spikeWindows or 0) >= 2 then
				w, c, u = m.spikeWindows, m.spikeCovered or 0, m.defensiveUses
			elseif r.role == "HEALER" then
				local extW, extC = 0, 0
				if TP.EXTERNALS_BY_SPEC and p.specID and TP.EXTERNALS_BY_SPEC[p.specID] then
					extW, extC = m.extWindows or 0, m.extCovered or 0
				end
				if (m.groupSpikeWindows or 0) + extW >= 2 then
					w = (m.groupSpikeWindows or 0) + extW
					c = (m.groupSpikeCovered or 0) + extC
					u = m.groupCdCasts
				end
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
