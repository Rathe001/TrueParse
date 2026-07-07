-- One tasteful chat line after meaningful fights: your grade, your biggest
-- opportunity, and any awards you earned. Bosses and long pulls only —
-- never per-trash spam. Toggle: /tp coach.
local _, TP = ...

local CoachLine = {}
TP.CoachLine = CoachLine

local function countPlayers(players)
	local n = 0
	for _ in pairs(players) do
		n = n + 1
	end
	return n
end

local function qualifies(fight)
	return countPlayers(fight.players) >= 3 and (fight.isBoss or (fight.duration or 0) >= 45)
end

local function onFightCaptured(_, fight)
	if not TP.Addon.db.profile.coach or not qualifies(fight) then
		return
	end
	local results = TP.Scoring.Engine.ScoreFight(fight, TP.GetScoringOptions())
	local me
	for _, r in ipairs(results) do
		local p = fight.players[r.guid]
		if p and p.isLocalPlayer then
			me = r
			break
		end
	end
	if not me then
		return
	end

	local grade = TP.Scoring.Grades.ForScore(me.score)
	local gr, gg, gb = TP.Scoring.Grades.Color(grade)
	local msg = ("|cff%02x%02x%02x%s|r (%.0f) — %s"):format(
		gr * 255, gg * 255, gb * 255, grade, me.score, fight.name or "fight")

	local advice = TP.Scoring.Coach.BiggestOpportunity(me)
	if advice then
		if advice.kind == "avoidable" then
			msg = msg .. (" · biggest opportunity: avoidable damage (-%.0f)"):format(advice.gain)
		elseif advice.kind == "deaths" then
			msg = msg .. (" · biggest opportunity: staying alive (-%.0f)"):format(advice.gain)
		else
			local label = TP.METRIC_LABELS[advice.key] or advice.key
			msg = msg .. (" · biggest opportunity: %s (+%.0f potential)"):format(label:lower(), advice.gain)
		end
	end

	local mine = TP.Scoring.Awards.Compute(fight)[me.guid]
	if mine then
		msg = msg .. " · |cffffd700★ " .. table.concat(mine, ", ") .. "|r"
	end
	TP.Addon:Print(msg)
end

function CoachLine:OnEnable()
	-- Own AceEvent identity: AceEvent allows one handler per message per
	-- object, and TP.Addon's slot is taken by the meter window.
	LibStub("AceEvent-3.0"):Embed(self)
	self:RegisterMessage("TrueParse_FIGHT_CAPTURED", onFightCaptured)
end
