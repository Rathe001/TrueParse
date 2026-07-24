-- "Always be casting" proxy from CLEU (Classic path). Each action event
-- credits up to one GCD-ish window since the player's previous action, so
-- back-to-back casting accrues real time and idle stretches credit a
-- single window. Hardcasts are the exception: a completed cast credits its
-- full cast time (matched via SPELL_CAST_START), because a 2s Wrath spent
-- casting is 2s of activity, not one GCD's worth. activity% = credited
-- time / fight duration - the same headline WoWAnalyzer leads with, at
-- proxy precision.
local _, TP = ...

local tracker = { subevents = {} }

local CAP = 1.6 -- one hasted-ish GCD
local CAST_CAP = 10 -- sanity ceiling: no single hardcast is longer than this

local function act(seg, srcGUID, spellId)
	local acc = seg.players[srcGUID] -- players only; pet actions don't count
	if not acc then
		return
	end
	local a = acc.activity
	local t = GetTime()
	local cap = CAP
	if spellId and a.castSpell == spellId and a.castStart then
		-- Completed hardcast: the whole cast bar was activity. A cancelled
		-- cast never matches (its success needs a fresh SPELL_CAST_START,
		-- which overwrites), so idle-after-cancel can't inflate this.
		local dur = t - a.castStart
		if dur > CAP and dur < CAST_CAP then
			cap = dur
		end
		a.castStart = nil
	end
	if a.last then
		a.active = a.active + math.min(t - a.last, cap)
	else
		a.active = a.active + cap
	end
	a.last = t
end

tracker.subevents.SPELL_CAST_START = function(seg, srcGUID, _, _, _, spellId)
	local acc = seg.players[srcGUID]
	if not acc then
		return
	end
	local a = acc.activity
	a.castStart = GetTime()
	a.castSpell = spellId
end

tracker.subevents.SPELL_CAST_SUCCESS = function(seg, srcGUID, _, _, _, spellId)
	act(seg, srcGUID, spellId)
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
