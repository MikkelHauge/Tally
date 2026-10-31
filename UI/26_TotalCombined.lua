-- Tally - the Total tab's combined sub-view: the selected characters added up.
local addonName, ns = ...

local ACCENT, SetTile, CreateTileRow, CreateListCard, QUALITY_COLORS, ItemQuality, SumBucket, SortedCategories, ClassColorCode, FillScrollingLines, FillCardRows, ShowCardText, AddCardTitleNote, MakeCardScrollable, ShowCharPicker, totalWidgets =
	ns.ACCENT, ns.SetTile, ns.CreateTileRow, ns.CreateListCard, ns.QUALITY_COLORS, ns.ItemQuality, ns.SumBucket, ns.SortedCategories, ns.ClassColorCode, ns.FillScrollingLines, ns.FillCardRows, ns.ShowCardText, ns.AddCardTitleNote, ns.MakeCardScrollable, ns.ShowCharPicker, ns.totalWidgets

local LEDGER_NOTE = "Money moved between your own characters shows up on both sides: it is income for one and spending for the other, so the totals include it twice rather than quietly hiding it."

-- Adds one ledger line per money category, up to `cap` of them, then an
-- "other" line summing the rest. The line names up to three of the
-- categories it covers, so nothing on the combined ledger is invisible.
local function AddLedgerCategoryRows(entries, bucket, cap)
	local list = SortedCategories(bucket, cap)
	for index = 1, #list do
		entries[#entries + 1] = { left = "   "..list[index].name, right = ns.MoneyColored(list[index].value) }
	end
	local rest = SortedCategories(bucket, nil)
	if #rest <= #list then
		return
	end
	local total = 0
	local names = {}
	for index = #list + 1, #rest do
		total = total + rest[index].value
		if #names < 3 then
			names[#names + 1] = rest[index].name
		end
	end
	if #rest - #list > #names then
		names[#names + 1] = "+"..(#rest - #list - #names)
	end
	entries[#entries + 1] = {
		left = "   other ("..table.concat(names, ", ")..")",
		right = ns.MoneyColored(total),
	}
end

local function RefreshTotalCombined()
	local agg = ns.AggregateTotal()
	local label = ns.TotalSelectionLabel()
	local tiles = totalWidgets.tiles

	if agg.chars == 0 then
		for index = 1, #tiles do
			SetTile(tiles[index], "-", "")
		end
		SetTile(tiles[4], "0", "nothing ticked")
		ShowCardText(totalWidgets.who, "Every character is unticked, so there is nothing to combine.\n\nUse the \"Edit characters\" button above to tick the ones you want.")
		ShowCardText(totalWidgets.ledger, "")
		return
	end

	-- Row 1: the headline combined numbers.
	local playedText, playedSub = "-", "no /played figure has been synced yet"
	if agg.playedKnown > 0 then
		playedText = ns.FormatDuration(agg.played)
		playedSub = "combined from selected characters"
	end
	SetTile(tiles[1], playedText, playedSub)

	if agg.goldKnown > 0 then
		SetTile(tiles[2], ns.MoneyString(agg.gold, 15), "Last known combined balance")
	else
		SetTile(tiles[2], "-", "no balance recorded yet")
	end

	SetTile(tiles[3], ns.FormatNumber(agg.fights).." / "..ns.FormatNumber(agg.deaths), "Since tracked")

	-- The fourth box answers one question plainly instead of trying to carry
	-- three: how many quests the selected characters have finished between
	-- them. Characters left out of the total are named, since that is the one
	-- fact the box used to hold that is not stated anywhere else.
	local questSub = "by the selected characters"
	if #agg.excluded > 0 then
		questSub = #agg.excluded..(#agg.excluded == 1 and " character left out" or " characters left out")
	end
	SetTile(tiles[4], ns.FormatNumber(agg.quests), questSub)

	-- Row 2: tracked time, sessions, items and zones.
	SetTile(tiles[5], ns.FormatDuration(agg.tracked), agg.oldest and ("Tally has been watching since "..ns.FormatDate(agg.oldest)) or "nothing recorded yet")

	local sessionSub = "no finished sessions yet"
	if agg.sessions > 0 then
		sessionSub = "avg "..ns.FormatDuration(math.floor(agg.sessionSeconds / agg.sessions), true).." - longest "..ns.FormatDuration(agg.sessionLongest, true)
	end
	SetTile(tiles[6], ns.FormatNumber(agg.sessions), sessionSub)

	local lootSub = "item values unavailable here"
	if agg.itemValueKnown then
		lootSub = ns.MoneyColored(agg.itemValue).." vendor value"
	end
	SetTile(tiles[7], ns.FormatNumber(agg.items), lootSub)

	local dungeonRuns = 0
	for _, dungeon in pairs(agg.dungeons) do
		dungeonRuns = dungeonRuns + (dungeon.entered or 0)
	end
	-- "Dungeons" counts distinct instances, "runs" counts the times a
	-- character zoned into one, so one visit to one dungeon reads as
	-- "1 dungeon, 1 run" until it is entered again.
	local dungeonCount = ns.CountTable(agg.dungeons)
	local dungeonText = "no dungeon entered yet"
	if dungeonCount > 0 or dungeonRuns > 0 then
		dungeonText = dungeonCount..(dungeonCount == 1 and " dungeon" or " dungeons")
			..", "..dungeonRuns..(dungeonRuns == 1 and " run" or " runs")
			.."  ·  "..agg.bosses..(agg.bosses == 1 and " boss" or " bosses")
	end
	SetTile(tiles[8], tostring(ns.CountTable(agg.zones)), dungeonText)

	-- One tall row per included character: name, level and class on the first
	-- line, balance and /played on the dim detail line. Excluded characters
	-- are not listed here; tiles[4] only counts them. The card scrolls, so a
	-- total of any size can be read.
	local whoLines = {}
	for index = 1, #agg.included do
		local entry = agg.included[index]
		local char = entry.char
		local color = ClassColorCode(char.classFile)
		local played = (char.played and char.played.total) and ns.FormatDuration(char.played.total, true) or "no /played"
		local gold = (char.gold and char.gold.balance) and ns.MoneyColored(char.gold.balance) or "-"
		whoLines[#whoLines + 1] = {
			left = (color or "")..ns.DisplayName(char).."|r "..(char.level or 0).." "..(color or "")..(char.class or "?").."|r",
			detail = gold,
			detailRight = played,
			tip = {
				kind = "note",
				title = ns.FullName(char),
				lines = {
					{ text = "Level "..(char.level or 0).." "..(char.class or "?").."  ·  "..(ns.CharFaction(char) or "side unknown"), color = { 0.8, 0.8, 0.8 } },
					{ text = "Tracked by Tally for "..ns.FormatDuration(char.tracked or 0).."  ·  "..(char.quests or 0).." quests completed", color = { 0.7, 0.7, 0.7 } },
				},
			},
		}
	end
	if FillScrollingLines(totalWidgets.who, whoLines, totalWidgets, "whoScrollOffset", "Who is in this total", 46, true) == 0 then
		ShowCardText(totalWidgets.who, "Nothing to list yet.")
	end

	-- The combined ledger: labels left, money right, and up to four best
	-- finds with their owner and value. Transfers between own characters
	-- appear on both sides (see LEDGER_NOTE). Categories past the named rows
	-- (mail, auction and trade among them) are summed into an "other" line.
	local ledgerEntries = {}
	local incomeTotal = SumBucket(agg.income) + (agg.unclassifiedIn or 0)
	local expenseTotal = SumBucket(agg.expenses) + (agg.unclassifiedOut or 0)
	ledgerEntries[#ledgerEntries + 1] = { left = "Money in", right = ns.MoneyColored(incomeTotal) }
	AddLedgerCategoryRows(ledgerEntries, agg.income, 4)
	ledgerEntries[#ledgerEntries + 1] = { left = "Money out", right = ns.MoneyColored(expenseTotal) }
	AddLedgerCategoryRows(ledgerEntries, agg.expenses, 3)
	if (agg.unclassifiedIn or 0) > 0 or (agg.unclassifiedOut or 0) > 0 then
		ledgerEntries[#ledgerEntries + 1] = {
			left = "unclassified",
			right = ns.MoneyColored(agg.unclassifiedIn or 0).." in, "..ns.MoneyColored(agg.unclassifiedOut or 0).." out",
		}
	end
	ledgerEntries[#ledgerEntries + 1] = { left = "Best finds", right = "", leftColor = ACCENT }
	local finds = 0
	for index = 1, #agg.best do
		if finds >= 3 then
			break
		end
		local find = agg.best[index]
		local ownerColor = ClassColorCode(find.ownerClass)
		ledgerEntries[#ledgerEntries + 1] = {
			left = find.name or "?",
			leftColor = QUALITY_COLORS[ItemQuality(find)] or QUALITY_COLORS[1],
			right = (ownerColor or "")..(find.owner or "?").."|r  ·  "..ns.MoneyColored(find.value or 0),
		}
		finds = finds + 1
	end
	if finds == 0 then
		ledgerEntries[#ledgerEntries + 1] = { left = "nothing looted yet", right = "" }
	end
	if FillCardRows(totalWidgets.ledger, ledgerEntries, 30) == 0 then
		ShowCardText(totalWidgets.ledger, "")
	end
end

local function BuildTotalCombined(combined)
	CreateTileRow(combined, -4, { "Total played", "Combined gold", "Fights / deaths", "Quests completed" }, totalWidgets.tiles, false, 0)
	CreateTileRow(combined, -76, { "Tracked by Tally", "Sessions", "Items looted", "Zones visited" }, totalWidgets.tiles, false, 4)
	local tiles = totalWidgets.tiles
	totalWidgets.who = CreateListCard(combined, 0, -148, 359, 274, "Who is in this total")
	-- A total can hold more characters than the card fits, so the list walks
	-- on the wheel like the other long cards, and its window is named in the
	-- title when part of the list is off screen.
	MakeCardScrollable(totalWidgets.who, totalWidgets, "whoScrollOffset", RefreshTotalCombined)
	totalWidgets.ledger = CreateListCard(combined, 371, -148, 359, 274, "Combined money and best finds")
	-- Tighter rows than the default: the "other" money lines added with the
	-- named categories need two more rows than the card held.
	totalWidgets.ledger.rowStep = 14
	AddCardTitleNote(totalWidgets.ledger, "Combined money and best finds", LEDGER_NOTE)

	-- The one characters picker, opened from here; the "who" card has room
	-- for it now that the old panel is gone.
	local editButton = CreateFrame("Button", nil, totalWidgets.who, "UIPanelButtonTemplate")
	editButton:SetSize(126, 20)
	editButton:SetPoint("TOPRIGHT", totalWidgets.who, "TOPRIGHT", -8, -4)
	editButton:SetText("characters")
	editButton:SetScript("OnClick", function()
		ShowCharPicker("levels", true)
	end)
	editButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Characters", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("select which characters to use", 1, 1, 1, true)
		GameTooltip:AddLine("The same choice as the economy graph and the level-times chart: the combined figures, both charts and the records below all follow it. A character's own record is never changed.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	editButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

ns.BuildTotalCombined, ns.RefreshTotalCombined = BuildTotalCombined, RefreshTotalCombined
