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
