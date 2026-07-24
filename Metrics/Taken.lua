-- Damage taken by roster members (tank soak metric + "Stood in bad").
-- Classic path.
local _, TP = ...

local tracker = { subevents = {} }

-- Session-wide tally of what actually hurt people, for curating
-- Data/Avoidable_*.lua ("/tp baddies" prints the top sources with IDs)
TP.TakenSpells = {}

local RECAP_SLOTS = 5 -- last hits kept per player for the death recap

local function addTaken(seg, dstGUID, amount, spellID, spellName, blocked, isSwing)
	if not amount then
		return
	end
	local acc = seg.players[dstGUID] -- players only; pet damage taken ignored
	if acc then
		acc.taken.total = acc.taken.total + amount
		-- tanking-stat ingredients (Josh 2026-07-24): shield-block value
		-- and the melee-swing denominator for the avoidance rate
		if blocked and blocked > 0 then
			acc.taken.blocked = (acc.taken.blocked or 0) + blocked
		end
		if isSwing then
			acc.taken.swings = (acc.taken.swings or 0) + 1
		end
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

-- SWING_DAMAGE suffix: amount, overkill, school, resisted, blocked, ...
tracker.subevents.SWING_DAMAGE = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4, a5)
	addTaken(seg, dstGUID, a1, nil, nil, a5, true)
end
-- SPELL/RANGE prefix: spellId, spellName, school, then the damage
-- suffix: amount, overkill, school, resisted, blocked, ...
local function spellTaken(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4, a5, a6, a7, a8)
	addTaken(seg, dstGUID, a4, a1, a2, a8)
end
tracker.subevents.SPELL_DAMAGE = spellTaken
tracker.subevents.SPELL_PERIODIC_DAMAGE = spellTaken
tracker.subevents.RANGE_DAMAGE = spellTaken
-- split/reflect damage kills people too (audit 2026-07-16: a death to
-- split damage showed a recap of stale earlier hits)
tracker.subevents.DAMAGE_SPLIT = spellTaken
tracker.subevents.DAMAGE_SHIELD = spellTaken
-- ENVIRONMENTAL suffix: environmentalType, amount
tracker.subevents.ENVIRONMENTAL_DAMAGE = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2)
	addTaken(seg, dstGUID, a2, nil, a1 and ("Environment: " .. tostring(a1)) or "Environment")
end

-- fully-avoided attacks (dodge/parry/miss): the avoidance half of the
-- tanking stat. Full absorbs arrive as SPELL_ABSORBED, not here.
local AVOIDED = { DODGE = true, PARRY = true, MISS = true }
local function addMiss(seg, dstGUID, missType)
	if not (missType and AVOIDED[missType]) then
		return
	end
	local acc = seg.players[dstGUID]
	if acc then
		acc.taken.avoided = (acc.taken.avoided or 0) + 1
	end
end
-- SWING_MISSED suffix: missType, isOffHand, amountMissed
tracker.subevents.SWING_MISSED = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	addMiss(seg, dstGUID, a1)
end
-- SPELL/RANGE_MISSED prefix spellId, spellName, school, then missType
local function spellMissed(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4)
	addMiss(seg, dstGUID, a4)
end
tracker.subevents.SPELL_MISSED = spellMissed
tracker.subevents.RANGE_MISSED = spellMissed

tracker.InitPlayer = function(acc)
	acc.taken = { total = 0, avoidable = 0, ring = {}, ringAt = 0 }
end
tracker.MergePlayer = function(dst, src)
	dst.taken.total = dst.taken.total + src.taken.total
	dst.taken.avoidable = (dst.taken.avoidable or 0) + (src.taken.avoidable or 0)
	dst.taken.blocked = (dst.taken.blocked or 0) + (src.taken.blocked or 0)
	dst.taken.swings = (dst.taken.swings or 0) + (src.taken.swings or 0)
	dst.taken.avoided = (dst.taken.avoided or 0) + (src.taken.avoided or 0)
end

TP.Metrics:Register(tracker)
