-- One tooltip style for every TrueParse hover: the same solid dark card
-- the gauge tooltip uses. Replaces the mix of GameTooltip and custom
-- frames that made hovers look like two different addons.
local _, TP = ...

local Tooltip = {}
TP.Tooltip = Tooltip

local WIDTH = 220
local INSET = 10
local CHIP_W, CHIP_H = 24, 13 -- matches the meter header's tier chip
-- EXPLICIT text widths, not anchor-derived (Josh 2026-07-28, second report
-- of the first-hover bug). A FontString whose width comes from a chain of
-- anchors cannot compute its wrapped height until that chain is resolved,
-- and on the very first Show it is not — so GetStringHeight returns the
-- SINGLE-LINE height, the accumulated card height comes up several lines
-- short, and the legend spills out of the backdrop. Given a width outright,
-- wrapping is computable immediately and the first hover measures like every
-- one after it.
local TEXT_W = WIDTH - INSET * 2
local CHIP_TEXT_W = TEXT_W - CHIP_W - 7
local tip
local lines = {}
local chips = {}
local rules = {}

local function build()
	tip = CreateFrame("Frame", "TrueParseTooltip", UIParent, "BackdropTemplate")
	tip:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	tip:SetBackdropColor(0.04, 0.04, 0.05, 1)
	tip:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	tip:SetWidth(WIDTH)
	tip:SetClampedToScreen(true)
	tip:SetFrameStrata("TOOLTIP")
	tip.title = tip:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	tip.title:SetPoint("TOPLEFT", INSET, -8)
	tip.title:SetWidth(TEXT_W)
	tip.title:SetJustifyH("LEFT")
	tip:Hide()
end

local function lineFS(i)
	local fs = lines[i]
	if not fs then
		fs = tip:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		fs:SetJustifyH("LEFT")
		-- long lines (award descriptions) WRAP, never ellipsize (Josh
		-- 2026-07-24): explicit, because template defaults clipped
		fs:SetWordWrap(true)
		fs:SetMaxLines(0)
		-- remembered so a per-line size override can always be undone: these
		-- FontStrings are POOLED across every tooltip in the addon, so a size
		-- set for one hover would otherwise leak into the next one
		fs.baseFont, fs.baseSize, fs.baseFlags = fs:GetFont()
		lines[i] = fs
	end
	return fs
end

-- A legend row's chip: the same filled plate the meter header wears, so a
-- tier looks identical wherever it appears. Fixed width, so every label to
-- the right of one lines up.
local function chipFrame(i)
	local c = chips[i]
	if not c then
		c = CreateFrame("Frame", nil, tip)
		c:SetSize(CHIP_W, CHIP_H)
		c.bg = c:CreateTexture(nil, "BACKGROUND")
		c.bg:SetAllPoints()
		c.edges = {}
		for e = 1, 4 do
			local t = c:CreateTexture(nil, "BORDER")
			if e == 1 then
				t:SetPoint("TOPLEFT"); t:SetPoint("TOPRIGHT"); t:SetHeight(1)
			elseif e == 2 then
				t:SetPoint("BOTTOMLEFT"); t:SetPoint("BOTTOMRIGHT"); t:SetHeight(1)
			elseif e == 3 then
				t:SetPoint("TOPLEFT"); t:SetPoint("BOTTOMLEFT"); t:SetWidth(1)
			else
				t:SetPoint("TOPRIGHT"); t:SetPoint("BOTTOMRIGHT"); t:SetWidth(1)
			end
			c.edges[e] = t
		end
		c.label = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		local f = c.label:GetFont()
		c.label:SetFont(f, 9, "")
		c.label:SetPoint("CENTER", 0, 0)
		chips[i] = c
	end
	return c
end

-- hairline between the "about this tier" half and the legend half
local function ruleTex(i)
	local r = rules[i]
	if not r then
		r = tip:CreateTexture(nil, "ARTWORK")
		r:SetHeight(1)
		r:SetColorTexture(1, 1, 1, 0.10)
		rules[i] = r
	end
	return r
end

-- owner: frame to anchor to. anchor: "TOP" (above the owner), "RIGHT"
-- (beside it, flipping to whichever side has screen room), or
-- "FORCE_LEFT"/"FORCE_RIGHT" (a fixed side — the breakdown panel uses
-- these so its tooltips never flip and never cover the meter window).
-- data: array of { text, r, g, b } lines; text wraps to the card width.
-- A line may also carry a NAMED `size` field ({ text, r, g, b, size = 13 })
-- to override the point size — the house pattern is a summary at 13 over a
-- detail at the default. Index 5 is NOT it: legacy callers pass a stray
-- `true` there and it is ignored.
function Tooltip:Show(owner, anchor, title, data)
	if not tip then
		build()
	end
	-- Anchor and SHOW before measuring anything. GetStringHeight on a
	-- hidden, unanchored frame's FontString has no resolved width to wrap
	-- against, so it reports the single-line height and every line lands on
	-- top of the one above it — the classic "first hover after a reload is
	-- garbled, every hover after is fine" (Josh 2026-07-28).
	tip:ClearAllPoints()
	if anchor == "TOP" then
		tip:SetPoint("BOTTOM", owner, "TOP", 0, 6)
	elseif anchor == "FORCE_LEFT" then
		tip:SetPoint("RIGHT", owner, "LEFT", -14, 0)
	elseif anchor == "FORCE_RIGHT" then
		tip:SetPoint("LEFT", owner, "RIGHT", 14, 0)
	elseif (owner:GetRight() or 0) + WIDTH + 12 <= UIParent:GetWidth() then
		tip:SetPoint("LEFT", owner, "RIGHT", 8, 0)
	else
		tip:SetPoint("RIGHT", owner, "LEFT", -8, 0)
	end
	tip:Show()

	tip.title:SetText(title or "")
	-- Each line hangs off the PREVIOUS one rather than a running y total, so
	-- a bad measurement can never stack two lines in the same place — the
	-- worst case is a backdrop an few pixels short, not unreadable text.
	-- Each row hangs off the PREVIOUS one rather than a running y total, so a
	-- bad measurement can never stack two rows in the same place — the worst
	-- case is a backdrop a few pixels short, not unreadable text. Height is
	-- accumulated as we go, because a chip row is a fixed height rather than
	-- whatever its label measures.
	local prev, shown = tip.title, 0
	local usedChips, usedRules = 0, 0
	local h = 8 + tip.title:GetStringHeight() + 4
	for _, line in ipairs(data or {}) do
		shown = shown + 1
		local fs = lineFS(shown)
		local gap = ((prev == tip.title) and -4 or -3) - (line.gapBefore or 0)
		h = h + (line.gapBefore or 0)

		-- optional hairline above this row, separating two zones of the card
		if line.rule then
			usedRules = usedRules + 1
			local r = ruleTex(usedRules)
			r:ClearAllPoints()
			r:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, gap)
			r:SetWidth(TEXT_W)
			r:Show()
			prev, gap = r, -6
			h = h + 7
		end

		if fs.baseFont then
			-- line.size = optional point size, so a card can lead with a
			-- summary and drop to detail underneath it. NAMED, not index 5:
			-- legacy callers pass a vestigial `true` there (a wrap flag from
			-- the GameTooltip:AddLine signature this tooltip never read) and
			-- SetFont choked on it. Reset unconditionally — pooled, see lineFS.
			local size = type(line.size) == "number" and line.size or fs.baseSize
			fs:SetFont(fs.baseFont, size, fs.baseFlags)
		end
		fs:SetText(line[1] or "")
		fs:ClearAllPoints()

		if line.chip then
			-- Chip at the left, label centred beside it. Fixed chip width is
			-- what makes the numerals stack in a column and every label start
			-- on the same x (Josh 2026-07-28).
			usedChips = usedChips + 1
			local c = chipFrame(usedChips)
			c:ClearAllPoints()
			c:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, gap)
			c:Show()
			c.label:SetText(line.chip)
			local r, g, b = line[2] or 1, line[3] or 1, line[4] or 1
			if line.active then
				-- identical treatment to the meter header's chip, so a tier
				-- looks the same wherever it shows up
				c.bg:SetColorTexture(r, g, b, 0.26)
				for _, e in ipairs(c.edges) do
					e:SetColorTexture(r, g, b, 0.85)
				end
				c.label:SetTextColor(r, g, b)
				fs:SetTextColor(r, g, b)
			else
				-- grey plate: the legend reads as "you are here" rather than
				-- three colours competing for the same attention
				c.bg:SetColorTexture(0.55, 0.55, 0.58, 0.10)
				for _, e in ipairs(c.edges) do
					e:SetColorTexture(0.55, 0.55, 0.58, 0.35)
				end
				c.label:SetTextColor(0.6, 0.6, 0.63)
				fs:SetTextColor(0.58, 0.58, 0.61)
			end
			fs:SetPoint("LEFT", c, "RIGHT", 7, 0)
			fs:SetWidth(CHIP_TEXT_W)
			prev = c
			h = h + CHIP_H + 3
		else
			fs:SetPoint("TOPLEFT", prev, "BOTTOMLEFT", 0, gap)
			fs:SetWidth(TEXT_W)
			fs:SetTextColor(line[2] or 1, line[3] or 1, line[4] or 1)
			prev = fs
			h = h + fs:GetStringHeight() + 3
		end
		fs:Show()
	end
	for i = shown + 1, #lines do
		lines[i]:Hide()
	end
	for i = usedChips + 1, #chips do
		chips[i]:Hide()
	end
	for i = usedRules + 1, #rules do
		rules[i]:Hide()
	end

	tip:SetHeight(h + 7)
end

function Tooltip:Hide()
	if tip then
		tip:Hide()
	end
end
