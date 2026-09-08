# Stormstout Brewery - MoP Classic

- **Journal name:** Stormstout Brewery
- **Type:** dungeon, 3 bosses
- **Source:** Icy Veins *Stormstout Brewery Dungeon Guide* (Mists of Pandaria Classic
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

Boss order: Ook-Ook -> Hoptallus -> Yan-Zhu the Uncasked.

Icy Veins notes there is no mechanical difference between Normal and Heroic
here - only health and damage - so nothing in this dungeon needs a `min` gate.

## 1. Ook-Ook

**core**
1. Ride the rolling barrels into him at 90%, 60% and 30%
2. Get behind him for Ground Pound

**notes**
- `CD` healer - "the barrel phases" - ability `Ground Pound`

## 2. Hoptallus

**core**
1. Circle him so the rotating Carrot Breath never catches you
2. Furlwind fixates one player and spins - if it picks you, run until it stops
3. When the virmen wave arrives, stack on the tank so they converge in one place

## 3. Yan-Zhu the Uncasked

**core**
1. Clear the three Alemental waves first - which ones you get decides his three abilities
2. Bloat means spread apart; Blackout Brew means keep moving and jump it off
3. Break the Bubble Shields, or block the healing beam from the Yeasty adds on Ferment

**notes**
- (no role) - "Carbonation: click a Fizzy Bubble to get airborne" - ability `Carbonation`
- (no role) - "Wall of Suds: use the Sudsy buff to jump it" - ability `Wall of Suds`

---

## Second source, 2026-09-08

**Confirms:** Carrot Breath as a channelled frontal that rotates a full 360°;
Wall of Suds cleared with the Sudsy jump buff; Yan-Zhu's three abilities being
set by which Alementals you fought.

**CONFLICT RESOLVED 2026-09-08.** Icy Veins said ranged and healers keep their
distance from Furlwind; two later sources both say it *fixates one player and
spins*, and the answer is for that player to run. Two against one, and the
fixate version explains the mechanic better - the line is now written that
way and Icy Veins is treated as wrong here.

**Adds:** Hoptallus summons waves of virmen; the group stacks on the tank so
the adds converge in one place.
