# Shado-Pan Monastery - MoP Classic

- **Journal name:** Shado-Pan Monastery
- **Type:** dungeon, 4 bosses
- **Source:** Icy Veins *Shado-Pan Monastery Dungeon Guide* (Mists of Pandaria Classic
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

Boss order: Gu Cloudstrike -> Master Snowdrift -> Sha of Violence -> Taran Zhu.

## 1. Gu Cloudstrike

**core**
1. Spread out - Invoke Lightning chains between you
2. Phase 2: the healer pours big heals into one target to break Magnetic Shroud and free the party

**notes**
- `TANK` tank - "Point the Azure Serpent's Lightning Breath away from the group" - ability `Lightning Breath`
- `CD` healer - "Magnetic Shroud absorbs healing: one target, big casts" - ability `Magnetic Shroud`

## 2. Master Snowdrift

**core**
1. Out of the Fists of Fury frontal, and back off for Tornado Kick
2. Phase 3: the fixated player kites Tornado Slam
3. Melee stop attacking during Parry Stance - it reflects and stuns

## 3. Sha of Violence

**core**
1. Kill the Lesser Volatile Energy adds from Sha Spike as they appear
2. Keep casting: every spell takes 5 seconds off Smoke Blades

**notes**
- `CURSE` need curse - "Disorienting Smash off the tank" - ability `Disorienting Smash`

## 4. Taran Zhu

**core**
1. Ring of Malice only hurts on the edge - be all the way in or all the way out
2. Watch the Hatred bar and Meditate before Haze of Hate lands
3. Kill the Gripping Hatred adds fast, they pull constantly

**notes**
- `KICK` need kick - "Rising Hate, every cast" - ability `Rising Hate`
- `TANK` tank - "Sha Blast knocks you out through Ring of Malice: keep your back to a pillar" - ability `Sha Blast`

---

## Second source, 2026-09-08

**Confirms:** the Rising Hate interrupt chain, Ring of Malice, killing
Gripping Hatred on sight, Gu's Lightning Breath and Magnetic Shroud.

**Sharpens the Taran Zhu line with real numbers:** Haze of Hate reaches 100
stacks, at which point your hit chance is 0% and your healing is cut 75%.
Meditate should be used around 50-70, not at the cap.

**Useful negative:** Heroic changes only health and damage here — the
mechanics are identical to Normal. Nothing in this dungeon needs a `min` gate.
