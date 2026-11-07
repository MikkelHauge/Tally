-- Tally - one event registrar for every domain.
--
-- Each event has one frame and an ordered list of handlers. Owners are called
-- Core, Auction, Kills; a handler failure is traced once and disabled for the
-- session so one mistake cannot stop the other owners. The registrar loads
-- before Core.lua so Core can register its own ADDON_LOADED handler at load.
local addonName, ns = ...

local OWNER_RANK = { Core = 1, Auction = 2, Kills = 3, Professions = 4, Social = 5 }

local frames = {}     -- [event key] = frame
local eventHandlers = {}   -- [event key] = ordered handler list
local sequence = 0

local function Trace(message)
	if ns.Trace then
		pcall(ns.Trace, message)
	end
end

local function KeyOf(event, unit)
	if unit then
		return event.."|"..unit
	end
	return event
end

local function RegisterFrame(key, event, unit)
	local frame = CreateFrame("Frame")
	frame:SetScript("OnEvent", function(_, eventName, ...)
		ns.Dispatch(key, eventName, ...)
	end)
	frames[key] = frame
	local ok, registered
	if unit and type(frame.RegisterUnitEvent) == "function" then
		ok, registered = pcall(frame.RegisterUnitEvent, frame, event, unit)
	else
		ok, registered = pcall(frame.RegisterEvent, frame, event)
	end
	if not ok or registered == false then
		pcall(frame.UnregisterAllEvents, frame)
		frames[key] = nil
		return nil
	end
	return frame
end

-- ns.On(event, handler, owner, opts)
-- opts.unit registers a unit event; opts.priority overrides the owner order.
function ns.On(event, handler, owner, opts)
	if type(event) ~= "string" or type(handler) ~= "function" then
		return false
	end
	opts = opts or {}
	local unit = opts.unit
	local key = KeyOf(event, unit)
	local list = eventHandlers[key]
	if not list then
		list = {}
		eventHandlers[key] = list
	end
	for index = 1, #list do
		local entry = list[index]
		if entry.handler == handler and entry.owner == owner then
			return true
		end
	end
	local frame = frames[key]
	if not frame then
		frame = RegisterFrame(key, event, unit)
		if not frame then
			eventHandlers[key] = nil
			return false
		end
	end
	local rank = opts.priority or OWNER_RANK[owner] or 50
	local entry = {
		event = event,
		unit = unit,
		owner = owner or "Unknown",
		handler = handler,
		rank = rank,
		sequence = sequence,
	}
	sequence = sequence + 1
	local position = #list + 1
	for index = 1, #list do
		local other = list[index]
		if rank < other.rank or (rank == other.rank and entry.sequence < other.sequence) then
			position = index
			break
		end
	end
	table.insert(list, position, entry)
	return true
end

-- ns.Off(event, handler, owner, unit)
-- handler nil removes every handler of that owner; owner nil removes every
-- handler. Returns how many entries were removed.
function ns.Off(event, handler, owner, unit)
	local key = KeyOf(event, unit)
	local list = eventHandlers[key]
	if not list then
		return 0
	end
	local removed = 0
	for index = #list, 1, -1 do
		local entry = list[index]
		if (handler == nil or entry.handler == handler)
			and (owner == nil or entry.owner == owner) then
			table.remove(list, index)
			removed = removed + 1
		end
	end
	if #list == 0 then
		eventHandlers[key] = nil
		local frame = frames[key]
		if frame then
			pcall(frame.UnregisterEvent, frame, event)
			pcall(frame.UnregisterAllEvents, frame)
			frames[key] = nil
		end
	end
	return removed
end

-- Dispatch one event to its eventHandlers. The snapshot keeps a handler that
-- removes itself during the call from disturbing the rest of the run.
function ns.Dispatch(key, event, ...)
	local list = eventHandlers[key]
	if not list or #list == 0 then
		return
	end
	local snapshot = {}
	for index = 1, #list do
		snapshot[index] = list[index]
	end
	for index = 1, #snapshot do
		local entry = snapshot[index]
		if not entry.disabled then
			local ok, err = pcall(entry.handler, event, ...)
			if not ok then
				entry.disabled = true
				ns.lastEventError = tostring(event).." ("..tostring(entry.owner).."): "..tostring(err)
				Trace("event "..tostring(event).." ("..tostring(entry.owner)..") failed: "..tostring(err))
			end
		end
	end
end

function ns.Emit(event, ...)
	ns.Dispatch(event, event, ...)
end

-- A stable list for /tally debug: event, unit, owners and handler count.
function ns.EventOwners()
	local out = {}
	for key, list in pairs(eventHandlers) do
		local event, unit = string.match(key, "^(.-)|(.+)$")
		if not event then
			event = key
		end
		local owners, seen = {}, {}
		for index = 1, #list do
			local entry = list[index]
			local label = entry.owner..(entry.disabled and " (disabled)" or "")
			if not seen[label] then
				seen[label] = true
				owners[#owners + 1] = label
			end
		end
		out[#out + 1] = { event = event, unit = unit, owners = owners, count = #list }
	end
	table.sort(out, function(a, b)
		if a.event == b.event then
			return (a.unit or "") < (b.unit or "")
		end
		return a.event < b.event
	end)
	return out
end

ns.OWNER_RANK = OWNER_RANK

ns.events = {}
ns.events.On = ns.On
ns.events.Off = ns.Off
ns.events.Emit = ns.Emit
ns.events.Dispatch = ns.Dispatch
ns.events.Owners = ns.EventOwners
ns.events.OwnerRank = ns.OWNER_RANK
