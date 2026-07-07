-- Interrupts, dispels, and deaths from CLEU. Classic path.
local _, TP = ...

local tracker = { subevents = {} }

tracker.subevents.SPELL_INTERRUPT = function(seg, srcGUID)
	local guid = TP.Roster:ResolveGUID(srcGUID)
	local acc = guid and seg.players[guid]
	if acc then
		acc.interrupts.kicks = acc.interrupts.kicks + 1
	end
end

tracker.subevents.SPELL_DISPEL = function(seg, srcGUID)
	local guid = TP.Roster:ResolveGUID(srcGUID)
	local acc = guid and seg.players[guid]
	if acc then
		acc.dispels.count = acc.dispels.count + 1
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
