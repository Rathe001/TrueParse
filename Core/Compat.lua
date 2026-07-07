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

-- Role from the group role assignment; NONE happens in non-matchmade groups,
-- where we fall back to DAMAGER until spec inspection lands (later phase).
function Compat.GetRole(unit)
	local role = UnitGroupRolesAssigned and UnitGroupRolesAssigned(unit)
	if role and role ~= "NONE" then
		return role
	end
	return TP.ROLE.DAMAGER
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
	if not (GetNumClasses and GetSpecializationInfoForClassID) then
		return map -- Classic clients
	end
	for classID = 1, GetNumClasses() do
		local numSpecs = GetNumSpecializationsForClassID and GetNumSpecializationsForClassID(classID) or 0
		for i = 1, numSpecs do
			local specID, _, _, icon, role = GetSpecializationInfoForClassID(classID, i)
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
