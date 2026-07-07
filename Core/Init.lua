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
			maxFights = 15,
		},
		debug = false,
		probe = true,
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
	TP.CastProbe:OnEnable()
	TP.MeterWindow:OnEnable()
end

function Addon:HandleSlash(input)
	local cmd = (input or ""):lower():match("^%s*(%S*)")
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
	elseif cmd == "probe" then
		self.db.profile.probe = not self.db.profile.probe
		self:Print("Cast probe " .. (self.db.profile.probe and "on." or "off."))
	else
		self:Print("Commands: /tp (toggle window), /tp lock, /tp reset, /tp debug, /tp probe")
	end
end

function Addon:Debug(...)
	if self.db and self.db.profile.debug then
		self:Print("|cff888888[debug]|r", ...)
	end
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
