-- Metric trackers register here at load time. The registry composes one
-- dispatch table (CLEU subevent -> handler) so the hot path does a single
-- table lookup per event. Trackers also pre-create their accumulator
-- sub-tables via InitPlayer so combat never allocates.
local _, TP = ...

local Metrics = {
	trackers = {},
	dispatch = {},
}
TP.Metrics = Metrics

function Metrics:Register(tracker)
	self.trackers[#self.trackers + 1] = tracker
end

function Metrics:BuildDispatch()
	wipe(self.dispatch)
	local lists = {}
	for _, tracker in ipairs(self.trackers) do
		for subevent, handler in pairs(tracker.subevents) do
			lists[subevent] = lists[subevent] or {}
			local l = lists[subevent]
			l[#l + 1] = handler
		end
	end
	for subevent, handlers in pairs(lists) do
		if #handlers == 1 then
			self.dispatch[subevent] = handlers[1]
		else
			self.dispatch[subevent] = function(...)
				for i = 1, #handlers do
					handlers[i](...)
				end
			end
		end
	end
end

function Metrics:InitPlayer(acc)
	for _, tracker in ipairs(self.trackers) do
		if tracker.InitPlayer then
			tracker.InitPlayer(acc)
		end
	end
end

function Metrics:MergePlayer(dst, src)
	for _, tracker in ipairs(self.trackers) do
		if tracker.MergePlayer then
			tracker.MergePlayer(dst, src)
		end
	end
end
