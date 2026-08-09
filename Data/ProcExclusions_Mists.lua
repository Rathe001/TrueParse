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
	-- EMPTY ON PURPOSE (Josh 2026-08-09). The four celestial empowerment
	-- names used to live here, and measuring what they actually removed is
	-- what retired them: across one of Josh's sessions the filter deleted
	-- 1,246,881,628 damage - 1.63% of 76.4B - while the celestial run it was
	-- meant to police accounted for roughly 146M of that session. So almost
	-- everything it took was SoO RAID damage, which is the same failure as
	-- the "Essence of Yu'lon" incident these entries were written after:
	--
	--   Xuen's Ferocity     487.7M      Serpent's Jadefire  402.4M
	--   Blazing Song        249.4M      Burning Song        102.7M
	--
	-- A name cannot see the context it fired in, and these fire in the raid
	-- too. The five-man inflation they were standing in for is handled where
	-- it belongs instead - Weights.mopFiveManReference scales the REFERENCE
	-- for five-man MoP content, per role and per metric, which is measured
	-- and cannot delete anybody's damage.
	--
	-- PROC_EXCLUDE_IDS above still works and is the right tool if a specific
	-- proc ever needs removing: an id knows exactly which spell it is.
	-- NIUZAO'S IS DELIBERATELY OFF (2026-07-30). Josh named it - "Xuen's
	-- ferocity, Serpent's jadefire, Earthquake(Niuzao), Blazing song" - and it
	-- belongs here, but "Earthquake" is ALSO Elemental Shaman's AoE and the
	-- only thing standing between the two is PROC_NAME_KEEP_IDS[61882], an id
	-- taken from memory and never verified. Josh raids SoO the same night,
	-- which is where an Elemental Shaman spams Earthquake on adds: a wrong id
	-- silently deletes their damage on tier-1 curves, to fix a proc that only
	-- exists in celestial DUNGEONS. Wrong risk, wrong night.
	-- TO ENABLE: /tp procs after a celestial dungeon prints "Earthquake (id)"
	-- for the real proc. Put THAT id in PROC_EXCLUDE_IDS above - an id match
	-- needs no name rule and no keep-list - and delete this note.
	-- ["Earthquake"] = true,
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
