-- Midnight Season 2 dungeon pool, and the season's raid at the end. Written once, per ROLE, in class-neutral
-- words; the addon filters every line to the reader's role and tools.
--
-- Shape:
--   name      journal instance name (English)
--   bosses    ordered as the journal lists them.
--               core   ONE TO THREE lines the GROUP executes; never filtered
--               notes  per-role lines. Fields: text, tag (or list of
--                      alternatives), role = tank | healer | dps | melee |
--                      ranged | nil(all), need = capability or list
--                      (magic curse poison disease bleed purge soothe kick
--                      stun lust), affix = show only on that week
--                      (Tyrannical | Fortified | Devour ...), class = show
--                      only to that class, ability (journal title, gates by
--                      difficulty), min (n h m k)
--               uses   what a kind of tool is FOR here, per kind (stun, kick,
--                      dispel, purge, soothe, utility): the ranked-run data
--                      then says "Capacitor Totem works well on Mirror
--                      Images" for every spec with a stun
--               units  (raids) the names you target for a boss whose
--                      encounter is named for something else: a council
--   trash     { name=, text=, tag=, role=, need=, affix=, class=, leg=, min= }
--             leg 1 = before boss 1; no leg = every stretch. An entry with
--             no `name` is a stretch-level line (the lust call, a talent
--             reminder, a TASK) and renders as a note, not a mob row.
--             TASK = a non-combat gate or pickup: what must be clicked,
--             gathered, chosen or talked to before the next boss, and the
--             class- or profession-gated buffs people don't know they can
--             take. Shown to everyone.
--
-- Nothing is dungeon-wide any more (Josh, round 3): the lust call lives on
-- the boss or the pack it belongs to, conditional on the week; dispel lines
-- live on the boss or mob that applies them; talent reminders sit on the
-- first stretch.
--
-- ESSENTIAL ONLY: a line earns its place if missing it wipes or kills, and
-- the telegraph does not tell you what to do. Sources: Method and Icy Veins,
-- Sept 2026, reconciled; where they disagreed the line was dropped (Fertile
-- Loam). Galvazzt spires: DPS soak them (Josh, 2026-09-08).
local _, TP = ...
local KN = TP.Notes

KN.RegisterDungeon({
	name = "Ruby Life Pools",
	bosses = {
		{ name = "Melidrussa Chillworn",
			core = {
				"Stack so Hailburst ice lands in one spot, rotate the room as it fills",
				"Chillstorm target runs out before it lands, away from the ice",
			},
			notes = {
				{ tag = "LUST", need = "lust", affix = "Tyrannical", text = "on the whelps at 66%", ability = "Awaken Whelps" },
				{ tag = "CD", role = "healer", text = "Frost Overload after the shield at 66 and 33", ability = "Frost Overload" },
				{ tag = "MAGIC", need = "magic", text = "Primal Chill off the tank at 4 stacks, 5 freezes them", ability = "Primal Chill" },
				{ tag = "TANK", role = "tank", text = "Pick up the Infused Whelps at 66 and 33; defensive for Crushing Smash", ability = "Awaken Whelps" },
			} },
		{ name = "Kokia Blazehoof",
			core = {
				"Kill the Blazebound Firestorm from Ritual of Blazebinding, kick Roaring Blaze, leave Burnout when it dies",
				"Sidestep Molten Boulder, it stuns",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Inferno from the add, which grows the longer it lives", ability = "Inferno" },
				{ tag = "TANK", role = "tank", text = "Defensive for every Searing Blows; pick up the Firestorm", ability = "Searing Blows" },
			} },
		{ name = "Kyrakka and Erkhart Stormvein",
			core = {
				"Read Winds of Change, drop fire puddles downwind of the group",
				"Spread for Inferno Spit: two targets in P1, three in P2",
				"Stop casting before Interrupting Cloudburst lands",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "in phase 2, when Erkhart mounts", ability = "Inferno Spit" },
				{ tag = "MAGIC", need = "magic", text = "Stormslam off the tank before the next cast, it doubles nature damage", ability = "Stormslam" },
				{ tag = "CD", role = "healer", text = "P2 Inferno Spit", ability = "Inferno Spit" },
				{ tag = "TANK", role = "tank", text = "Undispelled Stormslam stacks: call for the dispel", ability = "Stormslam" },
			} },
	},
	trash = {
		{ tag = "LUST", need = "lust", affix = "Fortified", text = "the first big pull", leg = 1 },
		{ tag = "BUILD", class = "SHAMAN", min = "k", text = "no poison here: swap Poison Cleansing Totem out", leg = 1 },
		{ name = "Chillweaver", tag = "PURGE", need = "purge", text = "Purge Ice Shield, it keeps the pack alive", leg = 1 },
		{ name = "Flamedancer", tag = "STUN", need = "stun", text = "Flame Dance can't be kicked: hard CC it", leg = 1 },
		{ name = "Primal Thundercloud", tag = "PURGE", need = "purge", text = "Purge its shield" },
		{ name = "Flamegullet", tag = "CD", role = "healer", text = "the enrage under 50%: party damage climbs fast", leg = 2 },
		{ name = "Flamegullet", tag = "TANK", role = "tank", text = "Fire Maw: defensive, it leaves a DoT", leg = 2 },
		{ name = "Thunderhead", tag = "MAGIC", need = "magic", text = "Dispel Rolling Thunder one player at a time, it spreads", leg = 3 },
		{ name = "Thunderhead", tag = "TANK", role = "tank", text = "Thunder Jaw: defensive", leg = 3 },
		{ name = "Defier Draghar", tag = "TANK", role = "tank", text = "Steel Barrage: defensive or external" },
	},
})

KN.RegisterDungeon({
	name = "Den of Nalorakk",
	bosses = {
		{ name = "The Hoardmonger",
			core = {
				"Soak every mushroom from Spoiled Supplies within 12s or it detonates on the group",
				"At 90/70/40 he empowers from the nearest pile: steer him, meat first, bone second, mushrooms last",
			},
			notes = {
				{ tag = "POISON", need = "poison", text = "Toxic Spores on the soakers", ability = "Toxic Spores" },
				{ tag = "CD", role = "healer", text = "Ravenous Bellow", ability = "Ravenous Bellow" },
				{ tag = "TANK", role = "tank", text = "Soak mushrooms too; the meat-pile Bellow knocks back", ability = "Spoiled Supplies" },
			} },
		{ name = "Sentinel of Winter",
			core = {
				"Stack to bait Raging Squall tornadoes into one spot, then rotate the room",
				"Kill the Fractured Shivercores, kick Winter's Shroud, one soaker per Rimeshatter",
			},
			notes = {
				{ tag = "LUST", need = "lust", affix = "Fortified", text = "when the Shivercores spawn", ability = "Shattering Frostspike" },
				{ tag = "MAGIC", need = "magic", text = "Glacial Torment off immediately", ability = "Glacial Torment" },
				{ tag = "CD", role = "healer", text = "Frozen Tempest channel", ability = "Frozen Tempest" },
				{ tag = "TANK", role = "tank", text = "Drag the boss to each Shivercore so it dies to cleave", ability = "Shattering Frostspike" },
				{ role = "ranged", text = "Ranged take the Rimeshatter soaks", ability = "Rimeshatter" },
			} },
		{ name = "Nalorakk",
			core = {
				"Drop Echoing Maul echoes in one corner, don't cleave",
				"Overwhelming Onslaught: behind Zul'jarra's shield, soak Forceful Slam",
				"Fury of the War God: wall up around Zul'jarra so no bear-shade reaches her",
			},
			notes = {
				{ tag = "LUST", need = "lust", affix = "Tyrannical", text = "on pull" },
				{ tag = "CD", role = "healer", text = "Three Onslaught hits, major on the third", ability = "Overwhelming Onslaught" },
				{ tag = "TANK", role = "tank", text = "Soak Forceful Slam right after Onslaught", ability = "Forceful Slam" },
			} },
	},
	trash = {
		{ tag = "TASK", progress = "Offering", text = "Gather offerings (berries, fishing spots, apple barrels) to summon the boss", leg = 1 },
		{ tag = "TASK", text = "Optional: Warding Incense (bear form or Alchemy 25), +5% versatility for 10 min", leg = 1 },
		{ tag = "TASK", text = "Optional: Snowworn Provisions mid-gauntlet, right side (Night Elf, Troll or bear form), halves knockbacks for 15 min", leg = 2 },
		{ name = "Earthwhisper Tender", tag = { "KICK", "PURGE" }, need = { "kick", "purge" }, text = "Kick or purge Healing Breeze, every cast" },
		{ name = "Spirit of Hunger", text = "Kill the Starvation Effigy totem it drops" },
		{ name = "Mauler / Mystic", tag = "KICK", need = "kick", text = "Kick Arc Lightning, never let one through" },
		{ name = "Loa Speaker Nanea", text = "Kill the Volatile Totems", leg = 3 },
		{ name = "Troll casters", tag = "CURSE", need = "curse", text = "Dispel their curses", leg = 3 },
		{ name = "Bonded Beasttamer", tag = "SOOTHE", need = "soothe", text = "Soothe Bestial Wrath" },
		{ name = "Territorial Matriarch", tag = "SOOTHE", need = "soothe", text = "Soothe Mother's Wrath" },
	},
})

KN.RegisterDungeon({
	name = "Murder Row",
	bosses = {
		{ name = "Kystia Manaheart",
			uses = { stun = "Mirror Images", dispel = "Envenom" },
			core = {
				"Kill Nibbles to 20%, not the shielded boss",
				"Kick or CC the five Mirror Images",
				"Out of Fel Spray",
			},
			notes = {
				{ tag = "MAGIC", need = "magic", text = "Corroding Spittle off immediately", ability = "Corroding Spittle" },
				{ tag = "CD", role = "healer", text = "Every Chaotic Burst phase", ability = "Chaotic Burst" },
				{ tag = "TANK", role = "tank", text = "Defensive for Envenom; keep Nibbles on the boss for cleave", ability = "Envenom" },
			} },
		{ name = "Zaen Bladesorrow",
			core = {
				"Fire Bomb circle: carry it into a Volatile Barrel to blow it up, or Fel-Infused Freight stacks on the group",
				"Murder in a Row: hide behind a Forbidden Freight barrel before it finishes",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Killing Spree, worse with Fel-Infused Freight stacked", ability = "Killing Spree" },
				{ tag = "POISON", need = "poison", text = "Envenom off the tank before Heartstop Poison lands", ability = "Envenom" },
				{ tag = "TANK", role = "tank", text = "Defensive for Envenom then Heartstop Poison; get Envenom off you fast", ability = "Envenom" },
			} },
		{ name = "Xathuux the Annihilator",
			core = {
				"Axe Toss: kill the Axe fast, Fel Lightning stacks while it lives",
				"Demonic Rage: kite him along the edge, out of Burning Steps",
				"Loose spread for Infernal Crush",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Infernal Crush landing on top of Demonic Rage", ability = "Infernal Crush" },
				{ tag = "TANK", role = "tank", text = "Legion Strike: defensive; hold him at the edge facing out", ability = "Legion Strike" },
				{ role = "ranged", text = "Drop the Axe next to the boss so melee cleave it", ability = "Axe Toss" },
			} },
		{ name = "Lithiel Cinderfury",
			uses = { stun = "the Wild Imps" },
			core = {
				"Kick rotation on Chaos Bolt",
				"Kill the Furious Vilefiend on spawn; CC the Wild Imps in Fingers of Gul'dan",
				"Malefic Wave: cleave the adds before it reaches them, then Demonic Gateway to the safe side",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "on pull, hardest boss in the dungeon" },
				{ tag = "CD", role = "healer", text = "Searing Fel Flame, a rot all fight: rolling, not burst", ability = "Searing Fel Flame" },
				{ tag = "TANK", role = "tank", text = "The Infernal can't die and kills on contact: keep the boss away from it; pick up the Vilefiend", ability = "Summon Vilefiend" },
			} },
	},
	trash = {
		{ tag = "TASK", progress = "Snitch", text = "Interrogate Silvermoon Snitches to unlock the boss", leg = 1 },
		{ tag = "TASK", text = "The bar: everyone talks to Selenar Sunshy and works their job to five stars, +10% damage and healing for 5 min", leg = 2 },
		{ tag = "BUILD", class = "SHAMAN", min = "k", text = "Improved Purify Spirit for Curse of Doom", leg = 1 },
		{ name = "Massive Felwyrm", text = "Explodes on death, kill it away from the group", leg = 1 },
		{ name = "Shivan Punisher", tag = "CD", role = "healer", text = "the enrage at 50%", leg = 3 },
		{ name = "Corrupted Warlock", tag = { "KICK", "CURSE" }, need = { "kick", "curse" }, text = "Kick Curse of Doom, or dispel it the moment it lands" },
	},
})

KN.RegisterDungeon({
	name = "Voidscar Arena",
	bosses = {
		{ name = "Taz'Rah",
			core = {
				"Nether Dash lines: stay close so the Umbral Rupture puddles clump, rotate along the wall",
				"Dodge every Dark Bloom orb",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "each Umbral Rupture: top everyone before it", ability = "Umbral Rupture" },
				{ tag = "TANK", role = "tank", text = "Void Blast knocks you back: defensive, and don't land in a puddle", ability = "Void Blast" },
			} },
		{ name = "Atroxus",
			core = {
				"Monstrous Roar spawns a Toxic Creeper: kill it at once, its Toxic Aura is a wipe",
				"Out of the Poison Pools, sidestep Noxious Breath",
			},
			notes = {
				{ tag = "LUST", need = "lust", affix = "Tyrannical", text = "on the first Creeper", ability = "Toxic Creeper" },
				{ tag = "CD", role = "healer", text = "Every Creeper", ability = "Toxic Creeper" },
				{ tag = "POISON", need = "poison", text = "Mind-Numbing Poison, it feeds Hulking Claw on the tank", ability = "Mind-Numbing Poison" },
				{ tag = "TANK", role = "tank", text = "The Creeper fixates you and every hit stacks Sickening Bite: kite it; defensive for Hulking Claw", ability = "Hulking Claw" },
			} },
		{ name = "Charonus",
			core = {
				"Gravitic Orb carriers run their orb into an Unstable Singularity star, fast: Condensed Mass stacks",
				"Nobody else touches a star: Atomized",
				"Spread for Cosmic Crash",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Orb carriers, slow ones first, while the stars pulse", ability = "Gravitic Orb" },
				{ tag = "TANK", role = "tank", text = "Dark Waves frontal: defensive; hold him in the middle of the three stars", ability = "Dark Waves" },
				{ role = "dps", text = "Stand near a star before Gravitic Orbs go out to shorten the run", ability = "Gravitic Orb" },
			} },
	},
	trash = {
		{ tag = "TASK", text = "Pick a path: left is Aegyra, fewer kicks, Proof of Endurance; right is Raj'kess, more shamans, Proof of Mastery. Buffs last 30 min", leg = 1 },
		{ tag = "TASK", progress = "Brutalizer", text = "Kill the Devouring Brutalizers to open the arena", leg = 3 },
		{ tag = "LUST", need = "lust", affix = "Fortified", text = "the opening pack", leg = 1 },
		{ name = "Devouring Brutalizer", text = "Devours low-health mobs to grow: don't leave things at 10%" },
		{ name = "Harrower (left)", text = "Sky Strike is a stack-to-split, not a spread", leg = 2 },
		{ name = "Enthralled Shaman", text = "Kill the Magma Totem on spawn" },
		{ name = "Kilivore Screamer", tag = "KICK", need = "kick", text = "Kick Demoralizing Shout" },
		{ name = "Agitated Voidscythe", tag = "POISON", need = "poison", text = "Dispel Corrosive Essence" },
	},
})

KN.RegisterDungeon({
	name = "The Blinding Vale",
	bosses = {
		{ name = "Lightblossom Trinity",
			core = {
				"Soak the Lightblossoms during Lightblossom Beam, spread so Light-Gorged doesn't stack on one person",
				"Kick Light Bolt",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Bedrock Slam", ability = "Bedrock Slam" },
				{ tag = "TANK", role = "tank", text = "Bedrock Slam: defensive; keep the three stacked for cleave", ability = "Bedrock Slam" },
				{ role = "melee", text = "Thornblade target: step out of melee, come back when Lekshi jumps to you", ability = "Thornblade" },
			} },
		{ name = "Ikuzz the Light Hunter",
			core = {
				"Don't touch Bloodthorn Roots; the Bloodthirsty Gaze target kites him over them to destroy them",
				"Lightcrazed Frenzy at 50% is the fight",
			},
			notes = {
				{ tag = "LUST", need = "lust", affix = "Tyrannical", text = "at 50%, for the frenzy", ability = "Lightcrazed Frenzy" },
				{ tag = "CD", role = "healer", text = "Thorncaller Roar pulses: hold majors for the frenzy", ability = "Thorncaller Roar" },
				{ tag = "TANK", role = "tank", text = "Hold him next to rooted players so cleave clears the roots", ability = "Bloodthorn Roots" },
			} },
		{ name = "Lightwarden Ruia",
			core = {
				"Kick Warden's Wrath, out of Lightfall",
				"Bear at 70%: tank bleeds · Haranir at 40%: 8s ability cycle",
			},
			notes = {
				{ role = "healer", text = "Healing the target to full clears Grievous Thrash", ability = "Grievous Thrash" },
				{ tag = "CD", role = "healer", text = "Lightfire explosions", ability = "Lightfire" },
				{ tag = "TANK", role = "tank", text = "Bear form hits harder (Mangling Claws); Grievous Thrash stacks until you are full", ability = "Grievous Thrash" },
				{ role = "melee", text = "Spread for Pulverizing Strikes, a cone on several of you", ability = "Pulverizing Strikes" },
			} },
		{ name = "Ziekket",
			core = {
				"Kill the lashers from Awaken the Lightbloom fast",
				"Aim Concentrated Lightbeam over their bodies or they come back",
				"Soak Lightbloom's Essence orbs before they reach him",
			},
			notes = {
				{ tag = "LUST", need = "lust", affix = "Fortified", text = "in the first add phase", ability = "Awaken the Lightbloom" },
				{ tag = "CD", role = "healer", text = "the add phase, where Oozing Xylem rot peaks; watch high Essence stacks", ability = "Oozing Xylem" },
				{ tag = "TANK", role = "tank", text = "Thornspike: defensive; group the lashers", ability = "Thornspike" },
			} },
	},
	trash = {
		{ tag = "TASK", text = "Optional: left path, Light-Starved Blossom (Paladin, Priest or Herbalism 25) for 20% speed and 5% haste, 2 min; right path, Hunters and Druids free the Baby Grovecrawler", leg = 1 },
		{ tag = "TASK", text = "After Ikuzz, talk to the bird to fly down", leg = 3 },
		{ name = "Sporeblight Belcher", text = "Explodes on death", leg = 2 },
		{ name = "Potatoad Matriarch", tag = "POISON", need = "poison", text = "Dispel Toxic Spew, it hits everyone", leg = 3 },
		{ name = "Radiant Spellsower", tag = "KICK", need = "kick", text = "Kick Light Bolt Volley, it wakes the dormant adds" },
	},
})

KN.RegisterDungeon({
	name = "Temple of Sethraliss",
	bosses = {
		{ name = "Adderis and Aspix",
			core = {
				"Storm Blessed immunity starts on Aspix and swaps at 40%: swap targets with it",
				"Gale Force knocks you back, then stack for the Thunder and Lightning soak",
				"Tempest Winds targets away from the group",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "the moment after the soak", ability = "Thunder and Lightning" },
				{ tag = "TANK", role = "tank", text = "Overload: defensive every cast", ability = "Overload" },
			} },
		{ name = "Merektha",
			uses = { stun = "the snakes" },
			core = {
				"A Knot of Snakes: dispel it if you can, else stack in melee and cleave the snakes",
				"Burrow: kick Poison Spit on the adds and kill them first; don't get knocked into Lingering Storm",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Serpentstorm", ability = "Serpentstorm" },
				{ tag = "POISON", need = "poison", text = "DoTs all fight" },
				{ tag = "TANK", role = "tank", text = "Lightning Bite: defensive; stack the snakes on the boss", ability = "Lightning Bite" },
				{ role = "melee", text = "Stay in for Knot of Snakes so one AoE CC catches both", ability = "A Knot of Snakes" },
			} },
		{ name = "Galvazzt",
			core = {
				"A DPS stands between each Lightning Spire and the boss, or he gains energy",
				"Full energy = Consume Charge = wipe",
				"Kite him out of the Induction fields",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "on pull, an energy race" },
				{ tag = "CD", role = "healer", text = "each Induction: soakers stack Galvanized, top everyone before it", ability = "Galvanized" },
				{ tag = "TANK", role = "tank", text = "Place him so the DPS can reach the spires; you don't soak", ability = "Lightning Spire" },
				{ role = "dps", text = "The spires are yours: rotate soakers, Galvanized stacks", ability = "Lightning Spire" },
			} },
		{ name = "Avatar of Sethraliss",
			uses = { stun = "the Tormentor wave" },
			core = {
				"Corrupted Guardian, then grab every Corrupted Lifeforce orb within 6s",
				"Essence Defiler first when it is up: it blocks healing on the Avatar",
				"CC and cleave the Tormentor wave, each one heals him",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Caustic Stomp DoT", ability = "Caustic Stomp" },
				{ role = "healer", text = "Latent Hex expiring drops Hex Muck: move", ability = "Latent Hex" },
				{ tag = "TANK", role = "tank", text = "Threat on the Corrupted Guardian instantly; defensive for Tainted Strike and Vile Charge", ability = "Tainted Strike" },
				{ role = "ranged", text = "Kite the Tormentors while the healer heals the Avatar", ability = "Faithless Tormentor" },
			} },
	},
	trash = {
		{ tag = "TASK", text = "Spark gauntlet: walk the spiral between the sparks; killing Spark Channelers thins them", leg = 3 },
		{ tag = "TASK", text = "Second gauntlet, then energize both Eyes: click one, stand in the damage until the bar fills, kill what spawns, repeat. The skull door opens to the boss", leg = 4 },
		{ tag = "BUILD", class = "SHAMAN", min = "k", text = "Poison Cleansing Totem, and Improved Purify Spirit for Addle Mind", leg = 1 },
		{ name = "Imbued Stormcaller", tag = "MAGIC", need = "magic", text = "Dispel every Imbued Conduction, it stuns when it expires" },
		{ name = "Poisonous Viper", tag = "POISON", need = "poison", text = "Dispel Cytotoxin" },
		{ name = "Faithless Subjugator", tag = { "KICK", "CURSE" }, need = { "kick", "curse" }, text = "Kick Addle Mind, or dispel it" },
	},
})

KN.RegisterDungeon({
	name = "Kings' Rest",
	bosses = {
		{ name = "The Golden Serpent",
			core = {
				"Kill every Animated Gold during Lucre's Call or he shields",
				"Spit Gold targets drop it away from him",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Every Serpentine Gust channel", ability = "Serpentine Gust" },
				{ tag = "TANK", role = "tank", text = "Tail Thrash: defensive; keep him away from the gold", ability = "Tail Thrash" },
			} },
		{ name = "Mchimba the Embalmer",
			core = {
				"Entomb: the entombed player mashes the button, everyone else shakes the right sarcophagus",
				"Kick Wretched Discharge, always",
				"Drain Fluids target: heal them above 90% to clear it",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Awakening Slam", ability = "Awakening Slam" },
				{ tag = "TANK", role = "tank", text = "Stack the mummies on the boss for cleave", ability = "Awakening Slam" },
				{ role = "ranged", text = "Burn Corruption: drop the fire away from the sarcophagi", ability = "Burn Corruption" },
			} },
		{ name = "The Council of Tribes",
			core = {
				"Call of the Elements: kill the Explosive Totem before it finishes; Healing Tide Totem on spawn",
				"Kick Poison Nova",
				"Whirling Axes adds patrol: stay out of them",
			},
			notes = {
				{ tag = "LUST", need = "lust", affix = "Tyrannical", text = "when Zanazal steps in" },
				{ tag = "CD", role = "healer", text = "Arc Lightning, which cleaves off the tank and hits hard", ability = "Arc Lightning" },
				{ tag = "TANK", role = "tank", text = "Debilitating Backhand: kite, stay out of melee until it drops; park Zanazal by his totems", ability = "Debilitating Backhand" },
			} },
		{ name = "Dazar, the First King",
			core = {
				"Kill Reban before the 80% mount",
				"Spread for Aerial Smash / Quaking Leap; out of Hunting Leap and Impaling Spear",
				"Kick Deathly Roar",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Gilded Destruction, the biggest hit of the dungeon", ability = "Gilded Destruction" },
				{ tag = "TANK", role = "tank", text = "Blade Combo: defensive; Savage Maul on top of it wants an external", ability = "Blade Combo" },
			} },
	},
	trash = {
		{ tag = "BUILD", class = "SHAMAN", min = "k", text = "Improved Purify Spirit for Hex; Poison Cleansing Totem for Serpent Strike", leg = 1 },
		{ tag = "LUST", need = "lust", affix = "Fortified", text = "the double pack in the Hall of Kings", leg = 2 },
		{ name = "Risen Hexer", tag = { "KICK", "MAGIC" }, need = { "kick", "magic" }, text = "Kick Hex Volley, it hits the whole party; dispel Shadowfrost Bolt", leg = 1 },
		{ name = "Phantom Hex Priest", tag = "CURSE", need = "curse", text = "Dispel Hex", leg = 2 },
		{ name = "Queen Patlaa", tag = "POISON", need = "poison", text = "Dispel Serpent Strike", leg = 2 },
		{ name = "Spectral Shaman", text = "Kill its Healing Tide Totem on spawn" },
		{ name = "Seneschal M'bara", tag = { "KICK", "PURGE" }, need = { "kick", "purge" }, text = "Kick Unholy Mending; purge what lands" },
		{ name = "Half-Finished Mummy", tag = "KICK", need = "kick", text = "Kick Wretched Discharge, every cast" },
		{ name = "Ghostly Brute", text = "Seismic Upheaval: move the moment it starts" },
	},
})

KN.RegisterDungeon({
	name = "Altar of Fangs",
	bosses = {
		{ name = "Rav'i",
			core = {
				"Ssscavenging: everyone into the Messy Eater soaks to break the shield, or Carrion Burst wipes",
				"Drag him to the Bone Pile without a Twinfang corpse first, no Scent of Blood",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Ravenous Stomp", ability = "Ravenous Stomp" },
				{ tag = "CD", role = "healer", text = "The whole Ssscavenging window until the shield breaks", ability = "Ssscavenging" },
				{ tag = "TANK", role = "tank", text = "Hydrastrike: defensive; move him off Fresh Meat corpses", ability = "Hydrastrike" },
			} },
		{ name = "The Writhing Coil",
			uses = { stun = "the Uncoiled Writhes" },
			core = {
				"Kick all three Toxic Barrage casts",
				"Death Rattle: tethered players run to snap the Vine Grip",
				"Uncoiled Writhes: their leftover health goes back on the boss, burn them",
			},
			notes = {
				{ role = "healer", text = "Synchronized Venom rots all fight: rolling heals", ability = "Synchronized Venom" },
				{ tag = "TANK", role = "tank", text = "Tail Scythe and Corrosive Fangs: defensive; stack the Writhes", ability = "Tail Scythe" },
				{ role = "melee", need = "stun", text = "CC the Writhes or they put Spiteful Venom on you", ability = "Spiteful Venom" },
			} },
		{ name = "Zul'jan",
			core = {
				"Soak all four Ritual of the Fang beams",
				"Clear Ritual Venom stacks in Boneslicer or Axegrinder before they kill you; out of the Bloodletting pools",
			},
			notes = {
				{ tag = "LUST", need = "lust", affix = "Tyrannical", text = "on pull" },
				{ tag = "CD", role = "healer", text = "Every beam channel", ability = "Ritual of the Fang" },
				{ tag = "TANK", role = "tank", text = "Chop Down: defensive, worse while you hold Ritual Venom", ability = "Chop Down" },
			} },
	},
	trash = {
		{ tag = "TASK", progress = "Caustic", text = "Destroy the Caustic Mist Totems at the start to open the way", leg = 1 },
		{ tag = "TASK", progress = "Infusion", text = "Destroy the Infusion Totems in the mist wall, then kill the Ascendant Serpent", leg = 3 },
		{ tag = "TASK", text = "Optional: Unfinished Mixture near Zul'jan (Cooking or Alchemy 25) gives Mutating Elixir for the run", leg = 3 },
		{ tag = "LUST", need = "lust", affix = "Fortified", text = "the Ritual Chieftain pack", leg = 1 },
		{ tag = "BUILD", class = "SHAMAN", min = "k", text = "Poison Cleansing Totem for Envenom and Mass Envenom", leg = 1 },
		{ name = "Ritual Chieftain", tag = "KICK", need = "kick", text = "Kick Blood Sacrifice, it puts a heal absorb on everyone", leg = 1 },
		{ name = "Ula'tek's Chosen", tag = { "KICK", "POISON" }, need = { "kick", "poison" }, text = "Kick Mass Envenom, every cast; dispel what lands" },
		{ name = "High Evolutionist", tag = { "STUN", "POISON" }, need = { "stun", "poison" }, text = "Hard CC Evolve, it can't be kicked and becomes Mass Envenom; dispel Envenom" },
		{ name = "Living Venom", text = "Explodes on death: stagger the kills" },
		{ name = "Twinfang Harrower", tag = "TANK", role = "tank", text = "Duostrike: defensive" },
		{ name = "Ravenous Descendant", tag = "SOOTHE", need = "soothe", text = "Soothe Ravenous" },
	},
})

---------------------------------------------------------------------------
-- The season's raid (boss-only: RegisterRaid refuses a trash table). Its two
-- wings clear in either order, so it does not declare `linear`: the view
-- lists the bosses and switches to one when its encounter starts. Sources:
-- Method and MythicTrap per-boss guides, 2026-09-08, reconciled in
-- research/instances/retail-the-venomous-abyss.md; lines the two disagree
-- on are left out. Nymrissa Wavecaller is not here: she is alone in The
-- Tidebound Grotto, registered below. Bosses in journal order.
---------------------------------------------------------------------------
KN.RegisterRaid({
	name = "The Venomous Abyss",
	bosses = {
		{ name = "Nek'zali the Soulcoiler",
			core = {
				"Break the shields on the Restless Amani and kill them before they reach the Well",
				"Essence Rend: get dispelled at the edge; the puddle stays where it drops",
				"At 50% burn the corpses with Hungering Pyre, then kill both Echoes of Jawae",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "in phase 2, before the energy caps", ability = "Uncoiling" },
				{ tag = "MAGIC", need = "magic", text = "Essence Rend, and only at the edge", ability = "Essence Rend" },
				{ tag = "TANK", role = "tank", text = "Hollowing Strikes: swap around 5-6 stacks and let it expire; stay 30 yards out for Possession Barrage", ability = "Hollowing Strikes" },
				{ tag = "CD", role = "healer", text = "Soulcoil Ignition, and the Uncoiling rot all through phase 2", ability = "Soulcoil Ignition" },
				{ text = "Stand behind the boss for Possession Barrage", ability = "Possession Barrage" },
			} },
		{ name = "Entombed Sentinels",
			units = { "Breath of Ula'tek", "Blood of Ula'tek" },
			core = {
				"Keep the two golems 40 yards apart or they take 99% less damage",
				"Unstable Miasma: everyone soaks it, it splits",
				"Intermission: pair up so your two stack counts add to exactly 4",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "on the pull, there is no burn phase" },
				{ tag = "MAGIC", need = "magic", text = "Blighted Blood, once they are at the edge", ability = "Blighted Blood" },
				{ tag = "TANK", role = "tank", text = "Swap after each Empowering Slam and each Bloodvenom Injection, not just at the intermission: repeated hits keep ramping", ability = "Empowering Slam" },
				{ tag = "CD", role = "healer", text = "Venom Coagulation, and the Unstable Miasma soak", ability = "Venom Coagulation" },
				{ text = "Run over the Toxic Droplets before they go off", ability = "Toxic Droplets" },
			} },
		{ name = "The Lost Explorers",
			units = { "Gebbo", "Nama", "Iku" },
			core = {
				"United Defense: never let all three sit within 30 yards, or they take 99% less damage",
				"Break the boxes and feed the Disgusting Fish to stop Final Ascension",
				"Frostfire Volley: clear fire in the frost patch and frost in the fire patch, or the raid explodes",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "on the pull" },
				{ tag = "KICK", need = "kick", text = "Iku's Icebound Flames", ability = "Icebound Flames" },
				{ tag = "MAGIC", need = "magic", text = "Icebound Flames if the cast lands", ability = "Icebound Flames" },
				{ tag = "TANK", role = "tank", text = "Swap on both: Iku's Shredding Shards is +50% magic taken, Nama's Steady Strikes stacks physical", ability = "Shredding Shards" },
				{ tag = "CD", role = "healer", text = "the Malevolent Presence rot, and the Fishy Feedback after every fish", ability = "Malevolent Presence" },
				{ text = "Nama's Mighty Thud: three soak groups, one per circle", ability = "Mighty Thud" },
				{ text = "Gebbo's bomb goes to the arena edge; bounce the shockwave on a mushroom", ability = "Explosive Surprise" },
			} },
		{ name = "Vashnik the Malignant",
			-- Method: this fight has no interrupts and no purges
			core = {
				"Every add dies before it reaches the centre pool",
				"Plague Froth: spread out and dodge the waves",
				"Toxic Vapor climbs with every Imbibe: that is the clock",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "on the pull" },
				{ tag = "TANK", role = "tank", text = "Dripping Fangs: swap every cast, it doubles physical damage taken", ability = "Dripping Fangs" },
				{ tag = "CD", role = "healer", text = "the infections: Siphoning groups up, Stygian spreads, Exploding gets staggered dispels", ability = "Toxic Vapor" },
				{ text = "Cover every Malignant Catalyst bile", ability = "Malignant Catalyst" },
			} },
		{ name = "Sszorak",
			-- no lust line: both sources flag a damage-amp window, neither calls one
			core = {
				"Apex Predator is a five-cast combo: Ravage points away, Mutilate points at the soak group, dodge the Tempest tornadoes",
				"Raging Crosswinds: pair with the player whose arrow points the opposite way and cancel the knock",
				"Drop the Viscous Cysts opposite the active wind tunnels, then ride the winds into them",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Ravage: swap between casts and point it away from the raid; watch Corroding Venom stacks", ability = "Ravage" },
				{ tag = "CD", role = "healer", text = "Ula'tek's Presence rot, and the Mutilate spike", ability = "Mutilate" },
				{ text = "Mutilate needs five or more soakers: alternate two groups", ability = "Mutilate" },
				{ text = "Stay out of the Caustic Claws pools, they raise your damage taken", ability = "Caustic Claws" },
			} },
		{ name = "The Twin Fangs",
			units = { "Vexhul", "Ithraz" },
			core = {
				"Eternal Venom is permanent and lethal at 10 stacks; Ravenous Feast is the only thing that sheds one",
				"Soak every Caustic Globule, one player each, or the whole raid takes a stack",
				"Kill both serpents together, or the survivor ramps with Uncoiled Wrath",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "on the pull" },
				{ tag = "TANK", role = "tank", text = "Stone Breaker: soak all three, then taunt swap; each soak is 33% vulnerability for 90 seconds", ability = "Stone Breaker" },
				{ tag = "TANK", role = "tank", text = "Swap Vexhul after each Caustic Deluge: Envenomed is +10% per stack for 90 seconds, so you trade serpents rather than swap on the spot", ability = "Caustic Deluge" },
				{ tag = "CD", role = "healer", text = "the Toxic Fumes rot all fight, and both tank soaks", ability = "Toxic Fumes" },
				{ text = "Ravenous Feast: three soak groups, nobody soaks twice, one stack off each", ability = "Ravenous Feast" },
				{ text = "Dodge the Corrosive Spit lines from the Venomous Emergence serpents", ability = "Corrosive Spit" },
				{ text = "Submerge: rotate against the Vile Flood beam and dodge the Sanguine Storm circles", ability = "Vile Flood" },
			} },
		{ name = "The Coiled Altar",
			units = { "Zul'jan", "Hex Lord Malacrass", "Malacrass" },
			core = {
				"Stay stacked behind the boss: the tank aims Sever into the orb and ghost clusters",
				"Break the shield to stop Eternal Nightfall, or it wipes the raid",
				"Phase 3: kill both evenly or Soulbound berserks the survivor",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "during the intermission, while Soulbinding has Zul'jan at double damage taken", ability = "Soulbinding" },
				{ tag = "KICK", need = "kick", text = "Wail of Terror on the Spiritcackles late, and kill them before they hit 100 energy and go immune", ability = "Wail of Terror" },
				{ tag = "POISON", need = "poison", text = "Venomfang", ability = "Venomfang" },
				{ tag = "MAGIC", need = "magic", text = "the healing absorb Eternal Nightfall leaves", ability = "Eternal Nightfall" },
				{ tag = "TANK", role = "tank", text = "Swap after every Sever, Soul Sever or Blighted Sever: each one massively increases the next", ability = "Sever" },
				{ tag = "CD", role = "healer", text = "the Dreadful Presence rot, and every phase push", ability = "Dreadful Presence" },
				{ text = "Guillotine needs five or more in the soak", ability = "Guillotine" },
				{ text = "Phase 2: AoE the mind-controlled free, and look at the Manifestations to freeze them", ability = "Dreadmarch" },
				{ text = "Collect the Soul Fragments within 15 seconds", ability = "Gloombomb" },
			} },
		{ name = "Ula'tek",
			core = {
				"Keep the venom off the Malignant Shells: an egg that gets hit hatches a Blightscale Viper",
				"The tank stays in melee of both Ula'tek and the Tail, or the raid eats Rattler Slam",
				"Serpent's Bite: three assigned soak groups, then spread for the Volatile Purge",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "on the first Rage of the Shackled, while the Heart takes double damage", ability = "Rage of the Shackled" },
				{ tag = "KICK", need = "kick", text = "Vicious Echoes from the Shriekers, every cast", ability = "Vicious Echoes" },
				{ tag = "TANK", role = "tank", text = "Mother's Wrath: defensive; step out of Mephitic Thrash and straight back in", ability = "Mother's Wrath" },
				{ tag = "CD", role = "healer", text = "the Necrotic Vapors rot, and every platform break, the second one in phase 3 hardest", ability = "Necrotic Vapors" },
				{ text = "Dodge Caustic Waves by moving against the telegraphed wing pull", ability = "Caustic Waves" },
				{ text = "Stack for the Spectral Coils soaks: the more bodies, the less it hurts", ability = "Spectral Coils" },
			} },
	},
})

---------------------------------------------------------------------------
-- Nymrissa Wavecaller's lair, a one-boss raid under the Wreck of Gral's
-- Belly. WCL files her under the Venomous Abyss zone, but the game puts her
-- in her own instance, so she registers on her own: listed in the Abyss she
-- would never be found. Sources: Method (Mythic) and MythicTrap (Heroic),
-- 2026-09-12, reconciled in research/instances/retail-the-tidebound-grotto.md.
-- Water Jet and the Frostscale are Mythic only; the journal hides them below.
---------------------------------------------------------------------------
KN.RegisterRaid({
	name = "The Tidebound Grotto",
	linear = true,
	bosses = {
		{ name = "Nymrissa Wavecaller",
			-- no lust line: neither source calls one
			core = {
				"Kill the murlocs before they reach the Alluring Bubble",
				"Swirling Whirlpools: stack in the one gap before they surge to the bubble",
				"Soak every Frost Orb from Chilling Frost, or it shatters on the raid",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Iceblade Flurry: defensive for each one, it raises the damage of the next", ability = "Iceblade Flurry" },
				{ tag = "TANK", role = "tank", text = "Water Jet: swap before its stacks get dangerous, and aim it at the icy patches", ability = "Water Jet" },
				{ tag = "CD", role = "healer", text = "Abyssal Rain, and every Pop! when a whirlpool breaks the bubble", ability = "Abyssal Rain" },
				{ text = "Kill any Bubblefin Berserker on sight: it pulses raid damage until it dies", ability = "Pulsing Tides" },
				{ text = "Kill the Bubblefin Frostscale first: its Waterfog Shield protects the murlocs around it", ability = "Waterfog Shield" },
				{ text = "Stand where Pop! cannot knock you into the water, or the sharks eat you", ability = "Pop!" },
			} },
	},
})
