local _, TP = ...

local format = string.format

-- 1234567 -> "1.23M"; keeps meter text short
function TP.FormatNumber(n)
	-- nil/secret guard (Josh 2026-07-26 audit): callers pass `x or 0` but
	-- `or` doesn't stop a SECRET (the >= compare would taint first), and a
	-- stray nil would crash. type() is safe on both. Closes the class for
	-- every call site at once.
	if type(n) ~= "number" then
		return "0"
	end
	if n >= 1e9 then
		return format("%.2fB", n / 1e9)
	elseif n >= 1e6 then
		return format("%.2fM", n / 1e6)
	elseif n >= 1e3 then
		return format("%.1fk", n / 1e3)
	end
	return format("%.0f", n)
end

-- "Beautzibub-Undermine" -> "Beautzibub". Cross-realm groups make the realm
-- suffix the single biggest waste of row width, and it tells you nothing you
-- act on (Josh 2026-07-28). DISPLAY ONLY: the stored name keeps its realm,
-- because peer sync and fight records key off the full name.
-- Character names can't contain a hyphen, so the first one always starts the
-- realm. Same type() guard as FormatNumber: names arrive secret often enough
-- (UnitName mid-encounter) that every string helper has to survive one.
function TP.ShortName(name)
	if type(name) ~= "string" then
		return name
	end
	return name:match("^([^%-]+)") or name
end

-- Do two name strings refer to the same character, when only ONE of them may
-- carry a realm? Addon-message senders are always realm-qualified
-- ("Elessar-Rotmire"); GetUnitName(unit, true) appends the realm only for a
-- player on a DIFFERENT one. Comparing the raw strings (what Sync did until
-- 2026-07-31) accepted cross-realm peers and rejected everyone on your own
-- realm, dropping their hellos, self-reports and wipe calls — they showed as
-- "no addon" with "?" for every self-reported metric.
--
-- Realms disqualify only when BOTH sides name one, so a bare name matches its
-- qualified twin without letting two different realms collide.
function TP.SameCharacter(a, b)
	if type(a) ~= "string" or type(b) ~= "string" then
		return false
	end
	-- UNKNOWN is Roster's fallback for a secret name; it owns no character
	if a == "" or b == "" or a == UNKNOWN or b == UNKNOWN then
		return false
	end
	local an, ar = a:match("^([^%-]+)%-?(.*)$")
	local bn, br = b:match("^([^%-]+)%-?(.*)$")
	if not an or an ~= bn then
		return false
	end
	if ar ~= "" and br ~= "" then
		return ar == br
	end
	return true
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