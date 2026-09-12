# The Venomous Abyss — retail (Midnight 12.1)

- **Journal name:** The Venomous Abyss
- **Type:** raid, 8 bosses. WCL zone 53 reports a 9th encounter, Nymrissa
  Wavecaller, who is a separate one-boss raid: see
  `retail-the-tidebound-grotto.md`
- **Sources:** Method *The Venomous Abyss* per-boss Heroic guides and
  MythicTrap *Venomous Abyss* per-boss guides, both read 2026-09-08.
  Reconciled.
- **Status:** shipped in 2.16.5

## Encounter order

1. **Nek'zali the Soulcoiler** — opener
2. Two wings, either first:
   - **Entombed Sentinels** → **Vashnik the Malignant**
   - **The Lost Explorers** → **Sszorak**
3. **The Twin Fangs** — opens once both wings are down
4. **The Coiled Altar**
5. **Ula'tek** — end boss

## Schema gap this raid exposes

Raid difficulty IDs are **not** in `KN.DIFF_BY_ID` (`Notes/Core.lua`), which
only maps 1/2/23/8 and the two Timewalking ids. Raids report 17 = LFR,
14 = Normal, 15 = Heroic, 16 = Mythic. Raid notes cannot gate by difficulty
until those are added, and LFR needs a rank below `n`.

Raid bosses also carry far more mechanics than dungeon bosses. The "one to
three core lines" rule holds for the *group-critical* lines, but several of
these fights have four or five things that genuinely wipe a pull. Flagging as
a design question rather than quietly widening the rule.

---

## 1. Nek'zali the Soulcoiler

Two phases with an intermission at 50%. The boss gains energy from adds
reaching the Soulcoil Well and from each Soulcoil Ignition; full energy is
Uncoiled Rage, a wipe.

**core**
1. Break the shields on the Restless Amani and kill them before they reach the Well
2. Essence Rend: get dispelled at the edge — the puddle stays where it drops
3. At 50% burn the corpses with Hungering Pyre, then kill both Echoes of Jawae

**notes**
- `LUST` need lust — "phase 2, before the energy caps" · ability `Uncoiling` · *both*
- `MAGIC` need magic — "Essence Rend, and only at the edge" · ability `Essence Rend` · *both*
- `TANK` tank — "Hollowing Strikes: swap around 5-6 stacks and let it expire; stay 30 yards out for Possession Barrage" · ability `Hollowing Strikes` · *both*
- `CD` healer — "Soulcoil Ignition, and the Uncoiling rot all through phase 2" · ability `Soulcoil Ignition` · *both*
- (no role) — "Stand behind the boss for Possession Barrage" · ability `Possession Barrage` · *MythicTrap*

---

## 2. Entombed Sentinels

Council: **Breath of Ula'tek** (acid) and **Blood of Ula'tek** (blood).

**core**
1. Keep the two golems 40 yards apart or they take 99% less damage
2. Unstable Miasma: everyone soaks it, it splits
3. Intermission: pair up so your two stack counts add to exactly 4

**notes**
- `LUST` need lust — "on the pull, there is no burn phase" · *Method*
- `MAGIC` need magic — "Blighted Blood, once they are at the edge" · ability `Blighted Blood` · *both*
- `TANK` tank — "Swap after each Empowering Slam and each Bloodvenom Injection, not just at the intermission — repeated hits keep ramping" · ability `Empowering Slam` · *both*
- `CD` healer — "Venom Coagulation, and the Unstable Miasma soak" · ability `Venom Coagulation` · *both*
- (no role) — "Run over the Toxic Droplets before they go off" · ability `Toxic Droplets` · *both*

---

## 3. Vashnik the Malignant

Single phase. The boss drinks from three fountains (blood, shadow, fire);
each Imbibe empowers it and raises the permanent raid damage.

**core**
1. Every add dies before it reaches the centre pool
2. Plague Froth: spread out and dodge the waves
3. Toxic Vapor climbs with every Imbibe — that is the clock

**notes**
- `LUST` need lust — "on the pull" · *Method*
- `TANK` tank — "Dripping Fangs: swap every cast, it doubles physical damage taken" · ability `Dripping Fangs` · *both*
- `CD` healer — "the infections: Siphoning groups up, Stygian spreads, Exploding gets staggered dispels" · ability `Toxic Vapor` · *both*
- (no role) — "Cover every Malignant Catalyst bile" · ability `Malignant Catalyst` · *Method*

Method states explicitly that this fight has **no interrupts and no purges**.

---

## 4. The Lost Explorers

Council of three turtles: **Gebbo**, **Nama**, **Iku**.

**core**
1. United Defense: never let all three sit within 30 yards, or they take 99% less damage
2. Break the boxes and feed the Disgusting Fish to stop Final Ascension
3. Frostfire Volley: clear fire in the frost patch and frost in the fire patch, or the raid explodes

**notes**
- `LUST` need lust — "on the pull" · *Method*
- `KICK` need kick — "Iku's Icebound Flames" · ability `Icebound Flames` · *both*
- `MAGIC` need magic — "Icebound Flames if the cast lands" · ability `Icebound Flames` · *both*
- `TANK` tank — "Swap on both: Iku's Shredding Shards is +50% magic taken, Nama's Steady Strikes stacks physical" · ability `Shredding Shards` · *both*
- `CD` healer — "the Malevolent Presence rot, and the Fishy Feedback after every fish" · ability `Malevolent Presence` · *both*
- (no role) — "Nama's Mighty Thud: three soak groups, one per circle" · ability `Mighty Thud` · *both*
- (no role) — "Gebbo's bomb goes to the arena edge — bounce the shockwave on a mushroom" · ability `Explosive Surprise` · *both*

---

## 5. Sszorak

Single phase looping Apex Predator → Venomous Surge → Raging Crosswinds ×2 →
intermission. The raid's raw damage check.

**core**
1. Apex Predator is a five-cast combo: Ravage points away, Mutilate points at the soak group, dodge the Tempest tornadoes
2. Raging Crosswinds: pair with the player whose arrow points the opposite way and cancel the knock
3. Drop the Viscous Cysts opposite the active wind tunnels, then ride the winds into them

**notes**
- `TANK` tank — "Ravage: swap between casts and point it away from the raid; watch Corroding Venom stacks" · ability `Ravage` · *both*
- `CD` healer — "Ula'tek's Presence rot, and the Mutilate spike" · ability `Mutilate` · *both*
- (no role) — "Mutilate needs five or more soakers: alternate two groups" · ability `Mutilate` · *Method*
- (no role) — "Stay out of the Caustic Claws pools, they raise your damage taken" · ability `Caustic Claws` · *Method*

Both sources name a 30% damage-amp window (Dig In / Howling Maelstrom) but
neither calls a lust on it — see open questions.

---

## 6. The Twin Fangs

Two serpents, **Vexhul** and **Ithraz**. One intermission per Submerge; the
third Submerge is the hard enrage (Caustic Rain).

**core**
1. Eternal Venom is permanent and lethal at 10 stacks — Ravenous Feast is the only thing that sheds one
2. Soak every Caustic Globule, one player each, or the whole raid takes a stack
3. Kill both serpents together, or the survivor ramps with Uncoiled Wrath

**notes**
- `LUST` need lust — "on the pull" · *Method*
- `TANK` tank — "Stone Breaker: soak all three, then taunt swap — each soak is 33% vulnerability for 90s" · ability `Stone Breaker` · *both*
- `TANK` tank — "Swap Vexhul after each Caustic Deluge — Envenomed is +10% per stack for 90s, so you trade serpents rather than swap on the spot" · ability `Caustic Deluge` · *both*
- `CD` healer — "the Toxic Fumes rot all fight, and both tank soaks" · ability `Toxic Fumes` · *both*
- (no role) — "Ravenous Feast: three soak groups, nobody soaks twice, one stack off each" · ability `Ravenous Feast` · *Method*
- (no role) — "Dodge the Corrosive Spit lines from the Venomous Emergence serpents" · ability `Corrosive Spit` · *both*
- (no role) — "Submerge: rotate against the Vile Flood beam and dodge the Sanguine Storm circles" · ability `Vile Flood` · *Method*

---

## 7. The Coiled Altar

Three phases plus an intermission. Two bosses: **Zul'jan** and **Malacrass**.

**core**
1. Stay stacked behind the boss — the tank aims Sever into the orb and ghost clusters
2. Break the shield to stop Eternal Nightfall, or it wipes the raid
3. Phase 3: kill both evenly or Soulbound berserks the survivor

**notes**
- `LUST` need lust — "the intermission, while Soulbinding has Zul'jan at double damage taken" · ability `Soulbinding` · *both*
- `KICK` need kick — "Wail of Terror on the Spiritcackles — kick it late, and kill them before they hit 100 energy and go immune" · ability `Wail of Terror` · *Method*
- `POISON` need poison — "Venomfang" · ability `Venomfang` · *both*
- `MAGIC` need magic — "the healing absorb Eternal Nightfall leaves" · ability `Eternal Nightfall` · *MythicTrap*
- `TANK` tank — "Swap after EVERY Sever, Soul Sever or Blighted Sever — each one massively increases the next" · ability `Sever` · *both*
- `CD` healer — "the Dreadful Presence rot, and every phase push" · ability `Dreadful Presence` · *both*
- (no role) — "Guillotine needs five or more in the soak" · ability `Guillotine` · *both*
- (no role) — "Phase 2: AoE the mind-controlled free, and look at the Manifestations to freeze them" · ability `Dreadmarch` · *both*
- (no role) — "Collect the Soul Fragments within 15 seconds" · ability `Gloombomb` · *Method*

---

## 8. Ula'tek

End boss. Three phases plus an intermission, built on egg control. Enrage is
Fury Unleashed on the final platform.

**core**
1. Keep the venom off the Malignant Shells — an egg that gets hit hatches a Blightscale Viper
2. The tank stays in melee of both Ula'tek and the Tail, or the raid eats Rattler Slam
3. Serpent's Bite: three assigned soak groups, then spread for the Volatile Purge

**notes**
- `LUST` need lust — "the first Rage of the Shackled, while the Heart takes double damage" · ability `Rage of the Shackled` · *both*
- `KICK` need kick — "Vicious Echoes from the Shriekers, every cast" · ability `Vicious Echoes` · *both*
- `TANK` tank — "Mother's Wrath: defensive; step out of Mephitic Thrash and straight back in" · ability `Mother's Wrath` · *both*
- `CD` healer — "the Necrotic Vapors rot, and every platform break — the second one in phase 3 hardest" · ability `Necrotic Vapors` · *Method*
- (no role) — "Dodge Caustic Waves by moving against the telegraphed wing pull" · ability `Caustic Waves` · *both*
- (no role) — "Stack for the Spectral Coils soaks — the more bodies the less it hurts" · ability `Spectral Coils` · *both*

---

## Nymrissa Wavecaller

Not part of this raid: she is alone in The Tidebound Grotto, registered as
its own one-boss raid. Research in `retail-the-tidebound-grotto.md`.

---

## Tank swap thresholds

Checked 2026-09-08 against Method's per-boss guides, wow.gg and a dedicated
Venomous Abyss tank guide.

**The headline: this raid mostly does not use stack thresholds.** Where SoO
says "swap at 4 stacks", the Venomous Abyss says "swap on the cast" - the
debuffs are long (45-90s) and amplify the *next* cast rather than building to
a breakpoint. Only Nek'zali gave a stack number at all.

| Boss | Debuff | Swap |
|---|---|---|
| Nek'zali the Soulcoiler | Hollowing Strikes | **~5-6 stacks**, then let it expire |
| Entombed Sentinels | Empowering Slam / Bloodvenom Injection | **after each cast** |
| The Lost Explorers | Shredding Shards (+50% magic, 80s) / Steady Strikes (4%/stack) | rotate Nama and Iku as both build |
| Vashnik the Malignant | Dripping Fangs | **every cast** - 100% physical amp, never tank twice |
| Sszorak | Ravage (300-400% vuln) / Corroding Venom (3% per hit) | between Ravage casts; before Corroding Venom gets unsafe |
| The Twin Fangs | Envenomed (+10%/stack, 90s) / Stone Breaker (33%/soak, 90s) | **after each Caustic Deluge**, and after each Stone Breaker set |
| The Coiled Altar | Sever / Soul Sever / Blighted Sever | **after every cast** |
| Ula'tek | Mother's Wrath | no threshold given |

**Conflicts left standing:**

- **Nek'zali's number.** One source says 5-6 stacks; Method frames the same
  swap as "30-40% healing reduction", which at 5% per stack in phase 1 is 6-8.
  Written as 5-6 with this note, since the two nearly agree.
- **Ula'tek's tank debuff.** The tank guide calls it "Stone Venom"; every other
  source and this file call the tank mechanic Mother's Wrath. Not written as a
  new ability until confirmed.

## CONFLICTS — not written

- **Lost Explorers enrage.** Method describes a hard enrage: only three fish
  exist, so the fourth energy cap is the timer and all three turtles must be
  dead before it. MythicTrap says flatly "No Enrage". Method's account is
  internally consistent with the fish count, but the two disagree, so no
  enrage line was written.
- **Lost Explorers order.** Method gives a *feed* order (Iku → Nama → Gebbo);
  MythicTrap gives a *kill* priority (Gebbo → Nama → Iku). These may not be
  the same thing. No order line written.
- **Sszorak's Ravage vulnerability.** Method says 400% increased damage taken,
  MythicTrap says 300%. The line avoids the number entirely.
- **Twin Fangs' Stone Breaker.** Both agree a tank soaks all three swirlies;
  Method has the two tanks alternating sets, MythicTrap has one tank taking
  all three each time. The alternation is not written.
- **Ula'tek's second interrupt.** Method names the Weakened Doomscale's
  Anguished Cry; MythicTrap calls it Warden Malice. Only the Shrieker's
  Vicious Echoes, which both name identically, is written.

## Open questions

- **Sszorak lust.** Both sources flag a 30% damage-amp window (Method calls it
  the intermission Dig In, MythicTrap the Howling Maelstrom winds) but neither
  actually calls a lust there. It is the obvious window; not written without a
  source that says so.
- **Wing order.** The two wings can be cleared in either order, so trash legs
  cannot be a simple 1..n sequence the way a dungeon's are. The Notes tracker
  keys trash to "the stretch between boss N and N+1" — that model does not fit
  a raid with parallel wings, and this is the second structural gap (after
  difficulty ids) that raid support has to answer.
