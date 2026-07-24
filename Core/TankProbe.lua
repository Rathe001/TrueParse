-- /tp probe — dev probe for retail tanking ingredients (2026-07-24).
-- Midnight forbids CLEU, so the Tanking composite can't be computed for
-- retail tanks today. UNIT_COMBAT is a non-CLEU event that fires for
-- the OWN unit with incoming action types (WOUND/DODGE/PARRY/BLOCK) and
-- amounts — if it registers and the payloads aren't secret, each tank's
-- install can self-report avoidance + block the same way defensives and
-- activity are donated, and the composite comes to retail. This probe
-- answers registerable/readable; off unless toggled, session-only.
local _, TP = ...

local Probe = {}
TP.TankProbe = Probe

local frame
local active = false
local tallies, secrets, amountSamples

local function reset()
	tallies, secrets, amountSamples = {}, 0, {}
end

local function report()
	local parts = {}
	for action, n in pairs(tallies) do
		parts[#parts + 1] = ("%s %d"):format(tostring(action), n)
	end
	table.sort(parts)
	TP.Addon:Print(("probe: %s | secrets %d | sample amounts: %s"):format(
		#parts > 0 and table.concat(parts, ", ") or "no events",
		secrets, #amountSamples > 0 and table.concat(amountSamples, ", ") or "none"))
end

function Probe:Toggle()
	if active then
		active = false
		if frame then
			frame:UnregisterAllEvents()
		end
		TP.Addon:Print("Tank probe off.")
		return
	end
	if not frame then
		frame = CreateFrame("Frame")
		frame:SetScript("OnEvent", function(_, event, unit, action, _, amount)
			if event == "PLAYER_REGEN_ENABLED" then
				report()
				reset()
				return
			end
			-- UNIT_COMBAT: unit, action, modifier, amount, school
			if TP.Compat.IsSecret(action) or TP.Compat.IsSecret(amount) then
				secrets = secrets + 1
				return
			end
			tallies[action or "?"] = (tallies[action or "?"] or 0) + 1
			if type(amount) == "number" and #amountSamples < 6
				and (action == "WOUND" or action == "BLOCK") then
				amountSamples[#amountSamples + 1] = ("%s=%d"):format(action, amount)
			end
		end)
	end
	reset()
	-- registration itself may be forbidden (the CLEU lesson): report it
	local ok, err = pcall(frame.RegisterUnitEvent, frame, "UNIT_COMBAT", "player")
	if not ok then
		TP.Addon:Print("Tank probe: UNIT_COMBAT registration FORBIDDEN (" .. tostring(err) .. ")")
		return
	end
	frame:RegisterEvent("PLAYER_REGEN_ENABLED")
	active = true
	TP.Addon:Print("Tank probe ON: take some hits, then leave combat for the verdict. '/tp probe' again to stop.")
end
