-- Major healing/raid cooldowns (MoP), for danger-window timing: a cast
-- of one of these inside a group-damage spike is exactly what the
-- cooldown exists for. Curated and conservative — big buttons only.
-- ALL IDs VERIFIED vs Wowhead MoP Classic 2026-07-19 (cast IDs, which
-- is what SPELL_CAST_SUCCESS emits — not the triggered heals/ground
-- auras). Non-healer raid CDs belong here too: team coverage asks "was
-- the window covered", and a warrior's Rallying Cry covers it.
local _, TP = ...

TP.HEALER_CDS = {
	[740] = true,    -- Tranquility (44203 is the internal trigger, not this)
	[64843] = true,  -- Divine Hymn (64844 = triggered heal)
	[62618] = true,  -- Power Word: Barrier (81782 = ground aura)
	[33206] = true,  -- Pain Suppression
	[47788] = true,  -- Guardian Spirit
	[108280] = true, -- Healing Tide Totem (summon cast; ticks are 114941/2)
	[98008] = true,  -- Spirit Link Totem (summon cast; tick is 98021)
	[114052] = true, -- Ascendance (Restoration)
	[115310] = true, -- Revival
	[116849] = true, -- Life Cocoon
	[102342] = true, -- Ironbark
	[31821] = true,  -- Devotion Aura
	[33891] = true,  -- Incarnation: Tree of Life
	[6940] = true,   -- Hand of Sacrifice (external, same tier as Ironbark)
	[97462] = true,  -- Rallying Cry (warrior raid CD)
	[108281] = true, -- Ancestral Guidance (talent, common on resto shamans)
	[115213] = true, -- Avert Harm (brewmaster raid CD, exists all of MoP)
	[15286] = true,  -- Vampiric Embrace (shadow's raid-healing CD)
}

-- Raid-WIDE cooldowns and who baseline-owns them, for the group card's
-- assignment line ("...sat unused"). Single-target externals (Pain
-- Suppression, Guardian Spirit, Ironbark, Life Cocoon, Sacrifice) are
-- deliberately absent - "assign the raid CD" advice only makes sense for
-- raid-wide buttons. Talent CDs (Ancestral Guidance, Ascendance) are
-- absent too: talents aren't observable, and naming a button nobody took
-- would be wrong. Names ship in English, like every data-file key.
TP.RAID_CDS = {
	[740] = { spec = 105, name = "Tranquility" },
	[64843] = { spec = 257, name = "Divine Hymn" },
	[62618] = { spec = 256, name = "Power Word: Barrier" },
	[108280] = { spec = 264, name = "Healing Tide Totem" },
	[98008] = { spec = 264, name = "Spirit Link Totem" },
	[115310] = { spec = 270, name = "Revival" },
	[31821] = { spec = 65, name = "Devotion Aura" },
	[97462] = { class = "WARRIOR", name = "Rallying Cry" },
	[115213] = { spec = 268, name = "Avert Harm" },
	[15286] = { spec = 258, name = "Vampiric Embrace" },
}
