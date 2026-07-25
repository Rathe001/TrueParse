-- Shareable chat reports (Josh 2026-07-25): each report turns a fight
-- (or a run) into a few plain-text lines fit for a chat channel — no
-- color codes, every line under the 255-char chat ceiling, no more
-- than ~5 lines so nobody gets spammed.
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

-- "Baddchi 99, Richardslice 97, Widowwmaker 86" — top n by score
local function topLine(results, n)
	local sorted = {}
	for _, r in ipairs(results or {}) do
		if r.score then
			sorted[#sorted + 1] = r
		end
	end
	table.sort(sorted, function(a, b)
		return (a.score or 0) > (b.score or 0)
	end)
	local parts = {}
	for i = 1, math.min(n or 3, #sorted) do
		parts[#parts + 1] = ("%s %d"):format(sorted[i].name or "?", sorted[i].score)
	end
	return #parts > 0 and table.concat(parts, ", ") or nil
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

-- every death in a fight as { t, name, cause, avoidable }, oldest first
local function deathList(fight)
	local out = {}
	for _, p in pairs(fight.players or {}) do
		local times = p.deathTimes or (p.deathTime and { p.deathTime }) or {}
		for _, t in ipairs(times) do
			local cause, avoidable
			-- the recap describes the LAST death; attach it there only
			if t == times[#times] and p.deathRecap and #p.deathRecap > 0 then
				local hit = p.deathRecap[#p.deathRecap]
				cause, avoidable = hit.spell, hit.avoidable
			end
			out[#out + 1] = { t = t, name = p.name or "?", cause = cause, avoidable = avoidable }
		end
	end
	table.sort(out, function(a, b)
		return a.t < b.t
	end)
	return out
end

local function causeSuffix(d)
	if not d.cause then
		return ""
	end
	return (" - %s%s"):format(d.cause, d.avoidable and " (avoidable)" or "")
end

local function buildWipe(ctx)
	local f = ctx.fight
	if not f then
		return nil
	end
	local lines = {}
	lines[#lines + 1] = ("Wipe: %s%s (%s)."):format(f.name or "?",
		f.bossPct and (" at %d%%"):format(f.bossPct) or "", mmss(f.duration))
	local deaths = deathList(f)
	if #deaths > 0 then
		local d = deaths[1]
		lines[#lines + 1] = ("First death: %s at %s%s."):format(d.name, mmss(d.t), causeSuffix(d))
	end
	if f.calledWipeAt then
		local pre = 0
		for _, d in ipairs(deaths) do
			if d.t < f.calledWipeAt then
				pre = pre + 1
			end
		end
		lines[#lines + 1] = ("Wipe called at %s%s - %d death%s before the call, %d after."):format(
			mmss(f.calledWipeAt), f.wipeCalledBy and (" by " .. f.wipeCalledBy) or "",
			pre, pre == 1 and "" or "s", #deaths - pre)
	elseif #deaths > 0 then
		lines[#lines + 1] = ("Deaths: %d."):format(#deaths)
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
	local top = topLine(ctx.results, 3)
	if gs then
		lines[#lines + 1] = ("Group score %d%s."):format(gs, top and (". Top: " .. top) or "")
	end
	local deaths = deathList(f)
	if #deaths == 0 then
		lines[#lines + 1] = "Deathless kill."
	end
	return lines
end

local function buildRun(ctx)
	local fights = ctx.runFights
	if not fights or #fights == 0 then
		return nil
	end
	local kills, wipes, fought, deaths = 0, 0, 0, 0
	local fastest
	for _, f in ipairs(fights) do
		fought = fought + (f.duration or 0)
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
			deaths = deaths + ((p.metrics or {}).deaths or 0)
		end
	end
	local lines = {}
	lines[#lines + 1] = ("Run: %s - %d kill%s, %d wipe%s, %s fought."):format(
		ctx.zone or fights[1].zone or "?", kills, kills == 1 and "" or "s",
		wipes, wipes == 1 and "" or "s", mmss(fought))
	local gs = ctx.groupScore or groupScore(ctx.results)
	local top = topLine(ctx.results, 3)
	if gs then
		lines[#lines + 1] = ("Group run score %d%s."):format(gs, top and (". Top: " .. top) or "")
	end
	lines[#lines + 1] = ("Deaths: %d."):format(deaths)
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
	local lines = { ("Deaths on %s (%d):"):format(f.name or "?", #deaths) }
	for i = 1, math.min(8, #deaths) do
		local d = deaths[i]
		lines[#lines + 1] = ("%s at %s%s"):format(d.name, mmss(d.t), causeSuffix(d))
	end
	if #deaths > 8 then
		lines[#lines + 1] = ("...and %d more."):format(#deaths - 8)
	end
	return lines
end

local function buildPrep(ctx)
	local f = ctx.fight
	if not f then
		return nil
	end
	local reporting, ready, missing = 0, 0, {}
	local hsReporting, hsEaten = 0, 0
	for _, p in pairs(f.players or {}) do
		local m = p.metrics or {}
		if m.consumables ~= nil then
			reporting = reporting + 1
			if m.consumables >= 2 then
				ready = ready + 1
			else
				missing[#missing + 1] = p.name or "?"
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
		table.sort(missing)
		local miss = ""
		if #missing > 0 then
			local named = {}
			for i = 1, math.min(4, #missing) do
				named[i] = missing[i]
			end
			miss = (" Missing: %s%s."):format(table.concat(named, ", "),
				#missing > 4 and (" +%d more"):format(#missing - 4) or "")
		end
		lines[#lines + 1] = ("Prep on %s: flask+food %d/%d.%s"):format(
			f.name or "?", ready, reporting, miss)
	end
	if hsReporting > 0 then
		lines[#lines + 1] = ("Healthstones eaten: %d/%d."):format(hsEaten, hsReporting)
	end
	return lines
end

-- The registry the panel renders, in display order. trigger names the
-- moment the report can auto-run (always local-only); manual-only
-- reports leave it nil.
Reports.LIST = {
	{
		key = "wipe", name = "Wipe analysis", trigger = "wipe",
		desc = "Root-cause read on the latest wipe: where it ended, who died first and to what, spike coverage, and the call.",
		example = 'Wipe: Garrosh Hellscream at 27% (5:43). First death: Nightbriar at 2:41 - Whirling Corruption (avoidable).',
		build = buildWipe,
	},
	{
		key = "kill", name = "Kill analysis", trigger = "kill",
		desc = "Kill time vs your last kill, pull count with best prior attempt, and the group's scores.",
		example = "Kill: Garrosh Hellscream in 6:20 (12s faster than last kill). Group score 63. Top: Baddchi 99, ...",
		build = buildKill,
	},
	{
		key = "run", name = "End of run", trigger = "runEnd",
		desc = "The whole visit in one report: kills, wipes, time fought, run scores, and the fastest kill.",
		example = "Run: Siege of Orgrimmar - 8 kills, 3 wipes, 1:42:10 fought. Group run score 63.",
		build = buildRun,
	},
	{
		key = "deaths", name = "Death report",
		desc = "Every death on the selected fight with its killing blow, avoidable hits flagged.",
		example = "Deaths on Garrosh Hellscream (3): Nightbriar at 2:41 - Whirling Corruption (avoidable), ...",
		build = buildDeaths,
	},
	{
		key = "prep", name = "Preparation check",
		desc = "Who brought flask and food (named when missing), and healthstone use where a warlock provided them.",
		example = "Prep on Garrosh Hellscream: flask+food 8/10. Missing: Nightbriar, Sunspire. Healthstones eaten: 6/9.",
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
