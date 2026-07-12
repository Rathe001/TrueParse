-- "Always be casting" proxy from CLEU (Classic path). Each action event
-- credits up to one GCD-ish window since the player's previous action, so
-- back-to-back casting accrues real time and idle stretches credit a
-- single window. activity% = credited time / fight duration - the same
-- headline WoWAnalyzer leads with, at proxy precision.
local _, TP = ...

local tracker = { subevents = {} }

local CAP = 1.6 -- one hasted-ish GCD

local function act(seg, srcGUID)
	local acc = seg.players[srcGUID] -- players only; pet actions don't count
	if not acc then
		return
	end
	local a = acc.activity
	local t = GetTime()
	if a.last then
		a.active = a.active + math.min(t - a.last, CAP)
	else
		a.active = a.active + CAP
	end
	a.last = t
end

tracker.subevents.SPELL_CAST_SUCCESS = function(seg, srcGUID)
	act(seg, srcGUID)
end
tracker.subevents.SWING_DAMAGE = function(seg, srcGUID)
	act(seg, srcGUID) -- auto-attacks = on-target uptime for melee
end
tracker.subevents.RANGE_DAMAGE = function(seg, srcGUID)
	act(seg, srcGUID)
end

tracker.InitPlayer = function(acc)
	acc.activity = { active = 0 }
end
tracker.MergePlayer = function(dst, src)
	dst.activity.active = dst.activity.active + (src.activity and src.activity.active or 0)
end

TP.Metrics:Register(tracker)
