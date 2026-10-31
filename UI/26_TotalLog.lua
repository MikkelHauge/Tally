-- Tally - Total -> Log: every stored event across the ticked characters.
-- Newest first, 20 rows per page, real page buttons, no scroll view.
local addonName, ns = ...

local totalLog = { page = nil, selection = "" }

local function BuildRow(event, char)
	local color = ns.ClassColorCode and ns.ClassColorCode(char.classFile) or nil
	local name = ns.DisplayName and ns.DisplayName(char) or char.name or "?"
	local left = ns.FormatDateTime(event.at).."  "..(color or "")..name.."|r  "..ns.EventText(event)
	return {
		left = left,
		right = event.zone or "",
		tip = ns.EventTip(event),
	}
end

function ns.BuildTotalLog(parent)
	totalLog.page = ns.BuildPagedList(parent, 0, -4, 730, 400, "Log", 23)
end

function ns.RefreshTotalLog()
	if not totalLog.page then
		return
	end
	local known = ns.KnownCharacters and ns.KnownCharacters() or {}
	local selected, keys = {}, {}
	for index = 1, #known do
		local entry = known[index]
		if ns.TotalIncludes(entry.key) then
			selected[#selected + 1] = entry
			keys[#keys + 1] = tostring(entry.key)
		end
	end
	local signature = table.concat(keys, "|")
	local merged = {}
	for index = 1, #selected do
		local entry = selected[index]
		local events = ns.AllEvents(entry.char)
		for eventIndex = 1, #events do
			merged[#merged + 1] = { event = events[eventIndex], char = entry.char }
		end
	end
	table.sort(merged, function(a, b)
		local aAt, bAt = a.event.at or 0, b.event.at or 0
		if aAt ~= bAt then
			return aAt > bAt
		end
		if (a.event.id or 0) ~= (b.event.id or 0) then
			return (a.event.id or 0) > (b.event.id or 0)
		end
		return tostring(a.char.name) < tostring(b.char.name)
	end)
	local rows = {}
	for index = 1, #merged do
		rows[#rows + 1] = BuildRow(merged[index].event, merged[index].char)
	end
	local reset = signature ~= totalLog.selection
	totalLog.selection = signature
	totalLog.page.SetLines(rows, reset)
end
