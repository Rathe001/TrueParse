-- Threat discipline: DPS/healers who pull the pack or rip aggro off the
-- tank, and tanks who let mobs chew on the group.
--
-- CLASSIC: UnitThreatSituation is unrestricted, so a 1s in-combat sampler
-- accumulates per player: seconds holding aggro as a non-tank, transitions
-- into aggro (rips), a confirmed body pull (aggro during the opening seconds
-- before any tank established it, held for 2+ samples so a fast taunt
-- forgives it), and per tank the seconds any mob was on a non-tank. Written
-- into the live segment's accumulators; FightHistory:AddFromSegment carries
-- them onto the fight record and Scoring/Engine turns them into penalties.
-- Fairness gates: nothing is attributed while no tank is alive (all-DPS
-- groups, wipes in progress), and a tank "loss" needs a non-tank to actually
-- hold aggro (taunt swaps between two tanks never register).
--
-- RETAIL (Midnight): EXPERIMENT 3 — group threat is expected to be
-- secret-locked mid-combat like every other hostile read; the probe below
-- (gated on /tp probe, like the cast probes) measures what
-- UnitThreatSituation / UnitDetailedThreatSituation actually return in a
-- real dungeon before anything is built on them. VERDICT: pending.
local _, TP = ...

local tankScratch = {} -- reused per sampler tick; never escapes

local Threat = {}
TP.Threat = Threat

local INTERVAL = 1
local PULL_WINDOW = 4 -- seconds of combat that still count as "the pull"

-- ================================ Classic: scored group tracking ==========

local ticker

local function ensureAggro(acc)
	local a = acc.aggro
	if not a then
		a = { time = 0, rips = 0, pulled = false, lost = 0, has = false, pullTicks = 0 }
		acc.aggro = a
	end
	return a
end

local function sample()
	local seg = TP.Segments.current
	if not seg then
		return
	end
	local elapsed = GetTime() - seg.startTime

	-- No living tank: aggro is nobody's job right now (all-DPS groups,
	-- tank death mid-wipe). Attribute nothing this tick.
	wipe(tankScratch)
	local tanks
	for guid, info in pairs(TP.Roster.players) do
		if info.role == "TANK" and UnitExists(info.unit) and not UnitIsDeadOrGhost(info.unit) then
			tanks = tankScratch
			tanks[#tanks + 1] = guid
		end
	end
	if not tanks then
		return
	end

	local nonTankHasAggro = false
	for guid, info in pairs(TP.Roster.players) do
		if info.role ~= "TANK" and UnitExists(info.unit) then
			local acc = seg.players[guid]
			if acc then
				local status = UnitThreatSituation(info.unit)
				local has = (status or 0) >= 2 -- 2/3 = mob is (in)securely theirs
				local a = ensureAggro(acc)
				if has then
					nonTankHasAggro = true
					a.time = a.time + INTERVAL
					if elapsed <= PULL_WINDOW and not seg.group.tankOpened then
						-- Opening aggro before the tank has it: a pull once
						-- they hold it for a second sample (an instant taunt
						-- save keeps it off their record)
						a.pullTicks = a.pullTicks + 1
						if a.pullTicks >= 2 then
							a.pulled = true
						end
					elseif not a.has then
						a.rips = a.rips + 1
					end
				end
				a.has = has
			end
		end
	end

	for _, guid in ipairs(tanks) do
		local info = TP.Roster.players[guid]
		local status = UnitThreatSituation(info.unit)
		if (status or 0) >= 2 then
			seg.group.tankOpened = true
		end
		local acc = seg.players[guid]
		if acc and nonTankHasAggro then
			ensureAggro(acc).lost = ensureAggro(acc).lost + INTERVAL
		end
	end
end

local function startTicker()
	if ticker then
		return
	end
	ticker = C_Timer.NewTicker(INTERVAL, function()
		if not TP.Segments.current then
			ticker:Cancel()
			ticker = nil
			return
		end
		sample()
	end)
end

-- ================================ Retail: EXPERIMENT 3 probe ==============

local counts = {
	selfReads = 0, selfNil = 0, selfSecret = 0,
	groupReads = 0, groupNil = 0, groupSecret = 0,
	detailedReads = 0, detailedSecret = 0,
}
local probeTicker

local function probeEnabled()
	return TP.Addon.db and TP.Addon.db.profile.probe
end

local function probeSample()
	if not probeEnabled() then
		return
	end
	local IsSecret = TP.Compat.IsSecret

	local ok, status = pcall(UnitThreatSituation, "player")
	if ok then
		counts.selfReads = counts.selfReads + 1
		if status == nil then
			counts.selfNil = counts.selfNil + 1
		elseif IsSecret(status) then
			counts.selfSecret = counts.selfSecret + 1
		end
	end

	if UnitExists("target") and UnitCanAttack("player", "target") then
		local okd, isTanking, st, pct = pcall(UnitDetailedThreatSituation, "player", "target")
		if okd then
			counts.detailedReads = counts.detailedReads + 1
			if IsSecret(isTanking) or IsSecret(st) or IsSecret(pct) then
				counts.detailedSecret = counts.detailedSecret + 1
			end
		end
	end

	for _, info in pairs(TP.Roster.players) do
		if UnitExists(info.unit) and not UnitIsUnit(info.unit, "player") then
			local okg, s = pcall(UnitThreatSituation, info.unit)
			if okg then
				counts.groupReads = counts.groupReads + 1
				if s == nil then
					counts.groupNil = counts.groupNil + 1
				elseif IsSecret(s) then
					counts.groupSecret = counts.groupSecret + 1
				end
			end
		end
	end
end

-- Same print-and-persist shape as the cast probes, so verdicts survive the
-- session in db.global.probeLog
local function emit(line)
	TP.Addon:Print(line)
	local db = TP.Addon.db.global
	db.probeLog = db.probeLog or {}
	table.insert(db.probeLog, 1, ("%s %s"):format(date("%m-%d %H:%M"), line))
	for i = #db.probeLog, 31, -1 do
		table.remove(db.probeLog, i)
	end
end

local function probeReport()
	if counts.selfReads + counts.groupReads + counts.detailedReads == 0 then
		return
	end
	emit(("Threat probe: you %d reads (%d nil, %d secret) · group %d reads (%d nil, %d secret) · detailed-vs-target %d reads (%d secret)"):format(
		counts.selfReads, counts.selfNil, counts.selfSecret,
		counts.groupReads, counts.groupNil, counts.groupSecret,
		counts.detailedReads, counts.detailedSecret))
	for k in pairs(counts) do
		counts[k] = 0
	end
end

-- ================================ Wiring ==================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", function(_, event)
	if TP.Compat.IS_RETAIL then
		if event == "PLAYER_REGEN_DISABLED" then
			if probeEnabled() and not probeTicker then
				probeTicker = C_Timer.NewTicker(2, probeSample)
			end
		else
			if probeTicker then
				probeTicker:Cancel()
				probeTicker = nil
			end
			probeReport()
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		startTicker()
	end
end)
