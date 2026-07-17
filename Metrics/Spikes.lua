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
	-- remember WHICH auras we counted: a REMOVED for an aura that was
	-- up before the pull (never counted) must not close someone else's
	-- window (audit 2026-07-16 underflow-by-proxy)
	s.counted = s.counted or {}
	if s.counted[spellID] then
		return
	end
	s.counted[spellID] = true
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
	if not s or s.n == 0 or not (s.counted and s.counted[a1]) then
		return -- never counted this aura: don't close someone else's window
	end
	s.counted[a1] = nil
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
				r.spikeMap = {}
				local cov = 0
				for _, win in ipairs(w) do
					local met = spanCovers(s.spans, s.since, win[1], win[2], TANK_SLOP)
					if met then
						cov = cov + 1
					end
					-- {start, end, met}: the breakdown's timeline strip
					r.spikeMap[#r.spikeMap + 1] = { math.floor(win[1]), math.floor(win[2]), met or nil }
				end
				r.spikeCovered = cov
			end
		end
		if #groupWindows > 0 then
			r.groupSpikeWindows = #groupWindows
			r.groupSpikeMap = {}
			local cov = 0
			for _, win in ipairs(groupWindows) do
				local met = castCovers(s and s.casts, win[1], win[2], HEALER_SLOP)
				if met then
					cov = cov + 1
				end
				r.groupSpikeMap[#r.groupSpikeMap + 1] = { math.floor(win[1]), math.floor(win[2]), met or nil }
			end
			r.groupSpikeCovered = cov
		end
		if next(r) then
			out[guid] = r
		end
	end
	return out
end

-- "Wipe it" detection (2026-07-14, Josh): when a raid leader calls the
-- wipe, people stand in bad on purpose, jump off ledges, or AFK until
-- the boss finishes them — none of that is performance. The tell is
-- GROUP OUTPUT COLLAPSE: even the living stop attacking. From the
-- per-second group damage-done buckets, find the moment output falls
-- below a fraction of the fight's own baseline and never recovers.
-- A wipe fought to the last death keeps output high to the end and
-- returns nil — everything counts on those.
function Spikes.DetectWipeCall(buckets, duration)
	duration = math.floor(duration or 0)
	if not buckets or duration < 30 then
		return nil
	end
	-- baseline: median per-second output over the fight's first 60%
	-- (the honest-effort phase on any wipe long enough to be called)
	local sample = {}
	for t = 0, math.floor(duration * 0.6) do
		sample[#sample + 1] = buckets[t] or 0
	end
	table.sort(sample)
	local baseline = sample[math.ceil(#sample / 2)] or 0
	if baseline <= 0 then
		return nil
	end
	-- walk backward: the last 5s window that still shows real effort
	-- (>= 40% of baseline) marks the end of trying
	local lastEffort
	for t = duration - 5, 0, -1 do
		local w = 0
		for k = t, t + 4 do
			w = w + (buckets[k] or 0)
		end
		if w / 5 >= baseline * 0.4 then
			lastEffort = t + 5
			break
		end
	end
	if not lastEffort then
		return nil
	end
	-- confidence: a meaningful collapsed tail (8s+), not the pull start,
	-- and the tail really is dead (< 20% baseline average)
	if lastEffort < 20 or duration - lastEffort < 8 then
		return nil
	end
	local tail, n = 0, 0
	for t = lastEffort, duration do
		tail = tail + (buckets[t] or 0)
		n = n + 1
	end
	if n > 0 and tail / n >= baseline * 0.2 then
		return nil
	end
	return lastEffort
end
