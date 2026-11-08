-- Tally - the Economy tab's Undermine Real view.
--
-- Tarnished Undermine Real is a Forever-only currency (item 226404), earned
-- from dungeon, raid and world bosses and spent at Pix Xizzix. The sub-tab
-- and this whole file are only built when Core/86_UndermineReal.lua says the
-- client has it.
local addonName, ns = ...

local ACCENT, GREEN, RED, VALUE_COLOR, ROW_DETAIL_DIM,
	DisplayChar, CreateTileRow, SetTile, CreateListCard, AddCardTitleNote,
	AddCardScrollbar, MakeCardScrollable, FillScrollingLines, ShowCardText,
	RowHoverTick, CreateCornerButton, SetCornerLabel, CutRowText =
	ns.ACCENT, ns.GREEN, ns.RED, ns.VALUE_COLOR, ns.ROW_DETAIL_DIM,
	ns.DisplayChar, ns.CreateTileRow, ns.SetTile, ns.CreateListCard, ns.AddCardTitleNote,
	ns.AddCardScrollbar, ns.MakeCardScrollable, ns.FillScrollingLines, ns.ShowCardText,
	ns.RowHoverTick, ns.CreateCornerButton, ns.SetCornerLabel, ns.CutRowText

-- No "os" table on this client; date() is the game's own function.
local Date
if type(date) == "function" then
	Date = date
elseif type(os) == "table" and type(os.date) == "function" then
	Date = os.date
else
	Date = function() return "unknown" end
end

local UNDERMINE_KEY = 226404
local undermineWidgets = {
	tiles = {},
	view = "recent",
	offset = 0,
}

local VENDOR_LINE = "You can use your Tarnished Undermine Real to purchase items from Pix Xizzix in Booty Bay."

local function EmptyText(main)
	return main.."\n\n|cff999999"..VENDOR_LINE.."|r"
end

local function EntryFor(char)
	local currency = char and char.currency
	local entry = type(currency) == "table" and currency[UNDERMINE_KEY]
	return type(entry) == "table" and entry or nil
end

local function Number(value)
	return tonumber(value) or 0
end

local function ShortWhen(at)
	if ns.ShortWhen then
		return ns.ShortWhen(at)
	end
	return at and ns.FormatDate(at) or ""
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

local function KindLabel(kind)
	if kind == "dungeon" then
		return "Dungeon"
	elseif kind == "raid" then
		return "Raid"
	elseif kind == "scenario" then
		return "Scenario"
	elseif kind == "pvp" then
		return "PvP"
	elseif kind == "world" then
		return "World"
	end
	return "Other"
end

-- Every place that produced Reals, most earned first.
local function SourceOrder(entry)
	local list = {}
	local bySource = type(entry.bySource) == "table" and entry.bySource or {}
	for key, bucket in pairs(bySource) do
		if type(bucket) == "table" then
			local earned = Number(bucket.earned)
			if earned > 0 then
				list[#list + 1] = {
					key = key,
					name = bucket.name or "Unknown",
					kind = bucket.kind or "unknown",
					earned = earned,
					lastAt = bucket.lastAt,
				}
			end
		end
	end
	table.sort(list, function(a, b)
		if a.earned ~= b.earned then
			return a.earned > b.earned
		end
		return tostring(a.name) < tostring(b.name)
	end)
	return list
end

local function SourceRows(entry)
	local list = SourceOrder(entry)
	if #list == 0 then
		return nil
	end
	local rows = {
		{
			left = "Source", mid2 = "Earned", mid = "Last",
			leftColor = ACCENT, mid2Color = ACCENT, midColor = ACCENT,
		},
	}
	local total = 0
	for index = 1, #list do
		local item = list[index]
		total = total + item.earned
		rows[#rows + 1] = {
			left = CutRowText(item.name, 34),
			mid2 = ns.FormatNumber(item.earned),
			mid = item.lastAt and ShortWhen(item.lastAt) or "",
			leftColor = ACCENT,
			mid2Color = GREEN,
			midColor = ROW_DETAIL_DIM,
			tip = {
				kind = "note", title = item.name,
				lines = {
					{ text = "Earned: "..ns.FormatNumber(item.earned) },
					{ text = "Last: "..(item.lastAt and ns.FormatDate(item.lastAt) or "unknown") },
					{ text = "Type: "..KindLabel(item.kind) },
				},
				key = "undermineSource|"..tostring(item.key),
			},
		}
	end
	rows[#rows + 1] = { divider = true }
	rows[#rows + 1] = {
		left = "Total", mid2 = ns.FormatNumber(total), mid = "",
		leftColor = ACCENT, mid2Color = ACCENT, midColor = ACCENT,
	}
	return rows
end

local function RecentRows(entry)
	local recent = type(entry.recent) == "table" and entry.recent or {}
	if #recent == 0 then
		return nil
	end
	local rows = {
		{
			left = "Source", mid = "When", right = "Amount",
			leftColor = ACCENT, midColor = ACCENT, rightColor = ACCENT,
		},
	}
	for index = #recent, 1, -1 do
		local change = recent[index]
		if type(change) == "table" then
			local delta = Number(change.delta)
			local place = change.place or change.source or "Currency change"
			local lines = {
				{ text = (delta > 0 and "Gained " or "Spent ")..ns.FormatNumber(math.abs(delta)) },
				{ text = ns.FormatDate(change.at) },
			}
			if change.place and change.source and change.source ~= change.place then
				lines[#lines + 1] = { text = "Source: "..change.source }
			end
			rows[#rows + 1] = {
				left = CutRowText(place, 34),
				mid = ShortWhen(change.at),
				right = (delta > 0 and "+" or "")..ns.FormatNumber(delta),
				leftColor = delta > 0 and GREEN or RED,
				midColor = ROW_DETAIL_DIM,
				rightColor = delta > 0 and GREEN or RED,
				tip = {
					kind = "note", title = place,
					lines = lines,
					key = "undermineChange|"..tostring(change.at).."|"..delta,
				},
			}
		end
	end
	return rows
end

local function RefreshTiles(entry)
	local tiles = undermineWidgets.tiles
	if #tiles == 0 then
		return
	end
	if not entry then
		for index = 1, #tiles do
			SetTile(tiles[index], "-", "")
			tiles[index].tipInfo = nil
		end
		return
	end
	local balance = Number(entry.balance)
	local starting = Number(entry.starting)
	local earned = Number(entry.earned)
	local spent = Number(entry.spent)
	local day = Date("%Y-%m-%d")
	local daily = type(entry.daily) == "table" and entry.daily or {}
	local today = type(daily[day]) == "table" and daily[day] or { earned = 0, spent = 0 }
	local todayEarned = Number(today.earned)
	local todaySpent = Number(today.spent)
	local todayNet = todayEarned - todaySpent
	local cap = Number(entry.maxQuantity)

	SetTile(tiles[1], ns.FormatNumber(balance), "starting "..ns.FormatNumber(starting))
	tiles[1].tipInfo = TipInfo("Undermine Real balance", {
		{ text = "Current: "..ns.FormatNumber(balance) },
		{ text = "Starting balance: "..ns.FormatNumber(starting) },
		{ text = "Earned since tracking: "..ns.FormatNumber(earned) },
		{ text = "Spent since tracking: "..ns.FormatNumber(spent) },
		{ text = "Cap: "..(cap > 0 and ns.FormatNumber(cap) or "unknown") },
	}, "Balance = starting + earned - spent.")

	SetTile(tiles[2], ns.FormatNumber(earned),
		entry.firstAt and ("since "..ns.FormatDate(entry.firstAt)) or "since tracking")
	tiles[2].tipInfo = TipInfo("Undermine Real earned", {
		{ text = ns.FormatNumber(earned).." gained in total" },
		{ text = "First seen "..(entry.firstAt and ns.FormatDate(entry.firstAt) or "unknown") },
	})

	SetTile(tiles[3], ns.FormatNumber(spent), "spent in total")
	tiles[3].tipInfo = TipInfo("Undermine Real spent", {
		{ text = ns.FormatNumber(spent).." spent in total" },
		{ text = "Last change "..(entry.lastAt and ns.FormatDate(entry.lastAt) or "unknown") },
	})

	SetTile(tiles[4], (todayNet > 0 and "+" or "")..ns.FormatNumber(todayNet),
		"+"..ns.FormatNumber(todayEarned).." / -"..ns.FormatNumber(todaySpent))
	tiles[4].tipInfo = TipInfo("Today", {
		{ text = "Earned today: "..ns.FormatNumber(todayEarned) },
		{ text = "Spent today: "..ns.FormatNumber(todaySpent) },
		{ text = "Net today: "..((todayNet > 0 and "+" or "")..ns.FormatNumber(todayNet)) },
	})
end

local function UpdateButtons()
	local viewButton = undermineWidgets.viewButton
	if viewButton then
		SetCornerLabel(viewButton, undermineWidgets.view == "sources" and "by source" or "recent")
	end
end

local function RefreshEconomyUndermineInner()
	local card = undermineWidgets.card
	if not card then
		return
	end
	local char = DisplayChar()
	if not char and ns.GetChar then
		-- The tab is per character. If the view lookup came back empty, fall
		-- back to the character being played rather than claiming none exists.
		char = ns.GetChar()
	end
	-- The currency can be read whether or not a character record is loaded,
	-- so the tab never has to be blank: the balance below is the live figure
	-- the client answers.
	local amount, _, maxQuantity
	if ns.UndermineReal and ns.UndermineReal.Read then
		amount, _, maxQuantity = ns.UndermineReal.Read()
	end
	local entry = EntryFor(char)
	if not entry and char and char == ns.GetChar() and ns.UndermineReal
		and type(ns.UndermineReal.Poll) == "function" then
		-- Opening the tab is a good moment for a read: if the record was never
		-- created (the login poll ran before the currency was readable), this
		-- creates it without waiting for the 10-second tick.
		pcall(ns.UndermineReal.Poll)
		entry = EntryFor(char)
	end

	if not entry then
		-- No record yet: show what the client actually reports and say that
		-- the history begins with the first change Tally sees.
		local name = char and ns.DisplayName and ns.DisplayName(char) or "this character"
		if amount ~= nil then
			RefreshTiles({ balance = amount, starting = 0, earned = 0, spent = 0, maxQuantity = maxQuantity })
			ShowCardText(card, EmptyText("You have "..ns.FormatNumber(amount)
				.." Tarnished Undermine Real. Tally starts the history with your next change."))
		else
			RefreshTiles(nil)
			ShowCardText(card, EmptyText("No Tarnished Undermine Real recorded for "
				..name.." yet. Earn them from dungeon and raid bosses."))
		end
		ns.Trace("undermine: no record yet (key="..tostring(ns.charKey)..", retry="..tostring(ns.retryLoginAttempt)
			..", client read="..tostring(amount)..")")
		return
	end
	RefreshTiles(entry)
	if undermineWidgets.view == "sources" then
		local rows = SourceRows(entry)
		if FillScrollingLines(card, rows or {}, undermineWidgets, "offset", "Where they came from", 44) == 0 then
			ShowCardText(card, EmptyText("No Undermine Real earned yet. Earn them from dungeon and raid bosses."))
		end
	else
		local rows = RecentRows(entry)
		if FillScrollingLines(card, rows or {}, undermineWidgets, "offset", "Recent changes", 44) == 0 then
			ShowCardText(card, EmptyText("No changes recorded yet."))
		end
	end
end

-- The page is drawn from a read of the client's currency, so a failure in one
-- draw must not take the rest of the Economy page with it: the error is kept
-- on the card instead of throwing.
local function RefreshEconomyUndermine()
	local ok, err = pcall(RefreshEconomyUndermineInner)
	if not ok then
		ns.lastUndermineUiError = tostring(err)
		ns.Trace("undermine: UI refresh failed: "..tostring(err))
		if undermineWidgets.card then
			ShowCardText(undermineWidgets.card, "Undermine Real could not be drawn: "..tostring(err))
		end
	end
end

local function BuildEconomyUndermine(page)
	CreateTileRow(page, -4, { "Balance", "Earned", "Spent", "Today" }, undermineWidgets.tiles, false)
	for index = 1, #undermineWidgets.tiles do
		AddTip(undermineWidgets.tiles[index])
	end

	local card = CreateListCard(page, 0, -88, 730, 338, "Undermine Real")
	undermineWidgets.card = card
	if ns.economyWidgets then
		ns.economyWidgets.undermineCard = card
	end
	-- The recent view uses the left, middle and right columns; the by-source
	-- view uses the left and the two right-hand columns.
	card.rowMidRight = 250
	card.rowMid2Right = 390
	AddCardTitleNote(card, "Undermine Real",
		"Per character. Reals are earned from dungeon, raid and world bosses and spent at Pix Xizzix; the starting balance is the amount Tally first saw, so it is not counted as earned. The corner button switches between the recent changes and a summary of where the Reals came from.")
	AddCardScrollbar(card, undermineWidgets, "offset", RefreshEconomyUndermine)
	MakeCardScrollable(card, undermineWidgets, "offset", RefreshEconomyUndermine)
	card:SetScript("OnUpdate", function()
		RowHoverTick(card)
	end)
	card:SetScript("OnLeave", function()
		card.hoverKey = nil
		if GameTooltip:IsOwned(card) then
			GameTooltip:Hide()
		end
	end)

	local viewButton = CreateCornerButton(card)
	undermineWidgets.viewButton = viewButton
	viewButton:SetScript("OnClick", function()
		undermineWidgets.view = undermineWidgets.view == "sources" and "recent" or "sources"
		undermineWidgets.offset = 0
		UpdateButtons()
		RefreshEconomyUndermine()
	end)
	viewButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Undermine Real view", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Switch between the recent changes and the summary of where the Reals came from.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	viewButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	UpdateButtons()
	RefreshEconomyUndermine()
end

ns.BuildEconomyUndermine = BuildEconomyUndermine
ns.RefreshEconomyUndermine = RefreshEconomyUndermine
