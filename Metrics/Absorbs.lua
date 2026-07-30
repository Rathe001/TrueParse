-- Absorbs granted (shields consumed) from CLEU SPELL_ABSORBED. Classic path.
-- The subevent has two payload shapes: swing-sourced damage starts with the
-- absorber GUID; spell-sourced damage prefixes the damaging spell's id/name/
-- school first, shifting everything by three.
local _, TP = ...

local tracker = { subevents = {} }

-- Session-wide tally of absorbs BY SHIELD, the twin of TP.HealSpells and
-- TP.DoneSpells: /tp procs prints it so a boss-granted shield can be named
-- and retired through Data/ProcExclusions.
TP.AbsorbSpells = {}

tracker.subevents.SPELL_ABSORBED = function(seg, srcGUID, dstGUID, srcFlags, dstFlags,
		a1, a2, a3, a4, a5, a6, a7, a8, a9, a10, a11)
	local absorberGUID, amount, shieldID, shieldName
	if type(a1) == "number" then
		-- spell variant: dmgSpellId, dmgSpellName, dmgSchool, absorberGUID,
		-- absorberName, absorberFlags, absorberRaidFlags, shieldSpellId,
		-- shieldSpellName, shieldSchool, amount
		absorberGUID, amount, shieldID, shieldName = a4, a11, a8, a9
	else
		-- swing variant: absorberGUID, absorberName, absorberFlags,
		-- absorberRaidFlags, shieldSpellId, shieldSpellName, shieldSchool, amount
		absorberGUID, amount, shieldID, shieldName = a1, a8, a5, a6
	end
	if not absorberGUID or type(amount) ~= "number" then
		return
	end
	-- WHICH SHIELD ate the damage. Absorbs used to be counted without ever
	-- looking at the spell, and a boss-granted shield is indistinguishable
	-- from a healer's without it: on Malkorok, where Ancient Barrier puts an
	-- absorb on EVERY player, the wearer is the "absorber", so a DPS who
	-- healed 10 was credited with 4,057,095 of healing output (Josh
	-- 2026-07-30). Tallied like TP.HealSpells / TP.DoneSpells so /tp procs
	-- can name the offender, and run through the same exclusion list, so
	-- retiring one is a data edit rather than a code change.
	if shieldID then
		local e = TP.AbsorbSpells[shieldID]
		if not e then
			e = { name = shieldName, total = 0 }
			TP.AbsorbSpells[shieldID] = e
		end
		e.total = e.total + amount
		if TP.IsExcludedProc and TP.IsExcludedProc(shieldID, shieldName) then
			return
		end
	end
	local guid = TP.Roster:ResolveGUID(absorberGUID)
	local acc = guid and seg.players[guid]
	if acc then
		acc.absorbs.granted = acc.absorbs.granted + amount
	end
	-- the VICTIM's view feeds the tanking stat (Josh 2026-07-24): how
	-- much damage shields ate for them, and how much of that was their
	-- own shield (self-sufficiency, not healer credit)
	local vic = TP.Roster:ResolveGUID(dstGUID)
	local vacc = vic and seg.players[vic]
	if vacc then
		vacc.absorbs.taken = (vacc.absorbs.taken or 0) + amount
		if vic == guid then
			vacc.absorbs.selfTaken = (vacc.absorbs.selfTaken or 0) + amount
		end
	end
end

tracker.InitPlayer = function(acc)
	acc.absorbs = { granted = 0 }
end
tracker.MergePlayer = function(dst, src)
	dst.absorbs.granted = dst.absorbs.granted + src.absorbs.granted
	dst.absorbs.taken = (dst.absorbs.taken or 0) + (src.absorbs.taken or 0)
	dst.absorbs.selfTaken = (dst.absorbs.selfTaken or 0) + (src.absorbs.selfTaken or 0)
end

TP.Metrics:Register(tracker)
