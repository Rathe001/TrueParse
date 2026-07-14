-- Damage taken by roster members (tank soak metric + "Stood in bad").
-- Classic path.
local _, TP = ...

local tracker = { subevents = {} }

-- Session-wide tally of what actually hurt people, for curating
-- Data/Avoidable_*.lua ("/tp baddies" prints the top sources with IDs)
TP.TakenSpells = {}

local RECAP_SLOTS = 5 -- last hits kept per player for the death recap

local function addTaken(seg, dstGUID, amount, spellID, spellName)
	if not amount then
		return
	end
	local acc = seg.players[dstGUID] -- players only; pet damage taken ignored
	if acc then
		acc.taken.total = acc.taken.total + amount
		local avoidable = spellID and TP.AVOIDABLE and TP.AVOIDABLE[spellID] or false
		if spellID then
			if avoidable then
				acc.taken.avoidable = acc.taken.avoidable + amount
				-- by second: a called wipe stops counting from the call
				local ab = acc.taken.avB
				if not ab then
					ab = {}
					acc.taken.avB = ab
				end
				local t = math.floor(GetTime() - (seg.startTime or GetTime()))
				ab[t] = (ab[t] or 0) + amount
			end
			local e = TP.TakenSpells[spellID]
			if not e then
				e = { name = spellName, total = 0, hits = 0 }
				TP.TakenSpells[spellID] = e
			end
			e.total = e.total + amount
			e.hits = e.hits + 1
		end
		-- ring buffer of the last hits: UNIT_DIED snapshots it into the
		-- death recap (slot tables are reused; the hot path allocates
		-- nothing after the first lap)
		local ring = acc.taken.ring
		local i = (acc.taken.ringAt % RECAP_SLOTS) + 1
		acc.taken.ringAt = i
		local slot = ring[i]
		if not slot then
			slot = {}
			ring[i] = slot
		end
		slot.t = seg.startTime and (GetTime() - seg.startTime) or 0
		slot.spell = spellName or "Melee"
		slot.amount = amount
		slot.avoidable = avoidable or nil
	end
end

-- Ordered copy of the ring, oldest first (Utility's UNIT_DIED calls this)
function tracker.RecapFor(acc)
	local ring = acc.taken and acc.taken.ring
	if not ring or #ring == 0 then
		return nil
	end
	local out = {}
	local at = acc.taken.ringAt
	for k = 1, RECAP_SLOTS do
		local slot = ring[((at + k - 1) % RECAP_SLOTS) + 1]
		if slot and slot.spell then
			out[#out + 1] = { t = slot.t, spell = slot.spell, amount = slot.amount,
				avoidable = slot.avoidable }
		end
	end
	return #out > 0 and out or nil
end
TP.TakenRecap = tracker.RecapFor

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
	acc.taken = { total = 0, avoidable = 0, ring = {}, ringAt = 0 }
end
tracker.MergePlayer = function(dst, src)
	dst.taken.total = dst.taken.total + src.taken.total
	dst.taken.avoidable = (dst.taken.avoidable or 0) + (src.taken.avoidable or 0)
end

TP.Metrics:Register(tracker)
