# TrueParse Changelog

## 2.11.0

**Fixes fights that were recorded as far longer than they really were, which
pushed every score in the group down at once.**

If a pull ended and the group stayed in combat - the usual case after a wipe,
with a lingering add or a damage-over-time effect still ticking - the next
fight's timer could start immediately and keep running through the whole
release and run back. One Heroic Norushen kill was recorded as nine minutes
when the fight itself lasted six, with over three minutes of nothing at the
front of it.

Every per-second number divides by that clock, so damage, healing and tank
mitigation uptime were all understated together. It does not look like a
timing bug when you see it: it looks like the whole group played badly. On
that pull, everyone scored an average of 29 points below their actual
Warcraft Logs parse, and the ranking barely resembled theirs. On the corrected
clock the same pull lands within 3 points of Warcraft Logs and the ordering
matches.

The intro before a boss is still counted, because Warcraft Logs counts it too
and scores are meant to line up with theirs. Only dead time far longer than
any intro is now treated as a fight that had not started yet.

This affects fights recorded from now on. Fights already in your history keep
the length they were saved with.

**The fight list has been rebuilt.** It now shows which difficulty each pull
was, on the row itself rather than the heading, so a night that switches
between Normal and Heroic reads correctly instead of showing the same raid
name three times over. Difficulty is colour-coded the way the game does it.

Wipes now say how much boss was **left**. That figure was always the boss's
remaining health, but nothing said so, and on a boss whose health refills
between phases "P2 0%" could easily read as a kill while a worse pull showed a
bigger number. The deepest attempt on each boss is marked, so the night's
progress reads at a glance instead of being worked out row by row.

The list also scrolls now - it never did - and shows arrows when there is more
above or below.

**Mists tanks on Heroic are now compared against Heroic tanks.** Both tank
baselines were built only from Normal logs and then used for Heroic as well,
which made tanks the one role measured against players who had not run the
same content. **Expect Heroic tank scores to go down.** Heroic tanks hold
active mitigation up more than Normal tanks do, not less, and contribute more
of their group's damage, so the correct comparison is a harder one. Normal
raids, dungeons and retail are unaffected.

## 2.10.2

**Fixes the load-time error on the addon list, reported against 2.10.0 and
2.10.1.** Thanks to MrFIXIT on CurseForge for the report.

The addon's file list referenced `Core/Build.lua`, a file that exists only in
a development copy and was never meant to be part of a release. The published
zip correctly did not contain it, but the file list still asked for it, so
every client complained about a missing file on login. Nothing was actually
broken - no feature depended on that file - but the warning was real and
should never have shipped.

The release build now omits the reference entirely, and the test suite fails
the build if any listed file would be absent from the published package.

## 2.10.1

**Fixes two mistakes in 2.10.0 that affected healers in five-player content.**

A healer's damage stopped being scored in dungeons in 2.10.0, because there
is no fair way to measure it there. That was right, but it left the card
showing a damage row reading **zero** - an unmeasurable number displayed as a
measured bad one. It now reads as context and says so.

Worse, on Mists it also removed the metric without anything to replace it.
The healing side of that swap only exists on retail, so Mists healers in
five-player content were left resting entirely on the one comparison we
already knew was poor there. They keep their damage score until the
replacement reaches that client.

**A healer's damage in five-player content now earns credit instead of being
ignored.** It still is not graded - there is no honest baseline to grade it
against - but out-damaging your own party is a real contribution, and reading
it as nothing was wrong. It is measured against what your group's damage
dealers actually did, capped, and can only ever help: a healer who skips it
is never penalised.

**Scores on content Warcraft Logs does not rank are no longer confidently
extreme.** Timewalking damage was reading either near-zero or near-perfect
with little in between - nearly two in five scores sat above 90 - because
those comparisons are stretched from other content and a few percent of
output swung the result end to end. A comparison that uncertain should not
produce a confident verdict, so those scores are now drawn toward the middle,
harder the further the comparison had to reach. Rankings within a fight are
unchanged; only the confidence is. Timewalking now lines up with raid scoring
where it used to sit twenty points off.


## 2.10.0

**Scores move in this release, and career stats reset because of it.** Three
things changed about how contribution is measured, so old career averages and
new ones are no longer the same scale. They retire on first login and
re-accumulate.

**Tanks are no longer scored on their share of the group's damage.** A share
falls as the group grows, so one baseline could never fit both a ten-man and a
twenty-five-man raid: measured on real fights, ten-man tanks cleared their own
top quartile on 65 of 69 pulls and simply scored 100, while twenty-five-man
tanks fell below the bottom quartile for the same quality of play. Tank damage
is now measured against what an average group member did, which does not
depend on how many people are standing there. Both game versions were
re-measured against Warcraft Logs for it.

**Healers in five-player content are scored on how much of the group's damage
they covered, not on healing per second.** Healing rate in a dungeon mostly
reflects how much damage the group took, which is mostly avoidable - so it paid
a healer for their group standing in fire. In the same Mythic+ runs, healers
were averaging 88 while damage dealers averaged 12. Coverage measures the same
healer against what was actually theirs to heal, after subtracting whatever the
group healed itself, so a self-sustaining tank no longer costs the healer.

The baseline for it comes from real recorded runs rather than ranked Warcraft
Logs runs. Ranked five-player logs turned out to be a narrow slice of unusually
strong groups - narrow enough that essentially every ordinary healer fell below
their bottom quartile - so 50 now means an average healer in the content people
actually run. Raid healing is untouched; it already matched ranked logs closely.

**A healer's damage is no longer scored in five-player content.** There is no
fair way to measure it there: as a rate there is nothing to compare against,
and as a share of the group it mostly measures how weak the damage dealers
were. It was handing out most of a free grade - more than half of those scores
sat above 90. Its weight moved onto healing. Raid healers keep the metric.

**TrueParse mode now adjusts for item level; Raw mode still does not.** That is
the difference between the two, and until now it only applied to content
Warcraft Logs does not rank. On a Mythic+ run, gear alone accounted for about a
fifth of the score - roughly thirty points across a normal spread of gear - so
an undergeared player could not climb out of grey and an overgeared one could
not fall out of gold. Raw remains exactly what Warcraft Logs would tell you.
Both mode buttons now say which they are.

**New: "/tp who" and "/tp diag".** The first lists who in your group is running
TrueParse and on what version - which tells "they have an old build" apart from
"they uninstalled it". The second prints everything a bug report needs on one
copyable line, including any errors the addon has hit. TrueParse now records
its own errors instead of discarding them silently, so a problem leaves
evidence rather than just a wrong number.


## 2.9.3

**Players on your own realm now register as running TrueParse.** Every message
the addon sends is stamped with the sender's full name and realm, but the name
TrueParse read back from the group only carries a realm when that player is on
a *different* one. The two never matched for anyone on your realm, so their
messages were discarded on arrival.

They showed as not having the addon, and every number a player can only report
about themselves came through as "?" - most visibly a tank's active-mitigation
uptime on retail, which has no other source. A wipe call from an officer on
your realm was ignored for the same reason. It looked like a version problem
because connected realms count as cross-realm, so most of a pug worked.

**Damage dealt to a mind-controlled ally no longer counts as damage done.** The
combat log flags a controlled player as an enemy, so the check that ignores
friendly fire let it through. On Paragons of the Klaxxi, where Kaz'tik controls
raid members, this inflated whoever broke the control - measured at 1.26x to
1.73x on the players doing it, while everyone else was unaffected. Warcraft
Logs does not count it either.

"/tp procs" now also lists group damage by target for the last pull, so a
fight's numbers can be checked against a log's own by-target breakdown.


## 2.9.2

**Fixes a Lua error in Delves, and anywhere else a target's name is hidden.**
Midnight returns many values as "secret" - readable only by Blizzard's own
secure code - and touching one throws. The check meant to skip those values
was written after the comparison it was supposed to protect, so the
comparison ran first and errored. It only escaped the 2.9.0 release because a
training dummy standing in a city is one of the few targets whose name is
readable; in a Delve it fires repeatedly.

The same shape was found in three more places, waiting on a hidden zone name,
and all four now check before they compare. A source check was added so this
class of mistake fails the test suite rather than a player's session - it
cannot be caught by running the code outside the game, because the error needs
a live client that actually hides the value.


## 2.9.1

**The rotation coach stops advising players on a build they aren't playing.**
A Fistweaver Mistweaver heals by meleeing and casts almost none of the caster
rotation the spec's profile is built from - so the card scored one 99 for
healing and, in the same breath, told them to cast four spells more, each
"you 0". The coach was comparing real play against a rotation that did not
describe it.

It now checks whether the profile fits before judging anyone by it. A player
producing only a token fraction of their spec's expected cast volume is either
running a different build or wasn't fully captured - those look identical from
one fight, and both mean the same thing: we have not earned the right to say
what they're missing. The coach and the rotation table stay quiet instead.
Players running the profiled build who are simply behind still get advice, and
genuine inactivity is unaffected - the activity metric measures time rather
than spell choice.

This is a guard, not a cure. A spec with two real builds wants two profiles,
and Warcraft Logs' rankings aren't split that way, so a player who runs some
of the profiled rotation can still be measured against a build they're only
half using.


## 2.9.0

**Mythic+ is scored against your own key level.** Warcraft Logs ranks dungeons
by keystone level, and the gap between bands is enormous - a Frost Mage's
median on one dungeon is 50,033 damage per second at +2 and 132,283 at +14,
2.6 times higher. TrueParse had one curve per dungeon covering all of it: the
top 2000 runs by keystone score, a population containing nobody running a +2.
Low keys were corrected toward it with gear scaling and a flat lift, which was
always an approximation of something that could simply be measured.

It is measured now. Curves are crawled per keystone band - 8 dungeons, five
bands, two million ranked parses - and a key is compared against players who
ran the same key level. That makes it a DIRECT comparison: no gear
normalisation, no difficulty correction, just your output against the field's.
A well-geared player naturally scores higher and an undergeared one naturally
scores lower, which is what the number should have meant all along.

Expect your Mythic+ scores to move, in both directions. On a real +2/+3 night
they went from a median of 3.5 (against the old elite curve, where 97.6% of
players scored under 10) to a median of 30. An earlier fix had over-corrected
these to a median of 72; that was generous, and this replaces the correction
with the actual population.

Keys far above every crawled band fall back to the previous behaviour rather
than being measured against a much lower one.

**Wipes on phase bosses say which phase.** Garrosh's health goes back up when
he is empowered, so his percentage is per-phase: one wipe recorded 79.6% and
another 5.2%, and every comparison in the addon reads lower-as-deeper, so the
shorter pull looked like the better one. Phases are counted now, "deepest push
yet" ranks by phase before percentage, and the label reads "wipe P3 80%" where
a boss has refilled. Bosses that never refill are unchanged.

**Group damage spikes stop blaming melee.** Auto-attacks were already excluded
from detecting a group spike - they are the fight's baseline, not a moment to
answer with a raid cooldown - but the label came from a shared map that still
included them, so a spike built entirely from spell damage could be named
after a tank's melee that contributed none of it.


## 2.8.1

**A tank's grade now follows the fight.** Mitigation uptime is 55% of a tank's
score and it prices exactly one thing: how well they blunted incoming damage.
On a pull where almost nothing reached them there was nothing to blunt, so
that weight was measuring the fight rather than the player. When a tank's
share of the group's damage taken falls well below what a tank normally
absorbs, mitigation weight slides toward zero and moves to damage and healing
instead - the mirror of the shift healers already got when there is nothing to
heal. Measured across real history it applies to roughly a third of Mists tank
fights and a fifth of retail ones, and usually only slightly.

Mitigation also always shows a number now. A measured zero is a reading, not a
gap; only a genuinely absent one still reads "?". That is safe precisely
because of the shift above - on a fight that barely touched the tank, an
honest zero costs almost nothing instead of most of their grade.

**Mists Challenge Mode scores were badly wrong, in both directions at once.**
Kill-duration data is merged into the same table as the percentile curves, so
a dungeon TrueParse has no curves for still looked like it had them. Those
fights were labelled tier II - "this dungeon's real curves, scaled to your
gear" - while actually being scored against pooled raid logs, and took tier
II's correction rather than tier III's. The result inverted rankings: on one
real pull the top damage dealer scored 7 and the player doing half their
damage scored 87, because the better-geared one sat at the reference item
level and the other collected a 3x discount. A kill-times-only dungeon is now
tier III, "nothing on Warcraft Logs covers this fight", which is the truth.

**Losing threat has some tolerance now.** Both the ripped-aggro and lost-aggro
penalties charged on the first sample, so the ordinary sequence of play - a
damage dealer reaches an add first, the tank taunts it a second later - was
charged to both of them. A rip now needs two consecutive samples, and the
first few seconds of any loss are treated as the pickup rather than a failure
to pick up. A tank moving between packs pays nothing; one who never picks it
up still does.

**Mists has no Mythic+.** Three surfaces said it anyway - the metric tooltip
and both tier footnotes. They name Challenge Mode there now.

**Also.** A cross-realm tank's mitigation reading is recorded properly (the
role check consulted a roster that often does not know them). Niuzao's
celestial proc is identified but deliberately not yet excluded: its name
collides with Elemental Shaman's Earthquake, and excluding it by name would
delete a real spell's damage - it goes in by spell id once that id is known.


## 2.8.0

**Mythic+ and Timewalking scores were impossible, and now aren't.** Measured
across 70 real player-scores from a Mythic+ night: the damage median was 3.5
out of 100, with 97.6% of players under 10. Two defects stacked. The reference
curve TrueParse pooled for unranked content was built the wrong way round, so
it had almost no lower tail - below about 0.81x the median, scores fell off a
cliff and a 13% drop in output cost 30 percentile points. And a low key was
compared against Warcraft Logs' dungeon rankings, which are the top 2000 runs
BY KEYSTONE SCORE - a high-key population that contains nobody running a +2.
Low keys now take the derived path with gear correction, and the pooled
reference is built from raid logs, which have a realistic spread. The same 70
scores now read a median of 71.9 with none under 10. Timewalking's median went
from 38.7 to 59.7 and its gray parses from 29% to 21%.

**Retail tanks are measured again.** Midnight returns every field of your own
auras as a secret value - a diagnostic with Shield of the Righteous visibly up
read 13 auras and could identify none of them - so every aura-sampling
collector had been reading nothing and reporting it as zero. Mitigation uptime
is now reconstructed from your own casts, which stay readable, and all six
tank specs have a crawled Warcraft Logs field to be scored against rather than
falling back to another spec's numbers.

**Flask and food stopped costing you points for consumables you drank.** Same
cause: an aura whose id we cannot read is not an aura that isn't there. A
retail player with a flask and hearty food up counted zero and ate the full
penalty regardless. Any unreadable aura now voids the count rather than
scoring it as absent, and a lookup that throws outright is treated as "we
could not see", not "there was nothing". On Midnight the honest outcome is
neutral - no penalty and no bonus - because the client will not tell us what
you drank.

**Three cards said something untrue.** A spike band with no detail blamed the
capture's age - "recorded before hit tracking" - on fights that had finished
minutes earlier; the real reason is that Midnight has no combat log, and the
detail can never arrive. A healer who covered a five-man's damage was told
"little to heal", because the demand test compared the fight's intake against
a RAID spec's median output, which it will almost always lose. And a
Retribution Paladin was penalised for not dispelling: the eligibility check
consults the fight's debuff types, that list is built from the combat log, and
on Midnight it is never learned - so a Poison-and-Disease cleanser was charged
a share of dispels that may all have been Magic.

**Training dummies capture as practice fights.** They score against the tier's
patchwerk boss - Iron Juggernaut on Mists, and on Midnight Vorasius, which
measurement picked: it takes 96.1% of the raid's damage on a single target,
ahead of every other fight in the zone. Practice never counts toward your
career, run averages, personal bests or trends; it is graded on its own card
and goes no further.

**Smaller things.** Adjustment points show one decimal, so two -0.6 penalties
no longer read as "-1 and -1" over a "-1" total, and adjustments under half a
point are shown rather than hidden. Death dots on the fight-shape graph can be
hovered for who died and what killed them. The Bloodlust window is marked on a
tank's timeline, not just a damage dealer's. Tank damage anchors are no longer
applied in five-mans, where they were raid-shaped. Adds taunting off a tank no
longer count as losing threat.


## 2.7.0

**Running TrueParse as a tank is no longer a penalty.** Mitigation uptime is
worth 55% of a tank's grade, and when a tank wasn't reporting it, that weight
was spread across damage and healing - which meant their grade quietly became
their damage meter, certifying elite mitigation on no evidence at all. It also
inverted the incentive: because the weight cancels out, reporting only helped
if your mitigation percentile beat your own throughput percentile. Measured
against real logs, a reporting tank was never ahead - four cases worse, two
tied, none better, worst case 44 points.

Unreported mitigation is now pinned at average instead of redistributed - the
honest "we didn't measure this" - which is the same treatment an Augmentation
Evoker without an uptime report already got. Break-even now sits exactly at
your spec's median uptime: hold it better than the average player of your spec
and reporting gains you points, hold it worse and it costs you. The number
shows as "?" rather than a score, so an assumption never reads as a
measurement, and the breakdown card says so outright.

Tanks not running TrueParse will stop reaching top scores. That's the point -
those scores were claiming something never observed - but it is a visible
change to how your group's tanks rank.

## 2.6.2

**Derived scores stop handing out elite parses.** For content Warcraft Logs
doesn't rank, TrueParse builds a reference curve by pooling every curve it has
for your spec. That pooling was flattening the result: curves from easy and
hard encounters were averaged together directly, so the reference came out
compressed and anything above average shot to the top of it. Each curve is now
normalised to its own shape before pooling, which keeps the spread intact.
On top of that, approximate scores are capped at 95 and rough ones at 90 - not
clamped, but compressed above 70, so the ordering survives and players don't
pile up on the ceiling. A derived tier is an estimate against players who never
ran this content; it shouldn't be able to certify a top-1% parse.

**One mistake can no longer spend your entire penalty budget.** Avoidable
damage was capped at 15 points - exactly the cap on all adjustments combined -
so a single bad night on mechanics could max out the penalty by itself. It's
capped at 9 now. The overall +/-15 range is unchanged; reaching it just takes
more than one thing going wrong.

**Tank mitigation gets the same colour bar as everything else.** Now that
mitigation is scored against crawled per-spec Warcraft Logs baselines, it's a
real population percentile, so it's coloured like one instead of using flat
verdict colours.

**Career stats reset once after a scoring change.** Career totals are banked
when a fight is captured, while fight scores are recalculated every time you
look at them - so after a recalibration your career GPA was averaging retired
numbers against current ones. Stats now clear once when scoring changes
materially and re-accumulate under the new rules. It happens once per
character, and says so when it does.

## 2.6.1

**Tank mitigation is now scored against real Warcraft Logs data.** 2.6.0
turned tank mitigation tracking back on, but it was still measured against a
placeholder baseline carried over from Classic - and on retail that
placeholder was far too generous. A tank holding average uptime for their
spec was scoring 94 out of 100 on the metric worth over half their grade.
Four specs now carry crawled per-spec baselines (Protection Warrior,
Guardian Druid, Blood Death Knight, Vengeance Demon Hunter) and any spec
without enough samples falls back to the middle of those rather than to a
guess. Expect retail tank scores to drop by roughly twenty points, which is
where they should have been.

**Timewalking scores were too high.** Item level barely matters in
Timewalking - the game scales everyone to a common power level - but the
addon was correcting for gear as if it were a normal fight, inflating those
scores. Measured against real logs, item level predicts output six times
less strongly in Timewalking than at max level. Corrected, and the
content-difficulty adjustment now carries that gap explicitly. Timewalking
scores drop back in line with everything else; nothing outside Timewalking
changes.

**Healers are graded on the fight they actually got.** When there is little
or nothing to heal, healing now counts for less and damage for more - all
the way to being graded like a damage dealer when no damage went out at all.
A normal amount of incoming damage keeps the usual balance. Judged per spec,
against how much that spec normally heals.

**Fixes**

- The tier tooltip said scores were "ranked at the difficulty you played,
  any Mythic+ key counts", which read as dungeon-only inside a raid. It now
  names both. The Tier III tooltip also still described comparing against
  other dungeons, which stopped being true in 2.6.0.

## 2.6.0

**Mythic+ parses were wrong for everyone.** Every M+ score read between 94
and 99 regardless of how the fight actually went - a p10 player and a p90
player got the same number. Warcraft Logs orders dungeon rankings by
keystone score rather than by damage or healing, so the correction that
converts a sampled rank into a true percentile was reading a keystone-sorted
list as if it were sorted by output. M+ now reports a real percentile, and
a round-trip test pins it: a player built at exactly p75 of the curve scores
75, in every raid bracket and every dungeon, on both clients.

**Scores on unranked content are steadier.** Tiers II and III used to scale
against the dungeon's own Mythic+ curves, and those curves are far too flat
to scale against - half the p50-to-p99 range is only 25% of output, while
the gear correction multiplies by three to five times. Nothing landed in the
middle. They now scale against the raid curves, which have the range to
absorb it, and tiers II and III carry separate corrections instead of
sharing one. A player of unchanged skill now scores within a point of
themselves across a 100-item-level range, where before it moved 20 points.

**Grades.** F is now reserved for a score of zero. Everything under 25 used
to fail, so a whole band of ordinary grey parses all read as F; they now get
real letters. S+ has to be earned - the parse plus its bonuses must clear 99
- so it means something when it appears. Score colours are unchanged.

**Fixes**

- Pets no longer appear as group members. A death knight's ghoul was showing
  up as a sixth player in a five-man, named "Unknown" because pet names come
  back hidden. Their damage was always credited to the owner, so nothing is
  lost. Existing history is cleaned on load.
- Tank mitigation was never being tracked on retail. The spec check relied on
  a positional API return that no longer holds, so tanks silently didn't
  register as tanks and reported no uptime at all. Added `/tp mit`, which
  reports what your spec resolves to and which mitigation buffs are being
  watched - useful because the retail buff list is still unverified.
- The addon downloads about half a megabyte smaller.

Under the hood, scoring is now covered by a validation suite that scores
synthetic players at known percentiles and checks the engine reports them
back: damage, healing, tank mitigation anchors, gear independence, role
fairness, and randomised bounds checking on the adjustment layer. Every role
scores identically at matched percentiles, which is the promise the addon is
built on.

## 2.5.0

**Scores on content Warcraft Logs doesn't rank.** A dungeon run on Normal,
a Timewalking clear, an old expansion's dungeon - none of these have a
ranked population to parse against, so scores there used to collapse to
near-zero or float to a meaningless 99. Every score now carries an
evidence tier, shown as a chip in the fight selector:

- **I - Precise.** A 1:1 comparison against Warcraft Logs, ranked at the
  difficulty you played. Any Mythic+ key counts.
- **II - Approximate.** The dungeon's real curves scaled to your gear,
  because WCL only ranks it at Mythic+.
- **III - Rough.** Nothing covers this fight, so it's measured against the
  average of every dungeon we do have data for.

Tiers II and III scale your output into the ranked population's terms
before reading the curve, so 50 still means "an average player at your
item level". The reference gear is read per client from the crawl itself,
and the extrapolation is capped so a leveling group can't peg at 99. Both
knobs were tuned against 183 real captures until the derived tiers tracked
tier I's score distribution across every quantile.

MoP Classic ships no dungeon curves at all, so Celestial dungeons fall
back to pooling the raid curves rather than giving up.

**Fixes**

- Duplicate runs filed under a continent or city ("Eastern Kingdoms",
  "Silvermoon City") are recognised and dropped, including re-reads that
  came back hours later reporting a different duration. This also stops
  the reports panel auto-running once per phantom on login.
- A wipe followed by a difficulty change now registers as a wipe. Switching
  difficulty starts a new run, which hid the later kill from the check that
  infers "this boss was pulled again, so that attempt didn't kill it".
- Verdict matching prefers the difficulty you actually played, so a Normal
  kill can no longer consume a Heroic wipe's verdict.
- Realm names are dropped from the scorecard, giving names room to breathe.
- The first tooltip after a reload no longer renders on top of itself.
- The "wipe it" button is no longer suppressed by a raid leader who runs
  TrueParse but never enabled it, and any group member can call it in a
  dungeon.

**Changes**

- The header is now a grid: the fight selector ends where the class bars
  end, and the tier chip, reports icon and cog line up with the columns
  beneath them. The wordmark is a mark, and the selector has a real caret.
- The post-fight coach line in chat is gone. The breakdown card already
  shows the same advice, so the chat copy was just noise after every pull.

## 2.4.0

**Mechanic coaching.** Instead of a generic "you took avoidable damage,"
the coach now names the specific ability that hurt you and measures it
against the crawled Warcraft Logs field: "You took Exploding Iron Star 3
times (~627k each) - only 41% of players get hit by it. Sidestep it." On
MoP Classic this works for every player (the combat log sees every hit);
on retail, where there's no combat log, it covers your own self-reported
spike hits and otherwise keeps the general "stood in bad." Built on the
per-ability data already crawled for death causes, now with each ability's
typical damage so the coaching carries real impact.

## 2.3.0

**Self-reported metrics no longer go missing on retail.** A whole run could
show none of the retail self-report data (activity, mana, dispels timing,
spike coverage, flask/food, defensives) even for your own character. The
cause was a race: the meter bulk-unlocks at combat end while the
self-report finalizes on its own timer, so if the capture landed first, the
report was recorded too late and never attached - and nothing re-attached
it. Reports now re-attach to their captured fight whenever they arrive, so
late reports (including the local player's own) still land.

**Flask and food now cost points if missing.** Each is worth a point, so
turning up without both costs -1, and without either costs -2 (it was
praise-only before). Applies to any role on either client, and only when a
player's own TrueParse actually reported the count - nobody is penalized on
missing data.

**Card polish.** The subtle green/red section washes behind the bonus and
penalty chips now show reliably (they were drawn on the same layer as the
card's backdrop and lost the coin-flip). The group card gets the same
three-section treatment as player cards: its verdicts are chips in bonus,
penalty, and neutral grids now, with plain-ink labels and only the +/-
value colored, instead of full-width colored sentences. The group nuance
(which player, what percent) moves to each chip's hover. The group row on
the main window shows a +/- like the player rows now - the sum of the
group card's own scored chips, so the row and the card always agree
(before, it averaged the individual adjustments and could show a penalty
the group card never listed).

**Coaching only nags low parses.** The "tighten the rotation" line was
firing on excellent fights - a 93 damage parse or an 86 healing parse
would still get told their output was low, because the old threshold
scaled with the metric's weight and caught high parses. It now fires only
when the parse is genuinely below the median, so top players just get
their grade and awards.

**Tanks are scored on mitigation.** Survival is now a tank's primary
metric instead of a bonus that barely moved the score. The Mitigation
metric is your active-mitigation uptime scored against your spec's real
Warcraft Logs field, crawled from WCL's buff data: "you held mitigation up
57%, the median Guardian holds 24%." It's WCL-relative like a damage parse,
not an arbitrary target, and each spec is judged against its own
population (a Guardian's Savage Defense and a Blood DK's Blood Shield sit
at very different uptimes, so equally skilled tanks of different specs
parse alike). A tank who tanks well but pulls modest damage now grades
fairly. The coach follows suit, pointing tanks at their mitigation uptime
rather than telling them to pad damage. Weighting is mitigation 55%,
damage 31%, self-healing 14%. Avoidance, block, and soak share stay on the
card as context, not scored: they're passive, gear-driven, or already
counted elsewhere, and WCL doesn't rank them. Works on both retail
(self-reported uptime) and MoP Classic (from the combat log); MoP
baselines are crawled, retail uses a provisional default until its
mit-buff ids are verified.

**Augmentation Evokers score Prescience, not Ebon Might.** The Ebon Might
uptime metric was double-counting: Ebon Might already drives the
"Amplified" number (your effective damage is your allies' damage times
your uptime), so scoring the uptime again on top of that credited it
twice. Ebon Might uptime now feeds Amplified and nothing else. In its
place the support metric tracks Prescience, which no attribution model
captures. True Prescience uptime isn't readable from your own client (it
lives on allies, whose auras are hidden on Midnight), so it's scored as
cadence: how close you kept to casting Prescience on cooldown, measured
from your own casts. (Retail only; needs the caster running TrueParse,
same as the other self-reported facts.)

**Coaching that names your actual mistake.** The post-fight coach used to
say the same "cast X more often" line on nearly every fight, even when a
much bigger issue was staring at you. It now ranks every scored
adjustment and leads with the single biggest one you can recover, phrased
specifically: standing in avoidable damage ("34% of your intake, move out
of the bad"), too much downtime ("active only 55% of the fight"), losing
threat as the tank, overkilling a dying target, overhealing full bars,
missing cooldown windows, and more. It names the death cause for a fatal
mistake and only falls back to rotation/throughput advice when nothing
concrete went wrong. Coaching now stays quiet on fights shorter than 90
seconds (too little signal, and short pulls swing wildly on the group)
and on unranked content like Celestial and Timewalking, which are too
chaotic to coach meaningfully.

## 2.2.0

**Reports read like a debrief now.** The chat reports are rewritten from
stat lists into plain-language summaries. A small narrator ranks every
fact by how much it mattered this fight and composes the top few into
sentences, with an outcome-driven tone: kills lead with "faster than N%
of ranked kills on Warcraft Logs" and the group's DPS and parse
averages; wipes lead with progress ("best pull today", or how far past
the last attempt) and name what went wrong. Phrasing varies between
fights but is stable for the same fight. Reports never name a player,
and open with a "<TrueParse>" signature so readers know the source. The
group score line explains itself for people who don't know the addon
("the average player beating 45% of ranked parses for their spec").

**Death coaching that names the cause.** A new engine reads each death's
final hits against per-encounter damage data crawled from Warcraft
Logs and tells you *why* someone died: an avoidable mechanic ("you died
to Whirling Corruption, move out"), a tankbuster to pre-mitigate, a
one-shot (forgiven), or chip damage (a healing gap, not a positioning
one). The raid report distinguishes "4 of 6 deaths were avoidable
mechanics" from "deaths were chip damage." Real data corrects old
guesses — a heal-through mechanic no longer reads as a dodge-fail. It
works today and sharpens as the monthly crawl refreshes.

**Retail catches up to Classic.** Midnight hides the combat log, but
your own client can see your own actions — so each TrueParse user now
self-reports theirs, and the addon fills in what it couldn't observe.
Retail tanks get the full Tanking composite (avoidance, mitigation
uptime, swing data); healers get cooldown-timing on group damage
spikes when enough people are reporting; and healthstones, Bloodlust
usage, mana pacing, personal spike strips, and honest death counts
(retail's meter misses combat-rezzed deaths — reports now say "everyone
standing at the end" instead of a false "deathless") all light up.

**New scoring and coaching from unused data.** Dispel reaction time is
now scored and shown (fast clears earn, slow ones cost a little).
Activity is judged against each spec's own top-parse idle rate instead
of one fixed curve. The coach line's hover shows your whole rotation
versus the top parses, not just the single biggest gap. The Tanking
composite now earns a bonus when it beats the spec's population.

**Reports panel.** A chat icon by the meter's cog opens a panel of
shareable reports — Fight analysis, End of run, Death report,
Preparation check — each with a channel picker (your own chat by
default), a confirmation before broadcasting, and an always-local
auto-run option. The old scattered announce/debrief options are retired
into it.

**Card and quality-of-life.** The score's hover shows the arithmetic
behind it (each metric × weight, plus adjustments); letter grades now
cover every bar; the header time reads "@10:34pm (6m20s)" from live
pull stamps (fixing impossible times on delayed captures); a "Clear
fight history" button (career stats kept); and the Off-healing split is
retired so a tank's Healing is the plain WCL parse again.

**Fixes.** A crash that aborted Classic captures when a tank took
absorbed or avoided damage (the totals accumulation hit an
uninitialized key). A crash on `/tp run` inside a retail dungeon
(secret instance name). Retail players missing a role now derive it
from their spec (tanks and healers were grading as DPS). A wipe called
at the pull instant no longer corrupts a fight's stats. Plus a full
audit pass hardening the capture, scoring, and UI paths against nil and
secret values, and a performance fix so hovering a raid scorecard
doesn't re-score the whole fight per row.

## 2.1.2

Fixes a crash that could abort a fight capture on Classic. When a tank
took absorbed or avoided damage (a shielded hit, a dodge or parry), the
totals accumulation hit an uninitialized key and errored, so the fight
"didn't parse." Most visible in Celestial 5-mans with a Protection
Paladin. Captures are reliable again.

## 2.1.1

The chat icon now hides with the cog when the window collapses.

## 2.1.0

**Shareable reports.** A chat icon beside the meter's cog opens the
new Reports panel: Fight analysis (kills lead with "faster than N% of
ranked kills on Warcraft Logs", time vs last kill, pulls today with
best prior attempt, group score / raid DPS / parse averages; wipes
lead with boss % progress - "best pull today" when it is - deaths and
the wipe-call timing, avoidable damage, spike coverage), End of run,
Death report, and Preparation check. Each report has a channel picker
(Info posts to your own chat; Say/Party/Raid/Guild broadcast after a
confirmation) and an auto-run option that is always local-only.
Reports never name a player - group metrics tell the story. Manual
reports run on whatever fight the meter's selector has pinned.

**The score is the law now.** True = your WCL percentile + your
earned adjustments (net +/-15), capped at 99. The old earned floor is
gone; a 0 with penalties glows shame-red. Tank base realigned to the
WCL tank-damage parse (damage 86% / healing 14%): the Tanking
composite gained active-mitigation uptime as a fifth ingredient and
now EARNS - up to +4 when it beats the spec's population anchors,
bonus-only since the gauge already shows weak tanking. The
Off-healing split is retired: a tank's Healing is the plain
WCL-comparable parse again. New: healthstone discipline (+1 eaten,
-1 sat on it, judged only when a warlock is in the group; MoP
Classic, where casts are visible).

**Card layout, round two.** The header timing line reads
"@10:34pm (6m20s)" from live pull stamps - delayed outdoor-raid
captures no longer show impossible pull times, and run cards use the
earliest pull's start. Gauges (Damage/Healing/Tanking) stack
full-width with their scores in the last column; everything counted
lives in a two-column chip grid split into bonuses (subtle green
wash), penalties (red wash), and no-point items, each sorted by
weight, with hairline rules pixel-snapped to exactly 1px. Chips are
monochrome except the green/red points. Active and Mitigation left
their gauges (Mitigation folded into Tanking entirely). DPS cards
now show the personal spike strip - defensives answering intake
spikes - like tanks. Spike strips sit flush under the fight graphs,
legends match across player and raid cards, and the raid card's
flask+food moved from the footer into the grid.

**Also.** Flask/food chips wear a potion icon (and the buff icon
points at Blizzard's actually-misspelled texture file, so it renders
again). Raw honesty note: on fights where WCL excludes pad targets
from rankings (e.g. Paragons adds), the meter's all-target damage
reads higher than WCL's ranked amount - the math is identical, the
inputs differ.

## 2.0.0

The breakdown cards are redesigned from the ground up. Words became
signals: every metric is now a micro-row that shows its verdict at a
glance, and everything that needs a sentence lives in a short hover.

**The Signal Column.** WCL-percentile metrics (damage, healing parses,
kill speed) render the parse-bracket gauge itself - the five bracket
color zones with a white marker at your position, so "where do I sit
in the population" reads without a single word. Population-anchored
metrics (Active, Mitigation) wear the same gauge, marker at their
population tier. Counts and coverage (Covered 3/4, Kicks 8/10, dispel
counts, deaths) are markless - a colored count and signed points, no
fake bar. A light rule separates the base score (damage/healing) from
the adjustments below it. Letter grades supported everywhere. Verdict
labels stay under four words; hovers explain in one or two lines.

**A real tanking stat.** The grey "Soaking" share is now a composite
Tanking gauge built from four ingredients: soak share, dodge/parry/miss
rate, blocked + external shields, and self-recovery (own heals, own
absorbs, and Brewmaster purified stagger - estimated tick x 10).
Avoided swings are priced into the recovery denominator so avoidance
never double-credits. Each tank spec will rank against its own field
as calibration data accumulates; a tank's Healing row is now
"Off-healing" (group contribution only - self-sustain lives in
Tanking).

**Healer externals.** Guardian Spirit, Ironbark, Pain Suppression,
Life Cocoon, and Hand of Sacrifice answering a TANK's damage spike now
count in the same cooldown-timing pool as raid CDs - one metric, one
cap, kit-appropriate windows per spec (resto shamans, who have no
single-target external in MoP, are never judged on one). Tank spike
hovers name the external that rode the spike.

**Fight graphs.** The group card draws the pull's whole arc: group
output per second with the Bloodlust window in cyan, deaths dotted
above, and the wipe-call collapse in red - plus a team coverage strip
(hover any spike for what hit, how hard, and who answered) and a
progression staircase (boss % per pull tonight, best in green). Player
cards get their own line: healers healing/sec, tanks damage intake/sec,
DPS damage/sec - downtime and dead time visible at a glance.

**The coach, humanized.** Visible on the card under a stopwatch icon,
phrased as advice ("Cast Rejuvenation more often - you average 11/min,
top parses 21."), wrapping instead of widening the card.

**Activity measures honestly.** Hardcasts credit their full cast time
(a chain-casting Wrath player used to cap at ~84%); channels credit
their full span on retail. Casters can finally reach 100.

**Cards, chrome, and type.** Hero header (name + big bracket-colored
score), one-line subheader (boss - wipe % - duration - run avg), and a
footer (flask/food ready-checks + pull time; the group card counts
preparedness across everyone reporting). The whole card is set in the
condensed sans of the quality-addon dialect. Tooltips are text-only -
the gauge lives on the card now.

**Raw mode is pure everywhere.** Both cards filter to WCL-backed rows
only - no adjustments, no advisors, no graphs, no strips.

**Wipe-it button.** Raid lead/assist can mark the exact moment a wipe
was called with a big skull button (config option, off by default);
scoring stops judging anyone past the call. Auto-detection still works
when nobody clicks. Practice mode: Raider's Training Dummy sessions
score like a patchwork boss so you can drill with the addon.

**Testing.** "/tp mock" injects a fully-loaded synthetic raid night
(client-appropriate: CLEU surfaces on Classic, meter + self-reports on
retail) so every card surface can be explored without a raid;
"/tp mock clear" removes it.

**Accuracy and audit fixes.** Challenge Mode bosses no longer claim a
bogus kill-speed p99 from full-run curves; pinned run cards survive
scorecard re-renders; run cards no longer call pressed raid CDs
unused; zero-kick and zero-dispel charges show in Other instead of
vanishing; low-demand healers keep a "Little to heal" row; an Aug
without their own TrueParse reads "Amplified ?" instead of a fake
mid-pack bar; group raid-CD names moved to the hover; every hover
explanation is one short line, audited to match how scoring actually
works.

## 1.6.0

**The parse coach.** A new monthly crawl reads the Casts tables of top
parses and distills, per spec, the signature spells and how often the
best players press them. In game, your own rate is compared after each
fight and the single biggest gap surfaces in two quiet places: the
post-fight coach line, when throughput is your biggest opportunity
("biggest opportunity: healing — top parses cast Rejuvenation 21x/min
- you 6"), and one line in the damage/healing breakdown tooltip. No
wall of text - one targeted line, only when a real gap exists, sourced
from what the best players of your spec actually do. MoP Classic only
(cast visibility); spell-rank morphs are merged so every way your
client fires a button counts.

**Healer interrupts are bonus-only.** Kicking is not the healer's job:
a healer who lands kicks still earns the full bonus (it signals a
higher level of play), but a healer who doesn't is no longer docked -
the below-share penalty now only applies to tanks and DPS.

## 1.5.5

Resto druids on MoP are no longer marked interrupt-capable. Skull Bash
is trained class-wide but needs Bear or Cat form, so a Resto druid
would have to stop healing to kick - that's not an assignment, and
"did not interrupt" was charging them for a button their role can't
reach. The kick weight redistributes as it always does for
incapable specs; Balance (Solar Beam), Feral, and Guardian druids are
still on the hook.

## 1.5.4

Boss-percent accuracy on phase bosses. The best-pull sampler tracked
the running MINIMUM of boss health, which two Garrosh mechanics broke:
he refills to full between phases (so the minimum stuck at the
pre-transition floor) and goes untargetable in intermissions where his
health reads zero (so wipes latched "best 0%" - a contradiction, since
zero is a kill). The sampler now reports where the boss stood when the
pull actually ended, matching how Warcraft Logs states wipe
percentages: phase refills are followed while anyone is alive, a boss
resetting over a dead raid is frozen out, and zero-HP reads are never
sampled. Existing sub-0.5%% wipe records from the old sampler are
dropped at login so they stop poisoning the "best" line.

## 1.5.3

Availability awareness: "could have, but didn't" now requires the
could-have. No penalty is charged for a button that was on cooldown.

- **Cooldown timing** (tank spikes and healer raid-damage windows) now
  caps the judged window count at demonstrated capacity: uses actually
  made, plus one more they might have held. A healer team that spent
  both its raid CDs well across a 6-spike fight ran out of buttons,
  not discipline - that read -3 before and reads positive now. Zero
  uses gets no cap (nothing was ever on cooldown), and the bullet
  says when capacity capped it ("met 2 of 6 raid-damage spikes
  (3 coverable)"). End-of-run advice applies the same cap.
- **Bloodlust misses** are excused when the player's last offensive
  cooldown went out within 90s before the window - it was still on
  cooldown during it. Older casts keep the softened penalty.
- **Dying without a defensive** is no longer charged when the
  readiness report says zero defensives were off cooldown at death -
  they were spent earlier or the spec has none.

## 1.5.2

Three additions: Mythic+ joins the percentile-honesty fix, and two new
group-card lines.

- **Mythic+ true populations.** A new crawler reads per-spec keystone
  populations from character zoneRankings (validated exactly against
  report-level totalParses). M+ populations dwarf WCL's 2000-character
  serving cap - 250,000+ parses per popular spec, so the old curves
  sampled only the top ~1% and mid-pack keystone runners read absurdly
  low. Capped M+ curves now rescale like raids have since 1.4.6.
- **Kill speed trend.** On a boss kill, the group card compares against
  your group's previous kill of the same boss and difficulty: "Killed
  30s faster than last time (p50 -> p75)". Ties within 5s stay silent.
- **Wipe-call crispness.** Called wipes now show how fast the group
  wrapped ("wrapped 10s later - crisp"); chronically slow wraps (25s+
  average) get an end-of-run pointer - once it's called, dying fast IS
  the reset. The wipe debrief line carries the wrap time too.

## 1.5.1

**Raid-cooldown assignment line.** When heavy-damage moments go
uncovered while raid-wide cooldowns sat in someone's kit unused the
whole fight, the group card now names the buttons: "2 of 4
heavy-damage moments had no cooldown - Revival, Tranquility sat
unused". The healers' timing points already judged coverage; this
line is the to-do list that fixes it - assign one button per big
moment before the pull. Baseline abilities only (talent cooldowns
aren't observable, so they're never listed); single-target externals
excluded by design. MoP Classic only, like all cast tracking.

## 1.5.0

Two group-level features, both born from real raid-night arguments.

**Healer-count advisor.** The kill-time crawl now records how many
healers ranked kills actually bring, per boss and bracket. When your
raid kills a boss running more healers than the field's dominant comp
(and only then - it never nags you to ADD healers, and never on
wipes), the group card notes it: "Ran 3 healers - ranked kills mostly
run 2", with the field distribution in the tooltip. Advice, never
points - comp is a group choice, and progression comps run extra
healers on purpose. If the pattern holds across a run, the end-of-run
advice names the trade: kill speed for safety. Raids only; sizes must
be comparable (flex guard).

**Bloodlust discipline, the group view.** The card now rolls up what
each DPS did with the lust window: "Bloodlust: 4 of 6 DPS stacked
cooldowns, 2 potioned", carrying the average of the individual lust
points that already existed. Players dead before the window opened are
excused - here, in the score, and now in the end-of-run advice too
(the advice engine previously counted corpses as wasted lust).

## 1.4.6

Percentile honesty: capped WCL samples now rescale against the real
population. Validated head-to-head against a raid night's official WCL
rankPercents - parse error dropped from as much as 27 points to about
1 point on average, and the kill-speed line now matches WCL's speed
percentile within a point.

- WCL's rankings silently cap at 2000 characters per spec, so popular
  specs' curves (Elemental, hunters, and most retail specs) were
  top-slice samples that under-rated everyone mid-pack by 10-27
  points. A new totals crawl records each capped curve's true
  population, and the engine converts the sample percentile into an
  exact rank inside it.
- The kill-speed announcement was too generous (~2x): the population
  estimate counted characters instead of kills. It now uses the true
  ranked-kill count crawled from report rankings; capped brackets
  without a crawled total stay silent rather than guess.
- Covered everywhere curves ship except Mythic+ (WCL's report rankings
  answer differently for keystone runs - M+ raw parses keep the old
  behavior for now): current retail raid + LFR, Sporefall, and MoP
  Siege of Orgrimmar.

## 1.4.5

Per-spec overheal thresholds for MoP healers, crawled from Warcraft
Logs report tables (the first data for the v1.4.3 overheal support).

- A healer's overheal is now judged against their own spec's normal
  range instead of fixed 20/45/60 thresholds: Discipline reads lowest
  (absorbs don't overheal), Resto Druid highest (HoT overwrite is the
  spec), a ~12-point spread the fixed numbers couldn't see.
- Covered: Disc, Holy Paladin, Resto Shaman, Resto Druid, Mistweaver.
  Holy Priest missed the sample floor by one this crawl and keeps the
  fixed fallback until the next refresh.

## 1.4.4

Monthly Warcraft Logs data refresh (first full staggered-crawl cycle).

- Retail percentile curves refreshed per difficulty (LFR/Normal/Heroic/Mythic),
  plus kill times with crawled average raid sizes for the flex rescale.
- MoP SoO percentiles refreshed and expanded: Heroic 10-man curves for 11
  bosses and a new 25-man bracket file (Normal for all 14 bosses, Heroic for
  13 - Heroic Garrosh's population is still under the sample floor).
- MoP kill times refreshed across all four brackets, now with average raid
  sizes and encounter-ID keying (locale-proof lookups).

## 1.4.3

A second deep audit, themed on one idea: a bonus or penalty must judge
the WHOLE fight, not a moment out of context (the lesson from the
Bloodlust pre-grace fix). Seventeen scoring fixes, all in the
forgiveness direction.

**Wipe calls now forgive everything they should.**
- Dying after the call no longer costs "died with defensives ready" or
  "died without a defensive" - saving cooldowns for the next pull was
  the right play.
- Accepting a battle rez and dying again after the call no longer costs
  MORE than staying dead.
- Running dry on mana after the call, brezzing into the doomed tail,
  and the post-call AFK sinking your mitigation uptime: all excused.
- The wipe debrief no longer indicts "avoidable damage before death"
  for people deliberately standing in fire to reset faster.

**Being dead is no longer scoreable.**
- A corpse can't waste Bloodlust: dead before the window opened means
  no penalty (and cooldowns spent earlier in the fight soften a miss).
- Heavy-damage windows that open after a healer's death don't count
  against them; a dead player's low activity isn't charged twice; the
  kick/dispel share penalty scales by time actually alive.
- One-shot deaths (a single hit for your whole health bar) skip the
  defensive penalties - nothing you pressed would have mattered.

**Correct play stopped reading as failure.**
- Healer raid-cooldown coverage is now TEAM coverage: three healers
  rotating cooldowns perfectly used to each read "missed most windows"
  - now a window covered by anyone credits everyone.
- Raid CDs cast proactively (up to 8s before the hit, on a timer) count
  as covering it. More raid CDs recognized: Hand of Sacrifice, Rallying
  Cry, Ancestral Guidance, Avert Harm, Vampiric Embrace. Brewmaster
  Guard, Elusive Brew, and Sacred Shield now count as active mitigation.
- Interruptible casts completing right after your group landed a kick
  (interrupt on cooldown) no longer count as missed opportunities.
- Disc priests: absorbs now count in the overheal denominator - shield
  play no longer inflates apparent waste. Well-scoring healers on
  trivial fights get the same low-demand exemption weak ones did.
- Overkill is only judged on real fights (60s+) - someone must land
  every killing blow.
- A tank's slow-projectile pull no longer flags the DPS whose pre-cast
  landed first; a freshly-rezzed tank gets a grace window before
  aggro penalties resume.

**Kill speed vs Warcraft Logs is now honest.** WCL only serves the
fastest 1000 kills per boss; treating that leaderboard as the whole
population read every real kill as bottom-decile (SoO Normal kills all
scored p8-p20). The addon now estimates the true field from parse
counts and rescales: a 5:20 Immerseus kill reads p85, not p47. Kills
slower than the 1000th-fastest honestly say "outside WCL's top 1000"
instead of a fake number.

**Also:** percentile curves resolve by encounter ID first (non-English
clients get scores once refreshed data ships); per-spec overheal
thresholds supported (data crawl pending); every MoP healer-CD and
tank-mitigation spell ID verified against Wowhead MoP Classic.

## 1.4.2

The second half of the deep audit: ten fixes to record integrity and
scoring edge cases.

**Your history can't lie to you anymore.**
- Kill/wipe verdicts are now matched pull-by-pull: several pulls of the
  same boss in one session each keep their own outcome instead of the
  last verdict overwriting all of them.
- A pull the game explicitly called a kill can never be re-flagged as a
  wipe by the retroactive wipe passes.
- Re-running the same instance on a later day can no longer silently
  replace yesterday's capture of the same boss.

**Retail parity.** Weekly stats (and /tp guild) now accumulate on
retail, not just Classic.

**Scoring edges.**
- Falling, drowning, and split/shield damage now count as damage taken,
  appear in spike detection, and show honestly in death recaps.
- Clean pulls can no longer manufacture healer group-damage windows
  (max-health snapshots now cover the whole roster).
- The group advice line counts players-who-died with the right
  denominator instead of mixing units.

**Smaller repairs:** the pinned run breakdown survives scrolling; a
secret pet GUID mid-combat can't crash the roster; two latent scoring
branches (spec factor fallback, curve cache invalidation) were fixed
before they could misfire.

Also new in the repo (invisible in-game): a monthly automated Warcraft
Logs data refresh keeps percentile curves and kill times from going
stale after active development ends.

## 1.4.1

A deep audit (four parallel reviewers over the whole codebase) plus a
raid night of live verification. Highlights:

**Fixed crashes and corruption.**
- The run card crashed on Classic dungeon fights that had both a kick
  and a typed dispel (introduced in 1.4.0).
- Run rows summed per-fight ratios: two fights of 35% overheal read as
  70% and earned a penalty neither fight deserved; activity could
  auto-award +4. Aggregates now omit ratio metrics entirely.

**Durations now match Warcraft Logs exactly.** Verified against a live
log: WCL's fight bounds are the encounter events themselves, so ours
now anchor to the same events - identical by construction. (The 1.3.3
first-damage trim read ~15s short; the audit also found its internal
clocks disagreed, which hid late-fight tank/healer danger windows.)

**Fairness.**
- Enemy mobs interrupting YOU no longer count as group kick coverage
  or teach the kickable-spell list; enemy purges no longer count as
  dispels.
- Cooldowns used up to 10s BEFORE Bloodlust lands now count -
  pre-lusting to save a global is correct play, not "Wasted Bloodlust".
- Best-pull percentages are health-pool weighted: adds in Garrosh's
  boss frames no longer drag a 25% wipe down to "boss at 4%".
- Pre-pull auras can no longer close a tank's live mitigation window.

**Sync repairs.** A /reload no longer leaves you blind to groupmates
(the handshake answered the wrong side); fight reports no longer
erase the announcer election's memory (duplicate announcements from
the second fight on); weekly standings reject garbage values; the
announce checkboxes broadcast changes immediately.

**Also:** auto-collapse releases after trash fights (the window could
stick collapsed until manual clicks), the Group row can't go
click-dead after combat with click-through enabled, /tp procs only
tallies group sources, the advice engine no longer names last week's
raid mechanic as tonight's avoidable culprit, and the disabled Raw
radio finally explains itself on hover.

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
