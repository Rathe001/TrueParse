-- Bloodlust-window usage, from CLEU (Classic path). When a lust buff goes
-- out, a 40s window opens on the segment; offensive cooldown casts and DPS
-- potion buffs inside it are tallied per player. Bullets phrase the result
-- for DPS only - informational, never scored.
local _, TP = ...

local tracker = { subevents = {} }

local LUST_DURATION = 40

tracker.subevents.SPELL_AURA_APPLIED = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	if not a1 then
		return
	end
	if TP.LUST and TP.LUST[a1] then
		seg.lustSeen = true
		seg.lustUntil = GetTime() + LUST_DURATION
		return
	end
	if TP.DPS_POTIONS and TP.DPS_POTIONS[a1]
		and seg.lustUntil and GetTime() < seg.lustUntil then
		local acc = seg.players[dstGUID]
		if acc and acc.lust then
			acc.lust.potion = true
		end
	end
end

tracker.subevents.SPELL_CAST_SUCCESS = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	if not a1 or not (TP.OFFENSIVE_CDS and TP.OFFENSIVE_CDS[a1]) then
		return
	end
	local acc = seg.players[srcGUID] -- players only; pet casts don't count
	if not (acc and acc.lust) then
		return
	end
	acc.lust.totalCasts = acc.lust.totalCasts + 1
	if seg.lustUntil and GetTime() < seg.lustUntil then
		acc.lust.casts = acc.lust.casts + 1
	end
end

tracker.InitPlayer = function(acc)
	acc.lust = { casts = 0, totalCasts = 0, potion = false }
end
tracker.MergePlayer = function(dst, src)
	dst.lust.casts = dst.lust.casts + (src.lust and src.lust.casts or 0)
	dst.lust.totalCasts = (dst.lust.totalCasts or 0) + (src.lust and src.lust.totalCasts or 0)
	dst.lust.potion = dst.lust.potion or (src.lust and src.lust.potion) or false
end

TP.Metrics:Register(tracker)
