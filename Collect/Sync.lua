-- Group sync v1: each TrueParse user broadcasts their own spec + item level
-- to the group. That's perfect first-party data — no inspection lag or
-- range problems — and it upgrades everyone's scoring inputs. Payloads are
-- only trusted for GUIDs actually present in our roster.
local _, TP = ...

local Sync = {}
TP.Sync = Sync

local PREFIX = "TrueParse"
local WIRE_VERSION = 1

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
	if not version then
		return
	end
	local info = TP.Roster.players[guid]
	if not info then
		return -- claimed GUID isn't in our group: ignore
	end
	specID = tonumber(specID)
	ilvl = tonumber(ilvl)
	if specID and specID > 0 then
		info.specID = specID
	end
	if ilvl and ilvl > 0 then
		info.ilvl = ilvl
	end
	TP.Roster.cache[guid] = { specID = info.specID, ilvl = info.ilvl }
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
