-- Pre-pull readiness. Out of combat, aura data is never secret-locked, so a
-- slow sampler snapshots which raid-buff categories each group member has;
-- when combat starts the latest snapshot is frozen as "the pull state".
-- StampFight then assigns each PROVIDER their coverage fraction — the priest
-- answers for missing Fortitude, not the player who lacked it.
local _, TP = ...

local Readiness = {
	snapshot = {},   -- [guid] = { [categoryKey] = true }, refreshed out of combat
	prePull = nil,   -- frozen copy of snapshot at combat start
	prePullAt = nil,
}
TP.Readiness = Readiness

local SCAN_PERIOD = 10
local MAX_SNAPSHOT_AGE = 600 -- ignore stale pulls (e.g. captured long after)

-- Returns true if ANY aura was readable: a living player always has some
-- buff, so zero readable auras means "couldn't scan" (range/phasing), not
-- "unbuffed".
local function scanUnit(unit, buffs)
	local sawAny = false
	for i = 1, 60 do
		local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
		if not ok or not aura then
			break
		end
		sawAny = true
		local spellId = aura.spellId
		if spellId and not TP.Compat.IsSecret(spellId) then
			for _, category in ipairs(TP.GROUP_BUFFS) do
				if category.auras[spellId] then
					buffs[category.key] = true
				end
			end
		end
	end
	return sawAny
end

local function scan()
	if not TP.GROUP_BUFFS or InCombatLockdown()
		or not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then
		return
	end
	wipe(Readiness.snapshot)
	for guid, info in pairs(TP.Roster.players) do
		-- Only members we can actually read count; out-of-range players were
		-- being recorded as "no buffs" and providers falsely penalized.
		if UnitExists(info.unit) and UnitIsVisible(info.unit) then
			local buffs = {}
			if scanUnit(info.unit, buffs) then
				Readiness.snapshot[guid] = buffs
			end
		end
	end
end

local function freeze()
	local copy = {}
	for guid, buffs in pairs(Readiness.snapshot) do
		local set = {}
		for key in pairs(buffs) do
			set[key] = true
		end
		copy[guid] = set
	end
	Readiness.prePull = copy
	Readiness.prePullAt = time()
end

-- Called by FightHistory when a fight record is built: computes coverage per
-- applicable category and stamps each provider's worst coverage fraction.
function Readiness:StampFight(fight)
	local prePull = self.prePull
	if not TP.GROUP_BUFFS or not prePull or not self.prePullAt
		or (time() - self.prePullAt) > MAX_SNAPSHOT_AGE then
		return
	end
	for _, category in ipairs(TP.GROUP_BUFFS) do
		local providerPresent = false
		for _, p in pairs(fight.players) do
			if p.class and category.providers[p.class] then
				providerPresent = true
				break
			end
		end
		if providerPresent then
			local total, covered = 0, 0
			for guid in pairs(fight.players) do
				local known = prePull[guid]
				if known then
					total = total + 1
					if known[category.key] then
						covered = covered + 1
					end
				end
			end
			if total > 0 then
				local coverage = covered / total
				for _, p in pairs(fight.players) do
					if p.class and category.providers[p.class] then
						p.buffCoverage = math.min(p.buffCoverage or 1, coverage)
					end
				end
			end
		end
	end
end

-- /tp buffs: live view of what the scanner sees, for hunting wrong or
-- missing aura IDs (several MoP buffs apply different IDs than their cast).
-- The own-auras line prints real spell IDs so an unrecognized raid buff
-- identifies itself in one paste.
function Readiness:Report()
	if not TP.GROUP_BUFFS then
		TP.Addon:Print("No buff categories for this game version.")
		return
	end
	scan()
	TP.Addon:Print("Live buff scan:")
	for _, category in ipairs(TP.GROUP_BUFFS) do
		local total, covered, missing = 0, 0, {}
		for guid, info in pairs(TP.Roster.players) do
			local known = Readiness.snapshot[guid]
			if known then
				total = total + 1
				if known[category.key] then
					covered = covered + 1
				else
					missing[#missing + 1] = info.name or "?"
				end
			end
		end
		local line = ("  %s: %d/%d covered"):format(category.label, covered, total)
		if #missing > 0 and #missing <= 5 then
			line = line .. " - missing: " .. table.concat(missing, ", ")
		end
		TP.Addon:Print(line)
	end
	local own = {}
	for i = 1, 60 do
		local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", i, "HELPFUL")
		if not ok or not aura then
			break
		end
		if aura.spellId and not TP.Compat.IsSecret(aura.spellId)
			and ((aura.duration or 0) == 0 or (aura.duration or 0) >= 1500) then
			own[#own + 1] = ("%s(%d)"):format(aura.name or "?", aura.spellId)
		end
	end
	TP.Addon:Print("Your long/permanent auras: " .. table.concat(own, ", "))
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:SetScript("OnEvent", freeze)

function Readiness:OnEnable()
	C_Timer.NewTicker(SCAN_PERIOD, scan)
	scan()
end
