-- Plain-language bullets explaining one player's score: green + for what
-- earned points, red - for what cost them, a dim mid-mark for middling
-- contributions. Ordered by weight so the biggest lever reads first.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Bullets = {}
TP.Scoring.Bullets = Bullets

local COUNT_METRICS = { interrupts = true, dispels = true }

local GOOD = { 0.30, 0.90, 0.40 }
local BAD = { 0.95, 0.35, 0.35 }
local MID = { 0.80, 0.80, 0.55 }
local GOLD = { 1.00, 0.82, 0.20 }

local PENALTY_DEFS = {
	{ key = "deaths", label = "Died" },
	{ key = "avoidable", label = "Avoidable damage taken" },
	{ key = "buffs", label = "Raid buff missing at the pull" },
}

-- result: one engine score row; awards: array of award names (optional).
-- Returns array of { kind = "metric"|"penalty"|"award", key, symbol,
-- color = {r,g,b}, text }
function Bullets.ForResult(result, awards)
	local out = {}

	local metrics = {}
	for key, b in pairs(result.breakdown) do
		if b.applicable then
			metrics[#metrics + 1] = { key = key, b = b }
		end
	end
	table.sort(metrics, function(x, y)
		return (x.b.effectiveWeight or 0) > (y.b.effectiveWeight or 0)
	end)

	for _, m in ipairs(metrics) do
		local b, key = m.b, m.key
		local normalized = b.normalized or 0
		local label = TP.METRIC_LABELS[key] or key
		local raw
		if COUNT_METRICS[key] then
			raw = ("%d"):format(b.value or 0)
		else
			raw = TP.FormatNumber(b.value or 0)
		end
		local symbol, color
		if normalized >= 70 then
			symbol, color = "+", GOOD
		elseif normalized <= 45 then
			symbol, color = "-", BAD
		else
			symbol, color = "\194\183", MID -- middle dot: present in all client fonts
		end
		out[#out + 1] = {
			kind = "metric", key = key, symbol = symbol, color = color,
			text = ("%s (%s): %.0f/100 — %.1f of %.0f possible pts"):format(
				label, raw, normalized, b.contribution or 0, (b.effectiveWeight or 0) * 100),
		}
	end

	local pd = result.penaltyDetail or {}
	for _, def in ipairs(PENALTY_DEFS) do
		local amount = pd[def.key] or 0
		if amount > 0 then
			out[#out + 1] = {
				kind = "penalty", key = def.key, symbol = "-", color = BAD,
				text = ("%s: -%.1f pts"):format(def.label, amount),
			}
		end
	end

	for _, award in ipairs(awards or {}) do
		out[#out + 1] = { kind = "award", symbol = "+", color = GOLD, text = award }
	end

	return out
end
