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

-- One color per letter family (the +/- variants share it)
local COLORS = {
	S = { 1.00, 0.82, 0.20 }, -- gold
	A = { 0.30, 0.90, 0.40 }, -- green
	B = { 0.35, 0.65, 1.00 }, -- blue
	C = { 0.90, 0.88, 0.55 }, -- pale yellow
	D = { 0.62, 0.62, 0.62 }, -- grey
	F = { 0.95, 0.25, 0.25 }, -- red
}

function Grades.Color(grade)
	local c = COLORS[grade:sub(1, 1)] or COLORS.C
	return c[1], c[2], c[3]
end
