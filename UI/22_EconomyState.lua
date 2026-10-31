-- Tally - Economy view state and the daily graph's day window.
--
-- The widget table is shared by the Economy sub-views, the Total tab's daily
-- graph and the characters picker. It lives here so the page shell and its
-- sub-views agree on one table without depending on load order.
local addonName, ns = ...

local economyWidgets = { tiles = {}, graph = {}, subview = "ledger" }

-- How far back the daily graph can look, and the label its button carries.
-- Defined here because the economy page build wires the button up long before
-- the graph itself is drawn.
local GRAPH_DAYS = { 3, 7, 14, 31 }

local function NextGraphDays(days)
	for index = 1, #GRAPH_DAYS do
		if GRAPH_DAYS[index] == days then
			return GRAPH_DAYS[index % #GRAPH_DAYS + 1]
		end
	end
	return 14
end

local function GraphDaysLabel(days)
	return tostring(days).." days"
end

-- One colour per month, for the date labels under the daily graph: a run of
-- labels in one colour reads as one month, and the day that starts a month
-- carries its name as well as its number.
local MONTH_COLORS = {
	{ 0.90, 0.68, 0.42 }, { 0.58, 0.78, 0.95 }, { 0.68, 0.92, 0.58 }, { 0.95, 0.72, 0.78 },
	{ 0.78, 0.72, 0.95 }, { 0.95, 0.86, 0.48 }, { 0.55, 0.92, 0.86 }, { 0.92, 0.62, 0.48 },
	{ 0.72, 0.88, 0.72 }, { 0.92, 0.78, 0.58 }, { 0.62, 0.72, 0.92 }, { 0.88, 0.68, 0.88 },
}

ns.economyWidgets = economyWidgets
ns.NextGraphDays = NextGraphDays
ns.GraphDaysLabel = GraphDaysLabel
ns.MONTH_COLORS = MONTH_COLORS
