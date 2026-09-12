# The Tidebound Grotto — retail (Midnight 12.1)

- **Journal name:** The Tidebound Grotto
- **Type:** raid, 1 boss (a lair). Registered on its own, not as part of The
  Venomous Abyss (Josh 2026-09-12). WCL zone 53 folds her into the Abyss,
  which is why it reports 9 encounters while every guide says "8 bosses".
- **Where:** under the water at the Wreck of Gral's Belly, south Coiled Isle.
  Wowhead zone 16671.
- **Sources:** Method's *Mythic* Nymrissa guide (filed under
  `method.gg/guides/the-tidebound-grotto/nymrissa-wavecaller`; the old 404 was
  the Abyss slug) and MythicTrap's Heroic guide, both read 2026-09-12.
  Reconciled. Tiebreak on the tank abilities from Wowhead's NPC page and
  warcraft.wiki.gg.
- **Status:** drafted in `Notes/Season2.lua`, not yet shipped

## Nymrissa Wavecaller

Single phase. Wavecaller's Might is a stacking soft enrage (Method); Unending
Tides is the hard enrage, 6 minutes per MythicTrap (Method gives no timer).

**Tank abilities, settled by a third source.** Method names the tank hit Water
Jet, MythicTrap names it Iceblade Flurry. Wowhead's NPC page lists both, and
warcraft.wiki.gg marks Water Jet **Mythic only**, so the two guides describe
different abilities rather than disagreeing. Iceblade Flurry is the tank hit
on every difficulty; Mythic adds Water Jet, which pushes the tank and washes
away the Lingering Frost patches.

**core**
1. Kill the murlocs before they reach the Alluring Bubble
2. Swirling Whirlpools: stack in the one gap before they surge to the bubble
3. Soak every Frost Orb from Chilling Frost, or it shatters on the raid

**notes**
- `TANK` tank — "Iceblade Flurry: defensive for each one, it raises the damage of the next" · ability `Iceblade Flurry` · *MythicTrap*
- `TANK` tank — "Water Jet: swap before its stacks get dangerous, and aim it at the icy patches" · ability `Water Jet` · *Method* (Mythic)
- `CD` healer — "Abyssal Rain, and every Pop! when a whirlpool breaks the bubble" · ability `Abyssal Rain` · *both*
- (no role) — "Kill any Bubblefin Berserker on sight: it pulses raid damage until it dies" · ability `Pulsing Tides` · *both* (MythicTrap: empowered murlocs deal raid damage; Method: kill on sight)
- (no role) — "Kill the Bubblefin Frostscale first: its Waterfog Shield protects the murlocs around it" · ability `Waterfog Shield` · *Method* (Mythic)
- (no role) — "Stand where Pop! cannot knock you into the water, or the sharks eat you" · ability `Pop!` · *Method*

No lust line: neither source calls one.

## Open questions

- **Drenched.** A boost-site guide says Abyssal Rain's Drenched "needs to be
  cleansed as soon as possible"; neither Method nor MythicTrap mentions a
  dispel, and no source gives its school. Not written.
- **The wiki's ability list is stale.** warcraft.wiki.gg names Water Flurry,
  Tidepiercer's Rush, Frost Barrage and Drifting Globules, which match no
  guide; it looks like PTR text. Used only for the Water Jet difficulty.
