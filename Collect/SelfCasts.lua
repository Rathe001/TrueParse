-- Records the player's OWN combat facts that Blizzard hides from everyone
-- else: defensive cooldowns used, consumables up at the pull, and whether
-- defensives were sitting ready at the moment of death. Own data is never
-- secret (probe-verified); each TrueParse user donates theirs via Sync.
local _, TP = ...

local SelfCasts = {}
TP.SelfCasts = SelfCasts

local combatStart
local defensivesUsed = 0
local consumablesAtPull = 0
local readyAtDeath = -1 -- -1 = didn't die this fight
-- own active-time proxy (retail can't read other players' casts, so each
-- TrueParse donates its own, like defensives)
local activeSecs = 0
local lastCastAt
local ACTIVITY_CAP = 1.6
-- Hardcasts and channels credit their real span, not one GCD: a 2s cast
-- or an 8s channel is that many seconds of activity (capped for sanity).
local ACTIVITY_SPAN_MAX = 10
local castStartAt, castSpellID
local channelStartAt

-- Retail SELF-coach (Josh 2026-07-25): Midnight hides everyone's casts
-- from CLEU, but your OWN UNIT_SPELLCAST_SUCCEEDED is readable — so the
-- coach can exist on retail for YOUR card only. We count just the
-- spec's signature spells (from the crawled profiles) per fight window
-- and attach them to the local player's capture like the other
-- self-facts. Never broadcast: nobody else's client can verify it.
local watchedSpells -- [spellID] = true, rebuilt per window from the profile
local ownCasts -- [spellID] = count for the current window

-- Extended self-facts (2026-07-25, /tp probe verdict): own UNIT_COMBAT
-- events are fully readable on retail, so each install can donate the
-- MoP-grade tanking ingredients (avoidance, swing damage) plus its own
-- mitigation-buff uptime and healthstone use. Retail-only collectors:
-- CLEU observes all of this for everyone on Classic.
local HEALTHSTONE_SPELL = 6262
local hsUsed = 0
local swingsLanded, swingsAvoided, swingDamage = 0, 0, 0
local mitSeconds = 0
local mitTicker
local mitTracked = false -- did this window sample mitigation at all?
-- cast-derived uptime (Midnight makes own-aura fields secret, so the
-- aura sampler reads nothing); mitCoveredUntil is the union cursor
local mitCastSeconds, mitCoveredUntil = 0, 0
-- phase 2 (2026-07-25): lust window, mana timeline, personal spike
-- windows — all from own-only signals, all retail (CLEU covers Classic)
local lustAtOff, lustCastsN, lastOffAt
local lustTicker
local manaMinPct, dryAtOff
local manaTicker, manaTracked
local takenBuckets, maxHPAtPull
local defCastTimes = {}
local ownDeaths, firstDeathAt = 0, nil
local brezCasts = 0
-- raid-CD cast times (retail group-spike coverage): feeds the healer
-- cdTiming metric once reporters' timelines are aggregated
local raidCdTimes = {}
local ROLE_LETTER = { TANK = "T", HEALER = "H", DAMAGER = "D", SUPPORT = "S" }
-- own combat-rez casts (retail; CLEU sees these on Classic)
local BREZ_SPELLS = {
	[20484] = true, -- Rebirth
	[61999] = true, -- Raise Ally
	[391054] = true, -- Intercession
	[20707] = true, -- Soulstone (cast on a dead player)
}

local function stopMitTicker()
	if mitTicker then
		mitTicker:Cancel()
		mitTicker = nil
	end
end

local function stopPhase2Tickers()
	if lustTicker then
		lustTicker:Cancel()
		lustTicker = nil
	end
	if manaTicker then
		manaTicker:Cancel()
		manaTicker = nil
	end
end

-- Role of the player's own spec. Derived from OUR spec table rather than
-- GetSpecializationInfo's fifth return value (Josh 2026-07-28): every other
-- caller in the addon trusts only return 1 (the specID) — Roster does, and
-- its specIDs are demonstrably correct in the field — so leaning on a
-- positional role here is the one place a shifted signature could silently
-- disable tank mitigation tracking, with no error to notice. 17 of 21
-- addon-running tanks reported every other self-report field but no
-- mitigation at all, which is exactly what this failure looks like.
local function specRole()
	if not (GetSpecialization and GetSpecializationInfo) then
		return nil
	end
	local spec = GetSpecialization()
	if not spec then
		return nil
	end
	local specID = select(1, GetSpecializationInfo(spec))
	local known = specID and TP.SPEC_ROLES and TP.SPEC_ROLES[specID]
	if known then
		return known
	end
	return select(5, GetSpecializationInfo(spec)) -- fallback for an unlisted spec
end

local function isTankSpec()
	return specRole() == "TANK"
end

-- exposed for /tp mit, which is the only way to tell a wrong buff id apart
-- from a spec that never read as TANK
function SelfCasts.DebugRole()
	return specRole()
end

local function buildWatchList()
	watchedSpells, ownCasts = nil, nil
	if not (TP.Compat.IS_RETAIL and TP.SpellProfiles
		and GetSpecialization and GetSpecializationInfo) then
		return
	end
	local spec = GetSpecialization()
	local specID = spec and GetSpecializationInfo(spec)
	local prof = specID and TP.SpellProfiles[specID]
	if not (prof and prof.spells) then
		return
	end
	watchedSpells, ownCasts = {}, {}
	for _, sp in ipairs(prof.spells) do
		for _, id in ipairs(sp.ids or {}) do
			watchedSpells[id] = true
		end
	end
end

local function creditActivity(t, span)
	local cap = ACTIVITY_CAP
	if span and span > cap and span < ACTIVITY_SPAN_MAX then
		cap = span
	end
	activeSecs = activeSecs + (lastCastAt and math.min(t - lastCastAt, cap) or cap)
	lastCastAt = t
end

-- Augmentation buff uptime: group auras are secret on Midnight, but Ebon
-- Might keeps a personal aura on the Evoker for exactly as long as it runs
-- on the allies, so the Aug's own client can measure its uptime and donate
-- it. Unlike the other self-reports this one IS scored (it's the metric
-- that defines the spec); the receiver clamps it to sane bounds.
local AUG_SPEC_ID = 1473
local EBON_MIGHT_SELF = 395296
-- Prescience is cast on ALLIES (no personal aura, ally auras are secret on
-- Midnight), so uptime isn't directly measurable. We count the Aug's own
-- Prescience casts and score the cadence instead (Josh 2026-07-26).
-- PROVISIONAL spell id, verify on Wowhead.
local PRESCIENCE_CAST = 409311
local uptimeSeconds = 0
local prescienceCasts = 0
local trackingUptime = false
local uptimeTicker

local function isAugEvoker()
	if not TP.Compat.IS_RETAIL then
		return false
	end
	local _, class = UnitClass("player")
	if class ~= "EVOKER" or not (GetSpecialization and GetSpecializationInfo) then
		return false
	end
	local spec = GetSpecialization()
	return (spec and GetSpecializationInfo(spec)) == AUG_SPEC_ID
end

local function stopUptimeTicker()
	if uptimeTicker then
		uptimeTicker:Cancel()
		uptimeTicker = nil
	end
end

-- Long-duration helpful auras at pull start, excluding raid buffs: flasks,
-- food, runes. Heuristic (25min-2h), locale-free, own auras only. The
-- ceiling matters: multi-hour event/holiday buffs (Josh's Aeki carried a
-- 19h aura, 2026-07-25) are not preparation and were minting false +1s.
local CONSUMABLE_MIN_DURATION = 1500
local CONSUMABLE_MAX_DURATION = 7200 -- alchemist flasks cap at 2h

local function isGroupBuffAura(spellId)
	if not TP.GROUP_BUFFS then
		return false
	end
	for _, category in ipairs(TP.GROUP_BUFFS) do
		if category.auras[spellId] then
			return true
		end
	end
	return false
end

local function countConsumables()
	if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then
		return 0
	end
	local count, seen, readable = 0, 0, 0
	for i = 1, 60 do
		local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
		if not ok or not aura then
			break
		end
		seen = seen + 1
		local duration = aura.duration
		local id = aura.spellId
		if id and not TP.Compat.IsSecret(id) then
			readable = readable + 1
			if duration and duration >= CONSUMABLE_MIN_DURATION
				and duration <= CONSUMABLE_MAX_DURATION
				and not isGroupBuffAura(id) then
				count = count + 1
			end
		end
	end
	-- UNMEASURABLE is not ZERO (Josh 2026-07-29). Midnight returns every
	-- field of the player's own auras as a secret value - a /tp mit dump
	-- with a flask up read 13 auras, 0 with a readable id - so this
	-- counted nothing and every retail player ate the "No flask/food"
	-- penalty regardless of what they drank. Auras present but none
	-- readable means we cannot see consumables at all; say so with nil and
	-- the engine skips the penalty (it already guards on ~= nil).
	-- ANY unreadable aura poisons the count, not just all of them (Josh
	-- 2026-07-29, second pass): the same character on the same run got -2
	-- on three bosses and -1 on the fourth without touching a consumable,
	-- because readability is partial - some ids come back, some are
	-- secret, and the flask can be in either bucket. "I saw 13 auras and
	-- could read 9" tells us nothing about whether the flask was among the
	-- 4 we couldn't. Only a fully readable list can support a penalty.
	if seen > readable then
		return nil
	end
	return math.min(count, 5)
end

-- How many known major defensives were OFF cooldown right now
local function countReadyDefensives()
	if not TP.DEFENSIVES then
		return 0
	end
	local ready = 0
	for spellId in pairs(TP.DEFENSIVES) do
		if IsPlayerSpell and IsPlayerSpell(spellId) then
			local start, duration
			if C_Spell and C_Spell.GetSpellCooldown then
				local ok, info = pcall(C_Spell.GetSpellCooldown, spellId)
				if ok and info then
					start, duration = info.startTime, info.duration
				end
			elseif GetSpellCooldown then
				local ok, s, d = pcall(GetSpellCooldown, spellId)
				if ok then
					start, duration = s, d
				end
			end
			-- off cooldown, or only the GCD remains
			if start ~= nil and ((start == 0) or ((start + (duration or 0)) - GetTime() <= 1.5)) then
				ready = ready + 1
			end
		end
	end
	return math.min(ready, 9)
end

-- Leaving combat mid-encounter (Blackfuse conveyor, fixates, feign-style
-- phasing) must NOT finalize the report: a fragment with a reset defensive
-- count matched the encounter duration and reported "0 defensives" for a
-- player who visibly used them. While ANY group member is still fighting,
-- the fight window stays open; re-entering combat resumes it.
local graceTicker
local GRACE_MAX_SECONDS = 180
-- While a boss ENCOUNTER is verifiably running, the grace cap doesn't
-- apply: die at minute 3 of a 10-minute wipe and the 180s cap used to
-- finalize a ~4-minute window whose duration fingerprint could never
-- match the real fight — the report went orphaned and the capture
-- showed no self-facts (Josh's raid night, 2026-07-24). ENCOUNTER_END
-- is the hard close, so the window can't stick open.
local encounterOpen = false

local function stopGrace()
	if graceTicker then
		graceTicker:Cancel()
		graceTicker = nil
	end
end

local function groupInCombat()
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			if UnitAffectingCombat("raid" .. i) then
				return true
			end
		end
	elseif IsInGroup() then
		for i = 1, GetNumGroupMembers() - 1 do
			if UnitAffectingCombat("party" .. i) then
				return true
			end
		end
	end
	return false
end

local function finalizeFight()
	stopGrace()
	stopUptimeTicker()
	stopMitTicker()
	stopPhase2Tickers()
	if not combatStart then
		return
	end
	local duration = GetTime() - combatStart
	combatStart = nil
	local uptimePct = -1 -- -1 = not an Aug, no uptime to report
	if trackingUptime and duration > 0 then
		uptimePct = math.min(100, math.floor(uptimeSeconds / duration * 100 + 0.5))
	end
	local activityPct = -1
	if duration > 0 and activeSecs > 0 then
		activityPct = math.min(100, math.floor(activeSecs / duration * 100 + 0.5))
	end
	if duration >= 10 and TP.Sync.RecordFightReport then
		-- ownCasts rides the LOCAL report only (retail self-coach);
		-- the broadcast wire never carries it
		local casts = ownCasts and next(ownCasts) and ownCasts or nil
		-- extended self-facts (retail): only fields with something to
		-- say ride along, and only where CLEU can't see them
		local x
		if TP.Compat.IS_RETAIL then
			x = {}
			if hsUsed > 0 then
				x.hs = hsUsed
			end
			if swingsLanded + swingsAvoided > 0 then
				x.sl, x.sa = swingsLanded, swingsAvoided
				x.sd = math.floor(swingDamage + 0.5)
			end
			-- Prefer whichever source actually saw something. Aura
			-- sampling is a true measurement and cast-derived is an
			-- estimate, so max() takes the real number when auras work and
			-- falls back to casts on Midnight, where they read nothing -
			-- and self-heals if Blizzard ever unblocks them.
			if (mitTracked or mitCastSeconds > 0) and duration > 0 then
				local secs = math.max(mitSeconds, mitCastSeconds)
				if secs > 0 then
					x.mi = math.min(100, math.floor(secs / duration * 100 + 0.5))
				end
			end
			-- lust window: when OUR aura opened it, when we last spent a
			-- big button, and how many landed inside the window
			if lustAtOff then
				x.la = math.floor(lustAtOff + 0.5)
				x.lc = lustCastsN
			end
			if lastOffAt then
				x.lo = math.floor(lastOffAt + 0.5)
			end
			-- healer mana timeline
			if manaTracked and manaMinPct then
				x.mm = math.floor(manaMinPct + 0.5)
				if dryAtOff then
					x.dr = math.floor(dryAtOff + 0.5)
				end
			end
			-- own deaths + first death time + combat rezzes cast
			if ownDeaths > 0 then
				x.de = ownDeaths
				x.dt = math.floor((firstDeathAt or 0) + 0.5)
			end
			if brezCasts > 0 then
				x.rz = brezCasts
			end
			-- Aug Prescience cast count (scored as cadence by the receiver)
			if prescienceCasts > 0 then
				x.pr = prescienceCasts
			end
			-- personal spike windows from own intake buckets, coverage
			-- from own defensive cast times (same slops the Classic
			-- tracker uses). The map rides the LOCAL report only.
			local personalWins
			if maxHPAtPull and TP.Spikes and TP.Spikes.FindWindows
				and next(takenBuckets or {}) then
				local threshold = maxHPAtPull * (TP.Spikes.TANK_3S_SHARE or 0.45)
				local ok, wins = pcall(TP.Spikes.FindWindows, takenBuckets, duration, threshold)
				if ok and wins and #wins > 0 then
					personalWins = wins
					local map, covered = {}, 0
					for _, w in ipairs(wins) do
						local met
						for _, ct in ipairs(defCastTimes) do
							if ct >= w[1] - 8 and ct <= w[2] + 1.5 then
								met = true
								break
							end
						end
						if met then
							covered = covered + 1
						end
						map[#map + 1] = { math.floor(w[1]), math.floor(w[2]), met or nil }
					end
					x.sw, x.sc, x.du = #wins, covered, defensivesUsed
					x.map = map -- table: local report only, never the wire
				end
			end
			-- group-spike inputs: my role, my personal spike windows (the
			-- votes), and my raid-CD cast times (coverage). Aggregated
			-- across reporters at capture to rebuild MoP's group cdTiming.
			local myRole = ROLE_LETTER[specRole() or ""] or "D"
			local gWindows = {}
			for _, w in ipairs(personalWins or {}) do
				gWindows[#gWindows + 1] = { math.floor(w[1]), math.floor(w[2]) }
			end
			if #gWindows > 0 or #raidCdTimes > 0 then
				x.g = { role = myRole, windows = gWindows, cdCasts = raidCdTimes }
			end
			if not next(x) then
				x = nil
			end
		end
		TP.Sync:RecordFightReport(UnitGUID("player"), duration, defensivesUsed, consumablesAtPull, readyAtDeath, uptimePct, activityPct, casts, x)
		TP.Sync:BroadcastFightReport(duration, defensivesUsed, consumablesAtPull, readyAtDeath, uptimePct, activityPct)
		if x then
			TP.Sync:BroadcastExtendedReport(duration, x)
			if x.g then
				TP.Sync:BroadcastGroupInput(duration, x.g)
			end
		end
	end
	ownCasts = watchedSpells and {} or nil
end

local function startWindow()
	combatStart = GetTime()
	defensivesUsed = 0
	readyAtDeath = -1
	activeSecs = 0
	lastCastAt = nil
	castStartAt, castSpellID, channelStartAt = nil, nil, nil
	hsUsed, swingsLanded, swingsAvoided, swingDamage = 0, 0, 0, 0
	mitSeconds = 0
	mitCastSeconds, mitCoveredUntil = 0, 0
	mitTracked = false
	stopMitTicker()
	stopPhase2Tickers()
	lustAtOff, lustCastsN, lastOffAt = nil, 0, nil
	manaMinPct, dryAtOff, manaTracked = nil, nil, false
	takenBuckets, maxHPAtPull = {}, nil
	defCastTimes = {}
	ownDeaths, firstDeathAt = 0, nil
	brezCasts = 0
	raidCdTimes = {}
	if TP.Compat.IS_RETAIL then
		local okHP, hp = pcall(UnitHealthMax, "player")
		if okHP and hp and not TP.Compat.IsSecret(hp) and hp > 0 then
			maxHPAtPull = hp
		end
		-- the lust window opens when OUR OWN lust aura lands (own auras
		-- are readable); one cheap check a second until found
		if TP.LUST and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
			lustTicker = C_Timer.NewTicker(1, function()
				if lustAtOff then
					return
				end
				for spellId in pairs(TP.LUST) do
					local okL, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellId)
					if okL and aura and combatStart then
						lustAtOff = GetTime() - combatStart
						return
					end
				end
			end)
		end
		-- healer mana timeline: minimum % and the moment the tank ran dry
		if specRole() == "HEALER" and UnitPowerType and UnitPowerType("player") == 0 then
			manaTracked = true
			manaTicker = C_Timer.NewTicker(1, function()
				local okP, cur = pcall(UnitPower, "player", 0)
				local okM, max = pcall(UnitPowerMax, "player", 0)
				-- IsSecret BEFORE the > 0 compare (own mana isn't secret
				-- today, but the reverse order is the shape that crashed on
				-- friendly HP - keep the safe ordering everywhere)
				if okP and okM and cur and max
					and not TP.Compat.IsSecret(cur) and not TP.Compat.IsSecret(max)
					and max > 0 then
					local pct = cur / max * 100
					if not manaMinPct or pct < manaMinPct then
						manaMinPct = pct
					end
					if pct <= 1 and not dryAtOff and combatStart then
						dryAtOff = GetTime() - combatStart
					end
				end
			end)
		end
	end
	-- own active-mitigation uptime, sampled once a second (own auras
	-- are readable on retail); tanks only, and only when the buff list
	-- for this client exists
	if TP.Compat.IS_RETAIL and TP.MITIGATION_BUFFS and isTankSpec()
		and C_UnitAuras and C_UnitAuras.GetPlayerAuraBySpellID then
		mitTracked = true
		mitTicker = C_Timer.NewTicker(1, function()
			for spellId in pairs(TP.MITIGATION_BUFFS) do
				local okM, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, spellId)
				if okM and aura then
					mitSeconds = mitSeconds + 1
					return
				end
			end
		end)
	end
	buildWatchList()
	local ok, count = pcall(countConsumables)
	-- nil, not 0, when the count is unmeasurable: `ok and count or 0`
	-- collapsed both onto the penalised value
	consumablesAtPull = ok and count or nil
	uptimeSeconds = 0
	prescienceCasts = 0
	trackingUptime = isAugEvoker()
	if trackingUptime and not uptimeTicker then
		uptimeTicker = C_Timer.NewTicker(1, function()
			local okA, aura = pcall(C_UnitAuras.GetPlayerAuraBySpellID, EBON_MIGHT_SELF)
			if okA and aura then
				uptimeSeconds = uptimeSeconds + 1
			end
		end)
	end
end

-- Own incoming combat events (probe-verified readable, 2026-07-25):
-- WOUND counts + amounts and DODGE/PARRY/MISS give the avoidance and
-- swing-damage ingredients the Tanking composite needs. Retail only;
-- CLEU observes this for everyone on Classic.
if TP.Compat.IS_RETAIL then
	local ucFrame = CreateFrame("Frame")
	local ok = pcall(ucFrame.RegisterUnitEvent, ucFrame, "UNIT_COMBAT", "player")
	if ok then
		ucFrame:SetScript("OnEvent", function(_, _, _, action, _, amount)
			if not combatStart or TP.Compat.IsSecret(action) then
				return
			end
			if action == "WOUND" then
				swingsLanded = swingsLanded + 1
				if type(amount) == "number" and not TP.Compat.IsSecret(amount) then
					swingDamage = swingDamage + amount
					-- per-second intake buckets: the personal spike
					-- windows are computed from these at fight end
					if takenBuckets then
						local off = math.floor(GetTime() - combatStart)
						takenBuckets[off] = (takenBuckets[off] or 0) + amount
					end
				end
			elseif action == "DODGE" or action == "PARRY" or action == "MISS" then
				swingsAvoided = swingsAvoided + 1
			end
		end)
	end
end

local frame = CreateFrame("Frame")
-- unit-filtered: the handler only cares about our own casts, and the
-- unfiltered event fires for every nameplate cast in a raid
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_DEAD")
frame:RegisterEvent("ENCOUNTER_START")
frame:RegisterEvent("ENCOUNTER_END")
frame:SetScript("OnEvent", function(_, event, unit, _, spellID)
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		if unit == "player" and combatStart then
			local isDefensive = TP.DEFENSIVES and TP.DEFENSIVES[spellID]
			if isDefensive then
				defensivesUsed = defensivesUsed + 1
				defCastTimes[#defCastTimes + 1] = GetTime() - combatStart
			end
			-- retail healthstone parity (CLEU counts these on Classic)
			if TP.Compat.IS_RETAIL and spellID == HEALTHSTONE_SPELL then
				hsUsed = hsUsed + 1
			end
			-- Active-mitigation uptime from CASTS, because Midnight makes
			-- own-aura fields secret and the sampler below reads nothing.
			-- Union, not a sum: a refresh before the buff expires only adds
			-- the seconds past what was already covered, so button-mashing
			-- can't inflate uptime the way count x duration would.
			local mitDur = TP.MITIGATION_CASTS and TP.MITIGATION_CASTS[spellID]
			if TP.Compat.IS_RETAIL and mitDur then
				-- REFRESH semantics: recasting restarts the buff, it does
				-- not queue behind the running one, so coverage becomes
				-- [now, now+duration] and only the part past what was
				-- already covered is new
				local now = GetTime()
				local newUntil = now + mitDur
				local prev = mitCoveredUntil or 0
				if newUntil > prev then
					mitCastSeconds = mitCastSeconds + (newUntil - math.max(now, prev))
					mitCoveredUntil = newUntil
				end
			end
			if TP.Compat.IS_RETAIL and BREZ_SPELLS[spellID] then
				brezCasts = brezCasts + 1
			end
			-- Prescience cadence input (Aug): count our own casts; the
			-- receiver scores casts/min vs the expected on-cooldown rate
			if TP.Compat.IS_RETAIL and spellID == PRESCIENCE_CAST then
				prescienceCasts = prescienceCasts + 1
			end
			-- raid-CD cast time (retail group-spike coverage)
			if TP.Compat.IS_RETAIL and TP.HEALER_CDS and TP.HEALER_CDS[spellID] then
				raidCdTimes[#raidCdTimes + 1] = math.floor(GetTime() - combatStart + 0.5)
			end
			-- generic offensive-CD detection (retail lust parity): any
			-- non-defensive button with a 60s+ base cooldown counts —
			-- no per-spec curation needed
			if TP.Compat.IS_RETAIL and spellID and not isDefensive
				and GetSpellBaseCooldown then
				local okCd, cd = pcall(GetSpellBaseCooldown, spellID)
				if okCd and cd and not TP.Compat.IsSecret(cd) and cd >= 60000 then
					local off = GetTime() - combatStart
					lastOffAt = off
					-- pre-lust grace matches the Classic tracker: casting
					-- 10s ahead of the window is correct play
					if lustAtOff and off >= lustAtOff - 10 and off <= lustAtOff + 42 then
						lustCastsN = lustCastsN + 1
					end
				end
			end
			if watchedSpells and spellID and watchedSpells[spellID] then
				ownCasts[spellID] = (ownCasts[spellID] or 0) + 1
			end
			local t = GetTime()
			local span
			if castStartAt and spellID == castSpellID then
				span = t - castStartAt
			end
			castStartAt, castSpellID = nil, nil
			creditActivity(t, span)
		end
	elseif event == "UNIT_SPELLCAST_START" then
		castStartAt, castSpellID = GetTime(), spellID
	elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
		channelStartAt = GetTime()
	elseif event == "UNIT_SPELLCAST_CHANNEL_STOP" then
		if combatStart and channelStartAt then
			local t = GetTime()
			creditActivity(t, t - channelStartAt)
		end
		channelStartAt = nil
	elseif event == "PLAYER_REGEN_DISABLED" then
		if graceTicker then
			-- back in combat while the group never left: same fight, keep
			-- every counter
			stopGrace()
			return
		end
		if not combatStart then
			startWindow()
		end
	elseif event == "ENCOUNTER_START" then
		encounterOpen = true
		-- boss pulled while chained from trash combat: the report must
		-- cover the ENCOUNTER, not the chain
		if combatStart then
			finalizeFight()
		end
		if UnitAffectingCombat("player") then
			startWindow()
		end
	elseif event == "ENCOUNTER_END" then
		encounterOpen = false
		-- finalize exactly at the encounter boundary so the duration
		-- fingerprint matches the capture (kills that chained into add
		-- cleanup or trash merged pulls into one unmatchable report)
		if combatStart then
			finalizeFight()
			if UnitAffectingCombat("player") then
				startWindow()
			end
		end
	elseif event == "PLAYER_DEAD" then
		if combatStart then
			local ok, count = pcall(countReadyDefensives)
			readyAtDeath = ok and count or -1
			-- own deaths are ground truth (Josh 2026-07-25: retail's
			-- Deaths attribute reads secret->0 and deathTimeSeconds only
			-- covers players still dead at the end, so a many-brez kill
			-- reported "deathless")
			ownDeaths = ownDeaths + 1
			if not firstDeathAt then
				firstDeathAt = GetTime() - combatStart
			end
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if not combatStart then
			return
		end
		if not IsInGroup() then
			finalizeFight()
			return
		end
		local waited = 0
		stopGrace()
		graceTicker = C_Timer.NewTicker(2, function()
			waited = waited + 2
			local ok, fighting = pcall(groupInCombat)
			if (ok and fighting) and (encounterOpen or waited < GRACE_MAX_SECONDS) then
				return -- fight still running; hold for ENCOUNTER_END
			end
			finalizeFight()
		end)
	end
end)

function SelfCasts:OnEnable()
	-- registrations above are load-time; nothing to do
end
