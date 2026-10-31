-- Tally - the auction house view, shared by the Economy tab and the Total tab.
--
-- One page, two homes: under Economy it describes the character being shown,
-- under Total it describes every ticked character at once. The page itself is
-- built here so the two can never drift apart; each mount hands in the list of
-- characters it should read and says whether the character column belongs.
--
-- The figures come from Auction.lua through ns.AuctionReport. This file draws
-- them and holds the two choices the reader makes: the day range and the order
-- of the top list. Nothing here writes to a character's record.
local addonName, ns = ...

local ACCENT, TILE_WIDTH, TILE_HEIGHT, TILE_GAP, ROW_STEP, QUALITY_COLORS, GREEN, RED, AMBER, VALUE_COLOR, ROW_DIM,
	ClassColorCode, DisplayChar, CreateTile, CreateTileRow, SetTile, CreateListCard, FillCardRows, FillScrollingLines,
	ShowCardText, MakeCardScrollable, CreateCornerButton, SetCornerLabel, AddCardTitleNote, QualityCode, CutRowText,
	ShortWhen, ShowCharPicker, charPickers =
	ns.ACCENT, ns.TILE_WIDTH, ns.TILE_HEIGHT, ns.TILE_GAP, ns.ROW_STEP, ns.QUALITY_COLORS, ns.GREEN, ns.RED, ns.AMBER, ns.VALUE_COLOR, ns.ROW_DIM,
	ns.ClassColorCode, ns.DisplayChar, ns.CreateTile, ns.CreateTileRow, ns.SetTile, ns.CreateListCard, ns.FillCardRows, ns.FillScrollingLines,
	ns.ShowCardText, ns.MakeCardScrollable, ns.CreateCornerButton, ns.SetCornerLabel, ns.AddCardTitleNote, ns.QualityCode, ns.CutRowText,
	ns.ShortWhen, ns.ShowCharPicker, ns.charPickers

-------------------------------------------------------------------------------
-- Choices
-------------------------------------------------------------------------------

-- The day ranges the button walks, in the order it walks them. The label is
-- what the button and the boxes say; `days` is what AuctionReport reads.
-- There is no all-time stop: the first list a session seeds with could hold
-- years of auctions, and 30 days is as far back as the card is meant to go.
local PERIODS = {
	{ days = 30, label = "30 days" },
	{ days = 14, label = "14 days" },
	{ days = 7, label = "7 days" },
	{ days = 3, label = "3 days" },
	{ days = 1, label = "today" },
}

local SORTS = {
	{ id = "sold", label = "by amount sold" },
	{ id = "income", label = "by income" },
	{ id = "bought", label = "recent buys" },
}

-- The recent list's filter. It only hides the other kinds; the date window
-- and the stored rows are the same for every choice.
local EVENT_FILTERS = {
	{ id = "all", label = "all events" },
	{ id = "sold", label = "sold" },
	{ id = "posted", label = "posted" },
	{ id = "expired", label = "expired" },
}

local function EventFilterLabel(mode)
	for index = 1, #EVENT_FILTERS do
		if EVENT_FILTERS[index].id == mode then
			return EVENT_FILTERS[index].label
		end
	end
	return EVENT_FILTERS[1].label
end

local function NextEventFilter(mode)
	for index = 1, #EVENT_FILTERS do
		if EVENT_FILTERS[index].id == mode then
			return EVENT_FILTERS[index % #EVENT_FILTERS + 1].id
		end
	end
	return EVENT_FILTERS[1].id
end

local function PeriodAt(index)
	return PERIODS[index] or PERIODS[1]
end

local function PeriodIndex(store)
	local days = store.days or 0
	for index = 1, #PERIODS do
		if PERIODS[index].days == days then
			return index
		end
	end
	return 1
end

local function SortLabel(mode)
	for index = 1, #SORTS do
		if SORTS[index].id == mode then
			return SORTS[index].label
		end
	end
	return SORTS[1].label
end

local function NextSort(mode)
	for index = 1, #SORTS do
		if SORTS[index].id == mode then
			return SORTS[index % #SORTS + 1].id
		end
	end
	return SORTS[1].id
end

-------------------------------------------------------------------------------
-- Numbers
-------------------------------------------------------------------------------

local BAND_NAMES = { "short", "medium", "long", "very long" }

-- A remaining time in words. Days are kept separate from hours, since an
-- auction can run for two days and "49h" says less.
local function RemainingText(seconds)
	seconds = math.max(0, seconds or 0)
	if seconds < 60 then
		return "under a minute"
	end
	local days = math.floor(seconds / 86400)
	local hours = math.floor((seconds % 86400) / 3600)
	local minutes = math.floor((seconds % 3600) / 60)
	if days > 0 then
		return days.."d "..hours.."h"
	elseif hours > 0 then
		return hours.."h "..minutes.."m"
	end
	return minutes.."m"
end

-- A live row: what is up, its asking price and how long it has left. The
-- countdown is worked out from the moment the list was read; a list that
-- states only a band (the classic one) keeps the band word instead.
local function LiveRowText(row, now)
	local parts = {}
	if row.units and row.units > 1 then
		parts[#parts + 1] = "x"..ns.FormatNumber(row.units)
	end
	if row.buyout and row.buyout > 0 then
		parts[#parts + 1] = ns.MoneyColored(row.buyout)
	elseif row.bid and row.bid > 0 then
		parts[#parts + 1] = ns.MoneyColored(row.bid).." bid"
	end
	if row.expiresAt then
		parts[#parts + 1] = RemainingText(row.expiresAt - now)
	elseif row.band then
		parts[#parts + 1] = BAND_NAMES[row.band] or "unknown"
	end
	return table.concat(parts, "  ·  ")
end

-- The item's quality, from the record or from the game's cache. A sale
-- invoice names its item but states no quality, so rows recorded from one
-- borrow the colour the game gives the name.
local ItemQuality = ns.ItemQuality
local CutTextToWidth = ns.CutTextToWidth

-- An item's name as a row draws it, in its quality colour. A posting written
-- before the game named the item has neither a name nor an id, so it says so
-- rather than showing a question mark that could be mistaken for one.
local function ColoredItemName(entry)
	local name = entry.name
	if not name or name == "?" then
		return "|cff8a8a8a(name not read)|r"
	end
	return QualityCode(ItemQuality(entry))..name.."|r"
end

local function ItemLabel(entry, width)
	local name = entry.name
	if not name or name == "?" then
		return "|cff8a8a8a(name not read)|r"
	end
	return QualityCode(ItemQuality(entry))..CutTextToWidth(name, width).."|r"
end

-- What one item fetched, from the sales Tally recorded. A single sale gives
-- one figure; several give the recorded range and how many sales it covers.
local function PriceEachText(row)
	local units = row.units or 0
	if units <= 0 then
		return nil
	end
	local average = (row.income or 0) / units
	local low, high = row.unitMin, row.unitMax
	if low and high then
		if math.abs(high - low) < 1 then
			return "Price each "..ns.MoneyColored(math.floor(average))
		end
		local text = "Price each "..ns.MoneyColored(math.floor(low))
			.." to "..ns.MoneyColored(math.floor(high))
		if (row.unitKnown or 0) < (row.sales or 0) then
			text = text.." recorded ("..ns.FormatNumber(row.unitKnown or 0)
				.." of "..ns.FormatNumber(row.sales or 0).." sales)"
		end
		return text.."  ·  average "..ns.MoneyColored(math.floor(average))
	end
	return "Average "..ns.MoneyColored(math.floor(average))
		.." each; no per-sale prices were recorded"
end

-- The Still up box, from the last list the game gave. It is drawn apart from
-- the rest of the page so it can run down by itself: the count and the
-- nearest end are read again every half minute, not only on a redraw.
local function RefreshLiveTile(store)
	local widgets = store.widgets
	local report = store.report
	if not widgets or not widgets.live or not report then
		return
	end
	local now = ns.Now()
	local count, earliest = 0, nil
	for index = 1, #report.live do
		local row = report.live[index]
		if not row.expiresAt or row.expiresAt > now then
			count = count + 1
			if row.expiresAt and (not earliest or row.expiresAt < earliest) then
				earliest = row.expiresAt
			end
		end
	end
	count = count + (report.liveUnlisted or 0)
	local sub
	if count == 0 then
		sub = report.liveAt > 0 and "none up" or "open the auction house"
	elseif earliest then
		sub = "next ends in "..RemainingText(earliest - now)
	elseif report.liveAt > 0 then
		sub = "as seen "..ShortWhen(report.liveAt)
	else
		sub = "open the auction house"
	end
	SetTile(widgets.live, ns.FormatNumber(count), sub)
end

-------------------------------------------------------------------------------
-- The page
-------------------------------------------------------------------------------

-- Every mounted page, so a tick in the one character picker redraws both.
local auctionStores = {}

local function Refresh(store)
	local widgets = store.widgets
	if not widgets.posted then
		return
	end
	-- If the auction house is open, this keeps the live list fresh even on a
	-- client that never raised the show event.
	if ns.AuctionPollLive then
		ns.AuctionPollLive()
	end
	local report = ns.AuctionReport(store.list(), store.days)
	store.report = report
	local totals = report.totals
	local period = PeriodAt(PeriodIndex(store))

	-- Tile row 1: the figures the day button filters, plus the dearest sale
	-- the character has ever had (which is not a figure for a range).
	local returned = {}
	if totals.expired > 0 then
		returned[#returned + 1] = ns.FormatNumber(totals.expired).." expired"
	end
	if totals.cancelled > 0 then
		returned[#returned + 1] = ns.FormatNumber(totals.cancelled).." cancelled"
	end
	SetTile(widgets.posted, ns.FormatNumber(totals.posted),
		#returned > 0 and table.concat(returned, " · ") or "nothing returned")
	SetTile(widgets.sold, ns.FormatNumber(totals.sold),
		totals.units > 0 and (ns.FormatNumber(totals.units)..(totals.units == 1 and " item" or " items")) or "no sales yet")
	SetTile(widgets.income, ns.MoneyString(totals.received, 15),
		totals.cut > 0 and ("after "..ns.MoneyColored(totals.cut).." cut") or "")
	if report.best then
		SetTile(widgets.best, ns.MoneyString(report.best.price or 0, 15),
			QualityCode(ItemQuality(report.best))..CutRowText(report.best.name or "?", 18).."|r")
	else
		SetTile(widgets.best, "-", "nothing sold yet")
	end

	-- Tile row 2: the buying side, and what is up now. The purchases follow
	-- the same day button as the sales above; the two "ever" boxes do not,
	-- and say so.
	SetTile(widgets.spent, ns.MoneyString(totals.spent, 15), "spent at the auction house")
	if report.bestBuy then
		SetTile(widgets.biggestBuy, ns.MoneyString(report.bestBuy.price or 0, 15),
			QualityCode(ItemQuality(report.bestBuy))..CutRowText(report.bestBuy.name or "?", 18).."|r")
	else
		SetTile(widgets.biggestBuy, "-", "nothing bought yet")
	end
	local mostBought, mostBoughtUnits = nil, 0
	for index = 1, #report.items do
		local row = report.items[index]
		if (row.bought or 0) > mostBoughtUnits then
			mostBought, mostBoughtUnits = row, row.bought or 0
		end
	end
	if mostBought then
		SetTile(widgets.mostBought,
			QualityCode(ItemQuality(mostBought))..CutRowText(mostBought.name or "?", 16).."|r",
			ns.FormatNumber(mostBoughtUnits).." bought")
	else
		SetTile(widgets.mostBought, "-", "nothing bought yet")
	end

	-- Three of the boxes name an item, so they answer a hover with its own
	-- tooltip; the two "ever" boxes state what the sale and the purchase
	-- were made of, and the Most bought box what the whole pile cost.
	widgets.best.tipItem = report.best and { name = report.best.name, id = report.best.id } or nil
	if report.best then
		local units = math.max(1, report.best.units or 1)
		local price = report.best.price or 0
		local lines = {
			{ text = "x"..ns.FormatNumber(units).." sold for "..ns.MoneyColored(price) },
		}
		if report.best.at then
			lines[#lines + 1] = {
				text = "Sold on "..ns.FormatDate(report.best.at),
				color = ROW_DIM,
			}
		end
		if price > 0 and units > 0 then
			lines[#lines + 1] = {
				text = "Price each "..ns.MoneyColored(math.floor(price / units)),
				color = VALUE_COLOR,
			}
		end
		if report.best.cut ~= nil then
			local after = math.max(0, price - (report.best.cut or 0))
			lines[#lines + 1] = {
				text = "After the cut "..ns.MoneyColored(after)
					..(units > 1 and ("  ·  "..ns.MoneyColored(math.floor(after / units)).." each") or ""),
				color = GREEN,
			}
		elseif units > 1 then
			lines[#lines + 1] = {
				text = "Before the cut "..ns.MoneyColored(math.floor(price / units)).." each",
				color = ROW_DIM,
			}
		end
		widgets.best.tipExtra = lines
	else
		widgets.best.tipExtra = nil
	end
	widgets.biggestBuy.tipItem = report.bestBuy and { name = report.bestBuy.name, id = report.bestBuy.id } or nil
	if report.bestBuy then
		local units = math.max(1, report.bestBuy.units or 1)
		local price = report.bestBuy.price or 0
		widgets.biggestBuy.tipExtra = {
			{ text = "x"..ns.FormatNumber(units).." bought for "..ns.MoneyColored(price)
				..(units > 1 and ("  ·  "..ns.MoneyColored(math.floor(price / units)).." each") or "") },
		}
	else
		widgets.biggestBuy.tipExtra = nil
	end
	if mostBought then
		widgets.mostBought.tipItem = { name = mostBought.name, id = mostBought.id }
		widgets.mostBought.tipExtra = {
			{ text = ns.FormatNumber(mostBoughtUnits).." bought for "..ns.MoneyColored(mostBought.cost or 0) },
			{ text = "Average "..ns.MoneyColored((mostBought.cost or 0) / math.max(1, mostBoughtUnits)).." each" },
		}
	else
		widgets.mostBought.tipItem = nil
		widgets.mostBought.tipExtra = nil
	end
	RefreshLiveTile(store)

	-- The live tile carries the list of what is up, since there is no room
	-- for a card of its own: a hover names each auction and its asking price.
	widgets.live.tipRows = report.live
	widgets.live.tipAt = report.liveAt

	-- The card shows either one row per item sold (three orders) or the most
	-- recent purchases, which is the fourth order of the same button.
	local topRows = {}
	local topTitle = "Top auctions"
	if store.sort == "bought" then
		topTitle = "Recent purchases"
		for index = 1, #report.buys do
			local buy = report.buys[index]
			local left = ""
			if store.combined and buy.who then
				left = (ClassColorCode(buy.classFile) or "")..CutRowText(buy.who, 8).."|r  "
			end
			left = left..ItemLabel(buy, store.combined and 120 or 180)
			topRows[#topRows + 1] = {
				left = left,
				mid = ShortWhen(buy.at),
				right = ns.MoneyColored(buy.price or 0),
				-- The item's own tooltip, as the game draws it, so a hover
				-- says what the thing is rather than repeating the figures
				-- already on the row.
				tip = {
					kind = "item",
					name = buy.name,
					id = buy.id,
					key = tostring(buy.at).."|"..tostring(buy.name).."|buy",
				},
			}
		end
	else
		local items = {}
		for index = 1, #report.items do
			-- This card is about what sold. A row that was only ever bought
			-- is kept for the Most bought box, but does not belong here with
			-- an x0 and a 0c on it.
			local row = report.items[index]
			if (row.sales or 0) > 0 then
				items[#items + 1] = row
			end
		end
		table.sort(items, function(a, b)
			if store.sort == "sold" then
				if (a.units or 0) ~= (b.units or 0) then
					return (a.units or 0) > (b.units or 0)
				end
			elseif (a.received or 0) ~= (b.received or 0) then
				return (a.received or 0) > (b.received or 0)
			end
			if (a.received or 0) ~= (b.received or 0) then
				return (a.received or 0) > (b.received or 0)
			end
			return (a.name or "") < (b.name or "")
		end)

		for index = 1, #items do
			local row = items[index]
			local tipLines = {
				{ text = ns.FormatNumber(row.sales or 0)..(row.sales == 1 and " sale" or " sales").."  ·  "
					..ns.FormatNumber(row.units or 0)..(row.units == 1 and " item" or " items"), color = VALUE_COLOR },
				{ text = "Sold for "..ns.MoneyColored(row.income or 0), color = VALUE_COLOR },
			}
			local priceLine = PriceEachText(row)
			if priceLine then
				tipLines[#tipLines + 1] = { text = priceLine, color = VALUE_COLOR }
			end
			tipLines[#tipLines + 1] = { text = "House cut "..ns.MoneyColored(row.cut or 0), color = ROW_DIM }
			tipLines[#tipLines + 1] = {
				text = "After the cut "..ns.MoneyColored((row.income or 0) - (row.cut or 0))
					..((row.units or 0) > 1 and ("  ·  "..ns.MoneyColored(
						math.floor(((row.income or 0) - (row.cut or 0)) / row.units)).." each") or ""), color = GREEN }
			tipLines[#tipLines + 1] = { text = "Total income "..ns.MoneyColored(row.received or 0), color = GREEN }
			tipLines[#tipLines + 1] = {
				text = "Dearest sale "..ns.MoneyColored(row.best or 0)..(row.bestAt and (" on "..ns.FormatDate(row.bestAt)) or ""), color = ROW_DIM }
			if row.bought and row.bought > 0 then
				tipLines[#tipLines + 1] = {
					text = "Bought "..ns.FormatNumber(row.bought).." for "..ns.MoneyColored(row.cost or 0)
						.." ("..ns.MoneyColored((row.cost or 0) / row.bought).." each)",
					color = ROW_DIM,
				}
			end
			topRows[#topRows + 1] = {
				left = ItemLabel(row, 180),
				mid2 = "x"..ns.FormatNumber(row.units or 0),
				right = ns.MoneyColored(row.received or 0),
				tip = {
					kind = "note",
					title = ColoredItemName(row),
					lines = tipLines,
					note = store.combined and "Across every ticked character, over the last thirty days of auction activity."
						or "Over this character's last thirty days of auction activity: the ranking is not limited by the day button.",
					key = (row.name or "").."|"..store.sort,
				},
			}
		end
	end
	if FillScrollingLines(widgets.top, topRows, store, "topOffset", topTitle, 34) == 0 then
		if store.sort == "bought" then
			ShowCardText(widgets.top, "Nothing bought at the auction house yet: a purchase is recorded when the mail carrying it is collected.")
		else
			ShowCardText(widgets.top, "Nothing has sold yet.")
		end
	end
	widgets.top.noteTitle = topTitle

	-- Recent list: every event, newest first, grouped under its day. The day
	-- heading is an orange row, as the profession list heads a profession; the
	-- rows below carry no date of their own, and the hover states the exact
	-- date and time.
	local recentRows = {}
	local filter = store.eventFilter or "all"
	local events = {}
	for index = 1, #report.recent do
		local entry = report.recent[index]
		if filter == "all" or entry.kind == filter then
			events[#events + 1] = entry
		end
	end
	local lastDay
	for index = 1, #events do
		local entry = events[index]
		local dayStamp = entry.at or 0
		local day = dayStamp > 0 and date("%Y-%m-%d", dayStamp) or "-"
		if day ~= lastDay then
			lastDay = day
			recentRows[#recentRows + 1] = {
				left = ns.FormatDate(dayStamp),
				leftColor = ACCENT,
			}
		end
		local kindColor, kindLabel
		if entry.kind == "sold" then
			kindColor, kindLabel = AMBER, "sold"
		elseif entry.kind == "posted" then
			kindColor, kindLabel = VALUE_COLOR, "posted"
		elseif entry.kind == "expired" then
			kindColor, kindLabel = ROW_DIM, "expired"
		else
			kindColor, kindLabel = RED, "cancelled"
		end
		local left = "   |cff"..string.format("%02x%02x%02x",
			math.floor(kindColor[1] * 255 + 0.5), math.floor(kindColor[2] * 255 + 0.5), math.floor(kindColor[3] * 255 + 0.5))
			..kindLabel.."|r  "
		if store.combined and entry.who then
			left = left..(ClassColorCode(entry.classFile) or "")..CutRowText(entry.who, 8).."|r  "
		end
		left = left..ItemLabel(entry, store.combined and 80 or 125)
		local figure
		if entry.kind == "sold" then
			figure = ns.MoneyColored(entry.net or 0)
		elseif entry.buyout and entry.buyout > 0 then
			figure = ns.MoneyColored(entry.buyout)
		elseif entry.price and entry.price > 0 then
			figure = ns.MoneyColored(entry.price)
		else
			figure = "|cff8a8a8a-|r"
		end
		local detail
		if entry.kind == "sold" then
			detail = ns.MoneyColored(entry.price or 0).." sale"
			if (entry.units or 1) > 1 then
				detail = "x"..ns.FormatNumber(entry.units).."  ·  "..detail
			end
		elseif entry.kind == "posted" then
			detail = "asked "..ns.MoneyColored(entry.buyout or entry.price or 0)
		else
			detail = "unsold"
		end
		recentRows[#recentRows + 1] = {
			left = left,
			mid2 = "x"..ns.FormatNumber(entry.units or 1),
			right = figure,
			tip = {
				kind = "note",
				title = ColoredItemName(entry).." - "..kindLabel,
				lines = {
					{ text = detail, color = VALUE_COLOR },
					{ text = (entry.units or 1)..((entry.units or 1) == 1 and " item" or " items"), color = ROW_DIM },
					{ text = entry.at and ("When "..ns.FormatDateTime(entry.at)) or "When not read", color = ROW_DIM },
				},
				key = tostring(entry.at).."|"..tostring(entry.name).."|"..tostring(entry.kind),
			},
		}
		if entry.kind == "sold" then
			recentRows[#recentRows].tip.lines[#recentRows[#recentRows].tip.lines + 1] =
				{ text = "Cut "..ns.MoneyColored(entry.cut or 0)..", deposit back "..ns.MoneyColored(entry.deposit or 0), color = ROW_DIM }
			local units = math.max(1, entry.units or 1)
			local price = entry.price or 0
			if price > 0 then
				recentRows[#recentRows].tip.lines[#recentRows[#recentRows].tip.lines + 1] = {
					text = "Price each "..ns.MoneyColored(math.floor(price / units)),
					color = VALUE_COLOR,
				}
				local after = math.max(0, price - (entry.cut or 0))
				recentRows[#recentRows].tip.lines[#recentRows[#recentRows].tip.lines + 1] = {
					text = "After the cut "..ns.MoneyColored(after)
						..(units > 1 and ("  ·  "..ns.MoneyColored(math.floor(after / units)).." each") or ""),
					color = GREEN,
				}
			end
			if store.combined and entry.who then
				recentRows[#recentRows].tip.lines[#recentRows[#recentRows].tip.lines + 1] =
					{ text = "Auction by "..entry.who, color = ROW_DIM }
			end
			if entry.restored then
				recentRows[#recentRows].tip.lines[#recentRows[#recentRows].tip.lines + 1] = {
					text = "From the item's record: the sale predates the event list Tally kept.",
					color = ROW_DIM,
				}
			end
		end
	end
	if FillScrollingLines(widgets.recent, recentRows, store, "recentOffset", "Recent auctions", 40) == 0 then
		if filter == "all" then
			ShowCardText(widgets.recent, "No auction events yet: post something and Tally will record it.")
		else
			ShowCardText(widgets.recent, "Nothing "..filter.." in this range.")
		end
	end

	-- The buttons say what they do and what they are set to.
	if widgets.periodButton then
		SetCornerLabel(widgets.periodButton, period.label)
		widgets.periodButton:SetWidth(widgets.periodButton.text:GetStringWidth() + 18)
		local dim = period.days == 30
		widgets.periodButton.text:SetTextColor(
			dim and 0.62 or AMBER[1],
			dim and 0.62 or AMBER[2],
			dim and 0.62 or AMBER[3])
	end
	if widgets.sortButton then
		widgets.sortButton:Show()
	end
end

local function BuildAuctionView(parent, opts)
	opts = opts or {}
	local store = opts.store or {}
	store.combined = opts.combined and true or false
	store.list = opts.list or function()
		local char = DisplayChar()
		if not char then
			return {}
		end
		return { { key = ns.viewKey or ns.charKey, char = char, name = ns.DisplayName(char) } }
	end
	store.widgets = {}
	local widgets = store.widgets
	auctionStores[#auctionStores + 1] = store
	store.days = store.days or 30
	store.sort = store.sort or "sold"
	store.eventFilter = store.eventFilter or "all"
	store.topOffset = store.topOffset or 0
	store.recentOffset = store.recentOffset or 0

	CreateTileRow(parent, -4, { "Auctions posted", "Sold", "Income", "Best sale ever" }, widgets, false, 0)
	CreateTileRow(parent, -76, { "Spent", "Biggest purchase ever", "Most bought", "Still up" }, widgets, false, 4)
	widgets.posted, widgets.sold, widgets.income, widgets.best = widgets[1], widgets[2], widgets[3], widgets[4]
	widgets.spent, widgets.biggestBuy, widgets.mostBought, widgets.live = widgets[5], widgets[6], widgets[7], widgets[8]

	-- The two cards, at the same height as the loot page's, with the tile row
	-- above them: fifteen rows each at the default step.
	widgets.top = CreateListCard(parent, 0, -148, 359, 274, "Top auctions")
	widgets.recent = CreateListCard(parent, 371, -148, 359, 274, "Recent auctions")
	-- A quantity column of its own on both cards, so a short name on one row
	-- does not move the x5 on the next: units right-align in their own column,
	-- close to the money, which leaves the name most of the width. The rows
	-- are created on the first draw, so the column is set here.
	widgets.top.rowMid2Right = 130
	widgets.recent.rowMid2Right = 130
	AddCardTitleNote(widgets.top, "Top auctions",
		"One row per item sold, with how many were sold and the total income after the house's cut. The button ranks them by amount sold, by income, or shows the most recent purchases; the ranking covers the last thirty days of auction activity, not just the day button.")
	AddCardTitleNote(widgets.recent, "Recent auctions",
		"The latest auction events Tally saw - put up, sold, expired or cancelled - newest first, grouped by day, and kept by date: thirty days of activity with no count limit. The button filters to sold, posted or expired; a sale is recorded when its mail is collected.")
	MakeCardScrollable(widgets.top, store, "topOffset", function()
		Refresh(store)
	end)
	MakeCardScrollable(widgets.recent, store, "recentOffset", function()
		Refresh(store)
	end)
	for _, card in ipairs({ widgets.top, widgets.recent }) do
		card:SetScript("OnUpdate", function()
			ns.RowHoverTick(card)
		end)
		card:SetScript("OnLeave", function()
			card.hoverKey = nil
			if GameTooltip:IsOwned(card) then
				GameTooltip:Hide()
			end
		end)
	end

	-- The boxes that name an item answer a hover with that item's own tooltip.
	for _, tile in ipairs({ widgets.best, widgets.biggestBuy, widgets.mostBought }) do
		tile:EnableMouse(true)
		tile:SetScript("OnEnter", function(self)
			if self.tipItem then
				ns.ItemTooltip(self, self.tipItem.name, self.tipItem.id, self.tipExtra)
			end
		end)
		tile:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
	end

	-- The live tile answers a hover with the auctions the game last listed,
	-- counting down from the moment that list was read.
	widgets.live:EnableMouse(true)
	widgets.live:SetScript("OnEnter", function(self)
		if not self.tipRows or #self.tipRows == 0 then
			return
		end
		local now = ns.Now()
		local shown, timed, banded = 0, false, false
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Still up", ACCENT[1], ACCENT[2], ACCENT[3])
		for index = 1, #self.tipRows do
			local row = self.tipRows[index]
			if not row.expiresAt or row.expiresAt > now then
				shown = shown + 1
				if row.expiresAt then
					timed = true
				elseif row.band then
					banded = true
				end
				if shown <= 12 then
					local left = (store.combined and row.who and (CutRowText(row.who, 10).."  ") or "")
						..ItemLabel(row, 200)
					GameTooltip:AddDoubleLine(left, LiveRowText(row, now), 0.9, 0.9, 0.9, 1, 1, 1)
				end
			end
		end
		if shown == 0 then
			GameTooltip:AddLine("Nothing is up now.", 0.7, 0.7, 0.7)
		elseif shown > 12 then
			GameTooltip:AddLine((shown - 12).." more", 0.7, 0.7, 0.7)
		end
		if self.tipAt and self.tipAt > 0 then
			GameTooltip:AddLine("As seen "..ns.FormatDateTime(self.tipAt)..".", 0.7, 0.7, 0.7, true)
		end
		if timed then
			GameTooltip:AddLine("The times count down from that reading; opening the auction house reads the list again.", 0.7, 0.7, 0.7, true)
		elseif banded then
			GameTooltip:AddLine("The game gives only a band for how long each auction has left here, so those do not count down.", 0.7, 0.7, 0.7, true)
		end
		GameTooltip:Show()
	end)
	widgets.live:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	-- The countdown runs by itself while the page is open: the box is read
	-- again every half minute from the last list, without asking the game.
	widgets.live.tickAt = 0
	widgets.live:SetScript("OnUpdate", function(self)
		local now = ns.Now()
		if now - (self.tickAt or 0) < 30 then
			return
		end
		self.tickAt = now
		RefreshLiveTile(store)
	end)

	-- Two buttons in the page's own tab strip, so the day range reads as the
	-- page's setting rather than one card's. They appear with the sub-view.
	local strip = opts.strip or parent
	widgets.band = CreateFrame("Frame", nil, strip)
	widgets.band:SetPoint("TOPRIGHT", strip, "TOPRIGHT", -2, 0)
	widgets.band:SetSize(10, 18)
	-- Hidden until the sub-view is shown: the band sits on the page, not in
	-- the sub-view, so nothing else would hide it.
	widgets.band:Hide()

	local sortButton = CreateCornerButton(widgets.top)
	sortButton:ClearAllPoints()
	sortButton:SetPoint("TOPRIGHT", widgets.top, "TOPRIGHT", -10, -6)
	widgets.sortButton = sortButton
	SetCornerLabel(sortButton, SortLabel(store.sort))
	sortButton:SetScript("OnClick", function()
		store.sort = NextSort(store.sort)
		store.topOffset = 0
		SetCornerLabel(sortButton, SortLabel(store.sort))
		ns.RefreshAuctionView(store)
	end)
	sortButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("The order of the top list", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to cycle: by amount sold (how many), by income (what each item actually brought in), and the most recent purchases, newest first.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	sortButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	-- The recent list's filter. It hides other kinds; the day headings and the
	-- date window are untouched, so "all events" is simply everything kept.
	local eventButton = CreateCornerButton(widgets.recent)
	eventButton:ClearAllPoints()
	eventButton:SetPoint("TOPRIGHT", widgets.recent, "TOPRIGHT", -10, -6)
	widgets.eventButton = eventButton
	SetCornerLabel(eventButton, EventFilterLabel(store.eventFilter))
	eventButton:SetScript("OnClick", function()
		store.eventFilter = NextEventFilter(store.eventFilter)
		store.recentOffset = 0
		SetCornerLabel(eventButton, EventFilterLabel(store.eventFilter))
		ns.RefreshAuctionView(store)
	end)
	eventButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Which auction events are listed", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to cycle all events, sold, posted and expired. This only hides the other kinds: the same thirty days of activity are kept, with no per-kind count, and the day headings stay.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	eventButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	local periodButton = CreateFrame("Button", nil, widgets.band, "BackdropTemplate")
	periodButton:SetHeight(18)
	periodButton:SetPoint("TOPRIGHT", widgets.band, "TOPRIGHT", 0, 0)
	periodButton:SetBackdrop(ns.TILE_BACKDROP)
	periodButton:SetBackdropColor(0.06, 0.06, 0.08, 0.6)
	periodButton:SetBackdropBorderColor(1, 1, 1, 0.12)
	periodButton.text = periodButton:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	periodButton.text:SetPoint("LEFT", 9, 0)
	periodButton.text:SetTextColor(0.62, 0.62, 0.62)
	periodButton.hover = periodButton:CreateTexture(nil, "HIGHLIGHT")
	periodButton.hover:SetAllPoints(periodButton)
	periodButton.hover:SetColorTexture(1, 1, 1, 0.09)
	periodButton:EnableMouse(true)
	periodButton:RegisterForClicks("LeftButtonUp")
	periodButton:SetScript("OnClick", function()
		local index = PeriodIndex(store)
		store.days = PeriodAt(index % #PERIODS + 1).days
		store.topOffset = 0
		store.recentOffset = 0
		ns.RefreshAuctionView(store)
	end)
	periodButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("How far back the figures go", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to cycle 30, 14, 7 and 3 days of activity, then today. The ranges end at the latest auction Tally saw, so a break in play does not empty the list. The boxes follow the range, the best-sale and best-buy boxes are all-time, and the still-up box runs down from the last time the auction house was open.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	periodButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	widgets.periodButton = periodButton

	-- The combined view can change which characters it covers without leaving
	-- the page; the one picker is the same one the charts use.
	if store.combined then
		local charsButton = CreateFrame("Button", nil, widgets.band, "BackdropTemplate")
		charsButton:SetHeight(18)
		charsButton:SetPoint("RIGHT", periodButton, "LEFT", -6, 0)
		charsButton:SetBackdrop(ns.TILE_BACKDROP)
		charsButton:SetBackdropColor(0.06, 0.06, 0.08, 0.6)
		charsButton:SetBackdropBorderColor(1, 1, 1, 0.12)
		charsButton.text = charsButton:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		charsButton.text:SetPoint("LEFT", 9, 0)
		charsButton.text:SetText("characters")
		charsButton.text:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
		charsButton:SetWidth(charsButton.text:GetStringWidth() + 18)
		charsButton.hover = charsButton:CreateTexture(nil, "HIGHLIGHT")
		charsButton.hover:SetAllPoints(charsButton)
		charsButton.hover:SetColorTexture(1, 1, 1, 0.09)
		charsButton:EnableMouse(true)
		charsButton:RegisterForClicks("LeftButtonUp")
		charsButton:SetScript("OnClick", function()
			ShowCharPicker("levels", true)
		end)
		charsButton:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
			GameTooltip:AddLine("Characters", ACCENT[1], ACCENT[2], ACCENT[3])
			GameTooltip:AddLine("select which characters to use", 1, 1, 1, true)
			GameTooltip:AddLine("The same choice as the charts and the records: this page covers the ticked characters, and nothing here changes a character's own record.", 0.7, 0.7, 0.7, true)
			GameTooltip:Show()
		end)
		charsButton:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		widgets.charsButton = charsButton
	end

	-- The strip buttons belong to the page, so they follow the sub-view in and
	-- out rather than sitting over the ledger.
	parent:SetScript("OnShow", function()
		widgets.band:Show()
		Refresh(store)
	end)
	parent:SetScript("OnHide", function()
		widgets.band:Hide()
		if GameTooltip:IsOwned(parent) then
			GameTooltip:Hide()
		end
	end)

	-- Widen the strip after the labels exist, so the buttons sit side by side.
	Refresh(store)
	local width = (widgets.periodButton:GetWidth() or 0) + 6
	if widgets.charsButton then
		width = width + (widgets.charsButton:GetWidth() or 0)
	end
	widgets.band:SetWidth(width)
	return store
end

local function RefreshAuctionView(store)
	if store then
		Refresh(store)
	end
end

ns.BuildAuctionView, ns.RefreshAuctionView = BuildAuctionView, RefreshAuctionView

-- The character picker has one selection behind both mounts, so a tick asks
-- every auction page to redraw, whichever tab happens to be open.
function ns.RefreshAuctionPages()
	for index = 1, #auctionStores do
		Refresh(auctionStores[index])
	end
end
