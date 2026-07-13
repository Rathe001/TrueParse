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


-- Semantic version compare: 1 when a > b, -1 when a < b, 0 when equal.
-- "1.2.10" beats "1.2.9" (numeric per segment, not string order).
function TP.CompareVersions(a, b)
	local ai = string.gmatch(tostring(a or ""), "%d+")
	local bi = string.gmatch(tostring(b or ""), "%d+")
	while true do
		local x, y = ai(), bi()
		if not x and not y then
			return 0
		end
		x, y = tonumber(x) or 0, tonumber(y) or 0
		if x ~= y then
			return x > y and 1 or -1
		end
	end
end