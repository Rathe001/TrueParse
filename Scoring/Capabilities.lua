-- Which classes/roles can perform gated actions. A spec that cannot press
-- the button must never be scored on it — the metric goes inapplicable and
-- its weight redistributes (see Engine.lua).
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Capabilities = {}
TP.Scoring.Capabilities = Capabilities

-- Interrupt capability, v1 granularity: class + role (spec-level tuning can
-- come later; corrections welcome as real data shows 0-kick capable specs).
local NO_KICK = {
	PRIEST = true, -- no interrupt on any spec
}
local NO_KICK_AS_HEALER = {
	PALADIN = true, -- Holy lacks Rebuke
	DRUID = true,   -- Resto lacks Skull Bash
	MONK = true,    -- Mistweaver lacks Spear Hand Strike
}

function Capabilities.CanInterrupt(class, role)
	if not class then
		return true -- unknown class: don't punish, don't exempt others
	end
	if NO_KICK[class] then
		return false
	end
	if role == "HEALER" and NO_KICK_AS_HEALER[class] then
		return false
	end
	return true
end
