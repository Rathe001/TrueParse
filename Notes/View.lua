-- The Notes view: lays a list of row descriptors into a rectangle of the
-- meter window from pooled frames. The window owns the frame, the drag, the
-- backdrop and the saved size; this file only knows how each row looks.
-- Look: canvas round 5 (Josh 2026-09-08). One grid for every row, gold for
-- bosses only, small-caps section headings with a hairline, alternating
-- shade on list rows.
--
-- Row descriptors (built by Notes\Tracker.lua):
--   { type="header",  name=, diff=, level=, spec=, role=, affixes={ {icon=, rgb=, name=, short=} } }
--   { type="section", label=, name=|nil, text=|nil }   -- "TRASH" + text, "NEXT · BOSS 1 OF 4" + name
--   { type="core",    num=, text= }
--   { type="note",    text=, icon=, label=, rgb= }     -- label column + text
--   { type="mob",     name=, text=, icon=, label=, rgb= }  -- name column + text (tool inline)
local _, TP = ...
local KN = TP.Notes

local View = {}
KN.View = View

local RGB, FONT = KN.RGB, KN.FONT
local LABEL_COL = 100   -- mob name / Objective / Lust / Cooldown column
local COL_GAP = 8
local ROW_PAD = 3       -- inside a list row, above and below the text
local SECTION_GAP = 12  -- above a section heading that follows content
local ICON = 14

local pools = {}
local used = {}
local parentFrame

local function textColor(fs, rgb)
	fs:SetTextColor(rgb[1], rgb[2], rgb[3])
end

local function font(fs, path, size)
	fs:SetFont(path, size, "")
end

-- Arial Narrow with the scorecard's hard 1/-1 shadow (UI/Scorecard.lua),
-- so notes text sits on the same ground as the rows.
local function newText(parent, path, size, rgb)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	font(fs, path, size)
	fs:SetShadowColor(0, 0, 0, 1)
	fs:SetShadowOffset(1, -1)
	fs:SetJustifyH("LEFT")
	fs:SetJustifyV("TOP")
	fs:SetWordWrap(true)
	fs:SetNonSpaceWrap(false)
	textColor(fs, rgb)
	return fs
end

local function inlineIcon(path, size)
	return "|T" .. path .. ":" .. size .. ":" .. size .. ":0:0:64:64:5:59:5:59|t"
end

local builders = {}

-- Dungeon band: name, difficulty or key pill, who you are; affix line.
builders.header = {
	create = function(parent)
		local r = CreateFrame("Frame", nil, parent)
		r.band = r:CreateTexture(nil, "BACKGROUND")
		r.band:SetColorTexture(RGB.band[1], RGB.band[2], RGB.band[3], 1)
		r.band:SetPoint("TOPLEFT", -10, 0)
		r.band:SetPoint("BOTTOMRIGHT", 10, 0)
		r.top = r:CreateTexture(nil, "BORDER")
		r.top:SetColorTexture(RGB.line[1], RGB.line[2], RGB.line[3], 0.95)
		r.top:SetHeight(1)
		r.top:SetPoint("TOPLEFT", r.band, "TOPLEFT", 0, 0)
		r.top:SetPoint("TOPRIGHT", r.band, "TOPRIGHT", 0, 0)
		r.bottom = r:CreateTexture(nil, "BORDER")
		r.bottom:SetColorTexture(RGB.line[1], RGB.line[2], RGB.line[3], 0.95)
		r.bottom:SetHeight(1)
		r.bottom:SetPoint("BOTTOMLEFT", r.band, "BOTTOMLEFT", 0, 0)
		r.bottom:SetPoint("BOTTOMRIGHT", r.band, "BOTTOMRIGHT", 0, 0)
		r.name = newText(r, FONT.head, 15, RGB.ink)
		r.name:SetPoint("TOPLEFT", 0, -6)
		r.name:SetWordWrap(false)
		r.pill = CreateFrame("Frame", nil, r)
		r.pill.bg = r.pill:CreateTexture(nil, "BACKGROUND")
		r.pill.bg:SetAllPoints()
		r.pill.fs = r.pill:CreateFontString(nil, "OVERLAY")
		font(r.pill.fs, FONT.body, 9)
		r.pill.fs:SetPoint("CENTER", 0, 0)
		textColor(r.pill.fs, RGB.bg)
		r.pill:SetHeight(12)
		r.pill:SetPoint("LEFT", r.name, "RIGHT", 8, 0)
		r.who = newText(r, FONT.body, 11, RGB.dim)
		r.who:SetWordWrap(false)
		r.who:SetJustifyH("RIGHT")
		r.who:SetPoint("TOPRIGHT", 0, -8)
		r.affix = newText(r, FONT.body, 11, RGB.accent)
		r.affix:SetPoint("TOPLEFT", 0, -25)
		return r
	end,
	set = function(r, d, width)
		r.name:SetText(d.name or "")
		r.name:SetWidth(math.min(width * 0.55, r.name:GetStringWidth() + 2))
		local dc = KN.DIFF_COLOR[d.diff] or RGB.grey
		r.pill.bg:SetColorTexture(dc[1], dc[2], dc[3], 1)
		r.pill.fs:SetText(d.level and ("+" .. d.level) or (KN.DIFF_LABEL[d.diff] or ""):upper())
		r.pill:SetWidth(r.pill.fs:GetStringWidth() + 10)
		r.who:SetText((d.spec or "") .. " · " .. KN.Hex(RGB.accent) .. (d.role or "") .. "|r")
		-- whatever the name and pill leave, so "DPS · Melee" is not clipped
		r.who:SetWidth(math.max(60, width - r.name:GetWidth() - r.pill:GetWidth() - 20))
		local h = 25
		if d.affixes and #d.affixes > 0 then
			local parts = {}
			for _, a in ipairs(d.affixes) do
				local icon = a.icon and ("|T" .. tostring(a.icon) .. ":12:12:0:0|t ") or ""
				parts[#parts + 1] = icon .. KN.Hex(a.rgb or RGB.dim) .. a.name .. "|r " .. (a.short or "")
			end
			r.affix:SetWidth(width)
			r.affix:SetText(table.concat(parts, "   "))
			r.affix:Show()
			h = h + r.affix:GetStringHeight() + 2
		else
			r.affix:SetText("")
			r.affix:Hide()
		end
		return h + 6
	end,
}

-- Small-caps label, then a boss name in the display face or a plain text,
-- with a hairline underneath.
builders.section = {
	create = function(parent)
		local r = CreateFrame("Frame", nil, parent)
		r.label = newText(r, FONT.body, 10, RGB.dim)
		r.label:SetWordWrap(false)
		r.label:SetPoint("BOTTOMLEFT", 0, 4)
		r.name = newText(r, FONT.head, 14, RGB.gold)
		r.name:SetWordWrap(false)
		r.name:SetPoint("BOTTOMLEFT", r.label, "BOTTOMRIGHT", 8, -1)
		r.text = newText(r, FONT.body, 12, RGB.accent)
		r.text:SetWordWrap(false)
		r.text:SetPoint("BOTTOMLEFT", r.label, "BOTTOMRIGHT", 8, 0)
		r.line = r:CreateTexture(nil, "ARTWORK")
		r.line:SetHeight(1)
		r.line:SetColorTexture(0.17, 0.15, 0.25, 1)
		r.line:SetPoint("BOTTOMLEFT", 0, 0)
		r.line:SetPoint("BOTTOMRIGHT", 0, 0)
		return r
	end,
	set = function(r, d, width)
		r.label:SetText((d.label or ""):upper())
		r.label:SetWidth(r.label:GetStringWidth() + 2)
		if d.name then
			-- a boss heading: the name in the display face on the left, the
			-- small-caps "NEXT · BOSS 1 OF 4" right-aligned on the same line
			-- (Josh 2026-09-08, third placement, the one that stuck)
			r.name:ClearAllPoints()
			r.name:SetPoint("BOTTOMLEFT", 0, 4)
			r.name:SetText(d.name)
			r.label:ClearAllPoints()
			r.label:SetPoint("BOTTOMRIGHT", 0, 5)
			r.label:SetJustifyH("RIGHT")
			r.name:SetWidth(math.max(40, width - r.label:GetStringWidth() - 10))
			r.name:Show()
			r.text:Hide()
			return 21
		end
		r.label:ClearAllPoints()
		r.label:SetPoint("BOTTOMLEFT", 0, 4)
		r.label:SetJustifyH("LEFT")
		r.name:Hide()
		r.text:SetText(d.text or "")
		r.text:SetWidth(math.max(20, width - r.label:GetStringWidth() - 10))
		r.text:Show()
		return 19
	end,
}

-- Numbered core line: gold numeral in a 14px column, bright text.
builders.core = {
	create = function(parent)
		local r = CreateFrame("Frame", nil, parent)
		r.num = newText(r, FONT.head, 13, RGB.gold)
		r.num:SetPoint("TOPLEFT", 4, 0)
		r.num:SetWidth(14)
		r.num:SetJustifyH("CENTER")
		r.fs = newText(r, FONT.body, 13, RGB.bright)
		r.fs:SetPoint("TOPLEFT", 4 + 14 + COL_GAP, 0)
		return r
	end,
	set = function(r, d, width)
		r.num:SetText(tostring(d.num or ""))
		r.fs:SetWidth(width - 4 - 14 - COL_GAP)
		r.fs:SetText(d.text or "")
		local h = r.fs:GetStringHeight()
		if h < 15 then h = 15 end
		return h + 1
	end,
}

-- A list row: [label column][text]. `mob` puts the mob name in the column
-- and any tool inline at the start of the text; `note` puts icon + label in
-- the column. Both take the alternating shade.
local function newListRow(parent)
	local r = CreateFrame("Frame", nil, parent)
	r.shade = r:CreateTexture(nil, "BACKGROUND")
	r.shade:SetColorTexture(1, 1, 1, 0.03)
	r.shade:SetAllPoints()
	r.icon = r:CreateTexture(nil, "ARTWORK")
	r.icon:SetSize(ICON, ICON)
	r.icon:SetPoint("TOPLEFT", 4, -ROW_PAD)
	r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
	r.label = newText(r, FONT.body, 12, RGB.accent)
	r.label:SetPoint("TOPLEFT", 4, -ROW_PAD)
	r.fs = newText(r, FONT.body, 12, RGB.ink)
	r.fs:SetPoint("TOPLEFT", 4 + LABEL_COL + COL_GAP, -ROW_PAD)
	return r
end

local function setListRow(r, d, width, labelText, labelRGB, textPrefix)
	if d.icon and not textPrefix then
		r.icon:SetTexture(d.icon)
		r.icon:Show()
		r.label:ClearAllPoints()
		r.label:SetPoint("TOPLEFT", 4 + ICON + 5, -ROW_PAD)
		r.label:SetWidth(LABEL_COL - ICON - 5)
	else
		r.icon:Hide()
		r.label:ClearAllPoints()
		r.label:SetPoint("TOPLEFT", 4, -ROW_PAD)
		r.label:SetWidth(LABEL_COL)
	end
	r.label:SetText(labelText or "")
	textColor(r.label, labelRGB or RGB.accent)
	r.fs:SetWidth(width - 4 - LABEL_COL - COL_GAP - 4)
	r.fs:SetText((textPrefix or "") .. (d.text or ""))
	r.shade:SetShown(d.shade and true or false)
	local h = math.max(r.fs:GetStringHeight(), r.label:GetStringHeight(), ICON)
	return h + ROW_PAD * 2
end

builders.note = {
	create = newListRow,
	set = function(r, d, width)
		return setListRow(r, d, width, d.label, d.rgb, nil)
	end,
}

builders.mob = {
	create = newListRow,
	set = function(r, d, width)
		local prefix
		if d.icon and d.label then
			prefix = inlineIcon(d.icon, 13) .. " " .. KN.Hex(d.rgb or RGB.dim) .. d.label .. "|r  "
		end
		return setListRow(r, d, width, d.name, RGB.accent, prefix or "")
	end,
}

local function acquire(kind)
	pools[kind] = pools[kind] or {}
	used[kind] = (used[kind] or 0) + 1
	local r = pools[kind][used[kind]]
	if not r then
		r = builders[kind].create(parentFrame)
		pools[kind][used[kind]] = r
	end
	r:Show()
	return r
end

local function releaseUnused()
	for kind, list in pairs(pools) do
		for i = (used[kind] or 0) + 1, #list do
			list[i]:Hide()
		end
	end
end

-- Lays `rows` top to bottom from (x, y) in `parent`, `width` wide. Returns
-- the height used. List rows alternate a shade within each section.
function View:Render(parent, rows, x, y, width)
	if parentFrame and parentFrame ~= parent then
		for _, list in pairs(pools) do for _, r in ipairs(list) do r:SetParent(parent) end end
	end
	parentFrame = parent
	for k in pairs(used) do used[k] = 0 end
	local cursor = 0
	local lastType
	local listIndex = 0
	for _, d in ipairs(rows) do
		local b = builders[d.type]
		if b then
			local pad = 0
			if d.type == "section" then
				pad = (lastType and lastType ~= "header") and SECTION_GAP or 2
				listIndex = 0
			elseif d.type == "core" then
				pad = (lastType == "section") and 5 or 3
			elseif d.type == "note" or d.type == "mob" then
				pad = (lastType == "section") and 4 or 0
				listIndex = listIndex + 1
				d.shade = (listIndex % 2 == 1)
			end
			local r = acquire(d.type)
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - cursor - pad)
			r:SetWidth(width)
			local h = b.set(r, d, width)
			r:SetHeight(h)
			cursor = cursor + pad + h
			lastType = d.type
		end
	end
	releaseUnused()
	return cursor
end

function View:Hide()
	for k in pairs(used) do used[k] = 0 end
	releaseUnused()
end
