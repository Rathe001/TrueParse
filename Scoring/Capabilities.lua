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

-- MoP Classic: Rebuke/Spear Hand Strike/Skull Bash are available to all
-- specs of their classes; only priests lack an interrupt.
local mopRules = false

function Capabilities.SetMoPRules(enabled)
	mopRules = enabled and true or false
end

function Capabilities.CanInterrupt(class, role)
	if not class then
		return true -- unknown class: don't punish, don't exempt others
	end
	if mopRules then
		return class ~= "PRIEST"
	end
	if NO_KICK[class] then
		return false
	end
	if role == "HEALER" and NO_KICK_AS_HEALER[class] then
		return false
	end
	return true
end

-- Friendly-dispel capability (coarse, class level): these classes have some
-- friendly cleanse on at least most specs, in MoP and retail alike. Pure
-- damage classes must not be scored on dispels they cannot perform.
local CAN_DISPEL = {
	PRIEST = true, PALADIN = true, DRUID = true, SHAMAN = true,
	MONK = true, MAGE = true, EVOKER = true,
}

function Capabilities.CanDispel(class)
	if not class then
		return true
	end
	return CAN_DISPEL[class] or false
end

-- Support specs whose output is transferred into OTHER players' numbers
-- (Augmentation Evoker). Their personal damage massively understates their
-- contribution and no support-damage attribute exists in C_DamageMeter, so
-- they get their own scoring role with calibrated expectations instead of
-- being measured against regular DPS.
local SUPPORT_SPEC_ICONS = {
	[5198700] = true, -- Evoker: Augmentation
}

function Capabilities.EffectiveRole(role, specIconID, specID)
	if specIconID and SUPPORT_SPEC_ICONS[specIconID] then
		return "SUPPORT"
	end
	-- The SPEC outranks the assigned group role: solo and open-world
	-- content assign no role (everyone falls back to DAMAGER), which
	-- graded a Mistweaver as DPS and handed them the non-healer
	-- Lifesaver award for doing their actual job.
	local specRole = specID and TP.SPEC_ROLES and TP.SPEC_ROLES[specID]
	if specRole then
		return specRole
	end
	if role == "TANK" or role == "HEALER" then
		return role
	end
	return "DAMAGER"
end
