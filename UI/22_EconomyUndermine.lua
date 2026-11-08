-- Tally - the Economy tab's Undermine Real view.
--
-- Tarnished Undermine Real is a Forever-only currency (item 226404). The
-- sub-tab and this whole file are only built when Core/86_UndermineReal.lua
-- says the client has it, so other clients never show an empty currency page.
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
	view = "levels",
	levelOrder = "high",
	offset = 0,
}

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

local function LevelOrder(entry)
	local levels = {}
	for level, row in pairs(type(entry.byLevel) == "table" and entry.byLevel or {}) do
		local earned = type(row) == "table" and Number(row.earned) or 0
		local spent = type(row) == "table" and Number(row.spent) or 0
		if (tonumber(level) or 0) > 0 and (earned > 0 or spent > 0) then
			levels[#levels + 1] = tonumber(level)
		end
	end
	table.sort(levels, function(a, b)
		if undermineWidgets.levelOrder == "low" then
			return a < b
		end
		return a > b
	end)
	return levels
end

local function LevelRows(entry)
	local levels = LevelOrder(entry)
	if #levels == 0 then
		return nil
	end
	local rows = {
		{
			left = "Level", mid2 = "Earned", mid = "Spent", right = "Net",
			leftColor = ACCENT, mid2Color = ACCENT, midColor = ACCENT, rightColor = ACCENT,
		},
	}
	for index = 1, #levels do
		local level = levels[index]
		local row = entry.byLevel[level]
		local earned = type(row) == "table" and Number(row.earned) or 0
		local spent = type(row) == "table" and Number(row.spent) or 0
		local net = earned - spent
		local lines = {}
		local recent = type(entry.recent) == "table" and entry.recent or {}
		for recentIndex = #recent, 1, -1 do
			local change = recent[recentIndex]
			if type(change) == "table" and Number(change.level) == level then
				local delta = Number(change.delta)
				lines[#lines + 1] = {
					text = (delta > 0 and "+" or "")..ns.FormatNumber(delta)
						.."  "..(change.source or "Currency change")
						.."  ·  "..ShortWhen(change.at),
				}
				if #lines >= 8 then
					break
				end
			end
		end
		rows[#rows + 1] = {
			left = "Level "..level,
			mid2 = ns.FormatNumber(earned),
			mid = ns.FormatNumber(spent),
			right = (net > 0 and "+" or "")..ns.FormatNumber(net),
			leftColor = ACCENT,
			mid2Color = earned > 0 and GREEN or ROW_DETAIL_DIM,
			midColor = spent > 0 and RED or ROW_DETAIL_DIM,
			rightColor = net > 0 and GREEN or (net < 0 and RED or ROW_DETAIL_DIM),
			tip = {
				kind = "note", title = "Level "..level,
				lines = lines,
				note = "Undermine Real changes Tally saw at this character level.",
				key = "undermineLevel|"..level,
			},
		}
	end
	return rows
end

local function RecentRows(entry)
	local recent = type(entry.recent) == "table" and entry.recent or {}
	if #recent == 0 then
		return nil
	end
	local rows = {
		{
			left = "Change", mid = "Level", right = "Amount",
			leftColor = ACCENT, midColor = ACCENT, rightColor = ACCENT,
		},
	}
	for index = #recent, 1, -1 do
		local change = recent[index]
		if type(change) == "table" then
			local delta = Number(change.delta)
			local source = change.source or "Currency change"
			rows[#rows + 1] = {
				left = CutRowText(source, 32),
				mid = "Level "..Number(change.level),
				right = (delta > 0 and "+" or "")..ns.FormatNumber(delta),
				leftColor = delta > 0 and GREEN or RED,
				midColor = ROW_DETAIL_DIM,
				rightColor = delta > 0 and GREEN or RED,
				tip = {
					kind = "note", title = source,
					lines = {
						{ text = (delta > 0 and "Gained " or "Spent ")..ns.FormatNumber(math.abs(delta)) },
						{ text = "Level "..Number(change.level) },
						{ text = ns.FormatDate(change.at) },
					},
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
	local sortButton = undermineWidgets.sortButton
	if viewButton then
		SetCornerLabel(viewButton, undermineWidgets.view == "recent" and "recent" or "by level")
	end
	if sortButton then
		sortButton:SetShown(undermineWidgets.view ~= "recent")
		SetCornerLabel(sortButton, undermineWidgets.levelOrder == "low" and "level: asc" or "level: desc")
		sortButton:ClearAllPoints()
		sortButton:SetPoint("TOPRIGHT", viewButton, "TOPLEFT", -6, 0)
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
	local amount = ns.UndermineReal and ns.UndermineReal.Read
		and select(1, ns.UndermineReal.Read()) or nil
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
		-- the history begins with the first change Tally sees. An empty tab
		-- next to a readable balance would just look broken.
		local name = char and ns.DisplayName and ns.DisplayName(char) or "this character"
		if amount ~= nil then
			RefreshTiles({ balance = amount, starting = 0, earned = 0, spent = 0 })
			ShowCardText(card, "Balance: "..ns.FormatNumber(amount).." Reals. Tally has not started the history for "
				..name.." yet, so the first change it sees will open the record.")
		else
			RefreshTiles(nil)
			ShowCardText(card, "No Tarnished Undermine Real collected for "..name.." yet. The client returned no value.")
		end
		ns.Trace("undermine: no record yet (key="..tostring(ns.charKey)..", retry="..tostring(ns.retryLoginAttempt)
			..", client read="..tostring(amount)..")")
		return
	end
	RefreshTiles(entry)
	if undermineWidgets.view == "recent" then
		local rows = RecentRows(entry)
		if FillScrollingLines(card, rows or {}, undermineWidgets, "offset", "Recent changes", 42) == 0 then
			ShowCardText(card, "No Undermine Real changes recorded yet.")
		end
	else
		local rows = LevelRows(entry)
		if FillScrollingLines(card, rows or {}, undermineWidgets, "offset", "By level", 44) == 0 then
			ShowCardText(card, "No Undermine Real earned or spent per level yet.")
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
	-- One set of columns for both views: Level, Earned, Spent, Net. The
	-- recent view uses the left and two right-hand columns only.
	card.rowMidRight = 250
	card.rowMid2Right = 390
	AddCardTitleNote(card, "Undermine Real",
		"Per character. The starting balance is the amount Tally first saw, so it is not counted as earned. Every later increase is Undermine Real earned and every decrease is spent, attributed to the character level it happened at. The corner buttons switch between the by-level table and the recent changes, and between highest and lowest level first.")
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
		undermineWidgets.view = undermineWidgets.view == "recent" and "levels" or "recent"
		undermineWidgets.offset = 0
		UpdateButtons()
		RefreshEconomyUndermine()
	end)
	viewButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Undermine Real view", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Switch between the by-level table and the recent changes.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	viewButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	local sortButton = CreateCornerButton(card)
	undermineWidgets.sortButton = sortButton
	sortButton:SetScript("OnClick", function()
		undermineWidgets.levelOrder = undermineWidgets.levelOrder == "low" and "high" or "low"
		undermineWidgets.offset = 0
		UpdateButtons()
		RefreshEconomyUndermine()
	end)
	sortButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Order of the levels", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to switch between highest level first and lowest level first.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	sortButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	UpdateButtons()
	RefreshEconomyUndermine()
end

ns.BuildEconomyUndermine = BuildEconomyUndermine
ns.RefreshEconomyUndermine = RefreshEconomyUndermine
