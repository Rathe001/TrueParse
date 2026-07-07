-- Tracks who is in the group: GUID -> player info, plus pet -> owner mapping.
-- The CLEU hot path uses ResolveGUID for O(1) attribution.
local _, TP = ...

local Roster = {
	players = {},  -- [guid] = { guid, name, class, role, unit }
	petOwner = {}, -- [petGUID] = ownerGUID
}
TP.Roster = Roster

local unitScratch = {}

function Roster:OnEnable()
	local Addon = TP.Addon
	local function rebuild()
		Roster:Rebuild()
	end
	Addon:RegisterEvent("GROUP_ROSTER_UPDATE", rebuild)
	Addon:RegisterEvent("PLAYER_ENTERING_WORLD", rebuild)
	Addon:RegisterEvent("UNIT_PET", function(_, unit)
		Roster:UpdatePets()
	end)
	self:Rebuild()
end

function Roster:Rebuild()
	wipe(self.players)
	wipe(self.petOwner)
	for _, unit in ipairs(TP.Compat.GroupUnits(unitScratch)) do
		if UnitExists(unit) then
			local guid = UnitGUID(unit)
			if guid then
				local _, class = UnitClass(unit)
				self.players[guid] = {
					guid = guid,
					name = GetUnitName(unit, true) or UNKNOWN,
					class = class or "PRIEST",
					role = TP.Compat.GetRole(unit),
					unit = unit,
				}
			end
		end
	end
	self:UpdatePets()
	TP.Addon:SendMessage("TrueParse_ROSTER_CHANGED")
end

function Roster:UpdatePets()
	wipe(self.petOwner)
	for guid, info in pairs(self.players) do
		local petUnit = TP.Compat.PetUnit(info.unit)
		if petUnit and UnitExists(petUnit) then
			local petGUID = UnitGUID(petUnit)
			if petGUID then
				self.petOwner[petGUID] = guid
			end
		end
	end
end

-- Maps a combat log source GUID to a roster player GUID (directly, or via
-- pet ownership). Returns nil for anything outside the group.
function Roster:ResolveGUID(guid)
	if self.players[guid] then
		return guid
	end
	return self.petOwner[guid]
end
