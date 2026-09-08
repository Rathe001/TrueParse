# Scarlet Halls - MoP Classic

- **Journal name:** Scarlet Halls
- **Type:** dungeon, 3 bosses
- **Source:** Icy Veins *Scarlet Halls Dungeon Guide* (Mists of Pandaria Classic
  section), read 2026-09-08, plus a second source (below).
- **Status:** drafted, **two sources reconciled**

> **Sourcing.** Primary: Icy Veins' MoP Classic guide. Second source added
> 2026-09-08 from the MoP Classic guide ecosystem (Wowhead MoP Classic,
> Skycoach, ConquestCapped and Ten Ton Hammer, via aggregated search) — the
> Wowhead MoP Classic pages themselves do not render for a fetch, so the
> second source is an aggregate rather than one page read end to end. What it
> confirmed, corrected and failed to corroborate is recorded at the bottom of
> this file.

> **Client caveat.** `Notes/Classes.lua` is a *retail* capability table. MoP
> Classic specs have different tools - every healer has an interrupt, curse and
> poison cleansing are split differently, and the retail removals of healer
> interrupts do not apply. A Mists capability table is a prerequisite for
> shipping any of this. See `research/INVENTORY.md`.

Boss order: Houndmaster Braun -> Armsmaster Harlan -> Flameweaver Koegler.

## 1. Houndmaster Braun

**core**
1. Spread 5 yards - Piercing Throw and Death Blossom both hit everything in between
2. AoE the Obedient Hounds down as they are called at 90, 80, 70 and 60%

**notes**
- `CD` healer - "the Bloody Mess bleed stacks, and Bloody Rage at 50%" - ability `Bloody Mess`
- `TANK` tank - "Kite the hounds rather than hold them all - the meat buckets pull them off you" - ability `Call Dog`

Bloody Rage is described as an enrage. Whether it can be soothed is not stated,
so no `SOOTHE` line is written.

## 2. Armsmaster Harlan

**core**
1. Keep Dragon's Reach pointed away, it cleaves a long way
2. When he Heroic Leaps to the middle and starts Blades of Light, get out

**notes**
- `PURGE` need purge - "Berserker Rage from 50% - a purge strips ten stacks" - ability `Berserker Rage`
- `TANK` tank - "Lead the whirlwind path, and keep Dragon's Reach pointed away the whole fight" - ability `Dragon's Reach`

## 3. Flameweaver Koegler

**core**
1. Interrupt him constantly - both Fireball Volley and Pyroblast can be stopped
2. Move around behind him through Greater Dragon's Breath
3. Block the Book Burner projectile with your body before it reaches the shelf

**notes**
- `KICK` need kick - "Fireball Volley and Pyroblast" - ability `Pyroblast`
- `TANK` tank - "Face him away: the breath cleaves everything in front" - ability `Greater Dragon's Breath`

---

## Second source, 2026-09-08

**Confirms:** Harlan's Heroic Leap into Blades of Light and the long-range
Dragon's Reach kept faced away; Koegler's Greater Dragon's Breath rotating on
the spot and disorienting; the Book Burner projectile aimed at a bookshelf.

**Puts numbers on Braun's enrage:** Bloody Rage at 50% is +50% attack speed
and +25% damage. Still **no source says whether it can be soothed**, so the
`SOOTHE` line stays unwritten — with numbers that big it is worth resolving.
