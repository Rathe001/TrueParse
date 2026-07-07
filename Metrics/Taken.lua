-- Damage taken by roster members (tank soak metric). Classic path.
local _, TP = ...

local tracker = { subevents = {} }

local function addTaken(seg, dstGUID, amount)
	if not amount then
		return
	end
	local acc = seg.players[dstGUID] -- players only; pet damage taken ignored
	if acc then
		acc.taken.total = acc.taken.total + amount
	end
end

-- SWING_DAMAGE suffix: amount, ...
tracker.subevents.SWING_DAMAGE = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	addTaken(seg, dstGUID, a1)
end
-- SPELL/RANGE prefix: spellId, spellName, school, amount, ...
local function spellTaken(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4)
	addTaken(seg, dstGUID, a4)
end
tracker.subevents.SPELL_DAMAGE = spellTaken
tracker.subevents.SPELL_PERIODIC_DAMAGE = spellTaken
tracker.subevents.RANGE_DAMAGE = spellTaken

tracker.InitPlayer = function(acc)
	acc.taken = { total = 0 }
end
tracker.MergePlayer = function(dst, src)
	dst.taken.total = dst.taken.total + src.taken.total
end

TP.Metrics:Register(tracker)
