-- Major healing/raid cooldowns (MoP), for danger-window timing: a cast
-- of one of these inside a group-damage spike is exactly what the
-- cooldown exists for. Curated and conservative — big buttons only.
-- UNVERIFIED against WCL cast IDs (same caveat as Mitigation_Mists):
-- field-check with /tp debug when a healer runs a raid.
local _, TP = ...

TP.HEALER_CDS = {
	[740] = true,    -- Tranquility
	[64843] = true,  -- Divine Hymn
	[62618] = true,  -- Power Word: Barrier
	[33206] = true,  -- Pain Suppression
	[47788] = true,  -- Guardian Spirit
	[108280] = true, -- Healing Tide Totem
	[98008] = true,  -- Spirit Link Totem
	[114052] = true, -- Ascendance (Restoration)
	[115310] = true, -- Revival
	[116849] = true, -- Life Cocoon
	[102342] = true, -- Ironbark
	[31821] = true,  -- Devotion Aura
	[33891] = true,  -- Incarnation: Tree of Life
}
