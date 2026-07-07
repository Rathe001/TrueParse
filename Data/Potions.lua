-- Self-rescue heals: potions and Healthstones. Spell IDs of the HEAL these
-- items produce (what shows in healing data), per game version.
-- Extend per season; IDs sourced from Details' constants.
local _, TP = ...

if TP.Compat.IS_RETAIL then
	TP.POTION_HEALS = {
		[307192] = "Spiritual Healing Potion",
		[1234768] = "Cosmic Healing Potion",
		[1262857] = "Potent Healing Potion",
		[307194] = "Potion of Spectral Rejuvenation",
		[6262] = "Healthstone",
	}
else
	-- Mists of Pandaria
	TP.POTION_HEALS = {
		[105708] = "Master Healing Potion",
		[6262] = "Healthstone",
	}
end
