-- Damage done. total includes overkill (matches Details for verification);
-- useful excludes it (what the scoring engine will consume in P5).
local _, TP = ...

local band = bit.band
local max = math.max
local FRIENDLY = COMBATLOG_OBJECT_REACTION_FRIENDLY

local tracker = { subevents = {} }

-- Damage BY TARGET for the CURRENT fight: npc id (as a string) -> damage.
-- Reset at every StartFight, because the thing it exists to answer is "does
-- our by-target breakdown for THIS pull match WCL's". /tp procs prints it.
-- No memo table keyed by GUID: spawn GUIDs are unique, so that grows without
-- bound over a raid night. An anchored match on a 30-char string is cheap
-- enough for the damage hot path.
TP.DoneByTarget = {}
local function targetKey(guid)
	if not guid then
		return nil
	end
	-- Creature-0-3299-1136-9-71152-000136DF91 -> "71152" (field 6 is the npc id)
	return guid:match("^%a+%-%d+%-%d+%-%d+%-%d+%-(%d+)%-") or "other"
end

local function addDamage(seg, srcGUID, dstGUID, dstFlags, amount, overkill)
	if not amount then
		return
	end
	-- Ignore friendly-fire mechanics; dummies and mobs are neutral/hostile.
	if band(dstFlags, FRIENDLY) ~= 0 then
		return
	end
	-- ...and NEVER count damage dealt to a PLAYER, whatever the flags say. A
	-- mind-controlled ally reads HOSTILE in the combat log, so the reaction
	-- check above waves it straight through, and breaking an MC by beating on
	-- a teammate is not damage done to the encounter. Warcraft Logs does not
	-- count it either. Paragons of the Klaxxi (Kaz'tik mind-controls) is the
	-- one fight of three where our raid total ran 1.44x WCL's; Garrosh and
	-- Siegecrafter matched within 1-2% (Josh's 2026-07-30 SoO, ground truth).
	-- Whether this is the WHOLE of that gap is NOT proven - see DoneByTarget
	-- below, which the next pull settles - but counting it was wrong anyway.
	if dstGUID and dstGUID:find("^Player%-") then
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
		-- when the TANK first dealt damage: threat's pull detection uses
		-- this to tell a tank-initiated pull (slow projectile still in
		-- the air while a DPS pre-cast lands) from a real DPS pull. One
		-- lookup per event until set, then short-circuits.
		if not g.tankFirstDamage and srcGUID == guid then
			local info = TP.Roster.players[guid]
			if info and info.role == "TANK" then
				g.tankFirstDamage = GetTime() - seg.startTime
			end
		end
	end
	-- damage BY TARGET, so our numbers can be diffed against WCL's own
	-- by-target table for the same pull instead of argued about from raid
	-- totals. Added 2026-07-31: Paragons ran 1.44x WCL while Garrosh and
	-- Siegecrafter matched, and no reasoning from aggregates could say WHERE.
	local tk = targetKey(dstGUID)
	if tk then
		TP.DoneByTarget[tk] = (TP.DoneByTarget[tk] or 0) + amount
	end
	local d = acc.damage
	d.total = d.total + amount
	d.useful = d.useful + amount - max(overkill or 0, 0)
	-- per-second OWN output: the player card's fight-shape line shows
	-- each player's downtime (Josh 2026-07-24)
	if seg.startTime then
		local ob = d.out
		if not ob then
			ob = {}
			d.out = ob
		end
		local ot = math.floor(GetTime() - seg.startTime)
		ob[ot] = (ob[ot] or 0) + amount
	end
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
