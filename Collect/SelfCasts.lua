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

local function stopMitTicker()
	if mitTicker then
		mitTicker:Cancel()
		mitTicker = nil
	end
end

local function isTankSpec()
	if not (GetSpecialization and GetSpecializationInfo) then
		return false
	end
	local spec = GetSpecialization()
	local role = spec and select(5, GetSpecializationInfo(spec))
	return role == "TANK"
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
local uptimeSeconds = 0
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
	local count = 0
	for i = 1, 60 do
		local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
		if not ok or not aura then
			break
		end
		local duration = aura.duration
		if duration and duration >= CONSUMABLE_MIN_DURATION
			and duration <= CONSUMABLE_MAX_DURATION
			and aura.spellId and not TP.Compat.IsSecret(aura.spellId)
			and not isGroupBuffAura(aura.spellId) then
			count = count + 1
		end
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
			if mitTracked and duration > 0 then
				x.mi = math.min(100, math.floor(mitSeconds / duration * 100 + 0.5))
			end
			if not next(x) then
				x = nil
			end
		end
		TP.Sync:RecordFightReport(UnitGUID("player"), duration, defensivesUsed, consumablesAtPull, readyAtDeath, uptimePct, activityPct, casts, x)
		TP.Sync:BroadcastFightReport(duration, defensivesUsed, consumablesAtPull, readyAtDeath, uptimePct, activityPct)
		if x then
			TP.Sync:BroadcastExtendedReport(duration, x)
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
	mitTracked = false
	stopMitTicker()
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
	consumablesAtPull = ok and count or 0
	uptimeSeconds = 0
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
			if TP.DEFENSIVES and TP.DEFENSIVES[spellID] then
				defensivesUsed = defensivesUsed + 1
			end
			-- retail healthstone parity (CLEU counts these on Classic)
			if TP.Compat.IS_RETAIL and spellID == HEALTHSTONE_SPELL then
				hsUsed = hsUsed + 1
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
