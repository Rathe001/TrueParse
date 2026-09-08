# Temple of the Jade Serpent - MoP Classic

- **Journal name:** Temple of the Jade Serpent
- **Type:** dungeon, 4 bosses
- **Source:** Icy Veins *Temple of the Jade Serpent Dungeon Guide* (Mists of Pandaria Classic
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

Boss order: Wise Mari -> Lorewalker Stonestep -> Liu Flameheart -> Sha of Doubt.

## 1. Wise Mari

**core**
1. Mari is immune until the four Corrupt Living Water elementals are dead - kill them away from the group
2. Stay out of the corrupted water on the floor
3. Phase 2: circle around behind him, off the Wash Away jet

**notes**
- `TANK` tank - "Hold the water elementals away from the group" - ability `Corrupt Living Water`
- `CD` healer - "the Hydrolance bursts" - ability `Hydrolance`

## 2. Lorewalker Stonestep

Two possible encounters; the corrupted scroll decides which.

**core**
1. Strife and Peril: swap targets constantly - whichever you keep hitting reaches Ultimate Power and goes immune
2. The other scroll: burn the Five Suns, then tank and interrupt the Haunting Sha each one leaves

**notes**
- `KICK` need kick - "the Haunting Sha" - ability `Haunting Sha`

## 3. Liu Flameheart

**core**
1. Spread out and stay off the Serpent Wave lava
2. At 30% she manifests as Yu'lon - keep out of the Jade Fire pools

**notes**
- `MAGIC` need magic - "Serpent Strike off the tank, straight away" - ability `Serpent Strike`
- `TANK` tank - "From 70% Jade Serpent Strike adds a healing absorb that CANNOT be dispelled, and the kick knocks you back: defensives up" - ability `Jade Serpent Strike`

## 4. Sha of Doubt

**core**
1. Bounds of Reality spawns a Figment of Doubt for every player - kill yours fast, they heal the boss
2. Stack up so the Figments can be cleaved

**notes**
- `MAGIC` need magic - "Touch of Nothingness, immediately" - ability `Touch of Nothingness`

---

## Second source, 2026-09-08

**Confirms:** Stonestep's Intensity / Dissipation / Ultimate Power loop
exactly; Touch of Nothingness dispelled on sight; the Figment of Doubt clone
per player; circling behind Wise Mari for Wash Away.

**Adds two lines the first source missed:**
- `KICK` need kick — "Hydrolance — interrupt it, or CC him" · ability `Hydrolance`
- `STUN` need stun — "Corrupt Droplets can't be interrupted: stun and burn them before the Splash AoEs overlap" · ability `Corrupt Droplets`

**Refines Liu Flameheart:** the dispel is on the tank for the *red* fire
strike; the *green* one wants big single-target healing instead. Worth
splitting into two lines when this is written.
