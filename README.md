# TrueParse

*A parse that shows you actually did your job.*

TrueParse is a World of Warcraft group meter that grades players on a
**Group Contribution Score** (S+ through F) instead of raw damage or
healing. Damage, effective healing, damage soaked, interrupts, dispels,
avoidable damage, deaths, raid buffs, and pull preparation all feed a
role-weighted grade — so a tank or healer can top the card just as easily
as a DPS, and standing in fire actually costs you.

Supports retail (Midnight) and Mists of Pandaria Classic.

## What it does

- **Post-fight scorecard**: letter grades per player, sorted by
  contribution, with a group grade footer. Click any row for a
  plain-language breakdown ("Strong damage", "Did not interrupt",
  "Died with 2 defensives ready") — hover any bullet for the full math.
- **Fair by construction**: scores are normalized per spec, per fight
  (Warcraft Logs medians for every raid boss and M+ dungeon), and per item
  level. A spec having a bad fight isn't a bad player; a low-ilvl alt doing
  its share outgrades a carried main. Metrics your spec can't perform
  (no interrupt, no cleanse) redistribute — you're never graded on a
  button you don't have.
- **Anchored to the world, not just your group**: throughput blends
  "fraction of the elite-logs median for your spec on this fight" with the
  in-group comparison, so your 80 means the same thing every night.
- **Coach line**: after bosses, one chat line with your grade and the single
  change that would have raised it most.
- **Awards**: Kick King, Cleanser, Untouchable, Lifesaver, Survivalist,
  Iron Wall — gold stars for exactly the play that wins fights.
- **Career tracking** (`/tp career`), **run report cards** (`/tp run`), and
  opt-in one-line **group chat summaries** (`/tp share`).
- **Better together**: TrueParse users share their own combat facts
  (defensive cooldowns used, consumables at the pull, defensives sitting
  ready at death) over a hidden addon channel — data Blizzard hides from
  everyone except the player themselves. Informational only, never scored.

## Install

CurseForge, or drop the folder into `Interface/AddOns/`. Left-click the
minimap note icon for the scorecard, right-click for options (`/tp config`).

## Commands

`/tp` toggle window · `/tp config` options · `/tp run` run report ·
`/tp share` post group summary · `/tp career` your stats ·
`/tp trends` where your play is heading · `/tp fights` history ·
`/tp score [n]` rescore a fight · `/tp ilvl` toggle gear normalization ·
`/tp coach` · `/tp announce`

## How scoring works (short version)

Every metric normalizes to 0–100 before role weights apply. Throughput
scores blend 60% "percent of the Warcraft Logs elite median for your spec
on this fight, gear-adjusted, with 100 points at 75% of that median" and
40% comparison against the best of your role in the group. Interrupts and
dispels score against an equal share among players whose class can perform
them. Penalties subtract for avoidable damage, deaths (dying at the end of
a fight costs far less than dying early), and providers whose raid buff
wasn't up at the pull. Inapplicable metrics redistribute their weight, so
100 is reachable for every role on every fight — but solo-role fallback
scoring caps at 92: perfect scores must be earned against actual
competition. The scoring engine is pure Lua with a headless test suite.

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
