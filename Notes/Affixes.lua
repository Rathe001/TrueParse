-- Affixes: a short effect line for the header, keyed by the name that
-- C_ChallengeMode.GetAffixInfo returns. The icon comes from the same call
-- (its fileDataID), so nothing here names a texture.
--
-- `match` is compared as a substring of the live name so "Xal'atath's
-- Bargain: Devour" finds "Devour". `key` is what a note's `affix` field
-- names to show only on that week.
local _, TP = ...
local KN = TP.Notes

KN.AFFIXES = {
	{ key = "Tyrannical", match = "Tyrannical", rgb = KN.RGB.amber,  short = "bosses +25% hp, +15% dmg" },
	{ key = "Fortified",  match = "Fortified",  rgb = KN.RGB.blue,   short = "trash +20% hp, +20% dmg" },
	{ key = "Ascendant",  match = "Ascendant",  rgb = KN.RGB.purple, short = "stop 10 orb casts: kick, CC, purge or knock" },
	{ key = "Voidbound",  match = "Voidbound",  rgb = KN.RGB.purple, short = "kill the Emissary, kick Dark Prayer" },
	{ key = "Pulsar",     match = "Pulsar",     rgb = KN.RGB.purple, short = "run to each other to clear them" },
	{ key = "Devour",     match = "Devour",     rgb = KN.RGB.purple, short = "dispel the rifts, 5 per pull" },
	{ key = "Guile",      match = "Guile",      rgb = KN.RGB.no,     short = "each death costs 15s" },
	{ key = "Guidance",   match = "Guidance",   rgb = KN.RGB.dim,    short = "enemies marked, 5% weaker" },
}

function KN.AffixDef(liveName)
	if not liveName then return nil end
	for _, a in ipairs(KN.AFFIXES) do
		if liveName:find(a.match, 1, true) then return a end
	end
	return nil
end

-- Season 2 keystone ladder (/kn ladder and the +N header label).
KN.LADDER = {
	{ from = 2,  ["until"] = 5,  text = "Lindormi's Guidance: enemies highlighted, 5% less damage and health" },
	{ from = 5,  ["until"] = 11, text = "One Xal'atath's Bargain, rotating weekly: Ascendant / Voidbound / Pulsar / Devour" },
	{ from = 7,  ["until"] = 9,  text = "Fortified OR Tyrannical, alternating weeks" },
	{ from = 10, ["until"] = nil, text = "Fortified AND Tyrannical, both" },
	{ from = 12, ["until"] = nil, text = "Bargain becomes Xal'atath's Guile: each death costs 15s" },
}

function KN.LadderLines(level)
	local out = {}
	for _, row in ipairs(KN.LADDER) do
		local active = level and level >= row.from and (row["until"] == nil or level <= row["until"])
		local range = row["until"] and ("+" .. row.from .. " to +" .. row["until"]) or ("+" .. row.from .. " and up")
		out[#out + 1] = { range = range, text = row.text, active = active }
	end
	return out
end
