-- Active-mitigation buffs per tank spec, RETAIL. Uptime of these is
-- the tank-skill ingredient the Tanking composite reads; on retail
-- each tank's own install tracks its own aura uptime (own auras are
-- readable) and donates it over Sync — Midnight has no CLEU.
-- PROVISIONAL IDs (2026-07-25): seeded from the classic AM buff set;
-- verify against Wowhead retail like the Mists list was (buff ids,
-- not cast ids).
local _, TP = ...

TP.MITIGATION_BUFFS = {
	[132404] = true, -- Shield Block buff (Protection Warrior; cast = 2565)
	[132403] = true, -- Shield of the Righteous buff (Prot Paladin; cast = 53600)
	[192081] = true, -- Ironfur (Guardian Druid)
	[77535] = true, -- Blood Shield (Blood DK; Death Strike mastery absorb)
	[203819] = true, -- Demon Spikes buff (Vengeance DH; cast = 203720)
	[215479] = true, -- Shuffle (Brewmaster Monk)
}
