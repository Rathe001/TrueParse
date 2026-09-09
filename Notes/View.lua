-- The Notes view: lays a list of row descriptors into a rectangle of the
-- meter window from pooled frames. The window owns the frame, the drag, the
-- backdrop and the saved size; this file only knows how each row looks.
-- Look: canvas round 5 (Josh 2026-09-08). One grid for every row, gold for
-- bosses only, small-caps section headings with a hairline, alternating
-- shade on list rows.
--
-- Row descriptors (built by Notes\Tracker.lua):
--   { type="header",  name=, diff=, level=, spec=, role=, affixes={ {icon=, rgb=, name=, short=} } }
--   { type="section", label=, name=, pre=|nil }         -- [NEXT] Name ....... BOSS 1 OF 4
--   { type="section", label=, text=, right=|nil }       -- TRASH to Kystia ....... 1 OF 4
--   { type="core",    num=, text= }                     -- numeral in the narrow column
--   { type="subhead", label=, icon=, text=|nil }        -- spec icon + name in small caps, no rule
--   { type="yours",   text=, tag= }                     -- one sentence, indented like core text
--   { type="task",    text=, icon= }                    -- objective callout across the row
--   { type="note",    text=, icon=, label=, rgb= }      -- label column + text
--   { type="mob",     name=, text=, icon=, label=, rgb= }  -- name column + tool chip + text
--
-- Canvas round 6 (Josh 2026-09-09, "option B, the ledger"): mob names in
-- an 84px column with the tool as a bordered chip; objectives as a callout
-- band; the boss heading with a small NEXT before the name; numerals and
-- the lines that are yours share one 18px column, right-aligned, so every
-- line of boss text starts at the same x.
local _, TP = ...
local KN = TP.Notes

local View = {}
KN.View = View

local RGB, FONT = KN.RGB, KN.FONT
local LABEL_COL = 84    -- mob name column (100 was more than any name needs)
local NUM_COL = 18      -- numeral / your-icon column under a boss
local NUM_GAP = 6
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

-- A 1px hairline box around a frame, from four colour textures: the strict
-- widget stub and every client draw these the same, unlike backdrops.
local function hairlineBox(f, rgb, alpha)
	f.edges = {}
	for i, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
		local t = f:CreateTexture(nil, "BORDER")
		t:SetColorTexture(rgb[1], rgb[2], rgb[3], alpha)
		if side == "TOP" or side == "BOTTOM" then
			t:SetHeight(1)
			t:SetPoint(side .. "LEFT", 0, 0)
			t:SetPoint(side .. "RIGHT", 0, 0)
		else
			t:SetWidth(1)
			t:SetPoint("TOP" .. side, 0, 0)
			t:SetPoint("BOTTOM" .. side, 0, 0)
		end
		f.edges[i] = t
	end
end

local builders = {}

-- Dungeon band: name, difficulty or key pill; then the affix summary line
-- (what this week does to bosses and trash), which is the only place the
-- numbers live. `spec` and `role` still arrive in the descriptor for the
-- tests and the debug line, and are not drawn.
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
		-- No spec/role line (Josh 2026-09-09): the band is the dungeon, the
		-- difficulty, and what this difficulty does to the enemies. Who you
		-- are is answered by the lines themselves, and by /tp notes spec.
		-- Enemy Forces sits where that line was, keystones only.
		r.forces = newText(r, FONT.body, 11, RGB.dim)
		r.forces:SetWordWrap(false)
		r.forces:SetJustifyH("RIGHT")
		r.forces:SetPoint("TOPRIGHT", 0, -8)
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
		if d.forces then
			-- the game rounds the same way on its own tracker
			r.forces:SetText("Forces " .. KN.Hex(RGB.accent) .. string.format("%d%%", math.floor(d.forces + 0.5)) .. "|r")
			r.forces:SetWidth(math.max(50, width - r.name:GetWidth() - r.pill:GetWidth() - 20))
			r.forces:Show()
		else
			r.forces:SetText("")
			r.forces:Hide()
		end
		local h = 25
		if d.affixes and #d.affixes > 0 then
			local parts = {}
			for _, a in ipairs(d.affixes) do
				local icon = a.icon and ("|T" .. tostring(a.icon) .. ":12:12:0:0|t ") or ""
				parts[#parts + 1] = icon .. KN.Hex(a.rgb or RGB.dim) .. a.name .. "|r " .. (a.short or "")
			end
			r.affix:SetWidth(width)
			-- one affix per line (Josh 2026-09-09): three effects run
			-- together read as one sentence
			r.affix:SetText(table.concat(parts, "\n"))
			r.affix:Show()
			h = h + r.affix:GetStringHeight() + 2
		else
			r.affix:SetText("")
			r.affix:Hide()
		end
		return h + 6
	end,
}

-- Two shapes on one hairline. A boss heading: a small NEXT (on a stretch)
-- before the name in the display face, "BOSS 1 OF 4" small-caps at the
-- right. A stretch heading: TRASH, the stretch text, "1 OF 4" at the right.
builders.section = {
	create = function(parent)
		local r = CreateFrame("Frame", nil, parent)
		local function small(fs)
			fs:SetWordWrap(false)
			return fs
		end
		r.label = small(newText(r, FONT.body, 10, RGB.dim))
		r.pre = small(newText(r, FONT.body, 10, RGB.dim))
		r.right = small(newText(r, FONT.body, 10, RGB.dim))
		r.right:SetJustifyH("RIGHT")
		r.name = small(newText(r, FONT.head, 14, RGB.gold))
		r.text = small(newText(r, FONT.body, 12, RGB.accent))
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
		r.label:ClearAllPoints()
		r.name:ClearAllPoints()
		r.pre:ClearAllPoints()
		r.right:ClearAllPoints()
		if d.name then
			local preW = 0
			if d.pre then
				r.pre:SetText(d.pre:upper())
				r.pre:SetWidth(r.pre:GetStringWidth() + 2)
				r.pre:SetPoint("BOTTOMLEFT", 0, 5)
				r.pre:Show()
				preW = r.pre:GetStringWidth() + 8
				r.name:SetPoint("BOTTOMLEFT", preW, 4)
			else
				r.pre:Hide()
				r.name:SetPoint("BOTTOMLEFT", 0, 4)
			end
			r.name:SetText(d.name)
			r.label:SetPoint("BOTTOMRIGHT", 0, 5)
			r.label:SetJustifyH("RIGHT")
			r.name:SetWidth(math.max(40, width - preW - r.label:GetStringWidth() - 10))
			r.name:Show()
			r.text:Hide()
			r.right:Hide()
			return 21
		end
		r.pre:Hide()
		r.name:Hide()
		r.label:SetPoint("BOTTOMLEFT", 0, 4)
		r.label:SetJustifyH("LEFT")
		local rightW = 0
		if d.right then
			r.right:SetText(d.right:upper())
			r.right:SetWidth(r.right:GetStringWidth() + 2)
			r.right:SetPoint("BOTTOMRIGHT", 0, 4)
			r.right:Show()
			rightW = r.right:GetStringWidth() + 8
		else
			r.right:Hide()
		end
		r.text:SetText(d.text or "")
		r.text:SetPoint("BOTTOMLEFT", r.label, "BOTTOMRIGHT", 8, 0)
		r.text:SetWidth(math.max(20, width - r.label:GetStringWidth() - rightW - 10))
		r.text:Show()
		return 19
	end,
}

-- Numbered core line: gold numeral right-aligned in the narrow column,
-- bright text after it.
builders.core = {
	create = function(parent)
		local r = CreateFrame("Frame", nil, parent)
		r.num = newText(r, FONT.head, 13, RGB.gold)
		r.num:SetPoint("TOPLEFT", 4, 0)
		r.num:SetWidth(NUM_COL)
		r.num:SetJustifyH("RIGHT")
		r.fs = newText(r, FONT.body, 13, RGB.bright)
		r.fs:SetPoint("TOPLEFT", 4 + NUM_COL + NUM_GAP, 0)
		return r
	end,
	set = function(r, d, width)
		r.num:SetText(tostring(d.num or ""))
		r.fs:SetWidth(width - 4 - NUM_COL - NUM_GAP - 4)
		r.fs:SetText(d.text or "")
		local h = r.fs:GetStringHeight()
		if h < 15 then h = 15 end
		return h + 1
	end,
}

-- The tertiary heading over the lines that are yours: your spec's icon
-- at the left, then its name in small caps, dim. No hairline, so it reads
-- as part of the boss block rather than a section of its own (Josh
-- 2026-09-09). A journal source is named beside it.
local SUB_ICON = 12
builders.subhead = {
	create = function(parent)
		local r = CreateFrame("Frame", nil, parent)
		r.icon = r:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(SUB_ICON, SUB_ICON)
		r.icon:SetPoint("LEFT", 4, 0)
		r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		r.label = newText(r, FONT.body, 10, RGB.dim)
		r.label:SetWordWrap(false)
		r.text = newText(r, FONT.body, 10, RGB.dim)
		r.text:SetWordWrap(false)
		return r
	end,
	set = function(r, d, width)
		-- the icon sits in the numeral column and the name starts where the
		-- line items' text starts, so the block shares one left edge (Josh
		-- 2026-09-09)
		local x = 4 + NUM_COL + NUM_GAP
		if d.icon then
			r.icon:SetTexture(d.icon)
			r.icon:ClearAllPoints()
			r.icon:SetPoint("LEFT", 4 + NUM_COL - SUB_ICON, 0)
			r.icon:Show()
		else
			r.icon:Hide()
		end
		r.label:ClearAllPoints()
		r.label:SetPoint("LEFT", x, 0)
		r.label:SetText((d.label or ""):upper())
		r.label:SetWidth(math.min(width - x, r.label:GetStringWidth() + 2))
		r.text:ClearAllPoints()
		r.text:SetPoint("LEFT", r.label, "RIGHT", 8, 0)
		r.text:SetText(d.text and ("· " .. d.text) or "")
		r.text:SetShown(d.text ~= nil)
		return 16
	end,
}

-- A line that is yours: a bullet in the numeral column, right-aligned
-- like the numerals, then one sentence on the same left edge as the core
-- lines' text, under the subheading that names your spec.
builders.yours = {
	create = function(parent)
		local r = CreateFrame("Frame", nil, parent)
		r.bullet = newText(r, FONT.body, 12, RGB.accent)
		r.bullet:SetPoint("TOPLEFT", 4, -ROW_PAD)
		r.bullet:SetWidth(NUM_COL)
		r.bullet:SetJustifyH("RIGHT")
		r.bullet:SetText("\226\128\162") -- a bullet, in UTF-8
		r.fs = newText(r, FONT.body, 12, RGB.ink)
		r.fs:SetPoint("TOPLEFT", 4 + NUM_COL + NUM_GAP, -ROW_PAD)
		return r
	end,
	set = function(r, d, width)
		r.fs:SetWidth(width - 4 - NUM_COL - NUM_GAP - 4)
		r.fs:SetText(d.text or "")
		return math.max(r.fs:GetStringHeight(), 12) + ROW_PAD * 2
	end,
}

-- An objective: a callout across the row on a faint tint with a hairline
-- box, the map icon and the text. Not a table row, because "Objective"
-- in a label column said nothing the icon does not.
builders.task = {
	create = function(parent)
		local r = CreateFrame("Frame", nil, parent)
		r.bg = r:CreateTexture(nil, "BACKGROUND")
		r.bg:SetColorTexture(RGB.accent[1], RGB.accent[2], RGB.accent[3], 0.07)
		r.bg:SetAllPoints()
		hairlineBox(r, RGB.accent, 0.14)
		r.icon = r:CreateTexture(nil, "ARTWORK")
		r.icon:SetSize(ICON, ICON)
		r.icon:SetPoint("TOPLEFT", 8, -5)
		r.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
		r.fs = newText(r, FONT.body, 12, RGB.bright)
		r.fs:SetPoint("TOPLEFT", 8 + ICON + 8, -5)
		return r
	end,
	set = function(r, d, width)
		r.icon:SetTexture(d.icon or KN.ICONS.TASK)
		r.fs:SetWidth(width - 8 - ICON - 8 - 8)
		r.fs:SetText(d.text or "")
		return math.max(r.fs:GetStringHeight(), ICON) + 10
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

-- A mob row: the name in the label column, then the text. The tool's verb
-- is already folded into the text by the tracker ("Kick Healing Breeze,
-- every cast"); an inline icon and word before it was one thing too many
-- (Josh 2026-09-09).
builders.mob = {
	create = newListRow,
	set = function(r, d, width)
		return setListRow(r, d, width, d.name, RGB.accent, "")
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
			elseif d.type == "subhead" then
				pad = (lastType == "core") and 8 or 4
			elseif d.type == "yours" then
				pad = (lastType == "subhead") and 3 or 2
			elseif d.type == "task" then
				pad = (lastType == "section") and 6 or 4
			elseif d.type == "note" or d.type == "mob" then
				pad = (lastType == "section" or lastType == "task") and 4 or 0
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
