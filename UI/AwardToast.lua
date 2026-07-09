-- On-screen flash + fanfare when YOU earn an award: a gold star and the
-- award name slide in under the top of the screen, hold, and fade. Only
-- your own awards toast; everyone else's are on the card.
local _, TP = ...

local Toast = {}
TP.AwardToast = Toast

local frame

local function build()
	frame = CreateFrame("Frame", nil, UIParent)
	frame:SetSize(600, 44)
	frame:SetPoint("TOP", 0, -170)
	frame:SetFrameStrata("HIGH")
	frame:Hide()

	frame.text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
	frame.text:SetPoint("CENTER")
	frame.text:SetTextColor(1, 0.82, 0.2)

	local ag = frame:CreateAnimationGroup()
	local fadeIn = ag:CreateAnimation("Alpha")
	fadeIn:SetFromAlpha(0)
	fadeIn:SetToAlpha(1)
	fadeIn:SetDuration(0.25)
	fadeIn:SetOrder(1)
	local hold = ag:CreateAnimation("Alpha")
	hold:SetFromAlpha(1)
	hold:SetToAlpha(1)
	hold:SetDuration(2.6)
	hold:SetOrder(2)
	local fadeOut = ag:CreateAnimation("Alpha")
	fadeOut:SetFromAlpha(1)
	fadeOut:SetToAlpha(0)
	fadeOut:SetDuration(0.9)
	fadeOut:SetOrder(3)
	ag:SetScript("OnFinished", function()
		frame:Hide()
	end)
	frame.anim = ag
end

local function onFightCaptured(_, fight)
	if not TP.Addon.db.profile.toasts then
		return
	end
	local mine = TP.Scoring.Awards.Compute(fight)[UnitGUID("player")]
	if not mine or #mine == 0 then
		return
	end
	if not frame then
		build()
	end
	local parts = {}
	for _, award in ipairs(mine) do
		parts[#parts + 1] = TP.STAR .. " " .. award
	end
	frame.text:SetText(table.concat(parts, "   "))
	frame.anim:Stop()
	frame:Show()
	frame.anim:Play()
	pcall(PlaySound, (SOUNDKIT and SOUNDKIT.UI_EPICLOOT_TOAST) or 31578)
end

function Toast:OnEnable()
	-- Own AceEvent identity (one handler per message per object)
	LibStub("AceEvent-3.0"):Embed(self)
	self:RegisterMessage("TrueParse_FIGHT_CAPTURED", onFightCaptured)
end
