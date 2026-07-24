-- Own-vs-top spell usage (the parse coach's raw material): counts each
-- player's casts of the spells that top parses of each spec signature
-- (Data/SpellProfiles_*). Classic CLEU path — retail can't see others'
-- casts. The flat watch set spans EVERY spec's profile (spec resolution
-- happens at comparison time; a resto druid's Rejuvenation count is
-- meaningless to a mage and simply never compared).
local _, TP = ...

local tracker = { subevents = {} }

local watchSet
local function watched(id)
	if not watchSet then
		watchSet = {}
		for _, prof in pairs(TP.SpellProfiles or {}) do
			for _, sp in ipairs(prof.spells or {}) do
				for _, spellID in ipairs(sp.ids or {}) do
					watchSet[spellID] = true
				end
			end
		end
	end
	return watchSet[id]
end

tracker.subevents.SPELL_CAST_SUCCESS = function(seg, srcGUID, dstGUID, srcFlags, dstFlags, a1)
	if not (a1 and watched(a1)) then
		return
	end
	local acc = seg.players[srcGUID]
	if not acc then
		return
	end
	local pc = acc.profCasts
	if not pc then
		pc = {}
		acc.profCasts = pc
	end
	pc[a1] = (pc[a1] or 0) + 1
end

tracker.InitPlayer = function(acc)
	acc.profCasts = nil -- lazy: most fights, most spells never fire
end
tracker.MergePlayer = function(dst, src)
	if src.profCasts then
		dst.profCasts = dst.profCasts or {}
		for id, n in pairs(src.profCasts) do
			dst.profCasts[id] = (dst.profCasts[id] or 0) + n
		end
	end
end

TP.Metrics:Register(tracker)
