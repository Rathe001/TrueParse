-- Midnight Season 2 dungeon pool. Written once, per ROLE, in class-neutral
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
				"Kill the Blazebound Firestorm from Ritual of Blazebinding, kick Roaring Blaze, out of Burnout when it dies",
				"Sidestep Molten Boulder, it stuns",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Inferno from the add, grows the longer it lives", ability = "Inferno" },
				{ tag = "TANK", role = "tank", text = "Defensive for every Searing Blows; pick the Firestorm up", ability = "Searing Blows" },
			} },
		{ name = "Kyrakka and Erkhart Stormvein",
			core = {
				"Read Winds of Change, drop fire puddles downwind of the group",
				"Spread for Inferno Spit: two targets in P1, three in P2",
				"Stop casting before Interrupting Cloudburst lands",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "phase 2, when Erkhart mounts", ability = "Inferno Spit" },
				{ tag = "MAGIC", need = "magic", text = "Stormslam off the tank before the next cast, it doubles nature damage", ability = "Stormslam" },
				{ tag = "CD", role = "healer", text = "P2 Inferno Spit", ability = "Inferno Spit" },
				{ tag = "TANK", role = "tank", text = "Stormslam stacks if it isn't dispelled: call for it", ability = "Stormslam" },
			} },
	},
	trash = {
		{ tag = "LUST", need = "lust", affix = "Fortified", text = "the first big pull", leg = 1 },
		{ tag = "BUILD", class = "SHAMAN", min = "k", text = "no poison here: swap Poison Cleansing Totem out", leg = 1 },
		{ name = "Chillweaver", tag = "PURGE", need = "purge", text = "Ice Shield keeps the pack alive", leg = 1 },
		{ name = "Flamedancer", tag = "STUN", need = "stun", text = "Flame Dance can't be kicked: hard CC it", leg = 1 },
		{ name = "Primal Thundercloud", tag = "PURGE", need = "purge", text = "Purge its shield" },
		{ name = "Flamegullet", tag = "CD", role = "healer", text = "Enrages under 50%, party damage climbs fast", leg = 2 },
		{ name = "Flamegullet", tag = "TANK", role = "tank", text = "Fire Maw: defensive, it leaves a DoT", leg = 2 },
		{ name = "Thunderhead", tag = "MAGIC", need = "magic", text = "Rolling Thunder: dispel one player at a time, it spreads", leg = 3 },
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
				{ tag = "TANK", role = "tank", text = "You can soak mushrooms too; the meat-pile Bellow knocks back", ability = "Spoiled Supplies" },
			} },
		{ name = "Sentinel of Winter",
			core = {
				"Stack to bait Raging Squall tornadoes into one spot, then rotate the room",
				"Kill the Fractured Shivercores, kick Winter's Shroud, one player soaks each Rimeshatter",
			},
			notes = {
				{ tag = "LUST", need = "lust", affix = "Fortified", text = "when the Shivercores spawn", ability = "Shattering Frostspike" },
				{ tag = "MAGIC", need = "magic", text = "Glacial Torment off immediately", ability = "Glacial Torment" },
				{ tag = "CD", role = "healer", text = "Frozen Tempest channel", ability = "Frozen Tempest" },
				{ tag = "TANK", role = "tank", text = "Drag the boss to each Shivercore so it dies to cleave", ability = "Shattering Frostspike" },
				{ role = "ranged", text = "Rimeshatter soaks usually fall to ranged", ability = "Rimeshatter" },
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
				{ tag = "TANK", role = "tank", text = "Forceful Slam is yours to soak right after Onslaught", ability = "Forceful Slam" },
			} },
	},
	trash = {
		{ tag = "TASK", text = "Gather six offerings (berries in bushes, fishing spots, apple barrels) to summon the Hoardmonger", leg = 1 },
		{ tag = "TASK", text = "Optional: Warding Incense (bear form, or Alchemy 25) is +5% versatility for 10 min", leg = 1 },
		{ tag = "TASK", text = "Optional: Snowworn Provisions halfway through the Harsh Winds gauntlet, right side (Night Elf, Troll, or bear form) halves knockbacks for 15 min", leg = 2 },
		{ name = "Earthwhisper Tender", tag = { "KICK", "PURGE" }, need = { "kick", "purge" }, text = "Healing Breeze, every cast" },
		{ name = "Spirit of Hunger", text = "Kill the Starvation Effigy totem it drops" },
		{ name = "Mauler / Mystic", tag = "KICK", need = "kick", text = "Arc Lightning, never let one through" },
		{ name = "Loa Speaker Nanea", text = "Kill the Volatile Totems", leg = 3 },
		{ name = "Troll casters", tag = "CURSE", need = "curse", text = "Their curses are yours", leg = 3 },
		{ name = "Bonded Beasttamer", tag = "SOOTHE", need = "soothe", text = "Bestial Wrath enrage" },
		{ name = "Territorial Matriarch", tag = "SOOTHE", need = "soothe", text = "Mother's Wrath enrage" },
	},
})

KN.RegisterDungeon({
	name = "Murder Row",
	bosses = {
		{ name = "Kystia Manaheart",
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
				{ tag = "POISON", need = "poison", text = "Envenom, then Heartstop Poison on the tank", ability = "Envenom" },
				{ tag = "TANK", role = "tank", text = "Envenom then Heartstop Poison: defensive, ask for the poison dispel", ability = "Envenom" },
			} },
		{ name = "Xathuux the Annihilator",
			core = {
				"Axe Toss: kill the Axe fast, Fel Lightning stacks while it lives",
				"Demonic Rage: kite him along the edge, out of Burning Steps",
				"Loose spread for Infernal Crush",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Infernal Crush, it lands on top of Demonic Rage", ability = "Infernal Crush" },
				{ tag = "TANK", role = "tank", text = "Legion Strike: defensive; hold him at the edge facing out", ability = "Legion Strike" },
				{ role = "ranged", text = "If you get the Axe, drop it next to the boss so melee cleave it", ability = "Axe Toss" },
			} },
		{ name = "Lithiel Cinderfury",
			core = {
				"Kick rotation on Chaos Bolt",
				"Kill the Furious Vilefiend on spawn; CC the Wild Imps in Fingers of Gul'dan",
				"Malefic Wave: cleave the adds before it reaches them, then Demonic Gateway to the safe side",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "on pull, hardest boss in the dungeon" },
				{ tag = "CD", role = "healer", text = "Searing Fel Flame rots all fight: rolling, not burst", ability = "Searing Fel Flame" },
				{ tag = "TANK", role = "tank", text = "The Infernal can't die and kills on contact: keep the boss away from it; pick up the Vilefiend", ability = "Summon Vilefiend" },
			} },
	},
	trash = {
		{ tag = "TASK", text = "Interrogate all four Silvermoon Snitches in the first area; Kystia's door stays shut until you do", leg = 1 },
		{ tag = "TASK", text = "The bar: all five of you talk to Selenar Sunshy, then work your job to five stars. Five Star Review is +10% damage and healing for 5 min", leg = 2 },
		{ tag = "BUILD", class = "SHAMAN", min = "k", text = "Improved Purify Spirit for Curse of Doom", leg = 1 },
		{ name = "Massive Felwyrm", text = "Explodes on death, kill it away from the group", leg = 1 },
		{ name = "Shivan Punisher", tag = "CD", role = "healer", text = "Enrages at 50%", leg = 3 },
		{ name = "Corrupted Warlock", tag = { "KICK", "CURSE" }, need = { "kick", "curse" }, text = "Curse of Doom: kick it, or dispel the moment it lands" },
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
				{ tag = "CD", role = "healer", text = "Top everyone before each Umbral Rupture", ability = "Umbral Rupture" },
				{ tag = "TANK", role = "tank", text = "Void Blast knocks you back: defensive, and don't land in a puddle", ability = "Void Blast" },
			} },
		{ name = "Atroxus",
			core = {
				"Monstrous Roar spawns a Toxic Creeper: kill it now, its Toxic Aura is a wipe",
				"Out of the Poison Pools, sidestep Noxious Breath",
			},
			notes = {
				{ tag = "LUST", need = "lust", affix = "Tyrannical", text = "on the first Creeper", ability = "Toxic Creeper" },
				{ tag = "CD", role = "healer", text = "Every Creeper", ability = "Toxic Creeper" },
				{ tag = "POISON", need = "poison", text = "Mind-Numbing Poison, it feeds Hulking Claw on the tank", ability = "Mind-Numbing Poison" },
				{ tag = "TANK", role = "tank", text = "The Creeper fixates you and every hit stacks Sickening Bite: kite it, and defensive Hulking Claw", ability = "Hulking Claw" },
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
				{ role = "dps", text = "Stand near a star before Gravitic Orbs go out, the run is shorter", ability = "Gravitic Orb" },
			} },
	},
	trash = {
		{ tag = "TASK", text = "Pick a path. Left: Aegyra, fewer kicks, Proof of Endurance buff. Right: Raj'kess, more Enthralled Shamans, Proof of Mastery. Both last 30 min", leg = 1 },
		{ tag = "TASK", text = "Kill all three Devouring Brutalizers to open Charonus's arena", leg = 3 },
		{ tag = "LUST", need = "lust", affix = "Fortified", text = "the opening pack", leg = 1 },
		{ name = "Devouring Brutalizer", text = "Devours low-health mobs to grow: don't leave things at 10%" },
		{ name = "Harrower (left)", text = "Sky Strike is a stack-to-split, not a spread", leg = 2 },
		{ name = "Enthralled Shaman", text = "Kill the Magma Totem on spawn" },
		{ name = "Kilivore Screamer", tag = "KICK", need = "kick", text = "Demoralizing Shout" },
		{ name = "Agitated Voidscythe", tag = "POISON", need = "poison", text = "Corrosive Essence" },
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
				{ tag = "CD", role = "healer", text = "Thorncaller Roar pulses, hold majors for the frenzy", ability = "Thorncaller Roar" },
				{ tag = "TANK", role = "tank", text = "Hold him next to rooted players so cleave clears the roots", ability = "Bloodthorn Roots" },
			} },
		{ name = "Lightwarden Ruia",
			core = {
				"Kick Warden's Wrath, out of Lightfall",
				"Bear at 70%: tank bleeds · Haranir at 40%: 8s ability cycle",
			},
			notes = {
				{ role = "healer", text = "Grievous Thrash clears when the target is healed to full", ability = "Grievous Thrash" },
				{ tag = "CD", role = "healer", text = "Lightfire explosions", ability = "Lightfire" },
				{ tag = "TANK", role = "tank", text = "Bear form hits harder (Mangling Claws) and Grievous Thrash stacks until you're full", ability = "Grievous Thrash" },
				{ role = "melee", text = "Spread for Pulverizing Strikes, it's a cone on several of you", ability = "Pulverizing Strikes" },
			} },
		{ name = "Ziekket",
			core = {
				"Kill the lashers from Awaken the Lightbloom fast",
				"Aim Concentrated Lightbeam over their bodies or they come back",
				"Soak Lightbloom's Essence orbs before they reach him",
			},
			notes = {
				{ tag = "LUST", need = "lust", affix = "Fortified", text = "the first add phase", ability = "Awaken the Lightbloom" },
				{ tag = "CD", role = "healer", text = "Oozing Xylem rot, peaks in the add phase; watch high Essence stacks", ability = "Oozing Xylem" },
				{ tag = "TANK", role = "tank", text = "Thornspike: defensive; group the lashers", ability = "Thornspike" },
			} },
	},
	trash = {
		{ tag = "TASK", text = "Optional: left path, the Light-Starved Blossom (Paladin, Priest, or Herbalism 25) is 20% speed and 5% haste for 2 min; right path, Hunters and Druids can free the Baby Grovecrawler to fight for a minute", leg = 1 },
		{ tag = "TASK", text = "After Ikuzz, talk to the bird to fly down to Ruia", leg = 3 },
		{ name = "Sporeblight Belcher", text = "Explodes on death", leg = 2 },
		{ name = "Potatoad Matriarch", tag = "POISON", need = "poison", text = "Toxic Spew hits everyone", leg = 3 },
		{ name = "Radiant Spellsower", tag = "KICK", need = "kick", text = "Light Bolt Volley wakes the dormant adds" },
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
				{ tag = "CD", role = "healer", text = "Right after the soak", ability = "Thunder and Lightning" },
				{ tag = "TANK", role = "tank", text = "Overload: defensive every cast", ability = "Overload" },
			} },
		{ name = "Merektha",
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
				{ tag = "LUST", need = "lust", text = "on pull, it is an energy race" },
				{ tag = "CD", role = "healer", text = "Soakers stack Galvanized; top everyone before each Induction", ability = "Galvanized" },
				{ tag = "TANK", role = "tank", text = "Place him so the DPS can reach the spires; you don't soak", ability = "Lightning Spire" },
				{ role = "dps", text = "The spires are yours: rotate soakers, Galvanized stacks", ability = "Lightning Spire" },
			} },
		{ name = "Avatar of Sethraliss",
			core = {
				"Corrupted Guardian, then grab every Corrupted Lifeforce orb within 6s",
				"Essence Defiler first when it's up: it stops healing on the Avatar",
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
		{ tag = "TASK", text = "Loose Spark gauntlet: walk the spiral between the sparks; killing the Spark Channelers thins them", leg = 3 },
		{ tag = "TASK", text = "Second gauntlet, same rules; then energize both Eyes of Sethraliss: click one, stand in the ticking damage until the bar fills, kill what spawns, repeat. The skull door opens to the Avatar", leg = 4 },
		{ tag = "BUILD", class = "SHAMAN", min = "k", text = "Poison Cleansing Totem, and Improved Purify Spirit for Addle Mind", leg = 1 },
		{ name = "Imbued Stormcaller", tag = "MAGIC", need = "magic", text = "Imbued Conduction stuns when it expires: dispel every one" },
		{ name = "Poisonous Viper", tag = "POISON", need = "poison", text = "Cytotoxin" },
		{ name = "Faithless Subjugator", tag = { "KICK", "CURSE" }, need = { "kick", "curse" }, text = "Addle Mind: kick it, or dispel it" },
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
				{ tag = "CD", role = "healer", text = "Arc Lightning cleaves off the tank and hits hard", ability = "Arc Lightning" },
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
		{ name = "Risen Hexer", tag = { "KICK", "MAGIC" }, need = { "kick", "magic" }, text = "Hex Volley hits the whole party; Shadowfrost Bolt is a dispel", leg = 1 },
		{ name = "Phantom Hex Priest", tag = "CURSE", need = "curse", text = "Hex", leg = 2 },
		{ name = "Queen Patlaa", tag = "POISON", need = "poison", text = "Serpent Strike", leg = 2 },
		{ name = "Spectral Shaman", text = "Kill its Healing Tide Totem on spawn" },
		{ name = "Seneschal M'bara", tag = { "KICK", "PURGE" }, need = { "kick", "purge" }, text = "Unholy Mending; purge what lands" },
		{ name = "Half-Finished Mummy", tag = "KICK", need = "kick", text = "Wretched Discharge, every cast" },
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
		{ tag = "TASK", text = "Destroy the six Caustic Mist Totems around the start to open the way to Rav'i", leg = 1 },
		{ tag = "TASK", text = "Destroy the four Infusion Totems in the mist wall, then kill the Ascendant Serpent to reach Zul'jan", leg = 3 },
		{ tag = "TASK", text = "Optional: the Unfinished Mixture near Zul'jan (Cooking or Alchemy 25) gives Mutating Elixir for the rest of the run", leg = 3 },
		{ tag = "LUST", need = "lust", affix = "Fortified", text = "the Ritual Chieftain pack", leg = 1 },
		{ tag = "BUILD", class = "SHAMAN", min = "k", text = "Poison Cleansing Totem for Envenom and Mass Envenom", leg = 1 },
		{ name = "Ritual Chieftain", tag = "KICK", text = "Blood Sacrifice puts a heal absorb on everyone", leg = 1 },
		{ name = "Ula'tek's Chosen", tag = { "KICK", "POISON" }, need = { "kick", "poison" }, text = "Mass Envenom, every cast; dispel what lands" },
		{ name = "High Evolutionist", tag = { "STUN", "POISON" }, need = { "stun", "poison" }, text = "Evolve can't be kicked: hard CC it or it becomes Mass Envenom; Envenom is a dispel" },
		{ name = "Living Venom", text = "Explodes on death: stagger the kills" },
		{ name = "Twinfang Harrower", tag = "TANK", role = "tank", text = "Duostrike: defensive" },
		{ name = "Ravenous Descendant", tag = "SOOTHE", need = "soothe", text = "Ravenous enrage" },
	},
})
