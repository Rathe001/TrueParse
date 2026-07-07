-- Combat data source for Midnight (12.0+) clients, where the raw combat log
-- is forbidden to addons. Blizzard computes meter aggregates natively and
-- exposes them per attribute via C_DamageMeter combat sessions:
--   session = { combatSources = {...}, totalAmount, maxAmount, durationSeconds }
--   combatSource = { name, sourceGUID, classFilename, specIconID,
--                    totalAmount, isLocalPlayer, ... }
-- Caveat: during "server combat" values may be SECRET (readable only by
-- secure widgets); Lua cannot sort/compare them, so every consumer must
-- check IsLocked() first and degrade gracefully until values unlock.
local _, TP = ...

local Meter = {}
TP.BlizzardMeter = Meter

Meter.available = (C_DamageMeter ~= nil)

local EMPTY = { combatSources = {}, totalAmount = 0, maxAmount = 0, durationSeconds = 0 }

-- Session for one attribute (Enum.DamageMeterType.*). Display priority:
-- live fight -> most recent finished fight -> overall. Returns the session
-- plus a scope tag for labeling.
function Meter:GetSession(meterType)
	if not self.available then
		return EMPTY, "none"
	end
	local session = C_DamageMeter.GetCombatSessionFromType(Enum.DamageMeterSessionType.Current, meterType)
	if session and #session.combatSources > 0 then
		return session, "current"
	end
	local all = C_DamageMeter.GetAvailableCombatSessions()
	local latest = all and all[#all] -- list is oldest -> newest
	if latest and latest.sessionID then
		session = C_DamageMeter.GetCombatSessionFromID(latest.sessionID, meterType)
		if session and #session.combatSources > 0 then
			return session, "last"
		end
	end
	session = C_DamageMeter.GetCombatSessionFromType(Enum.DamageMeterSessionType.Overall, meterType)
	return session or EMPTY, "overall"
end

-- True while the session's values are secrets (mid-combat in restricted
-- content). Checked on the first source; all fields lock together.
function Meter:IsLocked(session)
	local src = session.combatSources[1]
	if not src then
		return false
	end
	local IsSecret = TP.Compat.IsSecret
	return IsSecret(src.name) or IsSecret(src.totalAmount)
end
