-- Settings UI (AceConfig): every slash toggle as a real checkbox, plus
-- report buttons. Open with /tp config, the minimap button, or the
-- standard Interface Options AddOns list.
local _, TP = ...

local Options = {}
TP.Options = Options

local function profile()
	return TP.Addon.db.profile
end

local optionsTable = {
	type = "group",
	name = "TrueParse",
	args = {
		display = {
			type = "group", inline = true, name = "Scorecard", order = 1,
			args = {
				locked = {
					type = "toggle", order = 1, name = "Lock window",
					desc = "Prevent dragging the scorecard window.",
					get = function() return profile().window.locked end,
					set = function(_, v) profile().window.locked = v end,
				},
				clickThrough = {
					type = "toggle", order = 3, name = "Click-through in combat",
					desc = "While fighting, mouse clicks pass through the window to the world behind it. Interaction returns when combat ends.",
					get = function() return profile().window.clickThroughCombat end,
					set = function(_, v) profile().window.clickThroughCombat = v end,
				},
				autoCollapse = {
					type = "toggle", order = 2, name = "Auto-collapse in combat",
					desc = "Fold to the title bar when a fight starts (scores are post-fight by nature) and re-open when the scorecard lands.",
					get = function() return profile().window.autoCollapse end,
					set = function(_, v) profile().window.autoCollapse = v end,
				},
				letterGrades = {
					type = "toggle", order = 5, name = "Letter grades",
					desc = "Show scores as letter tiers (F, D- up to S+) instead of 0-100 numbers. Colors stay the same either way.",
					get = function() return profile().letterGrades end,
					set = function(_, v)
						profile().letterGrades = v
						TP.MeterWindow:Invalidate()
					end,
				},
				toasts = {
					type = "toggle", order = 4, name = "Award toasts",
					desc = "Flash a gold star and a fanfare on your screen when you earn an award.",
					get = function() return profile().toasts end,
					set = function(_, v) profile().toasts = v end,
				},
			},
		},
		-- (Scoring section removed 2026-07-13: the window's own radios
		-- switch the lens, ilvl normalization is simply how scoring works,
		-- and the resizable window replaced the max-rows cap.)
		chat = {
			type = "group", inline = true, name = "Chat", order = 3,
			args = {
				coach = {
					type = "toggle", order = 1, name = "Post-fight coach line",
					desc = "After bosses and long pulls: your grade plus the one change that would have raised it most. Only you see this.",
					get = function() return profile().coach end,
					set = function(_, v) profile().coach = v end,
				},
				practiceDummies = {
					type = "toggle", order = 2.7, name = "Score training dummies",
					desc = "Raider's-dummy sessions of a minute or more get a practice card, scored against Iron Juggernaut's ranked parses (the tier's stand-and-hit fight). Never touches career stats. Target the dummy when you start.",
					hidden = function() return TP.Compat.IS_RETAIL end,
					get = function() return profile().practiceDummies end,
					set = function(_, v) profile().practiceDummies = v end,
				},
				wipeButton = {
					type = "toggle", order = 2.5, name = "\"Wipe it\" button",
					desc = "A red button on the window header during boss fights. One press marks the exact wipe-call moment for every TrueParse in the group - nothing after it counts against anyone. If the raid lead or an assist runs TrueParse, only they see it. Classic only.",
					hidden = function() return TP.Compat.IS_RETAIL end,
					get = function() return profile().wipeButton end,
					set = function(_, v)
						profile().wipeButton = v
						if TP.MeterWindow.UpdateWipeButton then
							TP.MeterWindow:UpdateWipeButton()
						end
					end,
				},
			},
		},
		-- (the old announce/debrief toggles and run/share buttons retired
		-- 2026-07-25: the Reports panel owns every chat output now, with
		-- per-report channels, confirmations, and local-only auto-runs)
		reports = {
			type = "group", inline = true, name = "Reports", order = 4,
			args = {
				open = {
					type = "execute", order = 1, name = "Open reports panel",
					desc = "Shareable fight/run reports: pick a channel, confirm, send. Also on the chat icon in the meter header.",
					func = function()
						if TP.ReportsUI then
							TP.ReportsUI.Toggle()
						end
					end,
				},
				career = {
					type = "execute", order = 2, name = "Career stats",
					desc = "Print your GPA, trend, best fight, and strengths.",
					func = function() TP.Career:PrintSummary() end,
				},
			},
		},
		minimap = {
			type = "toggle", order = 5, name = "Show minimap button",
			get = function() return not profile().minimap.hide end,
			set = function(_, v)
				profile().minimap.hide = not v
				local icon = LibStub("LibDBIcon-1.0", true)
				if icon then
					if v then icon:Show("TrueParse") else icon:Hide("TrueParse") end
				end
			end,
		},
	},
}

function Options.Open()
	LibStub("AceConfigDialog-3.0"):Open("TrueParse")
end

function Options:OnEnable()
	LibStub("AceConfig-3.0"):RegisterOptionsTable("TrueParse", optionsTable)
	LibStub("AceConfigDialog-3.0"):AddToBlizOptions("TrueParse", "TrueParse")
end
