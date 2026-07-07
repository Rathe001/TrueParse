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
				if guid then
					local p = players[guid]
					if not p then
						local rosterInfo = TP.Roster.players[guid]
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

	local name = descriptor and descriptor.name
	if not name or IsSecret(name) or name == "" then
		name = ("Fight #%d"):format(sessionID)
	end

	local fight = {
		sessionID = sessionID,
		name = name,
		-- Blizzard prefixes encounter sessions with "(!) "
		isBoss = name:find("^%(!%)") ~= nil,
		duration = duration or 0,
		capturedAt = time(),
		players = players,
		totals = totals,
	}

	-- Where the fight happened; separates boss/trash/dungeon/raid rows when
	-- calibrating scoring weights from real runs.
	local zone, instanceType, difficultyID, difficultyName = GetInstanceInfo()
	if zone and not IsSecret(zone) then
		fight.zone = zone
	end
	if instanceType and not IsSecret(instanceType) then
		fight.instanceType = instanceType
	end
	if difficultyName and not IsSecret(difficultyName) then
		fight.difficulty = difficultyName
	end
	if C_ChallengeMode and C_ChallengeMode.GetActiveKeystoneInfo then
		local ok, keystoneLevel = pcall(C_ChallengeMode.GetActiveKeystoneInfo)
		if ok and keystoneLevel and not IsSecret(keystoneLevel) and keystoneLevel > 0 then
			fight.keystoneLevel = keystoneLevel
		end
	end

	TP.Readiness:StampFight(fight)

	-- Replace an earlier capture of the same session (resume case)
	for i = #self.fights, 1, -1 do
		if self.fights[i].sessionID == sessionID then
			table.remove(self.fights, i)
		end
	end
	table.insert(self.fights, 1, fight)
	local cap = TP.Addon.db.profile.history.maxFights
	for i = #self.fights, cap + 1, -1 do
		table.remove(self.fights, i)
	end

	self.snapshotted[sessionID] = true
	self:Persist()
	TP.Addon:SendMessage("TrueParse_FIGHT_CAPTURED", fight)
	TP.Addon:Debug(("Captured %s: %.0fs, %d players, dmg %s"):format(
		name, fight.duration, countPlayers(players), TP.FormatNumber(totals.damage or 0)))
	return true
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

local eventFrame = CreateFrame("Frame")
eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
	if event == "DAMAGE_METER_COMBAT_SESSION_UPDATED" then
		local damageMeterType, sessionId = arg1, arg2
		if damageMeterType ~= Enum.DamageMeterType.DamageDone or IsSecret(sessionId) then
			return
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
	local totals = {
		damage = 0, healing = 0, absorbs = 0, damageTaken = 0,
		avoidableTaken = 0, interrupts = 0, dispels = 0, deaths = 0,
		potionHealing = 0,
	}
	local players = {}
	local playerGUID = UnitGUID("player")
	for guid, acc in pairs(seg.players) do
		local m = {
			damage = acc.damage and acc.damage.useful or 0,
			healing = acc.healing and acc.healing.effective or 0,
			absorbs = acc.absorbs and acc.absorbs.granted or 0,
			damageTaken = acc.taken and acc.taken.total or 0,
			avoidableTaken = 0,
			interrupts = acc.interrupts and acc.interrupts.kicks or 0,
			dispels = acc.dispels and acc.dispels.count or 0,
			deaths = acc.deaths and acc.deaths.total or 0,
			potionHealing = acc.potions and acc.potions.healing or 0,
		}
		for k, v in pairs(m) do
			totals[k] = totals[k] + v
		end
		players[guid] = {
			guid = guid,
			name = acc.name,
			class = acc.class,
			role = acc.role,
			specID = acc.specID,
			ilvl = acc.ilvl,
			isLocalPlayer = (guid == playerGUID),
			deathTime = acc.deaths and acc.deaths.lastTime or nil,
			metrics = m,
		}
	end
	if totals.damage <= 0 then
		return -- trivial segment, don't pollute history
	end

	local fight = {
		name = seg.name or "Fight",
		isBoss = seg.encounterID and true or false,
		duration = seg.duration or 0,
		capturedAt = time(),
		zone = GetZoneText(),
		players = players,
		totals = totals,
	}
	TP.Readiness:StampFight(fight)
	table.insert(self.fights, 1, fight)
	local cap = TP.Addon.db.profile.history.maxFights
	for i = #self.fights, cap + 1, -1 do
		table.remove(self.fights, i)
	end
	self:Persist()
	TP.Addon:SendMessage("TrueParse_FIGHT_CAPTURED", fight)
end

function FightHistory:OnEnable()
	IsSecret = TP.Compat.IsSecret
	self.fights = TP.Addon.db.char.recentFights or {}
	-- Migrate away the account-wide storage used by earlier builds
	TP.Addon.db.global.recentFights = nil

	if not TP.BlizzardMeter.available then
		return -- Classic: fights arrive via AddFromSegment
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
	}) do
		pcall(eventFrame.RegisterEvent, eventFrame, ev)
	end
end
