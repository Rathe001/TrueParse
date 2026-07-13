-- Interrupts, dispels, deaths, and combat rezzes from CLEU. Classic path.
--
-- Interrupt OPPORTUNITIES (2026-07-13): an enemy cast counts as an
-- opportunity when its spellID is known-kickable — and the list is
-- self-curating: any spell anyone EVER interrupts is learned forever
-- (db.global.kickableSpells, the /tp baddies pattern). Kicked casts and
-- known-kickable casts that completed both count; the group's coverage
-- ("kicked 7 of 9") feeds the kick adjustment's intensity and the
-- bullets. Undercounts early, converges with play.
local _, TP = ...

local tracker = { subevents = {} }

-- enemy cast in flight: [enemyGUID] = { seg, spellID, at }
local pendingCasts = {}
-- harmful aura landed on a player: [dstGUID .. spellID] = { seg, at }
-- (dispel reaction time = dispel event minus this)
local debuffAt = {}
local lastSeg

local function segCheck(seg)
	if seg ~= lastSeg then
		lastSeg = seg
		wipe(pendingCasts)
		wipe(debuffAt)
	end
end

local function learnedKickable()
	local g = TP.Addon and TP.Addon.db and TP.Addon.db.global
	if not g then
		return nil
	end
	g.kickableSpells = g.kickableSpells or {}
	return g.kickableSpells
end

local HOSTILE = COMBATLOG_OBJECT_REACTION_HOSTILE
local band = bit.band

tracker.subevents.SPELL_CAST_START = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	segCheck(seg)
	if not a1 or band(srcFlags or 0, HOSTILE) == 0 then
		return
	end
	local p = pendingCasts[srcGUID]
	if not p then
		p = {}
		pendingCasts[srcGUID] = p
	end
	p.seg, p.spellID, p.at = seg, a1, GetTime()
end

-- SPELL_INTERRUPT suffix: kickSpellID, kickName, kickSchool,
-- interruptedSpellID, interruptedName, interruptedSchool
tracker.subevents.SPELL_INTERRUPT = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4)
	segCheck(seg)
	local guid = TP.Roster:ResolveGUID(srcGUID)
	local acc = guid and seg.players[guid]
	if acc then
		acc.interrupts.kicks = acc.interrupts.kicks + 1
	end
	if a4 then
		local known = learnedKickable()
		if known then
			known[a4] = true
		end
	end
	local g = seg.group
	g.kickOpps = (g.kickOpps or 0) + 1
	g.kicksLanded = (g.kicksLanded or 0) + 1
	pendingCasts[dstGUID] = nil
end

-- enemy cast that finished: if we know it was kickable, it got through
tracker.subevents.SPELL_CAST_SUCCESS = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	local p = pendingCasts[srcGUID]
	if not p or p.seg ~= seg or p.spellID ~= a1 then
		return
	end
	pendingCasts[srcGUID] = nil
	local known = learnedKickable()
	if known and known[a1] then
		local g = seg.group
		g.kickOpps = (g.kickOpps or 0) + 1
		g.kicksThrough = (g.kicksThrough or 0) + 1
	end
end

-- SPELL_AURA_APPLIED suffix: spellID, name, school, auraType
tracker.subevents.SPELL_AURA_APPLIED = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4)
	segCheck(seg)
	if a4 ~= "DEBUFF" or not a1 or not seg.players[dstGUID] then
		return
	end
	local key = dstGUID .. a1
	local mark = debuffAt[key]
	if not mark then
		mark = {}
		debuffAt[key] = mark
	end
	mark.seg, mark.at = seg, GetTime()
end

-- SPELL_DISPEL suffix: spellID, name, school, removedSpellID, ...
tracker.subevents.SPELL_DISPEL = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4)
	segCheck(seg)
	local guid = TP.Roster:ResolveGUID(srcGUID)
	local acc = guid and seg.players[guid]
	if acc then
		acc.dispels.count = acc.dispels.count + 1
		-- reaction time: how long that debuff sat on the target
		local key = a4 and (dstGUID .. a4)
		local mark = key and debuffAt[key]
		if mark and mark.seg == seg then
			local d = acc.dispels
			d.reactSum = (d.reactSum or 0) + (GetTime() - mark.at)
			d.reactN = (d.reactN or 0) + 1
			debuffAt[key] = nil
		end
	end
end

tracker.subevents.UNIT_DIED = function(seg, srcGUID, dstGUID)
	local acc = seg.players[dstGUID]
	if not acc then
		return
	end
	local info = TP.Roster.players[dstGUID]
	if info and UnitIsFeignDeath and UnitIsFeignDeath(info.unit) then
		return -- hunters fake their deaths
	end
	acc.deaths.total = acc.deaths.total + 1
	if seg.startTime then
		acc.deaths.lastTime = GetTime() - seg.startTime
	end
	-- death recap: the last hits, snapshotted at the moment of death
	-- (first death only: the recap that matters is the one that stuck)
	if not acc.deaths.recap and TP.TakenRecap then
		acc.deaths.recap = TP.TakenRecap(acc)
	end
end

-- combat rez: casting it is group contribution, full stop
tracker.subevents.SPELL_RESURRECT = function(seg, srcGUID)
	local guid = TP.Roster:ResolveGUID(srcGUID)
	local acc = guid and seg.players[guid]
	if acc then
		acc.utility = acc.utility or {}
		acc.utility.rezzes = (acc.utility.rezzes or 0) + 1
	end
end

tracker.InitPlayer = function(acc)
	acc.interrupts = { kicks = 0 }
	acc.dispels = { count = 0 }
	acc.deaths = { total = 0 }
end
tracker.MergePlayer = function(dst, src)
	dst.interrupts.kicks = dst.interrupts.kicks + src.interrupts.kicks
	dst.dispels.count = dst.dispels.count + src.dispels.count
	dst.deaths.total = dst.deaths.total + src.deaths.total
end

TP.Metrics:Register(tracker)
