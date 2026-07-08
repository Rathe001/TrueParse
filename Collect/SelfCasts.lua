-- Records the player's OWN defensive cooldown usage per combat window.
-- Own cast events are never secret (probe-verified), so this is the one
-- slice of "cooldown tracking" retail allows — each TrueParse user donates
-- their own counts to the group via Sync.
local _, TP = ...

local SelfCasts = {}
TP.SelfCasts = SelfCasts

local combatStart
local defensivesUsed = 0

local frame = CreateFrame("Frame")
frame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:RegisterEvent("PLAYER_REGEN_ENABLED")
frame:SetScript("OnEvent", function(_, event, unit, _, spellID)
	if event == "UNIT_SPELLCAST_SUCCEEDED" then
		if unit == "player" and combatStart and TP.DEFENSIVES and TP.DEFENSIVES[spellID] then
			defensivesUsed = defensivesUsed + 1
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		combatStart = GetTime()
		defensivesUsed = 0
	elseif event == "PLAYER_REGEN_ENABLED" then
		if combatStart then
			local duration = GetTime() - combatStart
			combatStart = nil
			if duration >= 10 and TP.Sync.RecordFightReport then
				TP.Sync:RecordFightReport(UnitGUID("player"), duration, defensivesUsed)
				TP.Sync:BroadcastFightReport(duration, defensivesUsed)
			end
		end
	end
end)

function SelfCasts:OnEnable()
	-- registrations above are load-time; nothing to do
end
