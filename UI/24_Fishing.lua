-- Tally - the Loot tab's Fishing view: what was pulled out of the water, where
-- and at which character level.
--
-- The figures come from Core/82_Fishing.lua: a cast plus loot inside the
-- window after it. Everything looted that way counts, including junk and pool
-- items; a fish from mail or a trade has no cast behind it.
local addonName, ns = ...

local ACCENT, CreateTileRow, SetTile, CreateListCard, FillScrollingLines,
	ShowCardText, AddCardTitleNote, AddCardScrollbar, MakeCardScrollable,
	RowHoverTick, CreateCornerButton, SetCornerLabel, QualityCode, CutRowText,
	DisplayChar =
	ns.ACCENT, ns.CreateTileRow, ns.SetTile, ns.CreateListCard,
	ns.FillScrollingLines, ns.ShowCardText, ns.AddCardTitleNote,
	ns.AddCardScrollbar, ns.MakeCardScrollable, ns.RowHoverTick,
	ns.CreateCornerButton, ns.SetCornerLabel, ns.QualityCode, ns.CutRowText,
	ns.DisplayChar

local fishingWidgets = {
	tiles = {},
	sort = "count",
	where = "zones",
}

local SORT_LABEL = { count = "most caught", value = "most valuable", name = "A-Z" }
local SORT_ORDER = { "count", "value", "name" }

local function ItemValue(item)
	return (tonumber(item.unitValue) or 0) * (tonumber(item.count) or 0)
end

local function MapTotals(map, prefix)
	local list = {}
	for key, count in pairs(map or {}) do
		if (tonumber(count) or 0) > 0 then
			list[#list + 1] = {
				name = prefix and (prefix..tostring(key)) or tostring(key),
				count = tonumber(count),
			}
		end
	end
	table.sort(list, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return a.name < b.name
	end)
	return list
end

local function ItemsOf(fishing)
	local list = {}
	for itemID, item in pairs(fishing.items or {}) do
		if type(item) == "table" and (tonumber(item.count) or 0) > 0 then
			list[#list + 1] = { id = itemID, item = item }
		end
	end
	return list
end

local function TopNamed(fishing, field, key, limit)
	local list = {}
	for _, entry in ipairs(ItemsOf(fishing)) do
		local map = entry.item[field]
		local count = map and tonumber(map[key]) or 0
		if count and count > 0 then
			list[#list + 1] = { name = entry.item.name or ("item "..tostring(entry.id)), count = count }
		end
	end
	table.sort(list, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return tostring(a.name) < tostring(b.name)
	end)
	while limit and #list > limit do
		table.remove(list)
	end
	return list
end

local function CountText(list, limit)
	local parts = {}
	for index = 1, math.min(#list, limit or 4) do
		local entry = list[index]
		parts[#parts + 1] = entry.name.." "..ns.FormatNumber(entry.count)
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, " · ")
end

local function TipInfo(title, lines, note)
	return { kind = "note", title = title, lines = lines, note = note }
end

local function AddTip(tile)
	tile:EnableMouse(true)
	tile:SetScript("OnEnter", function(self)
		local info = self.tipInfo
		if not info then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(info.title, ACCENT[1], ACCENT[2], ACCENT[3], true)
		for index = 1, #info.lines do
			local line = info.lines[index]
			if line.text then
				GameTooltip:AddLine(line.text, 1, 1, 1, true)
			end
		end
		if info.note then
			GameTooltip:AddLine(info.note, 0.7, 0.7, 0.7, true)
		end
		GameTooltip:Show()
	end)
	tile:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

local function BestItem(fishing)
	local best
	for _, entry in ipairs(ItemsOf(fishing)) do
		local item = entry.item
		if not best or (item.count or 0) > (best.item.count or 0) then
			best = entry
		end
	end
	return best and best.item
end

local function BestZone(fishing)
	local best
	for zone, count in pairs(fishing.zones or {}) do
		local value = tonumber(count) or 0
		if value > 0 and (not best or value > best.count) then
			best = { zone = zone, count = value }
		end
	end
	return best
end

local function RefreshTiles(fishing)
	local tiles = fishingWidgets.tiles
	local best = fishing.best
	if best and (tonumber(best.value) or 0) > 0 then
		SetTile(tiles[1], ns.MoneyString(best.value, 15), CutRowText(best.name or "?", 24))
		tiles[1].tipInfo = TipInfo(best.name or "?", {
			{ text = ns.MoneyColored(best.value).." vendor value" },
			{ text = "Caught x"..ns.FormatNumber(best.count or 0).." in "..tostring(best.zone or "unknown") },
			{ text = "on "..ns.FormatDate(best.at) },
		})
	else
		SetTile(tiles[1], "-", "no priced catch yet")
		tiles[1].tipInfo = nil
	end

	local top = BestItem(fishing)
	if top then
		SetTile(tiles[2], "x"..ns.FormatNumber(top.count or 0), CutRowText(top.name or "?", 24))
		tiles[2].tipInfo = TipInfo(top.name or "?", {
			{ text = "Caught "..ns.FormatNumber(top.count or 0).." in total" },
			{ text = "Zones: "..(CountText(MapTotals(top.zones), 4) or "unknown") },
			{ text = "Levels: "..(CountText(MapTotals(top.levels, "Level "), 4) or "unknown") },
		})
	else
		SetTile(tiles[2], "-", "no catches yet")
		tiles[2].tipInfo = nil
	end

	local zone = BestZone(fishing)
	if zone then
		SetTile(tiles[3], "x"..ns.FormatNumber(zone.count), CutRowText(zone.zone, 24))
		local fish = TopNamed(fishing, "zones", zone.zone, 4)
		tiles[3].tipInfo = TipInfo(zone.zone, {
			{ text = ns.FormatNumber(zone.count).." caught there" },
			{ text = "Most caught: "..(CountText(fish, 4) or "none") },
		})
	else
		SetTile(tiles[3], "-", "no zone yet")
		tiles[3].tipInfo = nil
	end

	local casts = tonumber(fishing.casts) or 0
	local catches = tonumber(fishing.catches) or 0
	if casts > 0 then
		local per = catches > 0 and string.format("%.1f", catches / casts) or "0.0"
		SetTile(tiles[4], ns.FormatNumber(casts), ns.FormatNumber(catches).." caught  ·  "..per.." per cast")
		tiles[4].tipInfo = TipInfo("Fishing casts", {
			{ text = ns.FormatNumber(casts).." lures thrown" },
			{ text = ns.FormatNumber(catches).." items caught" },
			{ text = per.." catches per cast" },
		})
	else
		SetTile(tiles[4], "-", "no casts yet")
		tiles[4].tipInfo = nil
	end
end

local function CatchesEntries(fishing)
	local list = ItemsOf(fishing)
	table.sort(list, function(a, b)
		if fishingWidgets.sort == "name" then
			return tostring(a.item.name) < tostring(b.item.name)
		elseif fishingWidgets.sort == "value" then
			local av, bv = ItemValue(a.item), ItemValue(b.item)
			if av ~= bv then
				return av > bv
			end
		end
		return (a.item.count or 0) > (b.item.count or 0)
	end)
	local entries = {}
	for index = 1, #list do
		local item = list[index].item
		local itemZones = MapTotals(item.zones)
		local itemLevels = MapTotals(item.levels, "Level ")
		local tip = TipInfo(item.name or "?", {
			{ text = "Caught "..ns.FormatNumber(item.count or 0).." in total" },
			{ text = "Vendor value: "..ns.MoneyColored(ItemValue(item)).." ("..ns.MoneyColored(item.unitValue or 0).." each)" },
			{ text = "Zones: "..(CountText(itemZones, 4) or "unknown") },
			{ text = "Levels: "..(CountText(itemLevels, 4) or "unknown") },
			{ text = "First "..ns.FormatDate(item.firstAt).."  ·  last "..ns.FormatDate(item.lastAt) },
		}, "Counted when loot arrived during a Fishing cast.")
		tip.key = "fishing|"..tostring(list[index].id)
		entries[#entries + 1] = {
			left = QualityCode(item.quality or 1)..CutRowText(item.name or "?", 26).."|r",
			right = "x"..ns.FormatNumber(item.count or 0),
			tip = tip,
		}
	end
	return entries
end

local function WhereEntries(fishing)
	local entries = {}
	if fishingWidgets.where == "levels" then
		for level, count in pairs(fishing.levels or {}) do
			local fish = TopNamed(fishing, "levels", level, 4)
			local tip = TipInfo("Level "..tostring(level), {
				{ text = ns.FormatNumber(count).." caught at this level" },
				{ text = "Most caught: "..(CountText(fish, 4) or "none") },
			}, "The character level when the catch was looted.")
			tip.key = "fishingLevel|"..tostring(level)
			entries[#entries + 1] = {
				left = "Level "..tostring(level),
				right = "x"..ns.FormatNumber(count),
				tip = tip,
			}
		end
		table.sort(entries, function(a, b)
			return (tonumber(string.match(a.left, "%d+")) or 0) < (tonumber(string.match(b.left, "%d+")) or 0)
		end)
	else
		for zone, count in pairs(fishing.zones or {}) do
			local fish = TopNamed(fishing, "zones", zone, 4)
			local tip = TipInfo(zone, {
				{ text = ns.FormatNumber(count).." caught there" },
				{ text = "Most caught: "..(CountText(fish, 4) or "none") },
			}, "The zone the character was standing in when the catch was looted.")
			tip.key = "fishingZone|"..tostring(zone)
			entries[#entries + 1] = {
				left = zone,
				right = "x"..ns.FormatNumber(count),
				tip = tip,
			}
		end
		table.sort(entries, function(a, b)
			local av = tonumber(string.match(a.right, "%d+")) or 0
			local bv = tonumber(string.match(b.right, "%d+")) or 0
			if av ~= bv then
				return av > bv
			end
			return a.left < b.left
		end)
	end
	return entries
end

local function AddCardBehaviour(card, offsetField, refresh)
	AddCardScrollbar(card, fishingWidgets, offsetField, refresh)
	MakeCardScrollable(card, fishingWidgets, offsetField, refresh)
	card:SetScript("OnUpdate", function()
		RowHoverTick(card)
	end)
	card:SetScript("OnLeave", function()
		card.hoverKey = nil
		if GameTooltip:IsOwned(card) then
			GameTooltip:Hide()
		end
	end)
end

local function RefreshLootFishing()
	local char = DisplayChar()
	local fishing = (char and char.fishing) or {}
	if not char then
		for index = 1, #fishingWidgets.tiles do
			SetTile(fishingWidgets.tiles[index], "-", "")
		end
		if fishingWidgets.catches then
			ShowCardText(fishingWidgets.catches, "No character selected.")
		end
		if fishingWidgets.whereCard then
			ShowCardText(fishingWidgets.whereCard, "No character selected.")
		end
		return
	end

	RefreshTiles(fishing)

	local catches = CatchesEntries(fishing)
	if fishingWidgets.catches then
		if FillScrollingLines(fishingWidgets.catches, catches, fishingWidgets, "catchesOffset", "Catches", 30) == 0 then
			ShowCardText(fishingWidgets.catches, "No catches recorded yet. Cast a line with Tally running.")
		end
	end

	local rows = WhereEntries(fishing)
	if fishingWidgets.whereCard then
		local title = fishingWidgets.where == "levels" and "Levels" or "Zones"
		if FillScrollingLines(fishingWidgets.whereCard, rows, fishingWidgets, "whereOffset", title, 30) == 0 then
			ShowCardText(fishingWidgets.whereCard, "No zone or level recorded for a catch yet.")
		end
	end
end

local function BuildLootFishing(frame)
	CreateTileRow(frame, -4, { "Most valuable catch", "Most caught", "Best zone", "Lure casts" }, fishingWidgets.tiles, false)
	for index = 1, #fishingWidgets.tiles do
		AddTip(fishingWidgets.tiles[index])
	end

	local catches = CreateListCard(frame, 0, -88, 359, 338, "Catches")
	fishingWidgets.catches = catches
	AddCardTitleNote(catches, "Catches",
		"Every item looted while a Fishing cast was running, or in the seconds after it, including junk and pool items. Hover a fish for its zones, levels and value.")
	AddCardBehaviour(catches, "catchesOffset", RefreshLootFishing)

	local sortButton = CreateCornerButton(catches)
	local function SortLabel()
		return SORT_LABEL[fishingWidgets.sort] or "most caught"
	end
	SetCornerLabel(sortButton, SortLabel())
	sortButton:SetScript("OnClick", function()
		for index = 1, #SORT_ORDER do
			if SORT_ORDER[index] == fishingWidgets.sort then
				fishingWidgets.sort = SORT_ORDER[index % #SORT_ORDER + 1]
				break
			end
		end
		SetCornerLabel(sortButton, SortLabel())
		fishingWidgets.catchesOffset = 0
		RefreshLootFishing()
	end)
	sortButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Order of the catches", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to cycle most caught, most valuable and A-Z.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	sortButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	local whereCard = CreateListCard(frame, 371, -88, 359, 338, "Where")
	fishingWidgets.whereCard = whereCard
	AddCardTitleNote(whereCard, "Where",
		"Catches by zone, or by the character level the catch was looted at. The corner button switches between the two. Hover a row for the fish caught there.")
	AddCardBehaviour(whereCard, "whereOffset", RefreshLootFishing)

	local whereButton = CreateCornerButton(whereCard)
	local function WhereLabel()
		return fishingWidgets.where == "levels" and "levels" or "zones"
	end
	SetCornerLabel(whereButton, WhereLabel())
	whereButton:SetScript("OnClick", function()
		fishingWidgets.where = fishingWidgets.where == "levels" and "zones" or "levels"
		SetCornerLabel(whereButton, WhereLabel())
		fishingWidgets.whereOffset = 0
		RefreshLootFishing()
	end)
	whereButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Group the catches", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Switch between the zone the catch was looted in and the character level it was looted at.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	whereButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	RefreshLootFishing()
end

ns.BuildLootFishing = BuildLootFishing
ns.RefreshLootFishing = RefreshLootFishing
ns.lootFishingWidgets = fishingWidgets
