# The War Within — dungeons

- **Type:** 10 max-level dungeons. **Thin treatment**: bosses and the two or
  three things that actually kill people. No trash (they are not in a
  Timewalking pool and not in the current keystone pool).
- **Source:** Icy Veins per-dungeon guides, read 2026-09-08. Single source.
- **Status:** drafted

TWW is the expansion immediately before Midnight and is in no Timewalking
pool, so it sat in the "legacy backlog" alongside Molten Core despite being
far more likely to be run. That is why it was pulled forward.

**Boss-name collision worth knowing:** `Rasha'nan` is the third boss of The
Dawnbreaker *and* the fourth boss of Nerub-ar Palace. Boss lookup is scoped to
the resolved instance (`findDataBoss` only searches `state.dungeon.bosses`),
so this is safe — but it is a good argument for keeping it that way.

---

## Ara-Kara, City of Echoes

Avanoxx → Anub'zekt → Ki'katal the Harvester.

**Avanoxx**
1. Kill the Starved Crawlers before they reach him — Insatiable stacks are the wipe
2. Stay out of Vile Webbing; ten stacks is Web Wrap

**Anub'zekt**
1. Stay in the safe zone through Eye of the Swarm
2. Dodge the Ceaseless Swarm swirlies
- `KICK` need kick — "Silken Restraints from the Bloodstained Webmages" · ability `Silken Restraints`
- `TANK` tank — "Impale is a frontal: point it away" · ability `Impale`

**Ki'katal the Harvester**
1. Take Grasping Blood from the damaged Bloodworkers and use the root to get clear of Singularity
- `POISON` need poison — "Cultivated Poisons — but dispelling it fires poison waves, so call it, don't reflex it" · ability `Cultivated Poisons`

---

## The Stonevault

E.D.N.A. → Skarmorak → Master Machinists Brokk and Dorlita → High Speaker Eirich.

**E.D.N.A.**
1. Stay close together for Volatile Spikes so they break quickly
- `CD` healer — "Earth Shatterer" · ability `Earth Shatterer`

**Skarmorak**
1. Break the Crystal Shards one at a time — they stack AoE as they die
2. End the Fortified Shell phase quickly or Void Discharge escalates

**Master Machinists Brokk and Dorlita**
1. They have to die together or Silenced Speaker wipes the raid
2. Blazing Crescendo spawns unavoidable Magma Waves
- `KICK` need kick — "Brokk's Molten Metal, every cast" · ability `Molten Metal`

**High Speaker Eirich**
1. Void Corruption is cleansed at a Void Rift — but going near one *without* the debuff kills you outright

---

## The Dawnbreaker

Speaker Shadowcrown → Anub'ikkaj → Rasha'nan.

**Speaker Shadowcrown**
1. Dodge the Obsidian Beam — contact is death
2. Darkness Comes: fly to a Radiant Light platform or die
- `KICK` need kick — "Shadow Bolt" · ability `Shadow Bolt`

**Anub'ikkaj**
1. Position for the Dark Orbs — being hit applies Dark Scars, which finishes you
- `KICK`/`STUN` — "Congealed Darkness during Animate Shadows" · ability `Congealed Darkness`
- `CD` healer — "the Shadowy Decay pulses" · ability `Shadowy Decay`

**Rasha'nan**
1. Phase 2: collect the Light Fragments by air or Encroaching Shadows kills you
2. Get out of the Spinneret's Strands webbing — standing in it escalates
- `KICK` need kick — "Acidic Eruption, before the phase 2 transition" · ability `Acidic Eruption`
- `CD` healer — "Erosive Spray; Lingering Erosion cannot be dispelled" · ability `Erosive Spray`

---

## City of Threads

Orator Krix'vizk → Fangs of the Queen → The Coaglamation → Izo, the Grand Splicer.

**Orator Krix'vizk**
1. Stay within 10 yards or Chains of Oppression drags you in
- `MAGIC` need magic — "Shadows of Doubt: dispel one, spot-heal the other, before the shadow waves spawn" · ability `Shadows of Doubt`
- `CD` healer — "Vociferous Indoctrination at 100 energy" · ability `Vociferous Indoctrination`

**Fangs of the Queen**
1. Dodge the Synergic Step frontals through the phase change
- `KICK` need kick — "Web Bolt" · ability `Web Bolt`
- `MAGIC` need magic — "Ice Sickles" · ability `Ice Sickles`
- `TANK` tank — "Frozen Solid stacks in phase 2 need the party's help" · ability `Freezing Blood`

**The Coaglamation**
1. Alternate the Vicious Darkness orb soaks — Corrupted Coating stacks kill
- `TANK` tank — "Oozing Smash" · ability `Oozing Smash`
- `CD` healer — "Dark Pulse at 100 energy" · ability `Dark Pulse`

**Izo, the Grand Splicer**
1. Stack through Umbral Weave and break the roots fast
2. Kill the Ravenous Scarabs before five Gorged stacks becomes Gutburst
- `KICK` need kick — "Web Bolt" · ability `Web Bolt`
- `TANK` tank — "Process of Elimination at 100 energy" · ability `Process of Elimination`

---

## The Rookery

Kyrioss → Stormguard Gorren → Voidstone Monstrosity.

**Kyrioss**
1. Sidestep Lightning Dash — it is lethal
2. Outrun the Lightning Torrent beam at 100 energy

**Stormguard Gorren**
1. Dodge the Crush Reality patterns; the Reality Tears they leave persist
2. Burn a movement cooldown to escape the Dark Gravity pull

**Voidstone Monstrosity**
1. Destroy the Voidstone Fragments during Null Upheaval before they transform
2. Sidestep the Oblivion Wave frontal
- `TANK` tank — "Stay in melee or he casts Entropy" · ability `Entropy`

No interrupts anywhere in this dungeon.

---

## Priory of the Sacred Flame

Captain Dailcry → Baron Braunpyke → Prioress Murrpray.

**Captain Dailcry**
- `KICK` need kick — "Battle Cry — it is his enrage" · ability `Battle Cry`
- `TANK` tank — "Pierce Armor stacks a bleed; Savage Mauling wants a cooldown" · ability `Savage Mauling`

**Baron Braunpyke**
1. Vindictive Wrath at 100 energy empowers everything — this is the dangerous window
2. Sacrificial Flame stacks and hits the group on every application
- `KICK` need kick — "Burning Light" · ability `Burning Light`

**Prioress Murrpray**
1. At 50% Barrier of Light shields her — break the absorb to reach the interrupt
- `KICK` need kick — "Holy Smite as often as you can, and Embrace the Light once the shield is down" · ability `Embrace the Light`
- `CD` healer — "the Inner Fire phase" · ability `Inner Fire`

---

## Darkflame Cleft

Ol' Waxbeard → Blazikon → The Candle King → The Darkness.

**Ol' Waxbeard**
1. Reckless Charge into Cave-In kills players and the Menial Laborers alike
2. The Underhanded Track-tics dynamite cart wipes the group

**Blazikon**
1. Enkindling Inferno at 100 energy is unavoidable unless you are in the safe spot
- `KICK` need kick — "Explosive Flame from the Blazing Fiends" · ability `Explosive Flame`
- `TANK` tank — "Stay in melee or Blazing Storms starts" · ability `Blazing Storms`

**The Candle King**
1. Clear the Eerie Molds quickly — the longer they live the more the party takes
2. Keep away from the wax statues or Cursed Wax triggers
- `KICK` need kick — "Paranoid Mind, at all times" · ability `Paranoid Mind`

**The Darkness**
1. Keep the Candlelight up — when it runs out Rising Gloom does not stop
- `KICK` need kick — "Call Darkspawn, quickly" · ability `Call Darkspawn`
- `CD` healer — "Eternal Darkness" · ability `Eternal Darkness`

---

## Cinderbrew Meadery

Brew Master Aldryr → I'pa → Benk Buzzbee → Goldie Baronbottom.

**Brew Master Aldryr**
1. Stay out of the Hot Honey
2. Happy Hour: the Thirsty Patrons' Rowdy Yell is the group damage
- `TANK` tank — "Keg Smash" · ability `Keg Smash`

**I'pa**
1. Stay out of the ichor from the Spouting Stout channel
- `MAGIC` need magic — "Burning Fermentation, immediately" · ability `Burning Fermentation`
- `TANK` tank — "Bottoms Uppercut" · ability `Bottoms Uppercut`

**Benk Buzzbee**
1. Focus the adds — Shredding Sting stacks a bleed
- `KICK` need kick — "Final Sting from the Worker Bees as they get low" · ability `Final Sting`
- `CD` healer — "Fluttering Wing" · ability `Fluttering Wing`

**Goldie Baronbottom**
1. Clear the barrels before 100 energy — Let It Hail! detonates every one still standing
2. Cindering Wounds stacks from the volatile barrels

---

## Operation: Floodgate

Big M.O.M.M.A. → Demolition Duo → Swampface → Geezle Gigazap.

**Big M.O.M.M.A.**
1. Stay out of the Excessive Electrification patches
- `KICK` need kick — "Maximum Distortion on the four Mechadrones — miss it and she caps energy and wipes you" · ability `Maximum Distortion`

**Demolition Duo**
1. Kill them together or Divided Duo enrages the survivor
2. Clear the bombs before the Deflagration timer
- `MAGIC` need magic — "Kinetic Explosive Gel, on the bombs" · ability `Kinetic Explosive Gel`

**Swampface**
1. Razorchoke Vines bind two players at 14 yards — never break the tether
2. Mudslide and the Awaken the Swamp waves come together

**Geezle Gigazap**
1. Lead the Leaping Sparks onto fresh water — electrified water kills
- `TANK` tank — "Thunder Punch" · ability `Thunder Punch`

---

## Eco-Dome Al'dani

Azhiccar → Taah'bat and A'wazj → Soul-Scribe.

**Azhiccar**
1. CC the Frenzied Mites before they reach him during Devour — they heal him badly
2. Don't stack through Toxic Regurgitation

**Taah'bat and A'wazj**
1. Arcane Blitz needs six Warp Strikes to break the immunity
2. Stand clear of the other anchors during Binding Javelin
- `TANK` tank — "Rift Claws" · ability `Rift Claws`

**Soul-Scribe**
1. Collect the souls during Whispers of Fate while avoiding the Ceremonial Dagger frontal
- `CD` healer — "the Dread of the Unknown channel" · ability `Dread of the Unknown`
