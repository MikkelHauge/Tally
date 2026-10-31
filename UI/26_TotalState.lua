-- Tally - Total view state shared by the page shell and its sub-views.
local addonName, ns = ...

local totalWidgets = {
	tiles = {},
	rows = {},
	legend = {},
	slotLabels = {},
	segments = {},
	markers = {},
	subview = "combined",
	page = 1,
	panelShown = false,
}

ns.totalWidgets = totalWidgets
