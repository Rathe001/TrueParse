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

local frame = CreateFrame("Frame")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:RegisterEvent("PLAYER_DEAD")
frame:SetScript("OnEvent", function(_, event, unit, _, spellID)
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		if unit == "player" and combatStart and TP.DEFENSIVES and TP.DEFENSIVES[spellID] then
			defensivesUsed = defensivesUsed + 1
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		combatStart = GetTime()
		defensivesUsed = 0
		readyAtDeath = -1
		local ok, count = pcall(countConsumables)
		consumablesAtPull = ok and count or 0
	elseif event == "PLAYER_DEAD" then
		if combatStart then
			local ok, count = pcall(countReadyDefensives)
			readyAtDeath = ok and count or -1
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if combatStart then
			local duration = GetTime() - combatStart
			combatStart = nil
			if duration >= 10 and TP.Sync.RecordFightReport then
				TP.Sync:RecordFightReport(UnitGUID("player"), duration, defensivesUsed, consumablesAtPull, readyAtDeath)
				TP.Sync:BroadcastFightReport(duration, defensivesUsed, consumablesAtPull, readyAtDeath)
			end
		end
	end
end)

function SelfCasts:OnEnable()
	-- registrations above are load-time; nothing to do
end
