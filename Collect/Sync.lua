-- Group sync v1: each TrueParse user broadcasts their own spec + item level
-- to the group. That's perfect first-party data — no inspection lag or
-- range problems — and it upgrades everyone's scoring inputs. Payloads are
-- only trusted for GUIDs actually present in our roster.
local _, TP = ...

local Sync = {}
TP.Sync = Sync

local PREFIX = "TrueParse"
local WIRE_VERSION = 1

local function addonVersion()
	if C_AddOns and C_AddOns.GetAddOnMetadata then
		return C_AddOns.GetAddOnMetadata("TrueParse", "Version") or "0"
	elseif GetAddOnMetadata then
		return GetAddOnMetadata("TrueParse", "Version") or "0"
	end
	return "0"
end

-- "1.2.10" -> 10210, for ordering; unparseable -> 0
local function versionNumber(v)
	local a, b, c = tostring(v or ""):match("^(%d+)%.(%d+)%.(%d+)")
	if not a then
		return 0
	end
	return tonumber(a) * 10000 + tonumber(b) * 100 + tonumber(c)
end

local versionNagged = false
local function checkNewerVersion(remoteVersion)
	if versionNagged or not remoteVersion then
		return
	end
	if versionNumber(remoteVersion) > versionNumber(addonVersion()) then
		versionNagged = true
		TP.Addon:Print(("A groupmate is running TrueParse %s (you have %s) — update when you get a chance."):format(
			remoteVersion, addonVersion()))
	end
end

Sync.users = {}   -- [guid] = { version, seen } — anyone who ever spoke on the channel
Sync.reports = {} -- [guid] = { {duration, defensives, at}, ... } pending fight reports

local REPORT_TTL = 7200

-- readyAtDeath: -1/nil = didn't die; 0+ = defensives off cooldown at death
-- buffUptime: -1/nil = not a support spec; 0-100 = Ebon Might uptime %
-- activity: -1/nil = unknown; 0-100 = own active-time percent
function Sync:RecordFightReport(guid, duration, defensives, consumables, readyAtDeath, buffUptime, activity)
	local list = self.reports[guid]
	if not list then
		list = {}
		self.reports[guid] = list
	end
	list[#list + 1] = {
		duration = duration, defensives = defensives,
		consumables = consumables,
		readyAtDeath = (readyAtDeath and readyAtDeath >= 0) and readyAtDeath or nil,
		buffUptime = (buffUptime and buffUptime >= 0) and math.min(buffUptime, 100) or nil,
		activity = (activity and activity >= 0) and math.min(activity, 100) or nil,
		at = time(),
	}
	-- prune stale
	for i = #list, 1, -1 do
		if (time() - (list[i].at or 0)) > REPORT_TTL then
			table.remove(list, i)
		end
	end
end

-- LFR/LFD are INSTANCE groups: plain IsInGroup()/"RAID" never saw them,
-- so hellos and reports silently went nowhere and everyone rendered "?"
local function commChannel()
	if IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then
		return "INSTANCE_CHAT"
	elseif IsInRaid() then
		return "RAID"
	elseif IsInGroup() then
		return "PARTY"
	end
end
Sync.CommChannel = commChannel

function Sync:BroadcastFightReport(duration, defensives, consumables, readyAtDeath, buffUptime, activity)
	-- (own facts are recorded locally by the caller — SelfCasts — before
	-- this broadcast; the receive path drops our own echo)
	local channel = commChannel()
	if not channel then
		return
	end
	self:SendCommMessage(PREFIX, ("F:%d:%s:%d:%d:%d:%d:%d:%d"):format(
		WIRE_VERSION, UnitGUID("player"), math.floor(duration + 0.5),
		defensives or 0, consumables or 0, readyAtDeath or -1, buffUptime or -1,
		activity or -1),
		channel)
end

-- Attach pending peer reports to a freshly captured fight, matching by
-- combat-window duration (a strong fingerprint since retail captures can
-- arrive long after the pull, in bulk). Also stamps addon presence.
function Sync:AttachReports(fight)
	for guid, p in pairs(fight.players) do
		-- Three-state presence: true = detected, false = confidently not
		-- (our hello went out long enough ago that a reply would have
		-- arrived), nil = unknown (UI shows "?"). Upgrades to true whenever
		-- the player finally answers; never downgrades.
		if p.hasAddon ~= true then
			if p.isLocalPlayer or self.users[guid] ~= nil then
				p.hasAddon = true
			elseif (self.helloAt and (time() - self.helloAt) > 10)
				or (self.enabledAt and (time() - self.enabledAt) > 60) then
				-- the session-age fallback keeps "?" from sticking forever
				-- when no hello went out (the LFR instance-channel bug)
				p.hasAddon = false
			end
		end
		-- gate the match on consumables: defensives may already be filled
		-- by CLEU on Classic, but consumables/readiness only come from
		-- self-reports on both clients
		local list = self.reports[guid]
		if list and p.metrics and p.metrics.consumables == nil then
			local bestIdx, bestDiff
			local tolerance = math.max(8, (fight.duration or 0) * 0.2)
			for i, report in ipairs(list) do
				local diff = math.abs((report.duration or 0) - (fight.duration or 0))
				if diff <= tolerance and (not bestDiff or diff < bestDiff) then
					bestIdx, bestDiff = i, diff
				end
			end
			if bestIdx then
				local report = list[bestIdx]
				if p.metrics.defensives == nil then
					p.metrics.defensives = report.defensives
				end
				p.metrics.consumables = report.consumables
				p.deathReadyDefensives = report.readyAtDeath
				-- The one self-report that IS scored: Ebon Might uptime as a
				-- fraction, feeding the SUPPORT role's buffUptime metric
				if report.buffUptime then
					p.metrics.buffUptime = report.buffUptime / 100
				end
				-- CLEU fills this for everyone on Classic; self-reports
				-- cover retail
				if p.metrics.activityPct == nil and report.activity then
					p.metrics.activityPct = report.activity
				end
				table.remove(list, bestIdx)
				-- award inputs changed (Iron Wall reads defensives)
				if TP.Scoring and TP.Scoring.Awards then
					TP.Scoring.Awards.Invalidate(fight)
				end
			end
		end
	end
end

function Sync:SendHello()
	self.helloTimer = nil
	local channel = commChannel()
	if not channel then
		return
	end
	local myGUID = UnitGUID("player")
	local me = TP.Roster.players[myGUID]
	local p = TP.Addon.db.profile
	local msg = ("H:%d:%s:%d:%d:%s:%d"):format(
		WIRE_VERSION, myGUID,
		(me and me.specID) or 0,
		(me and me.ilvl) or 0,
		addonVersion(),
		(p.announce or p.announceSummary) and 1 or 0) -- announcer election
	self:SendCommMessage(PREFIX, msg, channel)
	self.helloAt = time() -- presence stamps stay "unknown" until replies had time
end

-- One announcer per group: among TrueParse users with announcements
-- enabled, the newest addon version wins (its lines are the best ones);
-- ties break on lowest GUID — deterministic, no negotiation round.
-- Builds too old to carry the flag can't be suppressed remotely, so
-- they don't vote.
function Sync:ShouldAnnounce()
	local myGUID = UnitGUID("player")
	local mine = addonVersion()
	for guid, u in pairs(self.users) do
		if guid ~= myGUID and u.announces and TP.Roster.players[guid] then
			local cmp = TP.CompareVersions(u.addonVersion or "0", mine)
			if cmp > 0 or (cmp == 0 and guid < myGUID) then
				return false -- they outrank us: stay quiet
			end
		end
	end
	return true
end

-- Roster changes fire in bursts (zoning, joins); send one hello per burst
function Sync:QueueHello()
	if self.helloTimer then
		return
	end
	self.helloTimer = self:ScheduleTimer("SendHello", 5)
end

-- A payload's claimed GUID must belong to the SENDER: without this, any
-- groupmate could overwrite teammates' spec/ilvl or inject fight reports
-- for them (defensives, readiness) that flow into cards and history.
local function senderOwnsGuid(sender, guid)
	local info = TP.Roster.players[guid]
	if not info or not info.name or not sender then
		return false
	end
	return Ambiguate(info.name, "none") == Ambiguate(sender, "none")
end

function Sync:OnCommReceived(prefix, message, _, sender)
	if prefix ~= PREFIX then
		return
	end

	local version, guid, specID, ilvl, remoteAddonVersion, announceFlag =
		message:match("^H:(%d+):([^:]+):(%d+):(%d+):([%d%.]+):(%d)$")
	if not version then
		version, guid, specID, ilvl, remoteAddonVersion =
			message:match("^H:(%d+):([^:]+):(%d+):(%d+):([%d%.]+)$")
	end
	if not version then
		-- hello from builds that predate the addon-version field
		version, guid, specID, ilvl = message:match("^H:(%d+):([^:]+):(%d+):(%d+)$")
	end
	if version then
		local info = TP.Roster.players[guid]
		if not info or not senderOwnsGuid(sender, guid) then
			return -- not in our group, or claiming someone else's GUID
		end
		if guid ~= UnitGUID("player") then
			checkNewerVersion(remoteAddonVersion)
		end
		self.users[guid] = { version = tonumber(version), seen = time(),
			addonVersion = remoteAddonVersion,
			announces = announceFlag == "1" or nil }
		specID = tonumber(specID)
		ilvl = tonumber(ilvl)
		-- clamp remote claims: a bogus ilvl of 1e8 turns the gear curve
		-- into inf/NaN scores for the whole card
		if specID and TP.SPEC_ROLES and TP.SPEC_ROLES[specID] then
			info.specID = specID
		end
		if ilvl and ilvl > 0 and ilvl <= 2000 then
			info.ilvl = ilvl
		end
		TP.Roster.cache[guid] = { specID = info.specID, ilvl = info.ilvl }
		return
	end

	local fVersion, fGuid, duration, defensives, consumables, readyAtDeath, buffUptime, activity =
		message:match("^F:(%d+):([^:]+):(%d+):(%d+):(%d+):(%-?%d+):(%-?%d+):(%-?%d+)$")
	if not fVersion then
		-- 7-field format (no activity)
		fVersion, fGuid, duration, defensives, consumables, readyAtDeath, buffUptime =
			message:match("^F:(%d+):([^:]+):(%d+):(%d+):(%d+):(%-?%d+):(%-?%d+)$")
	end
	if not fVersion then
		-- 6-field format from earlier builds (no buff uptime)
		fVersion, fGuid, duration, defensives, consumables, readyAtDeath =
			message:match("^F:(%d+):([^:]+):(%d+):(%d+):(%d+):(%-?%d+)$")
	end
	if not fVersion then
		-- legacy 4-field format from the first builds
		fVersion, fGuid, duration, defensives = message:match("^F:(%d+):([^:]+):(%d+):(%d+)$")
	end
	if fVersion then
		if fGuid == UnitGUID("player") then
			return -- our own broadcast looping back; recorded locally already
		end
		if not TP.Roster.players[fGuid] or not senderOwnsGuid(sender, fGuid) then
			return -- not in our group, or claiming someone else's GUID
		end
		self.users[fGuid] = { version = tonumber(fVersion), seen = time() }
		-- sanity-bound self-reported numbers
		local ready = tonumber(readyAtDeath)
		self:RecordFightReport(fGuid,
			tonumber(duration) or 0,
			math.min(tonumber(defensives) or 0, 50),
			math.min(tonumber(consumables) or 0, 5),
			ready and math.min(ready, 9) or nil,
			tonumber(buffUptime),
			tonumber(activity))
	end
end

function Sync:OnEnable()
	self.enabledAt = time()
	-- Pending reports survive /reload: retail captures land in a bulk
	-- unlock minutes after the fight, and an in-memory staging table
	-- meant any reload in between silently discarded every report not
	-- yet attached (2026-07-14: cost an Aug their Ebon Might uptime and
	-- with it their whole damage attribution). SavedVariables flush on
	-- reload — exactly the event that was killing them.
	local g = TP.Addon.db.global
	g.pendingReports = g.pendingReports or {}
	self.reports = g.pendingReports
	for guid, list in pairs(self.reports) do
		for i = #list, 1, -1 do
			if (time() - (list[i].at or 0)) > REPORT_TTL then
				table.remove(list, i)
			end
		end
		if #list == 0 then
			self.reports[guid] = nil
		end
	end
	LibStub("AceComm-3.0"):Embed(self)
	LibStub("AceEvent-3.0"):Embed(self)
	LibStub("AceTimer-3.0"):Embed(self)
	self:RegisterComm(PREFIX)
	self:RegisterMessage("TrueParse_ROSTER_CHANGED", function()
		Sync:QueueHello()
	end)
	self:QueueHello()
end
