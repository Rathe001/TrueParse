-- Letter grades for contribution scores. 16 tiers: F for scores under 25,
-- then 5-point steps from D- (25) up to S+ (95-100).
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Grades = {}
TP.Scoring.Grades = Grades

Grades.ORDER = {
	"F", "D-", "D", "D+", "C-", "C", "C+", "B-", "B", "B+",
	"A-", "A", "A+", "S-", "S", "S+",
}

function Grades.ForScore(score)
	if not score or score < 25 then
		return "F"
	end
	local index = math.floor((score - 25) / 5) + 2
	if index > #Grades.ORDER then
		index = #Grades.ORDER
	end
	return Grades.ORDER[index]
end

-- Warcraft Logs parse-bracket colors, mapped onto our score thresholds so
-- the tiers read instantly to anyone who knows WCL: grey <25, green 25-49,
-- blue 50-74, purple 75-94, orange 95+, with pink at 99+ and gold at 100
-- (pass the score for those two).
local GREY = { 0.40, 0.40, 0.40 }
local GREEN = { 0.12, 1.00, 0.00 }
local BLUE = { 0.00, 0.44, 1.00 }
local PURPLE = { 0.64, 0.21, 0.93 }
local ORANGE = { 1.00, 0.50, 0.00 }
local PINK = { 0.89, 0.41, 0.66 }
local GOLD = { 0.90, 0.80, 0.50 }

local COLORS = {
	["F"] = GREY,
	["D-"] = GREEN, ["D"] = GREEN, ["D+"] = GREEN, ["C-"] = GREEN, ["C"] = GREEN,
	["C+"] = BLUE, ["B-"] = BLUE, ["B"] = BLUE, ["B+"] = BLUE, ["A-"] = BLUE,
	["A"] = PURPLE, ["A+"] = PURPLE, ["S-"] = PURPLE, ["S"] = PURPLE,
	["S+"] = ORANGE,
}

function Grades.Color(grade, score)
	if score and score >= 100 then
		return GOLD[1], GOLD[2], GOLD[3]
	elseif score and score >= 99 then
		return PINK[1], PINK[2], PINK[3]
	end
	local c = COLORS[grade] or BLUE
	return c[1], c[2], c[3]
end
