-- Active-mitigation uptime from CLEU aura events (Classic path). Tracks
-- how long each player kept ANY listed mitigation buff up (reference-
-- counted: Shield Block + Shield Barrier overlapping is one window);
-- FightHistory turns it into a percent for tanks. Informational only.
local _, TP = ...

local tracker = { subevents = {} }

-- SPELL_AURA_* suffix: spellId, spellName, school, auraType
local function applied(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	if not a1 or not TP.MITIGATION_BUFFS or not TP.MITIGATION_BUFFS[a1] then
		return
	end
	local acc = seg.players[dstGUID]
	local m = acc and acc.mitigation
	if not m then
		return
	end
	-- track WHICH auras were counted so a REMOVED for a never-counted
	-- pre-pull aura can't close a live window (audit 2026-07-16)
	m.counted = m.counted or {}
	if m.counted[a1] then
		return
	end
	m.counted[a1] = true
	m.n = m.n + 1
	if m.n == 1 then
		m.since = GetTime()
	end
end

local function refreshed(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	if not a1 or not TP.MITIGATION_BUFFS or not TP.MITIGATION_BUFFS[a1] then
		return
	end
	-- same aura re-applied: no count change, but a buff that was up
	-- BEFORE the segment started (missed APPLIED) opens the window here
	local acc = seg.players[dstGUID]
	local m = acc and acc.mitigation
	if m and m.n == 0 then
		m.counted = m.counted or {}
		m.counted[a1] = true -- so its own REMOVED can close the window
		m.n = 1
		m.since = GetTime()
	end
end

local function removed(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	if not a1 or not TP.MITIGATION_BUFFS or not TP.MITIGATION_BUFFS[a1] then
		return
	end
	local acc = seg.players[dstGUID]
	local m = acc and acc.mitigation
	if not m or m.n == 0 or not (m.counted and m.counted[a1]) then
		return
	end
	m.counted[a1] = nil
	m.n = m.n - 1
	if m.n == 0 and m.since then
		m.uptime = m.uptime + (GetTime() - m.since)
		m.since = nil
	end
end

tracker.subevents.SPELL_AURA_APPLIED = applied
tracker.subevents.SPELL_AURA_REFRESH = refreshed
tracker.subevents.SPELL_AURA_REMOVED = removed

tracker.InitPlayer = function(acc)
	acc.mitigation = { uptime = 0, n = 0 }
end
tracker.MergePlayer = function(dst, src)
	dst.mitigation.uptime = dst.mitigation.uptime + (src.mitigation and src.mitigation.uptime or 0)
	-- open windows don't merge; the fight-end close handles them
end

TP.Metrics:Register(tracker)
