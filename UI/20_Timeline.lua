-- Tally - Character -> Timeline: this character's stored events, newest first,
-- 20 rows per page. Character-specific, so it lives with the character.
local addonName, ns = ...

local timelineState = { page = nil, key = nil }

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

ns.BuildTimelinePage = function(parent)
	timelineState.page = ns.BuildPagedList(parent, 0, -4, 730, 400, "Timeline", 23)
end

ns.RefreshTimeline = function()
	if not timelineState.page then
		return
	end
	local char = ns.DisplayChar()
	if not char then
		timelineState.page.SetLines({}, true)
		return
	end
	local key = tostring(char.name).."|"..tostring(char.realm)
	local events = ns.AllEvents(char)
	local rows = {}
	for index = 1, #events do
		rows[#rows + 1] = BuildRow(events[index], char)
	end
	local reset = key ~= timelineState.key
	timelineState.key = key
	timelineState.page.SetLines(rows, reset)
end
