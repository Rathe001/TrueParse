-- Who is reading the notes: class, spec, role, range, and what they can do.
-- Player-unit reads are exempt from Midnight's secret values, but every
-- value is still guarded because that exemption has moved before.
local _, TP = ...
local KN = TP.Notes

local Player = {}
KN.Player = Player

local IsSecret = KN.IsSecret

local function plain(v)
	if v == nil or IsSecret(v) then return nil end
	return v
end

local ROLE_BY_API = { TANK = "tank", HEALER = "healer", DAMAGER = "dps" }

local state = {
	class = nil, specID = nil, caps = nil,
	role = "dps", range = "ranged",
	override = nil, -- { role=, range=, caps=, class=, label= } from /tp notes as
}
Player.state = state

-- Raw API returns from the last read, for /tp notes debug. Mists showed
-- "Unknown spec Monk" for a whole session (Josh 2026-09-08) and the header
-- cannot say whether the index, the id or the lookup was the part that
-- failed; this can.
state.raw = {}

local function readSpec()
	local raw = state.raw
	wipe(raw)
	local _, class, classID = UnitClass("player")
	class = plain(class)
	state.class = class
	raw.classID = plain(classID)
	local Compat = TP.Compat
	local idx = plain(Compat.GetSpecialization())
	raw.idx = idx
	-- Mists (dual spec): the bare call answered nil inside Siege of
	-- Orgrimmar while the roster's earlier call had answered (Josh
	-- 2026-09-08, idx=nil roster=269). Ask again naming the active talent
	-- group, which is the one argument the call takes.
	if not idx then
		local okG, group = pcall(Compat.GetActiveSpecGroup)
		group = okG and plain(group) or nil
		raw.group = group
		if group then
			local okS, i = pcall(Compat.GetSpecialization, false, false, group)
			idx = okS and plain(i) or nil
			raw.idxByGroup = idx
		end
	end
	local specID, apiRole
	local icon
	-- a spec icon is a fileDataID (retail) or a texture path (older
	-- clients); 0 and "" are the API's way of saying none
	local function useIcon(v)
		v = plain(v)
		if type(v) == "number" and v > 0 then return v end
		if type(v) == "string" and v ~= "" then return v end
		return nil
	end
	if idx then
		local ok, id, _, _, ic, role = pcall(Compat.GetSpecializationInfo, idx)
		raw.infoOK, raw.id, raw.role = ok, ok and id or nil, ok and role or nil
		if not ok then raw.err = tostring(id) end
		if ok then
			specID = plain(id)
			apiRole = plain(role)
			icon = useIcon(ic)
		end
	end
	-- Fallbacks, tried only when the direct read gives nothing usable:
	-- the per-class table (same data, different entry point), then the
	-- roster's own read of the player, which the scoring already trusts on
	-- both clients.
	if not (specID and KN.CLASSES[specID]) and idx and raw.classID then
		local ok, id, _, _, ic, role = pcall(Compat.GetSpecializationInfoForClassID, raw.classID, idx)
		raw.byClassID = ok and id or nil
		if ok and plain(id) and KN.CLASSES[plain(id)] then
			specID, apiRole = plain(id), plain(role) or apiRole
			icon = icon or useIcon(ic)
		end
	end
	state.icon = icon
	if not (specID and KN.CLASSES[specID]) and TP.Roster and TP.Roster.players and UnitGUID then
		local me = TP.Roster.players[UnitGUID("player")]
		raw.roster = me and me.specID or nil
		if me and me.specID and KN.CLASSES[me.specID] then
			specID = me.specID
		end
	end
	state.specID = specID
	local caps = specID and KN.CLASSES[specID]
	if not caps and class then
		-- unknown spec id (a new spec): borrow the class row, trust the API role
		local fb = KN.CLASS_FALLBACK[class]
		if fb then
			caps = {}
			for k, v in pairs(fb) do caps[k] = v end
			caps.name = "Unknown spec"
			caps.role = ROLE_BY_API[apiRole or ""] or fb.role
			caps.range = "melee"
		end
	end
	state.caps = caps
	state.role = caps and caps.role or (ROLE_BY_API[apiRole or ""] or "dps")
	state.range = caps and caps.range or "ranged"
end

function Player.Refresh()
	if not UnitClass then return end
	local ok, err = pcall(readSpec)
	if not ok then KN.Print("spec read failed: " .. tostring(err)) end
end

-- The spec API can answer nil at load and at PLAYER_ENTERING_WORLD on a
-- Classic client (Josh 2026-09-08, Mists: a Monk read as "Unknown spec
-- Monk · Tank" for the whole session). A nil read is not an answer, so
-- every reader retries it until one succeeds. Cheap: two API calls, and
-- only while the spec is still unknown.
local function ensure()
	if state.specID == nil and UnitClass then Player.Refresh() end
end

function Player.Role()
	ensure()
	return (state.override and state.override.role) or state.role
end

function Player.Range()
	ensure()
	return (state.override and state.override.range) or state.range
end

function Player.Caps()
	ensure()
	return (state.override and state.override.caps) or state.caps or {}
end

function Player.Class()
	ensure()
	return (state.override and state.override.class) or state.class
end

-- The spec's own icon, read alongside the id. Nothing draws it since the
-- lines that are yours went text-only (Josh 2026-09-09); kept because it
-- comes free with the read and the debug line can show it.
function Player.Icon()
	ensure()
	if state.override then return nil end
	return state.icon
end

function Player.Can(need)
	if not need then return true end
	local caps = Player.Caps()
	return caps[need] and true or false
end

-- A note's `role` against the player: "dps" means both ranges; "melee" and
-- "ranged" apply to healers and DPS alike; "tank"/"healer" are exact.
function Player.RoleMatches(role)
	if not role then return true end
	local r, range = Player.Role(), Player.Range()
	if role == "dps" then return r == "dps" end
	if role == "melee" or role == "ranged" then return range == role end
	return role == r
end

-- Dispel tags take the player's spell name as the line's label.
local TAG_TO_TYPE = { MAGIC = "magic", CURSE = "curse", POISON = "poison", DISEASE = "disease", BLEED = "bleed" }
function Player.Label(tag)
	local t = TAG_TO_TYPE[tag]
	if not t then return nil end
	local caps = Player.Caps()
	return caps.labels and caps.labels[t] or nil
end

local CLASS_NAMES = {
	WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest",
	DEATHKNIGHT = "Death Knight", SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", MONK = "Monk",
	DRUID = "Druid", DEMONHUNTER = "Demon Hunter", EVOKER = "Evoker",
}
local function cap(s) return s:sub(1, 1):upper() .. s:sub(2) end

-- "Death Knight" for DEATHKNIGHT; nil for an unknown file name
function Player.ClassName(class)
	return CLASS_NAMES[class or ""]
end
local ROLE_WORD = { tank = "Tank", healer = "Healer", dps = "DPS" }

-- "Restoration Shaman" (or "as Brewmaster Monk" when overridden)
function Player.SpecName()
	local caps = Player.Caps()
	if state.override and state.override.label then
		return "as " .. state.override.label
	end
	return ((caps.name or "") .. " " .. (CLASS_NAMES[Player.Class() or ""] or "")):gsub("^%s+", "")
end

-- "Healer · Ranged"
function Player.RoleLine()
	return (ROLE_WORD[Player.Role()] or cap(Player.Role())) .. " · " .. cap(Player.Range())
end

function Player.Describe()
	return Player.SpecName() .. " · " .. Player.RoleLine()
end

-- /tp notes as <tank|healer|melee|ranged|dps|classname|specname>; empty clears.
function Player.SetOverride(what)
	what = (what or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
	if what == "" then
		state.override = nil
		return "notes override cleared"
	end
	local base = state.caps or {}
	local o = { label = what, caps = base, role = state.role, range = state.range, class = state.class }
	if what == "tank" or what == "healer" or what == "dps" then
		o.role = what
	elseif what == "melee" or what == "ranged" then
		o.range = what
	else
		local found
		for _, row in pairs(KN.CLASSES) do
			local full = (row.name .. " " .. row.class):lower()
			if row.class:lower() == what or row.name:lower() == what or full:find(what, 1, true) then
				if not found or row.name:lower() == what then found = row end
			end
		end
		if not found then return "no role, class or spec called '" .. what .. "'" end
		o.caps, o.role, o.range, o.class = found, found.role, found.range, found.class
		o.label = found.name .. " " .. (CLASS_NAMES[found.class] or found.class)
	end
	state.override = o
	return "showing notes as " .. o.label
end

function Player.DebugLine()
	local caps = Player.Caps()
	local have = {}
	for _, k in ipairs({ "magic", "curse", "poison", "disease", "bleed", "purge", "soothe", "kick", "stun", "lust", "fear", "massdispel" }) do
		if caps[k] then have[#have + 1] = k end
	end
	local r = state.raw or {}
	return string.format("class=%s specID=%s role=%s range=%s can=%s%s"
		.. " | raw: classID=%s idx=%s group=%s idxByGroup=%s infoOK=%s id=%s role=%s byClassID=%s roster=%s%s",
		tostring(state.class), tostring(state.specID), Player.Role(), Player.Range(),
		table.concat(have, ","), state.override and (" override=" .. tostring(state.override.label)) or "",
		tostring(r.classID), tostring(r.idx), tostring(r.group), tostring(r.idxByGroup),
		tostring(r.infoOK), tostring(r.id), tostring(r.role),
		tostring(r.byClassID), tostring(r.roster), r.err and (" err=" .. r.err) or "")
end

-- Own frame: AceEvent allows one handler per event per object, and the
-- roster already owns PLAYER_SPECIALIZATION_CHANGED on the addon object.
local ev = CreateFrame("Frame")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("PLAYER_SPECIALIZATION_CHANGED")
ev:RegisterEvent("ACTIVE_TALENT_GROUP_CHANGED")
-- fires once talent data has actually arrived, which on Classic clients can
-- be after PLAYER_ENTERING_WORLD
pcall(ev.RegisterEvent, ev, "PLAYER_TALENT_UPDATE")
ev:SetScript("OnEvent", function(_, event, unit)
	if event == "PLAYER_SPECIALIZATION_CHANGED" and unit and unit ~= "player" then return end
	Player.Refresh()
	if KN.Tracker and KN.Tracker.Render then KN.Tracker.Render() end
end)
