-- Error sink. The addon has ~64 pcall sites and not one of them recorded why
-- it failed, so a throw inside any of them was indistinguishable from "there
-- was nothing to do". The two worst:
--
--   pcall(TP.Sync.AttachReports, TP.Sync, fight)   -- every self-reported
--       metric silently becomes "?" for the whole fight
--   pcall(TP.Scoring.Engine.ScoreFight, f, opts)   -- a throw reads exactly
--       like "no curves for this content"
--
-- TP.Trap is pcall that remembers. Failures land in SavedVariables with the
-- build that produced them, so any capture you hand over carries its own
-- crash log — see /tp diag.
local _, TP = ...

local MAX = 20 -- most recent distinct failures kept
local announced = {} -- contexts already mentioned THIS session

-- Deliberately NOT hooking seterrorhandler: that is global state shared with
-- every other addon, and TrueParse has no business owning it. This records
-- only what OUR call sites hand it.
function TP.TrapInit(store)
	TP.Errors = store
end

-- Same shape as pcall: TP.Trap(context, fn, ...) -> ok, ...
-- `context` is a short stable label ("AttachReports"), not a message - it is
-- the dedup key, so a failure firing every pull records once with a count
-- rather than flooding the store.
function TP.Trap(context, fn, ...)
	local a, b, c, d = pcall(fn, ...)
	if a then
		return a, b, c, d
	end
	local store = TP.Errors
	if not store then
		return a, b, c, d
	end
	local msg = tostring(b)
	-- strip the absolute AddOns path so the same error from two installs
	-- dedups to one entry
	msg = msg:gsub("Interface\\AddOns\\", ""):gsub("Interface/AddOns/", "")
	local hit
	for _, e in ipairs(store) do
		if e.context == context and e.msg == msg then
			hit = e
			break
		end
	end
	if hit then
		hit.count = (hit.count or 1) + 1
		hit.last = time()
		hit.build = TP.BUILD or hit.build -- last build that reproduced it
	else
		table.insert(store, 1, {
			context = context, msg = msg, count = 1,
			first = time(), last = time(),
			build = TP.BUILD, version = TP.AddonVersion and TP.AddonVersion() or nil,
			client = (TP.Compat and TP.Compat.IS_RETAIL) and "retail" or "mists",
		})
		for i = #store, MAX + 1, -1 do
			store[i] = nil
		end
	end
	-- Once per context PER SESSION. Keyed on a session-local table rather than
	-- the store, because the store persists: keying on it would announce a
	-- recurring error on the day it first appeared and stay silent forever
	-- after. One line per pull would be worse than the bug, which is what the
	-- dedup above prevents.
	if not announced[context] and TP.Addon and TP.Addon.Print then
		announced[context] = true
		TP.Addon:Print(("|cffff6666error in %s|r - /tp diag to see it. %s"):format(context, msg))
	end
	return a, b, c, d
end
