-- The reports panel (Josh 2026-07-25): a chat icon on the meter opens
-- a scrollable list of shareable reports. Each row = name, what it
-- says, an example line, a channel picker (Info default - your chat
-- only), Run with a confirmation, and (for triggerable reports) an
-- auto-run checkbox that is ALWAYS local-only — auto never posts to
-- a channel, because spam bad.
local _, TP = ...

local ReportsUI = {}
TP.ReportsUI = ReportsUI

local WIDTH, HEIGHT = 480, 400
local PAD = 10

local CHANNELS = {
	{ key = "INFO", label = "Info" },
	{ key = "SAY", label = "Say" },
	{ key = "PARTY", label = "Party" },
	{ key = "RAID", label = "Raid" },
	{ key = "GUILD", label = "Guild" },
}
local CHANNEL_LABELS = {}
for _, c in ipairs(CHANNELS) do
	CHANNEL_LABELS[c.key] = c.label
end

local function conf(key)
	local reports = TP.Addon.db.profile.reports
	local c = reports[key]
	if not c then
		c = { channel = "INFO", auto = false }
		reports[key] = c
	end
	return c
end

-- ===== context assembly: what fight/run does a report read? =====

local function latestFight(pred)
	for _, f in ipairs(TP.FightHistory and TP.FightHistory.fights or {}) do
		if not pred or pred(f) then
			return f
		end
	end
end

-- all fights sharing a runID (the anchor fight's whole visit)
local function fightsOfRun(runID)
	if not runID then
		return nil
	end
	local out = {}
	for _, f in ipairs(TP.FightHistory and TP.FightHistory.fights or {}) do
		if f.runID == runID then
			out[#out + 1] = f
		end
	end
	return #out > 0 and out or nil
end

-- what the meter's fight selector has pinned (nil = Current)
local function selectedFight()
	local mw = TP.MeterWindow
	return mw and mw.SelectedFight and mw:SelectedFight() or nil
end

-- Manual reports run on the SELECTED encounter (Josh 2026-07-25), not
-- just the newest capture: deaths/prep take the pinned fight as-is;
-- wipe/kill reports take it when it matches, else the same boss's
-- latest matching pull; the run report takes the pinned fight's whole
-- visit. Auto-runs pass the freshly captured fight instead.
local function contextFor(def, fight)
	local ctx = {}
	local sel = fight or selectedFight()
	if def.key == "run" then
		local anchor = sel or latestFight()
		ctx.runFights = anchor and fightsOfRun(anchor.runID)
		ctx.zone = anchor and anchor.zone
		if ctx.runFights and #ctx.runFights > 0 then
			local run = TP.Scoring.Runs.Aggregate(ctx.runFights, ctx.zone or "Run")
			local ok, results = pcall(TP.Scoring.Engine.ScoreFight, run, { normalizeIlvl = false })
			ctx.results = ok and results or nil
		end
		return ctx
	end
	if def.trigger == "wipe" then
		if sel and sel.isBoss and sel.wipe then
			ctx.fight = sel
		elseif sel and sel.isBoss then
			ctx.fight = latestFight(function(f)
				return f.isBoss and f.wipe and f.name == sel.name
			end)
		else
			ctx.fight = latestFight(function(f)
				return f.isBoss and f.wipe
			end)
		end
	elseif def.trigger == "kill" then
		if sel and sel.isBoss and not sel.wipe then
			ctx.fight = sel
		elseif sel and sel.isBoss then
			ctx.fight = latestFight(function(f)
				return f.isBoss and not f.wipe and f.name == sel.name
			end)
		else
			ctx.fight = latestFight(function(f)
				return f.isBoss and not f.wipe
			end)
		end
	else
		ctx.fight = sel or latestFight()
	end
	if ctx.fight then
		ctx.runFights = fightsOfRun(ctx.fight.runID)
		local ok, results = pcall(TP.Scoring.Engine.ScoreFight, ctx.fight, {})
		ctx.results = ok and results or nil
	end
	return ctx
end

-- ===== delivery =====

local function info(line)
	DEFAULT_CHAT_FRAME:AddMessage("|cff33ff99TrueParse|r: " .. line)
end

local function deliver(lines, channel)
	if channel == "INFO" then
		for _, line in ipairs(lines) do
			info(line)
		end
		return
	end
	if (channel == "RAID" and not IsInRaid())
		or (channel == "PARTY" and not IsInGroup())
		or (channel == "GUILD" and not IsInGuild()) then
		info(("Not in a %s - report shown here instead."):format(CHANNEL_LABELS[channel]:lower()))
		deliver(lines, "INFO")
		return
	end
	for _, line in ipairs(lines) do
		SendChatMessage(line, channel)
	end
end

local function runReport(def, channel, fight)
	local lines = TP.Scoring.Reports.Run(def.key, contextFor(def, fight))
	if not lines then
		info(("Nothing to report yet for %s."):format(def.name))
		return
	end
	deliver(lines, channel)
end

StaticPopupDialogs["TRUEPARSE_SEND_REPORT"] = {
	text = "Send %s to %s?",
	button1 = YES,
	button2 = NO,
	OnAccept = function(self, data)
		runReport(data.def, data.channel)
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3, -- avoid tainting the default popup slots
}

-- ===== the window =====

local frame
local channelMenu

local function ensureChannelMenu()
	if channelMenu then
		return channelMenu
	end
	channelMenu = CreateFrame("Frame", nil, frame, "BackdropTemplate")
	channelMenu:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	channelMenu:SetBackdropColor(0.05, 0.05, 0.06, 0.98)
	channelMenu:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	channelMenu:SetSize(90, #CHANNELS * 17 + 6)
	channelMenu:SetFrameStrata("DIALOG")
	channelMenu.items = {}
	for i, c in ipairs(CHANNELS) do
		local b = CreateFrame("Button", nil, channelMenu)
		b:SetSize(84, 16)
		b:SetPoint("TOPLEFT", 3, -3 - (i - 1) * 17)
		b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
		b.text:SetPoint("LEFT", 6, 0)
		b.text:SetText(c.label)
		b:SetHighlightTexture("Interface\\Buttons\\WHITE8X8")
		b:GetHighlightTexture():SetVertexColor(1, 1, 1, 0.08)
		b:SetScript("OnClick", function()
			if channelMenu.onPick then
				channelMenu.onPick(c.key)
			end
			channelMenu:Hide()
		end)
		channelMenu.items[i] = b
	end
	channelMenu:Hide()
	return channelMenu
end

local function makeRow(parent, def)
	local row = CreateFrame("Frame", nil, parent)
	row:SetWidth(WIDTH - 2 * PAD - 20)

	row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	row.name:SetPoint("TOPLEFT", 0, 0)
	row.name:SetText(def.name)

	local textW = row:GetWidth() - 150
	row.desc = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.desc:SetPoint("TOPLEFT", 0, -16)
	row.desc:SetWidth(textW)
	row.desc:SetJustifyH("LEFT")
	row.desc:SetWordWrap(true)
	row.desc:SetText(def.desc)
	row.desc:SetTextColor(0.75, 0.75, 0.75)

	row.example = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	row.example:SetPoint("TOPLEFT", 0, -16 - row.desc:GetStringHeight() - 4)
	row.example:SetWidth(textW)
	row.example:SetJustifyH("LEFT")
	row.example:SetWordWrap(true)
	row.example:SetText('"' .. def.example .. '"')

	-- right-side controls: channel picker over the Run button
	local c = conf(def.key)
	row.channel = CreateFrame("Button", nil, row, "BackdropTemplate")
	row.channel:SetSize(88, 18)
	row.channel:SetPoint("TOPRIGHT", 0, -1)
	row.channel:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	row.channel:SetBackdropColor(0, 0, 0, 0.55)
	row.channel:SetBackdropBorderColor(0.38, 0.38, 0.38, 0.9)
	row.channel.text = row.channel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	row.channel.text:SetPoint("LEFT", 6, 0)
	row.channel.text:SetText(CHANNEL_LABELS[c.channel] or "Info")
	row.channel.arrow = row.channel:CreateTexture(nil, "OVERLAY")
	row.channel.arrow:SetSize(14, 14)
	row.channel.arrow:SetPoint("RIGHT", -1, 0)
	row.channel.arrow:SetTexture("Interface\\Buttons\\UI-ScrollBar-ScrollDownButton-Up")
	row.channel:SetScript("OnClick", function(self)
		local menu = ensureChannelMenu()
		if menu:IsShown() and menu.owner == self then
			menu:Hide()
			return
		end
		menu.owner = self
		menu.onPick = function(key)
			conf(def.key).channel = key
			self.text:SetText(CHANNEL_LABELS[key])
		end
		menu:ClearAllPoints()
		menu:SetPoint("TOPRIGHT", self, "BOTTOMRIGHT", 0, -1)
		menu:Show()
	end)

	row.run = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
	row.run:SetSize(88, 18)
	row.run:SetPoint("TOPRIGHT", 0, -22)
	row.run:SetText("Run")
	row.run:SetScript("OnClick", function()
		local ch = conf(def.key).channel or "INFO"
		local dialog = StaticPopup_Show("TRUEPARSE_SEND_REPORT", def.name,
			ch == "INFO" and "your chat (Info)" or CHANNEL_LABELS[ch])
		if dialog then
			dialog.data = { def = def, channel = ch }
		end
	end)

	if def.trigger then
		row.auto = CreateFrame("CheckButton", nil, row, "UICheckButtonTemplate")
		row.auto:SetSize(20, 20)
		row.auto:SetPoint("TOPRIGHT", -68, -42)
		row.auto:SetChecked(c.auto)
		row.autoLabel = row:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
		row.autoLabel:SetPoint("LEFT", row.auto, "RIGHT", 0, 0)
		row.autoLabel:SetText("Auto (local)")
		row.auto:SetScript("OnClick", function(self)
			conf(def.key).auto = self:GetChecked() and true or false
		end)
		row.auto:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(def.name, 1, 1, 1)
			GameTooltip:AddLine(("Runs automatically after each %s - always to your own chat only, never to a channel."):format(
				def.trigger == "runEnd" and "run" or def.trigger), 0.8, 0.8, 0.8, true)
			GameTooltip:Show()
		end)
		row.auto:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
	end

	local textBottom = 16 + row.desc:GetStringHeight() + 4 + row.example:GetStringHeight()
	row:SetHeight(math.max(textBottom, def.trigger and 62 or 44) + 12)
	return row
end

local function createFrame()
	frame = CreateFrame("Frame", "TrueParseReports", UIParent, "BackdropTemplate")
	frame:SetSize(WIDTH, HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetBackdrop({
		bgFile = "Interface\\Buttons\\WHITE8X8",
		edgeFile = "Interface\\Buttons\\WHITE8X8",
		edgeSize = 1,
	})
	frame:SetBackdropColor(0.04, 0.04, 0.05, 1)
	frame:SetBackdropBorderColor(0.4, 0.4, 0.4, 0.9)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("HIGH")
	tinsert(UISpecialFrames, "TrueParseReports") -- ESC closes

	frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	frame.title:SetPoint("TOPLEFT", PAD, -PAD)
	frame.title:SetText("TrueParse Reports")

	frame.close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
	frame.close:SetPoint("TOPRIGHT", 2, 2)
	frame.close:SetSize(24, 24)

	frame.sub = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
	frame.sub:SetPoint("TOPLEFT", PAD, -26)
	frame.sub:SetText("Info posts to your chat only. Auto-run is always local.")

	frame.scroll = CreateFrame("ScrollFrame", "TrueParseReportsScroll", frame, "UIPanelScrollFrameTemplate")
	frame.scroll:SetPoint("TOPLEFT", PAD, -44)
	frame.scroll:SetPoint("BOTTOMRIGHT", -28, PAD)

	frame.content = CreateFrame("Frame", nil, frame.scroll)
	frame.content:SetWidth(WIDTH - 2 * PAD - 20)
	frame.scroll:SetScrollChild(frame.content)

	local y = 0
	for i, def in ipairs(TP.Scoring.Reports.LIST) do
		local row = makeRow(frame.content, def)
		row:SetPoint("TOPLEFT", 0, -y)
		y = y + row:GetHeight()
		if i < #TP.Scoring.Reports.LIST then
			local rule = frame.content:CreateTexture(nil, "ARTWORK")
			rule:SetColorTexture(0.5, 0.5, 0.55, 0.18)
			rule:SetHeight(1)
			rule:SetPoint("TOPLEFT", 0, -y + 6)
			rule:SetPoint("TOPRIGHT", 0, -y + 6)
		end
	end
	frame.content:SetHeight(y + 4)
end

function ReportsUI.Toggle()
	if not frame then
		createFrame()
	elseif frame:IsShown() then
		frame:Hide()
		return
	end
	frame:Show()
end

-- ===== auto-run (always local-only) =====

local function autoRun(trigger, fight)
	for _, def in ipairs(TP.Scoring.Reports.LIST) do
		if def.trigger == trigger and conf(def.key).auto then
			runReport(def, "INFO", fight)
		end
	end
end

function ReportsUI:OnEnable()
	LibStub("AceEvent-3.0"):Embed(self)
	self:RegisterMessage("TrueParse_FIGHT_CAPTURED", function(_, fight)
		if fight and fight.isBoss and not fight.practice then
			autoRun(fight.wipe and "wipe" or "kill", fight)
		end
	end)
	-- run end: where the client announces completion (same events the
	-- run summary trusts)
	pcall(self.RegisterEvent, self, "LFG_COMPLETION_REWARD", function()
		autoRun("runEnd")
	end)
	pcall(self.RegisterEvent, self, "CHALLENGE_MODE_COMPLETED", function()
		autoRun("runEnd")
	end)
end
