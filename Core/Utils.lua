local _, TP = ...

local format = string.format

-- 1234567 -> "1.23M"; keeps meter text short
function TP.FormatNumber(n)
	if n >= 1e9 then
		return format("%.2fB", n / 1e9)
	elseif n >= 1e6 then
		return format("%.2fM", n / 1e6)
	elseif n >= 1e3 then
		return format("%.1fk", n / 1e3)
	end
	return format("%.0f", n)
end

function TP.ClassColor(class)
	local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
	if c then
		return c.r, c.g, c.b
	end
	return 0.6, 0.6, 0.6
end
