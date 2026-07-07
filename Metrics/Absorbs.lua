-- Absorbs granted (shields consumed) from CLEU SPELL_ABSORBED. Classic path.
-- The subevent has two payload shapes: swing-sourced damage starts with the
-- absorber GUID; spell-sourced damage prefixes the damaging spell's id/name/
-- school first, shifting everything by three.
local _, TP = ...

local tracker = { subevents = {} }

tracker.subevents.SPELL_ABSORBED = function(seg, srcGUID, dstGUID, srcFlags, dstFlags,
		a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
	local absorberGUID, amount
	if type(a1) == "number" then
		-- spell variant: dmgSpellId, dmgSpellName, dmgSchool, absorberGUID,
		-- absorberName, absorberFlags, absorberRaidFlags, shieldSpellId,
		-- shieldSpellName, shieldSchool, amount
		absorberGUID, amount = a4, a11
	else
		-- swing variant: absorberGUID, absorberName, absorberFlags,
		-- absorberRaidFlags, shieldSpellId, shieldSpellName, shieldSchool, amount
		absorberGUID, amount = a1, a8
	end
	if not absorberGUID or type(amount) ~= "number" then
		return
	end
	local guid = TP.Roster:ResolveGUID(absorberGUID)
	local acc = guid and seg.players[guid]
	if acc then
		acc.absorbs.granted = acc.absorbs.granted + amount
	end
end

tracker.InitPlayer = function(acc)
	acc.absorbs = { granted = 0 }
end
tracker.MergePlayer = function(dst, src)
	dst.absorbs.granted = dst.absorbs.granted + src.absorbs.granted
end

TP.Metrics:Register(tracker)
