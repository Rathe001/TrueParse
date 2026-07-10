-- Damage done. total includes overkill (matches Details for verification);
-- useful excludes it (what the scoring engine will consume in P5).
local _, TP = ...

local band = bit.band
local max = math.max
local FRIENDLY = COMBATLOG_OBJECT_REACTION_FRIENDLY

local tracker = { subevents = {} }

local function addDamage(seg, srcGUID, dstGUID, dstFlags, amount, overkill)
	if not amount then
		return
	end
	-- Ignore friendly-fire mechanics; dummies and mobs are neutral/hostile.
	if band(dstFlags, FRIENDLY) ~= 0 then
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
	local d = acc.damage
	d.total = d.total + amount
	d.useful = d.useful + amount - max(overkill or 0, 0)
	-- boss vs adds split, when the encounter told us who the boss is
	if seg.bossGUIDs and seg.bossGUIDs[dstGUID] then
		d.toBoss = d.toBoss + amount - max(overkill or 0, 0)
	end
end

-- SWING_DAMAGE suffix: amount, overkill, ...
tracker.subevents.SWING_DAMAGE = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2)
	addDamage(seg, srcGUID, dstGUID, dstFlags, a1, a2)
end

-- SPELL/RANGE prefix adds spellId, spellName, school before the damage suffix:
-- spellId, spellName, school, amount, overkill, ...
local function spellDamage(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4, a5)
	addDamage(seg, srcGUID, dstGUID, dstFlags, a4, a5)
end
tracker.subevents.SPELL_DAMAGE = spellDamage
tracker.subevents.SPELL_PERIODIC_DAMAGE = spellDamage
tracker.subevents.RANGE_DAMAGE = spellDamage
tracker.subevents.DAMAGE_SHIELD = spellDamage
tracker.subevents.DAMAGE_SPLIT = spellDamage

tracker.InitPlayer = function(acc)
	acc.damage = { total = 0, useful = 0, toBoss = 0 }
end

tracker.MergePlayer = function(dst, src)
	dst.damage.total = dst.damage.total + src.damage.total
	dst.damage.useful = dst.damage.useful + src.damage.useful
	dst.damage.toBoss = dst.damage.toBoss + (src.damage.toBoss or 0)
end

TP.Metrics:Register(tracker)
