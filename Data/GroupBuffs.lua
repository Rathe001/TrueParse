-- Raid buff categories per game version: which classes are responsible for
-- providing them, and which aura spell IDs satisfy the category. Extendable.
local _, TP = ...

if TP.Compat.IS_RETAIL then
	TP.GROUP_BUFFS = {
		{ key = "fortitude", label = "Power Word: Fortitude",
			providers = { PRIEST = true }, auras = { [21562] = true } },
		{ key = "intellect", label = "Arcane Intellect",
			providers = { MAGE = true }, auras = { [1459] = true } },
		{ key = "attackpower", label = "Battle Shout",
			providers = { WARRIOR = true }, auras = { [6673] = true } },
		{ key = "wild", label = "Mark of the Wild",
			providers = { DRUID = true }, auras = { [1126] = true } },
		{ key = "skyfury", label = "Skyfury",
			providers = { SHAMAN = true }, auras = { [462854] = true } },
	}
else
	-- Mists of Pandaria: categories have multiple providers; any listed aura
	-- satisfies the category. (Haste/crit/mastery omitted in v1.)
	-- GOTCHA (field-verified 2026-07-09): several MoP buffs apply a DIFFERENT
	-- aura ID than the cast — Legacy of the Emperor's raid-wide cast lands as
	-- 117666, not 115921. Missing IDs here read as "didn't buff" and penalize
	-- innocent providers. Pet auras satisfy categories but add no provider.
	TP.GROUP_BUFFS = {
		{ key = "stats", label = "Stats (Kings/Wild/Legacy)",
			providers = { DRUID = true, PALADIN = true, MONK = true },
			auras = { [1126] = true, [20217] = true, [115921] = true,
				[117666] = true, -- Legacy of the Emperor, raid-wide applied aura
				[90363] = true }, -- Embrace of the Shale Spider (hunter pet)
		},
		{ key = "stamina", label = "Stamina (Fort/Commanding)",
			providers = { PRIEST = true, WARRIOR = true, WARLOCK = true },
			auras = { [21562] = true, [469] = true, [6307] = true,
				[90364] = true }, -- Qiraji Fortitude (hunter pet)
		},
		{ key = "attackpower", label = "Attack Power (Horn/Trueshot/Shout)",
			providers = { DEATHKNIGHT = true, HUNTER = true, WARRIOR = true },
			auras = { [57330] = true, [19506] = true, [6673] = true } },
		{ key = "spellpower", label = "Spell Power (Intent/Brilliance/Wrath)",
			providers = { WARLOCK = true, MAGE = true, SHAMAN = true },
			auras = { [109773] = true, [1459] = true,
				[61316] = true,   -- Dalaran Brilliance
				[77747] = true,   -- Burning Wrath (shaman)
				[126309] = true }, -- Still Water (hunter pet)
		},
	}
end
