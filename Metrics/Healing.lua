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
	acc.healing.effective = acc.healing.effective + a4 - (a5 or 0)
end
tracker.subevents.SPELL_HEAL = heal
tracker.subevents.SPELL_PERIODIC_HEAL = heal

tracker.InitPlayer = function(acc)
	acc.healing = { effective = 0 }
end
tracker.MergePlayer = function(dst, src)
	dst.healing.effective = dst.healing.effective + src.healing.effective
end

TP.Metrics:Register(tracker)
