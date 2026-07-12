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

-- ================================ Retail: scored group tracking ===========
-- EXPERIMENT 3 verdict (2026-07-12): retail group threat is READABLE
-- mid-combat (zero secrets live), so the same discipline tracking runs on
-- retail. Captures arrive in late bulk unlocks, so samples accumulate in
-- standalone combat windows and attach to fights by duration fingerprint
-- (the SelfCasts report pattern). Sampling skips groups larger than 5:
-- the engine never scores raid threat anyway (fixates make it noise).

local retailWindow -- { startedAt, tankOpened, players = { [guid] = aggro } }
local retailRecent = {} -- finalized windows awaiting capture match
local retailTicker

local function retailAggro(guid)
	local a = retailWindow.players[guid]
	if not a then
		a = { time = 0, rips = 0, pulled = false, lost = 0, has = false, pullTicks = 0 }
		retailWindow.players[guid] = a
	end
	return a
end

local function retailStatus(unit)
	local ok, s = pcall(UnitThreatSituation, unit)
	if not ok or TP.Compat.IsSecret(s) then
		return nil
	end
	return s
end

local function retailSample()
	if not retailWindow then
		return
	end
	local elapsed = GetTime() - retailWindow.startedAt

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
			local status = retailStatus(info.unit)
			local has = (status or 0) >= 2
			local a = retailAggro(guid)
			if has then
				nonTankHasAggro = true
				a.time = a.time + INTERVAL
				if elapsed <= PULL_WINDOW and not retailWindow.tankOpened then
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

	for _, guid in ipairs(tanks) do
		local info = TP.Roster.players[guid]
		if (retailStatus(info.unit) or 0) >= 2 then
			retailWindow.tankOpened = true
		end
		if nonTankHasAggro then
			retailAggro(guid).lost = retailAggro(guid).lost + INTERVAL
		end
	end
end

local function retailFinalize()
	if retailTicker then
		retailTicker:Cancel()
		retailTicker = nil
	end
	local window = retailWindow
	retailWindow = nil
	if not window then
		return
	end
	local meaningful = false
	for _, a in pairs(window.players) do
		if a.pulled or a.rips > 0 or a.time > 0 or a.lost > 0 then
			meaningful = true
			break
		end
	end
	if not meaningful then
		return
	end
	table.insert(retailRecent, 1, {
		duration = GetTime() - window.startedAt,
		at = GetTime(),
		players = window.players,
	})
	-- keep only fresh windows: captures land within minutes
	for i = #retailRecent, 1, -1 do
		if #retailRecent > 10 or (GetTime() - retailRecent[i].at) > 900 then
			table.remove(retailRecent, i)
		end
	end
end

local function retailStart()
	if GetNumGroupMembers() > 5 then
		return -- raids/LFR: never scored, don't sample
	end
	retailWindow = { startedAt = GetTime(), tankOpened = false, players = {} }
	if not retailTicker then
		retailTicker = C_Timer.NewTicker(INTERVAL, retailSample)
	end
end

-- Called by FightHistory:TrySnapshot — stamp the duration-matched window's
-- discipline facts onto the captured fight (same fields AddFromSegment
-- writes on Classic, so the engine and bullets need no changes).
function Threat:AttachRetail(fight)
	if not TP.Compat.IS_RETAIL or #retailRecent == 0 then
		return
	end
	local tolerance = math.max(8, (fight.duration or 0) * 0.2)
	local best, bestDiff
	for i, w in ipairs(retailRecent) do
		local diff = math.abs((w.duration or 0) - (fight.duration or 0))
		if diff <= tolerance and (not bestDiff or diff < bestDiff) then
			best, bestDiff = i, diff
		end
	end
	if not best then
		return
	end
	local window = table.remove(retailRecent, best)
	for guid, p in pairs(fight.players) do
		local a = window.players[guid]
		if a and p.aggroTime == nil and p.aggroRips == nil then
			p.aggroPulled = a.pulled or nil
			p.aggroRips = a.rips > 0 and a.rips or nil
			p.aggroTime = a.time > 0 and a.time or nil
			p.aggroLostTime = a.lost > 0 and a.lost or nil
		end
	end
end

-- ================================ Wiring ==================================

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
eventFrame:SetScript("OnEvent", function(_, event)
	if TP.Compat.IS_RETAIL then
		if event == "PLAYER_REGEN_DISABLED" then
			retailStart()
		else
			retailFinalize()
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		startTicker()
	end
end)
