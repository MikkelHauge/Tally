-- Tally - the Total tab's records sub-view: the best of each measurement
-- across the selected characters.
local addonName, ns = ...

local ACCENT, CreateListCard, AddCardTitleNote, MakeCardScrollable, CreateCornerButton, SetCornerLabel, ClassColorCode, QualityCode, ItemQuality, CutRowText, FillScrollingLines, ShowCardText, ShowCharPicker, totalWidgets =
	ns.ACCENT, ns.CreateListCard, ns.AddCardTitleNote, ns.MakeCardScrollable, ns.CreateCornerButton, ns.SetCornerLabel, ns.ClassColorCode, ns.QualityCode, ns.ItemQuality, ns.CutRowText, ns.FillScrollingLines, ns.ShowCardText, ns.ShowCharPicker, ns.totalWidgets

-- The records sub-view: the single best of each measurement across the
-- selected characters, from ns.Records(). Every fifth level is a milestone.
local RECORD_MILESTONES = {}
for milestone = 5, 60, 5 do
	RECORD_MILESTONES[#RECORD_MILESTONES + 1] = milestone
end

-- The explanatory note for the records card, shown as a tooltip on the card
-- title (AddCardTitleNote).
local RECORDS_NOTE = "Every row is the best figure of its kind across the ticked characters, with the date and the character who holds it. Use the order button to group the rows by section, by character or by name."
local LEDGER_NOTE = "Money moved between your own characters shows up on both sides: it is income for one and spending for the other, so the totals include it twice rather than quietly hiding it."

-- The orders the records card can be shown in, and the short label its
-- button carries for each. The button cycles them, exactly as the
-- profession list's order button does.
local RECORD_SORTS = { "sections", "characters", "alpha" }

local function NextRecordSort(mode)
	for index = 1, #RECORD_SORTS do
		if RECORD_SORTS[index] == mode then
			return RECORD_SORTS[index % #RECORD_SORTS + 1]
		end
	end
	return RECORD_SORTS[1]
end

local function RecordSortLabel(mode)
	if mode == "characters" then
		return "by character"
	end
	if mode == "alpha" then
		return "A-Z"
	end
	return "sections"
end

local function RefreshTotalRecords()
	local card = totalWidgets.records
	if not card then
		return
	end
	local records = ns.Records()
	local function Name(record)
		if not record then
			return "?"
		end
		return (ClassColorCode(record.classFile) or "")..(record.name or "?").."|r"
	end
	-- The colour an item record should be drawn in: the quality it kept, or
	-- the game's answer for its id or name when a sale invoice stated none.
	local function ItemCode(record)
		if not record then
			return ""
		end
		return QualityCode(ItemQuality{ quality = record.quality, id = record.itemID, name = record.item })
	end

	-- Every record becomes one row of four columns: what it is, the date it
	-- happened where there is one, the figure, and who holds it. The holder
	-- column carries the character and any remark about them.
	local items = {}
	local function AddRecord(section, label, value, record, remark, date)
		if not value then
			return
		end
		local holder, plain, color
		if record then
			holder = Name(record)
			plain = record.name
			color = ClassColorCode(record.classFile)
			if remark then
				holder = holder.."  ·  "..remark
			end
		elseif remark then
			holder = remark
		end
		items[#items + 1] = {
			section = section, label = label, value = value,
			holder = holder or "", plain = plain, color = color, date = date or "",
		}
	end

	for index = 1, #RECORD_MILESTONES do
		local milestone = RECORD_MILESTONES[index]
		local record = records.fastestTo and records.fastestTo[milestone]
		if record then
			AddRecord("Fastest to each level", "to level "..milestone, ns.FormatDuration(record.seconds, true),
				record, nil, record.at and ns.FormatDate(record.at))
		end
	end

	AddRecord("Levels and experience", "Highest XP rate over 10 minutes",
		records.bestRate and (ns.FormatCompact(records.bestRate.rate).." XP/h"),
		records.bestRate,
		records.bestRate and (ns.FormatNumber(records.bestRate.gained or 0).." XP in those ten minutes"),
		records.bestRate and records.bestRate.at and ns.FormatDate(records.bestRate.at))
	AddRecord("Levels and experience", "Most levels since install",
		records.mostLevels and (records.mostLevels.count..(records.mostLevels.count == 1 and " level" or " levels")),
		records.mostLevels, records.mostLevels and ("since "..ns.FormatDate(records.mostLevels.at)))
	AddRecord("Levels and experience", "First level-up Tally saw",
		records.firstLevelUp and ("to level "..records.firstLevelUp.level),
		records.firstLevelUp, nil, records.firstLevelUp and ns.FormatDate(records.firstLevelUp.at))

	AddRecord("Sessions", "Longest session",
		records.longestSession and ns.FormatDuration(records.longestSession.seconds),
		records.longestSession, nil, records.longestSession and ns.FormatDate(records.longestSession.start))
	AddRecord("Sessions", "Most XP in one session",
		records.bestSessionXp and (ns.FormatCompact(records.bestSessionXp.amount).." XP"),
		records.bestSessionXp, nil, records.bestSessionXp and ns.FormatDate(records.bestSessionXp.start))
	AddRecord("Sessions", "Most levels in one session",
		records.mostSessionLevels and (records.mostSessionLevels.count..(records.mostSessionLevels.count == 1 and " level" or " levels")),
		records.mostSessionLevels, nil, records.mostSessionLevels and ns.FormatDate(records.mostSessionLevels.start))
	AddRecord("Sessions", "Most gold earned in one session",
		records.bestSessionGold and ns.FormatMoneyDelta(records.bestSessionGold.amount),
		records.bestSessionGold, nil, records.bestSessionGold and ns.FormatDate(records.bestSessionGold.start))
	AddRecord("Sessions", "Most items in one session",
		records.mostItems and (records.mostItems.count.." items"),
		records.mostItems, nil, records.mostItems and ns.FormatDate(records.mostItems.start))
	AddRecord("Sessions", "Most fights in one session",
		records.mostFights and (records.mostFights.count.." fights"),
		records.mostFights, nil, records.mostFights and ns.FormatDate(records.mostFights.start))
	AddRecord("Sessions", "Most deaths in one session",
		records.mostDeaths and (records.mostDeaths.count.." deaths"),
		records.mostDeaths, nil, records.mostDeaths and ns.FormatDate(records.mostDeaths.start))
	AddRecord("Sessions", "Most new places in one session",
		records.mostFirsts and (records.mostFirsts.count.." first visits"),
		records.mostFirsts, nil, records.mostFirsts and ns.FormatDate(records.mostFirsts.start))

	AddRecord("Money", "Biggest day of income",
		records.bestDayIncome and ns.MoneyColored(records.bestDayIncome.amount),
		records.bestDayIncome, nil, records.bestDayIncome and ns.FormatDate(ns.DayToTime(records.bestDayIncome.day)))
	AddRecord("Money", "Biggest day of spending",
		records.bestDayExpense and ns.MoneyColored(records.bestDayExpense.amount),
		records.bestDayExpense, nil, records.bestDayExpense and ns.FormatDate(ns.DayToTime(records.bestDayExpense.day)))
	-- Repairs are a sum over the ticked characters. With exactly one ticked it
	-- is that character's own figure, so the row belongs to them (and sits
	-- under them in the by-character order); with several it is a figure for
	-- all of them.
	local repairTotal = 0
	local repairHolder, repairRemark
	local tickedCount, tickedName, tickedClassFile = 0, nil, nil
	local known = ns.KnownCharacters()
	for index = 1, #known do
		if ns.TotalIncludes(known[index].key) then
			tickedCount = tickedCount + 1
			tickedName = known[index].char.name or "?"
			tickedClassFile = known[index].char.classFile
			repairTotal = repairTotal + ((((known[index].char.gold or {}).expenses) or {}).repair or 0)
		end
	end
	if tickedCount == 1 then
		repairHolder = { name = tickedName, classFile = tickedClassFile }
	else
		repairRemark = "all characters"
	end
	AddRecord("Money", "Repair cost total", ns.MoneyColored(repairTotal), repairHolder, repairRemark)
	AddRecord("Money", "Most income from quests",
		records.mostQuestGold and ns.MoneyColored(records.mostQuestGold.value),
		records.mostQuestGold)

	AddRecord("World", "Most zones visited",
		records.mostZones and (tostring(records.mostZones.count)..(records.mostZones.count == 1 and " zone" or " zones")),
		records.mostZones)
	AddRecord("World", "Most dungeons visited",
		records.mostDungeons and (tostring(records.mostDungeons.count)..(records.mostDungeons.count == 1 and " dungeon" or " dungeons")),
		records.mostDungeons)
	AddRecord("World", "Most dungeon runs",
		records.mostDungeonRuns and (tostring(records.mostDungeonRuns.count)..(records.mostDungeonRuns.count == 1 and " run" or " runs")),
		records.mostDungeonRuns)
	AddRecord("World", "Most dungeon bosses killed",
		records.mostBosses and (tostring(records.mostBosses.count)..(records.mostBosses.count == 1 and " boss" or " bosses")),
		records.mostBosses)
	AddRecord("World", "Most time mounted",
		records.mostMounted and ns.FormatDuration(records.mostMounted.seconds),
		records.mostMounted)
	AddRecord("World", "Most deaths",
		records.mostDeathsByChar and (tostring(records.mostDeathsByChar.count)..(records.mostDeathsByChar.count == 1 and " death" or " deaths")),
		records.mostDeathsByChar)
	AddRecord("World", "Fewest deaths",
		records.fewestDeaths and (tostring(records.fewestDeaths.count)..(records.fewestDeaths.count == 1 and " death" or " deaths")),
		records.fewestDeaths, records.fewestDeaths and ns.FormatDuration(records.fewestDeaths.tracked))

	AddRecord("Social", "Most mails sent",
		records.mostMailSent and (ns.FormatNumber(records.mostMailSent.count)..(records.mostMailSent.count == 1 and " mail" or " mails")),
		records.mostMailSent)
	AddRecord("Social", "Most mails received",
		records.mostMailReceived and (ns.FormatNumber(records.mostMailReceived.count)..(records.mostMailReceived.count == 1 and " mail" or " mails")),
		records.mostMailReceived)
	AddRecord("Social", "Most messages sent",
		records.mostMessagesSent and (ns.FormatNumber(records.mostMessagesSent.count)..(records.mostMessagesSent.count == 1 and " message" or " messages")),
		records.mostMessagesSent)
	AddRecord("Social", "Most whispers received",
		records.mostWhispersReceived and (ns.FormatNumber(records.mostWhispersReceived.count)..(records.mostWhispersReceived.count == 1 and " whisper" or " whispers")),
		records.mostWhispersReceived)
	AddRecord("Social", "Most duels won",
		records.mostDuelsWon and (ns.FormatNumber(records.mostDuelsWon.count)..(records.mostDuelsWon.count == 1 and " duel" or " duels")),
		records.mostDuelsWon)
	AddRecord("Social", "Most duels lost",
		records.mostDuelsLost and (ns.FormatNumber(records.mostDuelsLost.count)..(records.mostDuelsLost.count == 1 and " duel" or " duels")),
		records.mostDuelsLost)

	AddRecord("Items and professions", "Best find",
		records.bestFind and ns.MoneyColored(records.bestFind.value),
		records.bestFind, records.bestFind and (ItemCode(records.bestFind)..(records.bestFind.item or "?").."|r"),
		records.bestFind and ns.FormatDate(records.bestFind.at))
	AddRecord("Items and professions", "Most looted item",
		records.mostLooted and ((records.mostLooted.estimated and "at least " or "")
			..ns.FormatNumber(records.mostLooted.count).." x "..ItemCode(records.mostLooted)
			..CutRowText(records.mostLooted.item or "?", 22).."|r"),
		records.mostLooted)
	AddRecord("Items and professions", "Most quests completed",
		records.mostQuests and (ns.FormatNumber(records.mostQuests.count)..(records.mostQuests.count == 1 and " quest" or " quests")),
		records.mostQuests)
	AddRecord("Items and professions", "Most items crafted",
		records.mostCrafted and (ns.FormatNumber(records.mostCrafted.count)..(records.mostCrafted.count == 1 and " item" or " items")),
		records.mostCrafted)
	AddRecord("Items and professions", "Most crafted item",
		records.mostCraftedItem and (ns.FormatNumber(records.mostCraftedItem.count).." x "
			..ItemCode(records.mostCraftedItem)
			..CutRowText(records.mostCraftedItem.item or "?", 22).."|r"),
		records.mostCraftedItem)

	-- One row per profession that has a crafted item, then the cooldown
	-- records for cooldowns someone actually used. Professions and cooldowns
	-- with no activation have no row at all.
	local professionNames = {}
	for profession in pairs(records.mostCraftedByProfession or {}) do
		professionNames[#professionNames + 1] = profession
	end
	table.sort(professionNames)
	for index = 1, #professionNames do
		local profession = professionNames[index]
		local record = records.mostCraftedByProfession[profession]
		AddRecord("Items and professions", "Most crafted - "..profession,
			ns.FormatNumber(record.count).." x "..ItemCode(record)
				..CutRowText(record.item or "?", 24).."|r", record)
	end
	local cooldownRows = {}
	for key, record in pairs(records.cooldownUses or {}) do
		cooldownRows[#cooldownRows + 1] = { key = key, record = record, kind = "uses" }
	end
	for key, record in pairs(records.cooldownOff or {}) do
		cooldownRows[#cooldownRows + 1] = { key = key, record = record, kind = "off" }
	end
	for key, record in pairs(records.cooldownShortest or {}) do
		cooldownRows[#cooldownRows + 1] = { key = key, record = record, kind = "shortest" }
	end
	table.sort(cooldownRows, function(a, b)
		local aName = (a.record.cooldown or a.key)..a.kind
		local bName = (b.record.cooldown or b.key)..b.kind
		return aName < bName
	end)
	for index = 1, #cooldownRows do
		local row = cooldownRows[index]
		local record = row.record
		local label
		if row.kind == "uses" then
			label = "Cooldown uses - "..(record.cooldown or "?")
		elseif row.kind == "off" then
			label = "Cooldown off time - "..(record.cooldown or "?")
		else
			label = "Cooldown shortest off - "..(record.cooldown or "?")
		end
		local value
		if row.kind == "uses" then
			value = ns.FormatNumber(record.count)..(record.count == 1 and " use" or " uses")
		else
			value = ns.FormatDuration(record.seconds, true)
		end
		AddRecord("Items and professions", label, value, record)
	end

	-- The auction house, from the invoices Tally read: the most expensive single
	-- purchase and sale, and who has moved the most items each way. A
	-- character who never bought or sold has no row to win.
	AddRecord("Auction house", "Most expensive purchase",
		records.bestBuyAuction and ns.MoneyColored(records.bestBuyAuction.value),
		records.bestBuyAuction,
		records.bestBuyAuction and (ItemCode(records.bestBuyAuction)
			..(records.bestBuyAuction.item or "?").."|r"),
		records.bestBuyAuction and records.bestBuyAuction.at and ns.FormatDate(records.bestBuyAuction.at))
	AddRecord("Auction house", "Most valuable sale",
		records.bestSellAuction and ns.MoneyColored(records.bestSellAuction.value),
		records.bestSellAuction,
		records.bestSellAuction and (ItemCode(records.bestSellAuction)
			..(records.bestSellAuction.item or "?").."|r"),
		records.bestSellAuction and records.bestSellAuction.at and ns.FormatDate(records.bestSellAuction.at))
	AddRecord("Auction house", "Most items sold",
		records.mostSoldUnits and (ns.FormatNumber(records.mostSoldUnits.count).." items"),
		records.mostSoldUnits,
		records.mostSoldUnits and (ns.FormatNumber(records.mostSoldUnits.sales)
			..(records.mostSoldUnits.sales == 1 and " sale" or " sales")))
	AddRecord("Auction house", "Most items bought",
		records.mostBoughtUnits and (ns.FormatNumber(records.mostBoughtUnits.count).." items"),
		records.mostBoughtUnits,
		records.mostBoughtUnits and (ns.MoneyColored(records.mostBoughtUnits.spent).." spent"))

	-- Rendering, one branch per order. Every row is drawn by EmitRow, so the
	-- four columns line up whatever order the rows arrive in.
	local mode = totalWidgets.recordsSort or "sections"
	local lines = {}
	local function EmitRow(item)
		lines[#lines + 1] = {
			left = item.label,
			mid2 = item.date,
			mid = item.value,
			right = item.holder,
		}
	end
	if mode == "alpha" then
		local sorted = {}
		for index = 1, #items do
			sorted[#sorted + 1] = items[index]
		end
		table.sort(sorted, function(a, b)
			if a.label == b.label then
				return (a.plain or "") < (b.plain or "")
			end
			return a.label < b.label
		end)
		for index = 1, #sorted do
			EmitRow(sorted[index])
		end
	elseif mode == "characters" then
		-- One block per character, alphabetically, with whatever is not one
		-- character's own record at the end.
		local groups, order = {}, {}
		for index = 1, #items do
			local item = items[index]
			local key = item.plain or ""
			if not groups[key] then
				groups[key] = { name = item.plain, color = item.color, rows = {} }
				order[#order + 1] = key
			end
			table.insert(groups[key].rows, item)
		end
		table.sort(order, function(a, b)
			if a == "" or b == "" then
				return b == ""
			end
			return a < b
		end)
		for index = 1, #order do
			local group = groups[order[index]]
			if group.name then
				lines[#lines + 1] = { left = (group.color or "")..group.name.."|r" }
			else
				lines[#lines + 1] = { left = "All characters", leftColor = ACCENT }
			end
			for rowIndex = 1, #group.rows do
				EmitRow(group.rows[rowIndex])
			end
		end
	else
		local section
		for index = 1, #items do
			local item = items[index]
			if item.section ~= section then
				section = item.section
				if section then
					lines[#lines + 1] = { left = section, leftColor = ACCENT }
				end
			end
			EmitRow(item)
		end
	end

	-- The button's label follows the order, wherever the change came from.
	if totalWidgets.recordsSortButton then
		SetCornerLabel(totalWidgets.recordsSortButton, RecordSortLabel(mode))
	end
	if FillScrollingLines(card, lines, totalWidgets, "recordsScrollOffset", "Records", 40) == 0 then
		ShowCardText(card, "No records yet: they appear as the selected characters play.")
	end
end

local function BuildTotalRecords(records)
	totalWidgets.records = CreateListCard(records, 0, -4, 730, 434, "Records")
	-- Four columns: the record's name (left), the date (mid2), the figure
	-- (mid) and the character (right, with any remark about them). The holder
	-- needs its room at the far right, so the figure column sits well in from
	-- it and the date column between the two.
	totalWidgets.records.rowMidRight = 250
	totalWidgets.records.rowMid2Right = 390
	-- A hairline under every row: the table is long and the rows are thin.
	totalWidgets.records.rowDividers = true
	AddCardTitleNote(totalWidgets.records, "Records", RECORDS_NOTE)
	MakeCardScrollable(totalWidgets.records, totalWidgets, "recordsScrollOffset", RefreshTotalRecords)

	-- The order button, top right of the records card, built exactly like the
	-- profession list's own (frame level + 4, so the card's rows and its
	-- wheel cannot take its clicks). It cycles the three orders.
	totalWidgets.recordsSort = "sections"
	local recordSort = CreateCornerButton(totalWidgets.records)
	SetCornerLabel(recordSort, RecordSortLabel(totalWidgets.recordsSort))
	recordSort:SetScript("OnClick", function()
		totalWidgets.recordsSort = NextRecordSort(totalWidgets.recordsSort)
		totalWidgets.recordsScrollOffset = 0
		ns.Trace("record order: "..totalWidgets.recordsSort)
		RefreshTotalRecords()
	end)
	recordSort:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("The order of the records", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to cycle: sections (a heading per kind of record), by character (one block per character, so everything that character holds sits together) and A-Z (every record by name). The wheel walks the rows in any order.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	recordSort:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	totalWidgets.recordsSortButton = recordSort

	-- The same characters picker, beside the order button: the records belong
	-- to the characters ticked there, so it can be changed without leaving the
	-- page. Anchored to the order button's left so the two never overlap.
	local recordsChars = CreateCornerButton(totalWidgets.records)
	SetCornerLabel(recordsChars, "characters")
	recordsChars:ClearAllPoints()
	recordsChars:SetPoint("RIGHT", recordSort, "LEFT", -6, 0)
	recordsChars:SetScript("OnClick", function()
		ShowCharPicker("levels", true)
	end)
	recordsChars:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Characters", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("select which characters to use", 1, 1, 1, true)
		GameTooltip:AddLine("The same choice as everywhere else: the records below cover the ticked characters, and the figures and graphs follow the same ticks.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	recordsChars:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

ns.BuildTotalRecords, ns.RefreshTotalRecords = BuildTotalRecords, RefreshTotalRecords
