-- Single choke point for client API divergence. When Classic support lands,
-- only this file should need version branches; callers stay untouched.
local _, TP = ...

local Compat = {}
TP.Compat = Compat

Compat.IS_RETAIL = (WOW_PROJECT_ID == WOW_PROJECT_MAINLINE)

-- Midnight (12.0+) forbids addons from registering COMBAT_LOG_EVENT_UNFILTERED
-- and instead exposes Blizzard-computed meter data via C_DamageMeter. Keyed on
-- the project, NOT on C_DamageMeter presence: MoP Classic ships the modern
-- engine (C_DamageMeter exists there) but its sessions are non-functional and
-- CLEU remains fully legal.
Compat.HAS_CLEU = not Compat.IS_RETAIL

-- Secret values (12.0+): mid-combat meter data may be readable only by secure
-- widgets; issecretvalue() detects them. Older clients have no secrets.
Compat.IsSecret = issecretvalue or function() return false end

-- The specialization API. 11.2 deprecated the globals in favour of
-- C_SpecializationInfo and marked them for removal; every caller guarded
-- on the global's existence, so the day it goes every retail capture
-- would silently lose its spec and grade against pooled role curves
-- (audit 2026-09-11). Resolved per call, not at load: the headless tests
-- swap the globals mid-run, and Mists still ships only the globals.
-- Each wrapper returns nothing when neither form exists.
local function specAPI(name)
	return function(...)
		local f = (C_SpecializationInfo and C_SpecializationInfo[name]) or _G[name]
		if f then
			return f(...)
		end
	end
end
Compat.GetSpecialization = specAPI("GetSpecialization")
Compat.GetSpecializationInfo = specAPI("GetSpecializationInfo")
Compat.GetSpecializationInfoByID = specAPI("GetSpecializationInfoByID")
Compat.GetSpecializationInfoForClassID = specAPI("GetSpecializationInfoForClassID")
Compat.GetNumSpecializationsForClassID = specAPI("GetNumSpecializationsForClassID")
Compat.GetActiveSpecGroup = specAPI("GetActiveSpecGroup")
Compat.GetInspectSpecialization = specAPI("GetInspectSpecialization")

-- Whether any specialization API exists at all (Classic Era has none)
function Compat.HasSpecAPI()
	return (C_SpecializationInfo and C_SpecializationInfo.GetSpecializationInfoForClassID)
		or GetSpecializationInfoForClassID
end

-- Role from the group role assignment. NONE happens in non-matchmade
-- groups; there the spec (inspected, cached across rebuilds) decides,
-- and only a player with no known spec falls back to DAMAGER. Returns
-- role, assigned - `assigned` says the group role itself answered, so
-- a later inspection can still overrule the fallback.
function Compat.GetRole(unit, specID)
	local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
	-- guard the compare against a secret value like every other live-API
	-- read in this file (Josh 2026-07-26 audit): consistent, cheap
	if role and not Compat.IsSecret(role) and role ~= "NONE" then
		return role, true
	end
	local bySpec = specID and TP.SPEC_ROLES and TP.SPEC_ROLES[specID]
	if bySpec then
		return bySpec, false
	end
	return TP.ROLE.DAMAGER, false
end

-- Fills `out` with the unit tokens of everyone in the group (including the
-- player). Reuses the caller's table to avoid allocation on roster churn.
function Compat.GroupUnits(out)
	wipe(out)
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			out[#out + 1] = "raid" .. i
		end
	else
		out[#out + 1] = "player"
		for i = 1, GetNumSubgroupMembers() do
			out[#out + 1] = "party" .. i
		end
	end
	return out
end

-- specIcon fileID -> { specID, role } for every spec. Combat sources carry
-- specIconID, so this gives fight records a stable, locale-proof spec
-- identity (matching Data/Benchmarks.lua keys) without inspection.
function Compat.BuildSpecIconMap()
	local map = {}
	if not (GetNumClasses and Compat.HasSpecAPI()) then
		return map -- Classic clients
	end
	for classID = 1, GetNumClasses() do
		local numSpecs = Compat.GetNumSpecializationsForClassID(classID) or 0
		for i = 1, numSpecs do
			local specID, _, _, icon, role = Compat.GetSpecializationInfoForClassID(classID, i)
			if specID and icon then
				map[icon] = { specID = specID, role = role }
			end
		end
	end
	return map
end

-- "player" -> "pet", "party3" -> "partypet3", "raid17" -> "raidpet17"
function Compat.PetUnit(unit)
	if unit == "player" then
		return "pet"
	end
	local kind, index = unit:match("^(%a+)(%d+)$")
	if kind == "party" or kind == "raid" then
		return kind .. "pet" .. index
	end
	return nil
end
