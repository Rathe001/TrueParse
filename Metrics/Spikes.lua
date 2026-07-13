-- Danger-window cooldown timing (Classic CLEU path). Damage taken is
-- bucketed per second per player; at capture, FindWindows locates the
-- spikes — 3 seconds of intake above a share of max HP — and coverage
-- asks whether a listed cooldown met each one:
--   tanks:   a major defensive AURA overlapping the window (walls cast
--            early still count — the buff is what matters)
--   healers: a raid-cooldown CAST near the window (reaction time slop)
-- Results land as m.spikeWindows/spikeCovered (tanks) and
-- m.groupSpikeWindows/groupSpikeCovered (healers) -> the cdTiming
-- adjustment. Timing beats totals: that's the whole point.
local _, TP = ...

local tracker = { subevents = {} }
local Spikes = {}
TP.Spikes = Spikes

Spikes.TANK_3S_SHARE = 0.45 -- own 3s intake >= 45% of own max HP
Spikes.GROUP_3S_SHARE = 0.18 -- group 3s intake >= 18% of group max HP
local MERGE_GAP = 3 -- windows this close merge into one event
local TANK_SLOP = 1.5 -- seconds of grace around a window for aura overlap
local HEALER_SLOP = 3 -- reaction time for a cast to count as "met it"

local function ensure(seg, dstGUID)
	local acc = seg.players[dstGUID]
	if not acc then
		return nil
	end
	local s = acc.spikes
	if not s then
		s = { taken = {}, spans = {}, casts = {}, n = 0 }
		acc.spikes = s
	end
	if not s.maxHP then
		local info = TP.Roster.players[dstGUID]
		local hp = info and info.unit and UnitHealthMax(info.unit)
		if hp and hp > 0 then
			s.maxHP = hp
		end
	end
	return s
end

local function addTaken(seg, dstGUID, amount)
	if not amount or amount <= 0 then
		return
	end
	local s = ensure(seg, dstGUID)
	if not s then
		return
	end
	local i = math.floor(GetTime() - seg.startTime)
	s.taken[i] = (s.taken[i] or 0) + amount
end

-- SWING_DAMAGE suffix: amount, overkill, ...
tracker.subevents.SWING_DAMAGE = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	addTaken(seg, dstGUID, a1)
end
-- SPELL/RANGE prefix adds spellId, spellName, school before the suffix
local function spellTaken(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4)
	addTaken(seg, dstGUID, a4)
end
tracker.subevents.SPELL_DAMAGE = spellTaken
tracker.subevents.SPELL_PERIODIC_DAMAGE = spellTaken
tracker.subevents.RANGE_DAMAGE = spellTaken

-- defensive aura spans (reference-counted like Mitigation; REFRESH
-- opens windows the pull started with)
local function auraOn(seg, dstGUID, spellID, refreshOnly)
	if not (spellID and TP.DEFENSIVES and TP.DEFENSIVES[spellID]) then
		return
	end
	local s = ensure(seg, dstGUID)
	if not s then
		return
	end
	if refreshOnly and s.n > 0 then
		return
	end
	s.n = s.n + 1
	if s.n == 1 then
		s.since = GetTime() - seg.startTime
	end
end

tracker.subevents.SPELL_AURA_APPLIED = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	auraOn(seg, dstGUID, a1, false)
end
tracker.subevents.SPELL_AURA_REFRESH = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	auraOn(seg, dstGUID, a1, true)
end
tracker.subevents.SPELL_AURA_REMOVED = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	if not (a1 and TP.DEFENSIVES and TP.DEFENSIVES[a1]) then
		return
	end
	local acc = seg.players[dstGUID]
	local s = acc and acc.spikes
	if not s or s.n == 0 then
		return
	end
	s.n = s.n - 1
	if s.n == 0 and s.since then
		s.spans[#s.spans + 1] = { s.since, GetTime() - seg.startTime }
		s.since = nil
	end
end

-- healer raid-cooldown casts (timestamps as fight offsets)
tracker.subevents.SPELL_CAST_SUCCESS = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	if not (a1 and TP.HEALER_CDS and TP.HEALER_CDS[a1]) then
		return
	end
	local s = ensure(seg, srcGUID)
	if s then
		s.casts[#s.casts + 1] = GetTime() - seg.startTime
	end
end

tracker.InitPlayer = function(acc)
	-- lazily built by ensure(): most players never spike
end
tracker.MergePlayer = function(dst, src)
	-- overall-segment merges don't carry spike timing; windows only make
	-- sense inside one fight's timeline
end

TP.Metrics:Register(tracker)

-- ===================== capture-time math (pure) =====================

-- Sliding 3s intake over a threshold; overlapping/adjacent windows
-- merge. buckets: sparse [second] = damage. Returns { {s, e}, ... }.
function Spikes.FindWindows(buckets, duration, threshold)
	local windows = {}
	local cur
	for t = 0, math.max(0, math.floor(duration)) do
		local intake = (buckets[t] or 0) + (buckets[t + 1] or 0) + (buckets[t + 2] or 0)
		if intake >= threshold then
			if cur and t - cur[2] <= MERGE_GAP then
				cur[2] = t + 2
			else
				cur = { t, t + 2 }
				windows[#windows + 1] = cur
			end
		end
	end
	return windows
end

local function spanCovers(spans, openSince, ws, we, slop)
	for _, sp in ipairs(spans or {}) do
		if sp[1] <= we + slop and sp[2] >= ws - slop then
			return true
		end
	end
	-- an aura still up at fight end covers everything after it started
	return openSince ~= nil and openSince <= we + slop
end

local function castCovers(casts, ws, we, slop)
	for _, t in ipairs(casts or {}) do
		if t >= ws - slop and t <= we + slop then
			return true
		end
	end
	return false
end

-- Returns [guid] = { spikeWindows, spikeCovered, groupSpikeWindows,
-- groupSpikeCovered } — fields nil when that player had no windows.
-- The caller (FightHistory) stamps them; the engine gates by role.
function Spikes.Compute(seg, duration)
	if not duration or duration <= 0 then
		return nil
	end
	local out = {}
	local groupTaken, groupHP = {}, 0
	for _, acc in pairs(seg.players) do
		local s = acc.spikes
		if s and s.maxHP then
			groupHP = groupHP + s.maxHP
			for t, v in pairs(s.taken) do
				groupTaken[t] = (groupTaken[t] or 0) + v
			end
		end
	end
	local groupWindows = groupHP > 0
		and Spikes.FindWindows(groupTaken, duration, groupHP * Spikes.GROUP_3S_SHARE) or {}

	for guid, acc in pairs(seg.players) do
		local s = acc.spikes
		local r = {}
		if s and s.maxHP then
			local w = Spikes.FindWindows(s.taken, duration, s.maxHP * Spikes.TANK_3S_SHARE)
			if #w > 0 then
				r.spikeWindows = #w
				local cov = 0
				for _, win in ipairs(w) do
					if spanCovers(s.spans, s.since, win[1], win[2], TANK_SLOP) then
						cov = cov + 1
					end
				end
				r.spikeCovered = cov
			end
		end
		if #groupWindows > 0 then
			r.groupSpikeWindows = #groupWindows
			local cov = 0
			for _, win in ipairs(groupWindows) do
				if castCovers(s and s.casts, win[1], win[2], HEALER_SLOP) then
					cov = cov + 1
				end
			end
			r.groupSpikeCovered = cov
		end
		if next(r) then
			out[guid] = r
		end
	end
	return out
end
