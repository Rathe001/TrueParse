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
	-- per-second GROUP output: wipe-call detection reads this (output
	-- collapse = the raid stopped trying)
	local g = seg.group
	if g and seg.startTime then
		local gb = g.out
		if not gb then
			gb = {}
			g.out = gb
		end
		local t = math.floor(GetTime() - seg.startTime)
		gb[t] = (gb[t] or 0) + amount
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

-- Session-wide tally of damage BY spell, for curating proc exclusions
-- ("/tp procs" prints the top sources with IDs — the TakenSpells twin)
TP.DoneSpells = {}

-- SPELL/RANGE prefix adds spellId, spellName, school before the damage suffix:
-- spellId, spellName, school, amount, overkill, ...
local function spellDamage(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4, a5)
	-- tally GROUP sources only (audit 2026-07-16: boss AoE totals were
	-- drowning player procs out of /tp procs and its login prune)
	if a1 and a4 and TP.Roster:ResolveGUID(srcGUID) then
		local e = TP.DoneSpells[a1]
		if not e then
			e = { name = a2, total = 0 }
			TP.DoneSpells[a1] = e
		end
		e.total = e.total + a4
		-- temporary-empowerment procs (celestial buffs): RNG windfall,
		-- not performance — excluded from every scored number
		if TP.IsExcludedProc and TP.IsExcludedProc(a1, a2) then
			return
		end
	end
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
