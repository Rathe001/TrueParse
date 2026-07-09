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
					desc = "Fold to the title bar while fighting (retail shows no live data anyway) and re-open when the scorecard lands.",
					get = function() return profile().window.autoCollapse end,
					set = function(_, v) profile().window.autoCollapse = v end,
				},
				toasts = {
					type = "toggle", order = 4, name = "Award toasts",
					desc = "Flash a gold star and a fanfare on your screen when you earn an award.",
					get = function() return profile().toasts end,
					set = function(_, v) profile().toasts = v end,
				},
				maxRows = {
					type = "range", order = 3, name = "Max rows",
					desc = "How many players the scorecard shows.",
					min = 5, max = 25, step = 1,
					get = function() return profile().bars.max end,
					set = function(_, v)
						profile().bars.max = v
						TP.MeterWindow:Invalidate()
					end,
				},
			},
		},
		scoring = {
			type = "group", inline = true, name = "Scoring", order = 2,
			args = {
				mode = {
					type = "select", order = 0, name = "Score mode", width = "double",
					desc = "Real: the full TrueParse score - damage, healing, kicks, dispels, soaking, minus penalties. Raw: pure damage (healing for healers) measured against top Warcraft Logs parses for your spec on this fight, nothing else. Career, coach, and run reports always use Real. Also switchable on the window itself.",
					values = {
						contribution = "Real (everything counts)",
						parse = "Raw (throughput vs top logs only)",
					},
					get = function() return profile().scoring.mode end,
					set = function(_, v)
						profile().scoring.mode = v
						TP.MeterWindow:UpdateModeButtons()
						TP.MeterWindow:Invalidate()
					end,
				},
				ilvl = {
					type = "toggle", order = 1, name = "Normalize by item level", width = "full",
					desc = "Grade throughput relative to gear: a low-ilvl player doing the same output as a high-ilvl one grades higher. Off compares absolute output.",
					get = function() return profile().scoring.normalizeIlvl end,
					set = function(_, v)
						profile().scoring.normalizeIlvl = v
						TP.MeterWindow:Invalidate()
					end,
				},
			},
		},
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
