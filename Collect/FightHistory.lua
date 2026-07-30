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

-- A capture with no encounterID whose instance context reads "none" can't be
-- PLACED: either the meter handed the session over from outside the instance,
-- or the ENCOUNTER_END that carries zone/difficulty/encounterID never
-- arrived. Outdoors GetInstanceInfo names the continent, so these records
-- wear "Eastern Kingdoms" and difficulty 0.
local function isPlaceless(f)
	return not f.encounterID and (not f.instanceType or f.instanceType == "none")
end

-- Is there already a properly-placed capture of this same fight? Same boss,
-- same length within a couple of seconds (a re-read drifts a little), and
-- either the same meter session or close enough in time to be the same play
-- session rather than a re-farm.
--
-- The sessionID arm matters (Josh 2026-07-28): his Murder Row run came back
-- a second time as "Silvermoon City" ELEVEN HOURS later, so the original
-- 3-hour window missed it and the phantoms survived — which also fired the
-- Reports panel's auto-run on login, once per re-read fight, looking like
-- "auto announce happens on login". The meter kept its session numbering
-- across the relog, and a re-read carries the same sessionID as the capture
-- it duplicates. Name + duration + session number together are conclusive
-- enough, and the record being dropped is the one with no zone, no
-- difficulty and no encounterID — the placed twin is strictly better.
-- A re-read does not always report the SAME duration as the original capture
-- (Josh 2026-07-28, round two): his Belo'ren pulls came back as 335s and 412s
-- against placed originals of 191s and 225s, so the duration test alone let
-- them through while their siblings were caught. Two arms now:
--   1. same length (±3s) and either the same meter session or the same play
--      session — the ordinary re-read;
--   2. same meter session with an EARLIER placed capture, any duration — the
--      re-read that also lost the clock. Bounded to a week so a session
--      number recycled months later can't reach back.
-- Both require a PLACED twin: a placeless capture with no twin is the real
-- record for bulk-unlocked (LFR-style) fights and must always survive.
local TWIN_SESSION_WINDOW = 7 * 24 * 3600

local function hasPlacedTwin(fights, fight)
	for i = 1, #fights do
		local f = fights[i]
		if f ~= fight and f.name == fight.name and not isPlaceless(f) then
			local sameSession = (f.sessionID == fight.sessionID)
			local gap = (fight.capturedAt or 0) - (f.capturedAt or 0)
			if math.abs((f.duration or 0) - (fight.duration or 0)) <= 3
				and (sameSession or math.abs(gap) <= 10800) then
				return true
			end
			if sameSession and gap > 0 and gap <= TWIN_SESSION_WINDOW then
				return true
			end
		end
	end
	return false
end
FightHistory.IsPlaceless = isPlaceless -- exposed for diagnostics

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
				-- PLAYERS ONLY (Josh 2026-07-28: a death knight's ghoul showed
				-- up as a 6th member of a 5-man, named "Unknown" because pet
				-- names come back secret). C_DamageMeter lists pets and
				-- guardians as their own combat sources, and it has ALREADY
				-- attributed their output to the owner - every pet row in the
				-- field data carried zero damage and zero healing. So this
				-- drops phantom rows, never real contribution.
				-- MockFight builds its fixtures straight into FightHistory
				-- and never reaches this loop, so its MOCK- guids are safe.
				if guid and not guid:find("^Player%-") then
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
						local specID = (iconInfo and iconInfo.specID)
							or (rosterInfo and rosterInfo.specID) or nil
						-- role from the roster snapshot, else DERIVE it from the
						-- spec (Josh 2026-07-25: 20% of retail player-fights had
						-- no role because the bulk-unlock roster missed them, so
						-- tanks/healers graded as DPS until EffectiveRole
						-- recovered it at scoring — now the stored record is
						-- correct too, so reports/coach/awards agree)
						local role = (rosterInfo and rosterInfo.role)
							or (specID and TP.SPEC_ROLES and TP.SPEC_ROLES[specID]) or nil
						p = {
							guid = guid,
							name = (not IsSecret(src.name)) and src.name or UNKNOWN,
							class = (not IsSecret(src.classFilename)) and src.classFilename or nil,
							specIconID = specIconID,
							specID = specID,
							ilvl = rosterInfo and rosterInfo.ilvl or nil,
							isLocalPlayer = src.isLocalPlayer and true or false,
							role = role,
							-- 0 means "didn't die", not "died at the pull" (Josh
							-- 2026-07-25: a deathless kill reported 5 deaths
							-- at 0:00) — only a real timestamp is a death
							deathTime = (not IsSecret(src.deathTimeSeconds))
								and (src.deathTimeSeconds or 0) > 0
								and src.deathTimeSeconds or nil,
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
		-- unnamed session: fall back to what we were hitting, recorded live
		-- (the only way a dummy session gets a usable label)
		local liveCtx = sessionContext[sessionID]
		name = (liveCtx and liveCtx.targetName) or ("Fight #%d"):format(sessionID)
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

	-- Practice on a raider's training dummy: a real single-target rotation
	-- worth grading, and the ONE non-encounter session that earns a record
	-- (Classic has done this since 2026-07-26 in AddFromSegment; retail
	-- never did, so dummies vanished into the trash filter below). Same
	-- gates as Classic: the option, the dummy's name, and 60s+ so a stray
	-- weapon swing on the way past isn't a parse.
	local practice = false
	if name:find("^%(!%)") == nil then
		practice = TP.Addon.db.profile.practiceDummies
			and TP.IsPracticeTarget(name)
	end

	-- A DUMMY SESSION'S durationSeconds IS NOT A FIGHT LENGTH. Josh's first
	-- capture came back ~3,449,228 (40 days), which made the card read
	-- "57487m8s" and every rate collapse to "1 per second" / "0 per second"
	-- on 2.24M healing and 1.41M damage (2026-07-30). Blizzard closes an
	-- encounter session at ENCOUNTER_END; nothing closes a dummy one, so its
	-- clock keeps running across every pause, and possibly since the meter
	-- itself began.
	-- The honest bound is how long WE have watched this session: the live
	-- context stamps `at` on the first meter update, which for a dummy is the
	-- moment the swinging started. Applied to practice ONLY - a bulk-unlocked
	-- dungeon session is snapshotted long after it ended, so the observed
	-- span would be far too LONG for those, and their durationSeconds is
	-- already correct.
	if practice then
		local liveCtx = sessionContext[sessionID]
		local active = liveCtx and liveCtx.activeSeconds
		if not (active and active > 0) then
			-- No time-on-target measured (the meter reset, which wipes
			-- sessionContext). Every rate on the card would be built on a
			-- number we know is wrong, so record nothing rather than a
			-- fabricated one - the mirror of "unmeasurable is not zero".
			self.snapshotted[sessionID] = true
			return true
		end
		duration = math.floor(active + 0.5)
	end
	-- the 60s floor is checked against the CORRECTED duration, or a session
	-- with a runaway clock would qualify no matter how briefly it was hit
	practice = practice and duration >= 60

	local fight = {
		sessionID = sessionID,
		-- Blizzard prefixes encounter sessions with "(!) ": keep the flag,
		-- store the name clean so no label downstream has to strip it
		name = name:gsub("^%(!%)%s*", ""),
		-- practice rides the boss pipeline (curves, coach, card) but flags
		-- itself so kill-speed/comp/career logic steps aside
		isBoss = name:find("^%(!%)") ~= nil or practice,
		practice = practice or nil,
		duration = duration or 0,
		capturedAt = time(),
		-- when the fight actually HAPPENED: the live context's stamp from
		-- the first meter update. Bulk/delayed unlocks build this record
		-- hours (or a login) later, so capturedAt - duration is NOT the
		-- pull time (Josh 2026-07-25: a 7pm raid showed a 1:07pm pull)
		startedAt = sessionContext[sessionID] and sessionContext[sessionID].at or nil,
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
	-- A DUMMY CANNOT BE WIPED ON (Josh 2026-07-30 saw one tagged "(wipe)").
	-- Practice rides the boss pipeline, so it reached the fallback below —
	-- "every participant died" — and a solo session where the player went
	-- down once is 1 of 1 dead. There is no encounter to fail: you stop
	-- hitting the dummy, that is all.
	local outcomeCtx
	if fight.isBoss and not fight.practice then
		local outcomes = encounterResults[fight.name]
		local outcome
		if outcomes and #outcomes > 0 then
			local live = sessionContext[sessionID]
			local anchor = (live and live.at) or time()
			-- The list is keyed by NAME alone, so a boss pulled on two
			-- difficulties in one sitting pools both verdicts — and nearest
			-- -timestamp alone let a Normal capture eat a Heroic wipe
			-- (Josh 2026-07-28: Sporefall heroic wipes, then Normal for the
			-- kill). The verdict already records its difficultyID; prefer a
			-- matching one and only fall back to any when none matches.
			local want = live and live.difficultyID
			local bestIdx, bestDiff, bestExact
			for i, o in ipairs(outcomes) do
				local diff = math.abs((o.at or 0) - anchor)
				local exact = (want ~= nil and o.difficultyID == want)
				-- an exact difficulty match always beats a closer timestamp
				if (exact and not bestExact)
					or (exact == bestExact and (not bestDiff or diff < bestDiff)) then
					bestIdx, bestDiff, bestExact = i, diff, exact
				end
			end
			outcome = table.remove(outcomes, bestIdx)
		end
		if outcome then
			fight.wipe = outcome.wipe or nil
			fight.hadVerdict = true -- explicit kill/wipe: retro passes keep off
			outcomeCtx = outcome
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
	-- The ENCOUNTER_END outcome outranks a missing/outdoor context: TW
	-- runs bulk-unlock after you leave, the live context recorded the
	-- CONTINENT and no difficulty, and the engine laddered a level-
	-- scaled mage into max-level raid pools (parsed 9 — Josh 2026-07-25)
	if outcomeCtx then
		if (not fight.instanceType or fight.instanceType == "none")
			and outcomeCtx.instanceType and outcomeCtx.instanceType ~= "none" then
			fight.zone = outcomeCtx.zone or fight.zone
			fight.instanceType = outcomeCtx.instanceType
			fight.difficulty = outcomeCtx.difficulty or fight.difficulty
			fight.difficultyID = outcomeCtx.difficultyID or fight.difficultyID
		end
		-- locale-proof curve keying, free: session records never had one
		if outcomeCtx.encounterID and not fight.encounterID then
			fight.encounterID = outcomeCtx.encounterID
		end
	end
	-- practice borrows the anchor's bracket so curve resolution lands on the
	-- intended population (a dummy in a capital reads difficulty 0, which
	-- ladders nowhere). No anchor for this client = the record still keeps,
	-- it just scores off the fightFactors path instead of a curve.
	if fight.practice and TP.PRACTICE_ANCHOR and TP.PRACTICE_ANCHOR.difficultyID then
		fight.difficultyID = TP.PRACTICE_ANCHOR.difficultyID
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

	-- PHANTOM re-capture (Josh 2026-07-27): DAMAGE_METER_RESET wipes both
	-- snapshotted and sessionContext, so every session the meter still lists
	-- gets re-read from OUTSIDE the instance - the continent for a zone,
	-- difficulty 0, and no ENCOUNTER_END left to correct either. A whole
	-- Murder Row run landed a second time under "Eastern Kingdoms" that way.
	-- Only drop it when the properly-placed capture already exists: the same
	-- placeless shape with NO twin is the real record for bulk-unlocked
	-- (LFR-style) fights that stream in after you leave, and those must
	-- still capture.
	if isPlaceless(fight) and hasPlacedTwin(self.fights, fight) then
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
	self:StampPrevKill(fight)
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

-- Speed trend: remember the previous KILL of this boss+difficulty so the
-- group card can say "14s faster than last time". Stamped at capture,
-- BEFORE the new fight enters the list — history access lives here so
-- Scoring stays pure. Fights are newest-first, so the first match wins.
function FightHistory:StampPrevKill(fight)
	-- practice sessions have no kill to trend (duration = attention span)
	if not fight.isBoss or fight.wipe or fight.practice then
		return
	end
	for _, old in ipairs(self.fights) do
		if old.isBoss and not old.wipe and not old.mock and old.name == fight.name
			and old.difficultyID == fight.difficultyID and (old.duration or 0) > 0 then
			fight.prevKillDuration = old.duration
			fight.prevKillAt = old.capturedAt
			return
		end
	end
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
	-- PRACTICE GETS NO RUN (Josh 2026-07-30: "make sure practice sessions
	-- aren't counted towards any averages or careers"). A dummy session is
	-- one player hitting a target, not a group's visit to an instance -
	-- giving it a runID made it a one-fight "run" whose average is just
	-- itself, and let a second dummy pull chain into the first. Everything
	-- keyed on runID (the run row, run averages, the run report) skips a
	-- fight without one, so this is the single choke point.
	if not TP.CountsInAggregates(fight) then
		return
	end
	-- /tp mock records must never chain a real pull into their fake run
	local prev
	for _, f in ipairs(self.fights) do
		if not f.mock then
			prev = f
			break
		end
	end
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
		-- practice never gets a run, never joins one, and never anchors one
		-- (StampRunID skips it the same way for new captures)
		if TP.CountsInAggregates(f) then
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
	-- different story than "nothing happened" (LFR bulk unlocks run late).
	-- pendingSince lets the card show the lock's AGE — outdoor-raid wipes
	-- hold the lock longest (no leave-the-instance unlock edge), and a
	-- visible clock reads as progress where a static line read as a bug
	-- (Josh 2026-07-24, Sporefall heroic wipe)
	self.pending = anyPending or nil
	if anyPending then
		self.pendingSince = self.pendingSince or time()
	else
		self.pendingSince = nil
	end

	if anyPending then
		if not retryTicker then
			retryTicker = C_Timer.NewTicker(5, function()
				FightHistory:Sweep()
				-- keep the waiting card's lock-age clock ticking
				if FightHistory.pending and TP.MeterWindow and TP.MeterWindow.Refresh then
					TP.MeterWindow:Refresh(true)
				end
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

-- Options' "Clear fight history" (Josh 2026-07-25): this character's
-- captured fights only — career stats and week standings stay.
function FightHistory:Clear()
	wipe(self.fights)
	self:Persist()
	if TP.MeterWindow then
		if TP.MeterWindow.ResetSelection then
			TP.MeterWindow:ResetSelection()
		end
		TP.MeterWindow:Invalidate()
	end
	if TP.BreakdownPanel and TP.BreakdownPanel.HideAll then
		TP.BreakdownPanel:HideAll()
	end
	TP.Addon:Print("Fight history cleared for this character.")
end

-- Best PRIOR score for this player on this encounter+difficulty — the
-- personal-best tag. Scores prior kills through the engine on demand,
-- memoized; the history-count in the key self-invalidates on capture.
local pbCache, pbCacheN = {}, 0
function FightHistory:PersonalBest(fight, guid)
	-- practice never sets or claims a personal best: a dummy is not an
	-- encounter, and the record it would compete against is another dummy
	if not (fight.isBoss and fight.name and guid) or not TP.CountsInAggregates(fight) then
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
			and not f.wipe and TP.CountsInAggregates(f) and f.players and f.players[guid] then
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
			-- the outcome carries IN-INSTANCE context too: bulk-unlocked
			-- sessions can first stream after you've left (the "live"
			-- session context then records the continent and no
			-- difficulty), but ENCOUNTER_END always fires inside
			local zone, itype, _, diffName = GetInstanceInfo()
			local diffID = arg3
			if itype == "none" then
				local zt = GetZoneText()
				if zt and zt ~= "" and not IsSecret(zt) then
					zone = zt
				end
			end
			list[#list + 1] = { wipe = (success == 0) or false, at = time(),
				encounterID = (not IsSecret(arg1)) and arg1 or nil,
				difficultyID = (not IsSecret(diffID)) and diffID or nil,
				zone = (not IsSecret(zone)) and zone or nil,
				instanceType = (not IsSecret(itype)) and itype or nil,
				difficulty = (not IsSecret(diffName)) and diffName or nil }
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
		-- TIME ON TARGET, accumulated live. A session that Blizzard never
		-- closes has no usable durationSeconds (a dummy's read ~3,449,228 —
		-- 40 days — and the card showed "57487:08"), and the wall time since
		-- we first SAW the session is barely better: it counts every pause
		-- between attempts, which is how a two-minute rehearsal read 28:17.
		-- This event streams several times a second while damage is landing
		-- and stops when it isn't, so summing the gaps BETWEEN updates -
		-- discarding any longer than a few seconds - measures the time
		-- actually spent hitting the thing. GetTime() doesn't survive a
		-- /reload and contexts do, hence the sign check as well.
		do
			local ctx0 = sessionContext[sessionId]
			local now = GetTime()
			local delta = ctx0.tickAt and (now - ctx0.tickAt) or nil
			if delta and delta > 0 and delta < 5 then
				ctx0.activeSeconds = (ctx0.activeSeconds or 0) + delta
			end
			ctx0.tickAt = now
		end
		-- Roster facts recorded LIVE: bulk-unlocked captures often land after
		-- the group disbands, when TP.Roster is empty — a queued Timewalking
		-- healer lost their role that way. Meter updates stream several times
		-- a second in combat, and roles/specs basically never change mid-
		-- fight: refresh at most every 5s (still catches joins).
		local ctx = sessionContext[sessionId]
		if ctx.roster and (not ctx.rosterAt or (GetTime() - ctx.rosterAt) > 5) then
			ctx.rosterAt = GetTime()
			-- WHAT we are hitting. Blizzard names encounter sessions only, so
			-- a raider's-training-dummy session arrives nameless and the
			-- record read "Fight #12" with isBoss false — which the trash
			-- filter below then dropped, so retail dummies never captured at
			-- all. Sticky, and a practice target outranks whatever we
			-- happened to be targeting first, so tabbing mid-session can't
			-- rename the pull.
			local tn = UnitExists and UnitExists("target") and UnitName("target") or nil
			if type(tn) == "string" and tn ~= "" and not IsSecret(tn)
				and (not ctx.targetName
					or (TP.IsPracticeTarget(tn)
						and not TP.IsPracticeTarget(ctx.targetName))) then
				ctx.targetName = tn
			end
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
	-- noise in history (world bosses still fire ENCOUNTER events).
	-- EXCEPTION (Josh 2026-07-26): a raider's-training-dummy session of
	-- 60s+ captures as a labeled PRACTICE fight, scored against the
	-- tier's patchwerk anchor — real practice with real curves. Detection
	-- is the segment name (from the pull target), so target the dummy;
	-- TP.PRACTICE_TARGETS lists what counts, golems included.
	local practice = false
	if not seg.encounterID then
		practice = TP.Addon.db.profile.practiceDummies
			and TP.IsPracticeTarget(seg.name)
			and (seg.duration or 0) >= 60
		-- boss-frame fallback (Celestial dungeons, 2026-07-24): engaged
		-- boss frames make a boss fight even without ENCOUNTER events
		if not practice and not seg.bossEngaged then
			return
		end
	end
	local _, itype, instDiff, _, maxPlayers = GetInstanceInfo()
	if itype == "scenario" then
		-- MoP's real scenarios (Arena of Annihilation etc., difficulty
		-- 11/12, 3-man) stay out: unranked noise. But the Celestial
		-- dungeon mode runs REAL dungeon encounters inside a
		-- scenario-typed instance (Josh's Vizier Jin'bak kill vanished
		-- here, 2026-07-24) — a 5-player group with a real encounter
		-- verdict is a dungeon boss whatever the instance type says.
		if instDiff == 11 or instDiff == 12 or (maxPlayers or 0) < 5 then
			return
		end
		-- classify the record as the dungeon it is: "scenario" would get
		-- swept at login, and a nil instanceType classifies as RAID in
		-- the curve ladder (the Timewalking cross-type lesson)
		itype = "party"
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
							-- hardest-hit records ride the same clock (they
							-- were missed here until audit 2026-07-24: band
							-- tooltips read the wrong seconds after a trim)
							sp.top = shift(sp.top)
							if sp.since then
								sp.since = sp.since - first
							end
							for _, span in ipairs(sp.spans or {}) do
								span[1], span[2] = span[1] - first, span[2] - first
							end
							for i, c in ipairs(sp.casts or {}) do
								sp.casts[i] = c - first
							end
							for _, ec in ipairs(sp.extCasts or {}) do
								ec[1] = math.max(0, ec[1] - first)
							end
						end
						-- per-player output series ride the trimmed clock too
						if acc.damage then
							acc.damage.out = shift(acc.damage.out)
						end
						if acc.healing then
							acc.healing.out = shift(acc.healing.out)
						end
						if acc.taken then
							acc.taken.avB = shift(acc.taken.avB)
							for _, slot in ipairs(acc.taken.ring or {}) do
								if slot.t then
									slot.t = math.max(0, slot.t - first)
								end
							end
						end
						-- the recap lives at deaths.recap (audit 2026-07-18:
						-- this loop shifted a field that never existed, so
						-- recap timestamps stayed on the untrimmed clock)
						if acc.deaths then
							for _, hit in ipairs(acc.deaths.recap or {}) do
								if hit.t then
									hit.t = math.max(0, hit.t - first)
								end
							end
							if acc.deaths.lastTime then
								acc.deaths.lastTime = math.max(0, acc.deaths.lastTime - first)
							end
							for i, t in ipairs(acc.deaths.times or {}) do
								acc.deaths.times[i] = math.max(0, t - first)
							end
						end
						if acc.utility then
							for i, t in ipairs(acc.utility.rezTimes or {}) do
								acc.utility.rezTimes[i] = math.max(0, t - first)
							end
						end
						if acc.dryAt then
							acc.dryAt = math.max(0, acc.dryAt - first)
						end
						if acc.lust and acc.lust.lastCastAt then
							acc.lust.lastCastAt = math.max(0, acc.lust.lastCastAt - first)
						end
					end
					if seg.lustAt then
						seg.lustAt = math.max(0, seg.lustAt - first)
					end
					if seg.manualWipeAt then
						seg.manualWipeAt = math.max(0, seg.manualWipeAt - first)
					end
				end
			end
		end
	end

	-- "Wipe it": a manual button press is ground truth and beats the
	-- output-collapse heuristic; without one, on a called wipe nothing
	-- after the detected collapse counts — people stand in bad on purpose
	-- to reset faster. A wipe fought to the end detects nothing and
	-- everything counts. BOTH paths require an actual wipe (Josh
	-- 2026-07-26): a called wipe that turns into a kill forgives nothing.
	local manualCall = seg.encounterWipe and seg.manualWipeAt or nil
	-- 0 is TRUTHY in Lua, so a wipe called at the pull instant (manual
	-- button at 0s, or a sync-clamped peer call) left calledAt=0 and every
	-- `calledAt or seg.duration` fallback silently kept 0 → activityPct =
	-- active/0 = nan (persisted!), all avoidable subtracted (t>=0), rezzes
	-- dropped (Josh 2026-07-26 audit). Normalize non-positive to nil so a
	-- degenerate 0 falls through to the heuristic / no-call behavior.
	if manualCall and manualCall <= 0 then manualCall = nil end
	local calledAt = manualCall
	if not calledAt and seg.encounterWipe and TP.Spikes and TP.Spikes.DetectWipeCall then
		local ok, at = pcall(TP.Spikes.DetectWipeCall,
			seg.group and seg.group.out, seg.duration)
		calledAt = ok and at or nil
	end
	if calledAt and calledAt <= 0 then calledAt = nil end

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
			-- tanking-stat ingredients (2026-07-24): sums, so no rebase
			blockedTaken = acc.taken and acc.taken.blocked or nil,
			absorbedTaken = acc.absorbs and acc.absorbs.taken or nil,
			selfAbsorbs = acc.absorbs and acc.absorbs.selfTaken or nil,
			swingsLanded = acc.taken and acc.taken.swings or nil,
			swingsAvoided = acc.taken and acc.taken.avoided or nil,
			swingDamageTaken = acc.taken and acc.taken.swingTotal or nil,
			staggerPurified = acc.taken and acc.taken.staggerPurified or nil,
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
			-- per-ability damage taken (MoP/CLEU), top few by damage: mechanic
			-- coaching cross-refs the names against the crawled field hitRate
			takenByAbility = (function()
				local bn = acc.taken and acc.taken.byName
				if not bn then
					return nil
				end
				local arr = {}
				for name, e in pairs(bn) do
					arr[#arr + 1] = { name = name, amount = e.amount, hits = e.hits }
				end
				if #arr == 0 then
					return nil
				end
				table.sort(arr, function(a, b) return a.amount > b.amount end)
				local out = {}
				for i = 1, math.min(8, #arr) do
					out[arr[i].name] = { amount = arr[i].amount, hits = arr[i].hits }
				end
				return out
			end)(),
			interrupts = acc.interrupts and acc.interrupts.kicks or 0,
			dispels = acc.dispels and acc.dispels.count or 0,
			deaths = acc.deaths and acc.deaths.total or 0,
			potionHealing = acc.potions and acc.potions.healing or 0,
		}
		for k, v in pairs(m) do
			-- default nil to 0: the metrics table carries keys the totals
			-- init doesn't pre-declare (the Tanking-composite ingredients
			-- absorbedTaken/swingsAvoided/etc. added in v2.0.0), and
			-- `nil + v` crashed AddFromSegment on any fight with a tank
			-- taking absorbed/avoided damage (MrFIXlT's Celestial run,
			-- 2026-07-26). Numeric-only so a future table metric can't
			-- crash here either.
			if type(v) == "number" then
				totals[k] = (totals[k] or 0) + v
			end
		end
		-- CLEU sees everyone's defensive casts on Classic (added after the
		-- totals loop: it's a count, not a summable throughput stat)
		if acc.cooldowns then
			m.defensives = acc.cooldowns.defensives
			-- pre-update in-flight segments lack the field: default 0
			m.healthstones = acc.cooldowns.healthstones or 0
		end
		-- Bloodlust-window usage: only meaningful when lust actually went
		-- out this fight (nil otherwise so bullets stay silent)
		if seg.lustSeen and acc.lust then
			m.lustCasts = acc.lust.casts
			m.lustPotion = acc.lust.potion and 1 or 0
			-- last offensive-CD cast before/around the window: availability
			-- evidence for the engine's miss penalty
			m.lastOffensiveAt = acc.lust.lastCastAt
		end
		-- profile-spell cast counts (parse coach: own rate vs top parses)
		if acc.profCasts then
			m.profCasts = acc.profCasts
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
			-- absorbs belong in the denominator: the healing SCORE counts
			-- them as output, and shield-heavy specs (Disc) pre-top their
			-- targets, which inflates the heal slice's overheal — waste
			-- must be measured against the same total output
			local raw = (acc.healing.effective or 0) + over
				+ (acc.absorbs and acc.absorbs.granted or 0)
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
			-- Store a measured ZERO for TANKS (2026-07-28): `up > 0` left a
			-- tank who never pressed mitigation indistinguishable from one
			-- nobody measured, and since unreported mitigation now imputes
			-- to average, that gap scored zero uptime as average. The
			-- accumulator is InitPlayer'd for EVERY player, so a bare zero
			-- would write this field on all 20 raiders - tanks only, or it
			-- is pure bloat in saved vars and sync payloads.
			local rosterInfo = TP.Roster.players[guid]
			if up > 0 or (rosterInfo and rosterInfo.role == "TANK") then
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
			-- single-target externals vs tank spikes (engine gates to
			-- healer specs owning one)
			m.extWindows, m.extCovered = sd.extWindows, sd.extCovered
			-- demonstrated capacity: the engine caps judged windows at
			-- uses+1 so nobody is penalized for physics
			m.defensiveUses, m.groupCdCasts = sd.defensiveUses, sd.groupCdCasts
		end
		-- the player's OWN fight shape (Josh 2026-07-24): healers healing,
		-- tanks intake, everyone else damage — downtime made visible
		if TP.Scoring.Signals and (seg.duration or 0) > 0 then
			local series
			if acc.role == "HEALER" then
				series = acc.healing and acc.healing.out
			elseif acc.role == "TANK" then
				series = acc.spikes and acc.spikes.taken
			else
				series = acc.damage and acc.damage.out
			end
			if series then
				m.shape = TP.Scoring.Signals.Downsample(series, seg.duration, 40)
			end
		end
		-- dispel reaction time (avg seconds a dispelled debuff sat there)
		if acc.dispels and (acc.dispels.reactN or 0) > 0 then
			m.dispelReactAvg = acc.dispels.reactSum / acc.dispels.reactN
		end
		-- combat rezzes cast (group contribution, adjustment-worthy).
		-- Post-call rezzes are wasted brezzes, not contribution: the
		-- target's ensuing death is itself forgiven as "the plan"
		if acc.utility and (acc.utility.rezzes or 0) > 0 then
			local rezzes = acc.utility.rezzes
			if calledAt and acc.utility.rezTimes then
				rezzes = 0
				for _, t in ipairs(acc.utility.rezTimes) do
					if t < calledAt then
						rezzes = rezzes + 1
					end
				end
			end
			if rezzes > 0 then
				m.combatRezzes = rezzes
			end
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
			-- every death's fight-offset: the engine drops post-call
			-- deaths from the charged count (brez double-charge fix)
			deathTimes = acc.deaths and acc.deaths.times or nil,
			-- max HP at fight start: lets the engine recognize one-shot
			-- deaths (no defensive would have mattered) from the recap
			maxHP = acc.spikes and acc.spikes.maxHP or nil,
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
		-- practice fights ride the boss pipeline (curves, coach, card)
		-- but flag themselves so kill-speed/comp/career logic steps aside
		isBoss = (seg.encounterID or practice or seg.bossEngaged) and true or false,
		practice = practice or nil,
		encounterID = seg.encounterID,
		-- explicit verdict, else the retail-style heuristic: a boss pull
		-- with no ENCOUNTER_END where every participant died is a wipe
		wipe = seg.encounterWipe,
		-- explicit ENCOUNTER_END verdict — or, on boss-frame fallback
		-- fights, every engaged boss dying (Celestial kill verdict)
		hadVerdict = (seg.encounterEnded or seg.bossKilled) or nil,
		-- the moment the raid stopped trying (nil = fought to the end);
		-- wipeCalledBy present = someone pressed the button (ground truth)
		calledWipeAt = calledAt,
		wipeCalledBy = manualCall and seg.manualWipeBy or nil,
		-- when Bloodlust went out (fight-offset): players dead before
		-- this can't have "wasted" it
		lustAt = seg.lustAt,
		-- lowest boss HP% reached: the progression number on wipes
		-- where the boss stood when the pull ended (WCL wipe semantics;
		-- refill-phase bosses like Garrosh made a running min meaningless)
		bossPct = seg.encounterWipe and seg.bossPctLast or nil,
		duration = seg.duration or 0,
		rawDuration = seg.rawDuration, -- untrimmed window (report matching)
		capturedAt = time(),
		-- CLEU records build at fight end, so the pull clock is exact
		startedAt = time() - (seg.duration or 0),
		zone = GetZoneText(),
		-- practice fights borrow the anchor's bracket so curve resolution
		-- lands on the intended population
		difficultyID = practice and TP.PRACTICE_ANCHOR and TP.PRACTICE_ANCHOR.difficultyID
			or instDiff,
		-- content classification for the curve ladder + login sweep
		-- (celestial dungeon captures arrive here as "party")
		instanceType = itype,
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
	-- fight shape: the group's output/sec downsampled to 40 cells — the
	-- group card's sparkline (opener ramp, lust burst, the call collapse).
	-- The wipe-call detector computes this series anyway; now it's drawn.
	if seg.group and seg.group.out and TP.Scoring.Signals then
		fight.shape = TP.Scoring.Signals.Downsample(seg.group.out, seg.duration, 40)
	end
	-- raid CDs pressed this fight (any at all): the group card's
	-- assignment line subtracts these from what the comp owns
	if seg.group and seg.group.raidCdsUsed then
		totals.raidCdsUsed = seg.group.raidCdsUsed
	end
	-- Enrichment must never block capture
	pcall(TP.Readiness.StampFight, TP.Readiness, fight)
	pcall(TP.Sync.AttachReports, TP.Sync, fight)
	if fight.isBoss and fight.wipe == nil and not seg.encounterEnded
		and not seg.bossKilled then
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
	self:StampPrevKill(fight)
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
	if not fight.isBoss or fight.practice then
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

-- How long after a pull a later pull of the same boss still implies the
-- earlier one didn't kill it. Generous enough for one raid night, short
-- enough that next week's farm doesn't retro-flag this week's kill.
local REPULL_WINDOW = 6 * 3600

function FightHistory:BackfillWipes()
	-- Keyed by ZONE, not runID (Josh 2026-07-28). Wiping on Heroic and
	-- switching to Normal for the kill INCREMENTS the run, so the kill was
	-- invisible to the heroic pulls and the last wipe of the night rendered
	-- as a kill. The zone survives a difficulty change; the time window below
	-- does the job runID was really there for.
	local pulledLater = {} -- [zone:name] = capturedAt of the newest pull seen
	for i = 1, #self.fights do
		local f = self.fights[i]
		if f.isBoss then
			local key = (f.zone or "?") .. ":" .. (f.name or "")
			if f.wipe == nil and not f.hadVerdict then
				local later = pulledLater[key]
				if later and RAID_DIFficulties[f.difficultyID or 0]
					and (later - (f.capturedAt or 0)) <= REPULL_WINDOW then
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
			-- newest wins: we walk newest -> oldest, so the first sighting
			-- of a key is the most recent pull of that boss
			pulledLater[key] = pulledLater[key] or f.capturedAt or 0
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
	-- ENCOUNTER_END verdicts persist for the same reason (Josh 2026-07-27):
	-- they carry the IN-INSTANCE zone, difficulty and encounterID, and a
	-- bulk unlock landing in a LATER game session used to find them gone.
	-- The capture then fell back to the outdoor context and filed the
	-- CONTINENT ("Eastern Kingdoms", difficulty 0, no encounterID) - which
	-- no dungeon or raid curve can match, so the fight scored against
	-- nothing. Name-keyed, so session renumbering doesn't touch them.
	g.encounterResults = g.encounterResults or {}
	encounterResults = g.encounterResults
	for name, list in pairs(encounterResults) do
		for i = #list, 1, -1 do
			if (time() - (list[i].at or 0)) > 21600 then
				table.remove(list, i)
			end
		end
		if #list == 0 then
			encounterResults[name] = nil
		end
	end
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
		else
			-- Pets captured as group members before the Player- filter
			-- (2026-07-28). They carry no output — their damage was always
			-- credited to the owner — but they take a scorecard row and
			-- inflate the head count the dispel fair-share divides by.
			-- MOCK- fixtures are deliberate and must survive.
			for guid in pairs(f.players or {}) do
				if not guid:find("^Player%-") and not guid:find("^MOCK") then
					f.players[guid] = nil
				end
			end
			if f.name then
				-- older captures stored Blizzard's "(!) " prefix in the name
				f.name = f.name:gsub("^%(!%)%s*", "")
			end
		end
		-- Records captured before the v1.5.4 sampler rewrite (epoch below =
		-- its exact commit) carry running-MIN percentages that phase bosses
		-- poisoned (Garrosh min-latched 3% on pulls that died in phase 2).
		-- Untrustworthy by definition — show plain (wipe) for those and let
		-- percentages mean "measured by the honest sampler".
		if f and f.wipe and f.bossPct and (f.capturedAt or 0) < 1784858547 then
			f.bossPct = nil
		end
	end
	-- Sweep phantom re-captures already in history (see isPlaceless): the
	-- placeless copy of a fight we ALSO hold properly placed. Runs after the
	-- name normalization above so twin matching compares clean names.
	for i = #self.fights, 1, -1 do
		if isPlaceless(self.fights[i]) and hasPlacedTwin(self.fights, self.fights[i]) then
			table.remove(self.fights, i)
		end
	end
	-- Retire practice records built on the runaway session clock (Josh
	-- 2026-07-30: "Dungeoneer's Training Dummy · 57487:08"). Blizzard never
	-- closes a dummy session, so durationSeconds kept counting and every
	-- rate on those cards is wrong by the same factor. The true length is
	-- not recoverable after the fact — time on target is measured live now —
	-- so drop them rather than leave a card that reads 0 damage per second.
	-- An hour is far past any real rehearsal and far below the bogus values.
	for i = #self.fights, 1, -1 do
		local f = self.fights[i]
		if f.practice and (f.duration or 0) > 3600 then
			table.remove(self.fights, i)
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
