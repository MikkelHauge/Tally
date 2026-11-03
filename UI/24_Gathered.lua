-- Tally - the Loot tab's Gathered view: fish, herbs, ore and leather.
--
-- The total view is a matrix of the four gathering professions by character
-- level, always in alphabetical order. Each profession view mirrors the
-- Fishing page: four summary tiles, then the items gathered and where they
-- came from, with the amount on the right of every row.
--
-- Mining, Herbalism and Skinning are credited by Core/83_Gathering.lua from a
-- successful gather and the loot that follows it. Fishing comes from the
-- existing char.fishing records.
local addonName, ns = ...

local ACCENT, GREEN, ROW_DETAIL_DIM, VALUE_COLOR, CreateListCard,
	AddCardTitleNote, AddCardScrollbar, MakeCardScrollable, FillScrollingLines,
	ShowCardText, RowHoverTick, DisplayChar, QualityCode, CutRowText,
	CreateCornerButton, SetCornerLabel, CreateTileRow, SetTile =
	ns.ACCENT, ns.GREEN, ns.ROW_DETAIL_DIM, ns.VALUE_COLOR, ns.CreateListCard,
	ns.AddCardTitleNote, ns.AddCardScrollbar, ns.MakeCardScrollable,
	ns.FillScrollingLines, ns.ShowCardText, ns.RowHoverTick, ns.DisplayChar,
	ns.QualityCode, ns.CutRowText, ns.CreateCornerButton, ns.SetCornerLabel,
	ns.CreateTileRow, ns.SetTile

local gatheredWidgets = {
	offset = 0,
	view = "total",
	sort = "count",
	where = "zones",
	levelOrder = "low",
	itemsOffset = 0,
	whereOffset = 0,
	tiles = {},
	totalTiles = {},
}

-- Alphabetical, so the total matrix always has the same four columns.
local TOTAL_PROFESSIONS = { "Fishing", "Herbalism", "Mining", "Skinning" }
local SORT_LABEL = { count = "most gathered", value = "most valuable", name = "A-Z" }
local SORT_ORDER = { "count", "value", "name" }
local PROFESSION_LABELS = {
	Mining = { top = "Most mined", attempts = "Nodes mined" },
	Herbalism = { top = "Most picked", attempts = "Herbs picked" },
	Skinning = { top = "Most skinned", attempts = "Corpses skinned" },
}

local LEVEL_FIELDS = { "mid5", "mid4", "mid3", "mid2", "mid", "right" }

local function LevelFields(names)
	local fields = {}
	local start = #LEVEL_FIELDS - #names + 1
	for index = 1, #names do
		fields[index] = LEVEL_FIELDS[start + index - 1]
	end
	return fields
end

local function LevelRow(names, values, colors, left, leftColor)
	local row = { left = left, leftColor = leftColor }
	local fields = LevelFields(names)
	for index = 1, #names do
		local field = fields[index]
		row[field] = values[index] or 0
		row[field.."Color"] = colors and colors[index] or nil
	end
	return row
end

local function LevelsFor(char, profession)
	if profession == "Fishing" then
		local fishing = char.fishing
		return type(fishing) == "table" and fishing.levels or {}
	end
	local store = char.gathering
	local entry = type(store) == "table" and store[profession]
	return type(entry) == "table" and entry.levels or {}
end

local function EntryFor(char, profession)
	local store = char and char.gathering
	local entry = type(store) == "table" and store[profession]
	return type(entry) == "table" and entry or {}
end

local function AvailableProfessions(char)
	if not char or not ns.gathering or not ns.gathering.Professions then
		return {}
	end
	local names = ns.gathering.Professions(char)
	table.sort(names, function(a, b)
		return tostring(a) < tostring(b)
	end)
	return names
end

local function MapTotals(map, prefix)
	local list = {}
	for key, count in pairs(type(map) == "table" and map or {}) do
		local value = tonumber(count) or 0
		if value > 0 then
			list[#list + 1] = {
				name = prefix and (prefix..tostring(key)) or tostring(key),
				count = value,
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

local function CountText(list, limit)
	local parts = {}
	for index = 1, math.min(#list, limit or 4) do
		parts[#parts + 1] = list[index].name.." "..ns.FormatNumber(list[index].count)
	end
	if #parts == 0 then
		return nil
	end
	return table.concat(parts, " · ")
end

local function ItemEntries(entry)
	local list = {}
	for itemID, item in pairs(type(entry.items) == "table" and entry.items or {}) do
		if type(item) == "table" and (tonumber(item.count) or 0) > 0 then
			list[#list + 1] = { id = itemID, item = item }
		end
	end
	return list
end

local function TopItem(entry)
	local best
	for _, entryItem in ipairs(ItemEntries(entry)) do
		if not best or (tonumber(entryItem.item.count) or 0) > (tonumber(best.item.count) or 0) then
			best = entryItem
		end
	end
	return best
end

local function BestZone(entry)
	local best
	for zone, count in pairs(type(entry.zones) == "table" and entry.zones or {}) do
		local value = tonumber(count) or 0
		if value > 0 and (not best or value > best.count) then
			best = { zone = zone, count = value }
		end
	end
	return best
end

-- The items from one map (a zone or a level), most first, for a tooltip.
local function TopIn(entry, field, key, limit)
	local list = {}
	for _, entryItem in ipairs(ItemEntries(entry)) do
		local map = type(entryItem.item[field]) == "table" and entryItem.item[field] or nil
		local count = map and tonumber(map[key]) or 0
		if count > 0 then
			list[#list + 1] = {
				name = entryItem.item.name or ("item "..tostring(entryItem.id)),
				count = count,
			}
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

-- The total view's tiles read across all four professions at once, so the
-- same item gathered by two professions is merged before it is shown.
local function CombinedItems(char)
	local merged = {}
	local function add(items)
		for itemID, item in pairs(type(items) == "table" and items or {}) do
			if type(item) == "table" and (tonumber(item.count) or 0) > 0 then
				local entry = merged[itemID]
				if not entry then
					entry = {
						id = itemID, name = item.name, quality = item.quality,
						count = 0, unitValue = 0, zones = {}, levels = {},
					}
					merged[itemID] = entry
				end
				entry.count = entry.count + (tonumber(item.count) or 0)
				local unitValue = tonumber(item.unitValue) or 0
				if unitValue > 0 then
					entry.unitValue = unitValue
				end
				for zone, count in pairs(type(item.zones) == "table" and item.zones or {}) do
					entry.zones[zone] = (tonumber(entry.zones[zone]) or 0) + (tonumber(count) or 0)
				end
				for level, count in pairs(type(item.levels) == "table" and item.levels or {}) do
					entry.levels[level] = (tonumber(entry.levels[level]) or 0) + (tonumber(count) or 0)
				end
			end
		end
	end
	add(char.fishing and char.fishing.items)
	local store = char.gathering
	for _, profession in ipairs(TOTAL_PROFESSIONS) do
		local entry = type(store) == "table" and store[profession]
		add(type(entry) == "table" and entry.items)
	end
	return merged
end

local function BestFind(char)
	local best
	local function consider(candidate)
		if type(candidate) ~= "table" then
			return
		end
		local value = tonumber(candidate.value) or 0
		if value > (tonumber(best and best.value) or 0) then
			best = candidate
		end
	end
	consider(type(char.fishing) == "table" and char.fishing.best)
	local store = char.gathering
	for _, profession in ipairs(TOTAL_PROFESSIONS) do
		local entry = type(store) == "table" and store[profession]
		consider(type(entry) == "table" and entry.best)
	end
	return best
end

local function TopMerged(merged, field, key, limit)
	local list = {}
	for _, item in pairs(merged) do
		local map = type(item[field]) == "table" and item[field] or nil
		local count = map and tonumber(map[key]) or 0
		if count > 0 then
			list[#list + 1] = { name = item.name or "?", count = count }
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

local function RefreshTotalTiles(char)
	local tiles = gatheredWidgets.totalTiles
	if #tiles == 0 then
		return
	end
	local merged = CombinedItems(char)
	local totalItems, levelCount = 0, 0
	local zoneCounts = {}
	local topItem
	local levels = {}
	for _, item in pairs(merged) do
		totalItems = totalItems + item.count
		if not topItem or item.count > topItem.count then
			topItem = item
		end
		for zone, count in pairs(item.zones) do
			zoneCounts[zone] = (zoneCounts[zone] or 0) + (tonumber(count) or 0)
		end
		for level, count in pairs(item.levels) do
			if (tonumber(count) or 0) > 0 then
				levels[level] = true
			end
		end
	end
	for _ in pairs(levels) do
		levelCount = levelCount + 1
	end

	local best = BestFind(char)
	if best and (tonumber(best.value) or 0) > 0 then
		SetTile(tiles[1], ns.MoneyString(best.value, 15), CutRowText(best.name or "?", 24))
		tiles[1].tipInfo = TipInfo(best.name or "?", {
			{ text = ns.MoneyColored(best.value).." vendor value" },
			{ text = "Gathered x"..ns.FormatNumber(best.count or 0).." in "..tostring(best.zone or "unknown") },
			{ text = "on "..ns.FormatDate(best.at) },
		})
	else
		SetTile(tiles[1], "-", "no priced find yet")
		tiles[1].tipInfo = nil
	end

	if topItem then
		SetTile(tiles[2], "x"..ns.FormatNumber(topItem.count or 0), CutRowText(topItem.name or "?", 24))
		tiles[2].tipInfo = TipInfo(topItem.name or "?", {
			{ text = "Gathered "..ns.FormatNumber(topItem.count or 0).." in total" },
			{ text = "Zones: "..(CountText(MapTotals(topItem.zones), 4) or "unknown") },
			{ text = "Levels: "..(CountText(MapTotals(topItem.levels, "Level "), 4) or "unknown") },
		})
	else
		SetTile(tiles[2], "-", "nothing gathered yet")
		tiles[2].tipInfo = nil
	end

	local bestZone, bestZoneCount
	for zone, count in pairs(zoneCounts) do
		if count > 0 and (not bestZoneCount or count > bestZoneCount) then
			bestZone, bestZoneCount = zone, count
		end
	end
	if bestZone then
		SetTile(tiles[3], "x"..ns.FormatNumber(bestZoneCount), CutRowText(bestZone, 24))
		tiles[3].tipInfo = TipInfo(bestZone, {
			{ text = ns.FormatNumber(bestZoneCount).." items gathered there" },
			{ text = "Most: "..(CountText(TopMerged(merged, "zones", bestZone, 4), 4) or "none") },
		})
	else
		SetTile(tiles[3], "-", "no zone yet")
		tiles[3].tipInfo = nil
	end

	local active = 0
	if type(char.fishing) == "table" and next(char.fishing.items or {}) ~= nil then
		active = active + 1
	end
	local store = char.gathering
	for _, profession in ipairs(TOTAL_PROFESSIONS) do
		local entry = type(store) == "table" and store[profession]
		if type(entry) == "table" and next(entry.items or {}) ~= nil then
			active = active + 1
		end
	end
	if totalItems > 0 then
		SetTile(tiles[4], ns.FormatNumber(totalItems),
			"across "..active..(active == 1 and " profession" or " professions"))
		tiles[4].tipInfo = TipInfo("Total items gathered", {
			{ text = ns.FormatNumber(totalItems).." items in total" },
			{ text = "Across "..active.." gathering professions" },
			{ text = levelCount.." character levels represented" },
		})
	else
		SetTile(tiles[4], "-", "nothing gathered yet")
		tiles[4].tipInfo = nil
	end
end

local function TotalRows(char, order)
	local names = TOTAL_PROFESSIONS
	local maps = {}
	local firstLevel, lastLevel
	for index = 1, #names do
		local map = LevelsFor(char, names[index])
		maps[index] = map
		for level, count in pairs(map) do
			if (tonumber(count) or 0) > 0 and type(level) == "number" then
				if not firstLevel or level < firstLevel then
					firstLevel = level
				end
				if not lastLevel or level > lastLevel then
					lastLevel = level
				end
			end
		end
	end
	local current = tonumber(char.level) or 0
	if current > (lastLevel or 0) then
		lastLevel = current
	end
	if not firstLevel and #names > 0 and current > 0 then
		-- Nothing gathered yet: show the current level with zero counts so the
		-- four profession columns are still visible.
		firstLevel = current
		lastLevel = current
	end
	if not firstLevel then
		return nil
	end

	local withTotal = #names > 1
	local columns = {}
	local colors = {}
	for index = 1, #names do
		columns[index] = names[index]
		colors[index] = ACCENT
	end
	if withTotal then
		columns[#columns + 1] = "Total"
		colors[#colors + 1] = ACCENT
	end
	local rows = { LevelRow(columns, columns, colors, "Level", ACCENT) }

	local ascending = order ~= "high"
	local firstRow = ascending and firstLevel or lastLevel
	local lastRow = ascending and lastLevel or firstLevel
	local step = ascending and 1 or -1
	for level = firstRow, lastRow, step do
		local values, rowColors, lines = {}, {}, {}
		local total = 0
		for index = 1, #names do
			local count = tonumber(maps[index][level]) or 0
			total = total + count
			values[index] = ns.FormatNumber(count)
			rowColors[index] = count > 0 and GREEN or ROW_DETAIL_DIM
			lines[index] = { text = names[index].."  "..ns.FormatNumber(count) }
		end
		if withTotal then
			values[#values + 1] = ns.FormatNumber(total)
			rowColors[#rowColors + 1] = total > 0 and VALUE_COLOR or ROW_DETAIL_DIM
			lines[#lines + 1] = { text = "Total  "..ns.FormatNumber(total) }
		end
		local row = LevelRow(columns, values, rowColors, "Level "..level)
		row.tip = {
			kind = "note", title = "Level "..level,
			lines = lines,
			note = "The total materials collected by this character through their professions.",
			key = "gatherLevel|"..level.."|"..table.concat(names, ","),
		}
		rows[#rows + 1] = row
	end
	return rows
end

-- Four summary tiles, one set per profession, mirroring the Fishing page.
local function RefreshDetailTiles(profession, entry)
	local tiles = gatheredWidgets.tiles
	local labels = PROFESSION_LABELS[profession] or {}
	tiles[1].label:SetText("Most valuable")
	tiles[2].label:SetText(labels.top or "Most gathered")
	tiles[3].label:SetText("Best zone")
	tiles[4].label:SetText(labels.attempts or "Gathers")

	local best = entry.best
	if best and (tonumber(best.value) or 0) > 0 then
		SetTile(tiles[1], ns.MoneyString(best.value, 15), CutRowText(best.name or "?", 24))
		tiles[1].tipInfo = TipInfo(best.name or "?", {
			{ text = ns.MoneyColored(best.value).." vendor value" },
			{ text = "Gathered x"..ns.FormatNumber(best.count or 0).." in "..tostring(best.zone or "unknown") },
			{ text = "on "..ns.FormatDate(best.at) },
		})
	else
		SetTile(tiles[1], "-", "no priced find yet")
		tiles[1].tipInfo = nil
	end

	local top = TopItem(entry)
	if top then
		SetTile(tiles[2], "x"..ns.FormatNumber(top.item.count or 0), CutRowText(top.item.name or "?", 24))
		tiles[2].tipInfo = TipInfo(top.item.name or "?", {
			{ text = "Gathered "..ns.FormatNumber(top.item.count or 0).." in total" },
			{ text = "Zones: "..(CountText(MapTotals(top.item.zones), 4) or "unknown") },
			{ text = "Levels: "..(CountText(MapTotals(top.item.levels, "Level "), 4) or "unknown") },
		})
	else
		SetTile(tiles[2], "-", "nothing gathered yet")
		tiles[2].tipInfo = nil
	end

	local zone = BestZone(entry)
	if zone then
		SetTile(tiles[3], "x"..ns.FormatNumber(zone.count), CutRowText(zone.zone, 24))
		local items = TopIn(entry, "zones", zone.zone, 4)
		tiles[3].tipInfo = TipInfo(zone.zone, {
			{ text = ns.FormatNumber(zone.count).." items gathered there" },
			{ text = "Most: "..(CountText(items, 4) or "none") },
		})
	else
		SetTile(tiles[3], "-", "no zone yet")
		tiles[3].tipInfo = nil
	end

	local attempts = tonumber(entry.attempts) or 0
	local gathered = tonumber(entry.gathered) or 0
	if attempts > 0 then
		local per = gathered > 0 and string.format("%.1f", gathered / attempts) or "0.0"
		SetTile(tiles[4], ns.FormatNumber(attempts),
			ns.FormatNumber(gathered).." items  ·  "..per.." per gather")
		tiles[4].tipInfo = TipInfo(labels.attempts or "Gathers", {
			{ text = ns.FormatNumber(attempts).." successful gathers" },
			{ text = ns.FormatNumber(gathered).." items gathered" },
			{ text = per.." items per gather" },
		})
	else
		SetTile(tiles[4], "-", "no gathers yet")
		tiles[4].tipInfo = nil
	end
end

local function DetailItemRows(profession, entry)
	local list = ItemEntries(entry)
	table.sort(list, function(a, b)
		if gatheredWidgets.sort == "name" then
			return tostring(a.item.name) < tostring(b.item.name)
		elseif gatheredWidgets.sort == "value" then
			local av = (tonumber(a.item.unitValue) or 0) * (tonumber(a.item.count) or 0)
			local bv = (tonumber(b.item.unitValue) or 0) * (tonumber(b.item.count) or 0)
			if av ~= bv then
				return av > bv
			end
		end
		return (tonumber(a.item.count) or 0) > (tonumber(b.item.count) or 0)
	end)
	local rows = {}
	for index = 1, #list do
		local item = list[index].item
		local itemValue = (tonumber(item.unitValue) or 0) * (tonumber(item.count) or 0)
		local tip = TipInfo(item.name or "?", {
			{ text = "Gathered "..ns.FormatNumber(item.count or 0).." in total" },
			{ text = "Vendor value: "..ns.MoneyColored(itemValue).." ("..ns.MoneyColored(item.unitValue or 0).." each)" },
			{ text = "Zones: "..(CountText(MapTotals(item.zones), 4) or "unknown") },
			{ text = "Levels: "..(CountText(MapTotals(item.levels, "Level "), 4) or "unknown") },
			{ text = "First "..ns.FormatDate(item.firstAt).."  ·  last "..ns.FormatDate(item.lastAt) },
		}, "Counted when the loot from a successful "..profession.." gather arrived.")
		tip.key = "gathering|"..tostring(profession).."|"..tostring(list[index].id)
		rows[#rows + 1] = {
			left = QualityCode(item.quality or 1)..CutRowText(item.name or "?", 30).."|r",
			right = "x"..ns.FormatNumber(item.count or 0),
			tip = tip,
		}
	end
	return rows
end

-- Where the profession's items came from: zone on the left, amount on the
-- right, or the same by character level. Levels run highest first.
local function DetailWhereRows(profession, entry)
	local rows = {}
	if gatheredWidgets.where == "levels" then
		local map = type(entry.levels) == "table" and entry.levels or {}
		local levels = {}
		for level, count in pairs(map) do
			local value = tonumber(count) or 0
			if value > 0 then
				levels[#levels + 1] = { level = tonumber(level) or 0, count = value }
			end
		end
		table.sort(levels, function(a, b)
			return a.level > b.level
		end)
		for _, row in ipairs(levels) do
			local tip = TipInfo("Level "..row.level, {
				{ text = ns.FormatNumber(row.count).." items gathered at this level" },
				{ text = "Most: "..(CountText(TopIn(entry, "levels", row.level, 4), 4) or "none") },
			}, "The character level when the loot was gathered.")
			tip.key = "gatheringLevel|"..tostring(profession).."|"..tostring(row.level)
			rows[#rows + 1] = {
				left = "Level "..row.level,
				right = "x"..ns.FormatNumber(row.count),
				tip = tip,
			}
		end
	else
		local map = type(entry.zones) == "table" and entry.zones or {}
		local zones = {}
		for zone, count in pairs(map) do
			local value = tonumber(count) or 0
			if value > 0 then
				zones[#zones + 1] = { zone = zone, count = value }
			end
		end
		table.sort(zones, function(a, b)
			if a.count ~= b.count then
				return a.count > b.count
			end
			return tostring(a.zone) < tostring(b.zone)
		end)
		for _, row in ipairs(zones) do
			local tip = TipInfo(row.zone, {
				{ text = ns.FormatNumber(row.count).." items gathered there" },
				{ text = "Most: "..(CountText(TopIn(entry, "zones", row.zone, 4), 4) or "none") },
			}, "The zone the character was standing in when the loot was gathered.")
			tip.key = "gatheringZone|"..tostring(profession).."|"..tostring(row.zone)
			rows[#rows + 1] = {
				left = CutRowText(row.zone, 30),
				right = "x"..ns.FormatNumber(row.count),
				tip = tip,
			}
		end
	end
	return rows
end

local function ViewLabel()
	local view = gatheredWidgets.view
	if not view or view == "total" then
		return "total items"
	end
	return string.lower(view)
end

local function ViewList(char)
	local list = { "total" }
	local names = AvailableProfessions(char)
	for index = 1, #names do
		list[#list + 1] = names[index]
	end
	return list
end

local function AddCardBehaviour(card, offsetField, refresh)
	AddCardScrollbar(card, gatheredWidgets, offsetField, refresh)
	MakeCardScrollable(card, gatheredWidgets, offsetField, refresh)
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

local function RefreshDetail(char, profession)
	if not gatheredWidgets.itemsCard or not gatheredWidgets.whereCard then
		return
	end
	local entry = EntryFor(char, profession)
	RefreshDetailTiles(profession, entry)

	local items = DetailItemRows(profession, entry)
	if FillScrollingLines(gatheredWidgets.itemsCard, items, gatheredWidgets, "itemsOffset", "Gathered", 30) == 0 then
		ShowCardText(gatheredWidgets.itemsCard, "No "..string.lower(profession).." items recorded yet.")
	end

	local rows = DetailWhereRows(profession, entry)
	local title = gatheredWidgets.where == "levels" and "Levels" or "Zones"
	if FillScrollingLines(gatheredWidgets.whereCard, rows, gatheredWidgets, "whereOffset", title, 30) == 0 then
		ShowCardText(gatheredWidgets.whereCard, "No zone or level recorded for this profession yet.")
	end
end

local function RefreshLootGathered()
	local card = gatheredWidgets.card
	if not card then
		return
	end
	local char = DisplayChar()
	if not char then
		if gatheredWidgets.fishingFrame then
			gatheredWidgets.fishingFrame:Hide()
		end
		if gatheredWidgets.detailFrame then
			gatheredWidgets.detailFrame:Hide()
		end
		if gatheredWidgets.totalFrame then
			gatheredWidgets.totalFrame:Show()
		end
		for index = 1, #gatheredWidgets.totalTiles do
			SetTile(gatheredWidgets.totalTiles[index], "-", "")
			gatheredWidgets.totalTiles[index].tipInfo = nil
		end
		card:Show()
		ShowCardText(card, "No character selected.")
		return
	end
	local names = AvailableProfessions(char)
	if #names == 0 then
		gatheredWidgets.view = "total"
	end
	local key = (char.name or "").."|"..(char.realm or "")
	if gatheredWidgets.charKey ~= key then
		gatheredWidgets.charKey = key
		gatheredWidgets.offset = 0
		gatheredWidgets.itemsOffset = 0
		gatheredWidgets.whereOffset = 0
	end
	if gatheredWidgets.view ~= "total" then
		local found = false
		for index = 1, #names do
			if names[index] == gatheredWidgets.view then
				found = true
				break
			end
		end
		if not found then
			gatheredWidgets.view = "total"
			gatheredWidgets.offset = 0
		end
	end
	if gatheredWidgets.button then
		SetCornerLabel(gatheredWidgets.button, ViewLabel())
	end

	if gatheredWidgets.view == "Fishing" and gatheredWidgets.fishingFrame then
		card:Hide()
		if gatheredWidgets.detailFrame then
			gatheredWidgets.detailFrame:Hide()
		end
		if gatheredWidgets.totalFrame then
			gatheredWidgets.totalFrame:Hide()
		end
		gatheredWidgets.fishingFrame:Show()
		if ns.RefreshLootFishing then
			ns.RefreshLootFishing()
		end
		return
	end
	if gatheredWidgets.fishingFrame then
		gatheredWidgets.fishingFrame:Hide()
	end

	if gatheredWidgets.view == "total" then
		if gatheredWidgets.detailFrame then
			gatheredWidgets.detailFrame:Hide()
		end
		if gatheredWidgets.totalFrame then
			gatheredWidgets.totalFrame:Show()
		end
		card:Show()
		RefreshTotalTiles(char)
		local rows = TotalRows(char, gatheredWidgets.levelOrder)
		if not rows then
			card.title:SetText("Total items gathered by level")
			ShowCardText(card, "No gathered items recorded yet. Mine a node, pick an herb or skin a corpse with Tally running.")
			return
		end
		FillScrollingLines(card, rows, gatheredWidgets, "offset", "Total items gathered by level", 30)
	else
		card:Hide()
		if gatheredWidgets.totalFrame then
			gatheredWidgets.totalFrame:Hide()
		end
		if gatheredWidgets.detailFrame then
			gatheredWidgets.detailFrame:Show()
		end
		RefreshDetail(char, gatheredWidgets.view)
	end
end

local function BuildLootGathered(frame)
	-- The existing Fishing page is one of the profession views, not a
	-- separate Loot sub-tab any more.
	local fishingFrame = CreateFrame("Frame", nil, frame)
	fishingFrame:SetAllPoints(frame)
	fishingFrame:Hide()
	gatheredWidgets.fishingFrame = fishingFrame
	if ns.BuildLootFishing then
		ns.BuildLootFishing(fishingFrame)
	end

	-- The total view: four summary tiles across all professions, then the
	-- by-level matrix.
	local total = CreateFrame("Frame", nil, frame)
	total:SetAllPoints(frame)
	total:Hide()
	gatheredWidgets.totalFrame = total

	CreateTileRow(total, -4, { "Most valuable", "Most gathered", "Best zone", "Total items" }, gatheredWidgets.totalTiles, false)
	for index = 1, #gatheredWidgets.totalTiles do
		AddTip(gatheredWidgets.totalTiles[index])
	end

	local card = CreateListCard(total, 0, -88, 730, 338, "Total items gathered by level")
	-- Up to four gathering professions plus a Total column.
	card.rowMidRight = 105
	card.rowMid2Right = 210
	card.rowMid3Right = 315
	card.rowMid4Right = 420
	gatheredWidgets.card = card
	AddCardTitleNote(card, "Gathered by level",
		"One row per character level, with Fishing, Herbalism, Mining and Skinning always shown in alphabetical order. The view button switches to one gathering profession: Fishing keeps its catches and where cards, the others show summary tiles and list every item with its amount. The corner button switches the level order between ascending and descending; rows are only sorted by level.")
	AddCardScrollbar(card, gatheredWidgets, "offset", RefreshLootGathered)
	MakeCardScrollable(card, gatheredWidgets, "offset", RefreshLootGathered)
	card:SetScript("OnUpdate", function()
		RowHoverTick(card)
	end)
	card:SetScript("OnLeave", function()
		card.hoverKey = nil
		if GameTooltip:IsOwned(card) then
			GameTooltip:Hide()
		end
	end)

	local orderButton = CreateCornerButton(card)
	local function OrderLabel()
		return gatheredWidgets.levelOrder == "high" and "level: desc" or "level: asc"
	end
	SetCornerLabel(orderButton, OrderLabel())
	orderButton:SetScript("OnClick", function()
		gatheredWidgets.levelOrder = gatheredWidgets.levelOrder == "high" and "low" or "high"
		SetCornerLabel(orderButton, OrderLabel())
		gatheredWidgets.offset = 0
		RefreshLootGathered()
	end)
	orderButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Order of the levels", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to switch between lowest level first (ascending) and highest level first (descending). The rows are only ever sorted by level.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	orderButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	-- One profession at a time: the same four tiles as Fishing, then the
	-- item list on the left and where it came from on the right.
	local detail = CreateFrame("Frame", nil, frame)
	detail:SetAllPoints(frame)
	detail:Hide()
	gatheredWidgets.detailFrame = detail

	CreateTileRow(detail, -4, { "Most valuable", "Most gathered", "Best zone", "Gathers" }, gatheredWidgets.tiles, false)
	for index = 1, #gatheredWidgets.tiles do
		AddTip(gatheredWidgets.tiles[index])
	end

	local itemsCard = CreateListCard(detail, 0, -88, 359, 338, "Gathered")
	gatheredWidgets.itemsCard = itemsCard
	AddCardTitleNote(itemsCard, "Gathered",
		"Every item credited to this profession, most gathered first. The corner button switches between most gathered, most valuable and A-Z. Hover an item for its zones, levels and value.")
	AddCardBehaviour(itemsCard, "itemsOffset", RefreshLootGathered)

	local sortButton = CreateCornerButton(itemsCard)
	local function SortLabel()
		return SORT_LABEL[gatheredWidgets.sort] or "most gathered"
	end
	SetCornerLabel(sortButton, SortLabel())
	sortButton:SetScript("OnClick", function()
		for index = 1, #SORT_ORDER do
			if SORT_ORDER[index] == gatheredWidgets.sort then
				gatheredWidgets.sort = SORT_ORDER[index % #SORT_ORDER + 1]
				break
			end
		end
		SetCornerLabel(sortButton, SortLabel())
		gatheredWidgets.itemsOffset = 0
		RefreshLootGathered()
	end)
	sortButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Order of the items", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to cycle most gathered, most valuable and A-Z.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	sortButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	local whereCard = CreateListCard(detail, 371, -88, 359, 338, "Where")
	gatheredWidgets.whereCard = whereCard
	AddCardTitleNote(whereCard, "Where",
		"Items by zone, or by the character level they were gathered at, with the amount on the right. The corner button switches between the two. Hover a row for the items found there.")
	AddCardBehaviour(whereCard, "whereOffset", RefreshLootGathered)

	local whereButton = CreateCornerButton(whereCard)
	local function WhereLabel()
		return gatheredWidgets.where == "levels" and "levels" or "zones"
	end
	SetCornerLabel(whereButton, WhereLabel())
	whereButton:SetScript("OnClick", function()
		gatheredWidgets.where = gatheredWidgets.where == "levels" and "zones" or "levels"
		SetCornerLabel(whereButton, WhereLabel())
		gatheredWidgets.whereOffset = 0
		RefreshLootGathered()
	end)
	whereButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Group the items", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Switch between the zone the items were gathered in and the character level they were gathered at.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	whereButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	-- The view button sits on the Loot page's top-right, above all the
	-- profession views, so Fishing's own corner buttons stay free.
	local page = frame:GetParent() or frame
	local button = CreateCornerButton(page, -12, -2)
	gatheredWidgets.button = button
	SetCornerLabel(button, ViewLabel())
	button:Hide()
	button:SetScript("OnClick", function()
		local char = DisplayChar()
		local list = ViewList(char)
		local current = 1
		for index = 1, #list do
			if list[index] == gatheredWidgets.view then
				current = index
				break
			end
		end
		gatheredWidgets.view = list[current % #list + 1] or "total"
		gatheredWidgets.offset = 0
		gatheredWidgets.itemsOffset = 0
		gatheredWidgets.whereOffset = 0
		SetCornerLabel(button, ViewLabel())
		RefreshLootGathered()
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Gathering view", ACCENT[1], ACCENT[2], ACCENT[3])
		local list = ViewList(DisplayChar())
		GameTooltip:AddLine("Click to cycle: "..table.concat(list, ", ")..". Only professions this character has are offered.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	RefreshLootGathered()
end

ns.BuildLootGathered = BuildLootGathered
ns.RefreshLootGathered = RefreshLootGathered
ns.lootGatheredWidgets = gatheredWidgets
