-- What each spec can do, so notes are filtered to the player's tools.
--
-- One row per specialization id (GetSpecializationInfo). Fields:
--   class   UnitClass file name        role   tank | healer | dps
--   name    display                    range  melee | ranged
--   magic curse poison disease bleed   friendly dispel of that type
--   purge   removes an enemy magic buff        soothe  removes an enrage
--   kick    has an interrupt                   stun    has a hard CC for trash
--   fear    can answer a fear on somebody else (Tremor Totem, Fear Ward)
--   massdispel  has Mass Dispel itself
--   lust    brings Bloodlust / Heroism / Time Warp / Primal Rage / Fury
--   labels  spell name per dispel type, shown as the line's label
--
-- WHY fear AND massdispel ARE THEIR OWN KEYS (Josh 2026-09-08: "if it only
-- works with mass dispel, then we should only show that point to priests
-- that have mass dispel"). Both were being written as `magic` or `purge`,
-- which shows the line to everyone holding that tool - and most of them
-- cannot do the job. A fear is answered by Tremor Totem and Fear Ward as
-- much as by a dispel; Divine Shield and Impervious Shield come off to
-- Mass Dispel and nothing else.
--
-- The reverse mistake costs just as much, so `massdispel` is used ONLY where
-- Mass Dispel is the only answer. Where it is merely the efficient one -
-- Elegon's Closed Circuit, Shek'zeer's phase 3 fears - the line stays MAGIC
-- or FEAR, so every dispeller keeps a job they can actually do.
--
-- MIDNIGHT: interrupts were removed from every healer spec except
-- Restoration Shaman (Wind Shear, 30s). Talent-dependent tools (Improved
-- Purify Spirit, Poison Cleansing Totem, Cauterizing Flame, Overawe) count
-- as available; the dungeon's `build` line reminds you to take them.
-- Sources: Warcraft Wiki dispel table + Blizzard's Midnight healer post.
-- Josh: tell me which rows to double-check for the specs you play.
local _, TP = ...
local KN = TP.Notes

local C = {}
KN.CLASSES = C

local function spec(id, class, name, role, range, caps)
	caps.class, caps.name, caps.role, caps.range, caps.id = class, name, role, range, id
	caps.labels = caps.labels or {}
	C[id] = caps
end

-- WARRIOR: no dispels, no purge
spec(71,  "WARRIOR", "Arms",        "dps",  "melee",  { kick = true, stun = true })
spec(72,  "WARRIOR", "Fury",        "dps",  "melee",  { kick = true, stun = true })
spec(73,  "WARRIOR", "Protection",  "tank", "melee",  { kick = true, stun = true })

-- PALADIN: Cleanse (Holy: magic+poison+disease), Cleanse Toxins (others)
spec(65,  "PALADIN", "Holy",        "healer", "melee", { magic = true, poison = true, disease = true, stun = true,
	labels = { magic = "Cleanse", poison = "Cleanse", disease = "Cleanse" } })
spec(66,  "PALADIN", "Protection",  "tank", "melee",  { poison = true, disease = true, kick = true, stun = true,
	labels = { poison = "Cleanse Toxins", disease = "Cleanse Toxins" } })
spec(70,  "PALADIN", "Retribution", "dps",  "melee",  { poison = true, disease = true, kick = true, stun = true,
	labels = { poison = "Cleanse Toxins", disease = "Cleanse Toxins" } })

-- HUNTER: Tranquilizing Shot purges and soothes; pet lust
spec(253, "HUNTER", "Beast Mastery", "dps", "ranged", { purge = true, soothe = true, kick = true, stun = true, lust = true })
spec(254, "HUNTER", "Marksmanship",  "dps", "ranged", { purge = true, soothe = true, kick = true, stun = true, lust = true })
spec(255, "HUNTER", "Survival",      "dps", "melee",  { purge = true, soothe = true, kick = true, stun = true, lust = true })

-- ROGUE: Shiv soothes
spec(259, "ROGUE", "Assassination", "dps", "melee", { soothe = true, kick = true, stun = true })
spec(260, "ROGUE", "Outlaw",        "dps", "melee", { soothe = true, kick = true, stun = true })
spec(261, "ROGUE", "Subtlety",      "dps", "melee", { soothe = true, kick = true, stun = true })

-- PRIEST: Purify (magic+disease) for healers; Dispel Magic purges; Shadow
-- keeps Mass Dispel for magic and Silence as its kick.
--
-- VERIFIED 2026-09-08. Mass Dispel is baseline for the class in Midnight, so
-- all three specs carry `massdispel`. They do NOT carry `fear`: Fear Ward was
-- removed in patch 7.0.3 and no longer exists, so a Priest's answer to a fear
-- is an ordinary magic dispel, which `magic` already covers.
spec(256, "PRIEST", "Discipline", "healer", "ranged", { magic = true, disease = true, purge = true, massdispel = true,
	labels = { magic = "Purify", disease = "Purify" } })
spec(257, "PRIEST", "Holy",       "healer", "ranged", { magic = true, disease = true, purge = true, stun = true, massdispel = true,
	labels = { magic = "Purify", disease = "Purify" } })
spec(258, "PRIEST", "Shadow",     "dps",    "ranged", { magic = true, purge = true, kick = true, stun = true, massdispel = true,
	labels = { magic = "Mass Dispel" } })

-- DEATH KNIGHT: no dispels, no purge
spec(250, "DEATHKNIGHT", "Blood",  "tank", "melee", { kick = true, stun = true })
spec(251, "DEATHKNIGHT", "Frost",  "dps",  "melee", { kick = true, stun = true })
spec(252, "DEATHKNIGHT", "Unholy", "dps",  "melee", { kick = true, stun = true })

-- SHAMAN: Purify Spirit (Resto: magic, curse w/ talent), Cleanse Spirit
-- (curse), Poison Cleansing Totem (class talent), Purge, Capacitor, lust.
-- Tremor Totem is the class's fear answer, hence `fear` on all three specs.
--
-- CAREFUL (patch 12.0.0): Tremor Totem moved to row 9 and is now a CHOICE
-- NODE against Poison Cleansing Totem - a Shaman can have one or the other,
-- never both. Both keys stay set here, following this file's existing rule
-- that talent-gated tools count as available; what makes that honest is the
-- `BUILD` line, which already exists to tell a Shaman which of the two this
-- dungeon wants (see the Ruby Life Pools entry in Season2.lua).
-- Resto is the one healer that kept its interrupt.
spec(262, "SHAMAN", "Elemental",   "dps",    "ranged", { curse = true, poison = true, purge = true, kick = true, stun = true, lust = true, fear = true,
	labels = { curse = "Cleanse Spirit", poison = "Poison totem" } })
spec(263, "SHAMAN", "Enhancement", "dps",    "melee",  { curse = true, poison = true, purge = true, kick = true, stun = true, lust = true, fear = true,
	labels = { curse = "Cleanse Spirit", poison = "Poison totem" } })
spec(264, "SHAMAN", "Restoration", "healer", "ranged", { magic = true, curse = true, poison = true, purge = true, kick = true, stun = true, lust = true, fear = true,
	labels = { magic = "Purify Spirit", curse = "Purify Spirit", poison = "Poison totem" } })

-- MAGE: Remove Curse, Spellsteal, no hard stun
spec(62, "MAGE", "Arcane", "dps", "ranged", { curse = true, purge = true, kick = true, lust = true, labels = { curse = "Remove Curse" } })
spec(63, "MAGE", "Fire",   "dps", "ranged", { curse = true, purge = true, kick = true, lust = true, labels = { curse = "Remove Curse" } })
spec(64, "MAGE", "Frost",  "dps", "ranged", { curse = true, purge = true, kick = true, lust = true, labels = { curse = "Remove Curse" } })

-- WARLOCK: Imp's Singe Magic, Felhunter's Devour Magic / Spell Lock, Shadowfury
spec(265, "WARLOCK", "Affliction",  "dps", "ranged", { magic = true, purge = true, kick = true, stun = true, labels = { magic = "Singe Magic" } })
spec(266, "WARLOCK", "Demonology",  "dps", "ranged", { magic = true, purge = true, kick = true, stun = true, labels = { magic = "Singe Magic" } })
spec(267, "WARLOCK", "Destruction", "dps", "ranged", { magic = true, purge = true, kick = true, stun = true, labels = { magic = "Singe Magic" } })

-- MONK: Detox (Mistweaver adds magic), Leg Sweep
spec(268, "MONK", "Brewmaster", "tank",   "melee", { poison = true, disease = true, kick = true, stun = true,
	labels = { poison = "Detox", disease = "Detox" } })
spec(270, "MONK", "Mistweaver", "healer", "melee", { magic = true, poison = true, disease = true, stun = true,
	labels = { magic = "Detox", poison = "Detox", disease = "Detox" } })
spec(269, "MONK", "Windwalker", "dps",    "melee", { poison = true, disease = true, kick = true, stun = true,
	labels = { poison = "Detox", disease = "Detox" } })

-- DRUID: Nature's Cure (Resto: magic+curse+poison), Remove Corruption, Soothe
spec(102, "DRUID", "Balance",     "dps",    "ranged", { curse = true, poison = true, soothe = true, kick = true, stun = true,
	labels = { curse = "Remove Corruption", poison = "Remove Corruption" } })
spec(103, "DRUID", "Feral",       "dps",    "melee",  { curse = true, poison = true, soothe = true, kick = true, stun = true,
	labels = { curse = "Remove Corruption", poison = "Remove Corruption" } })
spec(104, "DRUID", "Guardian",    "tank",   "melee",  { curse = true, poison = true, soothe = true, kick = true, stun = true,
	labels = { curse = "Remove Corruption", poison = "Remove Corruption" } })
spec(105, "DRUID", "Restoration", "healer", "ranged", { magic = true, curse = true, poison = true, soothe = true, stun = true,
	labels = { magic = "Nature's Cure", curse = "Nature's Cure", poison = "Nature's Cure" } })

-- DEMON HUNTER: Consume Magic purges, Disrupt, Chaos Nova (class tree)
spec(577, "DEMONHUNTER", "Havoc",     "dps",  "melee", { purge = true, kick = true, stun = true })
spec(581, "DEMONHUNTER", "Vengeance", "tank", "melee", { purge = true, kick = true })
-- Midnight's third spec (1480, Core/Constants.lua knows its role). Without
-- a row it fell to KN.CLASS_FALLBACK, which pairs(C) fills in hash order,
-- so it read as Havoc or Vengeance at random (audit 2026-09-11). Tools
-- are the class-wide set; verify the name in game with
-- /dump GetSpecializationInfoByID(1480) if it ever renders wrong.
spec(1480, "DEMONHUNTER", "Devourer", "dps",  "melee", { purge = true, kick = true, stun = true })

-- EVOKER: Cauterizing Flame (curse, poison, disease, bleed), Naturalize
-- (Preservation magic), Overawe soothes, Fury of the Aspects
spec(1467, "EVOKER", "Devastation",  "dps",    "ranged", { curse = true, poison = true, disease = true, bleed = true, soothe = true, kick = true, lust = true,
	labels = { curse = "Cauterizing Flame", poison = "Cauterizing Flame", disease = "Cauterizing Flame", bleed = "Cauterizing Flame" } })
spec(1468, "EVOKER", "Preservation", "healer", "ranged", { magic = true, curse = true, poison = true, disease = true, bleed = true, soothe = true, lust = true,
	labels = { magic = "Naturalize", curse = "Cauterizing Flame", poison = "Cauterizing Flame", disease = "Cauterizing Flame", bleed = "Cauterizing Flame" } })
spec(1473, "EVOKER", "Augmentation", "dps",    "ranged", { curse = true, poison = true, disease = true, bleed = true, soothe = true, kick = true, lust = true,
	labels = { curse = "Cauterizing Flame", poison = "Cauterizing Flame", disease = "Cauterizing Flame", bleed = "Cauterizing Flame" } })

-- Class-wide fallback for a spec id we don't know (a new spec): role comes
-- from the API, range and tools from the class's most common row.
KN.CLASS_FALLBACK = {}
for _, row in pairs(C) do
	KN.CLASS_FALLBACK[row.class] = KN.CLASS_FALLBACK[row.class] or row
end
