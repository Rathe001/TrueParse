# Sporefall — retail (Midnight, launch tier bonus raid)

- **Journal name:** Sporefall
- **Type:** raid, 1 boss (Rotmire). In Harandar, near the Grudge Pit delve.
  Added in patch 12.0.7. Flex composition on every difficulty including
  Mythic — the first raid in the game to do that.
- **Sources:** Icy Veins *Rotmire Raid Guide* and wow.gg *Sporefall Raid
  Guide*, both read 2026-09-08. Reconciled.
- **Status:** drafted

The addon already ships `Data/Percentiles_Sporefall.lua`,
`Data/KillTimes_Sporefall.lua` and `Data/Totals_Sporefall.lua` for this
encounter, which is how the raid was found — it does not appear in the wiki's
raid list.

---

## Rotmire

Single phase on a loop. Bursting Pustules stacks all fight and is the soft
enrage; Fungal Bloom at 100 energy is the cycle marker.

**core**
1. Drag the fixating Shroomlings under the boss and AoE them down together
2. Mind where corpses fall — Fungal Bloom raises them as Bursting Shrooms
3. Drop Festering Vines at the edges: the ground it leaves is permanent

**notes**
- `KICK` need kick, min `h` — "Poison Burst from the Sporecaps" · ability `Poison Burst` · *both*
- `TANK` tank — "Putrid Fist: swap every cast, it stacks physical vulnerability and knocks you up" · ability `Putrid Fist` · *both*
- `CD` healer — "Bursting Pustules climbs all fight, and every Fungal Bloom" · ability `Fungal Bloom` · *both*
- (no role) — "Stay out of the Awaken Fungi circles, they knock back as the adds come up" · ability `Awaken Fungi` · *both*
- (no role) min `m` — "Keep the different corpse types 10 yards apart or Cross Fertilization spawns a Doom Shroom" · ability `Cross Fertilization` · *both*

This encounter is a good first test of the `min` field on raid content: the
Sporecap interrupt only exists from Heroic up, and Cross Fertilization is
Mythic-only. Both sources agree on those gates, so the journal's
difficulty filtering should confirm rather than contradict them.

---

## Notes on sourcing

Both sources agree on every mechanic; the only difference is naming emphasis
(Icy Veins leads with Bursting Pustules as the soft enrage, wow.gg with
Fungal Bloom as the cycle). No conflicts.

Neither source gives a lust call. Not written.
