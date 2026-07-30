-- Temporary-empowerment procs excluded from scored damage and healing
-- (MoP seasonal dungeons): the celestial buffs hand players huge
-- proc damage/heals that are RNG and buff-assignment, not performance —
-- one player's "Serpent's Jadefire" at 22% of their damage buried the
-- real comparison (2026-07-14, Taran Zhu). Details still shows raw
-- numbers; TrueParse scores what the PLAYER did.
--
-- SAFETY: excluding a shared, evenly-distributed proc changes nobody's
-- relative standing, so a borderline entry fails soft — but a proc
-- only SOME players have skews hard, which is exactly why these are out.
--
-- Curate with /tp procs after a run (prints the session's top damage
-- and healing sources with IDs); names below are the bootstrap for
-- entries whose IDs haven't been captured yet (English clients; IDs
-- are locale-safe — promote names to IDs as /tp procs reports them).
local _, TP = ...

TP.PROC_EXCLUDE_IDS = {
	-- promote from /tp procs pastes
}

-- Names that COLLIDE with a real class ability. A name exclusion is a blunt
-- instrument - it cannot see who cast the spell - and "Earthquake" is both the
-- Niuzao celestial proc and Elemental Shaman's AoE. Excluding the name alone
-- would silently delete a Shaman's real damage, which is the Essence of Yu'lon
-- mistake in the note above, repeated.
-- So: the name is excluded EXCEPT for these ids, which are the legitimate
-- spell. Confirm each with /tp procs on a real run - an id here that is wrong
-- lets the proc back in, which is merely the status quo, but a MISSING one
-- takes a class's damage away.
TP.PROC_NAME_KEEP_IDS = {
	[61882] = true, -- Earthquake — Elemental Shaman (NOT the Niuzao proc)
}

TP.PROC_EXCLUDE_NAMES = {
	-- celestial empowerment procs seen 2026-07-14 (Taran Zhu seasonal).
	-- NEVER exclude legendary-cloak procs: "Essence of Yu'lon" (148008)
	-- is the caster cloak's own proc — WCL populations include cloak
	-- damage, and the name-match was subtracting 112M of legitimate SoO
	-- damage from casters' scores (caught by /tp procs, 2026-07-14).
	-- "Xuen's Ferocity" stays: the cloak proc is "Flurry of Xuen"
	-- (147891), a different name.
	["Serpent's Jadefire"] = true,
	["Xuen's Ferocity"] = true,
	["Burning Song"] = true,
	["Blazing Song"] = true,
	-- Niuzao's (Josh 2026-07-30, naming the set: "Xuen's ferocity, Serpent's
	-- jadefire, Earthquake(Niuzao), Blazing song"). Guarded by
	-- PROC_NAME_KEEP_IDS above so the Shaman spell survives.
	["Earthquake"] = true,
}

function TP.IsExcludedProc(spellID, spellName)
	if spellID and TP.PROC_EXCLUDE_IDS[spellID] then
		return true
	end
	-- an explicit id ALWAYS beats a name collision
	if spellID and TP.PROC_NAME_KEEP_IDS[spellID] then
		return false
	end
	return spellName ~= nil and TP.PROC_EXCLUDE_NAMES[spellName] or false
end
