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
function Sync:RecordFightReport(guid, duration, defensives, consumables, readyAtDeath, buffUptime, activity, casts, x)
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
		-- retail self-coach: own signature-spell counts, LOCAL reports
		-- only (the wire never carries tables)
		casts = casts,
		-- extended self-facts (X: wire, 2026-07-25): healthstones,
		-- avoidance counts, swing damage, mitigation uptime
		x = x,
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

-- Extended self-facts ride a SEPARATE message: the F: parsers are
-- $-anchored on every shipped version, so appending fields there would
-- make old clients drop the whole report. Unknown prefixes are ignored,
-- so X: is safe to introduce. key=value pairs, numbers only.
function Sync:BroadcastExtendedReport(duration, x)
	local channel = commChannel()
	if not channel or not x or not next(x) then
		return
	end
	local parts = {}
	for k, v in pairs(x) do
		-- numbers only: tables (the spike map) ride the local report
		if type(v) == "number" then
			parts[#parts + 1] = ("%s=%d"):format(k, v)
		end
	end
	if #parts == 0 then
		return
	end
	table.sort(parts) -- deterministic wire text
	self:SendCommMessage(PREFIX, ("X:1:%s:%d:%s"):format(
		UnitGUID("player"), math.floor(duration + 0.5), table.concat(parts, ",")),
		channel)
end

-- Attach an extended report to its base entry (matched by the same
-- duration fingerprint), or hold it alone until AttachReports runs
function Sync:RecordExtendedReport(guid, duration, x)
	local list = self.reports[guid]
	if not list then
		list = {}
		self.reports[guid] = list
	end
	for _, r in ipairs(list) do
		if math.abs((r.duration or 0) - duration) <= 3 then
			r.x = r.x or x
			return
		end
	end
	list[#list + 1] = { duration = duration, x = x, at = time() }
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
				-- self-reports measure the UNTRIMMED combat window; match
				-- both clocks (audit 2026-07-16: the WCL trim pushed intro
				-- fights past tolerance and dropped every report)
				local diff = math.abs((report.duration or 0) - (fight.duration or 0))
				if fight.rawDuration then
					diff = math.min(diff, math.abs((report.duration or 0) - fight.rawDuration))
				end
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
				-- a readyAtDeath report means this player DIED: retail's
				-- Deaths attribute reads secret->0 and deathTimeSeconds
				-- only covers players still dead at the end, so brez'd
				-- deaths vanished (Josh 2026-07-25: a many-death kill
				-- reported "deathless"). Works for old-version reporters
				-- too - readyAtDeath has been on the wire since 1.0.
				if report.readyAtDeath and (p.metrics.deaths or 0) == 0 then
					p.metrics.deaths = 1
				end
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
				-- retail self-coach: own cast counts feed ParseGap for the
				-- LOCAL player's card (CLEU fills this on Classic)
				if p.metrics.profCasts == nil and report.casts then
					p.metrics.profCasts = report.casts
				end
				-- extended self-facts (X: wire, 2026-07-25): the MoP-grade
				-- ingredients retail can't observe. CLEU fills these for
				-- everyone on Classic, so the observation wins there
				local x = report.x
				if x then
					local m = p.metrics
					if m.healthstones == nil and x.hs then
						m.healthstones = x.hs
					end
					if m.swingsLanded == nil and x.sl then
						m.swingsLanded = x.sl
						m.swingsAvoided = x.sa or 0
						m.swingDamageTaken = x.sd
					end
					if m.mitigationPct == nil and x.mi then
						m.mitigationPct = x.mi
					end
					-- lust window: any reporter's own aura stamps the
					-- fight-level moment; per-player usage rides along
					if fight.lustAt == nil and x.la then
						fight.lustAt = x.la
					end
					if m.lustCasts == nil and x.lc then
						m.lustCasts = x.lc
					end
					if m.lastOffensiveAt == nil and x.lo then
						m.lastOffensiveAt = x.lo
					end
					if m.manaMinPct == nil and x.mm then
						m.manaMinPct = x.mm
						m.dryAt = x.dr
					end
					if m.spikeWindows == nil and x.sw then
						m.spikeWindows = x.sw
						m.spikeCovered = x.sc or 0
						m.defensiveUses = x.du
					end
					if m.spikeMap == nil and x.map then
						m.spikeMap = x.map
					end
					-- own deaths are ground truth: they can only RAISE the
					-- observed count (the meter undercounts brez'd deaths)
					if x.de and (m.deaths or 0) < x.de then
						m.deaths = x.de
					end
					if x.dt and x.dt > 0 and p.deathTime == nil then
						p.deathTime = x.dt
					end
					if m.combatRezzes == nil and x.rz then
						m.combatRezzes = x.rz
					end
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

-- "Wipe it" permission (Josh 2026-07-26): when any raid lead or assist
-- runs TrueParse, only THEY may call it; otherwise anyone with the addon
-- can. unit nil = check the local player.
local function unitIsOfficer(unit)
	return unit and (UnitIsGroupLeader(unit) or UnitIsGroupAssistant(unit))
end

function Sync:WipeCallPermitted(guid)
	local anyOfficerHasAddon = false
	for g, info in pairs(TP.Roster.players) do
		if info.unit and unitIsOfficer(info.unit)
			and (self.users[g] or UnitIsUnit(info.unit, "player")) then
			anyOfficerHasAddon = true
			break
		end
	end
	local unit
	if guid then
		local info = TP.Roster.players[guid]
		unit = info and info.unit
	else
		unit = "player"
	end
	return unitIsOfficer(unit) or not anyOfficerHasAddon
end

-- Local button press: record + broadcast so every install locks out
function Sync:BroadcastWipeCall()
	if not IsInGroup() then
		return
	end
	self:SendCommMessage(PREFIX, ("C:%d"):format(GetServerTime()), commChannel())
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
			-- handshake (audit 2026-07-16: the unknown-SENDER test was
			-- backwards — a reloader's hello arrived at peers who all
			-- knew them, so nobody replied and the reloader stayed
			-- blind). A hello can't tell us whether the sender knows
			-- US, so reply whenever we haven't announced recently; our
			-- own fresh hello suppresses replying to the replies,
			-- which kills the storm.
			if time() - (self.helloAt or 0) > 15 then
				self:QueueHello()
			end
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

	-- "Wipe it" call: "C:<serverTime>". First one per fight wins across
	-- every install; the sender must hold the same permission the button
	-- itself enforces (lead/assist, or anyone when no officer has the
	-- addon). Clock skew beyond 30s is treated as "now".
	local callT = message:match("^C:(%d+)$")
	if callT then
		local seg = TP.Segments and TP.Segments.current
		if not seg or seg.manualWipeAt then
			return
		end
		local senderGuid
		for g, info in pairs(TP.Roster.players) do
			if info.name and Ambiguate(info.name, "none") == Ambiguate(sender, "none") then
				senderGuid = g
				break
			end
		end
		if not senderGuid or not self:WipeCallPermitted(senderGuid) then
			return
		end
		local skew = GetServerTime() - tonumber(callT)
		if skew < 0 or skew > 30 then
			skew = 0
		end
		TP.Segments:ManualWipeCall((GetTime() - seg.startTime) - skew, Ambiguate(sender, "none"))
		return
	end

	-- weekly standings for /tp guild: "W:<week>:<gpa*10>:<fights>:<tops>"
	local wWeek, wGpa, wFights, wTops = message:match("^W:(%d+):(%d+):(%d+):(%d+)$")
	-- sanity-bound remote claims like every other wire path (audit
	-- 2026-07-16): a garbage gpa of 9999999 sorted to rank 1
	if wWeek and (tonumber(wGpa) > 990 or tonumber(wFights) > 500) then
		wWeek = nil
	end
	if wWeek then
		local wGuid
		for guid2, info2 in pairs(TP.Roster.players) do
			if senderOwnsGuid(sender, guid2) then
				wGuid = guid2
				break
			end
		end
		if wGuid then
			self.weekBoard = self.weekBoard or {}
			self.weekBoard[wGuid] = {
				name = (sender or "?"):match("^([^-]+)") or sender,
				week = tonumber(wWeek), gpa = tonumber(wGpa) / 10,
				fights = tonumber(wFights), tops = tonumber(wTops), seen = time(),
			}
		end
		return
	end

	-- extended self-facts: X:1:guid:duration:k=v,k=v (2026-07-25)
	local xVersion, xGuid, xDur, xFields = message:match("^X:(%d+):([^:]+):(%d+):(.+)$")
	if xVersion then
		if xGuid == UnitGUID("player") then
			return -- our own broadcast looping back
		end
		if not TP.Roster.players[xGuid] or not senderOwnsGuid(sender, xGuid) then
			return
		end
		-- sanity-bound every field; unknown keys are carried (forward
		-- compatible) but still numeric-only by construction
		local CAPS = { hs = 10, sl = 20000, sa = 20000, sd = 2^43, mi = 100,
			la = 7200, lc = 50, lo = 7200, dr = 7200, mm = 100,
			sw = 50, sc = 50, du = 50, de = 20, dt = 7200, rz = 10 }
		local x = {}
		for k, v in xFields:gmatch("(%a+)=(%-?%d+)") do
			local n = tonumber(v)
			if n and n >= 0 then
				x[k] = math.min(n, CAPS[k] or n)
			end
		end
		if next(x) then
			self:RecordExtendedReport(xGuid, tonumber(xDur) or 0, x)
		end
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
		-- merge, never replace: a full overwrite here destroyed the
	-- addonVersion/announces learned from the hello, so the announcer
	-- election forgot its voters after the first fight (audit 2026-07-16)
	local known = self.users[fGuid]
	if known then
		known.version = tonumber(fVersion)
		known.seen = time()
	else
		self.users[fGuid] = { version = tonumber(fVersion), seen = time() }
	end
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
	-- weekly standing rides along after each capture (one small message)
	self:RegisterMessage("TrueParse_FIGHT_CAPTURED", function()
		Sync:BroadcastWeek()
	end)
	self:QueueHello()
end

function Sync:BroadcastWeek()
	local mw = TP.Addon.db.global.myWeek
	local channel = commChannel()
	if not mw or not channel or mw.fights == 0 then
		return
	end
	self:SendCommMessage(PREFIX, ("W:%d:%d:%d:%d"):format(
		mw.week, math.floor(mw.scoreSum / mw.fights * 10 + 0.5), mw.fights, mw.tops), channel)
end
