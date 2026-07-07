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
			locked = false, shown = true,
		},
		bars = {
			height = 18,
			max = 10,
			fontSize = 11,
		},
		history = {
			maxFights = 200,
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

function Addon:OnEnable()
	TP.Roster:OnEnable()
	TP.Segments:OnEnable()
	TP.EnableCombatLog()
	TP.FightHistory:OnEnable()
	TP.CastProbe:OnEnable()
	TP.MeterWindow:OnEnable()
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
	elseif cmd == "probe" then
		if rest == "status" then
			TP.CastProbe:Report(true)
		else
			self.db.profile.probe = not self.db.profile.probe
			self:Print("Cast probe " .. (self.db.profile.probe and "on." or "off."))
		end
	else
		self:Print("Commands: /tp (toggle window), /tp lock, /tp reset, /tp fights, /tp debug, /tp probe")
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
