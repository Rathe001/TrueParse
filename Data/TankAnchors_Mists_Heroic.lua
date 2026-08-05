-- HEROIC active-mitigation uptime baselines, crawled 2026-08-05 from Warcraft
-- Logs difficulty 4 (Heroic), sizes 10 and 25, Siege of Orgrimmar - 200
-- reports. Regenerate with:
--   pwsh scripts/fetch-tank-mitigation.ps1 -Brackets "4x10,4x25" -EmitAlt "5,6" `
--        -OutFile TankAnchors_Mists_Heroic.lua
--
-- Data/TankAnchors_Mists.lua is NORMAL only (-Brackets "3x10,3x25") and was
-- being applied to Heroic too, which is not the same field: heroic tanks hold
-- active mitigation up MORE, not less. Prot Warrior's median is 29.7 here
-- against 26.4 on Normal, Prot Paladin's 68.3 against 56.1.
--
-- `difficulties` are BLIZZARD difficultyIDs (5 = 10 Heroic, 6 = 25 Heroic),
-- not WCL's - WCL calls Heroic 4 and carries the raid size separately.
local _, TP = ...

TP.TANK_ANCHORS_ALT = {
	difficulties = { [5] = true, [6] = true },
	anchors = {
		default = { 41.1, 59.6, 68.8 }, -- DERIVED: median of the 5 crawled specs
		[66] = { 41.1, 68.3, 79.7 }, -- Prot Paladin (n=79)
		[73] = { 20, 29.7, 45.5 }, -- Prot Warrior (n=79)
		[104] = { 14.7, 26.5, 40.8 }, -- Guardian Druid (n=44)
		[250] = { 46.2, 59.6, 68.8 }, -- Blood DK (n=83)
		[268] = { 69.3, 80.9, 92.7 }, -- Brewmaster (n=66)
	},
}

-- Tank DAMAGE on Heroic, same crawl, same units (multiple of the group's
-- per-player mean). Heroic tanks contribute more relative to their group.
TP.TANK_DAMAGE_ANCHORS_ALT = {
	difficulties = { [5] = true, [6] = true },
	anchors = {
		default = { 1.13, 1.49, 1.91 }, -- DERIVED: median of the 5 crawled specs
		[66] = { 1.04, 1.4, 1.87 }, -- Prot Paladin (n=74)
		[73] = { 0.88, 1.34, 1.83 }, -- Prot Warrior (n=75)
		[104] = { 1.13, 1.49, 1.91 }, -- Guardian Druid (n=44)
		[250] = { 1.22, 1.63, 2.02 }, -- Blood DK (n=83)
		[268] = { 1.31, 1.67, 2.18 }, -- Brewmaster (n=63)
	},
}
