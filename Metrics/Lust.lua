-- Bloodlust-window usage, from CLEU (Classic path). When a lust buff goes
-- out, a 40s window opens on the segment; offensive cooldown casts and DPS
-- potion buffs inside it are tallied per player. Scored ±3 for DPS via the
-- lust adjustment (Engine); bullets phrase it.
local _, TP = ...

local tracker = { subevents = {} }

local LUST_DURATION = 40
-- pre-lusting is CORRECT play: popping cooldowns just before the lust
-- lands saves a global (Josh, 2026-07-16 — his pre-lust CDs read
-- "Wasted Bloodlust"). Casts this many seconds BEFORE the buff count.
local LUST_PRE_GRACE = 10
-- a cast queued at the window's edge lands just after it: same grace idea
local LUST_POST_GRACE = 2

tracker.subevents.SPELL_AURA_APPLIED = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	if not a1 then
		return
	end
	if TP.LUST and TP.LUST[a1] then
		if not seg.lustSeen then
			-- retro-credit cooldowns popped in the pre-lust grace
			local since = GetTime() - LUST_PRE_GRACE
			for _, acc in pairs(seg.players) do
				local l = acc.lust
				if l and l.recent then
					for _, t in ipairs(l.recent) do
						if t >= since then
							l.casts = l.casts + 1
						end
					end
					l.recent = nil
				end
			end
		end
		if not seg.lustSeen and seg.startTime then
			-- the window's fight-offset: the engine forgives "wasted lust"
			-- for players already dead when it opened (audit 2026-07-18)
			seg.lustAt = GetTime() - seg.startTime
		end
		seg.lustSeen = true
		seg.lustUntil = GetTime() + LUST_DURATION
		return
	end
	if TP.DPS_POTIONS and TP.DPS_POTIONS[a1]
		and seg.lustUntil and GetTime() < seg.lustUntil then
		local acc = seg.players[dstGUID]
		if acc and acc.lust then
			acc.lust.potion = true
		end
	end
end

tracker.subevents.SPELL_CAST_SUCCESS = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	if not a1 or not (TP.OFFENSIVE_CDS and TP.OFFENSIVE_CDS[a1]) then
		return
	end
	local acc = seg.players[srcGUID] -- players only; pet casts don't count
	if not (acc and acc.lust) then
		return
	end
	acc.lust.totalCasts = acc.lust.totalCasts + 1
	if seg.lustUntil and GetTime() < seg.lustUntil + LUST_POST_GRACE then
		acc.lust.casts = acc.lust.casts + 1
	elseif not seg.lustSeen then
		-- remember pre-lust casts so a lust in the next few seconds
		-- can claim them (ring of 4: nobody pre-lusts more CDs)
		local l = acc.lust
		l.recent = l.recent or {}
		l.recent[#l.recent % 4 + 1] = GetTime()
	end
end

tracker.InitPlayer = function(acc)
	acc.lust = { casts = 0, totalCasts = 0, potion = false }
end
tracker.MergePlayer = function(dst, src)
	dst.lust.casts = dst.lust.casts + (src.lust and src.lust.casts or 0)
	dst.lust.totalCasts = (dst.lust.totalCasts or 0) + (src.lust and src.lust.totalCasts or 0)
	dst.lust.potion = dst.lust.potion or (src.lust and src.lust.potion) or false
end

TP.Metrics:Register(tracker)
