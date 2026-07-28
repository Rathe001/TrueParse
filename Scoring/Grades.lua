-- Score colors and display. TrueParse shows a color-coded number by
-- default — players already read scores the way Warcraft Logs taught them,
-- so the brackets are WCL's: grey under 25, green 25-49, blue 50-74,
-- purple 75-94, orange 95-98, pink 99, gold for a perfect 100. COLORS ARE
-- SCORE BRACKETS and stay that way (Josh 2026-07-28) — they are not derived
-- from the letter.
--
-- The optional letter ladder (profile.letterGrades) is the part that
-- changed: its two ends are EARNED rather than bracketed. S+ needs the
-- UNCLAMPED total to clear 99, so it can only come from adjustments on top
-- of an already-elite parse; F needs the score driven to zero. The other
-- fourteen letters spread evenly over 1-99. The old ladder started at 25 and
-- dumped everything below into a single F, so a whole band of ordinary grey
-- parses all read as failures.
-- PURE LUA: no WoW API calls; loaded headlessly by tests/run.lua.
local _, TP = ...

TP.Scoring = TP.Scoring or {}
local Grades = {}
TP.Scoring.Grades = Grades

Grades.LETTERS = { "D-", "D", "D+", "C-", "C", "C+", "B-", "B", "B+",
	"A-", "A", "A+", "S-", "S" }
Grades.TOP_LETTER = "S+" -- index #LETTERS + 1, reachable only over 99

local BAND = 99 / #Grades.LETTERS -- ~7.07 points per letter



-- 0 = F, 1..14 = the letter ladder, 15 = S+. unclamped is the pre-99 total;
-- without it the best reachable grade is S, which is correct for every
-- caller that only has a display score to hand.
local function letterIndex(score, unclamped)
	score = score or 0
	if unclamped and unclamped > 99 then
		return #Grades.LETTERS + 1
	end
	if score <= 0 then
		return 0
	end
	local idx = math.ceil(score / BAND)
	if idx < 1 then
		idx = 1
	elseif idx > #Grades.LETTERS then
		idx = #Grades.LETTERS
	end
	return idx
end
Grades.LetterIndex = letterIndex

-- WCL parse brackets, straight off the score. Unchanged.
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

function Grades.LetterFor(score, unclamped)
	local idx = letterIndex(score, unclamped)
	if idx == 0 then
		return "F"
	end
	return Grades.LETTERS[idx] or Grades.TOP_LETTER
end

-- The score as display text: number by default, letter when the option is
-- on. Headless tests have no options DB and always get numbers.
function Grades.ScoreLabel(score, unclamped)
	local db = TP.Addon and TP.Addon.db
	if db and db.profile.letterGrades then
		return Grades.LetterFor(score, unclamped)
	end
	return ("%.0f"):format(score or 0)
end

-- A clamped-to-0 score whose UNCLAMPED total went negative: parsed
-- nothing AND took penalties. Wears danger red — the one score that
-- earns shame (Josh 2026-07-25). Pass an engine result row.
function Grades.IsShamed(result)
	return result and (result.score or 0) <= 0 and (result.unclamped or 0) < 0
end
Grades.SHAME = { 0.90, 0.30, 0.30 } -- the reserved danger red

-- "|cffRRGGBB87|r" — the score as colored chat text (honors letter
-- grades). shamed = true paints the danger red instead of the bracket.
function Grades.ColoredScore(score, shamed, unclamped)
	local r, g, b
	if shamed then
		r, g, b = Grades.SHAME[1], Grades.SHAME[2], Grades.SHAME[3]
	else
		r, g, b = Grades.ColorForScore(score)
	end
	return ("|cff%02x%02x%02x%s|r"):format(
		math.floor(r * 255), math.floor(g * 255), math.floor(b * 255),
		Grades.ScoreLabel(score, unclamped))
end
