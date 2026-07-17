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
				wipeDebrief = {
					type = "toggle", order = 2, name = "Post-wipe debrief",
					desc = "After a wipe: deaths, how many followed avoidable damage, and the pull's top pointers. Notes when the wipe looked called - nothing after that point counts against anyone. Only you see this.",
					get = function() return profile().wipeDebrief end,
					set = function(_, v) profile().wipeDebrief = v end,
				},
				announce = {
					type = "toggle", order = 3, name = "Announce run MVP to group",
					desc = "When a dungeon/key completes, post ONE line to group chat: the run MVP, what earned it, and the group score. When several TrueParse users have announcements on, only one (the newest version) posts - no duplicates. On retail a Post button asks first; Blizzard blocks addons from sending chat on their own. Off by default; be considerate.",
					get = function() return profile().announce end,
					set = function(_, v)
						profile().announce = v
						-- the election reads groupmates' last-heard flags;
						-- a silent change corrupts it (audit 2026-07-16)
						if TP.Sync and TP.Sync.QueueHello then
							TP.Sync:QueueHello()
						end
					end,
				},
				announceSummary = {
					type = "toggle", order = 4, name = "Announce group summary",
					desc = "When a run completes, post ONE line telling the group's story: the score, kill speed vs the group's own parses when they disagree (execution vs throughput), kick coverage, deaths, and the run's most useful pointer. No individual scores. Same one-announcer rule and retail Post button as the MVP line.",
					get = function() return profile().announceSummary end,
					set = function(_, v)
						profile().announceSummary = v
						if TP.Sync and TP.Sync.QueueHello then
							TP.Sync:QueueHello()
						end
					end,
				},
			},
		},
		reports = {
			type = "group", inline = true, name = "Reports", order = 4,
			args = {
				run = {
					type = "execute", order = 1, name = "Run report",
					desc = "Print the current run's report card to your chat: everyone's whole-run score, awards, and the run's top pointers. Only you see it.",
					func = function() TP.RunSummary:Report() end,
				},
				career = {
					type = "execute", order = 2, name = "Career stats",
					desc = "Print your GPA, trend, best fight, and strengths.",
					func = function() TP.Career:PrintSummary() end,
				},
				share = {
					type = "execute", order = 3, name = "Share kill to group",
					desc = "Post the latest kill to group chat: completion time vs Warcraft Logs ranked kills, plus the group score.",
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
