-- EXPERIMENT 1 (concluded 2026-07-07, Windrunner Spire follower dungeon):
-- can TrueParse count interrupt OPPORTUNITIES itself on Midnight?
-- VERDICT: no. UNIT_SPELLCAST_* events never fire for hostile NPCs (0 casts,
-- 0 secrets, 0 interrupted across many caster pulls), and group aura reads
-- are ~90% secret mid-combat. Interrupt scoring therefore uses C_DamageMeter
-- kick counts normalized among kick-capable specs, and buff checks must be
-- pre-pull snapshots (out-of-combat reads are never secret).
--
-- EXPERIMENT 2 (concluded 2026-07-08, Magisters' Terrace Heroic, 10 pulls):
-- do FRIENDLY group members' cast events reach addons readably in combat?
-- VERDICT: split. YOUR OWN casts are fully readable (~830 events, 0 secret).
-- OTHER group members' casts fire but every spellID is secret (126/126).
-- Hostile cast events also fire in real dungeons with secret payloads
-- (refining Experiment 1: events exist, data doesn't). Conclusion: group
-- defensive/CC credit is impossible on retail; personal-only tracking (own
-- defensives/utility feeding the coach line) remains possible. Classic can
-- do both via CLEU.
--
-- Default off. Toggle: /tp probe. Live dump: /tp probe status.
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
	selfCasts = 0, selfSecret = 0, groupCasts = 0, groupSecret = 0,
}
local seenCasts = {}
local seenInterrupts = {}
local auraTicker
local sampleSpells = {} -- a few readable group spellIDs, as proof of quality

local function reset()
	wipe(seenCasts)
	wipe(seenInterrupts)
	wipe(sampleSpells)
	for k in pairs(counts) do
		counts[k] = 0
	end
end

local function enabled()
	return IsSecret ~= nil and TP.Addon.db and TP.Addon.db.profile.probe
end

-- Friendly casts, only while in combat (out of combat nothing is secret and
-- the answer is already known). Canonical unit tokens only — the same cast
-- also fires on nameplate/target tokens and would double-count.
local function onFriendlyCast(unit, spellID)
	if not enabled() or not InCombatLockdown() then
		return
	end
	if unit == "player" then
		counts.selfCasts = counts.selfCasts + 1
		if IsSecret(spellID) then
			counts.selfSecret = counts.selfSecret + 1
		end
	elseif unit:match("^party%d$") or unit:match("^raid%d+$") then
		counts.groupCasts = counts.groupCasts + 1
		if IsSecret(spellID) then
			counts.groupSecret = counts.groupSecret + 1
		elseif spellID and #sampleSpells < 5 then
			local known = false
			for _, id in ipairs(sampleSpells) do
				if id == spellID then
					known = true
				end
			end
			if not known then
				sampleSpells[#sampleSpells + 1] = spellID
			end
		end
	end
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

-- Prints AND persists to SavedVariables, so probe verdicts survive the
-- session and can be analyzed from disk.
local function emit(line)
	TP.Addon:Print(line)
	local db = TP.Addon.db.global
	db.probeLog = db.probeLog or {}
	table.insert(db.probeLog, 1, ("%s %s"):format(date("%m-%d %H:%M"), line))
	for i = #db.probeLog, 31, -1 do
		table.remove(db.probeLog, i)
	end
end

function Probe:Report(force)
	local observed = counts.casts + counts.secret + counts.auraReads + counts.errors
		+ counts.selfCasts + counts.groupCasts
	if observed == 0 then
		if force then
			TP.Addon:Print("Probe: nothing observed yet (no cast events, no aura samples).")
		end
		return
	end
	emit(("Probe: enemy casts %d (interruptible %d, secret %d), interrupted %d · aura reads %d (%d secret) · errors %d"):format(
		counts.casts, counts.interruptible, counts.secret, counts.interrupted,
		counts.auraReads, counts.auraSecrets, counts.errors))
	emit(("Probe friendly (in combat): you %d casts (%d secret) · group %d casts (%d secret)"):format(
		counts.selfCasts, counts.selfSecret, counts.groupCasts, counts.groupSecret))
	if #sampleSpells > 0 then
		local names = {}
		for _, id in ipairs(sampleSpells) do
			local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
				or (GetSpellInfo and GetSpellInfo(id))
			names[#names + 1] = ("%s(%d)"):format(name or "?", id)
		end
		emit("Probe readable group spells: " .. table.concat(names, ", "))
	end
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
eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", function(_, event, unit, castGUID, spellID)
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		onFriendlyCast(unit, spellID)
	elseif event == "UNIT_SPELLCAST_START" then
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
