-- Shareable chat reports (Josh 2026-07-25): each report turns a fight
-- (or a run) into a few plain-text lines fit for a chat channel — no
-- color codes, every line under the 255-char chat ceiling, no more
-- than ~6 lines so nobody gets spammed.
-- HOUSE RULE (Josh 2026-07-25): reports NEVER name a player. Group
-- metrics only — counts, shares, and timings. Shame stays on the
-- private scorecard; chat gets the team story.
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
-- first — times and causes, never names
local function deathList(fight)
	local out = {}
	for _, p in pairs(fight.players or {}) do
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
	table.sort(out, function(a, b)
		return a.t < b.t
	end)
	return out
end

-- "3 players took avoidable damage (5% of all damage taken)"
local function avoidableLine(fight)
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
	return ("%s took avoidable damage (%d%% of all damage taken)."):format(
		plural(hit, "player"), math.floor(avoid / taken * 100 + 0.5))
end

-- "Kicks 13/16; dispels 14." — whatever the totals actually carry
local function kicksDispelsLine(fight)
	local t = fight.totals or {}
	local parts = {}
	if (t.kickOpportunities or 0) > 0 then
		local landed = t.kicksLanded or t.interrupts or 0
		local miss = t.kickOpportunities - landed
		parts[#parts + 1] = ("Kicks %d/%d%s"):format(landed, t.kickOpportunities,
			miss > 0 and (" (%d missed)"):format(miss) or "")
	elseif (t.interrupts or 0) > 0 then
		parts[#parts + 1] = ("Kicks %d"):format(t.interrupts)
	end
	if (t.dispels or 0) > 0 then
		parts[#parts + 1] = ("dispels %d"):format(t.dispels)
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, "; ") .. "."
end

-- "2 players never used a defensive; healthstones eaten 5/9." — counts
-- only, and only where the data reported
local function personalsLine(fight)
	local noDef, defReporting = 0, 0
	local hsEaten, hsReporting = 0, 0
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
	local parts = {}
	if defReporting > 0 and noDef > 0 then
		parts[#parts + 1] = ("%s never used a defensive"):format(plural(noDef, "player"))
	end
	if hsReporting > 0 then
		parts[#parts + 1] = ("healthstones eaten %d/%d"):format(hsEaten, hsReporting)
	end
	if #parts == 0 then
		return nil
	end
	local line = table.concat(parts, "; ") .. "."
	return line:sub(1, 1):upper() .. line:sub(2)
end

-- "Tough boss: top 24% of the tier by kill time." — context, so a
-- rough report on a rough boss reads fairly
local function toughnessLine(fight)
	local E = TP.Scoring and TP.Scoring.Engine
	if not (E and E.EncounterToughness) then
		return nil
	end
	local ok, rank, bosses = pcall(E.EncounterToughness, fight)
	if ok and rank and rank >= 0.7 then
		return ("Tough boss: top %d%% of the tier's %d bosses by kill time."):format(
			(1 - rank) * 100 + 1, bosses or 0)
	end
end

-- the previous pull of the same boss in the run (older = later in the
-- newest-first list), for boss-% progress comparisons
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

local function buildWipe(ctx)
	local f = ctx.fight
	if not f then
		return nil
	end
	local lines = {}
	local prev = prevPullPct(ctx)
	local vs = ""
	if f.bossPct and prev then
		if prev > f.bossPct then
			vs = (" - %d%% further than last pull"):format(prev - f.bossPct)
		elseif prev < f.bossPct then
			vs = (" - last pull reached %d%%"):format(prev)
		else
			vs = " - same as last pull"
		end
	end
	lines[#lines + 1] = ("Wipe: %s%s (%s)%s."):format(f.name or "?",
		f.bossPct and (" at %d%%"):format(f.bossPct) or "", mmss(f.duration), vs)
	local deaths = deathList(f)
	if #deaths > 0 then
		local d = ("Deaths: %d (first at %s)"):format(#deaths, mmss(deaths[1].t))
		if f.calledWipeAt then
			local pre = 0
			for _, dd in ipairs(deaths) do
				if dd.t < f.calledWipeAt then
					pre = pre + 1
				end
			end
			d = ("Deaths: %d (%d before the call, first at %s)"):format(#deaths, pre, mmss(deaths[1].t))
		end
		lines[#lines + 1] = d .. "."
	end
	if f.calledWipeAt and f.duration then
		local tail = math.floor(f.duration - f.calledWipeAt + 0.5)
		lines[#lines + 1] = ("Wipe called at %s; the pull ended %ds later."):format(
			mmss(f.calledWipeAt), tail)
	end
	local av = avoidableLine(f)
	if av then
		lines[#lines + 1] = av
	end
	-- group spike coverage: the windows are stamped identically on every
	-- player record, so any carrier speaks for the fight
	for _, p in pairs(f.players or {}) do
		local m = p.metrics or {}
		if (m.groupSpikeWindows or 0) > 0 then
			local un = m.groupSpikeWindows - (m.groupSpikeCovered or 0)
			if un > 0 then
				lines[#lines + 1] = ("%d of %d group damage spikes went uncovered."):format(
					un, m.groupSpikeWindows)
			end
			break
		end
	end
	local kd = kicksDispelsLine(f)
	if kd then
		lines[#lines + 1] = kd
	end
	local tough = toughnessLine(f)
	if tough then
		lines[#lines + 1] = tough
	end
	return lines
end

local function buildKill(ctx)
	local f = ctx.fight
	if not f then
		return nil
	end
	local lines = {}
	local vs = ""
	if f.prevKillDuration and f.duration then
		local diff = math.floor(f.prevKillDuration - f.duration + 0.5)
		if diff > 0 then
			vs = (" (%ds faster than last kill)"):format(diff)
		elseif diff < 0 then
			vs = (" (%ds slower than last kill)"):format(-diff)
		else
			vs = " (same as last kill)"
		end
	end
	lines[#lines + 1] = ("Kill: %s in %s%s."):format(f.name or "?", mmss(f.duration), vs)
	-- pulls + best prior attempt, from the run's fights on this boss
	local pulls, bestPct = 0, nil
	for _, rf in ipairs(ctx.runFights or {}) do
		if rf.name == f.name then
			pulls = pulls + 1
			if rf.wipe and rf.bossPct and (not bestPct or rf.bossPct < bestPct) then
				bestPct = rf.bossPct
			end
		end
	end
	if pulls > 1 then
		lines[#lines + 1] = ("Pull %d%s."):format(pulls,
			bestPct and (" - best prior attempt %d%%"):format(bestPct) or "")
	end
	local gs = ctx.groupScore or groupScore(ctx.results)
	if gs then
		lines[#lines + 1] = ("Group score %d."):format(gs)
	end
	local deaths = deathList(f)
	if #deaths == 0 then
		lines[#lines + 1] = "Deathless kill."
	else
		local line = ("Deaths: %d."):format(#deaths)
		local av = avoidableLine(f)
		if av then
			line = line .. " " .. av
		end
		lines[#lines + 1] = line
	end
	local kd = kicksDispelsLine(f)
	if kd then
		lines[#lines + 1] = kd
	end
	local tough = toughnessLine(f)
	if tough then
		lines[#lines + 1] = tough
	end
	return lines
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
	local lines = {}
	lines[#lines + 1] = ("Run: %s - %s, %s, %s fought."):format(
		ctx.zone or fights[1].zone or "?", plural(kills, "kill"), plural(wipes, "wipe"),
		mmss(fought))
	local gs = ctx.groupScore or groupScore(ctx.results)
	if gs then
		lines[#lines + 1] = ("Group run score %d."):format(gs)
	end
	local dl = ("Deaths: %d."):format(deaths)
	if taken > 0 and avoid > 0 then
		dl = dl .. (" Avoidable damage: %d%% of all damage taken."):format(
			math.floor(avoid / taken * 100 + 0.5))
	end
	lines[#lines + 1] = dl
	if kicksO > 0 then
		lines[#lines + 1] = ("Kicks across the run: %d/%d."):format(kicksL, kicksO)
	end
	if fastest and kills > 1 then
		lines[#lines + 1] = ("Fastest kill: %s (%s)."):format(fastest.name or "?", mmss(fastest.duration))
	end
	return lines
end

local function buildDeaths(ctx)
	local f = ctx.fight
	if not f then
		return nil
	end
	local deaths = deathList(f)
	if #deaths == 0 then
		return { ("Nobody died on %s."):format(f.name or "?") }
	end
	local lines = { ("Deaths on %s: %d (first at %s, last at %s)."):format(
		f.name or "?", #deaths, mmss(deaths[1].t), mmss(deaths[#deaths].t)) }
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
		lines[#lines + 1] = avoidable == 1
			and "1 of the killing blows was an avoidable hit."
			or ("%d of the killing blows were avoidable hits."):format(avoidable)
	end
	if ready > 0 then
		lines[#lines + 1] = ("%s died with 2+ defensives unused."):format(plural(ready, "player"))
	end
	local av = avoidableLine(f)
	if av then
		lines[#lines + 1] = av
	end
	return lines
end

local function buildPrep(ctx)
	local f = ctx.fight
	if not f then
		return nil
	end
	local reporting, ready = 0, 0
	local hsReporting, hsEaten = 0, 0
	for _, p in pairs(f.players or {}) do
		local m = p.metrics or {}
		if m.consumables ~= nil then
			reporting = reporting + 1
			if m.consumables >= 2 then
				ready = ready + 1
			end
		end
		if m.healthstones ~= nil then
			hsReporting = hsReporting + 1
			if m.healthstones > 0 then
				hsEaten = hsEaten + 1
			end
		end
	end
	if reporting == 0 and hsReporting == 0 then
		return { ("No preparation data for %s."):format(f.name or "?") }
	end
	local lines = {}
	if reporting > 0 then
		local missing = reporting - ready
		lines[#lines + 1] = ("Prep on %s: flask+food %d/%d%s."):format(
			f.name or "?", ready, reporting,
			missing > 0 and (" (%s missing)"):format(plural(missing, "player")) or "")
	end
	if hsReporting > 0 then
		lines[#lines + 1] = ("Healthstones eaten: %d/%d."):format(hsEaten, hsReporting)
	end
	return lines
end

-- one report, two shapes: the fight's outcome decides which story to
-- tell (Josh 2026-07-25: you'd never run a kill report on a wipe)
local function buildFight(ctx)
	if ctx.fight and ctx.fight.wipe then
		return buildWipe(ctx)
	end
	return buildKill(ctx)
end

-- The registry the panel renders, in display order. trigger names the
-- moment the report can auto-run (always local-only); manual-only
-- reports leave it nil. No report ever names a player.
Reports.LIST = {
	{
		key = "fight", name = "Fight analysis", trigger = "fight",
		desc = "The selected fight's story. Wipes: boss % vs last pull, deaths and call timing, avoidable damage, spike coverage. Kills: time vs last kill, pull count, group score. No names.",
		example = "Wipe: Garrosh Hellscream at 27% (5:43) - 14% further than last pull. / Kill: Garrosh Hellscream in 6:20 (12s faster than last kill).",
		build = buildFight,
	},
	{
		key = "run", name = "End of run", trigger = "runEnd",
		desc = "The whole visit in one report: kills, wipes, time fought, run score, deaths with avoidable share, and the fastest kill.",
		example = "Run: Siege of Orgrimmar - 8 kills, 3 wipes, 1:42:10 fought. Group run score 63. Deaths: 14.",
		build = buildRun,
	},
	{
		key = "deaths", name = "Death report",
		desc = "Death count and timing on the selected fight, avoidable killing blows, and deaths with defensives sitting unused. No names.",
		example = "Deaths on Garrosh Hellscream: 6 (first at 2:41, last at 5:50). 3 of the killing blows were avoidable hits.",
		build = buildDeaths,
	},
	{
		key = "prep", name = "Preparation check",
		desc = "How many brought flask and food, and healthstone use where a warlock provided them. Counts only, no names.",
		example = "Prep on Garrosh Hellscream: flask+food 8/10 (2 players missing). Healthstones eaten: 6/9.",
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
