-- Major personal defensive cooldowns, per game version. Used by the
-- own-cast recorder (own casts are never secret) whose counts are shared
-- with other TrueParse users over the addon channel. Curated and
-- deliberately conservative: big buttons only, extend per patch.
local _, TP = ...

if TP.Compat.IS_RETAIL then
	TP.DEFENSIVES = {
		[871] = true,    -- Shield Wall
		[12975] = true,  -- Last Stand
		[97462] = true,  -- Rallying Cry
		[118038] = true, -- Die by the Sword
		[642] = true,    -- Divine Shield
		[31850] = true,  -- Ardent Defender
		[86659] = true,  -- Guardian of Ancient Kings
		[498] = true,    -- Divine Protection
		[1022] = true,   -- Blessing of Protection
		[186265] = true, -- Aspect of the Turtle
		[109304] = true, -- Exhilaration
		[5277] = true,   -- Evasion
		[31224] = true,  -- Cloak of Shadows
		[185311] = true, -- Crimson Vial
		[19236] = true,  -- Desperate Prayer
		[47585] = true,  -- Dispersion
		[48792] = true,  -- Icebound Fortitude
		[48707] = true,  -- Anti-Magic Shell
		[55233] = true,  -- Vampiric Blood
		[108271] = true, -- Astral Shift
		[45438] = true,  -- Ice Block
		[110959] = true, -- Greater Invisibility
		[104773] = true, -- Unending Resolve
		[108416] = true, -- Dark Pact
		[115203] = true, -- Fortifying Brew
		[122783] = true, -- Diffuse Magic
		[122278] = true, -- Dampen Harm
		[22812] = true,  -- Barkskin
		[61336] = true,  -- Survival Instincts
		[198589] = true, -- Blur
		[196555] = true, -- Netherwalk
		[363916] = true, -- Obsidian Scales
		[374348] = true, -- Renewing Blaze
	}
else
	-- Mists of Pandaria
	TP.DEFENSIVES = {
		[871] = true,    -- Shield Wall
		[12975] = true,  -- Last Stand
		[118038] = true, -- Die by the Sword
		[642] = true,    -- Divine Shield
		[31850] = true,  -- Ardent Defender
		[86659] = true,  -- Guardian of Ancient Kings
		[498] = true,    -- Divine Protection
		[19263] = true,  -- Deterrence
		[5277] = true,   -- Evasion
		[31224] = true,  -- Cloak of Shadows
		[74001] = true,  -- Combat Readiness
		[19236] = true,  -- Desperate Prayer
		[47585] = true,  -- Dispersion
		[48792] = true,  -- Icebound Fortitude
		[48707] = true,  -- Anti-Magic Shell
		[55233] = true,  -- Vampiric Blood
		[108271] = true, -- Astral Shift
		[30823] = true,  -- Shamanistic Rage
		[45438] = true,  -- Ice Block
		[104773] = true, -- Unending Resolve
		[115203] = true, -- Fortifying Brew
		[115176] = true, -- Zen Meditation
		[122783] = true, -- Diffuse Magic
		[122278] = true, -- Dampen Harm
		[22812] = true,  -- Barkskin
		[61336] = true,  -- Survival Instincts
	}
end
