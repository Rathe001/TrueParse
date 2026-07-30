-- Active-mitigation buffs per tank spec, RETAIL. Uptime of these is
-- the tank-skill ingredient the Tanking composite reads; on retail
-- each tank's own install tracks its own aura uptime (own auras are
-- readable) and donates it over Sync — Midnight has no CLEU.
-- PROVISIONAL IDs (2026-07-25): seeded from the classic AM buff set;
-- verify against Wowhead retail like the Mists list was (buff ids,
-- not cast ids).
local _, TP = ...

-- CAST ids -> how long the mitigation buff they grant lasts, in seconds.
--
-- Midnight returns every field of the player's own auras as a secret
-- value (Josh 2026-07-29: /tp mit read 13 auras with Shield of the
-- Righteous visibly up, 0 with a readable id), so uptime cannot be
-- sampled from auras any more - and it isn't a matter of correcting an
-- id, because the lookup won't confirm a buff it won't describe. Your
-- OWN UNIT_SPELLCAST_SUCCEEDED is still readable, which is what the whole
-- retail self-report path is built on, so uptime is reconstructed from
-- casts instead: each cast covers `duration` seconds from when it lands,
-- unioned so a refresh doesn't double-count.
--
-- APPROXIMATE by construction. It cannot see a buff dispelled, cancelled
-- or cut short by death, and the durations below are nominal - talents
-- and haste move them. Same accuracy class as the rest of the retail
-- self-report path, and far better than the zero it reads today.
TP.MITIGATION_CASTS = {
	[53600] = 4.5, -- Shield of the Righteous (Prot Paladin)
	[2565] = 6, -- Shield Block (Prot Warrior)
	[192081] = 6, -- Ironfur (Guardian Druid)
	[203720] = 6, -- Demon Spikes (Vengeance DH)
	[49998] = 10, -- Death Strike -> Blood Shield absorb (Blood DK)
	-- BREWMASTER: the SHUFFLE GENERATORS, not a brew. Celestial Brew (322507)
	-- used to sit here and was wrong twice over - it does not appear at all in
	-- the buff tables of ranked Midnight Brewmasters (they don't talent it),
	-- and a Brewmaster who DID take it read ~20% uptime against a ~90% anchor
	-- and scored 0 on 55% of their grade. Their real active mitigation is
	-- Shuffle (215479, 99.7% uptime on ranked logs), which is not itself a
	-- cast: it is granted by these two.
	-- Durations from the in-game tooltips (Josh 2026-07-30); ids verified
	-- against a real Midnight log's Casts table rather than memory, which is
	-- how the Celestial Brew error happened. The crawler's retail set carries
	-- 215479 so the anchor measures the same button these estimate.
	[121253] = 5, -- Keg Smash: "Grants Shuffle for 5 sec"
	[205523] = 3, -- Blackout Kick: "granting Shuffle for 3 sec"
}

TP.MITIGATION_BUFFS = {
	[132404] = true, -- Shield Block buff (Protection Warrior; cast = 2565)
	[132403] = true, -- Shield of the Righteous buff (Prot Paladin; cast = 53600)
	[192081] = true, -- Ironfur (Guardian Druid)
	[77535] = true, -- Blood Shield (Blood DK; Death Strike mastery absorb)
	[203819] = true, -- Demon Spikes buff (Vengeance DH; cast = 203720)
	[215479] = true, -- Shuffle (Brewmaster Monk)
}
