package.path = "tests/?.lua;" .. package.path
local stub = require("uistub")
stub.install(_G)

local TP = {}
assert(loadfile("UI/Tooltip.lua"))("TrueParse", TP)
local T = TP.Tooltip
local owner = stub.Widget.new("Frame")

local fails = 0
local function check(ok, label)
  if ok then print("ok   "..label) else fails = fails + 1; print("FAIL "..label) end
end

-- 1. plain lines, the ordinary case
local ok, err = pcall(T.Show, T, owner, "TOP", "Plain", {
  { "first line", 1, 1, 1 },
  { "second line", 0.8, 0.8, 0.8 },
})
check(ok, "plain lines render ("..tostring(err)..")")

-- 2. THE REGRESSION: legacy callers pass a vestigial `true` at index 5
ok, err = pcall(T.Show, T, owner, "FORCE_LEFT", "Active", {
  { "Time spent casting or attacking.", 0.8, 0.8, 0.8, true },
})
check(ok, "legacy index-5 `true` survives ("..tostring(err)..")")

-- 3. named size override
ok, err = pcall(T.Show, T, owner, "TOP", "Sized", {
  { "summary", 0.95, 0.95, 0.95, size = 13 },
  { "detail", 0.66, 0.66, 0.7 },
})
check(ok, "named size override ("..tostring(err)..")")

-- 4. the tier legend: chips + rule + gapBefore, mixed with text lines
local TIERS = {
  { n = "I",   t = "Direct",                      r=0.35,g=0.85,b=0.4 },
  { n = "II",  t = "Derived · off-difficulty",    r=0.95,g=0.8, b=0.3 },
  { n = "III", t = "Derived · seasonal average",  r=0.9, g=0.4, b=0.35 },
}
local body = {
  { "A 1:1 comparison against Warcraft Logs.", 0.95, 0.95, 0.95, size = 13 },
  { "Ranked at the difficulty you played.", 0.66, 0.66, 0.7 },
}
for i, x in ipairs(TIERS) do
  body[#body+1] = { x.t, x.r, x.g, x.b, chip = x.n, active = (i == 2),
    rule = (i == 1) or nil, gapBefore = (i == 1) and 4 or nil }
end
ok, err = pcall(T.Show, T, owner, "TOP", "Tier II · Derived", body)
check(ok, "chip legend renders ("..tostring(err)..")")

-- 5. shrinking back to fewer lines must hide the surplus (pool hygiene)
ok, err = pcall(T.Show, T, owner, "TOP", "Short", { { "one line", 1, 1, 1 } })
check(ok, "shrink to one line ("..tostring(err)..")")

-- 6. every anchor mode
for _, a in ipairs({ "TOP", "FORCE_LEFT", "FORCE_RIGHT", "RIGHT" }) do
  local o = pcall(T.Show, T, owner, a, "A", { { "x", 1, 1, 1 } })
  check(o, "anchor mode "..a)
end

-- 7. empty / nil data
check(pcall(T.Show, T, owner, "TOP", "Empty", {}), "empty data")
check(pcall(T.Show, T, owner, "TOP", "Nil", nil), "nil data")

-- 8. THE FIRST-HOVER BUG: the card must be tall enough for its own text.
-- Josh reported this twice. The rows laid out fine, but the backdrop came up
-- short and the legend spilled onto the world, because a FontString with no
-- explicit width reports its SINGLE-LINE height and the running total
-- undercounts every wrapped line.
local tip = stub.byName.TrueParseTooltip
T:Show(owner, "TOP", "Tier II · Approximate", body)

local used = 0
for _, r in ipairs(rawget(tip, "_regions") or {}) do
  if rawget(r, "_shown") and r._kind == "FontString" then
    used = used + r:GetStringHeight()
  end
end
local h = rawget(tip, "_height") or 0
check(h >= used, ("card is tall enough for its text (%dpx card vs %dpx text)"):format(h, used))

-- the root cause, asserted directly: a wrapping line with no width cannot
-- report an honest height, so every visible one must have been given a width
local unmeasured = {}
for _, r in ipairs(rawget(tip, "_regions") or {}) do
  if rawget(r, "_shown") and r._kind == "FontString"
     and (rawget(r, "_text") or "") ~= "" and not rawget(r, "_width") then
    unmeasured[#unmeasured + 1] = rawget(r, "_text"):sub(1, 30)
  end
end
check(#unmeasured == 0,
  ("every visible text line has an explicit width (%d without: %s)")
    :format(#unmeasured, table.concat(unmeasured, " | ")))

print(fails == 0 and "\nALL OK" or ("\n"..fails.." FAILURES"))
return fails
