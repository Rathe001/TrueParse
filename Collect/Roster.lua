-- Tracks who is in the group: GUID -> player info, plus pet -> owner mapping.
-- The CLEU hot path uses ResolveGUID for O(1) attribution.
local _, TP = ...

local Roster = {
	players = {},  -- [guid] = { guid, name, class, role, unit, specID?, ilvl? }
	petOwner = {}, -- [petGUID] = ownerGUID
	cache = {},    -- [guid] = { specID?, ilvl? } survives roster rebuilds
}
TP.Roster = Roster

local unitScratch = {}
local inspectQueue = {}
local inspectingGUID

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
	Addon:RegisterEvent("INSPECT_READY", function(_, guid)
		Roster:OnInspectReady(guid)
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
				local cached = self.cache[guid]
				local info = {
					guid = guid,
					name = GetUnitName(unit, true) or UNKNOWN,
					class = class or "PRIEST",
					role = TP.Compat.GetRole(unit),
					unit = unit,
					specID = cached and cached.specID or nil,
					ilvl = cached and cached.ilvl or nil,
				}
				if unit == "player" then
					if GetSpecialization and GetSpecializationInfo then
						local specIndex = GetSpecialization()
						if specIndex then
							info.specID = GetSpecializationInfo(specIndex)
						end
					end
					if GetAverageItemLevel then
						local _, equipped = GetAverageItemLevel()
						if equipped and equipped > 0 then
							info.ilvl = math.floor(equipped + 0.5)
						end
					end
					self.cache[guid] = { specID = info.specID, ilvl = info.ilvl }
				end
				self.players[guid] = info
			end
		end
	end
	self:UpdatePets()
	self:QueueInspections()
	TP.Addon:SendMessage("TrueParse_ROSTER_CHANGED")
end

-- Out-of-combat inspection fills in spec + item level for group members;
-- one pending inspect at a time, spaced out to be polite to the server.
function Roster:QueueInspections()
	if not (NotifyInspect and CanInspect) then
		return
	end
	wipe(inspectQueue)
	for guid, info in pairs(self.players) do
		if info.unit ~= "player" and not (info.ilvl and info.specID) then
			inspectQueue[#inspectQueue + 1] = guid
		end
	end
	self:ProcessInspectQueue()
end

function Roster:ProcessInspectQueue()
	if inspectingGUID or InCombatLockdown() then
		return
	end
	while #inspectQueue > 0 do
		local guid = table.remove(inspectQueue, 1)
		local info = self.players[guid]
		if info and UnitExists(info.unit) and CanInspect(info.unit) then
			inspectingGUID = guid
			NotifyInspect(info.unit)
			return
		end
	end
end

function Roster:OnInspectReady(guid)
	local info = self.players[guid]
	if info and UnitExists(info.unit) and UnitGUID(info.unit) == guid then
		local ilvl = C_PaperDollInfo and C_PaperDollInfo.GetInspectItemLevel
			and C_PaperDollInfo.GetInspectItemLevel(info.unit)
		if ilvl and ilvl > 0 and not TP.Compat.IsSecret(ilvl) then
			info.ilvl = math.floor(ilvl + 0.5)
		end
		local specID = GetInspectSpecialization and GetInspectSpecialization(info.unit)
		if specID and specID > 0 and not TP.Compat.IsSecret(specID) then
			info.specID = specID
		end
		self.cache[guid] = { specID = info.specID, ilvl = info.ilvl }
	end
	if inspectingGUID == guid then
		inspectingGUID = nil
		if ClearInspectPlayer then
			ClearInspectPlayer()
		end
		C_Timer.After(1.5, function()
			Roster:ProcessInspectQueue()
		end)
	end
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
