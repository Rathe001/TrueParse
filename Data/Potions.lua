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
		-- Verified against ranked Venomous Abyss kill tables 2026-08-27:
		-- the current tier pots with these two, and NEITHER was in this
		-- list - which is why potionHealing read zero in every one of
		-- 2,054 captured player-fights. When a new season's potion ships,
		-- verify the id the same way (scan WCL Healing tables of ranked
		-- kills for "Potion" entries) rather than trusting a constants dump.
		[1295247] = "Concentrated Silvermoon Health Potion",
		[452930] = "Demonic Healthstone",
		[6262] = "Healthstone",
	}
else
	-- Mists of Pandaria
	TP.POTION_HEALS = {
		[105708] = "Master Healing Potion",
		[6262] = "Healthstone",
	}
end
