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
	Addon:RegisterEvent("ENCOUNTER_END", function(_, encounterID)
		Segments:OnEncounterEnd(encounterID)
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
		acc = { guid = guid, name = info.name, class = info.class, role = info.role }
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
	seg.endTime = GetTime()
	seg.duration = math.max(seg.endTime - seg.startTime, 1)
	self.current = nil

	table.insert(self.history, 1, seg)
	local maxFights = TP.Addon.db.profile.history.maxFights
	for i = #self.history, maxFights + 1, -1 do
		table.remove(self.history, i)
	end

	self:MergeOverall(seg)
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
		self.current.name = encounterName
	end
end

function Segments:OnEncounterEnd(encounterID)
	if self.current and self.current.encounterID == encounterID then
		self:EndFight()
		-- Boss can chain straight into trash without leaving combat (M+);
		-- PLAYER_REGEN_DISABLED won't re-fire, so open a new segment now.
		if UnitAffectingCombat("player") then
			self:StartFight()
		end
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
