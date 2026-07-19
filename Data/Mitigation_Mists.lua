-- Active-mitigation buffs per tank spec, MoP Classic. Uptime of these is
-- THE tank skill metric of the expansion; Metrics/Mitigation.lua tracks
-- aura uptime for everyone via CLEU (SPELL_AURA_APPLIED = BUFF ids, not
-- cast ids — Shield Block casts 2565 but applies 132404).
-- ALL IDs VERIFIED vs Wowhead MoP Classic 2026-07-19.
-- Deliberately OUT: Bone Shield 49222 (near-permanent charge buff —
-- would wash the uptime signal to ~100%% for every Blood DK), Frenzied
-- Regeneration 22842 (instant heal, NO aura in MoP — unmatchable here),
-- Anti-Magic Shell (personal magic CD, not AM rotation).
local _, TP = ...

TP.MITIGATION_BUFFS = {
	[115307] = true, -- Shuffle (Brewmaster)
	[132404] = true, -- Shield Block buff (Protection Warrior; cast = 2565)
	[112048] = true, -- Shield Barrier (Protection Warrior; cast = aura)
	[132403] = true, -- Shield of the Righteous buff (Prot Paladin; cast = 53600)
	[132402] = true, -- Savage Defense buff (Guardian; cast = 62606)
	[77535] = true,  -- Blood Shield (Blood DK; mastery absorb, aura-only)
	[115295] = true, -- Guard (Brewmaster; cast = aura)
	[123402] = true, -- Guard, Glyph of Guard magic-only variant
	[115308] = true, -- Elusive Brew active dodge (NOT the 128938/9 stacks)
	[65148] = true,  -- Sacred Shield absorb aura (Prot Paladin talent; cast = 20925)
}
