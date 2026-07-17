-- Post-fight snapshotter (Midnight+ clients). Once a Blizzard combat session
-- finishes and its values unlock, this captures every TP.METRIC_DEFS
-- attribute into one plain-data fight record — the input the scoring engine
-- consumes. Records contain no secrets and no WoW handles, so they persist
-- to SavedVariables and feed headless tests directly.
--
-- Session lifecycle notes (learned from Details' parser_nocleu):
-- * DAMAGE_METER_COMBAT_SESSION_UPDATED(damageMeterType, sessionId) streams
--   during fights; a NEW sessionId means the previous session finished.
-- * Sessions can RESUME (same id updates after it went quiet) — recapture.
-- * DAMAGE_METER_RESET wipes sessions and restarts ids.
-- * ADDON_RESTRICTION_STATE_CHANGED fires when secret-locking changes.
local _, TP = ...

local FightHistory = {
	fights = {},      -- newest first; plain data
	snapshotted = {}, -- [sessionID] = true once captured this game session
}
TP.FightHistory = FightHistory

local IsSecret
local metrics -- resolved METRIC_DEFS: { {key, enumValue}, ... }
local specIconMap -- icon fileID -> { specID, role }
-- Instance context recorded LIVE as each session first appears: real-group
-- content holds sessions locked until a bulk unlock after you leave, so
-- stamping context at capture time records the wrong zone.
local sessionContext = {} -- [sessionID] = { zone, instanceType, difficulty }
-- Kill/wipe outcomes by encounter name, recorded at ENCOUNTER_END: boss
-- sessions may not unlock until long after the pull, so the result has to
-- be remembered until the snapshot happens.
local encounterResults = {} -- [plainName] = { wipe, at }
local retryTicker
local sweepQueued = false
local lastLiveSession

local function countPlayers(players)
	local n = 0
	for _ in pairs(players) do
		n = n + 1
	end
	return n
end

local function groupInCombat()
	for _, info in pairs(TP.Roster.players) do
		if UnitExists(info.unit) and UnitAffectingCombat(info.unit) then
			return true
		end
	end
	return false
end

-- Reads one attribute session; returns nil, true when still secret-locked.
local function readAttribute(sessionID, enumValue)
	local session = C_DamageMeter.GetCombatSessionFromID(sessionID, enumValue)
	if not session then
		return nil
	end
	if IsSecret(session.durationSeconds) then
		return nil, true
	end
	local src = session.combatSources[1]
	if src and (IsSecret(src.name) or IsSecret(src.totalAmount) or IsSecret(src.sourceGUID)) then
		return nil, true
	end
	return session
end

-- Attempts a full capture. Returns false when the session is still locked.
function FightHistory:TrySnapshot(sessionID, descriptor)
	local players, totals = {}, {}
	local duration

	for _, m in ipairs(metrics) do
		local session, locked = readAttribute(sessionID, m.enumValue)
		if locked then
			return false
		end
		if session then
			duration = duration or session.durationSeconds
			totals[m.key] = (not IsSecret(session.totalAmount)) and session.totalAmount or 0
			for i = 1, #session.combatSources do
				local src = session.combatSources[i]
				local guid = src.sourceGUID
				-- locking is per-VALUE, not per-session: source #1 readable
				-- doesn't mean source #7's GUID is (a secret table key throws,
				-- and the 5s retry ticker would re-throw forever)
				if guid and IsSecret(guid) then
					guid = nil
				end
				if guid then
					local p = players[guid]
					if not p then
						-- prefer the roster snapshot recorded while the session
						-- was live; the current roster may already be empty
						local ctx = sessionContext[sessionID]
						local rosterInfo = (ctx and ctx.roster and ctx.roster[guid])
							or TP.Roster.players[guid]
						local specIconID = (not IsSecret(src.specIconID)) and src.specIconID or nil
						local iconInfo = specIconID and specIconMap and specIconMap[specIconID]
						p = {
							guid = guid,
							name = (not IsSecret(src.name)) and src.name or UNKNOWN,
							class = (not IsSecret(src.classFilename)) and src.classFilename or nil,
							specIconID = specIconID,
							specID = (iconInfo and iconInfo.specID)
								or (rosterInfo and rosterInfo.specID) or nil,
							ilvl = rosterInfo and rosterInfo.ilvl or nil,
							isLocalPlayer = src.isLocalPlayer and true or false,
							role = rosterInfo and rosterInfo.role or nil,
							deathTime = (not IsSecret(src.deathTimeSeconds)) and src.deathTimeSeconds or nil,
							metrics = {},
						}
						for _, mm in ipairs(metrics) do
							p.metrics[mm.key] = 0
						end
						players[guid] = p
					end
					p.metrics[m.key] = (not IsSecret(src.totalAmount)) and src.totalAmount or 0
				end
			end
		end
	end

	-- Self-rescue healing (potions/Healthstones) from the per-spell container
	local healingEnum = Enum.DamageMeterType and Enum.DamageMeterType.HealingDone
	if healingEnum and C_DamageMeter.GetCombatSessionSourceFromID then
		totals.potionHealing = 0
		for guid, p in pairs(players) do
			local potion = 0
			local ok, container = pcall(C_DamageMeter.GetCombatSessionSourceFromID,
				sessionID, healingEnum, guid, p.isLocalPlayer)
			if ok and container and container.combatSpells then
				for i = 1, #container.combatSpells do
					local spell = container.combatSpells[i]
					local id = spell.spellID
					if id and not IsSecret(id) and TP.POTION_HEALS[id] then
						local amount = spell.totalAmount
						if amount and not IsSecret(amount) then
							potion = potion + amount
						end
					end
				end
			end
			p.metrics.potionHealing = potion
			totals.potionHealing = totals.potionHealing + potion
		end
	end

	-- Deaths must never under-count: a secret value falls back to 0, which
	-- turned a multi-death LFR kill into a false "flawless" (Not on My
	-- Watch for a healer who died herself). deathTimeSeconds is a separate
	-- per-source value and often readable when the count isn't; and the
	-- per-player sums floor every session total for the same reason.
	for _, p in pairs(players) do
		if (p.deathTime or 0) > 0 and (p.metrics.deaths or 0) == 0 then
			p.metrics.deaths = 1
		end
	end
	for _, m in ipairs(metrics) do
		local sum = 0
		for _, p in pairs(players) do
			sum = sum + (p.metrics[m.key] or 0)
		end
		if sum > (totals[m.key] or 0) then
			totals[m.key] = sum
		end
	end

	local name = descriptor and descriptor.name
	if not name or IsSecret(name) or name == "" then
		name = ("Fight #%d"):format(sessionID)
	end

	if not duration then
		-- No attribute had data yet (session still empty/locked in a way
		-- IsLocked can't see). Do NOT blacklist: retry until data arrives —
		-- real-group dungeons deliver everything in one bulk unlock at the
		-- end of the run.
		return false
	end
	if duration < 10 then
		self.snapshotted[sessionID] = true -- pull-reset blip: skip for good
		return true
	end

	local fight = {
		sessionID = sessionID,
		-- Blizzard prefixes encounter sessions with "(!) ": keep the flag,
		-- store the name clean so no label downstream has to strip it
		name = name:gsub("^%(!%)%s*", ""),
		isBoss = name:find("^%(!%)") ~= nil,
		duration = duration or 0,
		capturedAt = time(),
		players = players,
		totals = totals,
	}

	-- Where the fight happened; separates boss/trash/dungeon/raid rows when
	-- calibrating scoring weights from real runs. Prefer the context recorded
	-- live when the session appeared — at capture time we may have already
	-- left the instance (bulk unlock).
	-- Kill or wipe? Prefer the recorded ENCOUNTER_END outcome nearest in
	-- time to when this session appeared (bulk unlocks deliver several
	-- pulls of one boss at once — each consumes its own verdict); fall
	-- back to "every player died" when no verdict matches.
	if fight.isBoss then
		local outcomes = encounterResults[fight.name]
		local outcome
		if outcomes and #outcomes > 0 then
			local live = sessionContext[sessionID]
			local anchor = (live and live.at) or time()
			local bestIdx, bestDiff
			for i, o in ipairs(outcomes) do
				local diff = math.abs((o.at or 0) - anchor)
				if not bestDiff or diff < bestDiff then
					bestIdx, bestDiff = i, diff
				end
			end
			outcome = table.remove(outcomes, bestIdx)
		end
		if outcome then
			fight.wipe = outcome.wipe or nil
			fight.hadVerdict = true -- explicit kill/wipe: retro passes keep off
		else
			local allDied, anyone = true, false
			for _, p in pairs(players) do
				anyone = true
				if (p.metrics.deaths or 0) == 0 then
					allDied = false
					break
				end
			end
			fight.wipe = (anyone and allDied) or nil
		end
	end

	local live = sessionContext[sessionID]
	local zone, instanceType, difficultyID, difficultyName = GetInstanceInfo()
	if instanceType == "none" then
		-- outdoors GetInstanceInfo names the CONTINENT map ("Eastern
		-- Kingdoms"); the actual zone tells outdoor raids and world
		-- content apart
		local zt = GetZoneText()
		if zt and zt ~= "" and not IsSecret(zt) then
			zone = zt
		end
	end
	if live then
		fight.zone, fight.instanceType, fight.difficulty = live.zone, live.instanceType, live.difficulty
		fight.difficultyID = live.difficultyID
	else
		if difficultyID and not IsSecret(difficultyID) then
			fight.difficultyID = difficultyID
		end
		if zone and not IsSecret(zone) then
			fight.zone = zone
		end
		if instanceType and not IsSecret(instanceType) then
			fight.instanceType = instanceType
		end
		if difficultyName and not IsSecret(difficultyName) then
			fight.difficulty = difficultyName
		end
	end
	-- Encounter sessions only, everywhere: instance trash AND open-world
	-- quest mobs are noise in history (a 36s Scavenging Hyena got a 92).
	-- World bosses still capture — they fire real (!) encounter sessions.
	local itype = fight.instanceType
	if not fight.isBoss then
		self.snapshotted[sessionID] = true
		return true
	end

	-- Companion content (delves, follower dungeons, story raids) fires real
	-- encounter sessions but never ranks, and its "party" is padded with
	-- NPC bodyguards — the not-supported card promises these are never
	-- captured, so keep that promise even for boss sessions.
	if itype == "scenario" or TP.UNSUPPORTED_DIFFICULTY[fight.difficultyID or 0] then
		self.snapshotted[sessionID] = true
		return true
	end

	if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
		local ok, keystoneLevel = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
		if ok and keystoneLevel and not IsSecret(keystoneLevel) and keystoneLevel > 0 then
			fight.keystoneLevel = keystoneLevel
		end
	end

	-- Enrichment must never block capture
	pcall(TP.Readiness.StampFight, TP.Readiness, fight)
	pcall(TP.Sync.AttachReports, TP.Sync, fight)
	pcall(TP.Threat.AttachRetail, TP.Threat, fight)

	-- Replace an earlier capture of the same session (resume case).
	-- Same NAME required, and RECENT (audit 2026-07-16): session IDs
	-- restart from 1 every client launch, so id+name alone let today's
	-- re-farm of a boss delete yesterday's record from the progression
	-- line. A genuine resume replays within hours, never days.
	for i = #self.fights, 1, -1 do
		local old = self.fights[i]
		if old.sessionID == sessionID and old.name == fight.name
			and (time() - (old.capturedAt or 0)) < 6 * 3600 then
			table.remove(self.fights, i)
		end
	end
	self:StampRunID(fight)
	table.insert(self.fights, 1, fight)
	local cap = TP.Addon.db.profile.history.maxFights
	for i = #self.fights, cap + 1, -1 do
		table.remove(self.fights, i)
	end

	self.snapshotted[sessionID] = true
	self:Persist()
	self:AccumulateWeek(fight) -- retail path (audit: /tp guild was dead here)
	TP.Addon:SendMessage("TrueParse_FIGHT_CAPTURED", fight)
	TP.Addon:Debug(("Captured %s: %.0fs, %d players, dmg %s"):format(
		name, fight.duration, countPlayers(players), TP.FormatNumber(totals.damage or 0)))
	return true
end

-- A "run" = one group's visit to one instance at one difficulty. New run
-- when the zone or difficulty changes, the group mostly turns over (LFR
-- wing A and last week's guild raid are NOT the same run just because
-- they share a zone), or an hour passes between captures.
local function sameRun(prev, fight)
	if not prev or not prev.runID then
		return false
	end
	if (fight.zone or "?") ~= (prev.zone or "?") then
		return false
	end
	if (fight.difficultyID or 0) ~= (prev.difficultyID or 0) then
		return false
	end
	if (fight.capturedAt or 0) - (prev.capturedAt or 0) > 3600 then
		return false
	end
	local shared, prevN, curN = 0, 0, 0
	for guid in pairs(prev.players or {}) do
		prevN = prevN + 1
		if fight.players and fight.players[guid] then
			shared = shared + 1
		end
	end
	for _ in pairs(fight.players or {}) do
		curN = curN + 1
	end
	return shared * 2 >= math.min(prevN, curN)
end

function FightHistory:StampRunID(fight)
	local prev = self.fights[1]
	if prev and sameRun(prev, fight) then
		fight.runID = prev.runID
	else
		local char = TP.Addon.db.char
		char.runCounter = (char.runCounter or 0) + 1
		fight.runID = char.runCounter
	end
end

-- Captures from before run tracking get IDs derived the same way,
-- oldest to newest
function FightHistory:BackfillRunIDs()
	local char = TP.Addon.db.char
	local counter = char.runCounter or 0
	local prev
	for i = #self.fights, 1, -1 do
		local f = self.fights[i]
		if not f.runID then
			if prev and sameRun(prev, f) then
				f.runID = prev.runID
			else
				counter = counter + 1
				f.runID = counter
			end
		end
		prev = f
	end
	char.runCounter = math.max(counter, char.runCounter or 0)
end

function FightHistory:Sweep()
	if not TP.BlizzardMeter.available then
		return
	end
	local ok, sessions = pcall(C_DamageMeter.GetAvailableCombatSessions)
	if not ok or not sessions then
		return
	end

	-- The newest listed session may still be accruing while any group member
	-- fights (follower chain pulls); hold off on it until everyone is out.
	local maxID
	for i = 1, #sessions do
		local id = sessions[i].sessionID
		if id and not IsSecret(id) and (not maxID or id > maxID) then
			maxID = id
		end
	end
	local holdNewest = groupInCombat()

	local anyPending = false
	for i = 1, #sessions do
		local desc = sessions[i]
		local id = desc.sessionID
		if id and not IsSecret(id) and not self.snapshotted[id] then
			if holdNewest and id == maxID then
				anyPending = true
			elseif not self:TrySnapshot(id, desc) then
				anyPending = true
			end
		end
	end

	-- the window's waiting card reads this: "recorded, still locked" is a
	-- different story than "nothing happened" (LFR bulk unlocks run late)
	self.pending = anyPending or nil

	if anyPending then
		if not retryTicker then
			retryTicker = C_Timer.NewTicker(5, function()
				FightHistory:Sweep()
			end)
		end
	elseif retryTicker then
		retryTicker:Cancel()
		retryTicker = nil
	end
end

local function queueSweep(delay)
	if sweepQueued then
		return
	end
	sweepQueued = true
	C_Timer.After(delay or 0.5, function()
		sweepQueued = false
		FightHistory:Sweep()
	end)
end

function FightHistory:Persist()
	-- Per character: your monk's dungeon history has no business showing up
	-- on your evoker.
	TP.Addon.db.char.recentFights = self.fights
end

-- Best PRIOR score for this player on this encounter+difficulty — the
-- personal-best tag. Scores prior kills through the engine on demand,
-- memoized; the history-count in the key self-invalidates on capture.
local pbCache, pbCacheN = {}, 0
function FightHistory:PersonalBest(fight, guid)
	if not (fight.isBoss and fight.name and guid) then
		return nil
	end
	local key = fight.name .. "|" .. tostring(fight.difficultyID) .. "|" .. guid .. "|" .. #self.fights
	local hit = pbCache[key]
	if hit ~= nil then
		return hit or nil
	end
	local best
	local opts = TP.GetScoringOptions and TP.GetScoringOptions() or {}
	for _, f in ipairs(self.fights) do
		if f ~= fight and f.name == fight.name and f.difficultyID == fight.difficultyID
			and not f.wipe and f.players and f.players[guid] then
			local ok, results = pcall(TP.Scoring.Engine.ScoreFight, f, opts)
			if ok then
				for _, r in ipairs(results) do
					if r.guid == guid and (not best or r.score > best) then
						best = r.score
					end
				end
			end
		end
	end
	if pbCacheN > 300 then
		pbCache, pbCacheN = {}, 0
	end
	pbCache[key] = best or false
	pbCacheN = pbCacheN + 1
	return best
end

-- Ordered kill scores on this boss+difficulty for one player, oldest
-- first, INCLUDING the given fight — the breakdown's progression line
-- ("This boss: 26 41 58 72"). Same memo discipline as PersonalBest.
local shCache, shCacheN = {}, 0
function FightHistory:ScoreHistory(fight, guid, maxN)
	if not (fight.isBoss and fight.name and guid) then
		return nil
	end
	local key = "H|" .. fight.name .. "|" .. tostring(fight.difficultyID) .. "|" .. guid .. "|" .. #self.fights
	local hit = shCache[key]
	if hit ~= nil then
		return hit or nil
	end
	local scores = {}
	local opts = TP.GetScoringOptions and TP.GetScoringOptions() or {}
	for i = #self.fights, 1, -1 do -- stored newest-first; walk oldest-first
		local f = self.fights[i]
		if f.name == fight.name and f.difficultyID == fight.difficultyID
			and not f.wipe and f.players and f.players[guid] then
			local ok, results = pcall(TP.Scoring.Engine.ScoreFight, f, opts)
			if ok then
				for _, r in ipairs(results) do
					if r.guid == guid then
						scores[#scores + 1] = r.score
					end
				end
			end
		end
	end
	while #scores > (maxN or 6) do
		table.remove(scores, 1)
	end
	if shCacheN > 300 then
		shCache, shCacheN = {}, 0
	end
	shCache[key] = #scores > 1 and scores or false
	shCacheN = shCacheN + 1
	return #scores > 1 and scores or nil
end

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2, arg3, arg4, arg5)
	if event == "ENCOUNTER_END" then
		local encounterName, success = arg2, arg5
		if encounterName and not IsSecret(encounterName) and not IsSecret(success) then
			-- a LIST per name (audit 2026-07-16): LFR wipe+kill of one
			-- boss unlock together, and one-slot storage gave every pull
			-- the LAST pull's verdict — the wipe recorded as a kill.
			-- wipe = false (not nil) is an explicit kill verdict.
			local list = encounterResults[encounterName]
			if not list then
				list = {}
				encounterResults[encounterName] = list
			end
			list[#list + 1] = { wipe = (success == 0) or false, at = time() }
		end
	elseif event == "DAMAGE_METER_COMBAT_SESSION_UPDATED" then
		local damageMeterType, sessionId = arg1, arg2
		if damageMeterType ~= Enum.DamageMeterType.DamageDone or IsSecret(sessionId) then
			return
		end
		if not sessionContext[sessionId] then
			local zone, instanceType, difficultyID, difficultyName = GetInstanceInfo()
			if instanceType == "none" then
				-- outdoors the "instance" is the continent map; the real
				-- zone separates outdoor raids from world content
				local zt = GetZoneText()
				if zt and zt ~= "" and not IsSecret(zt) then
					zone = zt
				end
			end
			sessionContext[sessionId] = {
				zone = (not IsSecret(zone)) and zone or nil,
				instanceType = (not IsSecret(instanceType)) and instanceType or nil,
				difficulty = (not IsSecret(difficultyName)) and difficultyName or nil,
				difficultyID = (not IsSecret(difficultyID)) and difficultyID or nil,
				roster = {},
				at = time(), -- prune anchor (contexts persist across /reload)
			}
		end
		-- Roster facts recorded LIVE: bulk-unlocked captures often land after
		-- the group disbands, when TP.Roster is empty — a queued Timewalking
		-- healer lost their role that way. Meter updates stream several times
		-- a second in combat, and roles/specs basically never change mid-
		-- fight: refresh at most every 5s (still catches joins).
		local ctx = sessionContext[sessionId]
		if ctx.roster and (not ctx.rosterAt or (GetTime() - ctx.rosterAt) > 5) then
			ctx.rosterAt = GetTime()
			for guid, info in pairs(TP.Roster.players) do
				local e = ctx.roster[guid]
				if not e then
					e = {}
					ctx.roster[guid] = e
				end
				e.role = info.role or e.role
				e.specID = info.specID or e.specID
				e.ilvl = info.ilvl or e.ilvl
			end
		end
		if FightHistory.snapshotted[sessionId] then
			-- Session resumed after we captured it; recapture when it settles
			FightHistory.snapshotted[sessionId] = nil
			queueSweep(1)
		elseif sessionId ~= lastLiveSession then
			-- New session started => the previous one just finished
			lastLiveSession = sessionId
			queueSweep(1)
		end
	elseif event == "DAMAGE_METER_RESET" then
		wipe(FightHistory.snapshotted)
		wipe(sessionContext)
		lastLiveSession = nil
		queueSweep(1)
	elseif event == "PLAYER_REGEN_ENABLED" or event == "ADDON_RESTRICTION_STATE_CHANGED" then
		queueSweep(1)
	elseif event == "PLAYER_ENTERING_WORLD" then
		local isInitialLogin, isReloadingUi = arg1, arg2
		if isReloadingUi then
			-- Same game session: Blizzard sessions survived, don't recapture
			for _, fight in ipairs(FightHistory.fights) do
				if fight.sessionID then
					FightHistory.snapshotted[fight.sessionID] = true
				end
			end
		end
		queueSweep(3)
	end
end)

-- Classic path: converts a finished CLEU segment's accumulators into the
-- same fight-record shape the retail snapshotter produces, so the scoring
-- engine, scorecard, and history behave identically on both clients.
function FightHistory:AddFromSegment(seg)
	if TP.BlizzardMeter.available then
		return
	end
	-- Encounter fights only: instance trash and open-world quest mobs are
	-- noise in history (world bosses still fire ENCOUNTER events)
	if not seg.encounterID then
		return
	end
	local _, itype = GetInstanceInfo()
	if itype == "scenario" then
		return -- scenario "bosses" (MoP scenarios): unranked, never captured
	end
	local totals = {
		damage = 0, damageToBoss = 0, healing = 0, selfHealing = 0,
		healingToTanks = 0, absorbs = 0, damageTaken = 0,
		avoidableTaken = 0, interrupts = 0, dispels = 0, deaths = 0,
		potionHealing = 0,
	}
	local players = {}
	local playerGUID = UnitGUID("player")
	-- WCL-aligned duration: Blizzard's ENCOUNTER window includes RP
	-- intros (Norushen: ~27 dead seconds before first damage), which
	-- deflated every per-second rate ~10% and crushed mid-pack Raw
	-- percentiles (p45 players read p15, 2026-07-14). WCL measures
	-- first damage -> last damage; the per-second output buckets give
	-- us the same trim. Kill-time percentiles want this too — WCL's
	-- ranked kill times use the same bounds.
	if (seg.duration or 0) > 0 then
		-- WCL's fight bounds are the ENCOUNTER events, intros included
		-- (verified vs live logs 2026-07-16: the first-damage trim read
		-- SHORT of WCL by ~15s). Anchor to the encounter window when we
		-- have one; fall back to damage-bucket bounds only for segments
		-- without a clean encounter verdict.
		local first, tight
		if seg.encounterStartTime and seg.encounterEnded and seg.endTime then
			first = math.max(0, math.floor(seg.encounterStartTime - seg.startTime))
			tight = math.max(1, math.floor(seg.endTime - seg.encounterStartTime + 0.5))
		elseif seg.group and seg.group.out then
			local last
			for t in pairs(seg.group.out) do
				if not first or t < first then
					first = t
				end
				if not last or t > last then
					last = t
				end
			end
			tight = first and last and last > first and (last - first + 1) or nil
		end
		if first and tight then
			if tight >= 10 and tight < seg.duration then
				seg.rawDuration = seg.duration
				seg.duration = tight
				-- REBASE every time-series to the trimmed clock (audit
				-- 2026-07-16: trimming only the length left buckets and
				-- timestamps on the untrimmed clock, so spike scans
				-- missed the fight's FINAL seconds and the wipe-call
				-- baseline kept the phantom intro zeros)
				if first > 0 then
					local function shift(t)
						if not t then
							return nil
						end
						local s = {}
						for k, v in pairs(t) do
							s[k - first] = v
						end
						return s
					end
					seg.group.out = shift(seg.group.out)
					for _, acc in pairs(seg.players) do
						local sp = acc.spikes
						if sp then
							sp.taken = shift(sp.taken) or {}
							if sp.since then
								sp.since = sp.since - first
							end
							for _, span in ipairs(sp.spans or {}) do
								span[1], span[2] = span[1] - first, span[2] - first
							end
							for i, c in ipairs(sp.casts or {}) do
								sp.casts[i] = c - first
							end
						end
						if acc.taken then
							acc.taken.avB = shift(acc.taken.avB)
							for _, slot in ipairs(acc.taken.ring or {}) do
								if slot.t then
									slot.t = math.max(0, slot.t - first)
								end
							end
						end
						for _, hit in ipairs(acc.deathRecap or {}) do
							if hit.t then
								hit.t = math.max(0, hit.t - first)
							end
						end
						if acc.deaths and acc.deaths.lastTime then
							acc.deaths.lastTime = math.max(0, acc.deaths.lastTime - first)
						end
						if acc.dryAt then
							acc.dryAt = math.max(0, acc.dryAt - first)
						end
					end
				end
			end
		end
	end

	-- "Wipe it" detection: on a called wipe, nothing after the call
	-- counts — people stand in bad on purpose to reset faster. Output
	-- collapse is the tell; a wipe fought to the end detects nothing
	-- and everything counts.
	local calledAt
	if seg.encounterWipe and TP.Spikes and TP.Spikes.DetectWipeCall then
		local ok, at = pcall(TP.Spikes.DetectWipeCall,
			seg.group and seg.group.out, seg.duration)
		calledAt = ok and at or nil
	end

	-- danger-window math runs once for the whole segment (group windows
	-- are shared); enrichment must never block capture. On a called
	-- wipe, windows past the call don't judge anyone's cooldowns.
	local spikeData
	if TP.Spikes and TP.Spikes.Compute then
		local ok, data = pcall(TP.Spikes.Compute, seg, calledAt or seg.duration)
		spikeData = ok and data or nil
	end
	for guid, acc in pairs(seg.players) do
		-- Roster members who never participated (offline, cross-zone, out of
		-- combat-log range the whole fight) don't belong on the card
		local active = (acc.damage and acc.damage.total or 0) > 0
			or (acc.healing and acc.healing.effective or 0) > 0
			or (acc.taken and acc.taken.total or 0) > 0
			or (acc.interrupts and acc.interrupts.kicks or 0) > 0
			or (acc.dispels and acc.dispels.count or 0) > 0
			or (acc.deaths and acc.deaths.total or 0) > 0
		if active then
		local m = {
			damage = acc.damage and acc.damage.useful or 0,
			damageToBoss = acc.damage and acc.damage.toBoss or 0,
			healing = acc.healing and acc.healing.effective or 0,
			selfHealing = acc.healing and acc.healing.selfPart or 0,
			healingToTanks = acc.healing and acc.healing.toTanks or 0,
			absorbs = acc.absorbs and acc.absorbs.granted or 0,
			damageTaken = acc.taken and acc.taken.total or 0,
			avoidableTaken = (function()
				local av = acc.taken and acc.taken.avoidable or 0
				-- post-call avoidable was on purpose: subtract it
				if calledAt and acc.taken and acc.taken.avB then
					for t, v in pairs(acc.taken.avB) do
						if t >= calledAt then
							av = av - v
						end
					end
				end
				return math.max(0, av)
			end)(),
			interrupts = acc.interrupts and acc.interrupts.kicks or 0,
			dispels = acc.dispels and acc.dispels.count or 0,
			deaths = acc.deaths and acc.deaths.total or 0,
			potionHealing = acc.potions and acc.potions.healing or 0,
		}
		for k, v in pairs(m) do
			totals[k] = totals[k] + v
		end
		-- CLEU sees everyone's defensive casts on Classic (added after the
		-- totals loop: it's a count, not a summable throughput stat)
		if acc.cooldowns then
			m.defensives = acc.cooldowns.defensives
		end
		-- Bloodlust-window usage: only meaningful when lust actually went
		-- out this fight (nil otherwise so bullets stay silent)
		if seg.lustSeen and acc.lust then
			m.lustCasts = acc.lust.casts
			m.lustPotion = acc.lust.potion and 1 or 0
		end
		-- WoWAnalyzer-style basics (post-totals: ratios/counts, not sums).
		-- Activity on a called wipe measures the TRYING phase only —
		-- standing still waiting to die isn't inactivity.
		if acc.activity and (seg.duration or 0) > 0 then
			local denom = calledAt or seg.duration
			m.activityPct = math.min(100, math.floor(acc.activity.active / denom * 100 + 0.5))
		end
		if acc.healing then
			local over = acc.healing.overheal or 0
			local raw = (acc.healing.effective or 0) + over
			if raw > 0 then
				m.overhealPct = math.floor(over / raw * 100 + 0.5)
			end
		end
		if acc.lust and (acc.lust.totalCasts or 0) > 0 then
			m.offensiveCDs = acc.lust.totalCasts
		end
		-- tank active-mitigation uptime; close a still-open window at the
		-- fight boundary
		if acc.mitigation and (seg.duration or 0) > 0 then
			local up = acc.mitigation.uptime
			if acc.mitigation.since and seg.endTime then
				up = up + math.max(0, seg.endTime - acc.mitigation.since)
			end
			if up > 0 then
				m.mitigationPct = math.min(100, math.floor(up / seg.duration * 100 + 0.5))
			end
		end
		-- danger-window cooldown timing (Metrics/Spikes.lua; the engine
		-- gates tank fields to tanks, group fields to healers)
		if spikeData and spikeData[guid] then
			local sd = spikeData[guid]
			m.spikeWindows, m.spikeCovered = sd.spikeWindows, sd.spikeCovered
			m.groupSpikeWindows, m.groupSpikeCovered = sd.groupSpikeWindows, sd.groupSpikeCovered
			m.spikeMap, m.groupSpikeMap = sd.spikeMap, sd.groupSpikeMap
		end
		-- dispel reaction time (avg seconds a dispelled debuff sat there)
		if acc.dispels and (acc.dispels.reactN or 0) > 0 then
			m.dispelReactAvg = acc.dispels.reactSum / acc.dispels.reactN
		end
		-- combat rezzes cast (group contribution, adjustment-worthy)
		if acc.utility and (acc.utility.rezzes or 0) > 0 then
			m.combatRezzes = acc.utility.rezzes
		end
		-- overkill share of total damage (padding context, tooltip-only)
		if acc.damage and (acc.damage.total or 0) > 0 then
			local waste = acc.damage.total - (acc.damage.useful or acc.damage.total)
			if waste > 0 then
				m.overkillPct = math.floor(waste / acc.damage.total * 100 + 0.5)
			end
		end
		-- healer mana timeline (Vitals sampler)
		if acc.minManaPct then
			m.manaMinPct = math.floor(acc.minManaPct * 100 + 0.5)
			m.dryAt = acc.dryAt
		end
		local ag = acc.aggro
		players[guid] = {
			guid = guid,
			name = acc.name,
			class = acc.class,
			role = acc.role,
			specID = acc.specID,
			ilvl = acc.ilvl,
			isLocalPlayer = (guid == playerGUID),
			deathTime = acc.deaths and acc.deaths.lastTime or nil,
			-- Threat discipline (Collect/Threat.lua sampler; Classic only)
			aggroPulled = ag and ag.pulled or nil,
			aggroRips = (ag and ag.rips or 0) > 0 and ag.rips or nil,
			aggroTime = (ag and ag.time or 0) > 0 and ag.time or nil,
			aggroLostTime = (ag and ag.lost or 0) > 0 and ag.lost or nil,
			-- Lowest health seen (Collect/Vitals.lua sampler; Classic only)
			minHealthPct = acc.minHealthPct,
			-- the last hits before their death (death-bullet tooltip)
			deathRecap = acc.deaths and acc.deaths.recap or nil,
			metrics = m,
		}
		end
	end
	if totals.damage <= 0 or (seg.duration or 0) < 10 then
		return -- trivial segment or a pull-reset blip: don't pollute history
	end

	local fight = {
		name = seg.name or "Fight",
		isBoss = seg.encounterID and true or false,
		encounterID = seg.encounterID,
		-- explicit verdict, else the retail-style heuristic: a boss pull
		-- with no ENCOUNTER_END where every participant died is a wipe
		wipe = seg.encounterWipe,
		-- explicit ENCOUNTER_END verdict: retro wipe passes keep off
		-- (an all-died KILL was flaggable as a wipe, audit 2026-07-16)
		hadVerdict = seg.encounterEnded or nil,
		-- the moment the raid stopped trying (nil = fought to the end)
		calledWipeAt = calledAt,
		-- lowest boss HP% reached: the progression number on wipes
		bossPct = seg.encounterWipe and seg.bossPctMin or nil,
		duration = seg.duration or 0,
		rawDuration = seg.rawDuration, -- untrimmed window (report matching)
		capturedAt = time(),
		zone = GetZoneText(),
		difficultyID = select(3, GetInstanceInfo()),
		players = players,
		totals = totals,
	}
	-- group interrupt coverage (opportunities from the self-curating
	-- kickable list; feeds the kick adjustment's intensity)
	if seg.group and (seg.group.kickOpps or 0) > 0 then
		totals.dispelTypes = seg.group.dispelTypes
		totals.kickOpportunities = seg.group.kickOpps
		totals.kicksLanded = seg.group.kicksLanded or 0
		totals.kicksThrough = seg.group.kicksThrough or 0
	end
	-- Enrichment must never block capture
	pcall(TP.Readiness.StampFight, TP.Readiness, fight)
	pcall(TP.Sync.AttachReports, TP.Sync, fight)
	if fight.isBoss and fight.wipe == nil and not seg.encounterEnded then
		local anyone, allDied = false, true
		for _, p in pairs(players) do
			anyone = true
			if (p.metrics.deaths or 0) == 0 then
				allDied = false
				break
			end
		end
		fight.wipe = (anyone and allDied) or nil
	end
	self:StampRunID(fight)
	table.insert(self.fights, 1, fight)
	local cap = TP.Addon.db.profile.history.maxFights
	for i = #self.fights, cap + 1, -1 do
		table.remove(self.fights, i)
	end
	self:Persist()
	self:AccumulateWeek(fight)
	TP.Addon:Debug(("Captured %s: %.0fs, dmg %s"):format(
		fight.name, fight.duration, TP.FormatNumber(totals.damage)))
	TP.Addon:SendMessage("TrueParse_FIGHT_CAPTURED", fight)
end

-- Weekly ledger for the lockout summary ("group 61, last week 56").
-- Weeks key off the US reset (Tuesday 15:00 UTC); only the two most
-- recent weeks are kept.
function FightHistory.WeekKey(t)
	return math.floor(((t or time()) - 1704207600) / 604800)
end

function FightHistory:AccumulateWeek(fight)
	if not fight.isBoss then
		return
	end
	local g = TP.Addon.db.global
	g.weekStats = g.weekStats or {}
	local wk = FightHistory.WeekKey()
	local w = g.weekStats[wk]
	if not w then
		w = { bosses = 0, wipes = 0, scoreSum = 0, scoreN = 0 }
		g.weekStats[wk] = w
		for k in pairs(g.weekStats) do
			if k < wk - 1 then
				g.weekStats[k] = nil
			end
		end
	end
	if fight.wipe then
		w.wipes = w.wipes + 1
	else
		w.bosses = w.bosses + 1
	end
	local ok, results = pcall(TP.Scoring.Engine.ScoreFight, fight,
		TP.GetScoringOptions and TP.GetScoringOptions() or {})
	if ok and #results > 0 then
		local sum = 0
		for _, r in ipairs(results) do
			sum = sum + r.score
		end
		w.scoreSum = w.scoreSum + sum / #results
		w.scoreN = w.scoreN + 1
		-- own weekly standing, for the /tp guild board (results are
		-- sorted best-first, so results[1] is the fight's top)
		local myGuid = UnitGUID and UnitGUID("player")
		if myGuid then
			for _, r in ipairs(results) do
				if r.guid == myGuid then
					if not (g.myWeek and g.myWeek.week == wk) then
						g.myWeek = { week = wk, fights = 0, scoreSum = 0, tops = 0 }
					end
					local mw = g.myWeek
					mw.fights = mw.fights + 1
					mw.scoreSum = mw.scoreSum + r.score
					if results[1].guid == myGuid then
						mw.tops = mw.tops + 1
					end
					break
				end
			end
		end
	end
end

-- Retroactive wipe verdicts for captures saved without one (records from
-- before wipe hardening, or ENCOUNTER_END that never landed):
-- 1) RAIDS: a boss re-pulled LATER in the same run can't have been dead —
--    every earlier same-boss pull in that run was a wipe. Airtight for
--    lockout content; never applied to resettable dungeons.
-- 2) Everyone died with no verdict: wipe (the retail heuristic).
local RAID_DIFficulties = {
	[3] = true, [4] = true, [5] = true, [6] = true, [7] = true,
	[14] = true, [15] = true, [16] = true, [17] = true,
}

function FightHistory:BackfillWipes()
	local pulledLater = {} -- [runID:name], walking newest -> oldest
	for i = 1, #self.fights do
		local f = self.fights[i]
		if f.isBoss then
			local key = tostring(f.runID) .. ":" .. (f.name or "")
			if f.wipe == nil and not f.hadVerdict then
				if pulledLater[key] and RAID_DIFficulties[f.difficultyID or 0] then
					f.wipe = true
				else
					local anyone, allDied = false, true
					for _, p in pairs(f.players or {}) do
						anyone = true
						if ((p.metrics and p.metrics.deaths) or 0) == 0 then
							allDied = false
							break
						end
					end
					if anyone and allDied then
						f.wipe = true
					end
				end
			end
			pulledLater[key] = true
		end
	end
end

-- Late ENCOUNTER_END verdict (Segments): the segment can close before the
-- boss resets when everyone dies and releases — flag the matching recent
-- capture as a wipe after the fact.
function FightHistory:AmendWipe(encounterID)
	local now = time()
	for i = 1, math.min(#self.fights, 5) do
		local f = self.fights[i]
		if f.encounterID == encounterID and f.wipe == nil
			and not f.hadVerdict
			and (now - (f.capturedAt or 0)) < 600 then
			f.wipe = true
			self:Persist()
			if TP.MeterWindow and TP.MeterWindow.Invalidate then
				TP.MeterWindow:Invalidate()
			end
			return
		end
	end
end

function FightHistory:OnEnable()
	IsSecret = TP.Compat.IsSecret
	-- Session contexts AND the captured-session ledger survive /reload,
	-- like pending reports: LFR bulk unlocks land after the run, and a
	-- mid-run reload (a) lost the live context — a Chimaerus LFR kill
	-- filed as difficulty-0 open world with no LFR bracket — and (b)
	-- forgot which sessions were already captured, so the next sweep
	-- RE-captured every still-listed session and REPLACED good records
	-- with degraded ones (reports and context gone: an Aug's uptime and
	-- their whole attribution overwritten hours later, 2026-07-14).
	local g = TP.Addon.db.global
	g.sessionContexts = g.sessionContexts or {}
	sessionContext = g.sessionContexts
	for id, ctx in pairs(sessionContext) do
		if (time() - (ctx.at or 0)) > 21600 then
			sessionContext[id] = nil
		end
	end
	g.snapshottedSessions = g.snapshottedSessions or {}
	self.snapshotted = g.snapshottedSessions
	self.fights = TP.Addon.db.char.recentFights or {}
	-- Migrate away the account-wide storage used by earlier builds
	TP.Addon.db.global.recentFights = nil
	-- Sweep captures from before companion content and non-encounter
	-- fights were declared unsupported: an NPC bodyguard's scorecard and
	-- a quest mob's 92 have no business persisting
	for i = #self.fights, 1, -1 do
		local f = self.fights[i]
		if not f.isBoss or f.instanceType == "scenario"
			or TP.UNSUPPORTED_DIFFICULTY[f.difficultyID or 0] then
			table.remove(self.fights, i)
		elseif f.name then
			-- older captures stored Blizzard's "(!) " prefix in the name
			f.name = f.name:gsub("^%(!%)%s*", "")
		end
	end
	self:BackfillRunIDs()
	self:BackfillWipes()

	if not TP.BlizzardMeter.available then
		return -- Classic: fights arrive via AddFromSegment
	end
	-- Persisted session state is for /reload survival ONLY. A client
	-- RESTART renumbers meter sessions from scratch, so a stale entry
	-- for session 3 would mislabel (or suppress) tomorrow's session 3:
	-- if the meter's newest ID is below anything stored, renumbering
	-- happened — drop everything keyed by session ID.
	do
		local ok, sessions = pcall(C_DamageMeter.GetAvailableCombatSessions)
		local maxID = 0
		if ok and sessions then
			for i = 1, #sessions do
				local id = sessions[i].sessionID
				if id and not IsSecret(id) and id > maxID then
					maxID = id
				end
			end
		end
		local stale = false
		for id in pairs(sessionContext) do
			if type(id) ~= "number" or id > maxID then
				stale = true
				break
			end
		end
		for id in pairs(self.snapshotted) do
			if type(id) ~= "number" or id > maxID then
				stale = true
				break
			end
		end
		if stale then
			wipe(sessionContext)
			wipe(self.snapshotted)
		end
	end
	specIconMap = TP.Compat.BuildSpecIconMap()

	metrics = {}
	for _, def in ipairs(TP.METRIC_DEFS) do
		local enumValue = Enum.DamageMeterType and Enum.DamageMeterType[def.enum]
		if enumValue then
			metrics[#metrics + 1] = { key = def.key, enumValue = enumValue }
		end
	end

	for _, ev in ipairs({
		"DAMAGE_METER_COMBAT_SESSION_UPDATED",
		"DAMAGE_METER_RESET",
		"PLAYER_REGEN_ENABLED",
		"ADDON_RESTRICTION_STATE_CHANGED",
		"PLAYER_ENTERING_WORLD",
		"ENCOUNTER_END",
	}) do
		pcall(eventFrame.RegisterEvent, eventFrame, ev)
	end
end
