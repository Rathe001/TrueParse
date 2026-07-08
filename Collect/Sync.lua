-- Group sync v1: each TrueParse user broadcasts their own spec + item level
-- to the group. That's perfect first-party data — no inspection lag or
-- range problems — and it upgrades everyone's scoring inputs. Payloads are
-- only trusted for GUIDs actually present in our roster.
local _, TP = ...

local Sync = {}
TP.Sync = Sync

local PREFIX = "TrueParse"
local WIRE_VERSION = 1

Sync.users = {}   -- [guid] = { version, seen } — anyone who ever spoke on the channel
Sync.reports = {} -- [guid] = { {duration, defensives, at}, ... } pending fight reports

local REPORT_TTL = 7200

-- readyAtDeath: -1/nil = didn't die; 0+ = defensives off cooldown at death
function Sync:RecordFightReport(guid, duration, defensives, consumables, readyAtDeath)
	local list = self.reports[guid]
	if not list then
		list = {}
		self.reports[guid] = list
	end
	list[#list + 1] = {
		duration = duration, defensives = defensives,
		consumables = consumables,
		readyAtDeath = (readyAtDeath and readyAtDeath >= 0) and readyAtDeath or nil,
		at = time(),
	}
	-- prune stale
	for i = #list, 1, -1 do
		if (time() - (list[i].at or 0)) > REPORT_TTL then
			table.remove(list, i)
		end
	end
end

function Sync:BroadcastFightReport(duration, defensives, consumables, readyAtDeath)
	if not IsInGroup() then
		return
	end
	self:SendCommMessage(PREFIX, ("F:%d:%s:%d:%d:%d:%d"):format(
		WIRE_VERSION, UnitGUID("player"), math.floor(duration + 0.5),
		defensives or 0, consumables or 0, readyAtDeath or -1),
		IsInRaid() and "RAID" or "PARTY")
end

-- Attach pending peer reports to a freshly captured fight, matching by
-- combat-window duration (a strong fingerprint since retail captures can
-- arrive long after the pull, in bulk). Also stamps addon presence.
function Sync:AttachReports(fight)
	for guid, p in pairs(fight.players) do
		if p.hasAddon == nil then
			p.hasAddon = (p.isLocalPlayer or self.users[guid] ~= nil) or nil
		end
		local list = self.reports[guid]
		if list and p.metrics and p.metrics.defensives == nil then
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
				p.metrics.defensives = report.defensives
				p.metrics.consumables = report.consumables
				p.deathReadyDefensives = report.readyAtDeath
				table.remove(list, bestIdx)
			end
		end
	end
end

function Sync:SendHello()
	self.helloTimer = nil
	if not IsInGroup() then
		return
	end
	local myGUID = UnitGUID("player")
	local me = TP.Roster.players[myGUID]
	local msg = ("H:%d:%s:%d:%d"):format(
		WIRE_VERSION, myGUID,
		(me and me.specID) or 0,
		(me and me.ilvl) or 0)
	self:SendCommMessage(PREFIX, msg, IsInRaid() and "RAID" or "PARTY")
end

-- Roster changes fire in bursts (zoning, joins); send one hello per burst
function Sync:QueueHello()
	if self.helloTimer then
		return
	end
	self.helloTimer = self:ScheduleTimer("SendHello", 5)
end

function Sync:OnCommReceived(prefix, message, _, sender)
	if prefix ~= PREFIX then
		return
	end

	local version, guid, specID, ilvl = message:match("^H:(%d+):([^:]+):(%d+):(%d+)$")
	if version then
		local info = TP.Roster.players[guid]
		if not info then
			return -- claimed GUID isn't in our group: ignore
		end
		self.users[guid] = { version = tonumber(version), seen = time() }
		specID = tonumber(specID)
		ilvl = tonumber(ilvl)
		if specID and specID > 0 then
			info.specID = specID
		end
		if ilvl and ilvl > 0 then
			info.ilvl = ilvl
		end
		TP.Roster.cache[guid] = { specID = info.specID, ilvl = info.ilvl }
		return
	end

	local fVersion, fGuid, duration, defensives, consumables, readyAtDeath =
		message:match("^F:(%d+):([^:]+):(%d+):(%d+):(%d+):(%-?%d+)$")
	if not fVersion then
		-- legacy 4-field format from earlier builds
		fVersion, fGuid, duration, defensives = message:match("^F:(%d+):([^:]+):(%d+):(%d+)$")
	end
	if fVersion then
		if fGuid == UnitGUID("player") then
			return -- our own broadcast looping back; recorded locally already
		end
		if not TP.Roster.players[fGuid] then
			return -- not in our group
		end
		self.users[fGuid] = { version = tonumber(fVersion), seen = time() }
		-- sanity-bound self-reported numbers
		self:RecordFightReport(fGuid,
			tonumber(duration) or 0,
			math.min(tonumber(defensives) or 0, 50),
			math.min(tonumber(consumables) or 0, 5),
			tonumber(readyAtDeath))
	end
end

function Sync:OnEnable()
	LibStub("AceComm-3.0"):Embed(self)
	LibStub("AceEvent-3.0"):Embed(self)
	LibStub("AceTimer-3.0"):Embed(self)
	self:RegisterComm(PREFIX)
	self:RegisterMessage("TrueParse_ROSTER_CHANGED", function()
		Sync:QueueHello()
	end)
	self:QueueHello()
end
