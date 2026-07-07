# TrueParse

*A parse that shows you actually did your job.*

TrueParse is a World of Warcraft group meter that ranks players by a **Group
Contribution Score** (0–100) instead of raw damage or healing. Damage,
effective healing, interrupts, dispels, buff uptime, mitigation, and avoiding
avoidable damage all feed a role-weighted score — so a tank or healer can top
the meter just as easily as a DPS, and standing in fire actually costs you.

## Status

Walking skeleton (Phase 1 of the roadmap): combat log capture, fight
segments, damage tracking, and a Details-style bar window sorted by damage.
Scoring lands in Phase 5.

## Development setup

1. Clone this repo anywhere.
2. Run `scripts\link-addon.ps1` (pass `-WowPath` if WoW isn't in the default
   location). This junctions the repo into `_retail_\Interface\AddOns\TrueParse`.
3. In-game: `/reload` after each change. Install **BugSack + BugGrabber** to
   catch Lua errors.

### Slash commands

| Command | Effect |
|---|---|
| `/tp` | Toggle the meter window |
| `/tp lock` | Lock/unlock window dragging |
| `/tp reset` | Reset window position |
| `/tp debug` | Toggle debug prints (fight start/end) |

## Phase 1 verification checklist

- [ ] Addon loads with zero Lua errors (check BugSack)
- [ ] `/tp` toggles the window; position survives `/reload`
- [ ] Attack a training dummy: a fight segment starts, your bar appears and
      updates every ~0.5s, fight ends a few seconds after you stop
- [ ] Run a follower dungeon with Details open side-by-side: damage totals
      match within ~1–2% for every party member
- [ ] On a hunter/warlock (or with one in the group): pet damage is credited
      to the owner

## Architecture (short version)

- `Collect/CombatLog.lua` — raw-frame CLEU dispatcher (hot path, zero alloc)
- `Collect/Segments.lua` — fight lifecycle; owns per-player accumulators
- `Collect/Roster.lua` — GUID→player map, roles, pet ownership
- `Metrics/` — one tracker per metric, registered into a dispatch table
- `Scoring/` — (Phase 5) pure-Lua normalizers + role weights, headless-testable
- `UI/` — bar meter window; breakdown panel comes in Phase 6
- `Core/Compat.lua` — all retail/Classic API divergence lives here

Design goal: every metric normalizes to 0–100 *before* role weights apply,
with weights that make 100 reachable for every role on every fight
(inapplicable metrics get their weight redistributed).
