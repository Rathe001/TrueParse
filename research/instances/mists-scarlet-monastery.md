# Scarlet Monastery - MoP Classic

- **Journal name:** Scarlet Monastery
- **Type:** dungeon, 3 bosses
- **Source:** Icy Veins *Scarlet Monastery Dungeon Guide* (Mists of Pandaria Classic
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

Boss order: Thalnos the Soulrender -> Brother Korloff ->
High Inquisitor Whitemane.

## 1. Thalnos the Soulrender

**core**
1. Kill the Empowering Spirits before they reach a fallen crusader - one that lands becomes an Empowered Zombie
2. Kill the raised Scarlet Crusaders quickly, they pile up

**notes**
- `KICK` need kick - "Spirit Gale" - ability `Spirit Gale`
- dispel, **type unstated** - "Evict Soul" - ability `Evict Soul`. The guide says
  it "requires dispel" without naming a school. Do not tag it until confirmed.

## 2. Brother Korloff

**core**
1. Keep moving - Firestorm Kick is fully avoidable, and Scorched Earth trails fire behind him from 50%
2. Stay out of the Blazing Fists front

**notes**
- `CD` healer - "Rising Flame adds 10% fire damage every 5 seconds: the end of the fight is the dangerous part" - ability `Rising Flame`

## 3. High Inquisitor Whitemane

**core**
1. Dodge Commander Durand's Dashing Strike
2. Interrupt Mass Resurrection every single time - a completed cast is the wipe

**notes**
- `KICK` need kick - "Mass Resurrection, without fail" - ability `Mass Resurrection`
- `PURGE` need purge - "Power Word: Shield" - ability `Power Word: Shield`

---

## Second source, 2026-09-08

**Confirms:** Thalnos raising multiple Scarlet Crusaders with Raise Fallen
Crusader; Whitemane's Mass Resurrection as a guaranteed wipe if it completes,
so it is interrupted every time without exception.

**Still unresolved:** Evict Soul is described as needing a dispel by the first
source and is not mentioned by the second. No school named by either, so no
dispel tag — it cannot be routed to a spec without one.
