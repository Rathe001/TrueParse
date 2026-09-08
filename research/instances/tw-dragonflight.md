# Timewalking pool — Dragonflight

- **Type:** 6 legacy dungeons, **thin treatment**: bosses and the two or three
  lines that still kill people. No trash.
- **Source:** Icy Veins per-dungeon guides, read 2026-09-08. Single source.
- **Status:** drafted (5 of 6; Ruby Life Pools already shipped)

**Ruby Life Pools is already registered** in `Notes/Season2.lua` as a Season 2
keystone dungeon, with full per-role notes and trash. One registration serves
both — the trash simply stops rendering outside a key now that
`trashApplies()` gates on keystone difficulty.

---

## Algeth'ar Academy

Overgrown Ancient → Crawth → Vexamus → Echo of Doragosa.

**Overgrown Ancient**
1. Burst Forth hits the group hard and wakes the adds
2. Pick the Hungry Lashers up quickly — their poison is what kills
- `KICK` need kick — "the Ancient Branch's heal" · ability `Ancient Branch`

**Crawth**
1. Dodge the Overpowering Gust frontal
2. Thread the fire motes and cyclones the goals leave behind
- `CD` healer — "Deafening Screech, stacked on top of the ground effects" · ability `Deafening Screech`

**Vexamus**
1. Keep the Arcane Orbs away from him — watch his Oversurge stacks
2. Arcane Fissure at 100 energy is the group hit
- `KICK` need kick — "the Corrupted Manafiend's Surge" · ability `Surge`

**Echo of Doragosa**
1. Manage Overwhelming Power or you spawn extra Arcane Rifts
2. Power Vacuum pushes you — don't get shoved into a rift
- `CD` healer — "Astral Breath at 100 energy" · ability `Astral Breath`

---

## Halls of Infusion

Watcher Irideus → Gulping Goliath → Khajin the Unyielding → Primal Tsunami.

**Watcher Irideus**
1. Destroy the three Nullification Devices to drop Ablative Barrier — the longer it stands the more Siphon Power he stacks
2. Stay out of the Reactive Spark puddles
- `KICK` need kick — "Purifying Blast from the devices" · ability `Purifying Blast`

**Gulping Goliath**
1. Kill the Curious Swoglets fast — ten stacks of Gulp Swog Toxin kills you
2. Somebody gets eaten on purpose, or Hangry enrages him and it cannot be removed
- *Hangry is explicitly undispellable — do not write a `SOOTHE` line*

**Khajin the Unyielding**
1. Hailstorm: get behind an Ice Boulder — each one breaks after a single use
2. Don't bait Frost Cyclone into the boulders you still need
- `KICK` need kick — "Ice Shards" · ability `Ice Shards`

**Primal Tsunami**
1. Stage two: split into the two corridors and survive the Crashing Tsunami knockback
2. Kill the Infused Globules before they land
- `KICK` need kick — "Infuse from the Primalist Infusers" · ability `Infuse`
- `MAGIC` need magic — "Waterlogged" · ability `Waterlogged`
- `TANK` tank — "Stay in melee or he casts Undertow" · ability `Undertow`

---

## Neltharus

Magmatusk → Chargath, Bane of Scales → Forgemaster Gorek → Warlord Sargha.

**Magmatusk**
1. Dodge the Lava Spray cone and the wave behind Blazing Charge
2. Stay out of Liquid Hot Magma

**Chargath, Bane of Scales**
1. Kite him through three Grounding Chains to trigger Fetter — that is the stun and a 50% damage window
- `TANK` tank — "Fiery Focus" · ability `Fiery Focus`

**Forgemaster Gorek**
1. Heated Swings knocks you back into the pools — watch where you stand
2. Stay out of the Forgestorm puddles
- `CD` healer — "Blazing Hammer" · ability `Blazing Hammer`

**Warlord Sargha**
1. Use the ground items — the Wand, the Bomb, the Rose — to break the Magma Shield faster
2. Kite Burning Pursuit from the Raging Ember
- `CURSE` need curse — "Curse of the Dragon Hoard" · ability `Curse of the Dragon Hoard`

---

## The Azure Vault

Leymor → Azureblade → Telash Greywing → Umbrelskul.

**Leymor**
1. Kill the Volatile Saplings before Stinging Sap goes off
2. Consuming Stomp scales with how many sprouts are live — defensives

**Azureblade**
1. All four Draconic Illusions die before she takes damage
2. Overwhelming Energy: dodge the Ancient Orb Fragments, and it is the healing check
- `KICK`/`STUN` — "Illusionary Bolt — a stun works too" · ability `Illusionary Bolt`

**Telash Greywing**
1. Absolute Zero: get under a Vault Rune or die
2. Icy Devastator: an immunity or a real defensive — a combat reset also drops it

**Umbrelskul**
1. Brittle phase: detonate the crystals or the group picks up a lasting DoT
2. Never be caught by Crystalline Roar
- `MAGIC` need magic — "the tank's Dragon Strike DoT" · ability `Dragon Strike`

---

## Brackenhide Hollow

Hackclaw's War-Band → Gutshot → Treemouth → Decatriarch Wratheye.

**Hackclaw's War-Band**
1. Gash Frenzy bleeds come off by healing the target above 90%
2. The tank soaks Savage Charge
- `KICK` need kick — "Greater Healing Rapids" · ability `Greater Healing Rapids`

**Gutshot**
1. Dodge the Bounding Leap indicator — it stuns
2. Kill the hyenas before the next pair arrive
- `KICK` need kick — "Master's Call" · ability `Master's Call`

**Treemouth**
1. Somebody has to be consumed to strip his shield
2. Stay out of the Decay pools after the Decaying Slimes burst
- `KICK` need kick — "Gushing Ooze from the slimes" · ability `Gushing Ooze`

**Decatriarch Wratheye**
1. Move out of the Choking Rotcloud — it silences
2. Kill the Rotburst Totems
- `KICK` need kick — "the Rotburst Totem cast" · ability `Rotburst Totem`
- `DISEASE` need disease — "Withering Rot" · ability `Withering Rot`
- `CD` healer — "Decaystrike on the tank" · ability `Decaystrike`

---

## Ruby Life Pools

Already shipped — see `Notes/Season2.lua`. Melidrussa Chillworn → Kokia
Blazehoof → Kyrakka and Erkhart Stormvein.
