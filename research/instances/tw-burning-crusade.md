# Timewalking pool — The Burning Crusade

- **Type:** 6 legacy dungeons, **thin treatment**: bosses and the two or three
  lines that still kill people. No trash.
- **Sources:** Icy Veins *TBC Classic* per-dungeon guides, read 2026-09-08.
  Single source, complete set.
- **Status:** drafted

---

## ⚠ Magisters' Terrace — the name collision, now confirmed

Both boss lists are in hand and they share nothing:

| | Midnight version | TBC version (this pool) |
|---|---|---|
| 1 | Arcanotron | Selin Fireheart |
| 2 | Seranel Sunlash | Vexallus |
| 3 | Gemellus | Priestess Delrissa |
| 4 | Degentrius | Kael'thas Sunstrider |

Same English journal name. `KN.RegisterDungeon` keys on that name, so
registering both silently discards one, and `Tracker.Preview` matches on a
name substring so it would find whichever survived. **The registry has to be
re-keyed on journal instanceID before either of these ships.**

---

## The Blood Furnace

The Maker → Broggok → Keli'dan the Breaker.

**The Maker**
1. Domination mind-controls someone, and it can take the tank — break it or kite them
2. Exploding Beaker knocks you back: mind where you are standing

**Broggok**
1. Stay out of the Slime Spray cone
- `POISON` need poison — "Poison Bolt stacks up fast" · ability `Poison Bolt`

**Keli'dan the Breaker**
1. Burning Nova pulls the whole group in, then Fire Nova goes off — get out the instant you land
2. Shadow Bolt Volley is what kills ranged

---

## Mana-Tombs

Pandemonius → Tavarok → Yor (Heroic only) → Nexus-Prince Shaffar.

**Pandemonius**
1. Stop all damage during Dark Shell or it comes straight back at the party

**Tavarok**
1. Outrange Earthquake
2. Crystal Prison stuns and has to be healed through

**Yor** — min `h`
1. Face Double Breath away from the group

**Nexus-Prince Shaffar**
1. Kill the Ethereal Beacons fast — they keep turning into Apprentices
- `MAGIC` need magic — "Frost Nova off the tank, it wrecks their threat" · ability `Frost Nova`

---

## The Underbog

Hungarfen → Ghaz'an → Swamplord Musel'ek → The Black Stalker.

**Hungarfen**
1. Move away from the mushrooms as they come up
2. Foul Spores at low health is the dangerous window

**Ghaz'an**
1. Stand at his side — Acid Breath and Tail Sweep are both cones

**Swamplord Musel'ek**
1. Stack on him so his ranged attacks cannot land
- `KICK` need kick — "Aimed Shot after the freezing trap" · ability `Aimed Shot`

**The Black Stalker**
1. Spread — Static Charge jumps between players
2. Kill the summons quickly

---

## The Botanica

Commander Sarannis → High Botanist Freywinn → Thorngrin the Tender → Laj →
Warp Splinter.

**Commander Sarannis**
1. Control the Summon Reinforcements adds or let the tank take them
- `KICK` need kick — "the Bloodwarder Mender's heals" · ability `Heal`
- `MAGIC` need magic — "Arcane Resonance off the tank" · ability `Arcane Resonance`

**High Botanist Freywinn**
1. Kill every add he summons — that alone makes the fight trivial
2. Tree Form: three Frayer Protectors die before he is vulnerable again

**Thorngrin the Tender**
1. Melee move out during Hellfire
- `CD` healer — "Hellfire and Sacrifice are both heavy party damage" · ability `Sacrifice`

**Laj**
1. His elemental shifts change what damage type works
- `MAGIC` need magic — "Allergic Reaction, quickly — it spikes tank damage" · ability `Allergic Reaction`

**Warp Splinter**
1. Ranged stay at maximum range for Stomp
- `CD` healer — "Arcane Volley is constant" · ability `Arcane Volley`

---

## The Shattered Halls

Grand Warlock Nethekurse → Blood Guard Porung (Heroic) →
Warbringer O'mrogg → Warchief Kargath Bladefist.

**Grand Warlock Nethekurse**
1. Move out of the fissures immediately
2. Dark Spin at low health hits very hard

**Blood Guard Porung** — min `h`
1. Don't stand in front of him
2. Kill or control the two archers with him

**Warbringer O'mrogg**
1. Phase 2 resets threat — whoever gets it kites while the rest keep going
2. Spread for Burning Maul

**Warchief Kargath Bladefist**
1. Spread as wide as the room allows for Blade Dance
2. Move as one group — splitting up wakes the assassins on the ramps

---

## Magisters' Terrace

Selin Fireheart → Vexallus → Priestess Delrissa → Kael'thas Sunstrider.

**Selin Fireheart**
1. Fel Explosion is AoE every second — the fight is a race
- `KICK` need kick — "the drain channels, or he heals off them" · ability `Drain Life`

**Vexallus**
1. Overload at 20% is the big AoE
2. Killed adds leave a stacking debuff — pace them
- `MAGIC` need magic — "Arcane Shock" · ability `Arcane Shock`

**Priestess Delrissa**
1. **Her four adds are a random draw each run** — read them before committing
- `KICK` need kick — "the healers among her adds" · ability `Heal`
- `FEAR` need fear — "Psychic Scream" · ability `Psychic Scream`

**Kael'thas Sunstrider**
1. Flame Strike is a delayed explosion — get off it
2. Gravity Lapse at 50% is unavoidable damage: save cooldowns
- `KICK` need kick — "Fireball and Pyroblast, consistently" · ability `Pyroblast`

---

## Randomised content, again

Priestess Delrissa draws four adds at random per run, the same way End Time
draws two of four shrine bosses. Three cases now (with Eye of Azshara's free
boss order). A note that assumes a fixed line-up is wrong for all three.
