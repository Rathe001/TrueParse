-- EXPERIMENT: can TrueParse count interrupt OPPORTUNITIES itself on Midnight?
-- The combat log is forbidden, but unit cast events are a different API
-- family. This probe counts enemy casts seen via UNIT_SPELLCAST_* events,
-- whether their payloads are readable or secret mid-fight, and whether group
-- aura data stays readable (for future buff/debuff metrics). It prints a
-- one-line report after each fight. Toggle with /tp probe.
--
-- If this works, interrupt scoring becomes true opportunity capture:
-- kickable casts counted here (denominator) x per-player kick counts from
-- C_DamageMeter (numerator).
local _, TP = ...

local Probe = {}
TP.CastProbe = Probe

local IsSecret -- bound on enable

local counts = {
	casts = 0, interruptible = 0, secret = 0, interrupted = 0,
	auraReads = 0, auraSecrets = 0, errors = 0,
}
local seenCasts = {}
local seenInterrupts = {}
local auraTimer

local function reset()
	wipe(seenCasts)
	wipe(seenInterrupts)
	for k in pairs(counts) do
		counts[k] = 0
	end
end

local function enabled()
	return TP.Addon.db.profile.probe
end

local function isHostileNPC(unit)
	return UnitExists(unit) and UnitCanAttack("player", unit) and not UnitIsPlayer(unit)
end

-- Same cast can fire once per unit token pointing at the mob (target,
-- nameplateN, boss1...). Dedupe by castGUID, falling back to mob GUID +
-- spell for events that omit it (channels historically did).
local function castKey(unit, castGUID, spellID)
	if castGUID and not IsSecret(castGUID) then
		return castGUID
	end
	return (UnitGUID(unit) or unit) .. "-" .. tostring(spellID)
end

local function readNotInterruptible(unit, isChannel)
	if isChannel then
		return select(7, UnitChannelInfo(unit))
	end
	return select(8, UnitCastingInfo(unit))
end

local function onCastStart(unit, castGUID, spellID, isChannel)
	if not enabled() or not isHostileNPC(unit) then
		return
	end
	if IsSecret(spellID) then
		counts.secret = counts.secret + 1
		return
	end
	local key = castKey(unit, castGUID, spellID)
	if seenCasts[key] then
		return
	end
	seenCasts[key] = true
	counts.casts = counts.casts + 1

	local ok, notInterruptible = pcall(readNotInterruptible, unit, isChannel)
	if not ok then
		counts.errors = counts.errors + 1
	elseif IsSecret(notInterruptible) then
		counts.secret = counts.secret + 1
	elseif not notInterruptible then
		counts.interruptible = counts.interruptible + 1
	end
end

local function onInterrupted(unit, castGUID, spellID)
	if not enabled() or not isHostileNPC(unit) then
		return
	end
	if IsSecret(spellID) then
		counts.secret = counts.secret + 1
		return
	end
	local key = castKey(unit, castGUID, spellID)
	if seenInterrupts[key] then
		return
	end
	seenInterrupts[key] = true
	counts.interrupted = counts.interrupted + 1
end

-- Mid-fight readability of group member auras (what buff/debuff-uptime
-- metrics would need). Samples the first helpful aura of each roster member.
local function sampleAuras()
	if not enabled() then
		return
	end
	for _, info in pairs(TP.Roster.players) do
		if UnitExists(info.unit) then
			local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, info.unit, 1, "HELPFUL")
			if not ok then
				counts.errors = counts.errors + 1
			elseif aura then
				counts.auraReads = counts.auraReads + 1
				if IsSecret(aura.name) or IsSecret(aura.spellId) then
					counts.auraSecrets = counts.auraSecrets + 1
				end
			end
		end
	end
end

function Probe:Report()
	if counts.casts == 0 and counts.secret == 0 and counts.auraReads == 0 then
		return
	end
	TP.Addon:Print(("Probe: enemy casts %d (interruptible %d, secret %d), interrupted %d · aura reads %d (%d secret) · errors %d"):format(
		counts.casts, counts.interruptible, counts.secret, counts.interrupted,
		counts.auraReads, counts.auraSecrets, counts.errors))
end

function Probe:OnEnable()
	IsSecret = TP.Compat.IsSecret
	local Addon = TP.Addon

	Addon:RegisterEvent("UNIT_SPELLCAST_START", function(_, unit, castGUID, spellID)
		onCastStart(unit, castGUID, spellID, false)
	end)
	Addon:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START", function(_, unit, castGUID, spellID)
		onCastStart(unit, castGUID, spellID, true)
	end)
	Addon:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED", function(_, unit, castGUID, spellID)
		onInterrupted(unit, castGUID, spellID)
	end)

	Addon:RegisterMessage("TrueParse_SEGMENT_CHANGED", function()
		if TP.Segments.current then
			reset()
			if not auraTimer then
				auraTimer = Addon:ScheduleRepeatingTimer(sampleAuras, 2)
			end
		else
			if auraTimer then
				Addon:CancelTimer(auraTimer)
				auraTimer = nil
			end
			if enabled() then
				Probe:Report()
			end
		end
	end)
end
