-- Tracks who is in the group: GUID -> player info, plus pet -> owner mapping.
-- The CLEU hot path uses ResolveGUID for O(1) attribution.
local _, TP = ...

local Roster = {
	players = {},     -- [guid] = { guid, name, class, role, unit, specID?, ilvl? }
	petOwner = {},    -- [petGUID] = ownerGUID (permanent pets; rebuilt on UNIT_PET)
	summonOwner = {}, -- [guardianGUID] = ownerGUID (wolves/gargoyles/army/treants,
	                  -- learned from SPELL_SUMMON; guardians never appear as
	                  -- "pet" units and their damage was falling on the floor)
	summonCount = 0,
	cache = {},       -- [guid] = { specID?, ilvl? } survives roster rebuilds
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
	-- a spec swap changes nobody's ROSTER, so nothing above fires: a
	-- flex healer's first pull after swapping scored vs the OLD spec's
	-- population (2026-07-16, Josh's druid). Rebuild re-reads own spec
	-- live, and the ROSTER_CHANGED message re-hellos so groupmates
	-- learn the new spec too. Both event names, pcall'd: retail fires
	-- PLAYER_SPECIALIZATION_CHANGED, Classic dual-spec swaps fire
	-- ACTIVE_TALENT_GROUP_CHANGED.
	pcall(Addon.RegisterEvent, Addon, "PLAYER_SPECIALIZATION_CHANGED", rebuild)
	pcall(Addon.RegisterEvent, Addon, "ACTIVE_TALENT_GROUP_CHANGED", rebuild)
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
			-- Midnight can secret unit identity mid-combat (rebuilds fire on
			-- joins/leaves): a secret GUID as a table key throws, a secret
			-- name poisons later concats. Skip the member this pass; the
			-- next roster event fills them in.
			if guid and TP.Compat.IsSecret(guid) then
				guid = nil
			end
			if guid then
				local _, class = UnitClass(unit)
				local name = GetUnitName(unit, true)
				if name and TP.Compat.IsSecret(name) then
					name = nil
				end
				local cached = self.cache[guid]
				local info = {
					guid = guid,
					name = name or UNKNOWN,
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
		-- Offline or cross-zone members make the server spam "Unknown unit."
		-- red text: only inspect units that are connected AND actually
		-- loaded/phased in (UnitIsVisible), not merely in the group.
		if info and UnitExists(info.unit)
			and UnitIsConnected(info.unit)
			and UnitIsVisible(info.unit)
			and CanInspect(info.unit) then
			inspectingGUID = guid
			NotifyInspect(info.unit)
			-- INSPECT_READY may never arrive (range/phasing edge): time out
			-- rather than stalling the queue forever
			C_Timer.After(5, function()
				if inspectingGUID == guid then
					inspectingGUID = nil
					Roster:ProcessInspectQueue()
				end
			end)
			return
		end
	end
end

function Roster:OnInspectReady(guid)
	local info = self.players[guid]
	if info and UnitExists(info.unit) and UnitGUID(info.unit) == guid then
		local ilvl = C_PaperDollInfo and C_PaperDollInfo.GetInspectItemLevel
			and C_PaperDollInfo.GetInspectItemLevel(info.unit)
		if not (ilvl and ilvl > 0) then
			-- Classic clients return nothing here: average the inspected
			-- unit's equipped item levels ourselves
			local total, count = 0, 0
			for slot = 1, 17 do
				if slot ~= 4 then -- shirt
					local link = GetInventoryItemLink(info.unit, slot)
					if link then
						local getLevel = (C_Item and C_Item.GetDetailedItemLevelInfo)
							or GetDetailedItemLevelInfo
						local itemLevel = getLevel and getLevel(link)
						if itemLevel and itemLevel > 0 then
							total = total + itemLevel
							count = count + 1
						end
					end
				end
			end
			if count >= 8 then
				ilvl = total / count
			end
		end
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

-- Maps a combat log source GUID to a roster player GUID (directly, via
-- permanent pet, or via tracked summon). Returns nil outside the group.
function Roster:ResolveGUID(guid)
	if self.players[guid] then
		return guid
	end
	return self.petOwner[guid] or self.summonOwner[guid]
end

-- SPELL_SUMMON: a group member (or their pet) summoned a guardian; credit
-- its future damage/healing to the player. Chained resolve handles pets
-- summoning pets. Table pruned by size so a long raid night can't grow it
-- unboundedly (stale entries are harmless; missing ones drop attribution).
function Roster:NoteSummon(srcGUID, summonedGUID)
	local owner = self:ResolveGUID(srcGUID)
	if not owner or not summonedGUID then
		return
	end
	if self.summonCount > 600 then
		wipe(self.summonOwner)
		self.summonCount = 0
	end
	if not self.summonOwner[summonedGUID] then
		self.summonCount = self.summonCount + 1
	end
	self.summonOwner[summonedGUID] = owner
end
