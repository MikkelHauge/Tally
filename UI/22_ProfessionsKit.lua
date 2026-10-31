-- Tally - shared profession views: the all-character summary, one-profession
-- recipe cards, secondary professions, cooldown rows and recipe interaction.
--
-- Economy and Total both use these builders. The kit never writes saved data;
-- it reads ns.professions and draws into the card it is given.
local addonName, ns = ...

local ACCENT, TILE_BACKDROP, ClassColorCode, CreateListCard, ROW_DETAIL_DIM, CATEGORY_HEAD_COLOR, CARD_TITLE_DIM_CODE, QualityCode, FillScrollingLines, ShowCardText, AddCardTitleNote, MakeCardScrollable, AddCardScrollbar, RowHoverTick, CooldownBarTick, RowAtCursor =
	ns.ACCENT, ns.TILE_BACKDROP, ns.ClassColorCode, ns.CreateListCard, ns.ROW_DETAIL_DIM, ns.CATEGORY_HEAD_COLOR, ns.CARD_TITLE_DIM_CODE, ns.QualityCode, ns.FillScrollingLines, ns.ShowCardText, ns.AddCardTitleNote, ns.MakeCardScrollable, ns.AddCardScrollbar, ns.RowHoverTick, ns.CooldownBarTick, ns.RowAtCursor

local PROFESSION_SORTS = { "alpha", "high", "low" }

local function NextSort(mode)
	for index = 1, #PROFESSION_SORTS do
		if PROFESSION_SORTS[index] == mode then
			return PROFESSION_SORTS[index % #PROFESSION_SORTS + 1]
		end
	end
	return PROFESSION_SORTS[1]
end

local function SortLabel(mode)
	if mode == "high" then
		return "rank: high"
	elseif mode == "low" then
		return "rank: low"
	end
	return "A-Z"
end

local function SelectedCharacters()
	return ns.ProfessionNotify.SelectedCharacters()
end

local function SelectedText()
	local selected = SelectedCharacters()
	return "Characters: "..#selected.." selected"
end

local function CreateSortButton(card, onClick, getLabel)
	local button = CreateFrame("Button", nil, card, "BackdropTemplate")
	button:SetHeight(18)
	button:SetFrameLevel((card:GetFrameLevel() or 1) + 4)
	button:SetBackdrop(TILE_BACKDROP)
	button:SetBackdropColor(0.06, 0.06, 0.08, 0.6)
	button:SetBackdropBorderColor(1, 1, 1, 0.12)
	button:SetPoint("TOPRIGHT", card, "TOPRIGHT", -10, -6)
	button.text = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	button.text:SetPoint("LEFT", 9, 0)
	button.text:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
	button.text:SetText(getLabel())
	button:SetWidth(button.text:GetStringWidth() + 18)
	button.hover = button:CreateTexture(nil, "HIGHLIGHT")
	button.hover:SetAllPoints(button)
	button.hover:SetColorTexture(1, 1, 1, 0.09)
	button:EnableMouse(true)
	button:RegisterForClicks("LeftButtonUp")
	button:SetScript("OnClick", onClick)
	return button
end

local function BuildSummaryCard(parent, x, y, width, height, store, offsetField, refresh, title)
	local card = CreateListCard(parent, x, y, width, height, title or "All characters")
	card.baseTitle = title or "All characters"
	card.sortMode = "alpha"
	card.sortButton = CreateSortButton(card, function()
		card.sortMode = NextSort(card.sortMode)
		ns.Trace("profession sort: "..card.sortMode)
		refresh()
	end, function()
		return SortLabel(card.sortMode)
	end)
	card.sortButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Profession order", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to cycle A-Z, highest rank first, lowest rank first. It sorts the professions and the characters under them; the rank of a profession is the best rank any of its characters has reached. Secondary professions always keep their own order.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	card.sortButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	AddCardTitleNote(card, title or "All characters",
		"Primary professions first, secondary ones after the divider, with one heading per profession and every selected character Tally has read under it. A character fills in once it has been played with Tally loaded.")
	AddCardScrollbar(card, store, offsetField, refresh)
	MakeCardScrollable(card, store, offsetField, refresh)
	card.store = store
	card.offsetField = offsetField
	card.refresh = refresh
	return card
end

local function RefreshSummary(card)
	if not card then
		return
	end
	card.sortButton.text:SetText(SortLabel(card.sortMode))
	card.sortButton:SetWidth(card.sortButton.text:GetStringWidth() + 18)
	local mode = card.sortMode or "alpha"
	local byProfession = {}
	local series = ns.LevelSeries()
	for index = 1, #series do
		local entry = series[index]
		local char = entry.char
		if ns.TotalIncludes(entry.key) then
			local store = char.professions
			local skills = (type(store) == "table" and store.skills) or {}
			local recipeBook = (type(store) == "table" and store.recipes) or {}
			for skillIndex = 1, #skills do
				local skill = skills[skillIndex]
				if not ns.professions.IsIgnored(skill.name) then
					local book = recipeBook[skill.name]
					local list = type(book) == "table" and book.list or nil
					local members = byProfession[skill.name]
					if not members then
						members = {}
						byProfession[skill.name] = members
					end
					members[#members + 1] = {
						name = entry.name,
						classFile = char.classFile,
						rank = skill.rank or 0,
						maxRank = skill.maxRank or 0,
						recipes = list and #list or nil,
					}
				end
			end
		end
	end
	local best = {}
	local primaryNames, secondaryNames = {}, {}
	for name, members in pairs(byProfession) do
		local top = 0
		for index = 1, #members do
			if members[index].rank > top then
				top = members[index].rank
			end
		end
		best[name] = top
		if ns.professions.IsSecondary(name) then
			secondaryNames[#secondaryNames + 1] = name
		else
			primaryNames[#primaryNames + 1] = name
		end
	end
	table.sort(primaryNames, function(a, b)
		if mode == "alpha" or best[a] == best[b] then
			return a < b
		end
		if mode == "low" then
			return best[a] < best[b]
		end
		return best[a] > best[b]
	end)
	table.sort(secondaryNames, function(a, b)
		local aOrder, bOrder = ns.professions.SecondaryOrder(a), ns.professions.SecondaryOrder(b)
		if aOrder == bOrder then
			return a < b
		end
		return aOrder < bOrder
	end)
	local lines = {}
	local function Emit(names)
		for index = 1, #names do
			local name = names[index]
			local members = byProfession[name]
			table.sort(members, function(a, b)
				if mode == "alpha" or a.rank == b.rank then
					return a.name < b.name
				end
				if mode == "low" then
					return a.rank < b.rank
				end
				return a.rank > b.rank
			end)
			lines[#lines + 1] = {
				left = name.." - "..#members..(#members == 1 and " character" or " characters"),
				leftColor = ACCENT,
			}
			for memberIndex = 1, #members do
				local member = members[memberIndex]
				local mid, midColor
				if member.recipes then
					mid = ns.FormatNumber(member.recipes)..(member.recipes == 1 and " recipe" or " recipes")
				else
					mid = "not read yet"
					midColor = ROW_DETAIL_DIM
				end
				lines[#lines + 1] = {
					left = "   "..(ClassColorCode(member.classFile) or "")..member.name.."|r",
					mid = mid,
					midColor = midColor,
					right = member.rank.." / "..member.maxRank,
				}
			end
		end
	end
	Emit(primaryNames)
	if #primaryNames > 0 and #secondaryNames > 0 then
		lines[#lines + 1] = { divider = true }
	end
	Emit(secondaryNames)
	if FillScrollingLines(card, lines, card.store, card.offsetField, card.baseTitle or "All characters", 40) == 0 then
		if #SelectedCharacters() == 0 then
			ShowCardText(card, "No characters selected. Use characters to choose who this card covers.")
		else
			ShowCardText(card, "No professions recorded yet - Tally reads them while a character is played.")
		end
	end
end

local function AppendCooldownRows(lines, book, now)
	if type(book) ~= "table" or type(book.cooldowns) ~= "table" then
		return
	end
	local cooldowns = {}
	for name, stored in pairs(book.cooldowns) do
		local readyAt, span = ns.professions.CooldownParts(stored)
		if readyAt then
			cooldowns[#cooldowns + 1] = {
				name = name, readyAt = readyAt, span = span, left = readyAt - now,
			}
		end
	end
	if #cooldowns == 0 then
		return
	end
	table.sort(cooldowns, function(a, b)
		local aReady, bReady = a.left <= 0, b.left <= 0
		if aReady ~= bReady then
			return aReady
		end
		if not aReady and a.left ~= b.left then
			return a.left < b.left
		end
		return a.name < b.name
	end)
	lines[#lines + 1] = { left = "Cooldowns", leftColor = ACCENT }
	for index = 1, #cooldowns do
		local entry = cooldowns[index]
		if entry.left > 0 then
			lines[#lines + 1] = {
				left = "   "..entry.name,
				right = ns.FormatDuration(entry.left, true).." left",
				rightColor = ROW_DETAIL_DIM,
				bar = entry.span and { readyAt = entry.readyAt, span = entry.span } or nil,
			}
		else
			lines[#lines + 1] = { left = "   "..entry.name, right = "ready" }
		end
	end
	lines[#lines + 1] = { divider = true }
end

local function AppendProfessionRows(lines, skill, book, crafts, most)
	local list = type(book) == "table" and book.list or nil
	local outputItems = type(book) == "table" and book.items or nil
	local recipeIDs = type(book) == "table" and book.ids or nil
	local parts = {}
	if list and #list > 0 then
		local total = type(book) == "table" and book.total or nil
		if total and total > #list then
			parts[#parts + 1] = ns.FormatNumber(#list).." of "..ns.FormatNumber(total).." recipes"
		else
			parts[#parts + 1] = ns.FormatNumber(#list)..(#list == 1 and " recipe" or " recipes")
		end
	end
	local crafted = crafts[skill.name] or 0
	if crafted > 0 then
		parts[#parts + 1] = ns.FormatNumber(crafted).." crafted"
	end
	lines[#lines + 1] = {
		left = skill.name..(#parts > 0 and (" · "..table.concat(parts, " · ")) or ""),
		leftColor = ACCENT,
		right = (skill.rank or 0).." / "..(skill.maxRank or 0),
	}
	if most then
		local name = most.name or "?"
		if #name > 34 then
			name = string.sub(name, 1, 31).."..."
		end
		local code = QualityCode(most.quality or 1)
		lines[#lines + 1] = {
			left = "   Most crafted: "..code..name.."|r x"..ns.FormatNumber(most.count),
			leftColor = ROW_DETAIL_DIM,
		}
	end
	if list and #list > 0 then
		local categoryList = type(book) == "table" and book.cats or nil
		local categoryOf = type(book) == "table" and book.catOf or nil
		local indent = (categoryList and categoryOf) and "      " or "   "
		local function EmitRecipe(name)
			local itemID = outputItems and outputItems[name] or nil
			local quality = itemID and select(3, ns.ItemInfo(itemID)) or nil
			lines[#lines + 1] = {
				left = indent..(quality and (QualityCode(quality)..name.."|r") or name),
				tip = {
					kind = "recipe",
					name = name,
					quality = quality,
					itemID = itemID,
					recipeID = recipeIDs and recipeIDs[name] or nil,
					profession = skill.name,
				},
			}
		end
		local placed = {}
		if categoryList and categoryOf then
			for categoryIndex = 1, #categoryList do
				local category = categoryList[categoryIndex]
				local group = {}
				for recipeIndex = 1, #list do
					local name = list[recipeIndex]
					if not placed[name] and categoryOf[name] == category.id then
						group[#group + 1] = name
						placed[name] = true
					end
				end
				if #group > 0 then
					if category.name ~= skill.name then
						lines[#lines + 1] = { left = "   "..category.name, leftColor = CATEGORY_HEAD_COLOR }
					end
					for groupIndex = 1, #group do
						EmitRecipe(group[groupIndex])
					end
				end
			end
		end
		for recipeIndex = 1, #list do
			if not placed[list[recipeIndex]] then
				EmitRecipe(list[recipeIndex])
			end
		end
	else
		local read = type(book) == "table" and book.read
		lines[#lines + 1] = {
			left = read and "   no recipes found" or "   open the window once to read its recipes",
			leftColor = ROW_DETAIL_DIM,
		}
	end
end

local function WireRecipeCard(card, refresh)
	card:SetScript("OnUpdate", function()
		CooldownBarTick(card)
		RowHoverTick(card)
	end)
	card:SetScript("OnLeave", function()
		card.hoverKey = nil
		if GameTooltip:IsOwned(card) then
			GameTooltip:Hide()
		end
	end)
	card:SetScript("OnMouseDown", function(self, button)
		if button == "LeftButton" then
			self.pressX, self.pressY = GetCursorPosition()
		end
	end)
	card:SetScript("OnMouseUp", function(self, button)
		local pressX, pressY = self.pressX, self.pressY
		self.pressX, self.pressY = nil, nil
		if button ~= "LeftButton" or not pressX then
			return
		end
		local cursorX, cursorY = GetCursorPosition()
		local slack = 5 * (self:GetEffectiveScale() or 1)
		if math.abs(cursorX - pressX) > slack or math.abs(cursorY - pressY) > slack then
			return
		end
		local row = RowAtCursor(self)
		local tip = row and row.tip
		if not (tip and tip.recipeID and tip.profession) then
			return
		end
		if ns.IsViewing() then
			ns.Trace("recipe click: ignored, the window is showing another character's list")
			return
		end
		ns.Trace("recipe click: "..tip.profession.." "..tip.recipeID)
		local problem = ns.professions.ShowRecipe(tip.profession, tip.recipeID)
		if problem then
			ns.Print(problem)
		end
	end)
end

local function AttachRecipeCard(card, store, offsetField, refresh)
	AddCardScrollbar(card, store, offsetField, refresh)
	MakeCardScrollable(card, store, offsetField, refresh)
	WireRecipeCard(card, refresh)
	card.store = store
	card.offsetField = offsetField
	return card
end

local function BuildRecipeCard(parent, x, y, width, height, store, offsetField, refresh, title)
	local card = CreateListCard(parent, x, y, width, height, title or "Recipes")
	AddCardTitleNote(card, title or "Recipes",
		"Ranks are read at login and on every skill-up; recipes, counts and cooldowns are read while that profession's window is open. Hover a recipe for its reagents, and click it to show it in the game's own profession window.")
	return AttachRecipeCard(card, store, offsetField, refresh)
end

local function CharTitle(char, skillName)
	local who = char and char.name or "?"
	local colour = ClassColorCode(char and char.classFile) or ""
	return colour..who.."|r"..CARD_TITLE_DIM_CODE.." · "..(skillName or "Recipes").."|r"
end

local function RefreshRecipeCard(card, char, skillName)
	if not card then
		return
	end
	if not char or not skillName then
		ShowCardText(card, "No profession recorded for this character yet.")
		return
	end
	local store = char.professions
	local skills = (type(store) == "table" and store.skills) or {}
	local crafts = (type(store) == "table" and store.crafts) or {}
	local recipeBook = (type(store) == "table" and store.recipes) or {}
	local skill
	for index = 1, #skills do
		if skills[index].name == skillName then
			skill = skills[index]
			break
		end
	end
	if not skill then
		ShowCardText(card, "No "..skillName.." recorded for this character yet.")
		return
	end
	local book = recipeBook[skillName]
	local lines = {}
	AppendCooldownRows(lines, book, ns.Now())
	AppendProfessionRows(lines, skill, book, crafts, ns.professions.MostCraftedFor(char, skillName))
	local title = CharTitle(char, skillName)
	card.noteTitle = title
	if FillScrollingLines(card, lines, card.store, card.offsetField, title, 44) == 0 then
		ShowCardText(card, "No recipes recorded yet.")
	end
end

local function RefreshSecondaryCard(card, char)
	if not card then
		return
	end
	if not char then
		ShowCardText(card, "No character selected.")
		return
	end
	local store = char.professions
	local skills = (type(store) == "table" and store.skills) or {}
	local crafts = (type(store) == "table" and store.crafts) or {}
	local recipeBook = (type(store) == "table" and store.recipes) or {}
	local lines = {}
	local first = true
	for index = 1, #ns.professions.Secondary do
		local name = ns.professions.Secondary[index]
		local skill
		for skillIndex = 1, #skills do
			if skills[skillIndex].name == name then
				skill = skills[skillIndex]
				break
			end
		end
		if skill then
			if not first then
				lines[#lines + 1] = { divider = true }
			end
			first = false
			AppendCooldownRows(lines, recipeBook[name], ns.Now())
			AppendProfessionRows(lines, skill, recipeBook[name], crafts, ns.professions.MostCraftedFor(char, name))
		end
	end
	local title = CharTitle(char, "Secondary professions")
	card.noteTitle = title
	if FillScrollingLines(card, lines, card.store, card.offsetField, title, 44) == 0 then
		ShowCardText(card, "No secondary professions recorded yet.")
	end
end

ns.professionsUI = {}

ns.ProfessionUISelectedCharacters = SelectedCharacters
ns.ProfessionUISelectedText = SelectedText
ns.ProfessionUIBuildSummaryCard = BuildSummaryCard
ns.ProfessionUIRefreshSummary = RefreshSummary
ns.ProfessionUIBuildRecipeCard = BuildRecipeCard
ns.ProfessionUIAttachRecipeCard = AttachRecipeCard
ns.ProfessionUIRefreshRecipeCard = RefreshRecipeCard
ns.ProfessionUIRefreshSecondaryCard = RefreshSecondaryCard

-- Called by the character picker after ticks change. It never rebuilds the
-- picker or writes a character; it only redraws the profession views.
function ns.ProfessionUIRefreshViews()
	if ns.professionsUI.RefreshTotal then
		ns.professionsUI.RefreshTotal()
	end
	if ns.professionsUI.RefreshNotify then
		ns.professionsUI.RefreshNotify()
	end
	if ns.professionsUI.RefreshEconomy then
		ns.professionsUI.RefreshEconomy()
	end
	if ns.professionsUI.RefreshSecondary then
		ns.professionsUI.RefreshSecondary()
	end
end

ns.professionsUI.SelectedCharacters = ns.ProfessionUISelectedCharacters
ns.professionsUI.SelectedText = ns.ProfessionUISelectedText
ns.professionsUI.BuildSummaryCard = ns.ProfessionUIBuildSummaryCard
ns.professionsUI.RefreshSummary = ns.ProfessionUIRefreshSummary
ns.professionsUI.BuildRecipeCard = ns.ProfessionUIBuildRecipeCard
ns.professionsUI.AttachRecipeCard = ns.ProfessionUIAttachRecipeCard
ns.professionsUI.RefreshRecipeCard = ns.ProfessionUIRefreshRecipeCard
ns.professionsUI.RefreshSecondaryCard = ns.ProfessionUIRefreshSecondaryCard
ns.professionsUI.RefreshViews = ns.ProfessionUIRefreshViews
