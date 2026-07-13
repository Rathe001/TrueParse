-- Lowest-health tracking: a 1s in-combat sampler records each group
-- member's lowest health fraction for the fight (dead counts as 0), which
-- feeds healer awards like Topped Off ("nobody dropped below half").
-- CLASSIC ONLY: Midnight secrets friendly health values mid-combat, so
-- retail fight records simply never carry minHealthPct and the awards that
-- need it stay unearnable there.
local _, TP = ...

local Vitals = {}
TP.Vitals = Vitals

local ticker

local function sample()
	local seg = TP.Segments.current
	if not seg then
		return
	end
	for guid, info in pairs(TP.Roster.players) do
		if UnitExists(info.unit) then
			local acc = seg.players[guid]
			if acc then
				local pct
				if UnitIsDeadOrGhost(info.unit) then
					pct = 0
				else
					local maxHp = UnitHealthMax(info.unit)
					if maxHp and maxHp > 0 then
						pct = UnitHealth(info.unit) / maxHp
					end
				end
				if pct and (not acc.minHealthPct or pct < acc.minHealthPct) then
					acc.minHealthPct = pct
				end
				-- healer mana timeline: the lowest the tank's lifeline got.
				-- Distinguishes a pacing problem (dry at 30% boss HP) from a
				-- throughput problem (plenty left on a wipe).
				if info.role == "HEALER" and not UnitIsDeadOrGhost(info.unit) then
					local maxMana = UnitPowerMax(info.unit, 0)
					if maxMana and maxMana > 0 then
						local mp = UnitPower(info.unit, 0) / maxMana
						if not acc.minManaPct or mp < acc.minManaPct then
							acc.minManaPct = mp
							if mp < 0.08 and not acc.dryAt and seg.startTime then
								acc.dryAt = GetTime() - seg.startTime
							end
						end
					end
				end
			end
		end
	end
end

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:SetScript("OnEvent", function()
	if TP.Compat.IS_RETAIL or ticker then
		return
	end
	ticker = C_Timer.NewTicker(1, function()
		if not TP.Segments.current then
			ticker:Cancel()
			ticker = nil
			return
		end
		sample()
	end)
end)
