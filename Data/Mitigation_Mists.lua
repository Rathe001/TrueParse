-- Active-mitigation buffs per tank spec, MoP Classic. Uptime of these is
-- THE tank skill metric of the expansion; Metrics/Mitigation.lua tracks
-- aura uptime for everyone via CLEU. Informational bullets only.
-- IDs from the MoP 5.x buff family; verify against Warcraft Logs buff
-- tabs before extending (the Blood Pact lesson applies to tanks too).
local _, TP = ...

TP.MITIGATION_BUFFS = {
	[115307] = true, -- Shuffle (Brewmaster)
	[132404] = true, -- Shield Block (Protection Warrior)
	[112048] = true, -- Shield Barrier (Protection Warrior)
	[132403] = true, -- Shield of the Righteous (Protection Paladin)
	[132402] = true, -- Savage Defense (Guardian)
	[77535] = true,  -- Blood Shield (Blood DK)
}
