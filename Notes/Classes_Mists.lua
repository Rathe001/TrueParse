-- What each spec can do ON MISTS OF PANDARIA CLASSIC, so notes are filtered
-- to the player's tools. Same shape as Notes/Classes.lua (retail), which is
-- the file to read for what every field means; this one exists because the
-- two clients' toolkits differ enough that sharing a table would route lines
-- to specs that cannot act on them - the exact failure `need` exists to
-- prevent (research/INVENTORY.md, prerequisite 8).
--
-- Spec ids are the same numbers on both clients (the spec system is MoP's),
-- so KN.CLASSES stays keyed by id. There is no Demon Hunter and no Evoker.
--
-- WHAT DIFFERS FROM RETAIL, and why (patch 5.4 / 5.5, checked against the
-- MoP spellbook 2026-09-08):
--   * Healers keep their interrupts. Rebuke is every Paladin's, Wind Shear
--     every Shaman's, Spear Hand Strike every Monk's; a Restoration Druid
--     shifts to cat for Skull Bash. Discipline and Holy Priests have none:
--     Silence is Shadow's. So "every healer" is really "every healer but
--     the Priests".
--   * Fear Ward EXISTS (removed in 7.0.3, alive here): every Priest carries
--     `fear`. Tremor Totem is baseline on every Shaman, not a choice node,
--     so no BUILD reminder is ever needed for it.
--   * Poison and disease cleansing is Paladin (Cleanse), Monk (Detox) and,
--     for poison only, Druid (Remove Corruption). Shamans lost poison and
--     disease cleansing in Cataclysm and do not have it here.
--   * Curses: Shaman (Cleanse Spirit / Purify Spirit), Mage (Remove Curse),
--     Druid (Remove Corruption / Nature's Cure).
--   * Magic on a friend: Holy Paladin (Sacred Cleansing), Discipline and
--     Holy Priest (Purify), every Priest through Mass Dispel, Restoration
--     Shaman (Purify Spirit), Warlock (the Imp's Singe Magic), Mistweaver
--     (Internal Medicine on Detox), Restoration Druid (Nature's Cure).
--   * Mass Dispel is baseline for all three Priest specs.
--   * Lust: Shamans, Mages (Time Warp), and ONLY Beast Mastery Hunters -
--     Ancient Hysteria is the Core Hound's, an exotic pet, and exotic pets
--     are Beast Mastery's alone. Netherwinds is a Warlords addition.
--   * Purge: Priest (Dispel Magic), Shaman (Purge), Mage (Spellsteal),
--     Warlock (Devour Magic), Hunter (Tranquilizing Shot, which also
--     soothes). Soothe: Hunter, Rogue (Shiv), Druid (Soothe).
--   * Hard CC for `stun`: the same rule as retail - a talent-gated tool
--     counts as available (Shockwave / Storm Bolt, Asphyxiate, Shadowfury,
--     Leg Sweep, Mighty Bash). Frost Mages have Deep Freeze; the other two
--     Mage specs have no stun. Disc Priests have none; Holy Word: Chastise
--     and Psychic Horror give Holy and Shadow one.
-- Josh: tell me which rows to double-check for the specs you play here.
local _, TP = ...
local KN = TP.Notes

local C = {}
KN.CLASSES = C

local function spec(id, class, name, role, range, caps)
	caps.class, caps.name, caps.role, caps.range, caps.id = class, name, role, range, id
	caps.labels = caps.labels or {}
	C[id] = caps
end

-- WARRIOR: Pummel; Shockwave / Storm Bolt; Berserker Rage is self-only so
-- it is not a `fear` answer for anybody else
spec(71,  "WARRIOR", "Arms",        "dps",  "melee",  { kick = true, stun = true })
spec(72,  "WARRIOR", "Fury",        "dps",  "melee",  { kick = true, stun = true })
spec(73,  "WARRIOR", "Protection",  "tank", "melee",  { kick = true, stun = true })

-- PALADIN: Cleanse is poison + disease for everyone; Holy's Sacred
-- Cleansing adds magic. Rebuke and Hammer of Justice on every spec.
spec(65,  "PALADIN", "Holy",        "healer", "melee", { magic = true, poison = true, disease = true, kick = true, stun = true,
	labels = { magic = "Cleanse", poison = "Cleanse", disease = "Cleanse" } })
spec(66,  "PALADIN", "Protection",  "tank", "melee",  { poison = true, disease = true, kick = true, stun = true,
	labels = { poison = "Cleanse", disease = "Cleanse" } })
spec(70,  "PALADIN", "Retribution", "dps",  "melee",  { poison = true, disease = true, kick = true, stun = true,
	labels = { poison = "Cleanse", disease = "Cleanse" } })

-- HUNTER: Tranquilizing Shot purges and soothes; Silencing Shot is a
-- talent (counts); Scatter Shot and traps for CC; lust is Beast Mastery's
-- Core Hound only
spec(253, "HUNTER", "Beast Mastery", "dps", "ranged", { purge = true, soothe = true, kick = true, stun = true, lust = true })
spec(254, "HUNTER", "Marksmanship",  "dps", "ranged", { purge = true, soothe = true, kick = true, stun = true })
spec(255, "HUNTER", "Survival",      "dps", "ranged", { purge = true, soothe = true, kick = true, stun = true })

-- ROGUE: Kick; Shiv strips an enrage; Kidney Shot
spec(259, "ROGUE", "Assassination", "dps", "melee", { soothe = true, kick = true, stun = true })
spec(260, "ROGUE", "Combat",        "dps", "melee", { soothe = true, kick = true, stun = true })
spec(261, "ROGUE", "Subtlety",      "dps", "melee", { soothe = true, kick = true, stun = true })

-- PRIEST: Purify (magic + disease) for the healers; Mass Dispel, Dispel
-- Magic and Fear Ward on all three; Silence is Shadow's only interrupt, so
-- the two healing specs have none
spec(256, "PRIEST", "Discipline", "healer", "ranged", { magic = true, disease = true, purge = true, massdispel = true, fear = true,
	labels = { magic = "Purify", disease = "Purify" } })
spec(257, "PRIEST", "Holy",       "healer", "ranged", { magic = true, disease = true, purge = true, stun = true, massdispel = true, fear = true,
	labels = { magic = "Purify", disease = "Purify" } })
spec(258, "PRIEST", "Shadow",     "dps",    "ranged", { magic = true, purge = true, kick = true, stun = true, massdispel = true, fear = true,
	labels = { magic = "Mass Dispel" } })

-- DEATH KNIGHT: Mind Freeze; Asphyxiate (talent) and the ghoul's Gnaw
spec(250, "DEATHKNIGHT", "Blood",  "tank", "melee", { kick = true, stun = true })
spec(251, "DEATHKNIGHT", "Frost",  "dps",  "melee", { kick = true, stun = true })
spec(252, "DEATHKNIGHT", "Unholy", "dps",  "melee", { kick = true, stun = true })

-- SHAMAN: Cleanse Spirit (curse) on all, Purify Spirit (curse + magic) for
-- Restoration; Purge, Wind Shear, Capacitor Totem, Bloodlust / Heroism and
-- Tremor Totem on every spec. No poison here, unlike retail.
spec(262, "SHAMAN", "Elemental",   "dps",    "ranged", { curse = true, purge = true, kick = true, stun = true, lust = true, fear = true,
	labels = { curse = "Cleanse Spirit" } })
spec(263, "SHAMAN", "Enhancement", "dps",    "melee",  { curse = true, purge = true, kick = true, stun = true, lust = true, fear = true,
	labels = { curse = "Cleanse Spirit" } })
spec(264, "SHAMAN", "Restoration", "healer", "ranged", { magic = true, curse = true, purge = true, kick = true, stun = true, lust = true, fear = true,
	labels = { magic = "Purify Spirit", curse = "Purify Spirit" } })

-- MAGE: Remove Curse, Spellsteal, Counterspell, Time Warp; Deep Freeze is
-- Frost's alone
spec(62, "MAGE", "Arcane", "dps", "ranged", { curse = true, purge = true, kick = true, lust = true, labels = { curse = "Remove Curse" } })
spec(63, "MAGE", "Fire",   "dps", "ranged", { curse = true, purge = true, kick = true, lust = true, labels = { curse = "Remove Curse" } })
spec(64, "MAGE", "Frost",  "dps", "ranged", { curse = true, purge = true, kick = true, stun = true, lust = true, labels = { curse = "Remove Curse" } })

-- WARLOCK: the Imp's Singe Magic, the Felhunter's Devour Magic and Spell
-- Lock, Shadowfury (talent)
spec(265, "WARLOCK", "Affliction",  "dps", "ranged", { magic = true, purge = true, kick = true, stun = true, labels = { magic = "Singe Magic" } })
spec(266, "WARLOCK", "Demonology",  "dps", "ranged", { magic = true, purge = true, kick = true, stun = true, labels = { magic = "Singe Magic" } })
spec(267, "WARLOCK", "Destruction", "dps", "ranged", { magic = true, purge = true, kick = true, stun = true, labels = { magic = "Singe Magic" } })

-- MONK: Detox (poison + disease; Mistweaver's Internal Medicine adds magic),
-- Spear Hand Strike on every spec, Leg Sweep / Paralysis
spec(268, "MONK", "Brewmaster", "tank",   "melee", { poison = true, disease = true, kick = true, stun = true,
	labels = { poison = "Detox", disease = "Detox" } })
spec(270, "MONK", "Mistweaver", "healer", "melee", { magic = true, poison = true, disease = true, kick = true, stun = true,
	labels = { magic = "Detox", poison = "Detox", disease = "Detox" } })
spec(269, "MONK", "Windwalker", "dps",    "melee", { poison = true, disease = true, kick = true, stun = true,
	labels = { poison = "Detox", disease = "Detox" } })

-- DRUID: Remove Corruption (curse + poison), Nature's Cure adds magic for
-- Restoration; Soothe on all; Solar Beam for Balance, Skull Bash for the
-- forms (Restoration shifts to cat for it); Mighty Bash (talent) and Maim
spec(102, "DRUID", "Balance",     "dps",    "ranged", { curse = true, poison = true, soothe = true, kick = true, stun = true,
	labels = { curse = "Remove Corruption", poison = "Remove Corruption" } })
spec(103, "DRUID", "Feral",       "dps",    "melee",  { curse = true, poison = true, soothe = true, kick = true, stun = true,
	labels = { curse = "Remove Corruption", poison = "Remove Corruption" } })
spec(104, "DRUID", "Guardian",    "tank",   "melee",  { curse = true, poison = true, soothe = true, kick = true, stun = true,
	labels = { curse = "Remove Corruption", poison = "Remove Corruption" } })
spec(105, "DRUID", "Restoration", "healer", "ranged", { magic = true, curse = true, poison = true, soothe = true, kick = true, stun = true,
	labels = { magic = "Nature's Cure", curse = "Nature's Cure", poison = "Nature's Cure" } })

-- Class-wide fallback for a spec id we don't know: role comes from the API,
-- range and tools from the class's most common row.
KN.CLASS_FALLBACK = {}
for _, row in pairs(C) do
	KN.CLASS_FALLBACK[row.class] = KN.CLASS_FALLBACK[row.class] or row
end
