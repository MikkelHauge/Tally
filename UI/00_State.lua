-- Tally - UI state shared by more than one file.
--
-- The tab list, the page frames, the per-tab refresh functions and the
-- overview's tile list. They live here so the load order in Tally.toc
-- never decides which file owns them.
local addonName, ns = ...
-- track: the primary tabs whose recording the settings page can switch off.
local TABS = {
	{ id = "overview", title = "Character", desc = "" },
	{ id = "playtime", title = "Playtime", desc = "time per level, sessions and overall played time", track = true },
	{ id = "economy", title = "Economy", desc = "Gold income, spending, auctions and graph", track = true },
	{ id = "combat", title = "Combat", desc = "time logged in and out of combat, and buffs", track = true },
	{ id = "loot", title = "Loot", desc = "Items looted and the best finds.", track = true },
	{ id = "explore", title = "Explore", desc = "Zones, instances and travel.", track = true },
	{ id = "total", title = "Total", desc = "Every character Tally has recorded, combined - and how their levelling compares." },
	{ id = "settings", title = "Settings", desc = "" },
}
local TAB_BY_ID = {}
for index = 1, #TABS do
	TAB_BY_ID[TABS[index].id] = TABS[index]
end
-- Every tile on the overview, so one refresh walks them all.
ns.overviewWidgets = { all = {} }
-- The function that redraws each tab, registered by its build function.
ns.pageRefresh = {}
ns.TABS, ns.TAB_BY_ID = TABS, TAB_BY_ID

-- The page frame for each tab id, filled in when the window is built.
ns.pages = {}
--@ENDFOOTER
