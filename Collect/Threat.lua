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
-- groups, wipes in progress), a tank "loss" needs a non-tank to actually
-- hold aggro (taunt swaps between two tanks never register) and to have
-- earned it on threat rather than been handed it by a fixate, and the tank
-- must not still be holding something themselves.
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

-- ================================ Fixate guard ============================
-- A mob parked on a non-tank is only a threat failure if that player
-- actually out-threatened the tank. Fixates, forced targets and "everyone
-- gets tossed a copy" mechanics move the mob without touching the threat
-- table, so the victim reads as tanking (UnitThreatSituation 3) while their
-- threat share stays far below the pull threshold — and the tank, who did
-- nothing wrong and often *cannot* taunt it back, eats the loss seconds.
-- Josh 2026-07-28: retail tanks charged "Lost aggro" all through a dungeon.
--
-- UnitDetailedThreatSituation's scaled percentage is the discriminator: 100
-- means "at the threshold where aggro flips", which is where a genuine rip
-- necessarily sits. Well under that while tanking = the game handed the mob
-- over. Judged against the boss frames, then the current target. When no mob
-- can be read the aggro counts as earned, so this only ever removes charges
-- we can positively identify as mechanical.
local EARNED_FLOOR = 90 -- scaled threat %; 100 = at the pull threshold

local function detailedThreat(unit, mob)
	local ok, isTanking, _, scaled = pcall(UnitDetailedThreatSituation, unit, mob)
	if not ok or TP.Compat.IsSecret(isTanking) or TP.Compat.IsSecret(scaled) then
		return nil
	end
	return isTanking, scaled
end

local function threatEarned(unit)
	local judged, anyBoss = false, false
	for i = 1, 5 do
		local mob = "boss" .. i
		if UnitExists(mob) then
			anyBoss = true
			local isTanking, scaled = detailedThreat(unit, mob)
			if isTanking then
				judged = true
				if (scaled or 0) >= EARNED_FLOOR then
					return true -- out-threatened the tank on this mob: real
				end
			end
		end
	end
	-- ONE-ARG UnitThreatSituation reports aggro on ANY mob, so in a dungeon
	-- every DPS holding an add or a stray caster read as ripping off the
	-- tank - Josh 2026-07-29 saw rip penalties on every boss of a
	-- Timewalking run where nothing was ever pulled off him. If boss frames
	-- exist and this player isn't tanking one of them, whatever they have
	-- is an add the tank never held. Not a rip.
	if anyBoss and not judged then
		return false
	end
	if not judged and UnitExists("target") then
		local isTanking, scaled = detailedThreat(unit, "target")
		if isTanking then
			judged = true
			if (scaled or 0) >= EARNED_FLOOR then
				return true
			end
		end
	end
	-- A PENALTY NEEDS EVIDENCE, not the absence of it. This used to return
	-- true when nothing could be judged, on the theory that it preserved
	-- the old behaviour - but that is exactly the case that produces
	-- phantom rips, and Josh reported them twice on runs where nothing was
	-- pulled off him. Old dungeons have no boss frames at all (the boss
	-- unit system postdates TBC), so in a Timewalking run NOTHING is
	-- judgeable and every DPS holding anything was charged. If we cannot
	-- positively confirm this player out-threatened the tank, we did not
	-- see a rip.
	return false
end

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
	-- tank death mid-wipe). Attribute nothing this tick — but keep the
	-- per-player `has` state current, or aggro acquired while the tank
	-- was dead reads as a fresh rip on the first tick after a brez
	-- (audit 2026-07-18). The grace window gives a rezzed tank a few
	-- seconds to taunt before rips/loss start charging again.
	wipe(tankScratch)
	local tanks
	for guid, info in pairs(TP.Roster.players) do
		if info.role == "TANK" and UnitExists(info.unit) and not UnitIsDeadOrGhost(info.unit) then
			tanks = tankScratch
			tanks[#tanks + 1] = guid
		end
	end
	if not tanks then
		for guid, info in pairs(TP.Roster.players) do
			if info.role ~= "TANK" and UnitExists(info.unit) then
				local acc = seg.players[guid]
				if acc then
					ensureAggro(acc).has = (UnitThreatSituation(info.unit) or 0) >= 2
				end
			end
		end
		seg.group.tankGraceUntil = GetTime() + 5
		return
	end
	local inGrace = seg.group.tankGraceUntil and GetTime() < seg.group.tankGraceUntil
	-- a tank-initiated pull (first tank damage within the opening
	-- seconds — slow projectile, body pull) is never a DPS "pull",
	-- even if a pre-cast landed first and briefly held the mob
	local tankInitiated = seg.group.tankFirstDamage and seg.group.tankFirstDamage <= 1.5

	local nonTankHasAggro = false
	for guid, info in pairs(TP.Roster.players) do
		if info.role ~= "TANK" and UnitExists(info.unit) then
			local acc = seg.players[guid]
			if acc then
				local status = UnitThreatSituation(info.unit)
				local has = (status or 0) >= 2 -- 2/3 = mob is (in)securely theirs
				-- a fixate is not this player's doing, and not the tank's
				-- failing: it counts for nobody
				local earned = has and threatEarned(info.unit)
				local a = ensureAggro(acc)
				if earned then
					nonTankHasAggro = true
					a.time = a.time + INTERVAL
					if elapsed <= PULL_WINDOW and not seg.group.tankOpened then
						-- Opening aggro before the tank has it: a pull once
						-- they hold it for a second sample (an instant taunt
						-- save keeps it off their record)
						if not tankInitiated then
							a.pullTicks = a.pullTicks + 1
							if a.pullTicks >= 2 then
								a.pulled = true
							end
						end
					elseif not a.has and not inGrace then
						a.rips = a.rips + 1
					end
				end
				a.has = earned or false
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
		-- loss-seconds only once the tank has actually had the pack (or
		-- the pull window passed): a DPS mis-pull isn't the tank losing
		-- aggro, and a freshly-rezzed tank gets the same grace as rips.
		-- A tank who is still holding something hasn't lost anything — a
		-- DPS grabbing a *different* add is that DPS's rip, already charged
		-- to them. Encounters where nobody tanks (Spoils, Norushen realms)
		-- stop reading as one long failure.
		if acc and nonTankHasAggro and not inGrace and (status or 0) < 2
			and (seg.group.tankOpened or elapsed > PULL_WINDOW) then
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
			local earned = has and threatEarned(info.unit)
			local a = retailAggro(guid)
			if earned then
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
			a.has = earned or false
		end
	end

	for _, guid in ipairs(tanks) do
		local info = TP.Roster.players[guid]
		local status = retailStatus(info.unit)
		if (status or 0) >= 2 then
			retailWindow.tankOpened = true
		end
		-- same gates Classic has always had: a DPS opening the pack before
		-- the tank ever held it is not the tank losing aggro, and a tank
		-- still holding something has lost nothing
		if nonTankHasAggro and (status or 0) < 2
			and (retailWindow.tankOpened or elapsed > PULL_WINDOW) then
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
