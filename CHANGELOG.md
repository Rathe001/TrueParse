# TrueParse Changelog

## 1.4.0

**Progression tracking.**
- Best-pull tracker (MoP): wipes show how far you got - "wipe 12%" in
  the fight menu, and the wipe debrief reads "Pull 3 - boss at 12%
  (best 12%)".
- Your last kills of each boss right on the breakdown: "this boss:
  26 41 58 72" in parse colors.
- The run report remembers your week: "This week: 12 bosses down,
  4 wipes - group 61 (last week 56)".
- /tp guild: weekly standings across TrueParse users in your groups -
  score average, fights, times topping the card.

**See it, don't read it.**
- Tank and healer breakdowns get a danger-window timeline: one strip
  for the fight, green band = damage spike your cooldown met, red =
  missed.
- Death recap hits carry bars sized by damage, red when avoidable.

**The impact-only card.** Every line now moves the score or stays off
it. New scored metrics (all default to 0 without data - addon-less
players untouched): overheal for healers on real-demand fights
(lean healing now earns points), overkill damage, running dry on
mana mid-fight, and dying without ever using a defensive.
Informational lines that couldn't honestly be scored are gone.

**Fairness fixes.**
- Dispels now check WHO could help: a Balance druid isn't scored on
  dispels when the fight's debuffs were all Magic. Capability is
  class+spec, and debuff types teach themselves from your dispels.
- "Healing struggled" no longer appears on fights with nothing to
  heal: on unranked content, nobody dying + healing covering intake
  means demand was met, period.
- The raid card's lines carry points like player rows ("4 players
  died (-8)"), and the kick pointer quantifies itself ("kicking 80%
  would be worth roughly +3").

## 1.3.4

- Fixed a scoring bug for MoP casters: "Essence of Yu'lon" is the
  legendary cloak's own proc, and the seasonal-dungeon exclusion was
  name-matching it - subtracting real cloak damage from casters'
  scores in raids. Cloak procs count again.
- Addon-presence dots work on MoP again (the old indicator art was
  retail-only), drawn as small circles inset on the spec icon, and
  presence now survives /reload: clients answer hellos from users they
  don't know, and rows green up live the moment a groupmate's addon
  speaks - no more one-user-green raids.
- First Siege of Orgrimmar avoidable-damage entries (Immerseus
  puddles/waves, Galakras drake breath, Jadefire Blaze). Norushen orbs
  deliberately excluded - soaking them is the job.
- New /tp procs command: top damage and healing sources with spell
  IDs, for curating the proc-exclusion list.

## 1.3.3

- Fight duration now matches Warcraft Logs (first damage to last
  damage) instead of Blizzard's encounter window. RP intros - 27 dead
  seconds on Norushen - were deflating every per-second rate ~10%,
  which read fine at the top of the curves but crushed mid-pack Raw
  percentiles (a p45 player showed p15). Verified against a live WCL
  log. Kill-speed percentiles use the same bounds and get sharper too.
  (MoP; retail already used Blizzard's tight session timing.)
- Two 99s aren't equal: ties at the score cap now rank by the full
  unclamped value, so a 99 with +6 in adjustments sorts above a bare
  99. The adjustment column already shows why.

## 1.3.2

- Raw run averages count kills only. Warcraft Logs never ranks wipes,
  and a wipe's per-second rates are structurally low (the dead
  contribute zero for the rest of the pull) - so on wipe-heavy runs
  the Raw avg column read about half the real parse. True mode still
  grades attempts, as designed.

## 1.3.1

MoP users: this adds new files - fully restart the client once.

**Augmentation Evokers finally score right.** Their personal damage
understates them by design - the output lives in allies' bars - so
TrueParse now credits the damage their buffs enabled, from their own
reported Ebon Might uptime applied to the buffed allies, and scores
that effective damage against the real DPS population. Calibrated
against Warcraft Logs: within a point or two of WCL's own attributed
parse on live fights. The damage tooltip shows the split ("27.9k own
+ 18.1k buffs enabled"), the bullet reads "amplification," and an Aug
whose uptime we never received pins neutral instead of getting a
damning score built on a number everyone knows is wrong.

**"Wipe it" detection (MoP).** When the raid calls a wipe, people
stand in bad on purpose to reset faster. On wipes, TrueParse now
detects the moment group damage output collapses and never recovers -
after that point, avoidable damage doesn't count, deaths cost
nothing, and activity measures only the trying phase. A wipe fought
to the last death detects nothing: everything counts.

**Smarter reports.**
- Post-wipe debrief (new, local): deaths, how many followed avoidable
  damage, and the pull's top pointers - right when everyone asks
  "what happened?"
- Specific pointers replace "work on: healing": "9 interruptible
  casts got through", "Falling Ash did the most avoidable damage -
  it's dodgeable", "the healer ran dry in 3 fights." A clean run gets
  no scolding.
- Share to group is now a flex line: kill time vs Warcraft Logs
  ranked kills plus the group score. Analysis stays local.
- The run report, MVP announce, and the window's avg column all agree
  now (same per-fight averages), and run averages follow the active
  lens - a Raw card averages Raw scores.

**Seasonal celestial procs (MoP)** no longer skew scores: Jadefire,
Essence of Yu'lon, the Songs and friends are excluded from scored
damage and healing (Details still shows raw). Curate additions with
the new /tp procs.

**Durability.** Reloading mid-run can no longer silently degrade
captures: pending reports, session contexts, and the captured-session
ledger all survive /reload, and session-ID reuse after a client
restart can't overwrite unrelated fights.

**Also:** true class colors for everyone (the non-addon muting wash
turned druids into warriors - the green/gray dot carries presence
now), bullets sorted best-to-worst, tooltips that never truncate or
overflow, an options cog on the window, click-through-in-combat,
per-client explanations for why "kicked X of Y" is or isn't
available, the aggro story told once, and up-to-date option tooltips.

## 1.3.0

The biggest scoring release since curves landed. All scores - history
included - recompute under the new model, so numbers will shift once.
MoP users: this adds new files, so fully restart the client once.

**Scoring is now: WCL base + adjustments.**
- The base is what's verifiable for every player, addon or not:
  damage and healing vs Warcraft Logs percentile curves (split per
  spec by its population's own mix) plus tank soak share.
- Everything else adjusts on top, signed and context-scaled: kicks
  swing up to +-6 on kick-heavy fights and barely register on quiet
  ones; staying out of the bad earns points, standing in it costs
  them; deaths, threat, activity, mitigation, consumables, and
  Bloodlust usage all nudge. Net adjustment caps at +-15, absence of
  addon data is always neutral, and True now tops at 99 like Raw -
  100 does not exist.
- The comparison ladder was rebuilt from a measured audit of 6M+
  parses: neighbor-difficulty comparisons are ratio-corrected (error
  down from 20-48 percentile points to 6-15), spec identity outranks
  encounter identity in fallbacks, and the everyone-pool - wrong by
  up to 49 points in both directions - is gone.
- Normal/heroic dungeons now compare against the dungeon's curves,
  labeled honestly as timed top runs; Raw lights up on seasonals.

**New metrics (Classic combat log; retail where the API allows):**
- Interrupt opportunities: casts kicked vs casts that got through,
  with a kickable-spell list that teaches itself from every interrupt
  anyone lands. "Kicked 7 of 9 interruptible casts."
- Danger windows: whether tank defensives met their damage spikes and
  healer cooldowns met the group's. Timing beats totals.
- Death recap on the death bullet: the last hits, avoidable flagged.
- Dispel reaction time, healer mana timeline (ran dry at 1:23),
  combat-rez credit, overkill share, personal-best tags, and an
  encounter-toughness context line on the group card.
- The MoP avoidable-damage list has its first curated entries:
  Stood in bad / Stayed out of the bad now live on Classic.

**The group card tells the whole story:** role-honest verdicts (a DPS
self-heal percentile can no longer drag "group healing" down),
demand-aware healing lines, kick coverage, deaths and avoidable
pressure as facts - plus execution-vs-parses analysis when the kill
speed and the meters disagree.

**Announcements:** one announcer per group (elected over the addon
channel - no more duplicate lines when several users have it on), the
summary line leads with the whole-group finding, the MVP line says
why, and retail posts via a click prompt (Blizzard now blocks
automated chat).

**UI:** Details-style rows and typography, presence dots (green =
addon, gray = not), rank-numbered names, an options cog on the
window, click-through-in-combat option, window height that never
exceeds its content, footer-click collapse, bullets sorted best to
worst, cards that widen instead of truncating, and window position
that finally survives reloads in every state.

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
