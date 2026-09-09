-- Mists of Pandaria Classic: every instance with a live audience on that
-- client - the nine dungeons (Challenge Modes included) and the five raids.
-- Same shape as Notes/Season2.lua; read that file's header for the fields.
--
-- BOSS-ONLY, dungeons and raids alike. Trash notes are a Mythic+ feature
-- (Josh 2026-09-08, decision 1) and the research corpus carries none for
-- this client, so every dungeon here registers without a `trash` table and
-- the tracker previews the next boss on each stretch instead.
--
-- Loaded by TrueParse_Mists.toc only. Six of these dungeons (Temple of the
-- Jade Serpent, Stormstout Brewery, Mogu'shan Palace, Shado-Pan Monastery,
-- Gate of the Setting Sun, Siege of Niuzao Temple) are also retail's MoP
-- Timewalking pool - same bosses, same mechanics - and can be lifted from
-- here when that pool ships; the raids cannot, being pre-TWW legacy on
-- retail and out of scope there.
--
-- Difficulty: `min = "h"` is Heroic dungeon OR Heroic raid (10 and 25
-- alike - KN.DIFF_BY_ID folds the sizes). Ra-den is a Heroic-only encounter,
-- so its core lines carry `coreMin = "h"` too. No line here needs Raid
-- Finder handling beyond the default: a note with no `min` shows there.
--
-- SOURCES, from research/instances/mists-*.md (2026-09-08). The nine
-- dungeons are two-source reconciled (Icy Veins' MoP Classic guides plus
-- the wider MoP Classic guide ecosystem). Throne of Thunder (Skycoach +
-- Overgear) and Siege of Orgrimmar (wow.gg + AccountShark) are two-source.
-- MOGU'SHAN VAULTS, HEART OF FEAR AND TERRACE OF ENDLESS SPRING ARE
-- SINGLE-SOURCE (Icy Veins) and still owe a second pass - shipped because
-- the research files were reconciled into this shape and the tier is
-- three years cold on this client, but treat a surprising line there with
-- suspicion. Lines the research explicitly holds back are NOT written:
-- Gekkan's Hex of Lethargy (curse uncorroborated), Thalnos' Evict Soul
-- (dispel school unstated), Braun's Bloody Rage (soothability unknown),
-- Council of Elders' unnamed curses, Durumu's Divine Shield trick, Lei
-- Shen's lust (two valid windows), Thok's silence (one source only).
local _, TP = ...
local KN = TP.Notes

---------------------------------------------------------------------------
-- Dungeons
---------------------------------------------------------------------------

KN.RegisterDungeon({
	name = "Temple of the Jade Serpent",
	bosses = {
		{ name = "Wise Mari",
			core = {
				"Mari is immune until the four Corrupt Living Water elementals die: kill them away from the group",
				"Stay out of the corrupted water on the floor",
				"Phase 2: circle behind him, off the Wash Away jet",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "Hydrolance, or CC him", ability = "Hydrolance" },
				{ tag = "STUN", need = "stun", text = "Stun the Corrupt Droplets, they can't be interrupted, and burn them before the Splash AoEs overlap", ability = "Corrupt Droplets" },
				{ tag = "TANK", role = "tank", text = "Hold the water elementals away from the group", ability = "Corrupt Living Water" },
				{ tag = "CD", role = "healer", text = "the Hydrolance bursts", ability = "Hydrolance" },
			} },
		{ name = "Lorewalker Stonestep",
			core = {
				"Strife and Peril: swap targets constantly, whichever you keep hitting reaches Ultimate Power and goes immune",
				"The other scroll: burn the Five Suns, then tank and interrupt the Haunting Sha each one leaves",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "the Haunting Sha", ability = "Haunting Sha" },
			} },
		{ name = "Liu Flameheart",
			core = {
				"Spread out and stay off the Serpent Wave lava",
				"At 30% she becomes Yu'lon: stay out of the Jade Fire pools",
			},
			notes = {
				{ tag = "MAGIC", need = "magic", text = "the red Serpent Strike off the tank at once", ability = "Serpent Strike" },
				{ tag = "CD", role = "healer", text = "the green Serpent Strike: big single-target heals on the tank, no dispel", ability = "Serpent Strike" },
				{ tag = "TANK", role = "tank", text = "From 70% Jade Serpent Strike adds an undispellable healing absorb and its kick knocks you back: defensives up", ability = "Jade Serpent Strike" },
			} },
		{ name = "Sha of Doubt",
			core = {
				"Bounds of Reality spawns a Figment of Doubt for every player: kill yours fast, they heal the boss",
				"Stack so the Figments die to cleave",
			},
			notes = {
				{ tag = "MAGIC", need = "magic", text = "Touch of Nothingness at once", ability = "Touch of Nothingness" },
			} },
	},
})

KN.RegisterDungeon({
	name = "Stormstout Brewery",
	bosses = {
		{ name = "Ook-Ook",
			core = {
				"Ride the rolling barrels into him at 90%, 60% and 30%",
				"Get behind him for Ground Pound",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "the barrel phases", ability = "Ground Pound" },
			} },
		{ name = "Hoptallus",
			core = {
				"Circle him so the rotating Carrot Breath never catches you",
				"Furlwind fixates one player and spins: if it picks you, run until it stops",
				"When the virmen wave comes, stack on the tank so they converge",
			} },
		{ name = "Yan-Zhu the Uncasked",
			core = {
				"Clear the three Alemental waves first: which ones you get decides his three abilities",
				"Bloat: spread. Blackout Brew: keep moving and jump it off",
				"Break the Bubble Shields, or block the healing beam from the Yeasty adds on Ferment",
			},
			notes = {
				{ text = "Carbonation: click a Fizzy Bubble to get airborne", ability = "Carbonation" },
				{ text = "Wall of Suds: jump it with the Sudsy buff", ability = "Wall of Suds" },
			} },
	},
})

KN.RegisterDungeon({
	name = "Mogu'shan Palace",
	bosses = {
		{ name = "Trial of the King",
			core = {
				"Kuai the Brute: dodge the shockwaves and kill him before his quilen Mu'Shiba",
				"Ming the Cunning: stay out of the Whirling Dervish and the Magnetic Field",
				"Haiyan the Unstoppable: 5 yards apart for Conflagrate, then back together to split the Meteor",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Face Kuai away: Shockwave throws anyone in front of him into the air", ability = "Shockwave" },
				{ tag = "TANK", role = "tank", text = "Haiyan's Traumatic Blow halves your healing for 5 seconds: defensive, don't rely on the healer", ability = "Traumatic Blow" },
				{ tag = "CD", role = "healer", text = "Traumatic Blow on the tank: pre-heal, you can't heal through it", ability = "Traumatic Blow" },
			} },
		{ name = "Gekkan",
			core = {
				"Kill Ironhide, Hexxer, Skulker, Oracle in that order: each death gives Gekkan haste and damage taken",
				"Pull the pack to a pillar and line-of-sight their casts",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "Iron Protector on the Ironhide: it cuts the pack's damage taken by 70% and kicks despite the cast bar saying otherwise", ability = "Iron Protector" },
				{ tag = "KICK", need = "kick", text = "Cleansing Flame on the Oracle, every cast", ability = "Cleansing Flame" },
			} },
		{ name = "Xin the Weaponmaster",
			core = {
				"Ground Slam: the tank moves corner to corner on every cast",
				"Dodge the room traps: Circle of Flame, the Whirlwinding Axes and, from 66%, the Blade Trap",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Inciting Roar, unavoidable, and Death From Above from 33%", ability = "Inciting Roar" },
				{ tag = "TANK", role = "tank", text = "Ground Slam strips armour from everyone it hits: hold him in the corner by the entrance", ability = "Ground Slam" },
			} },
	},
})

KN.RegisterDungeon({
	name = "Shado-Pan Monastery",
	bosses = {
		{ name = "Gu Cloudstrike",
			core = {
				"Spread out: Invoke Lightning chains between you",
				"Phase 2: the healer pours big heals into one target to break Magnetic Shroud and free the party",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Point the Azure Serpent's Lightning Breath away from the group", ability = "Lightning Breath" },
				{ tag = "CD", role = "healer", text = "Magnetic Shroud absorbs healing: one target, big casts", ability = "Magnetic Shroud" },
			} },
		{ name = "Master Snowdrift",
			core = {
				"Out of the Fists of Fury frontal, back off for Tornado Kick",
				"Phase 3: the fixated player kites Tornado Slam",
				"Melee stop attacking during Parry Stance: it reflects and stuns",
			} },
		{ name = "Sha of Violence",
			core = {
				"Kill the Lesser Volatile Energy adds from Sha Spike as they spawn",
				"Keep casting: every spell takes 5 seconds off Smoke Blades",
			},
			notes = {
				{ tag = "CURSE", need = "curse", text = "Disorienting Smash off the tank", ability = "Disorienting Smash" },
			} },
		{ name = "Taran Zhu",
			core = {
				"Ring of Malice only hurts on the edge: be fully in or fully out",
				"Meditate at 50 to 70 Hatred: at 100 you can't hit and your healing drops by three quarters",
				"Kill the Gripping Hatred adds fast, they pull constantly",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "Rising Hate, every cast", ability = "Rising Hate" },
				{ tag = "TANK", role = "tank", text = "Sha Blast knocks you out through Ring of Malice: keep your back to a pillar", ability = "Sha Blast" },
			} },
	},
})

KN.RegisterDungeon({
	name = "Gate of the Setting Sun",
	bosses = {
		{ name = "Saboteur Kip'tilak",
			core = {
				"Spread wide: the munitions and Sabotage both detonate in crosses, so step diagonally",
				"At 70% and 30% World in Flames sets off every munition on the floor at once",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "the two World in Flames detonations", ability = "Sabotage" },
			} },
		{ name = "Striker Ga'dok",
			core = {
				"Read the emote for the Strafing Run direction and get to the safe side",
				"Kill the adds before he lands, or the acid pools take the room",
			} },
		{ name = "Commander Ri'mok",
			core = {
				"The tank kites him off the Viscous Fluid: standing in it buffs him and weakens you",
				"Stay out of the Frenzied Assault front",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "Bombard from the Krik'thik Saboteurs", ability = "Bombard" },
			} },
		{ name = "Raigonn",
			core = {
				"Phase 1: hold the Krik'thik Protectorate waves while players take the launchers to the weak spot",
				"Phase 2: the fixated player kites him away from everyone",
			},
			notes = {
				{ text = "Spread for Screeching Swarm and stay out of the Engulfing Winds", ability = "Screeching Swarm" },
			} },
	},
})

KN.RegisterDungeon({
	name = "Siege of Niuzao Temple",
	bosses = {
		{ name = "Vizier Jin'bak",
			core = {
				"Kill the Sap Globules before they reach the middle: Detonate scales with the puddle",
			} },
		{ name = "Commander Vo'jak",
			core = {
				"Use the Caustic Tar jars on the waves, and again to strip his Rising Speed",
				"Single-target the Sik'thik Demolishers and stay spread: they explode on death",
				"Get off the Dashing Strike path before Thousand Blades follows it",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Dodge his cleave, don't eat it", ability = "Thousand Blades" },
			} },
		{ name = "General Pa'valak",
			core = {
				"Take Throw Explosives from the Amber-Sappers and throw them back through the shield phases at 65% and 35%",
				"Dodge the Blade Rush: he throws the sword first, then charges where it landed",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Kite him: standing and trading kills tanks here", ability = "Blade Rush" },
			} },
		{ name = "Wing Leader Ner'onok",
			core = {
				"Keep jumping to hold the Amber Resin bar down, or it stuns you for 10 seconds",
				"At 66% and 33% push through Gusting Winds to reach him and break the channel",
				"Stay out of the Caustic Pitch pools",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Face him so the cleave misses the group and the resin lands where you want it", ability = "Caustic Pitch" },
			} },
	},
})

KN.RegisterDungeon({
	name = "Scarlet Halls",
	bosses = {
		{ name = "Houndmaster Braun",
			core = {
				"Spread 5 yards: Piercing Throw and Death Blossom both hit everything in between",
				"AoE the Obedient Hounds as he calls them at 90, 80, 70 and 60%",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "the Bloody Mess bleed stacks, and Bloody Rage at 50%: +50% attack speed, +25% damage", ability = "Bloody Mess" },
				{ tag = "TANK", role = "tank", text = "Kite the hounds, don't hold them all: the meat buckets pull them off you", ability = "Call Dog" },
			} },
		{ name = "Armsmaster Harlan",
			core = {
				"Keep Dragon's Reach pointed away, it cleaves a long way",
				"When he Heroic Leaps to the middle and starts Blades of Light, get out",
			},
			notes = {
				{ tag = "PURGE", need = "purge", text = "Berserker Rage from 50%: each purge strips ten stacks", ability = "Berserker Rage" },
				{ tag = "TANK", role = "tank", text = "Lead the whirlwind path and keep Dragon's Reach pointed away all fight", ability = "Dragon's Reach" },
			} },
		{ name = "Flameweaver Koegler",
			core = {
				"Interrupt him constantly: Fireball Volley and Pyroblast both stop",
				"Move behind him through Greater Dragon's Breath",
				"Block the Book Burner projectile with your body before it reaches the shelf",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "Fireball Volley and Pyroblast", ability = "Pyroblast" },
				{ tag = "TANK", role = "tank", text = "Face him away: the breath cleaves everything in front", ability = "Greater Dragon's Breath" },
			} },
	},
})

KN.RegisterDungeon({
	name = "Scarlet Monastery",
	bosses = {
		{ name = "Thalnos the Soulrender",
			core = {
				"Kill the Empowering Spirits before they reach a fallen crusader: one that lands becomes an Empowered Zombie",
				"Kill the raised Scarlet Crusaders fast, they pile up",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "Spirit Gale", ability = "Spirit Gale" },
			} },
		{ name = "Brother Korloff",
			core = {
				"Keep moving: Firestorm Kick is fully avoidable, and from 50% Scorched Earth trails fire behind him",
				"Stay out of the Blazing Fists front",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Rising Flame adds 10% fire damage every 5 seconds: the end of the fight is the danger", ability = "Rising Flame" },
			} },
		{ name = "High Inquisitor Whitemane",
			core = {
				"Dodge Commander Durand's Dashing Strike",
				"Interrupt every Mass Resurrection: a completed cast is the wipe",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "Mass Resurrection, without fail", ability = "Mass Resurrection" },
				{ tag = "PURGE", need = "purge", text = "Power Word: Shield", ability = "Power Word: Shield" },
			} },
	},
})

KN.RegisterDungeon({
	name = "Scholomance",
	bosses = {
		{ name = "Instructor Chillheart",
			core = {
				"Stay ahead of the Ice Wall: touching it kills outright",
				"Phase 2: break the Phylactery and dodge the Arcane Bombs",
			} },
		{ name = "Jandice Barov",
			core = {
				"Mark the real Jandice on the pull and hit only the mark: the images hit back",
			},
			notes = {
				{ text = "Ranged and healers at max range for Gravity Flux", ability = "Gravity Flux" },
			} },
		{ name = "Rattlegore",
			core = {
				"Click the Bone Piles around the room to keep Bone Armor up: Bone Spike hits anyone without it",
				"The tank kites once Rusting stacks get high",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Rusting adds 25% damage per melee hit he lands: kite him until it drops", ability = "Rusting" },
			} },
		{ name = "Lilian Voss",
			core = {
				"Death's Grasp pulls everyone in and leaves Dark Blaze: spread before it drops",
				"The Fixate Anger target kites the soul away from the group",
			} },
		{ name = "Darkmaster Gandling",
			core = {
				"Kill the Failed Students through the Rise! channel: he takes 50% less damage while it runs",
				"Harsh Lesson ports someone to a side room: clear it and come back",
			},
			notes = {
				{ tag = "MAGIC", need = "magic", text = "Immolate at once", ability = "Immolate" },
				{ tag = "MAGIC", need = "magic", text = "Explosive Pain off the Fresh Test Subjects to clear the side room", ability = "Explosive Pain" },
				{ tag = "TANK", role = "tank", text = "Incinerate comes fast and hard: keep mitigation rolling through it", ability = "Incinerate" },
			} },
	},
})

---------------------------------------------------------------------------
-- Raids (boss-only by construction: RegisterRaid refuses a trash table)
---------------------------------------------------------------------------

-- SINGLE-SOURCE (Icy Veins). See the file header.
KN.RegisterRaid({
	linear = true, -- one fixed boss order: preview the next boss, page with next/prev
	name = "Mogu'shan Vaults",
	bosses = {
		{ name = "The Stone Guard",
			core = {
				"Keep all four Guardians stacked and cleave them down together",
				"When Petrification lands, let the matching Guardian Overload before the raid turns to stone",
				"Move out of the Amethyst Pools and away from the Cobalt Mines",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Sustained damage here is among the highest in the tier: rotate mitigation constantly", ability = "Jade Shards" },
				{ tag = "CD", role = "healer", text = "the Overloads: four schools, together the fight's largest hit", ability = "Overload" },
				{ text = "Jasper Chains links two of you: stay close, distance makes it worse", ability = "Jasper Chains" },
				{ text = "Activate the Living Crystals for the floor damage buff", ability = "Living Crystals" },
			} },
		{ name = "Feng the Accursed",
			core = {
				"The tank parks him by the weapon you want him to take at each transition",
				"Use the Nullification Barrier and Shroud of Reversal crystals on the big casts",
				"Drop Wildfire Spark well away from the raid",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "Epicenter, in the last phase", ability = "Epicenter" },
				{ tag = "TANK", role = "tank", text = "Swap every two stacks: Arcane Shock, Flaming Spear, Shadowburn, Lightning Lash", ability = "Arcane Shock" },
				{ tag = "CD", role = "healer", text = "Arcane Velocity, Draw Flame and Epicenter are all unavoidable", ability = "Draw Flame" },
				{ min = "h", text = "Kill the soul fragments before they reach the Siphoning Shield", ability = "Siphoning Shield" },
			} },
		{ name = "Gara'jal the Spiritbinder",
			core = {
				"Rotate a Spirit Realm team through the totems: heal to 90% within 30 seconds to get out",
				"In the Spirit Realm kill only the Shadowy Minions; ignore the Severers of Souls",
				"Voodoo Dolls links the tank and five others: they share every hit he lands",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Banishment throws you into the Spirit Realm: stay in the top two on threat through the swaps", ability = "Banishment" },
				{ tag = "CD", role = "healer", text = "Voodoo Dolls, and the Frenzy from 20%", ability = "Voodoo Dolls" },
			} },
		{ name = "The Spirit Kings",
			core = {
				"Qiang: stack to split the Massive Attacks and run through him to dodge Annihilate",
				"Zian: interrupt every Shadow Blast and spread so Charged Shadows can't bounce",
				"Meng: damage each other to remove Maddening Shout, and stop attacking through Cowardice",
			},
			notes = {
				-- Mass Dispel is the ONLY answer to Impervious Shield (research: same
				-- shape as Lightblinded Vanguard's Divine Shield)
				{ tag = "MASSDISP", need = "massdispel", min = "h", text = "Mass Dispel Qiang's Impervious Shield, and everybody stops attacking until it is gone", ability = "Impervious Shield" },
				{ tag = "KICK", need = "kick", text = "Zian's Shadow Blast, every cast", ability = "Shadow Blast" },
				-- an ordinary dispel works here; Mass Dispel is merely faster
				{ tag = "MAGIC", need = "magic", min = "h", text = "every stack of Zian's Shield of Darkness, and nobody attacks until it is clear: each hit is 300k to the raid", ability = "Shield of Darkness" },
				{ tag = "SOOTHE", need = "soothe", min = "h", text = "Meng's Delirious", ability = "Delirious" },
				{ tag = "TANK", role = "tank", text = "Face every king away from the raid and pick up the adds. The dead kings' abilities keep going", ability = "Flanking Orders" },
				{ text = "Subetai: spread 8 yards and kill the Pinning Arrows off whoever they stun", ability = "Rain of Arrows" },
				{ text = "Subetai's Volley fires three times one way and the third kills", ability = "Volley" },
			} },
		{ name = "Elegon",
			core = {
				"Watch your Overcharged stacks and step to the Outer Circle to reset them",
				"Total Annihilation when an add dies needs at least three soakers",
				"Phase 3: split evenly and destroy all six Empyreal Focus engines",
			},
			notes = {
				-- deliberately MAGIC, not MASSDISP: any dispel removes it
				{ tag = "MAGIC", need = "magic", text = "Closed Circuit from the Celestial Protectors: it halves healing received", ability = "Closed Circuit" },
				{ tag = "TANK", role = "tank", text = "Celestial Breath: defensive", ability = "Celestial Breath" },
				{ tag = "CD", role = "healer", text = "the Total Annihilation soaks, and Unstable Energy through phase 3", ability = "Total Annihilation" },
				{ text = "Radiating Energies kills anyone left in the Outer Circle: stack up", ability = "Radiating Energies" },
			} },
		{ name = "Will of the Emperor",
			core = {
				"Dodge all ten hits of Devastating Combo: the Arc stacks an armour break and the Stomp stuns",
				"Ranged take Emperor's Strength, melee take Emperor's Courage, and CC the Emperor's Rage fixates",
				"Thirteen-minute hard enrage",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Melee damage here is extreme: rotate cooldowns between every combo", ability = "Devastating Combo" },
				{ text = "Emperor's Courage blocks the front with Half Plate: hit it from behind and slow it", ability = "Half Plate" },
				{ min = "h", text = "Titan Sparks: pop an immunity to clear a group instead of soaking one at a time", ability = "Titan Spark" },
			} },
	},
})

-- SINGLE-SOURCE (Icy Veins). See the file header.
KN.RegisterRaid({
	linear = true, -- one fixed boss order: preview the next boss, page with next/prev
	name = "Heart of Fear",
	bosses = {
		{ name = "Imperial Vizier Zor'lok",
			core = {
				"Somebody stays in melee of him and of every Echo, or Song of the Empress wipes the raid",
				"Force and Verve: get inside a shield ring for the 60% reduction",
				"Convert mind-controls two to five of you: damage them to 50% to break it",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "the phase 2 opener at 40%", ability = "Force and Verve" },
				{ tag = "TANK", role = "tank", text = "Intercept the Exhale beam off whoever it picked", ability = "Exhale" },
				{ tag = "CD", role = "healer", text = "Force and Verve, and keep instants rolling through Attenuation", ability = "Attenuation" },
				{ text = "Stay off the centre until phase 2: Pheromones of Zeal fills it", ability = "Pheromones of Zeal" },
			} },
		{ name = "Blade Lord Ta'yak",
			core = {
				"Unseen Strike: the whole raid stacks on the marked player to split it",
				"Keep clear of the tornadoes as they pile up: they last the whole phase",
				"Phase 2 at 20%: keep moving through Storm Unleashed",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "on the pull: 40 seconds before the first major ability" },
				{ tag = "TANK", role = "tank", text = "Overwhelming Assault: swap every two stacks, defensive at one", ability = "Overwhelming Assault" },
				{ tag = "CD", role = "healer", text = "every Unseen Strike, and all of phase 2", ability = "Unseen Strike" },
				{ min = "h", text = "Blade Tempest pulls the whole raid onto him: get out within two seconds", ability = "Blade Tempest" },
			} },
		{ name = "Garalon",
			core = {
				"Kill the legs from inside the Weak Point circles: each broken leg costs him health and speed",
				"Never walk under him: entering his hitbox triggers Crush at once",
				"Pass Pheromones on at 12 to 14 stacks and kite it round the outside",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Stand in front with at least one other player: Furious Swipe hitting fewer than two gives him a Fury stack", ability = "Furious Swipe" },
				{ tag = "CD", role = "healer", text = "every Crush", ability = "Crush" },
				{ min = "h", text = "From 33% he stops chasing the Pheromones target and must be tanked", ability = "Pheromones" },
			} },
		{ name = "Wind Lord Mel'jarak",
			core = {
				"Kill the add groups first: he takes 99% more damage once they are all down",
				"Never touch an armed Wind Bomb",
				"Spread for Whirling Blade: it hits going out and coming back",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "Mending from the Zar'thik Battle-Menders, without exception", ability = "Mending" },
				{ tag = "PURGE", need = "purge", text = "Quickening: it gives every mantid 35% damage and attack speed", ability = "Quickening" },
				{ tag = "LUST", need = "lust", text = "a Recklessness window once the adds are down", ability = "Recklessness" },
				{ tag = "TANK", role = "tank", text = "Keep the active adds away from the ones you have CC'd; defensive through Recklessness", ability = "Recklessness" },
				{ tag = "CD", role = "healer", text = "Rain of Blades, and the triple Kor'thik Strike on one player", ability = "Rain of Blades" },
			} },
		{ name = "Amber-Shaper Un'sok",
			core = {
				"Reshape Life turns players into Mutated Constructs: use Amber Strike to stack Destabilize on the boss",
				"Amber Explosion from a Construct or the Monstrosity kills the raid: interrupt it with Amber Strike",
				"Spread 8 yards so the Living Ambers don't chain their explosions",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "phase 3", ability = "Volatile Amber" },
				{ tag = "TANK", role = "tank", text = "Alternate the Construct duty and eat Burning Amber pools to keep Willpower up", ability = "Reshape Life" },
				{ tag = "CD", role = "healer", text = "Parasitic Growth: heal it as little as you can, healing makes it hit harder; absorbs don't feed it", ability = "Parasitic Growth" },
			} },
		{ name = "Grand Empress Shek'zeer",
			core = {
				"Leave a Dissonance Field before Sonic Discharge blows it",
				"Combine five Sticky Resin pools into the Amber Trap you need for the Reavers",
				"Phase 3 under 30%: everything lands at once, stay ahead of Calamity",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "the moment phase 3 starts", ability = "Amassing Darkness" },
				{ tag = "KICK", need = "kick", text = "Dispatch from the Set'thik Windblades", ability = "Dispatch" },
				-- FEAR, not MASSDISP: Mass Dispel is the efficient answer, not the only one
				{ tag = "FEAR", need = "fear", text = "Answer the phase 3 fears: Visions of Demise marks players", ability = "Visions of Demise" },
				{ tag = "TANK", role = "tank", text = "Eyes of the Empress: swap at three or four, five mind-controls you", ability = "Eyes of the Empress" },
				{ tag = "CD", role = "healer", text = "phase 3 is continuous: rotate everything", ability = "Amassing Darkness" },
				{ text = "Don't kill the Set'thik Windblades until two Amber Traps exist", ability = "Sticky Resin" },
			} },
	},
})

-- SINGLE-SOURCE (Icy Veins). See the file header.
KN.RegisterRaid({
	linear = true, -- one fixed boss order: preview the next boss, page with next/prev
	name = "Terrace of Endless Spring",
	bosses = {
		{ name = "Protectors of the Endless",
			core = {
				"Kill order matters: every death gives the survivors 25% more damage and a new ability",
				"Interrupt Elder Regail's Lightning Bolt and Elder Asani's Water Bolt",
				"Spread so Lightning Prison can't catch anyone next to you",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "both Lightning Bolt and Water Bolt", ability = "Lightning Bolt" },
				{ tag = "PURGE", need = "purge", text = "Cleansing Waters off the kill target: it heals them 5% a second", ability = "Cleansing Waters" },
				{ tag = "MAGIC", need = "magic", text = "Lightning Prison, and Touch of Sha", ability = "Lightning Prison" },
				{ tag = "LUST", need = "lust", text = "phase 3, on the last one standing", ability = "Overwhelming Corruption" },
				{ min = "h", text = "Rotate the Corrupted Essence soaks: about nine stacks each before it explodes", ability = "Corrupted Essence" },
			} },
		{ name = "Tsulong",
			core = {
				"Night: get him to 0%. Day: heal him to 100%. Either ends the fight",
				"Stand in the Sunbeam to clear Dread Shadows: it shrinks with each use",
				"Day phase: take Sun Breath for Bathed in Light, then pour healing into him",
			},
			notes = {
				-- a magic debuff on the boss, so MAGIC rather than FEAR
				{ tag = "MAGIC", need = "magic", text = "Terrorize off Tsulong at once", ability = "Terrorize" },
				{ tag = "TANK", role = "tank", text = "Swap after each Shadow Breath: it doubles the shadow damage you take for 30 seconds", ability = "Shadow Breath" },
				{ tag = "CD", role = "healer", text = "save everything for the Day phase, under Bathed in Light", ability = "Bathed in Light" },
				{ text = "Spread: Nightmares explodes and fears", ability = "Nightmares" },
				{ min = "h", text = "Kill the Dark of Night adds before they reach the Sunbeam", ability = "The Dark of Night" },
			} },
		{ name = "Lei Shi",
			core = {
				"She Hides constantly: spread AoE across the room to break her out",
				"Get Away! channels for 45 seconds: push 4% of her health to end it early, and move toward her to halve the damage",
				"Only one Animated Protector must die at 80, 60, 40 and 20%",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Spray stacks frost damage taken 16% a time: swap around twelve", ability = "Spray" },
				{ tag = "CD", role = "healer", text = "the last 20%: Afraid has her casting 8% faster for every 10% health she has lost", ability = "Afraid" },
				{ min = "h", text = "Scary Fog: stay within 10 yards of her", ability = "Scary Fog" },
			} },
		{ name = "Sha of Fear",
			core = {
				"Be inside the Wall of Light before Breath of Fear: outside it, it kills",
				"Somebody stays in melee or Reaching Attack pulses the raid until someone does",
				"Phase 2: pass the Pure Light ball to break Huddle in Terror and kite the Dread Spawns",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "the start of phase 2: cooldowns reset over the transition", ability = "Dread Thrash" },
				{ tag = "FEAR", need = "fear", text = "Answer the fear from Penetrating Bolt: the Terror Spawns fear after two hits", ability = "Penetrating Bolt" },
				{ tag = "TANK", role = "tank", text = "Thrash, then Dread Thrash in phase 2: major defensive. Rotate when Naked and Afraid lands", ability = "Dread Thrash" },
				{ tag = "CD", role = "healer", text = "the Huddle in Terror chains, and every Thrash window", ability = "Huddle in Terror" },
				{ text = "Hit the Terror Spawns from behind: they are immune from the front", ability = "Terror Spawn" },
			} },
	},
})

-- Two-source (Skycoach + Overgear).
KN.RegisterRaid({
	linear = true, -- one fixed boss order: preview the next boss, page with next/prev
	name = "Throne of Thunder",
	bosses = {
		{ name = "Jin'rokh the Breaker",
			core = {
				"Stack in the newest Conductive Water for the damage and healing buff",
				"Focused Lightning: run the orb away and detonate it outside the pool",
				"Get out of the water and stack up when Lightning Storm starts",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "about 20 seconds after the first Conductive Water" },
				{ tag = "TANK", role = "tank", text = "Static Wound stacks: swap and reposition after Thundering Throw", ability = "Static Wound" },
				{ tag = "CD", role = "healer", text = "Lightning Storm", ability = "Lightning Storm" },
			} },
		{ name = "Horridon",
			core = {
				"Every door brings a different troll type: clear the adds before the next one opens",
				"Never stand in front of him or behind him: Double Swipe and Charge",
				"Phase five: kill War-God Jalak before Bestial Cry stacks up",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "the Zandalari Dinomancer's Dino-Mending, and the door casters", ability = "Dino-Mending" },
				{ tag = "TANK", role = "tank", text = "Triple Puncture: swap on stacks", ability = "Triple Puncture" },
				{ tag = "CD", role = "healer", text = "each door transition", ability = "Bestial Cry" },
			} },
		{ name = "Council of Elders",
			core = {
				"All four must fall together: push whichever is empowered",
				"Stack to split Frostbite",
				"Stop damaging Kazra'jin during Overload: it reflects",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "Sand Bolt and Wrath of the Loa, every chance", ability = "Sand Bolt" },
				{ tag = "POISON", need = "poison", text = "Blazing Sunlight", ability = "Blazing Sunlight" },
				{ tag = "DISEASE", need = "disease", text = "Deadly Plague", ability = "Deadly Plague" },
				{ tag = "TANK", role = "tank", text = "Swap on Frigid Assault; pick up Malakk and Sul", ability = "Frigid Assault" },
			} },
		{ name = "Tortos",
			core = {
				"Kick a Whirl Turtle into Tortos to interrupt Furious Stone Breath: one must be ready for every cast, no spell interrupt works",
				"Keep moving out of the Rockfall circles",
				"Kill the Vampiric Cave Bats fast, they drain the raid",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "One holds Tortos, the other takes the bats", ability = "Snapping Bite" },
				{ tag = "CD", role = "healer", text = "Quake Stomp", ability = "Quake Stomp" },
			} },
		{ name = "Megaera",
			core = {
				"Pick one head kill order and stick to it",
				"Cinders: run it over the icy ground before it comes off",
				"Rampage: every cooldown, every time",
			},
			notes = {
				{ tag = "MAGIC", need = "magic", text = "Cinders after the target crosses the ice", ability = "Cinders" },
				{ tag = "TANK", role = "tank", text = "Pick up the remaining heads and face the breaths away", ability = "Rampage" },
				{ tag = "CD", role = "healer", text = "every Rampage", ability = "Rampage" },
			} },
		{ name = "Ji-Kun",
			core = {
				"Take a feather to your assigned nest and kill the Hatchlings before they grow",
				"Catch the Feed Young globules for the buff and keep them off the platform",
				"Stack and heal through Quills; hold the centre through Down Draft",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Swap on Talon Rake and Infected Talons", ability = "Talon Rake" },
				{ tag = "CD", role = "healer", text = "Quills", ability = "Quills" },
			} },
		{ name = "Durumu the Forgotten",
			core = {
				"Colour phase: stand in the beams to reveal the adds. Kill the Crimson Fogs, avoid the Azure",
				"Disintegration Beam: follow the safe path and never stop moving",
				"Ten-minute enrage; Obliterate wipes the raid",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Swap on Hard Stare", ability = "Hard Stare" },
				{ tag = "CD", role = "healer", text = "the Disintegration phase", ability = "Disintegration Beam" },
			} },
		{ name = "Primordius",
			core = {
				"Take Mutagenic Pools until you are fully mutated, then go to the boss",
				"Unmutated players kill the Living Fluids to make more pools",
				"Once fully mutated, stay out of more pools or you pick up harmful mutations",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Malformed Blood: swap. Stay out of the Primordial Strike cone", ability = "Malformed Blood" },
				{ tag = "CD", role = "healer", text = "Volatile Pathogen", ability = "Volatile Pathogen" },
			} },
		{ name = "Dark Animus",
			core = {
				"Never let Dark Animus reach 100 Anima: Full Power is a wipe",
				"Activate only the golems you mean to, and kill the small ones apart from each other",
				"Stand in the Anima Ring impact zones so it cannot spread",
			},
			notes = {
				{ tag = "MAGIC", need = "magic", text = "Matter Swap after a short delay", ability = "Matter Swap" },
				{ tag = "TANK", role = "tank", text = "Split the Anima and Massive Anima Golems between you", ability = "Siphon Anima" },
				{ tag = "CD", role = "healer", text = "the Interrupting Jolt silences", ability = "Interrupting Jolt" },
			} },
		{ name = "Iron Qon",
			core = {
				"Rotate stacking groups for Unleashed Flame, then spread",
				"Wind phase: break the Arcing Lightning stuns and stay out of the tornadoes",
				"Frost phase: keep off the shielded side of the Dead Zone and free frozen players",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "the final phase", ability = "Rising Anger" },
				{ tag = "TANK", role = "tank", text = "Swap the debuff stacks; find tornado-free ground in the last phase", ability = "Fist Smash" },
				{ tag = "CD", role = "healer", text = "the final phase, where everything overlaps", ability = "Fist Smash" },
			} },
		-- Journal name per both mechanics sources; one boss list calls the
		-- encounter "Twin Empyreans". ENCOUNTER_START matching is a substring
		-- test, so "Twin" alone is not enough - confirm in game if the boss
		-- view never appears here.
		{ name = "Twin Consorts",
			core = {
				"Night: spread for Cosmic Barrage, avoid the sleep clouds, kite Beast of Nightmares",
				"Day: stand in an Ice Comet's shade to drop Blazing Radiance stacks",
				"Keep the Comets alive: later phases need them",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Alternate on Suen for Fan of Flames; take Beast of Nightmares", ability = "Fan of Flames" },
				{ tag = "CD", role = "healer", text = "the Darkness phase, and the Corrupted Healing debuffs", ability = "Cosmic Barrage" },
			} },
		{ name = "Lei Shen",
			core = {
				"Phase 1: split to the four quadrants and stop the conduits levelling up",
				"Transitions: go to your assigned corner and stay out of the overloaded quadrant",
				"Phase 2: face away for Fusion Slash, dodge the Lightning Whip lines, kill the Ball Lightning",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Swap on the stacks and mind which conduit you are next to", ability = "Decapitate" },
				{ tag = "CD", role = "healer", text = "both transitions, and Violent Gale Winds in phase 3", ability = "Violent Gale Winds" },
				{ text = "Stack for Static Shock and soak the Bouncing Bolt impacts", ability = "Static Shock" },
			} },
		-- Heroic-only encounter: nothing here exists below "h"
		{ name = "Ra-den",
			coreMin = "h",
			core = {
				"Phase 1: manage the Vita and Anima exchanges and kill the Materials balls in sequence",
				"Pass Unstable Vita to the furthest player; stack for the Unstable Anima dispels",
				"From 40% it is a burn: Ruin scales with what you consumed",
			},
			notes = {
				{ tag = "LUST", need = "lust", min = "h", text = "40%, when Ruin starts", ability = "Ruin" },
				{ tag = "TANK", role = "tank", min = "h", text = "Rotate cooldowns for Fatal Strike; stay close for the Vita exchanges", ability = "Fatal Strike" },
				{ tag = "CD", role = "healer", min = "h", text = "the Ruin phase from 40%", ability = "Ruin" },
			} },
	},
})

-- Two-source (wow.gg + AccountShark); boss names match the crawled
-- Data/Percentiles_Mists.lua exactly.
KN.RegisterRaid({
	linear = true, -- one fixed boss order: preview the next boss, page with next/prev
	name = "Siege of Orgrimmar",
	bosses = {
		{ name = "Immerseus",
			core = {
				"Split phase: DPS kill the Sha Puddles, healers heal the Contaminated Puddles to full",
				"Grip, stun, root and knock the puddles so none reach the middle",
				"Dodge the Swirl sweeps and the geysers",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Corrosive Blast: face it away and swap on every cast, it stacks 300% damage taken for 45 seconds", ability = "Corrosive Blast" },
				{ text = "Spread so the Sha Bolt pools don't overlap", ability = "Sha Bolt" },
			} },
		{ name = "The Fallen Protectors",
			core = {
				"All three must reach the threshold together",
				"Pass the Mark of Anguish along a chain, never sit on it",
				"Gather inside Sun's Dark Meditation",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "Sha Sear", ability = "Sha Sear" },
				{ tag = "MAGIC", need = "magic", text = "Shadow Word: Bane fast", ability = "Shadow Word: Bane" },
				{ tag = "TANK", role = "tank", text = "Sundering Blow stacks: swap. Take the Embodied adds at 66 and 33", ability = "Sundering Blow" },
				{ tag = "CD", role = "healer", text = "the Vengeful Strikes stun", ability = "Vengeful Strikes" },
			} },
		{ name = "Norushen",
			core = {
				"Everyone starts Corrupted: take the orb, clear your role's trial, come back purified",
				"Don't send too many DPS in at once: adds spawn in the room when they finish",
				"Dodge the expanding Blind Hatred zones",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "30%, when Norushen dies and his Final Gift clears everyone's corruption", ability = "Final Gift" },
				{ tag = "MAGIC", need = "magic", text = "Lingering Corruption, in the healer's trial", ability = "Lingering Corruption" },
				{ tag = "TANK", role = "tank", text = "Self Doubt stacks: swap. Your trial is Test of Confidence", ability = "Self Doubt" },
			} },
		{ name = "Sha of Pride",
			core = {
				"Keep your Pride low: at 100 it mind-controls you",
				"Stack up in Gift of the Titans for the buff",
				"Split the Bursting Pride explosions and free anyone in a Corrupted Prison",
			},
			notes = {
				{ tag = "MAGIC", need = "magic", text = "Mark of Arrogance only while you are under Gift of the Titans", ability = "Mark of Arrogance" },
				{ tag = "KICK", need = "kick", text = "Mocking Blast from the adds", ability = "Mocking Blast" },
				{ tag = "TANK", role = "tank", text = "Wounded Pride: swap for its whole 15s, it feeds you 5 Pride per melee hit. Never leave melee", ability = "Wounded Pride" },
			} },
		{ name = "Galakras",
			core = {
				"Send a team up the towers to kill the commanders while the raid holds the ground waves",
				"Line the raid up so the Flames of Galakrond beam is split",
				"Kill the Flagbearers",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "the Tidal Shamans' Healing Tide Totem, and Dagryn's Muzzle Spray", ability = "Healing Tide Totem" },
				{ tag = "TANK", role = "tank", text = "Swap on the stacking fire DoT", ability = "Flames of Galakrond" },
				{ tag = "CD", role = "healer", text = "Pulsing Flames as it stacks: that is the soft enrage", ability = "Pulsing Flames" },
				{ text = "Fireball soak: melee behind him, ranged 30 yards behind melee", ability = "Flames of Galakrond" },
			} },
		{ name = "Iron Juggernaut",
			core = {
				"Assault mode: dodge the fissures and the Mortar Blasts",
				"Siege mode: get your back to a wall before Shock Pulse",
				"Never cross the Cutter Laser through the Explosive Tar",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Flame Vents: taunt at 3 stacks (+10% fire damage taken each). A free tank soaks the Crawler Mines", ability = "Flame Vents" },
				{ tag = "CD", role = "healer", text = "the mine soaks, and the constant Seismic Activity chip", ability = "Seismic Activity" },
			} },
		{ name = "Kor'kron Dark Shaman",
			core = {
				"Kill the wolf mounts first",
				"Keep Toxicity down: it amplifies all nature damage after it",
				"Position them so the Ashen Wall doesn't cut the room in half",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "25%, the burn phase", ability = "Bloodlust" },
				{ tag = "TANK", role = "tank", text = "Froststorm Strike stacks: swap. Kite Foul Geyser and spread the slimes", ability = "Froststorm Strike" },
				{ tag = "KICK", need = "kick", text = "the shamans' direct casts", ability = "Foul Stream" },
			} },
		{ name = "General Nazgrim",
			core = {
				"Watch his stance: in Defensive Stance nobody attacks but the tanks",
				"Never let Ravager go off: that is 100 Rage",
				"Kill the War Shamans first, then the Assassins and Arcweavers",
			},
			notes = {
				{ tag = "KICK", need = "kick", text = "Chain Heal from the War Shamans", ability = "Chain Heal" },
				{ tag = "TANK", role = "tank", text = "Sundering Blow: swap at 3 to 4 stacks, and mind how much Rage each stance feeds him", ability = "Sundering Blow" },
				{ tag = "CD", role = "healer", text = "War Song takes about two thirds of the raid's health", ability = "War Song" },
				{ text = "Never turn your back on an Assassin", ability = "Assassin" },
			} },
		{ name = "Malkorok",
			core = {
				"Phase 1: every non-tank soaks an Imploding Energy vortex",
				"Breath of Y'Shaarj: know your marked sector before it casts",
				"Phase 2: stack tight at his face to split Blood Rage, and run Displaced Energy out",
			},
			notes = {
				{ tag = "CD", role = "healer", text = "Ancient Miasma turns your healing into absorbs: blanket the raid, don't spot-heal", ability = "Ancient Miasma" },
				{ tag = "TANK", role = "tank", text = "Fatal Strike: swap at 10 to 15 stacks, and stay in melee", ability = "Fatal Strike" },
			} },
		{ name = "Spoils of Pandaria",
			core = {
				"Split into two sides and open crates at a matching pace: the lever runs on that energy",
				"Kill the mantid bombs well away from the group",
				"Kill the Pandaren Relic spirits for your role's blessing",
			},
			notes = {
				{ tag = "MAGIC", need = "magic", text = "Torment before it chains to the nearest player, and Rage of the Empress", ability = "Torment" },
				{ tag = "KICK", need = "kick", text = "Forbidden Magic from the Shao-Tien", ability = "Forbidden Magic" },
				{ tag = "TANK", role = "tank", text = "Take whatever comes out of the Massive crates", ability = "Massive Crate" },
			} },
		{ name = "Thok the Bloodthirsty",
			core = {
				"Stand at his flank: the front is a cone and the back is the tail",
				"Phase 2: outrun the Fixate and break line of sight through the gates",
				"Kill the Kor'kron Jailer for the cage key and choose the prisoner order deliberately",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Fearsome Roar: swap at 4 stacks, and hold him away from the raid", ability = "Fearsome Roar" },
				{ tag = "CD", role = "healer", text = "Deafening Screech, and the Blood Frenzy burst", ability = "Deafening Screech" },
			} },
		{ name = "Siegecrafter Blackfuse",
			core = {
				"Rotate players onto the conveyor: at least one weapon dies per volley or he shields",
				"Never touch the conveyor's Matter Purification beam: it kills outright",
				"Scatter the Shockwave Missile rings by moving inward",
			},
			notes = {
				{ tag = "TANK", role = "tank", text = "Electrostatic Charge: swap at 7 stacks. Drag the Shredders 35 yards off him", ability = "Electrostatic Charge" },
				{ tag = "CD", role = "healer", text = "the Protective Frenzy spikes", ability = "Protective Frenzy" },
				{ text = "Kite the Crawler Mines, then stun them: after a minute they can't be CC'd", ability = "Crawler Mine" },
			} },
		{ name = "Paragons of the Klaxxi",
			core = {
				"Every Paragon that dies heals and buffs the survivors with Paragon's Purpose",
				"Claim the Paragon powers deliberately: each one suits a role",
				"Split Iyyokuk's Insane Calculation beams far apart",
			},
			notes = {
				{ tag = "MAGIC", need = "magic", text = "Injection", ability = "Injection" },
				{ tag = "TANK", role = "tank", text = "Intercept the Bloodletting creatures; handle Rik'kal's parasites and the Mutation form", ability = "Bloodletting" },
				{ tag = "CD", role = "healer", text = "Ingenious spreads your healing: take it if offered", ability = "Ingenious" },
				{ text = "Break Korven's amber shells, and watch Kaz'tik's Mesmerize", ability = "Mesmerize" },
			} },
		{ name = "Garrosh Hellscream",
			core = {
				"Interrupt every Touch of Y'Shaarj: a silence works even on the Empowered version",
				"CC the minions into the Iron Star path",
				"Intermission: cut through the sha adds and stop his power drain",
			},
			notes = {
				{ tag = "LUST", need = "lust", text = "phase 3", ability = "Hellscream's Warsong" },
				{ tag = "KICK", need = "kick", text = "Touch of Y'Shaarj, without exception", ability = "Touch of Y'Shaarj" },
				{ tag = "TANK", role = "tank", text = "Gripping Despair stacks: swap", ability = "Gripping Despair" },
				{ tag = "CD", role = "healer", text = "the minion phases, and every empowerment step", ability = "Desecrate" },
				{ text = "Kill the Empowered Whirling Corruption adds one at a time", ability = "Whirling Corruption" },
			} },
	},
})
