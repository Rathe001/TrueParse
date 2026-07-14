-- Avoidable damage sources, MoP Classic (the "Stood in bad" penalty).
-- Anything listed here counts toward a player's avoidable-damage share.
-- SAFETY: the engine only penalizes damage BEYOND an equal share of the
-- group's total from these spells - a mechanic the whole raid eats equally
-- can never hurt anyone's score, so a borderline entry fails soft.
-- Curate with /tp baddies after a raid night: it prints the session's top
-- damage-taken spells with their IDs. VERIFY before adding (wrong IDs =
-- unfair penalties; see the Blood Pact lesson): open the fight's log on
-- Warcraft Logs -> Post-Pull Analysis -> Damage Taken -> "Avoidable (By
-- Spell)" — WCL's own curated avoidable list for the fight. An ID both
-- there and in /tp baddies is confirmed; one only here should be
-- reviewed (2026-07-14, Josh's verification path).
local _, TP = ...

TP.AVOIDABLE = {
	-- Seasonal dungeons, curated from Josh's 2026-07-13 /tp baddies paste.
	-- Rule: ground effects, swirls, whirls, and bombs go in (movement
	-- dodges them; shared eating fails soft). TARGETED caster damage
	-- (Arc/Chain Lightning, Fire Bolt, Arcane Shock, Magistrike) stays
	-- out: random targeting hits unevenly through no fault of the player.
	[1298492] = true, -- Falling Ash (ground zones)
	[1298487] = true, -- Shockwave Missile (impact swirl)
	[1298486] = true, -- Shockwave Missile (impact swirl, second ID)
	[1298465] = true, -- Ironstorm (whirl aura)
	[1298482] = true, -- Ravager (Herod's whirlwind toy)
	[107215] = true,  -- Mantid Munition Explosion (bomb)
	[110968] = true,  -- Purifying Flames (ground fire)
	[110963] = true,  -- Flamestrike (ground fire)
	[106966] = true,  -- Explosion (bomb)
	-- Siege of Orgrimmar: still to be filled from a raid-night paste.
}
