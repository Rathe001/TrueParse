# TrueParse Changelog

## 1.2.8

- Awards are rare again: one per player per fight (rarest wins), and
  winning must be earned - Untouchable goes only to a sole dodger
  while the rest of the group got hit, Giant Slayer needs a 25%+
  margin over second place, Not on My Watch needs a real fight (90s+),
  Lifesaver goes to the top off-healer only, and kick/dispel/defensive
  minimums rise to 3.
- The fight picker scrolls past ~16 rows instead of drawing one
  screen-tall column after a night of dungeon hopping.

## 1.2.7

- MoP Classic clients on 5.5.4 no longer flag the addon "out of date"
  (which silently blocks loading unless "Load out of date AddOns" is
  checked - if TrueParse seems missing after install, that checkbox in
  the AddOns list is the workaround).

## 1.2.6

- Fight picker: a "Current" entry follows whatever is happening (the
  newest capture, or the waiting card in unrecorded content); every
  capture is its own pinnable entry, and a pinned fight no longer
  shifts when a new boss dies.
- Recording clarity: only real boss encounters are ever captured -
  delves, follower dungeons, story raids, scenarios, open-world quest
  mobs, and instance trash are all out, and the window says "not
  supported" where nothing will record. Old junk captures (NPC
  bodyguard cards, quest mobs) are pruned at login.
- After a kill the card says "unlocking..." while Blizzard still has
  the numbers secret-locked (LFR unlocks late) instead of claiming
  nothing was recorded.
- Deaths can no longer silently read as zero: a healer no longer earns
  "Not on My Watch" on a kill where people (or she herself) died.
- The parse-bracket gauge only shows for numbers with a real WCL
  population behind them; kicks and dispels read as words ("Dispelled
  1 of the group's 5").
- Live damage bars removed on both clients - TrueParse is a scorecard,
  not a damage race. Auto-collapse now applies on MoP too.
- The run column always shows, from the first boss of a run.
- Polish: collapsed bar text centers and no longer jumps on toggle,
  the encounter dropdown has even padding, less dead space under the
  Raid row, and Blizzard's "(!)" prefix no longer leaks into labels.

## 1.2.5

- Fixed fight scores rendering in the run column for players outside
  the current run (empty run cells collapsed and let the score slide
  over).
- Browsing an old fight shows THAT fight's run averages, not whatever
  run is live now.
- Scroll indicators: arrows on dark pills above/below the list when
  more rows exist in that direction.
- Note: updating adds new data files - a full game restart (not
  /reload) is needed once after installing.

## 1.2.4

- LFR works: Raid Finder groups are instance groups, which the addon
  sync never reached - presence marks and peer data were dead there.
  Raw mode now has real LFR percentile curves for every raid boss, and
  the outdoor Sporefall raid (Rotmire) has its own curves and kill
  times across all difficulties.
- Resizable window: drag the corner grip; rows re-flow live, the mouse
  wheel scrolls when the list doesn't fit, and the Raid row stays
  pinned (now showing the group's combined penalties).
- Fight picker: click the subtitle for a dropdown of recent captures,
  grouped by run - one group's visit to one instance at one difficulty.
  Run averages follow the same boundary, so LFR wings no longer blend
  with last week's guild raid.
- Healing demand cap: you can't heal damage that never went out. On
  fights whose incoming damage couldn't demand a median healer's
  output, healers who covered their share floor at neutral instead of
  parsing single digits against raid populations.
- Wipe detection hardened: late boss resets and full group deaths both
  register, and raid bosses re-pulled later in a run retroactively mark
  the earlier pulls as wipes.
- New info bullets: active time (always-be-casting), healer
  overhealing %, offensive cooldown counts, tank active-mitigation
  uptime (MoP). Group tooltips render gauges; the group card matches
  the player card layout.
- New award: Unbreakable. Lifesaver now requires healing other people.
- Column polish: class bars span the name column with hairline column
  separators, names truncate instead of wrapping, outdoor captures
  record their real zone.

## 1.2.3

- Group kill speed: the Raid breakdown shows how fast your kill was
  against every ranked kill of that boss and bracket on Warcraft Logs,
  with the population and median kill time on hover.
- New award: Unbreakable - a non-healer covering 15%+ of the group's
  healing almost entirely on themselves. Lifesaver now requires healing
  OTHER people (Classic; retail can't see the split).
- A low interrupt/dispel count that covered everything the fight offered
  is credited ("Did their share"), not scolded.
- /tp help lists every command with the addon version and bug-report
  link; award stars removed from scorecard rows (they wrapped long
  names; awards live in the breakdown and toasts).

## 1.2.2

- Fixed Mythic+ percentile curves: WCL orders dungeon rankings by
  keystone score, so nearly all shipped M+ curves were scrambled. Data
  regenerated, and the engine now sanitizes any curve set it loads.
- Run averages score against real populations (the run column showed a
  structural ~99 for the best player of each role); multi-fight Aug
  runs no longer peg Ebon Might uptime at 100.
- Raw mode is strictly this-encounter evidence; boss names with
  punctuation differences (Chimaerus) match their curves; a third
  Midnight Demon Hunter spec is recognized.
- Interrupt/dispel bullets tier on the actual count: 0 plain, 1 grey,
  2 green, 3 blue, 4 purple, 5+ orange.
- Retail stability: fixed errors from Blizzard's secret combat values
  in partially-locked sessions, roster updates mid-combat, and boss
  frames; self-report windows bind to encounter boundaries so
  defensive/consumable data attaches reliably; roles survive
  late-arriving captures after the group disbands.
- Group sync hardening: reports must come from the player they claim
  to be about, and remote spec/ilvl claims are validated.
- Performance: award computation memoized, hot-path allocations
  trimmed, memory caps on internal histories and the /tp baddies tally.

## 1.2.1

- Retail percentile data doubled: damage AND healing curves for all 37
  specs across Normal/Heroic/Mythic raid brackets.
- Mythic+ dungeon curves (8 dungeons, whole-run populations): M+ and
  Challenge Mode bosses parse against the right dungeon. Unranked
  difficulties (Timewalking, normal/heroic dungeons) never borrow the
  M+ population - Raw disables there instead of handing out unfair Fs.
- Raw mode only uses evidence from THIS encounter; the cross-encounter
  zoom ladder is now a True-mode fairness fallback only.
- Your spec decides your role everywhere (matching how Warcraft Logs
  ranks): a healer in unassigned-role content is no longer graded as
  DPS or handed the non-healer Lifesaver award.
- Retail captures record role/spec/ilvl while the fight is live - late
  bulk-unlocked captures no longer lose them when the group disbands.
- Fixed a retail error when boss GUIDs are secret mid-combat.

## 1.2.0

Scoring:

- True Warcraft Logs percentiles: population curves per encounter, spec,
  and bracket (10/25 x N/H on Classic; N/H/M on retail) for BOTH damage
  and healing. Raw mode now matches your WCL parse; True mode builds on
  the same curves through a contribution transform.
- Per-spec throughput profiles: the damage/healing weight split follows
  your spec's population median mix on the exact fight and bracket - a
  Disc priest's damage and a Blood DK's self-healing count the way their
  populations say they should.
- Widening evidence ladder: no curve for your exact spec+bracket? The
  comparison zooms out (neighboring brackets, role pools, whole-tier
  pools) instead of ever falling back to a group-relative guess. Tooltips
  name the comparison population.
- Raw mode is only offered when WCL data covers the fight; group-relative
  estimates cap at 99 and carry a ~ marker.
- Fairness: no threat penalties in raids (fixates make them noise),
  healers pay half for chasing a slacking tank, wipe deaths cost less,
  low-demand healing floors instead of scolding, and tanks/healers are
  never nagged about pull consumables on Classic (retail drops the
  expectation entirely).

Display:

- Scores are color-coded 0-100 in WCL parse colors everywhere; an
  optional letter-grade display (F to S+) is available in options or via
  /tp letters.
- Details-style rows: class-colored bars sized by score, spec icons,
  presence check/X/? marks, fight + run-average columns with headers, a
  merged Raid summary row, and a one-line footer legend with the
  TrueParse/Raw mode radios. The window title shows the active mode.
- Compact breakdown card: role tag by the name, score-vs-boss and
  run-average lines, five-tier bullet language (low / average / good /
  excellent / godly) that always matches the gauge percentile, and gauge
  tooltips with your marker on the parse-color scale.
- One tooltip style everywhere; solid backgrounds; panels and tooltips
  pick the roomier side of the screen; collapsing closes every tooltip
  and respects the window's screen half.

Collection (Classic):

- Boss-only capture in instances; damage-to-boss vs adds splits; healing
  to tanks vs self splits; guardian pets credited to their owners;
  defensive cooldowns read from the combat log for everyone; Bloodlust
  windows tracked with DPS cooldown+potion usage bullets; the
  self-report fight window survives mid-encounter combat drops
  (conveyor belts, fixates).
- Groundwork for a curated avoidable-damage list ("Stood in bad") with
  /tp baddies to review what actually hurt people.

CI: the test suite runs on every push; benchmark and percentile
refreshes skip green when API keys aren't configured.

## 1.1.0

- Hover a scorecard row to open the breakdown panel directly (click pins it);
  big grade-colored score in the panel header; rewritten plain-language
  hover tooltips.
- Score colors now match Warcraft Logs parse brackets, including pink at 99+
  and gold at a perfect 100.
- Threat discipline (Classic): body pulls, aggro rips, and tank aggro losses
  are tracked and penalized (lightly, with fairness gates). Retail ships a
  threat readability probe.
- Wipe-aware scoring: boss wipes are labeled, death penalties soften on
  them, top-damage trophies don't grant, and they don't drag career GPA.
- New awards: Not on My Watch, Topped Off, Healed Through Stupid (healers),
  Giant Slayer (boss top damage), Lawnmower (trash top damage) — plus an
  on-screen award toast with fanfare (toggleable).
- Augmentation: SUPPORT is now scored primarily on self-reported Ebon Might
  uptime when the Aug runs TrueParse (35% weight, 100 points at 60% uptime).
- /tp trends: score and per-metric direction over your recent fights, plus
  per-zone averages. Numeric score now sits beside the letter grade,
  grade-colored. Version-update nag when a groupmate runs a newer TrueParse.

## 1.0.0

First public release.

- Group Contribution Score (0-100, S+ through F letter grades): damage,
  effective healing + absorbs, damage soaked (tanks), interrupts, dispels —
  normalized per spec, per fight, and per item level, with penalties for
  avoidable damage, deaths (timing-aware), and missing raid buffs.
- Scoring anchored to Warcraft Logs statistics: per-encounter and per-dungeon
  spec medians (retail Midnight + MoP Classic), blended with in-group
  comparison; solo-role scores cap below perfection.
- Post-fight scorecard with clickable player rows, plain-language breakdown
  bullets (numbers on hover), a clickable group summary row, and awards:
  Kick King, Cleanser, Untouchable, Lifesaver, Survivalist, Iron Wall.
- Coach line after bosses: your grade and the one change that would have
  raised it most. Career stats (/tp career), run report cards (/tp run),
  opt-in group chat summaries (/tp share, /tp announce).
- TrueParse users share their own combat facts (defensive cooldowns used,
  consumables at the pull, defensives available at death) over a hidden
  addon channel — data Blizzard hides from everyone except the player
  themselves. Informational only, never scored.
- Retail (Midnight) and Mists of Pandaria Classic support.
