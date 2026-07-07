-- Minimap launcher (LDB + LibDBIcon): left-click toggles the scorecard,
-- right-click opens options.
local _, TP = ...

local Minimap = {}
TP.Minimap = Minimap

function Minimap:OnEnable()
	local LDB = LibStub("LibDataBroker-1.1", true)
	local LibDBIcon = LibStub("LibDBIcon-1.0", true)
	if not (LDB and LibDBIcon) then
		return
	end

	local dataObject = LDB:NewDataObject("TrueParse", {
		type = "launcher",
		icon = "Interface\\Icons\\INV_Misc_Note_02",
		OnClick = function(_, button)
			if button == "RightButton" then
				TP.Options.Open()
			else
				TP.MeterWindow:Toggle()
			end
		end,
		OnTooltipShow = function(tooltip)
			tooltip:AddLine("TrueParse")
			tooltip:AddLine("Left-click: toggle scorecard", 1, 1, 1)
			tooltip:AddLine("Right-click: options", 1, 1, 1)
			tooltip:AddLine("/tp run — run report · /tp career — career stats", 0.7, 0.7, 0.7)
		end,
	})

	LibDBIcon:Register("TrueParse", dataObject, TP.Addon.db.profile.minimap)
end
