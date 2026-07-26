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
-- proactive raid CDs are the BETTER play: Barrier dropped on a DBM timer
-- 5-8s before the hit still covers it (the buff lasts 6-10s), but the
-- cast timestamp precedes the window. Same shape as the Bloodlust
-- pre-grace (audit 2026-07-18). Tanks don't need this — their coverage
-- is aura-span overlap, which already credits early walls.
local HEALER_PRE_SLOP = 8

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
		-- friendly max-HP is a SECRET on retail: comparing it taints and
		-- throws (Josh 2026-07-25). This path only runs from CLEU
		-- subevents (Classic), but guard anyway against future callers.
		if hp and not (TP.Compat and TP.Compat.IsSecret and TP.Compat.IsSecret(hp)) and hp > 0 then
			s.maxHP = hp
		end
	end
	return s
end

local function addTaken(seg, dstGUID, amount, spell)
	if not amount or amount <= 0 then
		return
	end
	local s = ensure(seg, dstGUID)
	if not s then
		return
	end
	local i = math.floor(GetTime() - seg.startTime)
	s.taken[i] = (s.taken[i] or 0) + amount
	-- the second's hardest single hit, for the strip-band tooltips
	-- ("what hit us there") — one small record per active second
	if spell then
		local top = s.top
		if not top then
			top = {}
			s.top = top
		end
		if not top[i] or amount > top[i][1] then
			top[i] = { amount, spell }
		end
	end
end

-- SWING_DAMAGE suffix: amount, overkill, ...
tracker.subevents.SWING_DAMAGE = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	addTaken(seg, dstGUID, a1, "Melee")
end
-- SPELL/RANGE prefix adds spellId, spellName, school before the suffix
local function spellTaken(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4)
	addTaken(seg, dstGUID, a4, a2)
end
tracker.subevents.SPELL_DAMAGE = spellTaken
tracker.subevents.SPELL_PERIODIC_DAMAGE = spellTaken
tracker.subevents.RANGE_DAMAGE = spellTaken
tracker.subevents.DAMAGE_SPLIT = spellTaken
tracker.subevents.DAMAGE_SHIELD = spellTaken
tracker.subevents.ENVIRONMENTAL_DAMAGE = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2)
	addTaken(seg, dstGUID, a2, a1) -- a1 = environment type ("Falling", ...)
end

-- defensive aura spans (reference-counted like Mitigation; REFRESH
-- opens windows the pull started with)
local function auraOn(seg, dstGUID, spellID, refreshOnly, spellName)
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
		s.sinceName = spellName -- names the span for the band tooltips
	end
end

tracker.subevents.SPELL_AURA_APPLIED = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2)
	auraOn(seg, dstGUID, a1, false, a2)
end
tracker.subevents.SPELL_AURA_REFRESH = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2)
	auraOn(seg, dstGUID, a1, true, a2)
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
		-- [3] = the defensive's name, for the strip-band tooltips
		s.spans[#s.spans + 1] = { s.since, GetTime() - seg.startTime, s.sinceName }
		s.since = nil
		s.sinceName = nil
	end
end

-- healer raid-cooldown casts (timestamps as fight offsets)
tracker.subevents.SPELL_CAST_SUCCESS = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2)
	if not (a1 and TP.HEALER_CDS and TP.HEALER_CDS[a1]) then
		return
	end
	local s = ensure(seg, srcGUID)
	if s then
		s.casts[#s.casts + 1] = GetTime() - seg.startTime
		s.castNames = s.castNames or {}
		s.castNames[#s.casts] = a2 -- parallel to casts[]
	end
	-- single-target externals also land on the TARGET's record (Josh
	-- 2026-07-24): Guardian Spirit answering a tank spike is the healer's
	-- play, so Compute needs to know whose spike it met and who threw it
	if TP.EXTERNALS and TP.EXTERNALS[a1] and dstGUID and dstGUID ~= srcGUID then
		local ts = ensure(seg, dstGUID)
		if ts then
			ts.extCasts = ts.extCasts or {}
			ts.extCasts[#ts.extCasts + 1] = { GetTime() - seg.startTime, a2, srcGUID }
		end
	end
	-- which raid CDs got pressed at all: the group card names the ones
	-- that sat unused while heavy-damage moments went uncovered
	seg.group = seg.group or {}
	local used = seg.group.raidCdsUsed
	if not used then
		used = {}
		seg.group.raidCdsUsed = used
	end
	used[a1] = true
end

tracker.InitPlayer = function(acc)
	-- accumulators stay lazy (most players never spike), but max HP is
	-- captured for EVERYONE up front: the group spike threshold divides
	-- by summed group HP, and summing only damaged players' pools made
	-- clean pulls manufacture spike windows (audit 2026-07-16).
	-- RETAIL no-op (Josh 2026-07-25): this file loads on retail only for
	-- the pure GroupWindowsFromReports/FindWindows helpers; there is no
	-- CLEU there, and friendly UnitHealthMax is a SECRET that throws on
	-- the hp>0 compare. The retail group-spike path never needs it.
	if not (TP.Compat and TP.Compat.HAS_CLEU) then
		return
	end
	-- Guarded: headless tests have no WoW API.
	if UnitHealthMax and TP.Roster and TP.Roster.players then
		local info = TP.Roster.players[acc.guid]
		if info and info.unit then
			local ok, hp = pcall(UnitHealthMax, info.unit)
			if ok and type(hp) == "number" and hp > 0 then
				acc.spikes = acc.spikes or { taken = {}, spans = {}, casts = {}, n = 0 }
				acc.spikes.maxHP = hp
			end
		end
	end
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

-- Retail group-spike aggregation (2026-07-25): Midnight has no CLEU, so
-- the group-wide damage spikes MoP reads from summed raid intake are
-- rebuilt from what TrueParse users self-report. Each reporter's own
-- personal spike windows (times THEY took heavy damage) are the votes:
-- a GROUP spike is a moment when 2+ NON-TANK reporters spiked at once (a
-- raid mechanic hitting the group — tanks spike steadily and don't vote).
-- Coverage is team-union like MoP: any reporter's raid-CD cast near the
-- window covers it for every healer. PURE: headless-testable.
--   reports = { { role, windows = {{s,e},...}, cdCasts = {t,...} }, ... }
-- Returns groupWindows = {{s,e,covered},...} and total cdCasts, or nil
-- when too few non-tank reporters exist to tell a raid hit from a fluke.
function Spikes.GroupWindowsFromReports(reports)
	local voters, allCds = {}, {}
	local voterCount = 0
	for _, r in ipairs(reports or {}) do
		for _, t in ipairs(r.cdCasts or {}) do
			allCds[#allCds + 1] = t
		end
		if r.role ~= "TANK" and r.windows and #r.windows > 0 then
			voterCount = voterCount + 1
			for _, w in ipairs(r.windows) do
				voters[#voters + 1] = { s = w[1], e = w[2], who = voterCount }
			end
		end
	end
	if voterCount < 2 or #voters == 0 then
		return nil
	end
	-- coordinate sweep: every window edge is a boundary; a sub-interval
	-- with 2+ DISTINCT voters inside is a group spike
	local edges = {}
	for _, v in ipairs(voters) do
		edges[#edges + 1] = v.s
		edges[#edges + 1] = v.e
	end
	table.sort(edges)
	local group = {}
	for i = 1, #edges - 1 do
		local a, b = edges[i], edges[i + 1]
		if b > a then
			local mid = (a + b) / 2
			local who = {}
			for _, v in ipairs(voters) do
				if v.s <= mid and v.e >= mid then
					who[v.who] = true
				end
			end
			local n = 0
			for _ in pairs(who) do
				n = n + 1
			end
			if n >= 2 then
				local last = group[#group]
				if last and a - last[2] <= MERGE_GAP then
					last[2] = b
				else
					group[#group + 1] = { a, b }
				end
			end
		end
	end
	if #group == 0 then
		return nil
	end
	for _, w in ipairs(group) do
		local covered = false
		for _, t in ipairs(allCds) do
			if t >= w[1] - HEALER_PRE_SLOP and t <= w[2] + HEALER_SLOP then
				covered = true
				break
			end
		end
		w[3] = covered or nil
	end
	return group, #allCds
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

local function castCovers(casts, ws, we, preSlop, postSlop)
	for _, t in ipairs(casts or {}) do
		if t >= ws - preSlop and t <= we + postSlop then
			return true
		end
	end
	return false
end

-- ===== band-tooltip enrichment (Josh 2026-07-24): what hit, how hard,
-- and what the player answered with =====
local function windowStats(taken, top, ws, we)
	local amt, bigAmt, bigName = 0, 0, nil
	for t = math.floor(ws), math.ceil(we) do
		amt = amt + ((taken and taken[t]) or 0)
		local h = top and top[t]
		if h and h[1] > bigAmt then
			bigAmt, bigName = h[1], h[2]
		end
	end
	return amt, bigName
end

local function coveringCastName(s, ws, we)
	for i, t in ipairs((s and s.casts) or {}) do
		if t >= ws - HEALER_PRE_SLOP and t <= we + HEALER_SLOP then
			return s.castNames and s.castNames[i]
		end
	end
end

local function coveringSpanName(s, ws, we)
	for _, sp in ipairs((s and s.spans) or {}) do
		if sp[1] <= we + TANK_SLOP and sp[2] >= ws - TANK_SLOP then
			return sp[3]
		end
	end
	if s and s.since and s.since <= we + TANK_SLOP then
		return s.sinceName
	end
end

-- Returns [guid] = { spikeWindows, spikeCovered, groupSpikeWindows,
-- groupSpikeCovered } — fields nil when that player had no windows.
-- The caller (FightHistory) stamps them; the engine gates by role.
function Spikes.Compute(seg, duration)
	if not duration or duration <= 0 then
		return nil
	end
	local out = {}
	local groupTaken, groupTop, groupHP = {}, {}, 0
	for _, acc in pairs(seg.players) do
		local s = acc.spikes
		if s and s.maxHP then
			groupHP = groupHP + s.maxHP
			for t, v in pairs(s.taken) do
				groupTaken[t] = (groupTaken[t] or 0) + v
			end
			for t, h in pairs(s.top or {}) do
				if not groupTop[t] or h[1] > groupTop[t][1] then
					groupTop[t] = h
				end
			end
		end
	end
	local groupWindows = groupHP > 0
		and Spikes.FindWindows(groupTaken, duration, groupHP * Spikes.GROUP_3S_SHARE) or {}

	-- group windows are the TEAM's job: healers rotating raid CDs so each
	-- window has ONE cooldown is the universally correct strategy, but it
	-- means no single healer covers most windows. Coverage is therefore
	-- computed as "did ANYONE'S cooldown meet it" and credited to every
	-- healer (audit 2026-07-18: 3 healers rotating perfectly each read
	-- 2/6 covered and all three were penalized for 100% team coverage).
	local groupMet, groupWho = {}, {}
	for i, win in ipairs(groupWindows) do
		for _, acc in pairs(seg.players) do
			local s = acc.spikes
			if s and castCovers(s.casts, win[1], win[2], HEALER_PRE_SLOP, HEALER_SLOP) then
				groupMet[i] = true
				-- WHO answered the window, and with what (Josh 2026-07-24:
				-- the team strip should name the coverer)
				groupWho[i] = { acc.name, coveringCastName(s, win[1], win[2]) }
				break
			end
		end
	end
	-- the TEAM's demonstrated raid-CD capacity: how many cooldown casts
	-- actually happened. The engine caps the judged window count at
	-- capacity+1 — a team with 2 casts in a 6-window fight failed
	-- capacity, not discipline ("could have, but didn't" needs could-have)
	local teamCasts = 0
	for _, acc in pairs(seg.players) do
		local s = acc.spikes
		if s and s.casts then
			teamCasts = teamCasts + #s.casts
		end
	end

	-- TANK spike windows as the single-target-external pool (Josh
	-- 2026-07-24): a Guardian Spirit / Ironbark riding a tank spike is
	-- the healer's play. Union-credited like group windows (externals
	-- rotate too); the engine gates the fields to healer specs that OWN
	-- an external, so shamans are never judged on a button they lack.
	local tankWins = {}
	for _, acc in pairs(seg.players) do
		if acc.role == "TANK" then
			local s = acc.spikes
			if s and s.maxHP then
				for _, win in ipairs(Spikes.FindWindows(s.taken, duration, s.maxHP * Spikes.TANK_3S_SHARE)) do
					local met, who
					for _, ec in ipairs(s.extCasts or {}) do
						if ec[1] >= win[1] - HEALER_PRE_SLOP and ec[1] <= win[2] + HEALER_SLOP then
							met = true
							who = ec
							break
						end
					end
					tankWins[#tankWins + 1] = { win[1], win[2], met, who }
				end
			end
		end
	end

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
					-- {start, end, met, -, amount, what-hit, what-answered}:
					-- the strip's bands and their hover tooltips. [8] = an
					-- EXTERNAL that rode the spike ("Beebcat's Ironbark") —
					-- context for the hover, never coverage for the score
					-- (the tank's verdict judges the tank's own buttons)
					local amt, hitName = windowStats(s.taken, s.top, win[1], win[2])
					local extWho
					for _, ec in ipairs(s.extCasts or {}) do
						if ec[1] >= win[1] - HEALER_PRE_SLOP and ec[1] <= win[2] + HEALER_SLOP then
							local src = ec[3] and seg.players[ec[3]]
							extWho = src and src.name and (src.name .. "'s " .. (ec[2] or "external"))
								or ec[2]
							break
						end
					end
					r.spikeMap[#r.spikeMap + 1] = { math.floor(win[1]), math.floor(win[2]), met or nil, nil,
						amt, hitName, met and coveringSpanName(s, win[1], win[2]) or nil, extWho }
				end
				r.spikeCovered = cov
				-- demonstrated defensive capacity (completed aura spans,
				-- plus one still running at fight end)
				r.defensiveUses = #(s.spans or {}) + (s.since and 1 or 0)
			end
		end
		if #groupWindows > 0 then
			-- windows that open after this player's death don't judge
			-- them: a corpse can't cast Healing Tide (audit 2026-07-18)
			local diedAt = acc.deaths and (acc.deaths.total or 0) > 0
				and acc.deaths.lastTime or nil
			local windows, cov = 0, 0
			r.groupSpikeMap = {}
			for i, win in ipairs(groupWindows) do
				if not (diedAt and win[1] >= diedAt) then
					windows = windows + 1
					if groupMet[i] then
						cov = cov + 1
					end
				end
				-- 4th field: did THIS PLAYER personally cover it — a healer's
				-- raid-CD cast or anyone's defensive aura riding the window.
				-- The card tape draws ONLY personal coverage (Josh 2026-07-24:
				-- teammate state polluted the strip; team totals belong on
				-- the group card). The SCORE stays team-union regardless.
				local mine = s and (castCovers(s.casts, win[1], win[2], HEALER_PRE_SLOP, HEALER_SLOP)
					or spanCovers(s.spans, s.since, win[1], win[2], TANK_SLOP)) or nil
				if not mine then
					mine = nil -- false compresses out of the SavedVariables
				end
				-- 5-7: group damage in the window, the hardest-hitting
				-- ability, and what THIS player answered with (band tooltips)
				local amt, hitName = windowStats(groupTaken, groupTop, win[1], win[2])
				local used
				if mine then
					used = coveringCastName(s, win[1], win[2]) or coveringSpanName(s, win[1], win[2])
				end
				-- 8-9: the covering TEAMMATE and their cooldown (the group
				-- card's strip names them; personal answers stay in [7])
				local who = groupWho[i]
				r.groupSpikeMap[#r.groupSpikeMap + 1] = { math.floor(win[1]), math.floor(win[2]),
					groupMet[i] or nil, mine, amt, hitName, used,
					who and who[1] or nil, who and who[2] or nil }
			end
			if windows > 0 then
				r.groupSpikeWindows = windows
				r.groupSpikeCovered = cov
				r.groupCdCasts = teamCasts
			end
		end
		if #tankWins > 0 then
			-- tank-spike windows this player could still answer (dead
			-- healers can't Ironbark either); stamped for everyone, the
			-- engine gates to healer specs owning an external
			local diedAt = acc.deaths and (acc.deaths.total or 0) > 0
				and acc.deaths.lastTime or nil
			local ew, ec = 0, 0
			for _, win in ipairs(tankWins) do
				if not (diedAt and win[1] >= diedAt) then
					ew = ew + 1
					if win[3] then
						ec = ec + 1
					end
				end
			end
			if ew > 0 then
				r.extWindows = ew
				r.extCovered = ec
				-- capacity must ride along even when the fight had no
				-- group-wide spikes (the cap math reads groupCdCasts)
				r.groupCdCasts = r.groupCdCasts or teamCasts
			end
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
