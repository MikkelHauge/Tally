-- Tally - the Loot tab's Crafted view: the items this character made.
--
-- Only char.professions.crafted feeds this page. Looted and gathered items
-- never appear here; materials gained by disenchanting are added to the same
-- crafted tally as Enchanting output, because that is how Tally counts them.
local addonName, ns = ...

local ACCENT, VALUE_COLOR, CreateListCard, CreateTileRow, SetTile,
	AddCardTitleNote, AddCardScrollbar, MakeCardScrollable, FillScrollingLines,
	ShowCardText, RowHoverTick, DisplayChar, QualityCode, CutRowText,
	CreateCornerButton, SetCornerLabel =
	ns.ACCENT, ns.VALUE_COLOR, ns.CreateListCard, ns.CreateTileRow, ns.SetTile,
	ns.AddCardTitleNote, ns.AddCardScrollbar, ns.MakeCardScrollable,
	ns.FillScrollingLines, ns.ShowCardText, ns.RowHoverTick, ns.DisplayChar,
	ns.QualityCode, ns.CutRowText, ns.CreateCornerButton, ns.SetCornerLabel

local craftedWidgets = {
	tiles = {},
	sort = "count",
	itemsOffset = 0,
}

local SORT_LABEL = { count = "most crafted", value = "most valuable", name = "A-Z" }
local SORT_ORDER = { "count", "value", "name" }

local function CraftedItems(char)
	local list = {}
	local crafted = type(char) == "table" and type(char.professions) == "table"
		and char.professions.crafted or {}
	for name, tally in pairs(type(crafted) == "table" and crafted or {}) do
		if type(tally) == "table" and (tonumber(tally.count) or 0) > 0 then
			list[#list + 1] = { name = name, item = tally }
		end
	end
	return list
end

local function ItemValue(item)
	local itemID = tonumber(item.itemID)
	if not itemID then
		return 0
	end
	local _, _, _, sellPrice = ns.ItemInfo(itemID)
	return (tonumber(sellPrice) or 0) * (tonumber(item.count) or 0)
end

local function UnitValue(item)
	local itemID = tonumber(item.itemID)
	if not itemID then
		return 0
	end
	local _, _, _, sellPrice = ns.ItemInfo(itemID)
	return tonumber(sellPrice) or 0
end

local function Quality(item)
	local itemID = tonumber(item.itemID)
	if itemID then
		local _, _, quality = ns.ItemInfo(itemID)
		if quality then
			return quality
		end
	end
	return tonumber(item.quality) or 1
end

local function ProfessionOf(item)
	return item.profession or "Unknown"
end

local function ProfessionTotals(list)
	local totals = {}
	for index = 1, #list do
		local profession = ProfessionOf(list[index].item)
		totals[profession] = (totals[profession] or 0) + (tonumber(list[index].item.count) or 0)
	end
	return totals
end

local function TopProfession(totals)
	local best, bestCount
	for profession, count in pairs(totals) do
		if count > 0 and (not bestCount or count > bestCount) then
			best, bestCount = profession, count
		end
	end
	return best, bestCount
end

local function TopItem(list)
	local best
	for index = 1, #list do
		local item = list[index].item
		local count = tonumber(item.count) or 0
		if not best or count > (tonumber(best.item.count) or 0) then
			best = list[index]
		end
	end
	return best
end

local function MostValuable(list)
	local best, bestValue = nil, 0
	for index = 1, #list do
		local value = ItemValue(list[index].item)
		if value > bestValue then
			best, bestValue = list[index], value
		end
	end
	return best, bestValue
end

local function TopCraftedIn(list, profession, limit)
	local rows = {}
	for index = 1, #list do
		local item = list[index].item
		if ProfessionOf(item) == profession then
			rows[#rows + 1] = {
				name = item.name or list[index].name or "?",
				count = tonumber(item.count) or 0,
			}
		end
	end
	table.sort(rows, function(a, b)
		if a.count ~= b.count then
			return a.count > b.count
		end
		return tostring(a.name) < tostring(b.name)
	end)
	while limit and #rows > limit do
		table.remove(rows)
	end
	return rows
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

local function RefreshTiles(list)
	local tiles = craftedWidgets.tiles
	if #tiles == 0 then
		return
	end
	local total, kinds = 0, #list
	local professionTotals = ProfessionTotals(list)
	local topProfession, topProfessionCount = TopProfession(professionTotals)
	for index = 1, #list do
		total = total + (tonumber(list[index].item.count) or 0)
	end

	local top = TopItem(list)
	if top then
		SetTile(tiles[1], "x"..ns.FormatNumber(top.item.count or 0), CutRowText(top.item.name or "?", 24))
		tiles[1].tipInfo = TipInfo(top.item.name or "?", {
			{ text = "Crafted "..ns.FormatNumber(top.item.count or 0).." in total" },
			{ text = "Profession: "..ProfessionOf(top.item) },
			{ text = "First "..ns.FormatDate(top.item.firstAt).."  ·  last "..ns.FormatDate(top.item.lastAt) },
		})
	else
		SetTile(tiles[1], "-", "nothing crafted yet")
		tiles[1].tipInfo = nil
	end

	local valuable, value = MostValuable(list)
	if valuable and value > 0 then
		SetTile(tiles[2], ns.MoneyString(value, 15), CutRowText(valuable.item.name or "?", 24))
		tiles[2].tipInfo = TipInfo(valuable.item.name or "?", {
			{ text = ns.MoneyColored(value).." vendor value" },
			{ text = "Crafted "..ns.FormatNumber(valuable.item.count or 0).." in total" },
			{ text = "Profession: "..ProfessionOf(valuable.item) },
		})
	else
		SetTile(tiles[2], "-", "no priced craft yet")
		tiles[2].tipInfo = nil
	end

	if topProfession then
		SetTile(tiles[3], "x"..ns.FormatNumber(topProfessionCount), CutRowText(topProfession, 24))
		tiles[3].tipInfo = TipInfo(topProfession, {
			{ text = ns.FormatNumber(topProfessionCount).." items crafted there" },
			{ text = "Most: "..(CountText(TopCraftedIn(list, topProfession, 4), 4) or "none") },
		})
	else
		SetTile(tiles[3], "-", "no profession yet")
		tiles[3].tipInfo = nil
	end

	if total > 0 then
		SetTile(tiles[4], ns.FormatNumber(total), ns.FormatNumber(kinds)..(kinds == 1 and " kind" or " kinds"))
		tiles[4].tipInfo = TipInfo("Items crafted", {
			{ text = ns.FormatNumber(total).." items in total" },
			{ text = kinds..(kinds == 1 and " different item" or " different items") },
			{ text = "Across "..#professionTotals..(#professionTotals == 1 and " profession" or " professions") },
		})
	else
		SetTile(tiles[4], "-", "nothing crafted yet")
		tiles[4].tipInfo = nil
	end
end

local function GroupedItemRows(list)
	local groups = {}
	local professionNames = {}
	for index = 1, #list do
		local entry = list[index]
		local profession = ProfessionOf(entry.item)
		local group = groups[profession]
		if not group then
			group = { items = {}, total = 0 }
			groups[profession] = group
			professionNames[#professionNames + 1] = profession
		end
		group.items[#group.items + 1] = entry
		group.total = group.total + (tonumber(entry.item.count) or 0)
	end
	table.sort(professionNames, function(a, b)
		return tostring(a) < tostring(b)
	end)

	local rows = {}
	for professionIndex = 1, #professionNames do
		local profession = professionNames[professionIndex]
		local group = groups[profession]
		if #rows > 0 then
			rows[#rows + 1] = {}
		end
		local kinds = #group.items
		rows[#rows + 1] = {
			left = CutRowText(profession, 44),
			right = "x"..ns.FormatNumber(group.total),
			leftColor = ACCENT,
			rightColor = ACCENT,
			tip = {
				kind = "note", title = profession,
				lines = {
					{ text = ns.FormatNumber(group.total).." items crafted" },
					{ text = kinds..(kinds == 1 and " different item" or " different items") },
				},
				key = "craftedProfession|"..tostring(profession),
			},
		}

		table.sort(group.items, function(a, b)
			if craftedWidgets.sort == "name" then
				return tostring(a.item.name) < tostring(b.item.name)
			elseif craftedWidgets.sort == "value" then
				local av, bv = ItemValue(a.item), ItemValue(b.item)
				if av ~= bv then
					return av > bv
				end
			end
			return (tonumber(a.item.count) or 0) > (tonumber(b.item.count) or 0)
		end)

		for itemIndex = 1, #group.items do
			local entry = group.items[itemIndex]
			local item = entry.item
			local value = ItemValue(item)
			local unit = UnitValue(item)
			local tip = TipInfo(item.name or "?", {
				{ text = "Crafted "..ns.FormatNumber(item.count or 0).." in total" },
				{ text = "Profession: "..profession },
				{ text = value > 0 and ("Vendor value: "..ns.MoneyColored(value).." ("..ns.MoneyColored(unit).." each)") or "No vendor value known" },
				{ text = "First "..ns.FormatDate(item.firstAt).."  ·  last "..ns.FormatDate(item.lastAt) },
			}, "Counted from the craft itself, never from loot or a gather.")
			tip.key = "crafted|"..tostring(entry.name)
			rows[#rows + 1] = {
				left = "    "..QualityCode(Quality(item))..CutRowText(item.name or "?", 40).."|r",
				right = "x"..ns.FormatNumber(item.count or 0),
				rightColor = VALUE_COLOR,
				tip = tip,
			}
		end
	end
	return rows
end

local function RefreshLootCrafted()
	local char = DisplayChar()
	local list = CraftedItems(char)
	if not char then
		for index = 1, #craftedWidgets.tiles do
			SetTile(craftedWidgets.tiles[index], "-", "")
			craftedWidgets.tiles[index].tipInfo = nil
		end
		if craftedWidgets.items then
			ShowCardText(craftedWidgets.items, "No character selected.")
		end
		return
	end
	local key = (char.name or "").."|"..(char.realm or "")
	if craftedWidgets.charKey ~= key then
		craftedWidgets.charKey = key
		craftedWidgets.itemsOffset = 0
	end
	RefreshTiles(list)
	if craftedWidgets.items then
		local rows = GroupedItemRows(list)
		if FillScrollingLines(craftedWidgets.items, rows, craftedWidgets, "itemsOffset", "Crafted", 44) == 0 then
			ShowCardText(craftedWidgets.items, "No crafted items recorded yet. Craft something with the profession window open.")
		end
	end
end

local function AddCardBehaviour(card, offsetField)
	AddCardScrollbar(card, craftedWidgets, offsetField, RefreshLootCrafted)
	MakeCardScrollable(card, craftedWidgets, offsetField, RefreshLootCrafted)
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

local function BuildLootCrafted(frame)
	CreateTileRow(frame, -4, { "Most crafted", "Most valuable", "Top profession", "Items crafted" }, craftedWidgets.tiles, false)
	for index = 1, #craftedWidgets.tiles do
		AddTip(craftedWidgets.tiles[index])
	end

	local items = CreateListCard(frame, 0, -88, 730, 338, "Crafted")
	craftedWidgets.items = items
	AddCardTitleNote(items, "Crafted",
		"Every item this character has crafted, plus the materials gained by disenchanting, grouped under the profession that produced it. Each heading shows the profession's total; the items below show how many of each were made or gained. Looted and gathered items are never added. The corner button orders the items inside each profession by most crafted, most valuable or A-Z.")
	AddCardBehaviour(items, "itemsOffset")

	local sortButton = CreateCornerButton(items)
	local function SortLabel()
		return SORT_LABEL[craftedWidgets.sort] or "most crafted"
	end
	SetCornerLabel(sortButton, SortLabel())
	sortButton:SetScript("OnClick", function()
		for index = 1, #SORT_ORDER do
			if SORT_ORDER[index] == craftedWidgets.sort then
				craftedWidgets.sort = SORT_ORDER[index % #SORT_ORDER + 1]
				break
			end
		end
		SetCornerLabel(sortButton, SortLabel())
		craftedWidgets.itemsOffset = 0
		RefreshLootCrafted()
	end)
	sortButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Order of the items", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to order the items inside each profession: most crafted, most valuable or A-Z.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	sortButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	RefreshLootCrafted()
end

ns.BuildLootCrafted = BuildLootCrafted
ns.RefreshLootCrafted = RefreshLootCrafted
ns.lootCraftedWidgets = craftedWidgets
