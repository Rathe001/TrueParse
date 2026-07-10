-- Bloodlust-window data, MoP Classic. Used by Metrics/Lust.lua to judge
-- whether DPS players stacked their cooldowns and potion into the 40s
-- window. Informational bullets only - never scored. Curated conservative:
-- big offensive buttons only; a missing ID means a missed compliment, a
-- wrong one a bogus count, so verify against Warcraft Logs before adding.
local _, TP = ...

-- The lust buffs themselves (any one opens the window)
TP.LUST = {
	[2825] = true,   -- Bloodlust
	[32182] = true,  -- Heroism
	[80353] = true,  -- Time Warp
	[90355] = true,  -- Ancient Hysteria (Core Hound pet)
}

-- Major offensive cooldowns per class (SPELL_CAST_SUCCESS IDs)
TP.OFFENSIVE_CDS = {
	-- Warrior
	[1719] = true,   -- Recklessness
	[107574] = true, -- Avatar
	[12292] = true,  -- Bloodbath
	[114207] = true, -- Skull Banner
	-- Paladin
	[31884] = true,  -- Avenging Wrath
	[105809] = true, -- Holy Avenger
	-- Hunter
	[19574] = true,  -- Bestial Wrath
	[3045] = true,   -- Rapid Fire
	[121818] = true, -- Stampede
	-- Rogue
	[13750] = true,  -- Adrenaline Rush
	[121471] = true, -- Shadow Blades
	[79140] = true,  -- Vendetta
	[51690] = true,  -- Killing Spree
	[51713] = true,  -- Shadow Dance
	-- Priest
	[10060] = true,  -- Power Infusion
	-- Death Knight
	[51271] = true,  -- Pillar of Frost
	[49016] = true,  -- Unholy Frenzy
	[49206] = true,  -- Summon Gargoyle
	-- Shaman
	[114049] = true, -- Ascendance
	[16166] = true,  -- Elemental Mastery
	[2894] = true,   -- Fire Elemental Totem
	[51533] = true,  -- Feral Spirit
	[120668] = true, -- Stormlash Totem
	-- Mage
	[12472] = true,  -- Icy Veins
	[12042] = true,  -- Arcane Power
	[11129] = true,  -- Combustion
	[55342] = true,  -- Mirror Image
	-- Warlock (Dark Soul flavors)
	[113858] = true, -- Dark Soul: Instability
	[113860] = true, -- Dark Soul: Misery
	[113861] = true, -- Dark Soul: Knowledge
	-- Monk
	[116740] = true, -- Tigereye Brew
	[123904] = true, -- Invoke Xuen, the White Tiger
	-- Druid
	[112071] = true, -- Celestial Alignment
	[102560] = true, -- Incarnation: Chosen of Elune
	[106951] = true, -- Berserk (feral)
	[102543] = true, -- Incarnation: King of the Jungle
	[124974] = true, -- Nature's Vigil
}

-- DPS potion buffs (SPELL_AURA_APPLIED IDs)
TP.DPS_POTIONS = {
	[105706] = true, -- Potion of Mogu Power (strength)
	[105697] = true, -- Virmen's Bite (agility)
	[105702] = true, -- Potion of the Jade Serpent (intellect)
}
