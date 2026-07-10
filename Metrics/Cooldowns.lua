-- Defensive cooldown casts, from CLEU (Classic path). On Classic every
-- player's casts are visible in the combat log — unlike retail, where
-- other players' casts are secret and defensives are self-reported over
-- Sync. This fills the same metrics.defensives field for EVERYONE.
local _, TP = ...

local tracker = { subevents = {} }

-- SPELL_CAST_SUCCESS suffix: spellId, spellName, school
tracker.subevents.SPELL_CAST_SUCCESS = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	if not a1 or not TP.DEFENSIVES or not TP.DEFENSIVES[a1] then
		return
	end
	local guid = TP.Roster:ResolveGUID(srcGUID)
	if not guid or guid ~= srcGUID then
		return -- pets don't cast player defensives; require the player
	end
	local acc = seg.players[guid]
	if acc then
		acc.cooldowns.defensives = acc.cooldowns.defensives + 1
	end
end

tracker.InitPlayer = function(acc)
	acc.cooldowns = { defensives = 0 }
end
tracker.MergePlayer = function(dst, src)
	dst.cooldowns.defensives = dst.cooldowns.defensives + (src.cooldowns and src.cooldowns.defensives or 0)
end

TP.Metrics:Register(tracker)
