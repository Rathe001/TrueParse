-- Uptime proxy from CLEU (Classic path). Each action credits the time since
-- the player's previous action, up to IDLE_GAP; anything longer is real
-- downtime and only the first IDLE_GAP of it counts. activity% = credited
-- time / fight duration.
--
-- IDLE_GAP is 5s, not one GCD (Josh 2026-07-28: "many fights have a lot of
-- downtime and our coach is talking about it"). We score this against WCL's
-- activeTime, and measuring both on real history showed ours reading 20.6
-- points low - but not evenly. Melee were nearly right (Assassination -3.5,
-- Windwalker -5.3) while every healer and channeler was far off (Resto Druid
-- -35.5, Shadow -34.3, Holy Paladin -29.7). Healers do not idle 30% more
-- than rogues; WCL's ranked healers simply are not on the GCD 98.5% of a
-- fight either. Their activeTime is fight duration minus idle STRETCHES, so
-- a healer waiting 3s for the next cast is still "active" and a rogue
-- auto-attacking is too. Measuring occupancy against an idleness anchor
-- charged casters ~25 points for a definition mismatch.
--
-- The threshold reproduces the crawl independently: Immerseus is the one SoO
-- boss where the raid is forced to stand around, and WCL's own median there
-- is 76.4% - about what three ~30s split phases give you when only the first
-- 5s of each counts. Malkorok, with no forced downtime, sits at 99.2%.
--
-- It also subsumes two defects for free: a 6s channel is one SPELL_CAST_SUCCESS
-- with no further events, and a whiffed swing produces no damage event - both
-- now ride inside the gap instead of reading as idle.
--
-- Hardcasts are still the exception in the other direction: a completed cast
-- credits its full cast time (matched via SPELL_CAST_START), because a cast
-- longer than the gap since the last action is activity we would otherwise
-- clip.
local _, TP = ...

local tracker = { subevents = {} }

local CAP = 5 -- an action gap longer than this is genuine downtime
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
		-- first action of the fight: never credit more than has elapsed,
		-- or a 5s window lands on a pull that was 1s ago
		a.active = a.active + math.min(t - (seg.startTime or t), cap)
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
-- a dodged or parried swing is still a swing: the attempt is the activity
tracker.subevents.SWING_MISSED = function(seg, srcGUID)
	act(seg, srcGUID)
end
tracker.subevents.RANGE_MISSED = function(seg, srcGUID)
	act(seg, srcGUID)
end

tracker.InitPlayer = function(acc)
	acc.activity = { active = 0 }
end
tracker.MergePlayer = function(dst, src)
	dst.activity.active = dst.activity.active + (src.activity and src.activity.active or 0)
end

TP.Metrics:Register(tracker)
