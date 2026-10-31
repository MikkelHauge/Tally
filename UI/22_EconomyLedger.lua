-- Tally - the Economy tab's ledger sub-view: tiles, income, spending and the
-- recent money changes.
local addonName, ns = ...

local ACCENT, GREEN, RED, CATEGORY_LABELS, CategoryNames, SortedCategories, DisplayChar, SetTile, CreateTileRow, CreateListCard, ROW_STEP, FillCardRows, ShowCardText, AddCardTitleNote, FillScrollingLines, MakeCardScrollable, RowHoverTick, economyWidgets =
	ns.ACCENT, ns.GREEN, ns.RED, ns.CATEGORY_LABELS, ns.CategoryNames, ns.SortedCategories, ns.DisplayChar, ns.SetTile, ns.CreateTileRow, ns.CreateListCard, ns.ROW_STEP, ns.FillCardRows, ns.ShowCardText, ns.AddCardTitleNote, ns.FillScrollingLines, ns.MakeCardScrollable, ns.RowHoverTick, ns.economyWidgets

local function PinCardRowToBottom(card, rowIndex)
	local row = card.rowLines and card.rowLines[rowIndex]
	if not row then
		return
	end
	row:ClearAllPoints()
	row:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 12, 10)
	row:SetPoint("RIGHT", card, "RIGHT", -12, 0)
end

local function RefreshEconomyLedger()
	if not economyWidgets.income then
		return
	end
	local char = DisplayChar()
	if not char then
		for index = 1, #economyWidgets.tiles do
			SetTile(economyWidgets.tiles[index], "-", "")
		end
		ShowCardText(economyWidgets.income, "No data yet.")
		ShowCardText(economyWidgets.spend, "No data yet.")
		ShowCardText(economyWidgets.recent, "No data yet.")
		return
	end

	local gold = char.gold
	-- The first reading is the opening balance of the earliest session Tally
	-- recorded, so it survives the stored field being cleared or re-derived.
	local firstReading = ns.money.FirstReading(char)
	-- Read from the record, never from a bare name: these two were undefined
	-- globals until this line, which a nil comparison turns into an error.
	local unclassifiedIn = (gold.unclassified and gold.unclassified.cashIn) or 0
	local unclassifiedOut = (gold.unclassified and gold.unclassified.cashOut) or 0
	local balanceSub = "first reading pending"
	if firstReading then
		-- A first reading of nothing says only that Tally met the character
		-- with an empty purse; it is left off rather than stated.
		balanceSub = firstReading > 0 and ("Initial: "..ns.FormatMoneyBig(firstReading, 11)) or ""
	end
	SetTile(economyWidgets.tiles[1], ns.MoneyString(gold.balance or 0, 15), balanceSub)
	if firstReading and gold.balance then
		local delta = gold.balance - firstReading
		-- The delta uses the client's coin icons with a plain sign in front.
		local money
		if delta < 0 then
			money = "-"..ns.MoneyString(-delta, 15)
		elseif delta > 0 then
			money = "+"..ns.MoneyString(delta, 15)
		else
			money = ns.MoneyString(0, 15)
		end
		SetTile(economyWidgets.tiles[2], money, "tracked since "..ns.FormatDate(char.created))
	else
		SetTile(economyWidgets.tiles[2], "-", "waiting for a second reading")
	end
	local earned, spent = ns.money.Totals(gold)
	-- The tiles carry the figure only: the amounts per category are named in
	-- the cards below, where there is room for them. The spending line names
	-- the categories instead, which is what the tile has room for.
	SetTile(economyWidgets.tiles[3], earned > 0 and ("+"..ns.MoneyString(earned, 15)) or ns.MoneyString(0, 15), "")
	local names = CategoryNames(gold.expenses, 2)
	SetTile(economyWidgets.tiles[4], spent > 0 and ("-"..ns.MoneyString(spent, 15)) or ns.MoneyString(0, 15), spent > 0 and names or "")

	-- Both windows hold six rows and end with their own total, so the named
	-- categories are capped to leave that row in place however busy the
	-- character has been; the tiles above carry the figures the rows do not
	-- have room for. Unclassified is a source like any other and gets a row
	-- when anything arrived that way (Y5), and the total line answers "and all
	-- of it together?" without naming a day (Y7, Y8).
	local incomeRows = math.max(2, math.floor((economyWidgets.income:GetHeight() - 46) / ROW_STEP))
	local incomeExtra = (unclassifiedIn > 0) and 1 or 0
	local incomeEntries = {}
	local incomeList = SortedCategories(gold.income, incomeRows - 1 - incomeExtra)
	for index = 1, #incomeList do
		incomeEntries[#incomeEntries + 1] = {
			left = incomeList[index].name,
			right = ns.MoneyColored(incomeList[index].value),
		}
	end
	if unclassifiedIn > 0 then
		incomeEntries[#incomeEntries + 1] = {
			left = "Unclassified",
			right = ns.MoneyColored(unclassifiedIn),
			tip = {
				kind = "note", title = "Unclassified",
				lines = {
					{ text = ns.MoneyColored(unclassifiedIn).." arrived without Tally being able to name the source.", color = { 1, 1, 1 } },
				},
			},
		}
	end
	incomeEntries[#incomeEntries + 1] = {
		left = "total income",
		leftColor = ACCENT,
		right = ns.MoneyColored(earned),
	}
	local incomeDrawn = FillCardRows(economyWidgets.income, incomeEntries, 26)
	if incomeDrawn == 0 then
		ShowCardText(economyWidgets.income, "Nothing earned since Tally was installed.")
	else
		PinCardRowToBottom(economyWidgets.income, incomeDrawn)
	end

	-- The spending window's own rows. What arrived unclassified already has a
	-- row in the income window above, so this window's Unclassified row carries
	-- only what left the purse that way; the number of changes and the two
	-- directions are in the row's hover.
	local spendRows = math.max(2, math.floor((economyWidgets.spend:GetHeight() - 46) / ROW_STEP))
	local spendExtra = (unclassifiedOut > 0) and 1 or 0
	local spendEntries = {}
	local spendList = SortedCategories(gold.expenses, spendRows - 1 - spendExtra)
	for index = 1, #spendList do
		spendEntries[#spendEntries + 1] = {
			left = spendList[index].name,
			right = ns.MoneyColored(spendList[index].value),
		}
	end
	if unclassifiedOut > 0 then
		spendEntries[#spendEntries + 1] = {
			left = "Unclassified",
			right = ns.MoneyColored(unclassifiedOut),
			tip = {
				kind = "note", title = "Unclassified",
				lines = {
					{ text = ns.MoneyColored(unclassifiedIn).." came in and "..ns.MoneyColored(unclassifiedOut).." went out, over "..(gold.unclassified.count or 0)..((gold.unclassified.count or 0) == 1 and " change" or " changes")..".", color = { 1, 1, 1 } },
					{ text = "Tally could not name the source or the sink, so the money is kept out of the named categories and counted in the totals.", color = { 0.7, 0.7, 0.7 } },
				},
			},
		}
	end
	spendEntries[#spendEntries + 1] = {
		left = "total spending",
		leftColor = ACCENT,
		right = ns.MoneyColored(spent),
	}
	local spendDrawn = FillCardRows(economyWidgets.spend, spendEntries, 26)
	if spendDrawn == 0 then
		ShowCardText(economyWidgets.spend, "Nothing spent since Tally was installed.")
	else
		PinCardRowToBottom(economyWidgets.spend, spendDrawn)
	end

	-- Every stored change, newest first, in a scrolling window: the card holds
	-- ten rows and the wheel walks the rest. The left text is allowed its
	-- whole width, so a category name is never cut in half.
	local recentLines = {}
	for index = #gold.tx, 1, -1 do
		local transaction = gold.tx[index]
		recentLines[#recentLines + 1] = {
			left = ns.FormatDateTime(transaction.t).."  ·  "..(CATEGORY_LABELS[transaction.c] or transaction.c),
			right = ns.FormatMoneyDelta(transaction.d),
			rightColor = (transaction.d or 0) > 0 and GREEN or ((transaction.d or 0) < 0 and RED or nil),
		}
	end
	if FillScrollingLines(economyWidgets.recent, recentLines, economyWidgets, "txScrollOffset", "Recent money changes", 60) == 0 then
		ShowCardText(economyWidgets.recent, "No money changes recorded yet.")
	end
end

local function BuildEconomyLedger(ledger)
	CreateTileRow(ledger, -4, { "Balance", "Since tracking", "Income", "Spending" }, economyWidgets.tiles, false, 0)
	-- The two money boxes answer a hover with what they are: totals since the
	-- first reading, not nets, so a reader does not have to work out whether
	-- spending has already been taken off.
	local tileNotes = {
		[3] = "Income is every coin that came in since Tally's first reading of this character, including any it could not name a source for. It is a total, not a net: money spent does not reduce it.",
		[4] = "Spending is every coin that went out since Tally's first reading of this character, including any it could not name a source for. It is a total of its own, not taken off the income figure.",
	}
	for index, note in pairs(tileNotes) do
		local tile = economyWidgets.tiles[index]
		tile:EnableMouse(true)
		tile:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(self.label:GetText() or "Money", ACCENT[1], ACCENT[2], ACCENT[3])
			GameTooltip:AddLine(note, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		tile:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
	end
	economyWidgets.income = CreateListCard(ledger, 0, -88, 359, 150, "Income")
	economyWidgets.spend = CreateListCard(ledger, 371, -88, 359, 150, "Spending")
	-- Both windows answer a hover: the Unclassified rows use it to name the
	-- two directions and the number of changes behind the one figure shown.
	for _, card in ipairs({ economyWidgets.income, economyWidgets.spend }) do
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
	-- 184, not 210: the sub-view's own frame ends 26 above the page's bottom
	-- (it starts at -26), so a taller card would run through the footer.
	economyWidgets.recent = CreateListCard(ledger, 0, -250, 730, 184, "Recent money changes")
	AddCardTitleNote(economyWidgets.recent, "Recent money changes",
		"Every change Tally has booked, newest first, with the date, the clock and the category it was booked under. A change is \"unclassified\" only when nothing Tally can see explains it.")
	MakeCardScrollable(economyWidgets.recent, economyWidgets, "txScrollOffset", function() ns.RefreshEconomy() end)
end

ns.BuildEconomyLedger, ns.RefreshEconomyLedger = BuildEconomyLedger, RefreshEconomyLedger
