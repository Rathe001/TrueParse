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
-- food, runes. Heuristic (25min+), locale-free, own auras only.
local CONSUMABLE_MIN_DURATION = 1500

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
		TP.Sync:RecordFightReport(UnitGUID("player"), duration, defensivesUsed, consumablesAtPull, readyAtDeath, uptimePct, activityPct)
		TP.Sync:BroadcastFightReport(duration, defensivesUsed, consumablesAtPull, readyAtDeath, uptimePct, activityPct)
	end
end

local function startWindow()
	combatStart = GetTime()
	defensivesUsed = 0
	readyAtDeath = -1
	activeSecs = 0
	lastCastAt = nil
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

local frame = CreateFrame("Frame")
-- unit-filtered: the handler only cares about our own casts, and the
-- unfiltered event fires for every nameplate cast in a raid
frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
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
			local t = GetTime()
			activeSecs = activeSecs + (lastCastAt and math.min(t - lastCastAt, ACTIVITY_CAP) or ACTIVITY_CAP)
			lastCastAt = t
		end
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
		-- boss pulled while chained from trash combat: the report must
		-- cover the ENCOUNTER, not the chain
		if combatStart then
			finalizeFight()
		end
		if UnitAffectingCombat("player") then
			startWindow()
		end
	elseif event == "ENCOUNTER_END" then
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
			if (ok and fighting) and waited < GRACE_MAX_SECONDS then
				return -- encounter still running; hold the window open
			end
			finalizeFight()
		end)
	end
end)

function SelfCasts:OnEnable()
	-- registrations above are load-time; nothing to do
end
