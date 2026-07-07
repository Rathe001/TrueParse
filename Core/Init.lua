-- TrueParse: group contribution meter.
-- Every file receives (addonName, privateNamespace) as varargs; modules attach
-- themselves to the shared TP table rather than polluting globals.
local ADDON_NAME, TP = ...

TP.Addon = LibStub("AceAddon-3.0"):NewAddon(ADDON_NAME, "AceConsole-3.0", "AceEvent-3.0", "AceTimer-3.0")
local Addon = TP.Addon

local defaults = {
	profile = {
		window = {
			point = "CENTER", relPoint = "CENTER", x = 0, y = 0,
			width = 240, height = 200,
			locked = false, shown = true, collapsed = false, autoCollapse = true,
		},
		coach = true,
		announce = false, -- opt-in: one MVP line to group chat on run completion
		bars = {
			height = 18,
			max = 10,
			fontSize = 11,
		},
		history = {
			maxFights = 200,
		},
		scoring = {
			normalizeIlvl = true,
		},
		debug = false,
		probe = false,
	},
}

function Addon:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("TrueParseDB", defaults, true)
	self:RegisterChatCommand("trueparse", "HandleSlash")
	self:RegisterChatCommand("tp", "HandleSlash")
end

-- Benchmarks are point-in-time WCL statistics; class tuning drifts every
-- balance patch. Nudge (once per session) when they're getting stale.
local function checkBenchmarkAge()
	local B = TP.Benchmarks
	if not B or not B.generated then
		return
	end
	local y, m, d = B.generated:match("^(%d+)-(%d+)-(%d+)$")
	if not y then
		return
	end
	local ageDays = (time() - time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })) / 86400
	if ageDays >= 60 then
		Addon:Print(("Spec benchmarks are %d days old; grades may drift from current class tuning. Regenerate with scripts\\fetch-benchmarks.ps1 (see README)."):format(ageDays))
	end
end

function Addon:OnEnable()
	if not TP.Compat.IS_RETAIL then
		TP.Scoring.Capabilities.SetMoPRules(true)
	end
	checkBenchmarkAge()
	TP.Roster:OnEnable()
	TP.Segments:OnEnable()
	TP.EnableCombatLog()
	TP.FightHistory:OnEnable()
	TP.CastProbe:OnEnable()
	TP.CoachLine:OnEnable()
	TP.Career:OnEnable()
	TP.Sync:OnEnable()
	TP.RunSummary:OnEnable()
	TP.MeterWindow:OnEnable()
end

-- Options passed to every Engine.ScoreFight call from the UI
function TP.GetScoringOptions()
	return { normalizeIlvl = Addon.db.profile.scoring.normalizeIlvl }
end

function Addon:HandleSlash(input)
	local cmd, rest = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
	if cmd == "" then
		TP.MeterWindow:Toggle()
	elseif cmd == "lock" then
		self.db.profile.window.locked = not self.db.profile.window.locked
		self:Print(self.db.profile.window.locked and "Window locked." or "Window unlocked (drag to move).")
	elseif cmd == "reset" then
		local w = self.db.profile.window
		w.point, w.relPoint, w.x, w.y = "CENTER", "CENTER", 0, 0
		TP.MeterWindow:ApplyPosition()
		self:Print("Window position reset.")
	elseif cmd == "debug" then
		self.db.profile.debug = not self.db.profile.debug
		self:Print("Debug " .. (self.db.profile.debug and "on." or "off."))
	elseif cmd == "fights" then
		local fights = TP.FightHistory.fights
		if #fights == 0 then
			self:Print("No fights captured yet.")
		else
			self:Print(("Captured fights (%d, newest first):"):format(#fights))
			for i = 1, math.min(#fights, 10) do
				local f = fights[i]
				local players = 0
				for _ in pairs(f.players) do
					players = players + 1
				end
				self:Print(("  %d. %s — %d:%02d, %d players, dmg %s, heal %s, kicks %d"):format(
					i, f.name, math.floor(f.duration / 60), f.duration % 60, players,
					TP.FormatNumber(f.totals.damage or 0), TP.FormatNumber(f.totals.healing or 0),
					f.totals.interrupts or 0))
			end
		end
	elseif cmd == "run" then
		TP.RunSummary:Report()
	elseif cmd == "career" then
		TP.Career:PrintSummary()
	elseif cmd == "coach" then
		self.db.profile.coach = not self.db.profile.coach
		self:Print("Post-fight coach line " .. (self.db.profile.coach and "on." or "off."))
	elseif cmd == "announce" then
		self.db.profile.announce = not self.db.profile.announce
		self:Print("Run-MVP group chat announcement "
			.. (self.db.profile.announce and "ON — one line to group chat when a run completes." or "off."))
	elseif cmd == "ilvl" then
		self.db.profile.scoring.normalizeIlvl = not self.db.profile.scoring.normalizeIlvl
		self:Print("Item-level normalization "
			.. (self.db.profile.scoring.normalizeIlvl and "on — grades are relative to gear."
				or "off — grades compare absolute output."))
		TP.MeterWindow:Invalidate()
	elseif cmd == "score" then
		local idx = tonumber(rest) or 1
		local fight = TP.FightHistory.fights[idx]
		if not fight then
			self:Print("No captured fight #" .. idx .. " (see /tp fights).")
		else
			local results = TP.Scoring.Engine.ScoreFight(fight, TP.GetScoringOptions())
			self:Print(("Contribution scores — %s (%d:%02d):"):format(
				fight.name, math.floor(fight.duration / 60), fight.duration % 60))
			for i, r in ipairs(results) do
				local grade = TP.Scoring.Grades.ForScore(r.score)
				local gr, gg, gb = TP.Scoring.Grades.Color(grade)
				local penaltyText = r.penalty > 0 and (" |cffff4444(-%.0f)|r"):format(r.penalty) or ""
				self:Print(("  %d. |cff%02x%02x%02x%s|r %s [%s] — %.0f%s"):format(
					i, gr * 255, gg * 255, gb * 255, grade, r.name, r.role, r.score, penaltyText))
			end
		end
	elseif cmd == "probe" then
		if rest == "status" then
			TP.CastProbe:Report(true)
		else
			self.db.profile.probe = not self.db.profile.probe
			self:Print("Cast probe " .. (self.db.profile.probe and "on." or "off."))
		end
	else
		self:Print("Commands: /tp (toggle window), /tp lock, /tp reset, /tp fights, /tp score [n], /tp run, /tp career, /tp coach, /tp announce, /tp ilvl, /tp debug, /tp probe")
	end
end

-- Secret-proof debug print: secret values crash table.concat inside
-- AceConsole, so stringify every arg defensively first.
function Addon:Debug(...)
	if not (self.db and self.db.profile.debug) then
		return
	end
	local IsSecret = TP.Compat.IsSecret
	local out = {}
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		out[i] = IsSecret(v) and "<secret>" or tostring(v)
	end
	self:Print("|cff888888[debug]|r " .. table.concat(out, " "))
end

-- TEMPORARY diagnostics: these events fire synchronously inside the blocked
-- call, so debugstack() here reveals the offending call site. Remove once
-- the load error is fixed.
local diag = CreateFrame("Frame")
diag:RegisterEvent("ADDON_ACTION_FORBIDDEN")
diag:RegisterEvent("ADDON_ACTION_BLOCKED")
diag:SetScript("OnEvent", function(_, event, addonName, func)
	if addonName ~= ADDON_NAME then
		return
	end
	local stack = debugstack(3, 20, 0)
	print("|cffff4444TrueParse diag:|r", event, "->", tostring(func))
	for line in stack:gmatch("[^\n]+") do
		if line:find("TrueParse", 1, true) then
			print("|cffff8888  at:|r", line)
		end
	end
	if Addon.db then
		Addon.db.global.lastBlocked = { event = event, func = tostring(func), stack = stack, when = date() }
	end
end)
