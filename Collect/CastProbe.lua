-- EXPERIMENT (concluded 2026-07-07, Windrunner Spire follower dungeon):
-- can TrueParse count interrupt OPPORTUNITIES itself on Midnight?
--
-- VERDICT: no. UNIT_SPELLCAST_* events never fire for hostile NPCs (0 casts,
-- 0 secrets, 0 interrupted across many caster pulls), and group aura reads
-- are ~90% secret mid-combat. Interrupt scoring therefore uses C_DamageMeter
-- kick counts normalized among kick-capable specs, and buff checks must be
-- pre-pull snapshots (out-of-combat reads are never secret).
--
-- Kept (default off) for re-testing on future patches and Classic clients.
-- Toggle: /tp probe. Live dump: /tp probe status.
--
-- Deliberately keyed to the player's own PLAYER_REGEN_* state on a private
-- frame, NOT to TP.Segments: follower-dungeon NPCs can hold segments open,
-- and AceEvent allows only one handler per event per object.
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
local auraTicker

local function reset()
	wipe(seenCasts)
	wipe(seenInterrupts)
	for k in pairs(counts) do
		counts[k] = 0
	end
end

local function enabled()
	return IsSecret ~= nil and TP.Addon.db and TP.Addon.db.profile.probe
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

function Probe:Report(force)
	local observed = counts.casts + counts.secret + counts.auraReads + counts.errors
	if observed == 0 then
		if force then
			TP.Addon:Print("Probe: nothing observed yet (no enemy cast events, no aura samples).")
		end
		return
	end
	TP.Addon:Print(("Probe: enemy casts %d (interruptible %d, secret %d), interrupted %d · aura reads %d (%d secret) · errors %d"):format(
		counts.casts, counts.interruptible, counts.secret, counts.interrupted,
		counts.auraReads, counts.auraSecrets, counts.errors))
end

local function onCombatStart()
	reset()
	if not auraTicker then
		auraTicker = C_Timer.NewTicker(2, sampleAuras)
	end
end

local function onCombatEnd()
	if auraTicker then
		auraTicker:Cancel()
		auraTicker = nil
	end
	if enabled() then
		Probe:Report(false)
	end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("UNIT_SPELLCAST_START")
eventFrame:RegisterEvent("UNIT_SPELLCAST_CHANNEL_START")
eventFrame:RegisterEvent("UNIT_SPELLCAST_INTERRUPTED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", function(_, event, unit, castGUID, spellID)
	if event == "UNIT_SPELLCAST_START" then
		onCastStart(unit, castGUID, spellID, false)
	elseif event == "UNIT_SPELLCAST_CHANNEL_START" then
		onCastStart(unit, castGUID, spellID, true)
	elseif event == "UNIT_SPELLCAST_INTERRUPTED" then
		onInterrupted(unit, castGUID, spellID)
	elseif event == "PLAYER_REGEN_DISABLED" then
		onCombatStart()
	elseif event == "PLAYER_REGEN_ENABLED" then
		onCombatEnd()
	end
end)

function Probe:OnEnable()
	IsSecret = TP.Compat.IsSecret
end
