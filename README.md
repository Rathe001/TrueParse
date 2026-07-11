<img src="Logo.png" alt="TrueParse" width="160" align="right" />

# TrueParse

*A parse that shows you actually did your job.*

TrueParse is a World of Warcraft group meter that grades players on a
**Group Contribution Score** — a 0–100 number in the parse colors you
already know from Warcraft Logs — instead of raw damage or healing.
Damage, effective healing, damage soaked, interrupts, dispels, avoidable
damage, deaths, raid buffs, and pull preparation all feed a role-weighted
score — so a tank or healer can top the card just as easily as a DPS, and
standing in fire actually costs you.

Supports retail (Midnight) and Mists of Pandaria Classic.

## What it does

- **Post-fight scorecard**: Details-style rows with per-fight and
  whole-run scores, a merged Raid/Group summary row, and a check mark for
  who's running TrueParse. Hover any row for a plain-language breakdown
  ("Excellent damage", "Did their share of dispels", "Wasted Bloodlust")
  with percentile gauges showing exactly where you landed against your
  spec's population — click to pin. Optional **letter grades** (F to S+)
  via `/tp letters`.
- **Two lenses**, switchable on the window: **TrueParse** (the full
  contribution score) or **Raw** — your true Warcraft Logs percentile
  for this exact boss, bracket, and spec. If you parse 92 on WCL, Raw
  shows 92. Raw disables itself on content WCL doesn't rank instead of
  inventing a number.
- **Fair by construction**: real WCL population curves per encounter,
  spec, and bracket for BOTH damage and healing — a Disc priest's damage
  and a Blood DK's self-healing count the way their populations say they
  should. Metrics your spec can't perform redistribute; mechanics that
  force damage onto you never count against you; fights with nothing to
  heal don't scold healers; item level is normalized (toggleable).
- **Group kill speed**: the Raid breakdown shows how fast your kill was
  against every ranked kill of that boss on Warcraft Logs.
- **Coach line**: after bosses, one private chat line with your grade and
  the single change that would have raised it most.
- **Awards**: Kick King, Cleanser, Untouchable, Lifesaver, Unbreakable,
  Survivalist, Iron Wall, Giant Slayer, Virtuoso, and healer-only honors
  like Not on My Watch — with descriptions on hover.
- **Career tracking** (`/tp career`), **run report cards** (`/tp run`), and
  opt-in one-line **group chat summaries** (`/tp share` — off by default,
  be considerate).
- **Better together**: TrueParse users share their own combat facts
  (defensive cooldowns used, consumables at the pull, defensives sitting
  ready at death) over a hidden addon channel — data Blizzard hides from
  everyone except the player themselves. Informational only, never scored.

## Install

[CurseForge](https://www.curseforge.com/wow/addons/trueparse), or drop the
folder into `Interface/AddOns/`. Left-click the minimap icon for the
scorecard, right-click for options (`/tp config`).

## Commands

`/tp help` lists everything in-game. Highlights: `/tp` toggle window ·
`/tp mode` TrueParse/Raw · `/tp letters` letter grades · `/tp run` run
report · `/tp share` post group summary · `/tp career` · `/tp trends` ·
`/tp fights` history · `/tp score [n]` · `/tp buffs` pre-pull diagnostic ·
`/tp ilvl` · `/tp coach` · `/tp announce`

## How scoring works (short version)

Throughput grades against **Warcraft Logs percentile curves** sampled from
the full ranked population for your spec, on that boss, in your bracket
(10/25-player on Classic; Normal/Heroic/Mythic on retail; whole-run curves
for M+). True mode maps the percentile through a contribution transform
and splits the damage/healing weight by your spec's population mix on that
exact fight; Raw is the percentile itself. When your exact spec+bracket
has no curve, True zooms out through progressively wider populations
(neighboring brackets, role pools, the whole tier) rather than comparing
you against your own group — and the tooltip names the population used.
Interrupts and dispels score against an equal share among players who can
perform them, with low-opportunity fights smoothed so one kick isn't a
coin flip. Penalties subtract for avoidable damage beyond an equal share,
deaths (late deaths cost less; wipe deaths less still), threat accidents
(5-mans only), and missing raid buffs at the pull. Inapplicable metrics
redistribute their weight, so 100 is reachable for every role on every
fight. The scoring engine is pure Lua with a headless test suite.

## Known limitations

- **English clients get the sharpest data**: encounter matching keys on
  English names today, so non-English clients fall back to wider
  population pools. Keying by encounter ID is planned.
- On retail, Blizzard hides other players' casts and mid-combat values
  ("secrets"), so combat-log-based extras (Bloodlust windows, damage-target
  splits, defensives for non-TrueParse players) are MoP-Classic-only.
- Raw mode needs WCL-ranked content: unranked difficulties (Timewalking,
  normal dungeons) fall back to True scores by design.

Bug reports and requests: [GitHub issues](https://github.com/Rathe001/TrueParse/issues).

## Maintenance: refreshing spec benchmarks

Grading uses per-fight spec expectations generated from Warcraft Logs
statistics (`Data/Benchmarks*.lua`). **These are point-in-time snapshots**
— a scheduled GitHub Action refreshes them weekly (secret: `WCL_API_KEY`),
and the addon nags in-game once the shipped data is 60+ days old. Manual
refresh:

```powershell
# Retail (current raid + M+ season):
powershell -File scripts\fetch-benchmarks.ps1

# MoP Classic (SoO + ToT + Challenge Modes):
powershell -File scripts\fetch-benchmarks.ps1 -GameBase https://classic.warcraftlogs.com `
    -RaidZoneIds 1054,1046 -DungeonZone 1039 -MinSamples 6 -OutFile Benchmarks_Mists.lua
```

Requires a free WCL V1 API key in `scripts\wcl-key.local.txt` (gitignored).
Zone IDs change each season — list current ones via the `/v1/zones`
endpoint and update `.github/workflows/benchmarks.yml` to match.

## Development

1. Clone anywhere; run `scripts\link-addon.ps1` to junction the repo into
   `_retail_\Interface\AddOns` (repeat with your Classic path if wanted).
2. `/reload` after changes; BugSack + BugGrabber recommended.
3. Headless tests: `lua tests/run.lua [path-to-SavedVariables]`.

Releases: push a `v*` tag; the packager workflow builds and uploads to
CurseForge (secret: `CF_API_KEY`).

## Credits

Benchmark data derived from [Warcraft Logs](https://www.warcraftlogs.com)
public statistics. Built on Ace3, LibSharedMedia, LibDataBroker, LibDBIcon.
MIT licensed.
