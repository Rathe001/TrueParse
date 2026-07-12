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

-- EXPERIMENT 3 (probe removed 2026-07-12) VERDICT: retail group threat is
-- READABLE mid-combat — UnitThreatSituation returned 0 secrets for self,
-- group, and detailed-vs-target in live dungeon combat. Retail threat
-- discipline (5-man scoring like Classic's) is therefore buildable when
-- wanted; nothing is built on it yet.

-- ================================ Wiring ==================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:SetScript("OnEvent", function()
	if not TP.Compat.IS_RETAIL then
		startTicker()
	end
end)
