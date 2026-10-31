-- Tally - the Total tab's professions sub-view: the selected-character summary
-- and the cooldown board for those characters.
--
-- Both blocks read the one selection the Total picker writes. The summary is
-- drawn by the shared kit; the board lives here because only Total offers the
-- whole known cooldown list across characters.
local addonName, ns = ...

local ACCENT, AMBER, ClassColorCode, QualityCode, CreateListCard, ShowCardText,
	AddCardTitleNote, FillScrollingLines, MakeCardScrollable, AddCardScrollbar, CreateCornerButton,
	SetCornerLabel, ShowCharPicker, totalWidgets =
	ns.ACCENT, ns.AMBER, ns.ClassColorCode, ns.QualityCode, ns.CreateListCard, ns.ShowCardText,
	ns.AddCardTitleNote, ns.FillScrollingLines, ns.MakeCardScrollable, ns.AddCardScrollbar, ns.CreateCornerButton,
	ns.SetCornerLabel, ns.ShowCharPicker, ns.totalWidgets

local TPWidgets = {}

local function ReadyText(entry, now)
	if entry.known then
		return "not seen yet"
	end
	if entry.readyAt and entry.readyAt > now then
		return ns.FormatDuration(entry.readyAt - now, true).." left"
	end
	return "ready"
end

local function CooldownTip(entry)
	local lines = {
		{ text = (entry.profession or "?").." · "..(entry.ownerName or "?"), color = { 0.8, 0.8, 0.8 } },
	}
	if entry.known then
		lines[#lines + 1] = { text = "No cooldown recorded yet; use the recipe once to start tracking it.", color = { 0.7, 0.7, 0.7 } }
	elseif entry.readyAt and entry.readyAt > ns.Now() then
		lines[#lines + 1] = { text = "Ready "..ns.FormatDateTime(entry.readyAt), color = { 0.7, 0.7, 0.7 } }
		if entry.span then
			lines[#lines + 1] = { text = "Total cooldown "..ns.FormatDuration(entry.span), color = { 0.7, 0.7, 0.7 } }
		end
	else
		lines[#lines + 1] = { text = "Ready now.", color = { 0.7, 0.7, 0.7 } }
	end
	return { kind = "note", title = entry.name or "Cooldown", lines = lines }
end

local COOLDOWN_SORTS = {
	{ key = "remaining", dir = 1 },
	{ key = "remaining", dir = -1 },
	{ key = "length", dir = 1 },
	{ key = "length", dir = -1 },
	{ key = "profession", dir = 1 },
	{ key = "profession", dir = -1 },
	{ key = "character", dir = 1 },
	{ key = "character", dir = -1 },
}

local function CooldownSortLabel(sort)
	if sort.key == "remaining" then
		return sort.dir > 0 and "remaining: low" or "remaining: high"
	elseif sort.key == "length" then
		return sort.dir > 0 and "length: short" or "length: long"
	elseif sort.key == "profession" then
		return sort.dir > 0 and "profession: A-Z" or "profession: Z-A"
	end
	return sort.dir > 0 and "character: A-Z" or "character: Z-A"
end

local function NextCooldownSort(sort)
	for index = 1, #COOLDOWN_SORTS do
		local candidate = COOLDOWN_SORTS[index]
		if candidate.key == sort.key and candidate.dir == sort.dir then
			return COOLDOWN_SORTS[index % #COOLDOWN_SORTS + 1]
		end
	end
	return COOLDOWN_SORTS[1]
end

local function CooldownLine(entry, now)
	local _, _, quality = ns.ItemInfo(entry.itemID)
	local itemColour = quality and QualityCode(quality) or nil
	local detail = (ClassColorCode(entry.classFile) or "")..tostring(entry.ownerName or "?").."|r"
		.." · "..tostring(entry.profession or "?")
	if entry.span then
		detail = detail.." · "..ns.FormatDuration(entry.span, true)
	end
	return {
		left = (itemColour and (itemColour..(entry.name or "?").."|r") or (entry.name or "?")),
		detail = detail,
		right = ReadyText(entry, now),
		rightColor = (not entry.known and entry.readyAt <= now) and ACCENT or nil,
		bar = (not entry.known and entry.readyAt > now and entry.span) and { readyAt = entry.readyAt, span = entry.span } or nil,
		tip = CooldownTip(entry),
	}
end

local function RefreshCooldowns()
	local card = TPWidgets.cooldowns
	if not card then
		return
	end
	local selected = ns.professionsUI.SelectedCharacters()
	local settings = ns.ProfessionNotify.Settings()
	local now = ns.Now()
	local rows = {}
	for index = 1, #selected do
		local entry = selected[index]
		local list = ns.ProfessionCooldowns(entry.char, {
			includeKnown = true,
			includeItems = settings.items ~= false,
			key = entry.key,
			name = entry.name,
			classFile = entry.char.classFile,
			live = entry.live,
		})
		for cooldownIndex = 1, #list do
			local cd = list[cooldownIndex]
			cd.ownerName = entry.name
			cd.classFile = entry.char.classFile
			cd.live = entry.live
			cd.left = math.max(0, (cd.readyAt or 0) - now)
			rows[#rows + 1] = cd
		end
	end

	local sort = TPWidgets.cooldownSort or COOLDOWN_SORTS[1]
	local function SortKey(entry)
		if sort.key == "remaining" then
			return entry.known and math.huge or entry.left
		elseif sort.key == "length" then
			return entry.span or -1
		elseif sort.key == "profession" then
			return string.lower(tostring(entry.profession or ""))
		end
		return string.lower(tostring(entry.ownerName or ""))
	end
	table.sort(rows, function(a, b)
		if (sort.key == "remaining" or sort.key == "length") and a.known ~= b.known then
			return not a.known
		end
		local aKey, bKey = SortKey(a), SortKey(b)
		if aKey ~= bKey then
			if sort.dir > 0 then
				return aKey < bKey
			end
			return aKey > bKey
		end
		if a.ownerName ~= b.ownerName then
			return tostring(a.ownerName) < tostring(b.ownerName)
		end
		if a.profession ~= b.profession then
			return tostring(a.profession) < tostring(b.profession)
		end
		return tostring(a.name) < tostring(b.name)
	end)

	local lines = {}
	for index = 1, #rows do
		lines[index] = CooldownLine(rows[index], now)
	end
	if #lines == 0 then
		if #selected == 0 then
			ShowCardText(card, "No characters selected. Use characters to choose who this board covers.")
		else
			ShowCardText(card, "No profession cooldowns tracked for the selected characters yet.")
		end
		return
	end
	if FillScrollingLines(card, lines, TPWidgets, "cooldownOffset", "All cooldowns", 42, true) == 0 then
		ShowCardText(card, "No profession cooldowns tracked for the selected characters yet.")
	end
end

local function RefreshTotalProfessions()
	if not TPWidgets.summary then
		return
	end
	if TPWidgets.selection then
		local selected = ns.professionsUI.SelectedCharacters()
		TPWidgets.selection:SetText(ns.professionsUI.SelectedText())
		TPWidgets.selection:SetTextColor(selected[1] and ACCENT[1] or AMBER[1], selected[1] and ACCENT[2] or AMBER[2], selected[1] and ACCENT[3] or AMBER[3])
	end
	ns.professionsUI.RefreshSummary(TPWidgets.summary)
	RefreshCooldowns()
end

local function BuildTotalProfessions(page)
	TPWidgets.selection = page:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	TPWidgets.selection:SetPoint("TOPLEFT", page, "TOPLEFT", 2, -2)
	TPWidgets.selection:SetText(ns.professionsUI.SelectedText())

	TPWidgets.characters = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
	TPWidgets.characters:SetSize(90, 18)
	TPWidgets.characters:SetPoint("TOPRIGHT", page, "TOPRIGHT", -2, 0)
	TPWidgets.characters:SetText("characters")
	TPWidgets.characters:SetScript("OnClick", function()
		ShowCharPicker("levels", true)
	end)
	TPWidgets.characters:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Characters", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("The same ticks as the other Total views. The professions summary and the cooldown board only cover these characters.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	TPWidgets.characters:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	TPWidgets.summary = ns.professionsUI.BuildSummaryCard(page, 0, -24, 359, 408, TPWidgets, "summaryOffset", RefreshTotalProfessions, "Selected characters")
	TPWidgets.cooldowns = CreateListCard(page, 371, -24, 359, 408, "All cooldowns")
	AddCardTitleNote(TPWidgets.cooldowns, "All cooldowns",
		"Every known crafting cooldown for the selected characters, including the current one. Sort by time left, total length, profession or character; the bar walks down while a cooldown runs.")
	TPWidgets.cooldownSort = COOLDOWN_SORTS[1]
	local sortButton = CreateCornerButton(TPWidgets.cooldowns)
	TPWidgets.cooldownSortButton = sortButton
	SetCornerLabel(sortButton, CooldownSortLabel(TPWidgets.cooldownSort))
	sortButton:SetScript("OnClick", function()
		TPWidgets.cooldownSort = NextCooldownSort(TPWidgets.cooldownSort)
		TPWidgets.cooldownOffset = 0
		SetCornerLabel(sortButton, CooldownSortLabel(TPWidgets.cooldownSort))
		RefreshTotalProfessions()
	end)
	sortButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Cooldown order", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to cycle: time left (low or high), total cooldown length (short or long), profession (A-Z or Z-A), character (A-Z or Z-A).", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	sortButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	AddCardScrollbar(TPWidgets.cooldowns, TPWidgets, "cooldownOffset", RefreshTotalProfessions)
	MakeCardScrollable(TPWidgets.cooldowns, TPWidgets, "cooldownOffset", RefreshTotalProfessions)
	TPWidgets.cooldowns:SetScript("OnUpdate", function()
		ns.RowHoverTick(TPWidgets.cooldowns)
	end)
	TPWidgets.cooldowns:SetScript("OnLeave", function()
		TPWidgets.cooldowns.hoverKey = nil
		if GameTooltip:IsOwned(TPWidgets.cooldowns) then
			GameTooltip:Hide()
		end
	end)
	RefreshTotalProfessions()
end

ns.ProfessionUIBuildTotal = BuildTotalProfessions
ns.ProfessionUIRefreshTotal = RefreshTotalProfessions
ns.BuildTotalProfessions = ns.ProfessionUIBuildTotal
ns.RefreshTotalProfessions = ns.ProfessionUIRefreshTotal
ns.professionsUI.BuildTotal = ns.ProfessionUIBuildTotal
ns.professionsUI.RefreshTotal = ns.ProfessionUIRefreshTotal

function ns.ClearTotalProfessionsHover()
	local card = TPWidgets.cooldowns
	if not card then
		return
	end
	card.hoverKey = nil
	if GameTooltip:IsOwned(card) then
		GameTooltip:Hide()
	end
end
