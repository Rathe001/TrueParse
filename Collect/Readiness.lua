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

local function scanUnit(unit, buffs)
	for i = 1, 60 do
		local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, unit, i, "HELPFUL")
		if not ok or not aura then
			break
		end
		local spellId = aura.spellId
		if spellId and not TP.Compat.IsSecret(spellId) then
			for _, category in ipairs(TP.GROUP_BUFFS) do
				if category.auras[spellId] then
					buffs[category.key] = true
				end
			end
		end
	end
end

local function scan()
	if not TP.GROUP_BUFFS or InCombatLockdown()
		or not C_UnitAuras or not C_UnitAuras.GetAuraDataByIndex then
		return
	end
	wipe(Readiness.snapshot)
	for guid, info in pairs(TP.Roster.players) do
		if UnitExists(info.unit) then
			local buffs = {}
			scanUnit(info.unit, buffs)
			Readiness.snapshot[guid] = buffs
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

local frame = CreateFrame("Frame")
frame:RegisterEvent("PLAYER_REGEN_DISABLED")
frame:SetScript("OnEvent", freeze)

function Readiness:OnEnable()
	C_Timer.NewTicker(SCAN_PERIOD, scan)
	scan()
end
