-- Score colors. TrueParse shows a color-coded number, no letter tiers —
-- players already read scores the way Warcraft Logs taught them, so the
-- brackets are WCL's: grey under 25, green 25-49, blue 50-74, purple 75-94,
-- orange 95-98, pink 99, gold for a perfect 100.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Grades = {}
TP.Scoring.Grades = Grades

function Grades.ColorForScore(score)
	score = score or 0
	if score >= 100 then
		return 0.90, 0.80, 0.50 -- gold
	elseif score >= 99 then
		return 0.89, 0.41, 0.66 -- pink
	elseif score >= 95 then
		return 1.00, 0.50, 0.00 -- orange
	elseif score >= 75 then
		return 0.64, 0.21, 0.93 -- purple
	elseif score >= 50 then
		return 0.00, 0.44, 1.00 -- blue
	elseif score >= 25 then
		return 0.12, 1.00, 0.00 -- green
	end
	return 0.40, 0.40, 0.40 -- grey
end

-- "|cffRRGGBB87|r" — the score as colored chat text
function Grades.ColoredScore(score)
	local r, g, b = Grades.ColorForScore(score)
	return ("|cff%02x%02x%02x%.0f|r"):format(
		math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), score or 0)
end
