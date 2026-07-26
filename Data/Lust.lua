-- Bloodlust-window data, RETAIL. Each install detects the window from
-- its OWN aura (own auras are readable on retail) and self-reports its
-- lust-window cooldown usage over Sync — Midnight has no CLEU.
-- Unlike the Mists list there is no curated offensive-CD table here:
-- retail detects "big offensive button" generically via
-- GetSpellBaseCooldown (>= 60s base cooldown, not a defensive).
-- PROVISIONAL aura ids (2026-07-25): verify against Wowhead retail.
local _, TP = ...

TP.LUST = {
	[2825] = true, -- Bloodlust (Shaman, Horde)
	[32182] = true, -- Heroism (Shaman, Alliance)
	[80353] = true, -- Time Warp (Mage)
	[264667] = true, -- Primal Rage (Hunter pet)
	[390386] = true, -- Fury of the Aspects (Evoker)
}
