# Mogu'shan Palace - MoP Classic

- **Journal name:** Mogu'shan Palace
- **Type:** dungeon, 3 bosses
- **Source:** Icy Veins *Mogu'shan Palace Dungeon Guide* (Mists of Pandaria Classic
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

Boss order: Trial of the King -> Gekkan -> Xin the Weaponmaster.

## 1. Trial of the King

Three sub-encounters in sequence.

**core**
1. Kuai the Brute: dodge the shockwaves, and kill him before his quilen Mu'Shiba
2. Ming the Cunning: stay out of the Whirling Dervish and out of the Magnetic Field
3. Haiyan the Unstoppable: 5 yards apart for Conflagrate, then back together to split the Meteor

**notes**
- `TANK` tank - "Face Kuai away: Shockwave throws anyone in front of him into the air" - ability `Shockwave`
- `TANK` tank - "Haiyan's Traumatic Blow cuts your healing by half for 5 seconds - defensive, don't rely on the healer" - ability `Traumatic Blow`
- `CD` healer - "Traumatic Blow on the tank: pre-heal, you cannot heal through it" - ability `Traumatic Blow`

## 2. Gekkan

**core**
1. Kill order is Ironhide, Hexxer, Skulker, Oracle - every add that dies gives Gekkan haste and damage taken
2. Pull the pack to a pillar and line-of-sight their casts

**notes**
- `KICK` need kick - "Iron Protector on the Ironhide - it cuts 70% of your damage" - ability `Iron Protector`
- `KICK` need kick - "Cleansing Flame on the Oracle, every cast" - ability `Cleansing Flame`
- `CURSE` need curse - "Hex of Lethargy off the casters" - ability `Hex of Lethargy`

## 3. Xin the Weaponmaster

**core**
1. Ground Slam: the tank moves corner to corner on every cast
2. Dodge the room traps - Circle of Flame, the Whirlwinding Axes, and the Blade Trap from 66%

**notes**
- `CD` healer - "Inciting Roar cannot be avoided, and Death From Above starts at 33%" - ability `Inciting Roar`
- `TANK` tank - "Ground Slam strips armour from everyone it hits: hold him in the corner by the entrance" - ability `Ground Slam`

---

## Second source, 2026-09-08

**Confirms:** three encounters; Gekkan's Reckless Inspiration stacking per
bodyguard killed; Xin as a movement fight with no complex mechanics.

**Sharpens the Ironhide line, and it matters:** Iron Protector reduces damage
taken by allies within 5 yards by 70%, and **the mob shows no interrupt
indicator even though a standard interrupt stops it**. That is exactly the
kind of thing a note earns its place on — a player who trusts the UI will
never try.

**Not corroborated:** Hex of Lethargy on the Glintrok Hexxer. The second
source does not mention it at all. The `CURSE` line stays single-sourced —
confirm before shipping.
