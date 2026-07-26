-- Major healing/raid cooldowns, RETAIL. A cast of one of these near a
-- group-damage spike is exactly what the cooldown exists for; each
-- TrueParse healer self-reports its own cast times (own casts are
-- readable) so retail can rebuild MoP's raid-CD-coverage metric from
-- reporters (Midnight has no CLEU). Cast IDs, not triggered heals.
-- PROVISIONAL ids (2026-07-25): verify against Wowhead retail like the
-- Mists list was — a wrong id is a missed coverage, not a bogus one.
local _, TP = ...

TP.HEALER_CDS = {
	-- Priest
	[64843] = true, -- Divine Hymn
	[62618] = true, -- Power Word: Barrier
	[33206] = true, -- Pain Suppression
	[47788] = true, -- Guardian Spirit
	-- Druid
	[740] = true, -- Tranquility
	[102342] = true, -- Ironbark
	[197721] = true, -- Flourish
	-- Shaman
	[108280] = true, -- Healing Tide Totem
	[98008] = true, -- Spirit Link Totem
	[114052] = true, -- Ascendance (Restoration)
	-- Monk
	[115310] = true, -- Revival
	[116849] = true, -- Life Cocoon
	-- Paladin
	[31821] = true, -- Aura Mastery
	[6940] = true, -- Blessing of Sacrifice
	[31884] = true, -- Avenging Wrath (Holy raid throughput)
	-- Evoker (Preservation)
	[370960] = true, -- Emerald Communion
	[363534] = true, -- Rewind
	[357170] = true, -- Time Dilation
	-- Non-healer raid CDs (team coverage asks "was the window covered")
	[97462] = true, -- Rallying Cry (Warrior)
}

-- Single-target externals and who owns them, for the tank-spike pool
-- (same ownership gate as MoP). PROVISIONAL specIDs + ids.
TP.EXTERNALS = {
	[33206] = { spec = 256, name = "Pain Suppression" }, -- Discipline
	[47788] = { spec = 257, name = "Guardian Spirit" }, -- Holy
	[102342] = { spec = 105, name = "Ironbark" }, -- Restoration Druid
	[116849] = { spec = 270, name = "Life Cocoon" }, -- Mistweaver
	[6940] = { spec = 65, name = "Blessing of Sacrifice" }, -- Holy Paladin
	[357170] = { spec = 1468, name = "Time Dilation" }, -- Preservation
}

TP.EXTERNALS_BY_SPEC = {}
for _, ext in pairs(TP.EXTERNALS) do
	TP.EXTERNALS_BY_SPEC[ext.spec] = ext.name
end
