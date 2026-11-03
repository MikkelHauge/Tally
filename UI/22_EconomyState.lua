-- Tally - Economy view state and the daily graph's day window.
--
-- The widget table is shared by the Economy sub-views, the Total tab's daily
-- graph and the characters picker. It lives here so the page shell and its
-- sub-views agree on one table without depending on load order.
local addonName, ns = ...

local economyWidgets = { tiles = {}, graph = {}, subview = "ledger" }

-- How far back the daily graph can look: a window of up to a year, ending up
-- to a year before today. The daily ledger keeps as many days, so the longest
-- window is drawn from stored balances rather than guessed at.
local GRAPH_DAYS_MAX = 365
local GRAPH_DAYS_DEFAULT = 31

-- One colour per month, for the date labels under the daily graph: a run of
-- labels in one colour reads as one month, and the day that starts a month
-- carries its name as well as its number.
local MONTH_COLORS = {
	{ 0.90, 0.68, 0.42 }, { 0.58, 0.78, 0.95 }, { 0.68, 0.92, 0.58 }, { 0.95, 0.72, 0.78 },
	{ 0.78, 0.72, 0.95 }, { 0.95, 0.86, 0.48 }, { 0.55, 0.92, 0.86 }, { 0.92, 0.62, 0.48 },
	{ 0.72, 0.88, 0.72 }, { 0.92, 0.78, 0.58 }, { 0.62, 0.72, 0.92 }, { 0.88, 0.68, 0.88 },
}

ns.economyWidgets = economyWidgets
ns.GRAPH_DAYS_MAX = GRAPH_DAYS_MAX
ns.GRAPH_DAYS_DEFAULT = GRAPH_DAYS_DEFAULT
ns.MONTH_COLORS = MONTH_COLORS
