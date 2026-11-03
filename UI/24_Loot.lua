-- Tally - the Loot tab: what was picked up, by quality and by value.
local addonName, ns = ...

-- Helpers and constants from the files loaded above (see Tally.toc).
local ACCENT, TILE_WIDTH, TILE_HEIGHT, TILE_GAP, CreateTile, SetTile, CreateTileRow, DisplayChar, QUALITY_NAMES, QUALITY_COLORS, PercentText, QualityCode, ItemQuality, CreateListCard, ROW_STEP, FillCardRows, ShowCardText, ShortWhen, CutRowText, AddCardTitleNote, FillScrollingLines, MakeCardScrollable, pageRefresh =
	ns.ACCENT, ns.TILE_WIDTH, ns.TILE_HEIGHT, ns.TILE_GAP, ns.CreateTile, ns.SetTile, ns.CreateTileRow, ns.DisplayChar, ns.QUALITY_NAMES, ns.QUALITY_COLORS, ns.PercentText, ns.QualityCode, ns.ItemQuality, ns.CreateListCard, ns.ROW_STEP, ns.FillCardRows, ns.ShowCardText, ns.ShortWhen, ns.CutRowText, ns.AddCardTitleNote, ns.FillScrollingLines, ns.MakeCardScrollable, ns.pageRefresh
local BuildLootGathered, RefreshLootGathered = ns.BuildLootGathered, ns.RefreshLootGathered
local BuildLootCrafted, RefreshLootCrafted = ns.BuildLootCrafted, ns.RefreshLootCrafted
-------------------------------------------------------------------------------
-- Loot page
-------------------------------------------------------------------------------

local lootWidgets = { tiles = {}, view = "value" }
local CreateCornerButton, SetCornerLabel = ns.CreateCornerButton, ns.SetCornerLabel

-- How many rows the loot card holds: FillCardRows draws
-- floor((height - 46) / ROW_STEP) of them, and the two blocks on the card
-- are laid out to fit that many exactly.
local function LootCardRows()
	local card = lootWidgets.quality
	local step = card.rowStep or ROW_STEP
	return math.max(1, math.floor((card:GetHeight() - 46) / step))
end

local function RefreshLoot()
	if not lootWidgets.quality then
		return
	end
	local char = DisplayChar()
	if not char then
		for index = 1, #lootWidgets.tiles do
			SetTile(lootWidgets.tiles[index], "-", "")
		end
		ShowCardText(lootWidgets.quality, "No data yet.")
		ShowCardText(lootWidgets.best, "No data yet.")
		SetTile(lootWidgets.session[1], "-", "")
		SetTile(lootWidgets.session[2], "-", "")
		SetTile(lootWidgets.qualityBoxes[1], "-", "")
		SetTile(lootWidgets.qualityBoxes[2], "-", "")
		if lootWidgets.tiles[4] then
			lootWidgets.tiles[4].tipInfo = nil
			if lootWidgets.tiles[4].subRight then
				lootWidgets.tiles[4].subRight:SetText("")
			end
		end
		return
	end

	local loot = char.loot
	local valued = (ns.itemValueAvailable ~= false)
	local best = loot.best[1]
	local liveSession = (not ns.IsViewing()) and char.sessions.current or nil
	SetTile(lootWidgets.session[1], liveSession and ns.FormatNumber(liveSession.items or 0) or "-", liveSession and (ns.FormatDuration(liveSession.seconds, true).." so far") or "no session active")
	if not valued then
		SetTile(lootWidgets.session[2], "-", "item values unavailable here")
	elseif liveSession then
		SetTile(lootWidgets.session[2], ns.MoneyString(liveSession.itemValue or 0, 15), "vendor value of this session's loot")
	else
		SetTile(lootWidgets.session[2], "-", "no session active")
	end
	SetTile(lootWidgets.tiles[1], ns.FormatNumber(loot.items), "since "..ns.FormatDate(char.created))
	if valued then
		SetTile(lootWidgets.tiles[2], ns.MoneyString(loot.value, 15), "")
		SetTile(lootWidgets.tiles[3], best and ns.MoneyString(best.value, 15) or "-", best and (QualityCode(ItemQuality(best))..(best.name or "?").."|r") or "nothing valuable yet")
	else
		SetTile(lootWidgets.tiles[2], "-", "item values unavailable here")
		SetTile(lootWidgets.tiles[3], "-", "item values unavailable here")
	end

	-- loot.qualityUnknown counts items whose quality was never recorded.
	-- They stay in loot.items but get a dim row of their own, and the
	-- quality percentages are measured against knownItems only.
	local unknown = loot.qualityUnknown or 0
	local knownItems = (loot.items or 0) - unknown
	-- One card, two blocks: what was looted by quality, then the items
	-- looted most often. Tally's own heading rows keep the blocks apart,
	-- in the same orange as the other lists' headings, since a quality row
	-- carries no heading of its own.
	local entries = { { left = "By quality:", leftColor = ACCENT } }
	for quality = 6, 0, -1 do
		local count = loot.quality[quality] or 0
		if count > 0 then
			entries[#entries + 1] = {
				left = QUALITY_NAMES[quality],
				leftColor = QUALITY_COLORS[quality],
				right = count.."  ·  "..PercentText(count, knownItems),
			}
		end
	end
	if unknown > 0 then
		entries[#entries + 1] = {
			left = ns.FormatNumber(unknown).." earlier items",
			leftColor = QUALITY_COLORS[0],
			right = "quality unknown",
			rightColor = QUALITY_COLORS[0],
		}
	end
	-- The items looted most often, by count, ties read alphabetically so a
	-- refresh does not shuffle them.
	local top = {}
	for id, tally in pairs(loot.itemCounts or {}) do
		local lower, estimated = ns.loot.TallyCount(tally)
		top[#top + 1] = { id = id, name = tally.name or "?", count = tally.count or 0, lower = lower, estimated = estimated }
	end
	table.sort(top, function(a, b)
		if a.count == b.count then
			return a.name < b.name
		end
		return a.count > b.count
	end)
	-- The card holds so many rows; the quality block is drawn in full, and
	-- the five items take what is left of them. A count that came from the
	-- top-40 sketch's inherited figure is shown as a lower bound.
	local room = LootCardRows() - #entries - 1
	if room > 0 and #top > 0 then
		entries[#entries + 1] = { left = "Top looted items:", leftColor = ACCENT }
		for index = 1, math.min(5, room, #top) do
			local item = top[index]
			local _, _, quality = ns.ItemInfo(item.id)
			entries[#entries + 1] = {
				left = item.name,
				leftColor = QUALITY_COLORS[quality] or QUALITY_COLORS[1],
				right = (item.estimated and "at least x" or "x")..ns.FormatNumber(item.lower),
			}
		end
	end
	if FillCardRows(lootWidgets.quality, entries, 48) == 0 then
		ShowCardText(lootWidgets.quality, "No loot recorded yet.")
	end

	-- Item on the left, vendor value and time on the right; ShortWhen gives a
	-- clock time for today's finds and a date for older ones. The card has two
	-- views: the 50 most valuable finds, and the last 50 individual drops.
	local bestEntries = {}
	local bestTitle = "Most valuable finds"
	if lootWidgets.view == "recent" then
		bestTitle = "Most recent loot"
		local recent = loot.recent or {}
		for index = #recent, 1, -1 do
			local entry = recent[index]
			local _, _, quality, sellPrice = ns.ItemInfo(entry.id)
			local value = sellPrice and sellPrice * (entry.count or 1) or nil
			local name = entry.name or "?"
			if (entry.count or 1) > 1 then
				name = name.." x"..entry.count
			end
			bestEntries[#bestEntries + 1] = {
				left = name,
				leftColor = QUALITY_COLORS[quality or entry.quality or 1] or QUALITY_COLORS[1],
				right = (value and ns.MoneyColored(value) or "no price").."  ·  "..ShortWhen(entry.at),
			}
		end
	else
		for index = 1, #loot.best do
			local entry = loot.best[index]
			bestEntries[#bestEntries + 1] = {
				left = entry.name or "?",
				leftColor = QUALITY_COLORS[ItemQuality(entry)] or QUALITY_COLORS[1],
				right = ns.MoneyColored(entry.value).."  ·  "..ShortWhen(entry.at),
			}
		end
	end
	if FillScrollingLines(lootWidgets.best, bestEntries, lootWidgets, "bestScrollOffset", bestTitle, 22) == 0 then
		if lootWidgets.view == "recent" then
			ShowCardText(lootWidgets.best, "Nothing looted yet.")
		elseif not valued then
			ShowCardText(lootWidgets.best, "This game does not give addons item values, so Tally cannot work out what loot is worth. The count and the quality breakdown are unaffected; values stay blank.")
		else
			ShowCardText(lootWidgets.best, "Nothing with a sell value has been looted yet.")
		end
	end

	-- The item looted most often, in the headline row with the other figures:
	-- its combined vendor value as the figure, and "N × name" under it in the
	-- item's quality colour. The client's item cache is asked for the price;
	-- an item it will no longer price keeps its count and says the value is
	-- not available rather than showing a figure from anywhere else.
	local favourite, favouriteUpper = nil, 0
	for id, tally in pairs(loot.itemCounts or {}) do
		local upper = tally.count or 0
		local lower, estimated = ns.loot.TallyCount(tally)
		local betterTie = (upper == favouriteUpper) and favourite
			and (tally.name or "") < (favourite.name or "")
		if upper > favouriteUpper or betterTie then
			favourite = { id = id, name = tally.name, count = lower, estimated = estimated }
			favouriteUpper = upper
		end
	end
	if favourite then
		local _, _, quality, sellPrice = ns.ItemInfo(favourite.id)
		local name = QualityCode(quality)..CutRowText(favourite.name or "?", 17).."|r"
		local count = ns.FormatNumber(favourite.count)
		local tile = lootWidgets.tiles[4]
		if not tile.subRight then
			-- The count reads from the tile's left edge and the pile's value
			-- from the right, so the two never run together.
			tile.subRight = tile:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			tile.subRight:SetPoint("TOPRIGHT", -10, -42)
			tile.subRight:SetJustifyH("RIGHT")
			tile.subRight:SetTextColor(0.55, 0.55, 0.55)
		end
		SetTile(tile, name, (favourite.estimated and "at least " or "")..count.." looted",
			QUALITY_COLORS[quality] or QUALITY_COLORS[1])
		-- The game's own item cache does the pricing. An item it will no
		-- longer price says so rather than carrying a figure from elsewhere.
		tile.subRight:SetText(sellPrice and ns.MoneyString(sellPrice * favourite.count, 11) or "no price")
		-- The hover carries the same, in full: the tile's name may be cut.
		tile.tipInfo = {
			name = favourite.name or "?", quality = quality, count = favourite.count,
			estimated = favourite.estimated,
			value = sellPrice and (sellPrice * favourite.count) or nil,
			each = sellPrice,
		}
	else
		SetTile(lootWidgets.tiles[4], "-", "nothing looted yet")
		lootWidgets.tiles[4].tipInfo = nil
		if lootWidgets.tiles[4].subRight then
			lootWidgets.tiles[4].subRight:SetText("")
		end
	end

	-- The two rarest qualities the character has looted: rare and epic, or -
	-- once a legendary has dropped - epic and legendary, so the pair always
	-- shows the rarest things this character actually has.
	local legendary = loot.quality[5] or 0
	local boxes = {
		{ quality = legendary > 0 and 4 or 3 },
		{ quality = legendary > 0 and 5 or 4 },
	}
	for index = 1, #boxes do
		local spec = boxes[index]
		local tile = lootWidgets.qualityBoxes[index]
		tile.label:SetText(QUALITY_NAMES[spec.quality].." items")
		local count = loot.quality[spec.quality] or 0
		if count > 0 then
			SetTile(tile, ns.FormatNumber(count), PercentText(count, knownItems).." of the items read", QUALITY_COLORS[spec.quality])
		else
			SetTile(tile, "0", "none yet", QUALITY_COLORS[spec.quality])
		end
	end
end

local function BuildLootContent(content)
	CreateTileRow(content, -4, { "Items looted", "Total vendor value", "Most valuable find", "Most looted item" }, lootWidgets.tiles, false)
	lootWidgets.quality = CreateListCard(content, 0, -88, 359, 250, "Looted")
	lootWidgets.best = CreateListCard(content, 371, -88, 359, 250, "Most valuable finds")
	AddCardTitleNote(lootWidgets.quality, "Looted",
		"Every item this character loots, by quality and then the five items looted most often; grey and quest items are left out of the ranking. Other players' loot lines are not counted.")
	AddCardTitleNote(lootWidgets.best, "Most valuable finds",
		"The 50 most valuable items looted, priced at what a vendor would pay for one; the date is when it dropped. The corner button switches to the last 50 individual drops.")
	-- The same card, two views: value and recency. It keeps its own scroll
	-- position per view so switching back does not lose the place.
	local viewButton = CreateCornerButton(lootWidgets.best)
	SetCornerLabel(viewButton, "most valuable")
	viewButton:SetScript("OnClick", function()
		if lootWidgets.view == "recent" then
			lootWidgets.view = "value"
			SetCornerLabel(viewButton, "most valuable")
		else
			lootWidgets.view = "recent"
			SetCornerLabel(viewButton, "recent loot")
		end
		lootWidgets.bestScrollOffset = 0
		RefreshLoot()
	end)
	viewButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Which finds", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Switch between the 50 most valuable items and the last 50 individual drops. Both list one item per row with its value and the time it dropped.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	viewButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	-- Every find is kept, so the card takes the wheel like the other lists.
	MakeCardScrollable(lootWidgets.best, lootWidgets, "bestScrollOffset", RefreshLoot)

	-- Two session tiles under the quality card: what this session has looted
	-- and what that loot would sell for. They are per session, so a viewed
	-- character (which has no session running) shows dashes.
	lootWidgets.session = {}
	local sessionLabels = { "Loot this session", "Session value" }
	for index = 1, 2 do
		local tile = CreateTile(content, sessionLabels[index])
		tile:SetSize(TILE_WIDTH, TILE_HEIGHT)
		tile:SetPoint("TOPLEFT", content, "TOPLEFT", (index - 1) * (TILE_WIDTH + TILE_GAP), -346)
		lootWidgets.session[index] = tile
	end

	-- Two quality boxes under Best finds, side by side, the same width as the
	-- session tiles: the two rarest qualities the character has looted. The
	-- labels are set at refresh time, since a legendary moves the pair up.
	lootWidgets.qualityBoxes = {}
	for index = 1, 2 do
		local tile = CreateTile(content, index == 1 and "Rare items" or "Epic items")
		tile:SetSize(TILE_WIDTH, TILE_HEIGHT)
		tile:SetPoint("TOPLEFT", content, "TOPLEFT", 371 + (index - 1) * (TILE_WIDTH + TILE_GAP), -346)
		lootWidgets.qualityBoxes[index] = tile
	end
	-- The most looted tile's name can be longer than the tile, so its hover
	-- carries the whole name, the count and the pile's value as well.
	local mostTile = lootWidgets.tiles[4]
	mostTile:EnableMouse(true)
	mostTile:SetScript("OnEnter", function(self)
		local info = self.tipInfo
		if not info then
			return
		end
		local color = QUALITY_COLORS[info.quality] or QUALITY_COLORS[1]
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(info.name, color[1], color[2], color[3])
		GameTooltip:AddLine((info.estimated and "at least " or "")..ns.FormatNumber(info.count).." looted", 1, 1, 1)
		if info.value then
			GameTooltip:AddLine("Pile value: "..ns.MoneyColored(info.value).." ("..ns.MoneyColored(info.each or 0).." each)", 1, 1, 1)
		else
			GameTooltip:AddLine("The game will not price this item now, so the pile has no figure.", 0.7, 0.7, 0.7, true)
		end
		GameTooltip:Show()
	end)
	mostTile:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

local function SelectLootSubview(name)
	lootWidgets.subview = name
	if lootWidgets.lootedFrame then
		lootWidgets.lootedFrame:SetShown(name == "looted")
	end
	if lootWidgets.gatheredFrame then
		lootWidgets.gatheredFrame:SetShown(name == "gathered")
	end
	if lootWidgets.craftedFrame then
		lootWidgets.craftedFrame:SetShown(name == "crafted")
	end
	-- The Gathered view selector belongs to the Gathered page only.
	local viewButton = ns.lootGatheredWidgets and ns.lootGatheredWidgets.button
	if viewButton then
		viewButton:SetShown(name == "gathered")
	end
	local buttons = lootWidgets.subButtons or {}
	for id, button in pairs(buttons) do
		local active = (id == name)
		button.underline:SetShown(active)
		button.text:SetTextColor(active and ACCENT[1] or 0.62, active and ACCENT[2] or 0.62, active and ACCENT[3] or 0.62)
	end
	if name == "gathered" and RefreshLootGathered then
		RefreshLootGathered()
	elseif name == "crafted" and RefreshLootCrafted then
		RefreshLootCrafted()
	else
		RefreshLoot()
	end
end

local function RefreshLootPage()
	if lootWidgets.subview == "gathered" and RefreshLootGathered then
		RefreshLootGathered()
	elseif lootWidgets.subview == "crafted" and RefreshLootCrafted then
		RefreshLootCrafted()
	else
		RefreshLoot()
	end
end

local function BuildLootPage(page)
	lootWidgets.subButtons = {}
	lootWidgets.subview = "looted"
	local x = 2
	local function AddSubButton(id, title)
		local button = CreateFrame("Button", nil, page)
		button:SetHeight(18)
		button.text = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		button.text:SetPoint("LEFT", 0, 0)
		button.text:SetText(title)
		button:SetWidth(button.text:GetStringWidth() + 20)
		button:SetPoint("TOPLEFT", page, "TOPLEFT", x, -2)
		button.underline = button:CreateTexture(nil, "ARTWORK")
		button.underline:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
		button.underline:SetHeight(2)
		button.underline:SetPoint("TOPLEFT", button.text, "BOTTOMLEFT", -2, -2)
		button.underline:SetPoint("TOPRIGHT", button.text, "BOTTOMRIGHT", 2, -2)
		button:RegisterForClicks("LeftButtonUp")
		button:SetScript("OnClick", function()
			SelectLootSubview(id)
		end)
		lootWidgets.subButtons[id] = button
		x = x + button:GetWidth() + 10
	end
	AddSubButton("looted", "Looted")
	AddSubButton("gathered", "Gathered")
	AddSubButton("crafted", "Crafted")

	local looted = CreateFrame("Frame", nil, page)
	looted:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	looted:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	lootWidgets.lootedFrame = looted
	BuildLootContent(looted)

	local gathered = CreateFrame("Frame", nil, page)
	gathered:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	gathered:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	gathered:Hide()
	lootWidgets.gatheredFrame = gathered
	if BuildLootGathered then
		BuildLootGathered(gathered)
	end

	local crafted = CreateFrame("Frame", nil, page)
	crafted:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	crafted:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	crafted:Hide()
	lootWidgets.craftedFrame = crafted
	if BuildLootCrafted then
		BuildLootCrafted(crafted)
	end

	SelectLootSubview("looted")
	pageRefresh.loot = RefreshLootPage
end

-- Handed to the shell, which builds and refreshes every tab.
ns.BuildLootPage, ns.RefreshLoot = BuildLootPage, RefreshLoot
ns.RefreshLootPage = RefreshLootPage
