-- Fight/segment lifecycle. A segment owns the per-player accumulators that
-- metric trackers write into during combat. Kinds: the live `current` fight,
-- a `history` ring buffer of finished fights, and a session `overall`.
local _, TP = ...

local Segments = {
	current = nil,
	history = {},
	overall = nil,
	revision = 0, -- bumped on every segment change; UI uses it to skip redraws
}
TP.Segments = Segments

local function newSegment(kind, name)
	return {
		kind = kind,
		name = name,
		startTime = GetTime(),
		endTime = nil,
		duration = nil,
		encounterID = nil,
		players = {},
		group = {}, -- fight-wide counters (interruptibleCasts etc., later phases)
	}
end

function Segments:OnEnable()
	local Addon = TP.Addon
	self.overall = newSegment(TP.SEGMENT.OVERALL, "Overall")
	self.overall.duration = 0

	Addon:RegisterEvent("PLAYER_REGEN_DISABLED", function()
		Segments:StartFight()
	end)
	Addon:RegisterEvent("PLAYER_REGEN_ENABLED", function()
		Segments:ScheduleEndCheck()
	end)
	Addon:RegisterEvent("ENCOUNTER_START", function(_, encounterID, encounterName)
		Segments:OnEncounterStart(encounterID, encounterName)
	end)
	Addon:RegisterEvent("ENCOUNTER_END", function(_, encounterID, _, _, _, success)
		Segments:OnEncounterEnd(encounterID, success)
	end)
	-- Players who join mid-fight still need accumulators
	Addon:RegisterMessage("TrueParse_ROSTER_CHANGED", function()
		local seg = Segments.current
		if seg then
			for guid in pairs(TP.Roster.players) do
				Segments:EnsurePlayer(seg, guid)
			end
		end
	end)
end

function Segments:EnsurePlayer(seg, guid)
	local acc = seg.players[guid]
	if not acc then
		local info = TP.Roster.players[guid]
		if not info then
			return nil
		end
		acc = {
			guid = guid, name = info.name, class = info.class, role = info.role,
			specID = info.specID, ilvl = info.ilvl,
		}
		TP.Metrics:InitPlayer(acc)
		seg.players[guid] = acc
	end
	return acc
end

function Segments:StartFight(name)
	if self.current then
		return
	end
	self:CancelEndCheck()
	if not name then
		-- Best guess at a label; boss segments get renamed by ENCOUNTER_START
		name = (UnitExists("target") and UnitName("target")) or GetZoneText() or "Fight"
	end
	-- Mid-encounter even UnitName("target") can be a secret string; a secret
	-- must never become a fight label (it poisons prints and SavedVariables)
	if TP.Compat.IsSecret(name) then
		name = GetZoneText() or "Fight"
		if TP.Compat.IsSecret(name) then
			name = "Fight"
		end
	end
	local seg = newSegment(TP.SEGMENT.FIGHT, name)
	for guid in pairs(TP.Roster.players) do
		self:EnsurePlayer(seg, guid)
	end
	self.current = seg
	self.revision = self.revision + 1
	TP.Addon:SendMessage("TrueParse_SEGMENT_CHANGED")
	TP.Addon:Debug("Fight started:", name)
end

function Segments:EndFight()
	local seg = self.current
	if not seg then
		return
	end
	self:CancelEndCheck()
	if self.bossPctTimer then
		TP.Addon:CancelTimer(self.bossPctTimer)
		self.bossPctTimer = nil
	end
	seg.endTime = GetTime()
	seg.duration = math.max(seg.endTime - seg.startTime, 1)
	self.current = nil

	-- Raw segments are only read as history[1] (fight browsing uses
	-- FightHistory.fights, which AddFromSegment fills below). Keeping 200
	-- of them pinned ~80k live tables on a raid night for nothing.
	table.insert(self.history, 1, seg)
	for i = #self.history, 4, -1 do
		table.remove(self.history, i)
	end

	self:MergeOverall(seg)
	TP.FightHistory:AddFromSegment(seg)
	self.revision = self.revision + 1
	TP.Addon:SendMessage("TrueParse_SEGMENT_CHANGED")
	TP.Addon:Debug("Fight ended:", seg.name, ("(%.0fs)"):format(seg.duration))
end

-- PLAYER_REGEN_ENABLED only means *you* left combat; the group may still be
-- fighting (e.g. you died). Poll until the whole roster is out of combat.
function Segments:ScheduleEndCheck()
	self:CancelEndCheck()
	self.endTimer = TP.Addon:ScheduleRepeatingTimer(function()
		if not Segments.current then
			Segments:CancelEndCheck()
			return
		end
		for _, info in pairs(TP.Roster.players) do
			if UnitExists(info.unit) and UnitAffectingCombat(info.unit) then
				return -- someone still fighting; keep waiting
			end
		end
		Segments:CancelEndCheck()
		Segments:EndFight()
	end, 1)
end

function Segments:CancelEndCheck()
	if self.endTimer then
		TP.Addon:CancelTimer(self.endTimer)
		self.endTimer = nil
	end
end

-- Boss unit GUIDs let trackers split damage-to-boss from damage-to-adds.
-- Only the CLEU (Classic) trackers consume these, and Midnight secrets
-- boss GUIDs mid-combat — a secret string as a table key throws.
local function captureBossGUIDs(seg)
	if TP.Compat.IS_RETAIL then
		return
	end
	seg.bossGUIDs = seg.bossGUIDs or {}
	for i = 1, 8 do
		local guid = UnitGUID("boss" .. i)
		if guid and not TP.Compat.IsSecret(guid) then
			seg.bossGUIDs[guid] = true
		end
	end
end

function Segments:OnEncounterStart(encounterID, encounterName)
	if TP.Compat.IsSecret(encounterName) then
		encounterName = nil
	end
	-- Close any trash segment so the boss gets a clean one
	if self.current and not self.current.encounterID then
		self:EndFight()
	end
	self:StartFight(encounterName)
	if self.current then
		self.current.encounterID = encounterID
		-- WCL's fight bounds ARE the encounter events; anchoring our
		-- duration here matches their rankings by construction
		self.current.encounterStartTime = GetTime()
		if encounterName then -- secret name: keep StartFight's fallback label
			self.current.name = encounterName
		end
		captureBossGUIDs(self.current)
		local seg = self.current
		C_Timer.After(3, function()
			-- boss frames can populate late (multi-boss encounters)
			if self.current == seg then
				captureBossGUIDs(seg)
			end
		end)
		-- best-pull tracking: sample boss HP every 2s; "how far we got" is
		-- WHERE THE BOSS STOOD WHEN THE PULL ENDED (WCL's wipe semantics),
		-- not the running minimum — bosses that refill at phase transitions
		-- (Garrosh heals to full between phases) made the min read the
		-- pre-transition floor, and untargetable intermission bosses read
		-- 0 HP and latched "best 0%" (Josh's report 2026-07-23).
		-- Cancel any prior ticker FIRST and let the closure cancel its OWN
		-- handle (audit 2026-07-16: a double ENCOUNTER_START orphaned the
		-- old ticker, which then assassinated every future fight's sampler
		-- via the shared self.bossPctTimer field)
		if self.bossPctTimer then
			TP.Addon:CancelTimer(self.bossPctTimer)
			self.bossPctTimer = nil
		end
		local myTimer
		myTimer = TP.Addon:ScheduleRepeatingTimer(function()
			if self.current ~= seg then
				TP.Addon:CancelTimer(myTimer)
				if self.bossPctTimer == myTimer then
					self.bossPctTimer = nil
				end
				return
			end
			-- health-POOL-weighted progress (2026-07-16, Garrosh read
			-- "4%" at a 25% wipe): adds in boss frames have tiny pools,
			-- and a plain average let a dying 10M-HP add drag a 600M-HP
			-- boss's number to the floor. sum(hp)/sum(maxHP) is how
			-- DBM/WCL compute boss % — adds barely move it.
			local hpSum, mxSum = 0, 0
			for i = 1, 5 do
				local u = "boss" .. i
				if UnitExists(u) then
					-- Midnight secrets boss health mid-combat, and secrets
					-- throw on COMPARISON, not on call — the whole compute
					-- lives inside the pcall with an explicit secret check
					-- (live error: "attempt to compare a secret number")
					local ok, hp, mx = pcall(function()
						local h, m = UnitHealth(u), UnitHealthMax(u)
						if TP.Compat.IsSecret(h) or TP.Compat.IsSecret(m) then
							return nil
						end
						if type(h) == "number" and type(m) == "number" and m > 0 then
							return h, m
						end
					end)
					if ok and hp and mx then
						hpSum = hpSum + hp
						mxSum = mxSum + mx
					end
				end
			end
			if mxSum > 0 then
				-- pool-continuity gate: if the boss leaves the frames
				-- (realm/intermission phases) an adds-only sample sums a
				-- fraction of the real pool — don't let it speak. Zero HP
				-- says nothing either: an untargetable transition boss
				-- reads 0, and a REAL zero is a kill, not a sample.
				seg.bossMxPeak = math.max(seg.bossMxPeak or 0, mxSum)
				if mxSum >= seg.bossMxPeak * 0.5 and hpSum > 0 then
					local pct = hpSum / mxSum * 100
					local prev = seg.bossPctLast
					if prev and pct > prev + 5 then
						-- the pool jumped back UP: a phase refill (follow
						-- it — the pull is still going) or the boss
						-- resetting over a dead raid (freeze — a reset
						-- is not the raid losing progress). Living
						-- raiders tell the two apart; secrets read as
						-- alive so retail never freezes wrongly.
						local ok, alive = pcall(function()
							for _, info in pairs(TP.Roster.players) do
								if info.unit and UnitExists(info.unit)
									and not UnitIsDeadOrGhost(info.unit) then
									return true
								end
							end
							return false
						end)
						if not ok or alive then
							seg.bossPctLast = pct
						end
					else
						seg.bossPctLast = pct
					end
				end
			end
		end, 2)
		self.bossPctTimer = myTimer
	end
end

function Segments:OnEncounterEnd(encounterID, success)
	if self.current and self.current.encounterID == encounterID then
		self.current.encounterWipe = (success == 0) or nil
		self.current.encounterEnded = true -- explicit verdict arrived
		self:EndFight()
		-- Boss can chain straight into trash without leaving combat (M+);
		-- PLAYER_REGEN_DISABLED won't re-fire, so open a new segment now.
		if UnitAffectingCombat("player") then
			self:StartFight()
		end
	elseif success == 0 then
		-- Late wipe verdict: die early, release, and the segment closes
		-- (everyone dead = combat drops) long before the boss resets and
		-- ENCOUNTER_END finally fires — the capture was saved without its
		-- wipe flag (five unmarked Thok "kills" on one lockout, live).
		TP.FightHistory:AmendWipe(encounterID)
	end
end

function Segments:MergeOverall(seg)
	local overall = self.overall
	overall.duration = overall.duration + seg.duration
	for guid, src in pairs(seg.players) do
		local dst = overall.players[guid]
		if not dst then
			dst = { guid = guid, name = src.name, class = src.class, role = src.role }
			TP.Metrics:InitPlayer(dst)
			overall.players[guid] = dst
		end
		TP.Metrics:MergePlayer(dst, src)
	end
end

-- What the meter window shows: live fight if one is running, otherwise the
-- most recent fight, otherwise the (possibly empty) overall.
function Segments:GetDisplaySegment()
	return self.current or self.history[1] or self.overall
end

function Segments:GetDuration(seg)
	return seg.duration or math.max(GetTime() - seg.startTime, 1)
end
