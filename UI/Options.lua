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
				autoCollapse = {
					type = "toggle", order = 2, name = "Auto-collapse in combat",
					desc = TP.Compat.IS_RETAIL
						and "Fold to the title bar while fighting (the client shows no live data mid-fight) and re-open when the scorecard lands."
						or "Fold to the title bar while fighting (hides the live damage bars) and re-open when the scorecard lands.",
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
				announce = {
					type = "toggle", order = 2, name = "Announce run MVP to group",
					desc = "When a dungeon/key completes, post ONE line to group chat with the run MVP and group grade. Off by default; be considerate.",
					get = function() return profile().announce end,
					set = function(_, v) profile().announce = v end,
				},
				announceSummary = {
					type = "toggle", order = 3, name = "Announce group summary",
					desc = "When a run completes, post ONE line: group grade plus the group's biggest strength and what to work on. No individual scores.",
					get = function() return profile().announceSummary end,
					set = function(_, v) profile().announceSummary = v end,
				},
			},
		},
		reports = {
			type = "group", inline = true, name = "Reports", order = 4,
			args = {
				run = {
					type = "execute", order = 1, name = "Run report",
					desc = "Print the current instance run's report card to your chat.",
					func = function() TP.RunSummary:Report() end,
				},
				career = {
					type = "execute", order = 2, name = "Career stats",
					desc = "Print your GPA, trend, best fight, and strengths.",
					func = function() TP.Career:PrintSummary() end,
				},
				share = {
					type = "execute", order = 3, name = "Share to group",
					desc = "Post the one-line group summary (grade + strengths/weaknesses) to group chat right now.",
					func = function() TP.RunSummary:Share() end,
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
