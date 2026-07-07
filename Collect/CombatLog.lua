-- CLEU hot path. Deliberately NOT AceEvent: a raw frame with a direct
-- OnEvent handler and a single dispatch-table lookup per event, zero
-- allocation. This can run thousands of times per second in raid combat.
local _, TP = ...

local Segments = TP.Segments
local CombatLogGetCurrentEventInfo = CombatLogGetCurrentEventInfo

local dispatch
local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function()
	local seg = Segments.current
	if not seg then
		return
	end
	-- Base payload: timestamp, subevent, hideCaster, srcGUID, srcName,
	-- srcFlags, srcRaidFlags, dstGUID, dstName, dstFlags, dstRaidFlags,
	-- then up to ~10 subevent-specific args.
	local _, subevent, _, srcGUID, _, srcFlags, _, dstGUID, _, dstFlags, _,
		a1, a2, a3, a4, a5, a6, a7, a8, a9, a10 = CombatLogGetCurrentEventInfo()
	local handler = dispatch[subevent]
	if handler then
		handler(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1, a2, a3, a4, a5, a6, a7, a8, a9, a10)
	end
end)

function TP.EnableCombatLog()
	TP.Metrics:BuildDispatch()
	dispatch = TP.Metrics.dispatch
	frame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
end
