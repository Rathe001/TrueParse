# Timewalking pool — Battle for Azeroth

- **Type:** 6 legacy dungeons, **thin treatment**: bosses and the two or three
  lines that still kill people. No trash.
- **Sources:** Icy Veins per-dungeon guides for Atal'Dazar, Freehold and
  Waycrest Manor; MMO-Champion for Shrine of the Storm (Icy Veins has no
  reachable page for it). All read 2026-09-08. Single source each.
- **Status:** drafted (4 of 6; Kings' Rest and Temple of Sethraliss already
  shipped)

**Kings' Rest and Temple of Sethraliss are already registered** in
`Notes/Season2.lua` — both are in the Midnight Season 2 keystone pool as well
as this Timewalking pool, so one registration serves both. Their trash notes
simply stop rendering outside a key.

---

## Atal'Dazar

Priestess Alun'za → Rezan → Vol'kaal → Yazma.

**Priestess Alun'za**
1. Soak Tainted Blood during Transfusion with a defensive up
2. Keep the Spirits of Gold away from the Tainted Blood pools
- `MAGIC` need magic — "Molten Gold, quickly" · ability `Molten Gold`

**Rezan**
1. Pursuit fixates, and it ends in Devour — run
2. Don't step on a Pile of Bones, it wakes the raptors
- `TANK` tank — "Serrated Teeth bleed: a real cooldown" · ability `Serrated Teeth`

**Vol'kaal**
1. Kill the Soulspawns before they reach him and feed Soulfeast
- `KICK` need kick — "Noxious Stench, fast, to keep the stacks down" · ability `Noxious Stench`
- `DISEASE` need disease — "Lingering Nausea, before it stacks" · ability `Lingering Nausea`

**Yazma**
1. Stay out of the Echoing Shadra pools — Shadowy Remains kills
2. Kill the Soulspawns before they reach her; be healthy for Soul Link
- `KICK` need kick — "Wracking Pain, or the party eats it" · ability `Wracking Pain`

---

## Freehold

Skycap'n Kragg → Council o' Captains → Trothak → Harlan Sweete.

**Skycap'n Kragg**
1. Dodge the charge in phase one and the dive bombs in phase two
- `TANK` tank — "the pistol shots are unavoidable: defensives" · ability `Pistol Shot`

**Council o' Captains** (Captain Eudora and Captain Raoul)
1. Move out of the grapeshot spreads
2. Destroy the barrels before they go off

**Trothak**
1. Kite the sharks onto the chum to neutralise them
2. Don't be near a shark when it rearms
- `TANK` tank — "the ripper punch bleed: defensives" · ability `Ripper Punch`

**Harlan Sweete**
1. CC the incoming grenadiers before the bombs land
- `TANK` tank — "the man-o-war phase gives him 100% attack speed" · ability `Man-o-War`
- `CD` healer — "Swiftwind Saber is constant incoming damage" · ability `Swiftwind Saber`

---

## Shrine of the Storm

Aqu'sirr → Tidesage Council → Lord Stormsong → Vol'zith the Whisperer.

**Aqu'sirr**
1. Surging Rush and Undertow both knock you back — mind the edges
2. Grasp from the Depths roots: kill the tentacles to free people
3. He splits into Aqualings at 50%, and they copy his abilities
- `MAGIC` need magic — "Choking Brine" · ability `Choking Brine`

**Tidesage Council**
1. Don't interrupt during Blessing of the Tempest — it triggers Blowback
- `KICK` need kick — "Slicing Blast, but never through Blessing of the Tempest" · ability `Slicing Blast`
- `TANK` tank — "Hindering Cleave" · ability `Hindering Cleave`

**Lord Stormsong**
1. Stay out of the Waken the Void explosions — unless you are the one mind-controlled
- `KICK` need kick — "Void Bolt" · ability `Void Bolt`

**Vol'zith the Whisperer**
1. Grasp of the Sunken City: kill the denizens to get out of the drowning phase
2. Move him out of the pools he drops
- `MAGIC` need magic — "Whispers of Power" · ability `Whispers of Power`

---

## Waycrest Manor

Heartsbane Triad → Soulbound Goliath → Raal the Gluttonous →
Lord and Lady Waycrest → Gorak Tul.

**Heartsbane Triad**
1. Soul Manipulation charms someone: damage them to break it
2. Manage the energy or Dire Ritual wipes you
- `KICK` need kick — "Soul Bolt, Ruinous Bolt and Bramble Bolt — especially on the focused sister — and Soul Manipulation" · ability `Soul Manipulation`
- `CURSE` need curse — "Unstable Runic Mark" · ability `Unstable Runic Mark`
- `BLEED` need bleed — "Jagged Nettles" · ability `Jagged Nettles`

**Soulbound Goliath**
1. Reset Soul Harvest stacks by moving him into the Wildfire — but never during Soul Thorns
2. Burning Souls on top of Burning Brush is what actually kills

**Raal the Gluttonous**
1. Kill the Wasting Servants before they reach him — Gluttonous Bile cannot be dispelled
2. Rotten Expulsion is a frontal and it spawns adds

**Lord and Lady Waycrest**
1. Virulent Pathogen leaves Contagious Remnants on the floor
2. Stay out of the Discordant Cadenza puddles
- `DISEASE` need disease — "Virulent Pathogen" · ability `Virulent Pathogen`

**Gorak Tul**
1. Kill the Deathtouched Slavers and burn the corpses with Alchemical Fire before he finishes resurrecting them
- `KICK` need kick — "Death Lens on the Slavers" · ability `Death Lens`
- `CD` healer — "Dread Essence" · ability `Dread Essence`

---

## Already shipped

- **Kings' Rest** — `Notes/Season2.lua`
- **Temple of Sethraliss** — `Notes/Season2.lua`
