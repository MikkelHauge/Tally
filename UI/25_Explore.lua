-- Tally - the Explore tab: zones, instances, bosses and travel.
local addonName, ns = ...

-- Helpers and constants from the files loaded above (see Tally.toc).
local ACCENT, TILE_WIDTH, TILE_HEIGHT, TILE_GAP, CreateTile, SetTile, CreateTileRow, DisplayChar, CreateListCard, ShowCardText, AddCardTitleNote, FillScrollingLines, MakeCardScrollable, CreateCornerButton, SetCornerLabel, pageRefresh =
	ns.ACCENT, ns.TILE_WIDTH, ns.TILE_HEIGHT, ns.TILE_GAP, ns.CreateTile, ns.SetTile, ns.CreateTileRow, ns.DisplayChar, ns.CreateListCard, ns.ShowCardText, ns.AddCardTitleNote, ns.FillScrollingLines, ns.MakeCardScrollable, ns.CreateCornerButton, ns.SetCornerLabel, ns.pageRefresh
-------------------------------------------------------------------------------
-- Explore page
-------------------------------------------------------------------------------

local exploreWidgets = { tiles = {} }

-- The orders the two place cards can be listed in, and the short label their
-- button carries for each. Time runs both ways and the names run A-Z or Z-A,
-- so the button cycles all four like the other order buttons in the addon.
local EXPLORE_SORTS = { "most", "least", "az", "za" }

local function NextExploreSort(mode)
	for index = 1, #EXPLORE_SORTS do
		if EXPLORE_SORTS[index] == mode then
			return EXPLORE_SORTS[index % #EXPLORE_SORTS + 1]
		end
	end
	return EXPLORE_SORTS[1]
end

local function ExploreSortLabel(mode)
	if mode == "least" then
		return "least time"
	end
	if mode == "az" then
		return "A-Z"
	end
	if mode == "za" then
		return "Z-A"
	end
	return "most time"
end

local function RefreshExplore()
	if not exploreWidgets.zones then
		return
	end
	local char = DisplayChar()
	if not char then
		for index = 1, #exploreWidgets.tiles do
			SetTile(exploreWidgets.tiles[index], "-", "")
		end
		ShowCardText(exploreWidgets.zones, "No data yet.")
		ShowCardText(exploreWidgets.dungeons, "No data yet.")
		if exploreWidgets.zoneSortButton then
			exploreWidgets.zoneSortButton:SetShown(false)
		end
		if exploreWidgets.dungeonSortButton then
			exploreWidgets.dungeonSortButton:SetShown(false)
		end
		return
	end

	local explore = char.explore
	local zoneCount = ns.CountTable(explore.zones)
	local latest = explore.recentFirsts[#explore.recentFirsts]
	SetTile(exploreWidgets.tiles[1], tostring(zoneCount), latest and ("Latest: "..latest.name) or "none yet")

	local zoneList = {}
	for name, entry in pairs(explore.zones) do
		zoneList[#zoneList + 1] = { name = name, seconds = entry.seconds or 0, visits = entry.visits or 0, first = entry.first }
	end
	-- The order button walks time in both directions and the names A-Z or
	-- Z-A; the name settles ties in every order, so rows never shuffle.
	local zoneSort = exploreWidgets.zoneSort or "most"
	table.sort(zoneList, function(a, b)
		if zoneSort == "az" then
			return a.name < b.name
		end
		if zoneSort == "za" then
			return a.name > b.name
		end
		if a.seconds == b.seconds then
			return a.name < b.name
		end
		if zoneSort == "least" then
			return a.seconds < b.seconds
		end
		return a.seconds > b.seconds
	end)

	local dungeonList = {}
	for name, dungeon in pairs(explore.dungeons) do
		dungeonList[#dungeonList + 1] = {
			name = name,
			entered = dungeon.entered or 0,
			bosses = dungeon.bosses or 0,
			seconds = dungeon.seconds or 0,
			first = dungeon.first,
			last = dungeon.last,
		}
	end
	local dungeonSort = exploreWidgets.dungeonSort or "most"
	table.sort(dungeonList, function(a, b)
		if dungeonSort == "az" then
			return a.name < b.name
		end
		if dungeonSort == "za" then
			return a.name > b.name
		end
		if a.seconds == b.seconds then
			if a.entered == b.entered then
				return a.name < b.name
			end
			return a.entered > b.entered
		end
		if dungeonSort == "least" then
			return a.seconds < b.seconds
		end
		return a.seconds > b.seconds
	end)
	-- The tile counts every run, and names the instance entered last rather
	-- than the one first seen last: a place visited twice keeps the newer
	-- date, and coming back to it later makes it the latest again.
	local newestInstance, newestAt
	local runs = 0
	for index = 1, #dungeonList do
		local dungeon = dungeonList[index]
		runs = runs + (dungeon.entered or 0)
		local at = dungeon.last or dungeon.first
		if at and (not newestAt or at > newestAt) then
			newestAt, newestInstance = at, dungeon
		end
	end
	SetTile(exploreWidgets.tiles[2], tostring(runs), newestInstance and ("Latest: "..newestInstance.name) or "none entered yet")
	SetTile(exploreWidgets.tiles[3], ns.FormatDistance(explore.distance), "approximate, on foot")
	SetTile(exploreWidgets.tiles[4], ns.FormatDuration(explore.flightSeconds, true), (explore.flights or 0) > 0 and (explore.flights.." flights") or "no flights yet")

	-- The quests boxes: how many quests were completed, the experience read
	-- after a turn-in, and the reward money booked to them. Every figure is
	-- only what the client actually reported, so a dash means "not read yet".
	local questGold = char.gold and char.gold.income and char.gold.income.quest
	SetTile(exploreWidgets.tiles[5], tostring(char.quests or 0), "since "..ns.FormatDate(char.created))
	if char.questXp then
		SetTile(exploreWidgets.tiles[6], ns.FormatNumber(char.questXp), "only what was read at hand-ins")
	else
		SetTile(exploreWidgets.tiles[6], "-", "no quest experience read yet")
	end
	if questGold then
		SetTile(exploreWidgets.tiles[7], ns.MoneyString(questGold), "reward money booked to quests")
	else
		SetTile(exploreWidgets.tiles[7], "-", "no quests have rewarded gold yet")
	end
	-- Time on a mount, read from the client's own answer once a second. Where
	-- the client cannot say, the box says so rather than showing a zero that
	-- would read as "never mounted".
	local liveSession = (not ns.IsViewing()) and char.sessions.current or nil
	if ns.CanReadMounted and ns.CanReadMounted() then
		local mountedSub = "on a mount, as Tally saw it"
		if liveSession then
			mountedSub = ns.FormatDuration(liveSession.mountedSeconds or 0, true).." this session"
		end
		SetTile(exploreWidgets.tiles[8], ns.FormatDuration(explore.mountedSeconds, true), mountedSub)
	else
		SetTile(exploreWidgets.tiles[8], "-", "Tally cannot tell here")
	end

	-- Tall rows: the place on the left, active time on the right, and visits
	-- plus the first day seen on the detail line. Only active time is
	-- counted, so AFK hours are not included.
	local zoneEntries = {}
	for index = 1, #zoneList do
		local zone = zoneList[index]
		zoneEntries[#zoneEntries + 1] = {
			left = zone.name,
			right = ns.FormatDuration(zone.seconds, true),
			detail = zone.visits > 0 and (zone.visits..(zone.visits == 1 and " visit" or " visits")) or "no visits counted yet",
			detailRight = zone.first and ("first "..ns.FormatDate(zone.first)) or nil,
		}
	end
	if FillScrollingLines(exploreWidgets.zones, zoneEntries, exploreWidgets, "zoneScrollOffset", "Time in zones", 26, true) == 0 then
		ShowCardText(exploreWidgets.zones, "No zone time recorded yet.")
	end

	local dungeonEntries = {}
	for index = 1, #dungeonList do
		local dungeon = dungeonList[index]
		dungeonEntries[#dungeonEntries + 1] = {
			left = dungeon.name,
			right = ns.FormatDuration(dungeon.seconds, true),
			detail = dungeon.entered..(dungeon.entered == 1 and " run" or " runs").." · "..dungeon.bosses..(dungeon.bosses == 1 and " boss" or " bosses"),
			detailRight = dungeon.last and ("last "..ns.FormatDate(dungeon.last)) or nil,
		}
	end
	if FillScrollingLines(exploreWidgets.dungeons, dungeonEntries, exploreWidgets, "dungeonScrollOffset", "Time in dungeons", 26, true) == 0 then
		ShowCardText(exploreWidgets.dungeons, "No dungeon runs recorded yet.")
	end

	-- The order button sits on the card only while there is more than one
	-- place to order: with a single row every order looks the same.
	if exploreWidgets.zoneSortButton then
		local shown = #zoneList > 1
		exploreWidgets.zoneSortButton:SetShown(shown)
		if shown then
			SetCornerLabel(exploreWidgets.zoneSortButton, ExploreSortLabel(exploreWidgets.zoneSort or "most"))
		end
	end
	if exploreWidgets.dungeonSortButton then
		local shown = #dungeonList > 1
		exploreWidgets.dungeonSortButton:SetShown(shown)
		if shown then
			SetCornerLabel(exploreWidgets.dungeonSortButton, ExploreSortLabel(exploreWidgets.dungeonSort or "most"))
		end
	end
end

local function BuildExplorePage(page)
	CreateTileRow(page, -4, { "Zones Visited", "Dungeons", "Distance", "Flight time" }, exploreWidgets.tiles, false)
	-- The row under that one, four boxes of the same size as the ones above:
	-- quests handed in, the experience read at those hand-ins, the reward
	-- money booked to them, and the time Tally saw the character on a mount.
	local secondRow = { "Quests completed", "Quest XP", "Quest gold", "Time mounted" }
	for index = 1, #secondRow do
		local tile = CreateTile(page, secondRow[index])
		tile:SetSize(TILE_WIDTH, TILE_HEIGHT)
		tile:SetPoint("TOPLEFT", page, "TOPLEFT", (index - 1) * (TILE_WIDTH + TILE_GAP), -78)
		exploreWidgets.tiles[4 + index] = tile
	end
	-- The two place cards take all the height the quests row leaves them.
	exploreWidgets.zones = CreateListCard(page, 0, -156, 359, 304, "Time in zones")
	exploreWidgets.dungeons = CreateListCard(page, 371, -156, 359, 304, "Time in dungeons")
	AddCardTitleNote(exploreWidgets.zones, "Time in zones",
		"Time spent in each zone and its visits, counted second by second and leaving AFK out. A visit is leaving and coming back; logging in or reloading is not one.")
	AddCardTitleNote(exploreWidgets.dungeons, "Time in dungeons",
		"Time spent in each instance, with runs and bosses; raids count here too. A run is one entry, so the same place entered three times reads three.")
	-- Both lists keep every entry, so both cards take the wheel, and both
	-- carry an order button that hides itself while the card holds one place.
	MakeCardScrollable(exploreWidgets.zones, exploreWidgets, "zoneScrollOffset", RefreshExplore)
	MakeCardScrollable(exploreWidgets.dungeons, exploreWidgets, "dungeonScrollOffset", RefreshExplore)

	local function AddExploreSortButton(card, modeField, offsetField, buttonField)
		exploreWidgets[modeField] = "most"
		local button = CreateCornerButton(card)
		SetCornerLabel(button, ExploreSortLabel(exploreWidgets[modeField]))
		button:SetScript("OnClick", function()
			exploreWidgets[modeField] = NextExploreSort(exploreWidgets[modeField])
			exploreWidgets[offsetField] = 0
			RefreshExplore()
		end)
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
			GameTooltip:AddLine("The order of the list", ACCENT[1], ACCENT[2], ACCENT[3])
			GameTooltip:AddLine("Click to cycle: most time first, least time first, A-Z and Z-A. The wheel walks the rows in any order.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		exploreWidgets[buttonField] = button
	end
	AddExploreSortButton(exploreWidgets.zones, "zoneSort", "zoneScrollOffset", "zoneSortButton")
	AddExploreSortButton(exploreWidgets.dungeons, "dungeonSort", "dungeonScrollOffset", "dungeonSortButton")
	pageRefresh.explore = RefreshExplore
end

-- Handed to the shell, which builds and refreshes every tab.
ns.BuildExplorePage, ns.RefreshExplore = BuildExplorePage, RefreshExplore
