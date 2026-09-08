# Scholomance - MoP Classic

- **Journal name:** Scholomance
- **Type:** dungeon, 5 bosses
- **Source:** Icy Veins *Scholomance Dungeon Guide* (Mists of Pandaria Classic
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

Boss order: Instructor Chillheart -> Jandice Barov -> Rattlegore ->
Lilian Voss -> Darkmaster Gandling.

## 1. Instructor Chillheart

**core**
1. Stay ahead of the Ice Wall - touching it kills outright
2. Phase 2: break the Phylactery, and dodge the Arcane Bombs

## 2. Jandice Barov

**core**
1. Mark the real Jandice on the pull and only ever hit the marked target - the images hit back

**notes**
- (no role) - "Ranged and healers at max range for Gravity Flux" - ability `Gravity Flux`

## 3. Rattlegore

**core**
1. Click the Bone Piles around the room to keep Bone Armor up
2. The tank kites once Rusting stacks get high

**notes**
- `TANK` tank - "Rusting adds 25% damage per melee hit he lands: kite him until it drops off" - ability `Rusting`

## 4. Lilian Voss

**core**
1. Death's Grasp pulls everyone in and leaves Dark Blaze - spread before it drops
2. The Fixate Anger target kites the soul away from the group

## 5. Darkmaster Gandling

**core**
1. Kill the Failed Students through the Rise! channel - he takes 50% less damage while it runs
2. Harsh Lesson ports someone to a side room: clear it and come back

**notes**
- `MAGIC` need magic - "Immolate, immediately" - ability `Immolate`
- `MAGIC` need magic - "in the side room, dispel Explosive Pain off the Fresh Test Subjects to clear it" - ability `Explosive Pain`
- `TANK` tank - "Incinerate comes fast and hard: keep mitigation rolling through it" - ability `Incinerate`

---

## Second source, 2026-09-08

**Confirms:** the Ice Wall as an instant kill on contact; Jandice cloning at
66% and 33%; Rattlegore's Bone Spike against Bone Armor stacks; Lilian's
Death's Grasp pulling everyone in and the 8-second Dark Blaze spread;
Gandling's Immolate dispelled off the tank and the Study Room teleport.

**Adds:**
- Bone Spike specifically punishes players **without** Bone Armor — the line
  should be about keeping the buff up, not about dodging.
- Jandice's Wondrous Rapidity comes in frontal arcs.
- There are six Study Rooms.
