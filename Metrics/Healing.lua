-- Effective healing (amount minus overhealing) from CLEU. Classic path.
local _, TP = ...

local tracker = { subevents = {} }

-- SPELL_HEAL suffix: spellId, spellName, school, amount, overhealing, absorbed, critical
local function heal(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4, a5)
	if not a4 then
		return
	end
	local guid = TP.Roster:ResolveGUID(srcGUID)
	if not guid then
		return
	end
	local acc = seg.players[guid]
	if not acc then
		return
	end
	local effective = a4 - (a5 or 0)
	acc.healing.effective = acc.healing.effective + effective
	acc.healing.overheal = acc.healing.overheal + (a5 or 0)
	-- self vs others: "Great off-healing" and "Great self-sustain" are
	-- different compliments (pet heals landing on the owner count as self)
	local dstPlayer = TP.Roster:ResolveGUID(dstGUID)
	if dstPlayer == guid then
		acc.healing.selfPart = acc.healing.selfPart + effective
	end
	-- healing focus: how much landed on tanks (WCL's to-tanks split)
	if dstPlayer then
		local info = TP.Roster.players[dstPlayer]
		if info and info.role == "TANK" then
			acc.healing.toTanks = acc.healing.toTanks + effective
		end
	end
	if TP.POTION_HEALS[a1] then
		acc.potions.healing = acc.potions.healing + effective
	end
end
tracker.subevents.SPELL_HEAL = heal
tracker.subevents.SPELL_PERIODIC_HEAL = heal

tracker.InitPlayer = function(acc)
	acc.healing = { effective = 0, selfPart = 0, toTanks = 0, overheal = 0 }
	acc.potions = { healing = 0 }
end
tracker.MergePlayer = function(dst, src)
	dst.healing.effective = dst.healing.effective + src.healing.effective
	dst.healing.selfPart = dst.healing.selfPart + (src.healing.selfPart or 0)
	dst.healing.toTanks = dst.healing.toTanks + (src.healing.toTanks or 0)
	dst.healing.overheal = (dst.healing.overheal or 0) + (src.healing.overheal or 0)
	dst.potions.healing = dst.potions.healing + src.potions.healing
end

TP.Metrics:Register(tracker)
