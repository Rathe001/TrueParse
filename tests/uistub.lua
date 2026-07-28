-- Minimal WoW widget stub, enough to run UI/Tooltip.lua headlessly and
-- catch API misuse (wrong SetFont arg types, missing methods, unbalanced
-- pools) without launching the game.
local M = {}

local calls = {}
M.calls = calls
-- created frames, by name, so a test can reach into the widget it is
-- exercising (the tooltip keeps its frame in a file-local)
M.byName = {}

local function record(kind, method, ...)
	calls[#calls + 1] = { kind = kind, method = method, n = select("#", ...), args = { ... } }
end

local Widget = {}
Widget.__index = Widget

local STRICT = {
	-- methods whose argument types WoW actually enforces
	SetFont = function(self, path, size, flags)
		if type(path) ~= "string" then
			error(("SetFont arg1 must be string, got %s"):format(type(path)), 3)
		end
		if type(size) ~= "number" then
			error(("bad argument #2 to 'SetFont' (number expected, got %s)"):format(type(size)), 3)
		end
		self._font = { path, size, flags }
	end,
	SetColorTexture = function(self, r, g, b, a)
		for i, v in ipairs({ r, g, b }) do
			if type(v) ~= "number" then
				error(("SetColorTexture arg%d must be number, got %s"):format(i, type(v)), 3)
			end
		end
	end,
	SetText = function(self, t)
		if t ~= nil and type(t) ~= "string" and type(t) ~= "number" then
			error(("SetText expects string, got %s"):format(type(t)), 3)
		end
		self._text = t and tostring(t) or ""
	end,
	SetWidth = function(self, w)
		if type(w) ~= "number" then
			error(("SetWidth expects number, got %s"):format(type(w)), 3)
		end
		self._width = w
	end,
	-- Simulates WRAPPING, which is the whole point: a FontString that was
	-- never given a width can't know how many lines it occupies, and the
	-- real client returns the single-line height in that case. Reproducing
	-- that is what lets the tests catch a card sized too short for its text.
	GetStringHeight = function(self)
		local size = (rawget(self, "_font") and rawget(self, "_font")[2]) or 10
		local lineH = size + 2
		local text = rawget(self, "_text") or ""
		if text == "" then
			return lineH
		end
		local w = rawget(self, "_width")
		if not w or w <= 0 then
			return lineH -- unmeasurable: exactly what the client does
		end
		local charW = size * 0.5 -- rough average glyph advance
		local perLine = math.max(1, math.floor(w / charW))
		return math.max(1, math.ceil(#text / perLine)) * lineH
	end,
	SetPoint = function(self, point, rel, relPoint, x, y)
		if type(point) ~= "string" then
			error("SetPoint arg1 must be an anchor string", 3)
		end
		-- Two legal shapes: SetPoint(point, x, y) relative to the parent, and
		-- SetPoint(point, region, relPoint, x, y). Only reject a relativeTo
		-- that is neither a region nor the start of the short form.
		if rel ~= nil and type(rel) ~= "table" and type(rel) ~= "string"
			and type(rel) ~= "number" then
			error(("SetPoint relativeTo must be a region, got %s"):format(type(rel)), 3)
		end
		if type(rel) == "table" and relPoint ~= nil and type(relPoint) ~= "string" then
			error(("SetPoint relativePoint must be an anchor string, got %s")
				:format(type(relPoint)), 3)
		end
		self._points = (self._points or 0) + 1
	end,
	ClearAllPoints = function(self)
		self._points = 0
	end,
}

function Widget.new(kind)
	local w = setmetatable({ _kind = kind, _shown = false, _points = 0 }, Widget)
	return w
end

function Widget:__index_fallback() end

setmetatable(Widget, {
	__index = function(_, key)
		return nil
	end,
})

Widget.__index = function(self, key)
	if STRICT[key] then
		return STRICT[key]
	end
	local v = rawget(Widget, key)
	if v then
		return v
	end
	-- every other widget method: accept anything, return plausible values
	return function(_, ...)
		record(self._kind, key, ...)
		if key == "CreateFontString" or key == "CreateTexture" then
			local w = Widget.new(key == "CreateFontString" and "FontString" or "Texture")
			local regions = rawget(self, "_regions")
			if not regions then
				regions = {}
				rawset(self, "_regions", regions)
			end
			regions[#regions + 1] = w
			return w
		elseif key == "GetFont" then
			return "Fonts\\FRIZQT__.TTF", 10, ""
		elseif key == "GetStringWidth" then
			return 40
		elseif key == "GetRight" then
			return 500
		elseif key == "GetWidth" or key == "GetHeight" then
			return 220
		elseif key == "SetHeight" then
			self._height = ...
		elseif key == "Show" then
			self._shown = true
		elseif key == "Hide" then
			self._shown = false
		end
		return nil
	end
end

function M.install(env)
	env.UIParent = Widget.new("Frame")
	env.CreateFrame = function(kind, name, parent, template)
		local w = Widget.new("Frame")
		w._children = {}
		if name then
			M.byName[name] = w
		end
		local kids = type(parent) == "table" and rawget(parent, "_children")
		if kids then
			kids[#kids + 1] = w
		end
		return w
	end
	env.GameTooltip = Widget.new("Frame")
	return env
end

M.Widget = Widget
return M
