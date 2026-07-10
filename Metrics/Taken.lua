-- Damage taken by roster members (tank soak metric + "Stood in bad").
-- Classic path.
local _, TP = ...

local tracker = { subevents = {} }

-- Session-wide tally of what actually hurt people, for curating
-- Data/Avoidable_*.lua ("/tp baddies" prints the top sources with IDs)
TP.TakenSpells = {}

local function addTaken(seg, dstGUID, amount, spellID, spellName)
	if not amount then
		return
	end
	local acc = seg.players[dstGUID] -- players only; pet damage taken ignored
	if acc then
		acc.taken.total = acc.taken.total + amount
		if spellID then
			if TP.AVOIDABLE and TP.AVOIDABLE[spellID] then
				acc.taken.avoidable = acc.taken.avoidable + amount
			end
			local e = TP.TakenSpells[spellID]
			if not e then
				e = { name = spellName, total = 0, hits = 0 }
				TP.TakenSpells[spellID] = e
			end
			e.total = e.total + amount
			e.hits = e.hits + 1
		end
	end
end

-- SWING_DAMAGE suffix: amount, ...
tracker.subevents.SWING_DAMAGE = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	addTaken(seg, dstGUID, a1)
end
-- SPELL/RANGE prefix: spellId, spellName, school, amount, ...
local function spellTaken(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4)
	addTaken(seg, dstGUID, a4, a1, a2)
end
tracker.subevents.SPELL_DAMAGE = spellTaken
tracker.subevents.SPELL_PERIODIC_DAMAGE = spellTaken
tracker.subevents.RANGE_DAMAGE = spellTaken

tracker.InitPlayer = function(acc)
	acc.taken = { total = 0, avoidable = 0 }
end
tracker.MergePlayer = function(dst, src)
	dst.taken.total = dst.taken.total + src.taken.total
	dst.taken.avoidable = (dst.taken.avoidable or 0) + (src.taken.avoidable or 0)
end

TP.Metrics:Register(tracker)
