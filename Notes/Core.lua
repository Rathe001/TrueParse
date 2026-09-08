-- Dungeon notes: the cheat sheet that follows you through a Mythic+ run,
-- rendered as the "Notes" view of the meter window (Josh 2026-09-08, canvas
-- round 3 for the look, round 4 option H for where it lives).
--
-- WHY IT IS SHAPED THIS WAY. Midnight (12.0.5+) makes every non-party unit's
-- identity secret on an instanced map: UnitName, UnitGUID and the npc id all
-- come back as secret values, in or out of combat, and the combat log is gone.
-- So the notes never ask "which mob is that". They ask what the game still
-- answers plainly: which dungeon (map -> Encounter Journal), which difficulty
-- (GetInstanceInfo), which boss (ENCOUNTER_START), how many bosses are dead
-- (ENCOUNTER_END), and who is reading (the player's own spec is not secret).
-- Trash notes are keyed to the stretch between bosses, not to the mob in
-- front of you.
--
-- DIFFICULTY comes from the Encounter Journal too: a boss note names its
-- ability, and the journal says whether that ability exists at the selected
-- difficulty. Normal runs don't see Mythic mechanics, and nobody hand-tags
-- the boss data.
--
-- Retail only: listed in the mainline TOCs, absent from Mists.
local _, TP = ...

local KN = {}
TP.Notes = KN

KN.IsSecret = TP.Compat.IsSecret

function KN.Print(msg)
	if TP.Addon and TP.Addon.Print then
		TP.Addon:Print(tostring(msg))
	else
		print("TrueParse notes: " .. tostring(msg))
	end
end

-- Keybinding labels (Bindings.xml at the repo root)
BINDING_HEADER_TRUEPARSE = "TrueParse"
BINDING_NAME_TRUEPARSE_NOTES = "Switch between Scores and Notes"
BINDING_NAME_TRUEPARSE_NOTES_NEXT = "Notes: next stretch of trash"
BINDING_NAME_TRUEPARSE_NOTES_PREV = "Notes: previous stretch of trash"

-- Difficulty rank: notes carry `min` = "n" | "h" | "m" | "k" and are hidden
-- below it. Keystone counts as above Mythic so a "k" note is key-only.
KN.DIFF_RANK = { n = 1, h = 2, m = 3, k = 4 }
KN.DIFF_BY_ID = {
	[1] = "n", [2] = "h", [23] = "m", [8] = "k",
	[24] = "h", [33] = "h", -- timewalking: heroic-shaped
}
KN.DIFF_LABEL = { n = "Normal", h = "Heroic", m = "Mythic", k = "Keystone" }

-- Palette: TrueParse's violet neutrals (UI/MeterWindow.lua, Josh 2026-07-28
-- design review) with the notes' own meaning colours on top. RGB so textures
-- and text share one definition; KN.Hex turns any entry into a colour code.
KN.RGB = {
	bg     = { 0.078, 0.067, 0.122 },
	band   = { 0.110, 0.095, 0.170 },
	line   = { 0.220, 0.192, 0.298 },
	chip   = { 0.133, 0.114, 0.192 },
	accent = { 0.812, 0.784, 0.871 }, -- the subtitle silver: dungeon name
	ink    = { 0.91, 0.90, 0.87 },
	bright = { 0.98, 0.98, 0.96 },
	dim    = { 0.45, 0.47, 0.53 },
	gold   = { 1.00, 0.827, 0.43 },  -- titles, numbers, the +N pill
	amber  = { 1.00, 0.827, 0.43 },
	teal   = { 0.50, 0.85, 0.82 },   -- your cooldown
	magic  = { 0.36, 0.56, 0.94 },
	curse  = { 0.66, 0.49, 0.90 },
	poison = { 0.42, 0.77, 0.42 },
	no     = { 0.73, 0.54, 0.54 },
	kick   = { 0.62, 0.70, 0.69 },
	purge  = { 0.50, 0.85, 0.82 },
	-- fear gets its own violet rather than borrowing the curse purple, and
	-- Mass Dispel a lighter blue than magic: both sit next to the tag they
	-- are most likely to be confused with, so they must not share its colour
	fear   = { 0.72, 0.45, 0.78 },
	mass   = { 0.45, 0.72, 0.95 },
	grey   = { 0.60, 0.60, 0.60 },
	blue   = { 0.35, 0.55, 0.90 },
	purple = { 0.64, 0.45, 0.85 },
}

function KN.Hex(rgb)
	return string.format("|cff%02x%02x%02x",
		math.floor(rgb[1] * 255 + 0.5), math.floor(rgb[2] * 255 + 0.5), math.floor(rgb[3] * 255 + 0.5))
end

-- One entry per kind of line: label word + colour.
KN.TAGS = {
	MAGIC   = { label = "Magic",    rgb = KN.RGB.magic },
	CURSE   = { label = "Curse",    rgb = KN.RGB.curse },
	POISON  = { label = "Poison",   rgb = KN.RGB.poison },
	DISEASE = { label = "Disease",  rgb = KN.RGB.no },
	BLEED   = { label = "Bleed",    rgb = KN.RGB.no },
	NO      = { label = "Bleed",    rgb = KN.RGB.no },
	KICK    = { label = "Kick",     rgb = KN.RGB.kick },
	PURGE   = { label = "Purge",    rgb = KN.RGB.purge },
	-- A fear is not reliably a magic dispel: Tremor Totem, Fear Ward and a
	-- dispel all answer it, and plenty of magic dispellers answer none of
	-- them. Its own tag so it reaches the specs that can actually act.
	FEAR    = { label = "Fear",     rgb = KN.RGB.fear },
	-- ONLY for effects nothing else removes - Divine Shield on Lightblinded
	-- Vanguard, Impervious Shield on the Spirit Kings. Where an ordinary
	-- dispel also works (Elegon's Closed Circuit) the line stays MAGIC, or
	-- every other dispeller loses a job they can do (Josh 2026-09-08).
	MASSDISP = { label = "Mass Dispel", rgb = KN.RGB.mass },
	SOOTHE  = { label = "Soothe",   rgb = KN.RGB.purge },
	STUN    = { label = "Stun",     rgb = KN.RGB.kick },
	CD      = { label = "Cooldown", rgb = KN.RGB.teal },
	LUST    = { label = "Lust",     rgb = KN.RGB.amber },
	TANK    = { label = "Tank",     rgb = KN.RGB.gold },
	BUILD   = { label = "Talents",  rgb = KN.RGB.dim },
	-- non-combat gates and pickups on a stretch: snitches to interrogate,
	-- totems to click, a path to choose, a bird to talk to (Josh 2026-09-08:
	-- "often a reason for confusion")
	TASK    = { label = "Objective", rgb = KN.RGB.accent },
}

KN.DIFF_COLOR = { n = KN.RGB.grey, h = KN.RGB.blue, m = KN.RGB.purple, k = KN.RGB.gold }

-- One icon per kind of line, from the game's own spell art.
KN.ICONS = {
	LUST    = "Interface\\Icons\\Spell_Nature_BloodLust",
	CD      = "Interface\\Icons\\INV_Misc_PocketWatch_01",
	MAGIC   = "Interface\\Icons\\Spell_Holy_DispelMagic",
	CURSE   = "Interface\\Icons\\Spell_Holy_RemoveCurse",
	POISON  = "Interface\\Icons\\Spell_Nature_NullifyPoison_02",
	DISEASE = "Interface\\Icons\\Spell_Holy_NullifyDisease",
	BLEED   = "Interface\\Icons\\Ability_Rogue_Rupture",
	NO      = "Interface\\Icons\\Ability_Rogue_Rupture",
	KICK    = "Interface\\Icons\\Ability_Kick",
	PURGE   = "Interface\\Icons\\Spell_Nature_Purge",
	FEAR    = "Interface\\Icons\\Spell_Nature_TremorTotem",
	MASSDISP = "Interface\\Icons\\Spell_Arcane_MassDispel",
	SOOTHE  = "Interface\\Icons\\Ability_Hunter_BeastSoothe",
	STUN    = "Interface\\Icons\\Spell_Frost_Stun",
	TANK    = "Interface\\Icons\\Ability_Warrior_DefensiveStance",
	BUILD   = "Interface\\Icons\\Ability_Marksmanship",
	TASK    = "Interface\\Icons\\INV_Misc_Map_01",
}

KN.FONT = {
	head = "Fonts\\FRIZQT__.TTF",
	body = "Fonts\\ARIALN.TTF",
}

-- Instance data registered by Notes\Season2.lua and friends. `kind` decides
-- whether trash exists at all.
--
-- KEYED BY JOURNAL instanceID, NOT BY NAME (2026-09-08). The old registry was
-- `KN.dungeons[def.name] = def`, and English journal names are not unique:
-- Midnight ships a dungeon called Magisters' Terrace (Arcanotron, Seranel
-- Sunlash, Gemellus, Degentrius) and the Burning Crusade Timewalking pool
-- contains the original (Selin Fireheart, Vexallus, Priestess Delrissa,
-- Kael'thas Sunstrider). Registering both silently discarded one, and the
-- name-substring lookup then matched whichever survived.
--
-- `instanceID` is optional while a name is unique, so nothing already written
-- has to change. The moment two defs share a name, BOTH must declare one or
-- registration fails at load - loudly, in a way a test catches, rather than
-- quietly losing a dungeon.
KN.instances = {}     -- every def, in registration order
KN.byInstanceID = {}  -- [journal instanceID] = def, for defs that declare one
KN.byName = {}        -- [normalised name] = { def, ... }

-- Journal names arrive with articles and punctuation that players do not type
-- ("The Necrotic Wake" vs "necrotic wake"). One normaliser, shared by the
-- registry and the tracker's lookup so they can never disagree.
function KN.Normalize(s)
	return (tostring(s or ""):lower():gsub("^the%s+", ""):gsub("[^%w]", ""))
end

local function register(def, kind)
	local key = KN.Normalize(def.name)
	local bucket = KN.byName[key]

	-- validate everything BEFORE touching any table, so a refused registration
	-- leaves the registry exactly as it was
	if bucket then
		local function needsID(d)
			if not d.instanceID then
				error(("Notes: '%s' is registered twice and %s declares no instanceID."
					.. " Colliding journal names need one each."):format(def.name,
					d == def and "the new one" or "the existing one"), 3)
			end
		end
		needsID(def)
		for _, other in ipairs(bucket) do needsID(other) end
	end
	if def.instanceID then
		local prev = KN.byInstanceID[def.instanceID]
		if prev and prev ~= def then
			error(("Notes: instanceID %s is already registered to '%s'")
				:format(tostring(def.instanceID), prev.name), 3)
		end
	end

	def.kind = kind
	if not bucket then
		bucket = {}
		KN.byName[key] = bucket
	end
	if def.instanceID then KN.byInstanceID[def.instanceID] = def end
	bucket[#bucket + 1] = def
	KN.instances[#KN.instances + 1] = def
	return def
end

-- Resolve to a single def. The journal's instanceID wins outright; a name is
-- only trusted when it is unambiguous. Returning nil on an ambiguous name is
-- deliberate: showing the wrong dungeon's notes is worse than showing none.
function KN.Find(name, instanceID)
	if instanceID and KN.byInstanceID[instanceID] then
		return KN.byInstanceID[instanceID]
	end
	local n = KN.Normalize(name)
	if n == "" then return nil end
	local exact = KN.byName[n]
	if exact then
		if #exact == 1 then return exact[1] end
		return nil, "ambiguous"
	end
	local hit, count = nil, 0
	for key, bucket in pairs(KN.byName) do
		if n:find(key, 1, true) or key:find(n, 1, true) then
			for _, d in ipairs(bucket) do
				count = count + 1
				hit = hit or d
			end
		end
	end
	if count == 1 then return hit end
	if count > 1 then return nil, "ambiguous" end
	return nil
end

function KN.RegisterDungeon(def)
	return register(def, "dungeon")
end

-- Raids register the same shape MINUS trash. Josh 2026-09-08: "trash notes
-- are really only needed in mythic+ ... we can exclude that entirely in
-- raids, since trash is generally not a problem there."
--
-- That also dissolves the ordering problem raids had. Trash was keyed to
-- `leg` = the stretch between boss N and N+1, which assumes bosses come in
-- one order; The Venomous Abyss has two wings clearable either way round.
-- With no trash there are no legs to sequence, so a raid needs nothing
-- special. The error is deliberate rather than a silent drop: a raid file
-- that grew a trash table is a mistake worth failing loudly at load.
function KN.RegisterRaid(def)
	if def.trash then
		error("Notes: raid '" .. tostring(def.name) .. "' must not define trash", 2)
	end
	return register(def, "raid")
end

-- Where learned dungeonEncounterID -> boss name pairs live, so a boss still
-- resolves on a day ENCOUNTER_START's name arrives secret.
function KN.LearnedBosses()
	local g = TP.Addon and TP.Addon.db and TP.Addon.db.global
	if not g then return {} end
	g.notesBosses = g.notesBosses or {}
	return g.notesBosses
end

function KN.Profile()
	return TP.Addon and TP.Addon.db and TP.Addon.db.profile or nil
end

-- The meter window's current view, "scores" or "notes".
function KN.ViewIsNotes()
	local p = KN.Profile()
	return p and p.window and p.window.view == "notes" or false
end

function KN:OnEnable()
	if KN.Player then KN.Player.Refresh() end
	if KN.Tracker then KN.Tracker.OnEnable() end
end
