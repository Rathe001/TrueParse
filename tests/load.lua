-- Load EVERY file a client loads, in TOC order, with WoW globals stubbed -
-- the closest headless approximation of PLAYER_LOGIN. A syntax check proves a
-- file PARSES; this proves it RUNS, which is where a bad file-scope
-- expression, a missing load-order dependency or an indexing error actually
-- bites. Those are the failures a user sees as a red Lua error before the
-- addon has done anything at all.
--
-- Both TOCs are checked, because the two clients load different file sets and
-- a retail-only or Mists-only break is invisible in the other.
--
--   lua tests/load.lua            (both)
--   lua tests/load.lua <toc>      (one)
local only = ...
_G.WOW_PROJECT_ID, _G.WOW_PROJECT_MAINLINE, _G.WOW_PROJECT_MISTS_CLASSIC = 5, 1, 5
local stub = setmetatable({}, { __index = function() return function() return nil end end })
local function frame()
	local f = setmetatable({}, { __index = function() return function() return stub end end })
	return f
end
_G.CreateFrame = function() return frame() end
_G.UnitGUID = function() return "Player-1-0001" end
_G.UnitName = function() return "Tester" end
_G.GetTime = function() return 1000 end
_G.time = os.time
_G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
_G.issecretvalue = function() return false end
_G.GetInstanceInfo = function() return "Zone", "raid", 3, "Normal", 10 end
_G.GetZoneText = function() return "Zone" end
_G.UnitAffectingCombat = function() return false end
_G.UnitExists = function() return false end
_G.UnitThreatSituation = function() return 0 end
_G.UnitHealthMax = function() return 100 end
_G.IsInGroup, _G.IsInRaid = function() return false end, function() return false end
_G.C_Timer = { After = function() end, NewTicker = function() return stub end }
_G.Enum = setmetatable({}, { __index = function() return setmetatable({}, { __index = function() return 1 end }) end })
_G.C_UnitAuras = { GetAuraDataByIndex = function() return nil end }
_G.LibStub = function() return setmetatable({}, { __index = function() return function() return stub end end }) end
_G.hooksecurefunc = function() end
_G.GameFontHighlightSmall = {}
_G.PixelUtil = stub
_G.GameTooltip = stub
_G.SlashCmdList = {}
_G.bit = { band = function() return 0 end, bor = function() return 0 end, bxor = function() return 0 end, lshift = function() return 0 end, rshift = function() return 0 end }
_G.StaticPopupDialogs = {}
_G.StaticPopup_Show = function() end
_G.UIParent = frame()
_G.C_DamageMeter = nil
local function checkToc(toc)
	-- a FRESH namespace per client: the two TOCs load different files and
	-- must not inherit each other's tables
	local TP = {}
	local files, n, bad = {}, 0, 0
	for line in io.lines(toc) do
		line = line:gsub("^98791", ""):gsub("%s+$", "")
		if line:match("%.lua$") and not line:match("^#") then
			files[#files + 1] = (line:gsub("\\", "/"))
		end
	end
	for _, f in ipairs(files) do
		local chunk, err = loadfile(f)
		if not chunk then
			print(("LOAD-FAIL %-34s %s"):format(f, err))
			bad = bad + 1
		else
			local ok, e = pcall(chunk, "TrueParse", TP)
			if not ok then
				print(("RUN-FAIL  %-34s %s"):format(f, e))
				bad = bad + 1
			else
				n = n + 1
			end
		end
	end
	print(("%-26s %d/%d files executed; %d failed"):format(toc, n, #files, bad))
	return bad
end

local tocs = only and { only } or { "TrueParse_Mists.toc", "TrueParse_Mainline.toc" }
local failed = 0
for _, t in ipairs(tocs) do
	failed = failed + checkToc(t)
end
print("")
if failed > 0 then
	print(("%d FILES FAILED TO LOAD"):format(failed))
	os.exit(1)
end
print("ALL FILES LOAD CLEAN")
