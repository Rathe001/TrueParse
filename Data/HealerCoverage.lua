-- Per-spec healer COVERAGE baselines: { p25, p50, p75 } of a healer's healing
-- divided by the intake that was actually THEIRS TO HEAL - the group's damage
-- taken, less whatever the group healed itself - times the number of healers.
-- Read 0.99 as "this healer covered 99% of a fair share of the damage nobody
-- else picked up".
--
-- Self-healing comes out of the denominator because a healer only gets to
-- cover what nobody else covered. Against raw intake, coverage correlated
-- -0.76 with the non-healer healing share on 21 real M+ fights: 58% of its
-- variance was group composition, not the healer, and a single Blood DK tank
-- could move it. Against healable intake that falls to +0.13, i.e. 2%, while
-- 1.70x of spread survives (Josh spotted this before the crawl ran).
--
-- Times the healer count because raw coverage is divided among the healers,
-- so it falls as the roster adds them: the same defect as scoring a tank on
-- share of raid damage. Josh's MoP raids median 0.326 coverage on two healers
-- and 0.241 on three; normalised those are 0.652 and 0.723, against 0.680 for
-- a solo Mythic+ healer. A 2.82x spread becomes 1.11x, which is why ONE table
-- covers five-mans and raids instead of needing separate ones.
--
-- Why not HPS (Josh 2026-07-31). Healing rate in a 5-man is mostly a function
-- of how much damage the group TAKES, which is mostly avoidable - so scoring a
-- healer on HPS pays them for their group standing in things. Measured on 21
-- real Mythic+ fights: correlation(group intake/s, healer percentile) = +0.44,
-- and intake above 65k/s lifted the median healer percentile from 68 to 87.
-- In the same runs healers medianed 87.9 while damagers medianed 12.3.
--
-- Coverage is immune to that: double the intake and the healer heals roughly
-- double, so the ratio holds. It still discriminates - 0.36 to 0.84 across
-- those same fights, a 2.3x spread - because what varies is how much of the
-- group's damage the HEALER covered rather than the group self-sustaining.
--
-- A spec too rare to crawl falls back to default, itself the median of the
-- crawled specs. HEALER_COVERAGE_UNIT lets the engine refuse a file whose
-- units it does not recognise instead of scoring against the wrong scale.
local _, TP = ...

TP.HEALER_COVERAGE_UNIT = "healable-share-x-healers"

TP.HEALER_COVERAGE_ANCHORS = {
	default = { 0.819, 0.97, 1.086 }, -- DERIVED: median of the 7 crawled specs
	[65] = { 0.819, 0.958, 1.092 }, -- Holy Paladin (n=65)
	[105] = { 0.818, 0.979, 1.081 }, -- Resto Druid (n=90)
	[256] = { 1.03, 1.17, 1.338 }, -- Disc Priest (n=104)
	[257] = { 0.762, 0.912, 0.995 }, -- Holy Priest (n=61)
	[264] = { 0.796, 0.931, 1.086 }, -- Resto Shaman (n=126)
	[270] = { 0.882, 1.063, 1.216 }, -- Mistweaver (n=150)
	[1468] = { 0.837, 0.97, 1.07 }, -- Preservation (n=40)
}