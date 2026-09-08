# Terrace of Endless Spring — MoP Classic

- **Journal name:** Terrace of Endless Spring
- **Type:** raid, 4 bosses. **Boss-only** — no trash, per Josh 2026-09-08.
- **Source:** Icy Veins MoP Classic per-boss encounter guides, read 2026-09-08.
  Single source; second-source pass still owed.
- **Status:** drafted, needs a second source

Boss order: Protectors of the Endless → Tsulong → Lei Shi → Sha of Fear.

---

## 1. Protectors of the Endless

Council of three: Elder Regail, Elder Asani, Protector Kaolan. Each death
makes the survivors stronger and hands them a new ability, so kill order is
the whole fight.

**core**
1. Kill order matters: every death gives the survivors 25% more damage and a new ability
2. Interrupt Elder Regail's Lightning Bolt and Elder Asani's Water Bolt
3. Spread so Lightning Prison cannot catch anyone standing next to you

**notes**
- `KICK` need kick — "Lightning Bolt and Water Bolt, both of them" · ability `Lightning Bolt`
- `PURGE` need purge — "Cleansing Waters off the kill target: it heals them 5% a second" · ability `Cleansing Waters`
- `MAGIC` need magic — "Lightning Prison, and Touch of Sha" · ability `Lightning Prison`
- `LUST` need lust — "phase 3, on the last one standing" · ability `Overwhelming Corruption`
- (no role) min `h` — "Rotate the Corrupted Essence soaks — about nine stacks each before it explodes" · ability `Corrupted Essence`

---

## 2. Tsulong

Two alternating phases with two different win conditions.

**core**
1. Night: get him to 0%. Day: heal him to 100%. Either one ends the fight
2. Stand in the Sunbeam to clear Dread Shadows — it shrinks every time it is used
3. Day phase: take Sun Breath for Bathed in Light, then pour healing into him

**notes**
- `MAGIC` need magic — "Terrorize, off Tsulong the instant it lands" · ability `Terrorize`
- `TANK` tank — "Swap after each Shadow Breath: it doubles the shadow damage you take for 30 seconds" · ability `Shadow Breath`
- `CD` healer — "save everything for the Day phase, under Bathed in Light" · ability `Bathed in Light`
- (no role) — "Spread — Nightmares explodes and fears" · ability `Nightmares`
- (no role) min `h` — "Kill the Dark of Night adds before they reach the Sunbeam" · ability `The Dark of Night`

Hard enrage after the third Night phase, about eight minutes in.

---

## 3. Lei Shi

**core**
1. She Hides constantly — spread AoE across the room to break her out
2. Get Away! channels for 45 seconds: push 4% of her health to end it early, and move toward her to halve the damage
3. Only one Animated Protector has to die at 80, 60, 40 and 20%

**notes**
- `TANK` tank — "Spray stacks frost damage taken 16% a time: swap around twelve" · ability `Spray`
- `CD` healer — "the last 20% — Afraid has her casting 8% faster for every 10% health she has lost" · ability `Afraid`
- (no role) min `h` — "Scary Fog: stay within 10 yards of her" · ability `Scary Fog`

---

## 4. Sha of Fear

**core**
1. Be inside the Wall of Light before Breath of Fear — outside it, it kills
2. Somebody stays in melee or Reaching Attack pulses the raid until someone does
3. Phase 2: pass the Pure Light ball to break Huddle in Terror and to kite the Dread Spawns

**notes**
- `LUST` need lust — "the start of phase 2 — cooldowns reset over the transition" · ability `Dread Thrash`
- `FEAR` **new capability** — "Penetrating Bolt from the Terror Spawns fears after two hits" · ability `Penetrating Bolt`
- `TANK` tank — "Thrash, then Dread Thrash in phase 2: major defensive. Rotate when Naked and Afraid lands" · ability `Dread Thrash`
- `CD` healer — "the Huddle in Terror chains, and every Thrash window" · ability `Huddle in Terror`
- (no role) — "Hit the Terror Spawns from behind — they are immune from the front" · ability `Terror Spawn`

---

## Note on the `FEAR` capability

Terrace produces two more fear cases (Penetrating Bolt here, Tsulong's
Terrorize which is an ordinary magic dispel off the boss). They are not the
same thing:

- **Terrorize** is a magic debuff on the boss — a plain `MAGIC` line.
- **Penetrating Bolt** and **Huddle in Terror** are fears on players, answered
  by fear-specific tools as much as by dispels.

That distinction is the argument for a separate `FEAR` key rather than folding
fears into `MAGIC`.
