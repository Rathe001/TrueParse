# Mogu'shan Vaults — MoP Classic

- **Journal name:** Mogu'shan Vaults
- **Type:** raid, 6 bosses. **Boss-only** — no trash, per Josh 2026-09-08.
- **Source:** Icy Veins MoP Classic per-boss encounter guides, read 2026-09-08.
  Single source; see the caveat in any `mists-*` dungeon file.
- **Status:** drafted, needs a second source

Boss order: The Stone Guard → Feng the Accursed → Gara'jal the Spiritbinder →
The Spirit Kings → Elegon → Will of the Emperor.

---

## 1. The Stone Guard

**core**
1. Keep all four Guardians stacked and cleave them down together
2. When Petrification lands, let the matching Guardian Overload to clear it before the raid turns to stone
3. Move out of the Amethyst Pools and away from the Cobalt Mines

**notes**
- `TANK` tank — "Sustained damage here is among the highest in the tier: rotate mitigation constantly" · ability `Jade Shards`
- `CD` healer — "the Overloads — four schools, and together they are the largest hit in the fight" · ability `Overload`
- (no role) — "Jasper Chains links two of you: stay close, distance makes it worse" · ability `Jasper Chains`
- (no role) — "Activate the Living Crystals for the floor damage buff" · ability `Living Crystals`

---

## 2. Feng the Accursed

Four phases; he takes a different spirit weapon in each.

**core**
1. The tank parks him next to the weapon you want him to pick up at each transition
2. Use the Nullification Barrier and Shroud of Reversal crystals on the big casts
3. Drop Wildfire Spark well away from the raid

**notes**
- `KICK` need kick — "Epicenter, in the last phase" · ability `Epicenter`
- `TANK` tank — "Swap every two stacks — Arcane Shock, Flaming Spear, Shadowburn, Lightning Lash" · ability `Arcane Shock`
- `CD` healer — "Arcane Velocity, Draw Flame and Epicenter are all unavoidable" · ability `Draw Flame`
- (no role) min `h` — "Kill the soul fragments before they reach the Siphoning Shield" · ability `Siphoning Shield`

---

## 3. Gara'jal the Spiritbinder

**core**
1. Rotate a Spirit Realm team through the totems — heal to 90% inside 30 seconds to get back out
2. In the Spirit Realm kill only the Shadowy Minions; ignore the Severers of Souls
3. Voodoo Dolls links the tank and five others, and they share every hit he lands

**notes**
- `TANK` tank — "Banishment throws you into the Spirit Realm: stay in the top two on threat through the swaps" · ability `Banishment`
- `CD` healer — "Voodoo Dolls, and the Frenzy from 20%" · ability `Voodoo Dolls`

The guide states explicitly that this encounter has no interruptible casts and
no dispellable debuffs.

---

## 4. The Spirit Kings

Four kings in sequence; each wakes the next at 30%, so there is always a brief
overlap.

**core**
1. Qiang: stack to split the Massive Attacks, and run through him to dodge Annihilate
2. Zian: interrupt every Shadow Blast, and spread so Charged Shadows cannot bounce
3. Meng: Maddening Shout is removed by damaging each other — and stop attacking through Cowardice

**notes**
- `MASSDISPEL` **new capability** min `h` — "Qiang's Impervious Shield: Mass Dispel it, and everybody stops attacking until it is gone" · ability `Impervious Shield`
- `KICK` need kick — "Zian's Shadow Blast, every cast" · ability `Shadow Blast`
- `MAGIC` need magic, min `h` — "Zian's Shield of Darkness: every stack off, and nobody attacks until it is clear — each hit is 300k to the raid" · ability `Shield of Darkness`
- `SOOTHE` need soothe, min `h` — "Meng's Delirious" · ability `Delirious`
- `TANK` tank — "Face every king away from the raid and pick up the adds - and remember the dead kings' abilities keep going" · ability `Flanking Orders`
- (no role) — "Subetai: spread 8 yards, and kill the Pinning Arrows off whoever they stun" · ability `Rain of Arrows`
- (no role) — "Subetai's Volley fires three times in one direction and the third one kills" · ability `Volley`

---

## 5. Elegon

**core**
1. Watch your Overcharged stacks and step to the Outer Circle to reset them
2. Total Annihilation when an add dies needs at least three soakers
3. Phase 3: split evenly and destroy all six Empyreal Focus engines

**notes**
- `MAGIC` need magic — "Closed Circuit from the Celestial Protectors — it halves healing received" · ability `Closed Circuit`
- `TANK` tank — "Celestial Breath: defensive" · ability `Celestial Breath`
- `CD` healer — "the Total Annihilation soaks, and Unstable Energy through phase 3" · ability `Total Annihilation`
- (no role) — "Radiating Energies kills anyone left in the Outer Circle: stack up" · ability `Radiating Energies`

---

## 6. Will of the Emperor

**core**
1. Dodge all ten hits of Devastating Combo — the Arc stacks an armour break and the Stomp stuns
2. Ranged take Emperor's Strength, melee take Emperor's Courage, and CC the Emperor's Rage fixates
3. Thirteen-minute hard enrage

**notes**
- `TANK` tank — "Melee damage here is extreme: rotate cooldowns between every combo" · ability `Devastating Combo`
- (no role) — "Emperor's Courage blocks the front with Half Plate: hit it from behind, and slow it" · ability `Half Plate`
- (no role) min `h` — "Titan Sparks: pop an immunity to clear a group rather than soaking one at a time" · ability `Titan Spark`

---

## Mass Dispel — three cases now, and they are not the same

This raid alone produces two more Mass Dispel situations, and they differ in a
way the capability design has to respect:

- **Qiang's Impervious Shield** (Heroic) — Mass Dispel *specifically*. This is
  the same shape as Lightblinded Vanguard's Divine Shield: only a Priest with
  Mass Dispel can act, so only they should see the line.
- **Elegon's Closed Circuit** — an ordinary magic dispel works; the guide only
  says Mass Dispel is *preferable* because it is efficient. This one stays a
  plain `MAGIC` line, or every dispeller loses a job they can do.
- **Zian's Shield of Darkness** (Heroic) — 11 stacks that must come off fast.
  The guide does not say Mass Dispel is required, so it stays `MAGIC`.

So the new capability must be used only where Mass Dispel is the *only*
answer, not everywhere it happens to be the best tool. Two of the three cases
here would be mis-tagged if the rule were "Mass Dispel is mentioned".
