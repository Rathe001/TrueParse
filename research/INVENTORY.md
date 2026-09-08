# Dungeon & raid notes — research inventory

Staging for the Notes view (`Notes/*.lua`). Not packaged: `research` is in the
`.pkgmeta` ignore list, so nothing here ships to CurseForge.

Scope opened by Josh 2026-09-08 as *every instance, legacy included*, for both
clients — retail (mainline) and MoP Classic. Research everything first, write
the Lua afterwards.

**Scope narrowed the same day, once the shape of the work was clear.** What is
covered is every instance with a live max-level audience: current retail
(Midnight), The War Within, all of MoP Classic, and every Timewalking pool.
Pre-TWW legacy raids and the legacy dungeons outside the Timewalking pools are
**out of scope for now** — see the section at the bottom for what that means
and what it would take to reopen.

## How this is organised

- `INVENTORY.md` (this file) — the index. One row per instance, with status.
- `instances/<client>-<slug>.md` — one research file per instance: exact
  journal name, ordered boss list, and the per-boss / per-leg raw material
  reconciled from sources, in the field shape `Notes/Season2.lua` uses.

Status values: `todo` · `bosses` (boss list confirmed) · `drafted` (notes
written into the research file) · `shipped` (registered in a `Notes/*.lua`).

## Sourcing rule

Most recent guide available wins, and two independent sources are reconciled
before a line is written; where they disagree the line is dropped rather than
guessed (the rule `Notes/Season2.lua` already follows). For legacy content the
"most recent" guide is often years old — record the source date in the instance
file so a stale line can be re-checked later.

Exact **English Encounter Journal names** are what the addon keys on
(`KN.RegisterDungeon{ name = ... }`), so names here are journal names, not
colloquial ones.

---

## Retail — Midnight (12.x)

Nine expansion dungeons; the Mythic+ pool mixes four of them with returning
legacy dungeons per season.

| Instance | Type | Bosses | In S2 pool | Status |
|---|---|---|---|---|
| Altar of Fangs | dungeon | ? | yes | shipped |
| Den of Nalorakk | dungeon | ? | yes | shipped |
| Murder Row | dungeon | ? | yes | shipped |
| The Blinding Vale | dungeon | ? | yes | shipped |
| Voidscar Arena | dungeon | ? | yes | shipped |
| Windrunner Spire | dungeon | 4 | no | drafted |
| Maisara Caverns | dungeon | 3 | no | drafted |
| Magisters' Terrace | dungeon | 4 | no | drafted |
| Nexus-Point Xenas | dungeon | 3 | no | drafted |

Returning legacy dungeons currently in the Season 2 pool (already shipped, but
they belong to their own expansion rows below too):

| Instance | Home expansion | Status |
|---|---|---|
| Kings' Rest | Battle for Azeroth | shipped |
| Ruby Life Pools | Dragonflight | shipped |
| Temple of Sethraliss | Battle for Azeroth | shipped |

### Midnight raids

The launch tier is **four separate raid instances**, not one — which is why WCL
folds them into a single zone 46. Boss-to-raid mapping confirmed 2026-09-08
against Icy Veins' Season 1 raid guide and cross-checked against the addon's
own crawled curve files.

| Instance | Bosses | Status |
|---|---|---|
| The Venomous Abyss (12.1) | 9 | drafted (8 reconciled, Nymrissa single-source) |
| The Voidspire | 6 | drafted |
| The Dreamrift | 1 | drafted |
| March on Quel'Danas | 2 | drafted (single-source, needs a second) |
| Sporefall | 1 | drafted |

- **The Venomous Abyss** — Nek'zali the Soulcoiler; then two wings (Entombed
  Sentinels → Vashnik the Malignant, and The Lost Explorers → Sszorak); then
  The Twin Fangs, The Coiled Altar, Ula'tek. Plus **Nymrissa Wavecaller**, an
  optional lair boss in Tidebound Grotto — that is the 9th encounter WCL
  reports while every guide says "8 bosses".
- **The Voidspire** — Imperator Averzian, Vorasius, Fallen-King Salhadaar,
  Vaelgor and Ezzorak, Lightblinded Vanguard, Crown of the Cosmos.
- **The Dreamrift** — Chimaerus, the Undreamt God. Single boss, in Harandar.
- **March on Quel'Danas** — Belo'ren, Child of Al'ar; Midnight Falls (L'ura).
- **Sporefall** — Rotmire. One boss, flex composition even on Mythic. The
  addon already ships `Data/Percentiles_Sporefall.lua` and
  `Data/KillTimes_Sporefall.lua` for it.

---

## MoP Classic — confirmed complete

Notes does not exist on this client yet: `Notes\*` is absent from
`TrueParse_Mists.toc`. Wiring it up is a prerequisite, and the view needs to
handle instances with no affixes and no keystone level (MoP has Challenge
Modes, not Mythic+).

### Dungeons (9)

| Instance | Level | Bosses | Status |
|---|---|---|---|
| Temple of the Jade Serpent | 80-90 (H90) | 4 | drafted (2 sources) |
| Stormstout Brewery | 80-90 (H90) | 3 | drafted (2 sources) |
| Mogu'shan Palace | 82-90 (H90) | 3 | drafted (2 sources) |
| Shado-Pan Monastery | 82-90 (H90) | 4 | drafted (2 sources) |
| Gate of the Setting Sun | 83-90 (H90) | 4 | drafted (2 sources) |
| Siege of Niuzao Temple | 83-90 (H90) | 4 | drafted (2 sources) |
| Scarlet Halls | 28-31 (H90) | 3 | drafted (2 sources) |
| Scarlet Monastery | 30-33 (H90) | 3 | drafted (2 sources) |
| Scholomance | 41-44 (H90) | 5 | drafted (2 sources) |

### Raids (5, 43 bosses)

| Instance | Bosses | Status |
|---|---|---|
| Mogu'shan Vaults | 6 | drafted (single-source) |
| Heart of Fear | 6 | drafted (single-source) |
| Terrace of Endless Spring | 4 | drafted (single-source) |
| Throne of Thunder | 13 | drafted |
| Siege of Orgrimmar | 14 | drafted |

Siege of Orgrimmar boss names are already confirmed from the crawled data:
Immerseus, Fallen Protectors, Norushen, Sha of Pride, Galakras, Iron
Juggernaut, Kor'kron Dark Shaman, General Nazgrim, Malkorok, Spoils of
Pandaria, Thok the Bloodthirsty, Siegecrafter Blackfuse, Paragons of the
Klaxxi, Garrosh Hellscream.

---

## OUT OF SCOPE — pre-TWW legacy raids

**Not planned, not queued.** Decided with Josh 2026-09-08 after the rest was
finished. Listed here so the boundary is explicit rather than implied by rows
that sit at `todo` forever.

Why: none of these has a live max-level audience. They are soloed for
transmog, mounts and achievements, where a cheat sheet earns nothing — the
whole premise of the Notes view is telling a *group* what is about to happen.
Sourcing also degrades the further back you go; the Warlords pool needed a
full re-source for exactly that reason, and it is far more recent than most of
this list.

The four exceptions are already done, because they are the ones people still
run: Black Temple, Ulduar, Firelands and Blackrock Depths are covered in
`tw-raids.md` as Timewalking raids.

To reopen: these are self-contained per raid, so any of them can be picked up
individually without disturbing what exists.

- **Classic** — Molten Core, Blackwing Lair, Ruins of Ahn'Qiraj, Temple of
  Ahn'Qiraj, Naxxramas (40), Onyxia's Lair, Zul'Gurub
- **The Burning Crusade** — Karazhan, Gruul's Lair, Magtheridon's Lair,
  Serpentshrine Cavern, The Eye, Battle for Mount Hyjal, Black Temple,
  Zul'Aman, Sunwell Plateau
- **Wrath of the Lich King** — Naxxramas, Obsidian Sanctum, Eye of Eternity,
  Vault of Archavon, Ulduar, Trial of the Crusader, Onyxia's Lair, Icecrown
  Citadel, Ruby Sanctum
- **Cataclysm** — Baradin Hold, Blackwing Descent, Bastion of Twilight, Throne
  of the Four Winds, Firelands, Dragon Soul
- **Mists of Pandaria** — as the MoP Classic section above
- **Warlords of Draenor** — Highmaul, Blackrock Foundry, Hellfire Citadel
- **Legion** — Emerald Nightmare, Trial of Valor, The Nighthold, Tomb of
  Sargeras, Antorus the Burning Throne
- **Battle for Azeroth** — Uldir, Battle of Dazar'alor, Crucible of Storms,
  The Eternal Palace, Ny'alotha the Waking City
- **Shadowlands** — Castle Nathria, Sanctum of Domination, Sepulcher of the
  First Ones
- **Dragonflight** — Vault of the Incarnates, Aberrus the Shadowed Crucible,
  Amirdrassil the Dream's Hope
- **The War Within** — **done**, see the section below
- **Midnight** — as the Midnight section above

### The War Within — done 2026-09-08

Pulled forward out of the legacy backlog: TWW is the expansion immediately
before Midnight and sits in no Timewalking pool, so it was filed next to
Molten Core despite being far more likely to be run.

| Instance | Type | Bosses | Status |
|---|---|---|---|
| Ara-Kara, City of Echoes | dungeon | 3 | drafted |
| The Stonevault | dungeon | 4 | drafted |
| The Dawnbreaker | dungeon | 3 | drafted |
| City of Threads | dungeon | 4 | drafted |
| The Rookery | dungeon | 3 | drafted |
| Priory of the Sacred Flame | dungeon | 3 | drafted |
| Darkflame Cleft | dungeon | 4 | drafted |
| Cinderbrew Meadery | dungeon | 4 | drafted |
| Operation: Floodgate | dungeon | 4 | drafted |
| Eco-Dome Al'dani | dungeon | 3 | drafted |
| Nerub-ar Palace | raid | 8 | drafted |
| Liberation of Undermine | raid | 8 | drafted |
| Manaforge Omega | raid | 8 | drafted |

Two more non-fixed boss sequences found here — Nerub-ar Palace (free choice
after Rasha'nan) and Liberation of Undermine (four free middle bosses). That
makes five across the corpus, alongside Eye of Azshara, End Time and Priestess
Delrissa's random adds.

### Timewalking pools — the legacy that actually gets run at cap

Confirmed against the Warcraft Wiki Timewalking page, 2026-09-08. Ten pools,
59 dungeons, 4 raids. This is the priority slice of legacy: these are the old
dungeons players queue into at max level, so they are the ones where a note
still earns its place.

| Pool | Dungeons | Status |
|---|---|---|
| Classic | Deadmines, Zul'Farrak, Dire Maul (Warpwood Quarter), Dire Maul (Capital Gardens), Stratholme (Main Gate), Stratholme (Service Entrance) | drafted |
| Burning Crusade | The Blood Furnace, The Botanica, Magisters' Terrace, Mana-Tombs, The Shattered Halls, The Underbog | drafted |
| Wrath | Azjol-Nerub, The Forge of Souls, Gundrak, Halls of Lightning, The Nexus, Utgarde Keep | drafted |
| Cataclysm | Blackrock Caverns, End Time, Lost City of the Tol'vir, Stonecore, The Vortex Pinnacle, Throne of the Tides | drafted |
| Mists of Pandaria | Gate of the Setting Sun, Mogu'shan Palace, Scholomance, Shado-Pan Monastery, Stormstout Brewery, Temple of the Jade Serpent | **already drafted** |
| Warlords | Auchindoun, Bloodmaul Slag Mines, The Everbloom, Grimrail Depot, Shadowmoon Burial Grounds, Skyreach | drafted (re-sourced) |
| Legion | Black Rook Hold, Eye of Azshara, Darkheart Thicket, Vault of the Wardens, Neltharion's Lair, Court of Stars | drafted |
| Battle for Azeroth | Atal'Dazar, Freehold, Kings' Rest, Shrine of the Storm, Temple of Sethraliss, Waycrest Manor | drafted (4; 2 shipped) |
| Shadowlands | De Other Side, Halls of Atonement, Necrotic Wake, Plaguefall, Sanguine Depths, Spires of Ascension | drafted |
| Dragonflight | Algeth'ar Academy, Halls of Infusion, Neltharus, Ruby Life Pools, The Azure Vaults, Brackenhide Hollow | drafted (5; Ruby Life Pools shipped) |

| Timewalking raids | Black Temple (9), Ulduar (14), Firelands (7), Blackrock Depths (8) | drafted |

Blackrock Depths is the 20th-anniversary Timewalking raid (added 11.0.5,
10-15 players); it returned in 2025 as Raid Finder only.

**Free coverage already banked:** the entire MoP Timewalking pool is the same
six encounters drafted for MoP Classic — same bosses, same mechanics, one set
of notes serves both clients. Ruby Life Pools, Kings' Rest and Temple of
Sethraliss are already shipped in `Notes/Season2.lua` as Season 2 pool
dungeons. So 9 of the 59 are done before legacy work starts.

### BLOCKER FOUND: `KN.dungeons` is keyed by name, and names collide

**Magisters' Terrace exists twice.** Midnight ships a dungeon by that name
(Arcanotron, Seranel Sunlash, Gemellus, Degentrius — drafted in
`retail-magisters-terrace.md`) and the Burning Crusade Timewalking pool
contains the original (Selin Fireheart, Vexallus, Priestess Delrissa,
Kael'thas Sunstrider). Same English journal name, completely different boss
lists.

`KN.RegisterDungeon` does `KN.dungeons[def.name] = def`, so registering both
silently discards one — and `Tracker.Preview` matches on a name substring, so
it would find whichever survived. Whoever plans the implementation has to
re-key the registry on the journal **instanceID** (which `Journal.CurrentInstance`
already returns) or on name-plus-expansion, before any legacy content is
written. This is not hypothetical: it lands the moment the TBC pool is added.

Stratholme and Dire Maul are a milder version of the same problem — the pool
lists them as wings ("Main Gate", "Service Entrance", "Warpwood Quarter",
"Capital Gardens"), which may or may not be how the journal names them.

---

## Decisions (Josh, 2026-09-08)

These settle three of the open questions and cut the remaining scope sharply.

1. **Trash notes are a Mythic+ feature.** They belong only where route
   knowledge actually matters. Consequences:
   - **Raids carry no trash at all.** This dissolves the parallel-wing problem
     — with no trash there are no legs to order, so The Venomous Abyss' two
     wings need nothing special. Raid instances are boss-only.
   - **Legacy content is boss mechanics only, no trash.** A Timewalking or
     transmog run does not need pack-by-pack notes.
   - The current-tier M+ pool keeps its full trash treatment, and so do the
     four Midnight dungeons outside the pool, since they are M+-capable and a
     future season can pull them in.
2. **A line is shown only to players who can actually act on it.** Divine
   Shield needs Mass Dispel, so that line goes to Priests who have Mass Dispel
   and to nobody else — not to every purge-capable spec. The same principle
   settles the fear gap by extension: a fear line goes only to specs that can
   actually answer a fear.
3. **Legacy treatment is the thin one:** the bosses, and the two or three
   lines that still kill people. Not full per-role coverage.

## Verified capabilities, 2026-09-08

Researched against live sources rather than assumed:

- **Mass Dispel is baseline for all three Priest specs in Midnight** —
  `massdispel` on Discipline, Holy and Shadow is correct.
- **Fear Ward was removed in patch 7.0.3 and no longer exists.** Priests had
  been given `fear` on that basis; the key is removed. A Priest's answer to a
  fear is an ordinary magic dispel, which `magic` already covers.
- **Tremor Totem still exists** and is the Shaman's fear answer, so `fear`
  stays on all three Shaman specs — but as of patch 12.0.0 it is a **choice
  node against Poison Cleansing Totem**, so a Shaman has one or the other,
  never both. The `BUILD` line mechanism already exists to tell a Shaman which
  one a given dungeon wants.

## Implemented 2026-09-08

The three decisions above are now in code, with `tests/notes.lua` covering
each (33 checks, all green; `run.lua`, `validate.lua` and `load.lua` clean):

- `KN.RegisterRaid` (`Notes/Core.lua`) registers a boss-only instance and
  **errors** on a `trash` table rather than dropping it silently.
  `RegisterDungeon` now stamps `kind = "dungeon"`.
- `trashApplies()` (`Notes/Tracker.lua`) gates the trash section on keystone
  difficulty. Below a key the next boss still previews, so nothing is lost.
- A raid with no active boss lists its bosses instead of naming one "next" —
  `killed` is only a count, so with parallel wings "next" would be a guess.
  `Tracker.Step` is inert in a raid.
- `fear` and `massdispel` are capability keys (`Notes/Classes.lua`), with
  `FEAR` / `MASSDISP` tags, icons and colours, and entries in `TAG_NEED` so
  tag alternatives resolve. Priests carry both (**provisional** — verify per
  spec against the live spellbook); Shamans carry `fear` for Tremor Totem.

## Code prerequisites still open

The research keeps hitting things the Notes system cannot express yet. None of
these are content problems — they are code that has to exist before the
corresponding notes can ship.

### Raids

1. **Raid difficulty ids are missing.** `KN.DIFF_BY_ID` (`Notes/Core.lua`) maps
   only 1, 2, 23, 8 and the two Timewalking ids. Raids report 17 = LFR,
   14 = Normal, 15 = Heroic, 16 = Mythic. Until those exist, no raid note can
   be gated by difficulty, and LFR needs a rank below `n` in `KN.DIFF_RANK`.
2. ~~Trash legs assume a straight line.~~ **RESOLVED** by decision 1: raids
   carry no trash, so there are no legs to order and the parallel wings of The
   Venomous Abyss need nothing. `RegisterRaid` should simply not accept a
   `trash` table.
3. **Three core lines is tight for a raid.** Several of these fights have four
   or five things that genuinely wipe a pull. Widening the rule for raids is a
   design decision, not something to do quietly. Still open.

### Capabilities

4. **Fear removal.** Vaelgor and Ezzorak's Dread Breath is a dispellable fear.
   Per decision 2 this needs its own capability key — a fear is answered very
   differently by Tremor Totem, Fear Ward, Berserker Rage and a magic dispel,
   so `magic` is the wrong proxy.
5. **Mass Dispel.** Lightblinded Vanguard's Divine Shield needs Mass Dispel
   specifically. Per decision 2 this gets its own capability key set on the
   Priest specs that have it — **not** `class = "PRIEST"`, which would show it
   to a Priest spec lacking the spell, and not `PURGE`, which would show it to
   every purge-capable spec.

Both are the same shape: a new key in the `KN.CLASSES` capability row, tested
the way `tests/notes.lua` already tests kick/purge/poison — the existing audit
loop fails any spec that sees a line for a tool it does not have, so adding the
key to the audit is most of the work.

### MoP Classic

6. **`Notes\*` is not in `TrueParse_Mists.toc` at all.** Wiring is step one.
7. **The view assumes affixes and a keystone level.** MoP has Challenge Modes,
   not Mythic+, so the header needs a no-affix, no-key shape. `tests/notes.lua`
   already exercises the header's affix and level fields, so it will need a
   Mists case.
8. **`Notes/Classes.lua` is a retail capability table.** MoP specs have
   different tools; the retail healer-interrupt removals do not apply there. A
   separate Mists capability table is required, and `KN.CLASSES` is keyed by
   spec id, which overlaps but does not match.

## OUT OF SCOPE — legacy dungeons outside the Timewalking pools

**Not planned, not queued**, same decision and same reasoning as the legacy
raids above.

Each expansion has roughly twice as many dungeons as its Timewalking pool
holds, and the pool is the curated subset players actually queue into at max
level. Roughly 70 dungeons sit outside those pools. If a future patch adds one
of them to a pool, that single dungeon is worth doing then — the pools are the
right trigger.

---

## ANSWERED — the Adventure Guide's bullets are readable, and usable

Probed in game 2026-09-08 (`/kn journal`, `/kn journal overview`) in Murder
Row. Result: **yes**, and the journal's own structure is close to the schema
`Season2.lua` already uses.

### What the journal actually exposes

Each encounter carries `headerType == 3` overview sections:

```
[31279] Overview          hdr=3   (1 bullet, scene-setting)
  [31280] Damage Dealers  hdr=3   flags 1=1   3 bullets
  [31281] Healers         hdr=3   flags 1=2   3 bullets
  [31282] Tank            hdr=3   flags 1=0   3 bullets
```

- **Role comes as data**, via `C_EncounterJournal.GetSectionIconFlags`:
  `0` = tank, `1` = damage, `2` = healer.
- **Bullets are separated by the literal token `$bullet;`** inside
  `description`.
- **Ability sections carry effect flags too.** Envenom and Heartstop Poison
  both show `2=9`, and both are poisons — so dispel school is reachable per
  ability, not only per role.
- **`filteredByDifficulty` works** (Fel Nova, Freight Explosion,
  Fel-Infused Freight), which we already consume.
- **The language is imperative, not descriptive**: "Avoid Nibbles' [Fel
  Spray]", "Interrupt Kystia's [Mirror Images]", "Get to cover!". This was the
  thing I expected the journal to fail at, and it does not.

### The shape maps onto ours almost exactly

Kystia Manaheart, in full:

| | bullet 1 | bullet 2 | bullet 3 |
|---|---|---|---|
| Damage | Illicit Infusion | Avoid Fel Spray | **Interrupt Mirror Images** |
| Healer | Illicit Infusion | Avoid Fel Spray | **Heavy damage while Destabilized** |
| Tank | Illicit Infusion | Avoid Fel Spray | **Interrupt Mirror Images** |

Two bullets shared by every role, one that differs. That is `core` plus a
per-role `note` — the exact split this project arrived at independently.

**A derivation algorithm I proposed and the data then killed.** From the
Kystia sample it looked like "bullets in all three role sections are `core`,
bullets unique to one are that role's note". Ula'tek (Venomous Abyss) breaks
it outright — its three role sections share **nothing**:

- Damage: Blightscale Spawn hatching, Blightscale Clutch, Doomscale Wardens
- Healer: Putrid Membrane raid damage, Spectral Coils soak-splitting
- Tank: Unchecked Rage, Rattler Slam, Mother's Wrath

Intersection would yield zero core lines. So:

- **Per-role notes: reliably generated.** The role sections are role-tagged
  and, on a real raid boss, genuinely role-specific.
- **`core`: not reliably generated.** The only role-neutral section is the
  `Overview` (role=nil), and on Ula'tek that is three paragraphs of scene-
  setting prose, not bullets. Core lines stay hand-written.

### What it still does not give

- **Capability routing.** "Interrupt Kystia's Mirror Images" goes to a *role*,
  not to whoever actually owns an interrupt. `need`, `massdispel` and `fear`
  exist precisely because role is the wrong axis. The per-ability effect flags
  (poison, magic...) partly bridge this — a role bullet names `[Spell]`, and
  that spell's own section carries the school — but nothing in the journal
  knows that Divine Shield needs Mass Dispel specifically.
- **Depth.** One role-specific bullet per role. Our boss entries carry several.
- **Timing and positioning specifics** — "at 66%", "under Tyrannical", "drop it
  at the edge", "the tank snaps last".
- **Everything that is not a boss ability:** lust calls, `BUILD` talent
  reminders, `TASK` gates (free the snitches, take the Arcane Tome, a Rogue
  switches off the tripwires, equip the Reshii Wraps).
- **Trash**, which is the entire M+ half of the feature.
- Tank and Damage bullets were *identical* on this boss, so the role split is
  partly cosmetic. One sample; needs confirming across more encounters.

### What this means for the plan

The default inverts. Generate `core` and a baseline role note from the
journal for **every instance in the game**, and keep the hand-written corpus
as the curated overlay where it beats that: capability routing, trash, lust,
build and task lines, and sharper core lines.

**It does NOT reopen the out-of-scope blocks.** Probed 2026-09-08: Molten
Core's Ragnaros returns `root=0` and no `hdr=3` sections at all — the journal
entry is empty. Legacy content has no overview bullets and no ability tree to
read, so generated coverage is a **current-content feature**. The out-of-scope
decision stands on its own merits.

Where the cutoff sits is still unknown and worth one probe pass: Venomous
Abyss (Midnight) is rich, Molten Core (Classic) is empty. Somewhere between
those the journal starts carrying overview sections, and that boundary decides
how much of the Timewalking corpus a generator could ever replace.

Probes are in the code and are diagnostic-only:
`Journal.DumpSections`, `Journal.Overview`, `/kn journal [overview] [boss]`.

## Research status

| Block | State |
|---|---|
| Retail — Midnight | complete: 9 dungeons, 5 raids |
| Retail — The War Within | complete: 10 dungeons, 3 raids |
| MoP Classic | complete: 9 dungeons (2 sources), 5 raids |
| Timewalking | complete: 59 dungeons, 4 raids |
| Pre-TWW legacy raids | out of scope |
| Legacy dungeons outside the pools | out of scope |

Everything in scope is drafted. What remains before any of it ships is
verification work, not research: the second-source pass on the blocks still
marked single-source in their own files, and the handful of named conflicts
those files record.
