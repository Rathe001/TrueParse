-- Shareable chat reports (Josh 2026-07-25): each report reads like a
-- raid lead's debrief, not a stat dump. A small narrator ranks every
-- available fact by how much it mattered THIS fight, keeps the top
-- few, and composes them into plain sentences.
-- HOUSE RULES: reports NEVER name a player (group metrics only); no
-- em/en dashes in output (Josh: they read as AI); plain text; every
-- chat line under the 255-char ceiling; phrasing varies between
-- fights but is DETERMINISTIC per fight (same fight, same words).
-- PURE LUA: builders read only the ctx they're handed; loaded
-- headlessly by tests/run.lua. Delivery/UI lives in UI/ReportsWindow.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Reports = {}
TP.Scoring.Reports = Reports

local function mmss(sec)
	sec = math.floor((sec or 0) + 0.5)
	local h = math.floor(sec / 3600)
	if h > 0 then
		return ("%d:%02d:%02d"):format(h, math.floor(sec % 3600 / 60), sec % 60)
	end
	return ("%d:%02d"):format(math.floor(sec / 60), sec % 60)
end

local function plural(n, word)
	return ("%d %s%s"):format(n, word, n == 1 and "" or "s")
end

-- ===== deterministic phrasing: same fight always reads the same =====

local function hashOf(s)
	local h = 5381
	for i = 1, #s do
		h = (h * 33 + s:byte(i)) % 2147483647
	end
	return h
end

local function seedFor(fight, zone)
	return hashOf(((fight and fight.name) or zone or "run") .. "#"
		.. math.floor((fight and fight.duration) or 0))
end

local function pick(seed, salt, options)
	return options[(seed + salt) % #options + 1]
end

local function capitalize(s)
	return s:sub(1, 1):upper() .. s:sub(2)
end

-- sentences -> chat lines, greedily packed under the ceiling (with
-- headroom for the "<TrueParse> " prefix delivery adds to line one)
local function packLines(sentences)
	local lines = {}
	for _, s in ipairs(sentences) do
		if s and s ~= "" then
			local cur = lines[#lines]
			if cur and #cur + #s + 1 <= 235 then
				lines[#lines] = cur .. " " .. s
			else
				lines[#lines + 1] = s
			end
		end
	end
	return lines
end

-- ===== fact extraction (data only; words come later) =====

local function groupScore(results)
	local sum, n = 0, 0
	for _, r in ipairs(results or {}) do
		if r.score then
			sum = sum + r.score
			n = n + 1
		end
	end
	return n > 0 and math.floor(sum / n + 0.5) or nil
end

-- every death in a fight as { t, avoidable, readyDefensives }, oldest
-- first. The deaths COUNTER is the authority: retail records stamped
-- deathTime=0 on players who never died (a deathless kill reported
-- "5 deaths at 0:00", 2026-07-25), so a zero counter contributes
-- nothing regardless of stamps.
local function deathList(fight)
	local out = {}
	for _, p in pairs(fight.players or {}) do
		if ((p.metrics or {}).deaths or 0) > 0 then
			local times = p.deathTimes or (p.deathTime and { p.deathTime }) or {}
			for _, t in ipairs(times) do
				local avoidable
				-- the recap describes the LAST death; attach it there only
				if t == times[#times] and p.deathRecap and #p.deathRecap > 0 then
					avoidable = p.deathRecap[#p.deathRecap].avoidable
				end
				out[#out + 1] = { t = t, avoidable = avoidable,
					readyDefensives = t == times[#times] and (p.deathReadyDefensives or 0) or 0 }
			end
		end
	end
	table.sort(out, function(a, b)
		return a.t < b.t
	end)
	return out
end

-- Retail's meter can't see brez'd deaths of players without the addon,
-- so a zero count on a KILL proves only "everyone was standing at the
-- end" (Josh 2026-07-25). CLEU (Classic) counts everyone; wipes are
-- reliable on both clients because the dead stay dead.
local function deathsUncertain(fight)
	if fight.wipe then
		return false
	end
	return not (TP.Compat and TP.Compat.HAS_CLEU)
end

local function avoidableStats(fight)
	local hit, avoid, taken = 0, 0, 0
	for _, p in pairs(fight.players or {}) do
		local m = p.metrics or {}
		avoid = avoid + (m.avoidableTaken or 0)
		taken = taken + (m.damageTaken or 0)
		if (m.avoidableTaken or 0) > 0 then
			hit = hit + 1
		end
	end
	if hit == 0 or taken <= 0 then
		return nil
	end
	return hit, math.floor(avoid / taken * 100 + 0.5)
end

local function kickStats(fight)
	local t = fight.totals or {}
	if (t.kickOpportunities or 0) > 0 then
		return t.kicksLanded or t.interrupts or 0, t.kickOpportunities
	end
end

local function spikeStats(fight)
	-- the windows are stamped identically on every player record, so
	-- any carrier speaks for the fight
	for _, p in pairs(fight.players or {}) do
		local m = p.metrics or {}
		if (m.groupSpikeWindows or 0) > 0 then
			return m.groupSpikeWindows, m.groupSpikeWindows - (m.groupSpikeCovered or 0)
		end
	end
end

local function personalsStats(fight)
	local noDef, defReporting, hsEaten, hsReporting = 0, 0, 0, 0
	for _, p in pairs(fight.players or {}) do
		local m = p.metrics or {}
		if m.defensives ~= nil then
			defReporting = defReporting + 1
			if m.defensives == 0 then
				noDef = noDef + 1
			end
		end
		if m.healthstones ~= nil then
			hsReporting = hsReporting + 1
			if m.healthstones > 0 then
				hsEaten = hsEaten + 1
			end
		end
	end
	return noDef, defReporting, hsEaten, hsReporting
end

-- real WCL percentiles across the group: average + best (primary
-- metric per role; only curve-backed percentiles count)
local function parseStats(results)
	local sum, n, best = 0, 0, nil
	for _, r in ipairs(results or {}) do
		local key = r.role == "HEALER" and "healing" or "damage"
		local b = r.breakdown and r.breakdown[key]
		local p = b and b.applicable and b.pctile
		if p then
			sum = sum + p
			n = n + 1
			if not best or p > best then
				best = p
			end
		end
	end
	if n == 0 then
		return nil
	end
	return math.floor(sum / n + 0.5), math.floor(best + 0.5)
end

-- "top N% boss by kill time" context; only fires on the tier's rough end
local function toughnessTop(fight)
	local E = TP.Scoring and TP.Scoring.Engine
	if not (E and E.EncounterToughness) then
		return nil
	end
	local ok, rank = pcall(E.EncounterToughness, fight)
	if ok and rank and rank >= 0.7 then
		return math.floor((1 - rank) * 100 + 1)
	end
end

-- WCL kill-speed percentile, real rankings only (bounded ceilings
-- never brag)
local function killSpeedPct(fight)
	local E = TP.Scoring and TP.Scoring.Engine
	if not (E and E.KillSpeedPercentile) then
		return nil
	end
	local ok, pct, _, _, bounded = pcall(E.KillSpeedPercentile, fight)
	if ok and pct and not bounded then
		return math.floor(pct + 0.5)
	end
end

-- the previous pull of the same boss in the run (older = later in the
-- newest-first list)
local function prevPullPct(ctx)
	local f = ctx.fight
	local seen
	for _, rf in ipairs(ctx.runFights or {}) do
		if seen and rf.name == f.name and rf.wipe and rf.bossPct then
			return rf.bossPct
		end
		if rf == f then
			seen = true
		end
	end
end

-- is this wipe the run's deepest push on its boss? (needs company)
local function isBestPullToday(ctx)
	local f = ctx.fight
	if not f.bossPct then
		return false
	end
	local others = 0
	for _, rf in ipairs(ctx.runFights or {}) do
		if rf ~= f and rf.name == f.name and rf.wipe then
			others = others + 1
			if rf.bossPct and rf.bossPct <= f.bossPct then
				return false
			end
		end
	end
	return others > 0
end

local function pullCount(ctx)
	local f = ctx.fight
	local pulls, bestPct = 0, nil
	for _, rf in ipairs(ctx.runFights or {}) do
		if rf.name == f.name then
			pulls = pulls + 1
			if rf.wipe and rf.bossPct and (not bestPct or rf.bossPct < bestPct) then
				bestPct = rf.bossPct
			end
		end
	end
	return pulls, bestPct
end

-- ===== shared sentences =====

-- "The group put up 62.6k DPS for a parse of 61, parsing 45 on
-- average with a 90 on top." The word matters (Josh 2026-07-25):
-- "parse" only when WCL data actually backed the fight; unranked
-- content says "score".
local function groupSentence(ctx, seed, compact)
	local f = ctx.fight
	local gs = ctx.groupScore or groupScore(ctx.results)
	local dps
	local t = f and f.totals or {}
	if (t.damage or 0) > 0 and (f.duration or 0) > 0 and TP.FormatNumber then
		dps = TP.FormatNumber(t.damage / f.duration)
	end
	local avg, best = parseStats(ctx.results)
	-- outsider-legible context (Josh 2026-07-25: "group score of 59"
	-- means nothing to non-users): WCL-backed fights say what the parse
	-- average actually means; unranked content at least names the scale
	local scoreText = avg and ("a parse of %d"):format(gs or 0)
		or ("a score of %d out of 100"):format(gs or 0)
	local parseClause = avg
		and (", the average player beating %d%% of ranked parses for their spec (%d on top)"):format(
			avg, best) or ""
	if gs and dps and compact then
		return pick(seed, 11, {
			("Group %s on %s DPS."):format(scoreText:gsub("^a ", ""), dps),
			("The group ran %s DPS for %s."):format(dps, scoreText),
		})
	elseif gs and dps then
		return pick(seed, 11, {
			("The group put up %s DPS for %s%s."):format(dps, scoreText, parseClause),
			("That's %s on %s raid DPS%s."):format(scoreText, dps, parseClause),
		})
	elseif gs then
		return capitalize(("%s for the group%s."):format(scoreText, parseClause))
	elseif avg then
		return ("The average player here beat %d%% of ranked parses for their spec, %d at best."):format(avg, best)
	end
end

-- The concern pool: every "went wrong" fact scored by how much it
-- mattered this fight; the top picks get the ink. This is what keeps
-- a long metric list from becoming a stat dump.
local function concerns(fight, deaths, seed)
	local pool = {}
	-- personal-prep nags only matter when the fight actually threatened
	-- anyone (Josh 2026-07-25: "1 player never pressed a defensive" was
	-- closing every trivial farm kill)
	local threatening = fight.wipe or #(deaths or {}) > 0
		or (fight.duration or 0) >= 120
	local windows, uncovered = spikeStats(fight)
	if windows and uncovered and uncovered > 0 then
		pool[#pool + 1] = { sal = 30 + uncovered / windows * 50,
			text = ("%d of %d damage spikes had no cooldown answer"):format(uncovered, windows) }
	end
	local hit, share = avoidableStats(fight)
	if hit then
		pool[#pool + 1] = { sal = 20 + share * 2 + hit * 4,
			text = ("%s took avoidable damage, %d%% of everything taken"):format(
				plural(hit, "player"), share) }
	end
	local landed, opps = kickStats(fight)
	if landed and landed < opps then
		local miss = opps - landed
		pool[#pool + 1] = { sal = 25 + miss / opps * 50,
			text = pick(seed, 3, {
				("%d of %d kicks got away"):format(miss, opps),
				("only %d of %d kicks landed"):format(landed, opps),
			}) }
	end
	local ready = 0
	for _, d in ipairs(deaths or {}) do
		if (d.readyDefensives or 0) >= 2 then
			ready = ready + 1
		end
	end
	if ready > 0 then
		pool[#pool + 1] = { sal = 45,
			text = ("%s died with defensives still ready"):format(plural(ready, "player")) }
	end
	if threatening then
		local noDef, defReporting, hsEaten, hsReporting = personalsStats(fight)
		if defReporting > 0 and noDef > 0 then
			pool[#pool + 1] = { sal = 18,
				text = ("%s never pressed a defensive"):format(plural(noDef, "player")) }
		end
		if hsReporting > 0 and hsEaten < hsReporting then
			pool[#pool + 1] = { sal = 15,
				text = ("only %d of %d ate a healthstone"):format(hsEaten, hsReporting) }
		end
	end
	table.sort(pool, function(a, b)
		return a.sal > b.sal
	end)
	return pool
end

local function concernSentence(pool, seed, gentle)
	if #pool == 0 then
		return nil
	end
	if #pool == 1 or gentle then
		local intro = gentle
			and pick(seed, 5, { "Only loose thread: ", "One thing to tighten: ", "The lone blemish: " })
			or pick(seed, 5, { "But ", "Still, ", "Even so, " })
		return capitalize(intro .. pool[1].text .. ".")
	end
	local pivot = pick(seed, 7, { "But ", "Still, ", "Even so, " })
	return capitalize(pivot .. pool[1].text .. ", and " .. pool[2].text .. ".")
end

-- ===== the stories =====

local function buildKill(ctx)
	local f = ctx.fight
	if not f then
		return nil
	end
	local seed = seedFor(f, ctx.zone)
	local deaths = deathList(f)
	local pulls = pullCount(ctx)
	local speed = killSpeedPct(f)
	local s = {}

	-- farm-speed one-shots get a short, varied line instead of the full
	-- debrief shape (Josh 2026-07-25: five TW bosses read identically)
	local trivial = (f.duration or 0) < 120 and #deaths == 0
		and pulls <= 1 and not speed and not f.wipe
	if trivial then
		s[#s + 1] = pick(seed, 1, {
			("%s folded in %s."):format(f.name or "The boss", mmss(f.duration)),
			("Quick work: %s down in %s."):format(f.name or "the boss", mmss(f.duration)),
			("%s barely slowed the group down, dead in %s."):format(f.name or "The boss", mmss(f.duration)),
			("%s down in %s without much drama."):format(f.name or "The boss", mmss(f.duration)),
		})
		s[#s + 1] = groupSentence(ctx, seed, true)
		-- only a genuinely loud concern interrupts a farm kill
		local pool = concerns(f, deaths, seed)
		if pool[1] and pool[1].sal >= 40 then
			s[#s + 1] = concernSentence({ pool[1] }, seed, true)
		end
		return packLines(s)
	end

	-- opener: outcome plus its short brags
	local extras = {}
	if pulls == 1 then
		extras[#extras + 1] = "one pull"
	end
	if #deaths == 0 then
		extras[#extras + 1] = deathsUncertain(f)
			and "everyone standing at the end"
			or pick(seed, 1, { "nobody died", "no deaths", "deathless" })
	end
	s[#s + 1] = ("%s %s %s%s."):format(f.name or "The boss",
		pick(seed, 2, { "down in", "dead in", "dropped in" }), mmss(f.duration),
		#extras > 0 and (", " .. table.concat(extras, ", ")) or "")

	if speed then
		s[#s + 1] = ("That's faster than %d%% of ranked kills on Warcraft Logs."):format(speed)
	end

	if pulls > 1 then
		local _, bestPct = pullCount(ctx)
		s[#s + 1] = ("It took %s%s."):format(plural(pulls, "pull"),
			bestPct and (", the best prior attempt reaching %d%%"):format(bestPct) or "")
	end

	s[#s + 1] = groupSentence(ctx, seed)

	if #deaths > 0 then
		local avoidable = 0
		for _, d in ipairs(deaths) do
			if d.avoidable then
				avoidable = avoidable + 1
			end
		end
		-- on retail a kill's count is a floor: brez'd deaths of players
		-- without the addon are invisible
		s[#s + 1] = ("%s%d died on the way%s."):format(
			deathsUncertain(f) and "At least " or "", #deaths,
			avoidable > 0 and (", %d to avoidable hits"):format(avoidable) or "")
	end

	local pool = concerns(f, deaths, seed)
	-- a slower kill is a concern too, not a headline
	if f.prevKillDuration and f.duration then
		local diff = math.floor(f.prevKillDuration - f.duration + 0.5)
		if diff < 0 then
			pool[#pool + 1] = { sal = 38,
				text = ("it ran %d seconds slower than the last kill"):format(-diff) }
			table.sort(pool, function(a, b)
				return a.sal > b.sal
			end)
		elseif diff > 0 then
			s[#s + 1] = ("%d seconds faster than the last kill."):format(diff)
		end
	end
	-- clean kills only surface concerns that earned the ink
	if #deaths == 0 then
		local kept = {}
		for _, c in ipairs(pool) do
			if c.sal >= 25 then
				kept[#kept + 1] = c
			end
		end
		pool = kept
	end
	s[#s + 1] = concernSentence(pool, seed, #deaths == 0)

	local top = toughnessTop(f)
	if top then
		s[#s + 1] = ("And this is a top %d%% boss in the tier by kill time."):format(top)
	end
	return packLines(s)
end

local function buildWipe(ctx)
	local f = ctx.fight
	if not f then
		return nil
	end
	local seed = seedFor(f, ctx.zone)
	local deaths = deathList(f)
	local best = isBestPullToday(ctx)
	local prev = prevPullPct(ctx)
	local s = {}

	-- opener: how deep, and what that means
	local at = f.calledWipeAt and mmss(f.calledWipeAt) or mmss(f.duration)
	if best and f.bossPct then
		s[#s + 1] = ("%s: %s to %d%% before it came apart at %s."):format(
			pick(seed, 1, { "Best pull of the day", "Deepest push yet" }),
			f.name or "the boss", f.bossPct, at)
	elseif f.bossPct and prev and prev > f.bossPct then
		s[#s + 1] = ("%s to %d%%, %d points past the last pull, before it came apart at %s."):format(
			f.name or "The boss", f.bossPct, prev - f.bossPct, at)
	elseif f.bossPct and prev and prev < f.bossPct then
		s[#s + 1] = ("%s at %d%% this time; the last pull reached %d%%."):format(
			f.name or "The boss", f.bossPct, prev)
	elseif f.bossPct then
		s[#s + 1] = ("Wipe on %s at %d%% (%s)."):format(f.name or "the boss",
			f.bossPct, mmss(f.duration))
	else
		s[#s + 1] = ("Wipe on %s (%s)."):format(f.name or "the boss", mmss(f.duration))
	end

	if #deaths > 0 then
		local first = deaths[1]
		local d
		if f.calledWipeAt then
			local pre = 0
			for _, dd in ipairs(deaths) do
				if dd.t < f.calledWipeAt then
					pre = pre + 1
				end
			end
			d = ("%d died getting there, %d before the call, the first at %s%s."):format(
				#deaths, pre, mmss(first.t),
				first.avoidable and " to avoidable damage" or "")
		else
			d = ("%d died, the first at %s%s."):format(#deaths, mmss(first.t),
				first.avoidable and " to avoidable damage" or "")
		end
		s[#s + 1] = d
	end
	if f.calledWipeAt and f.duration then
		local tail = math.floor(f.duration - f.calledWipeAt + 0.5)
		if tail <= 20 then
			s[#s + 1] = ("The raid reset just %d seconds after the call."):format(tail)
		else
			s[#s + 1] = ("The pull ended %d seconds after the call."):format(tail)
		end
	end

	s[#s + 1] = groupSentence(ctx, seed)
	s[#s + 1] = concernSentence(concerns(f, deaths, seed), seed, false)

	if best and f.bossPct then
		s[#s + 1] = ("The %d%% is real progress."):format(f.bossPct)
	else
		local top = toughnessTop(f)
		if top then
			s[#s + 1] = ("For what it's worth, this is a top %d%% boss in the tier by kill time."):format(top)
		end
	end
	return packLines(s)
end

-- one report, two stories: the fight's outcome decides which (Josh
-- 2026-07-25: you'd never run a kill report on a wipe)
local function buildFight(ctx)
	if ctx.fight and ctx.fight.wipe then
		return buildWipe(ctx)
	end
	return buildKill(ctx)
end

local function buildRun(ctx)
	local fights = ctx.runFights
	if not fights or #fights == 0 then
		return nil
	end
	local kills, wipes, fought, deaths = 0, 0, 0, 0
	local kicksL, kicksO, avoid, taken = 0, 0, 0, 0
	local fastest
	for _, f in ipairs(fights) do
		fought = fought + (f.duration or 0)
		local t = f.totals or {}
		kicksL = kicksL + (t.kicksLanded or t.interrupts or 0)
		kicksO = kicksO + (t.kickOpportunities or 0)
		if f.isBoss then
			if f.wipe then
				wipes = wipes + 1
			else
				kills = kills + 1
				if not fastest or (f.duration or 0) < fastest.duration then
					fastest = f
				end
			end
		end
		for _, p in pairs(f.players or {}) do
			local m = p.metrics or {}
			deaths = deaths + (m.deaths or 0)
			avoid = avoid + (m.avoidableTaken or 0)
			taken = taken + (m.damageTaken or 0)
		end
	end
	local zone = ctx.zone or fights[1].zone or "The run"
	local gs = ctx.groupScore or groupScore(ctx.results)
	-- "parse" only when WCL data backed the run (Josh 2026-07-25);
	-- unranked content names the scale so outsiders can read it
	local scoreClause = ""
	if gs then
		scoreClause = parseStats(ctx.results)
			and (" for a run parse of %d"):format(gs)
			or (" for a run score of %d out of 100"):format(gs)
	end
	local s = {}
	if wipes == 0 and kills > 0 then
		s[#s + 1] = ("%s cleared: %s, no wipes, %s of fighting%s."):format(
			zone, plural(kills, "kill"), mmss(fought), scoreClause)
	else
		s[#s + 1] = ("%s: %s, %s, %s of fighting%s."):format(
			zone, plural(kills, "kill"), plural(wipes, "wipe"), mmss(fought), scoreClause)
	end
	-- a run's kills carry uncertain death counts on retail (brez'd
	-- deaths of non-addon players are invisible); all-wipe runs and
	-- Classic stay certain
	local runUncertain = kills > 0 and not (TP.Compat and TP.Compat.HAS_CLEU)
	if deaths == 0 then
		s[#s + 1] = runUncertain
			and "No deaths recorded, everyone standing at the end of each fight."
			or "Nobody died all run."
	else
		local avClause = ""
		if taken > 0 and avoid > 0 then
			avClause = (", and %d%% of the damage taken was avoidable"):format(
				math.floor(avoid / taken * 100 + 0.5))
		end
		s[#s + 1] = ("%s%s across the run%s."):format(
			runUncertain and "At least " or "",
			runUncertain and plural(deaths, "death") or capitalize(plural(deaths, "death")),
			avClause)
	end
	if kicksO > 0 then
		s[#s + 1] = ("Kicks landed %d of %d."):format(kicksL, kicksO)
	end
	if fastest and kills > 1 then
		s[#s + 1] = ("Fastest kill: %s at %s."):format(fastest.name or "?", mmss(fastest.duration))
	end
	return packLines(s)
end

local function buildDeaths(ctx)
	local f = ctx.fight
	if not f then
		return nil
	end
	local deaths = deathList(f)
	local uncertain = deathsUncertain(f)
	if #deaths == 0 then
		return { uncertain
			and ("Everyone was standing when %s died."):format(f.name or "the boss")
			or ("Nobody died on %s."):format(f.name or "?") }
	end
	local s = { ("%s%s on %s, the first at %s and the last at %s."):format(
		uncertain and "At least " or "",
		uncertain and plural(#deaths, "death") or capitalize(plural(#deaths, "death")),
		f.name or "?", mmss(deaths[1].t), mmss(deaths[#deaths].t)) }
	local avoidable, ready = 0, 0
	for _, d in ipairs(deaths) do
		if d.avoidable then
			avoidable = avoidable + 1
		end
		if (d.readyDefensives or 0) >= 2 then
			ready = ready + 1
		end
	end
	if avoidable > 0 then
		s[#s + 1] = avoidable == 1
			and "One of the killing blows was an avoidable hit."
			or ("%d of the killing blows were avoidable hits."):format(avoidable)
	end
	if ready > 0 then
		s[#s + 1] = ("%s died with 2 or more defensives unused."):format(plural(ready, "player"))
	end
	local hit, share = avoidableStats(f)
	if hit then
		s[#s + 1] = ("%s took avoidable damage, %d%% of everything taken."):format(
			plural(hit, "player"), share)
	end
	return packLines(s)
end

local function buildPrep(ctx)
	local f = ctx.fight
	if not f then
		return nil
	end
	local reporting, ready = 0, 0
	for _, p in pairs(f.players or {}) do
		local m = p.metrics or {}
		if m.consumables ~= nil then
			reporting = reporting + 1
			if m.consumables >= 2 then
				ready = ready + 1
			end
		end
	end
	local _, _, hsEaten, hsReporting = personalsStats(f)
	if reporting == 0 and hsReporting == 0 then
		return { ("No preparation data for %s."):format(f.name or "?") }
	end
	local s = {}
	if reporting > 0 then
		if ready == reporting then
			s[#s + 1] = ("Everyone came prepared on %s: %d of %d with flask and food."):format(
				f.name or "?", ready, reporting)
		else
			s[#s + 1] = ("Prep on %s: %d of %d brought flask and food, %s short."):format(
				f.name or "?", ready, reporting, plural(reporting - ready, "player"))
		end
	end
	if hsReporting > 0 then
		s[#s + 1] = ("Healthstones eaten: %d of %d."):format(hsEaten, hsReporting)
	end
	return packLines(s)
end

-- The registry the panel renders, in display order. trigger names the
-- moment the report can auto-run (always local-only); manual-only
-- reports leave it nil. No report ever names a player.
Reports.LIST = {
	{
		key = "fight", name = "Fight analysis", trigger = "fight",
		desc = "The selected fight's story, told like a debrief. Kills: speed rank, pulls, group score/DPS/parses, what to tighten. Wipes: progress, deaths and the call, what went wrong. No names.",
		example = "Edwin VanCleef down in 1:03, one pull, nobody died. That's faster than 78% of ranked kills on Warcraft Logs. The group put up 62.6k DPS for a score of 61. Only loose thread: 3 of 5 kicks got away.",
		build = buildFight,
	},
	{
		key = "run", name = "End of run", trigger = "runEnd",
		desc = "The whole visit in a few sentences: kills, wipes, time fought, run score, deaths with the avoidable share, and the fastest kill.",
		example = "Deadmines cleared: 6 kills, no wipes, 4:32 of fighting for a run score of 73. Nobody died all run. Fastest kill: Captain Greenskin at 0:19.",
		build = buildRun,
	},
	{
		key = "deaths", name = "Death report",
		desc = "Deaths on the selected fight: count and timing, avoidable killing blows, and deaths with defensives sitting unused. No names.",
		example = "6 deaths on Garrosh Hellscream, the first at 2:41 and the last at 5:50. 3 of the killing blows were avoidable hits.",
		build = buildDeaths,
	},
	{
		key = "prep", name = "Preparation check",
		desc = "Who brought flask and food, and healthstone use where a warlock provided them. Counts only, no names.",
		example = "Prep on Garrosh Hellscream: 8 of 10 brought flask and food, 2 players short. Healthstones eaten: 6 of 9.",
		build = buildPrep,
	},
}

Reports.byKey = {}
for _, def in ipairs(Reports.LIST) do
	Reports.byKey[def.key] = def
end

-- Run one report against a ctx. Returns the lines or nil when the ctx
-- has nothing to report on (callers say so politely).
function Reports.Run(key, ctx)
	local def = Reports.byKey[key]
	if not def then
		return nil
	end
	local lines = def.build(ctx or {})
	if lines and #lines == 0 then
		return nil
	end
	return lines
end
