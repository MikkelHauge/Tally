-- Tally - shared profession views: the all-character summary, one-profession
-- recipe cards, secondary professions, cooldown rows and recipe interaction.
--
-- Economy and Total both use these builders. The kit never writes saved data;
-- it reads ns.professions and draws into the card it is given.
local addonName, ns = ...

local ACCENT, TILE_BACKDROP, ClassColorCode, CreateListCard, ROW_DETAIL_DIM, CATEGORY_HEAD_COLOR, CARD_TITLE_DIM_CODE, QualityCode, FillScrollingLines, ShowCardText, AddCardTitleNote, MakeCardScrollable, AddCardScrollbar, RowHoverTick, CooldownBarTick, RowAtCursor, CreateCornerButton, SetCornerLabel, GREEN, CreateTileRow, SetTile, CutRowText, AMBER =
	ns.ACCENT, ns.TILE_BACKDROP, ns.ClassColorCode, ns.CreateListCard, ns.ROW_DETAIL_DIM, ns.CATEGORY_HEAD_COLOR, ns.CARD_TITLE_DIM_CODE, ns.QualityCode, ns.FillScrollingLines, ns.ShowCardText, ns.AddCardTitleNote, ns.MakeCardScrollable, ns.AddCardScrollbar, ns.RowHoverTick, ns.CooldownBarTick, ns.RowAtCursor, ns.CreateCornerButton, ns.SetCornerLabel, ns.GREEN, ns.CreateTileRow, ns.SetTile, ns.CutRowText, ns.AMBER

local PROFESSION_SORTS = { "alpha", "high", "low" }
local MATRIX_PROFESSIONS = {
	"Alchemy", "Blacksmithing", "Cooking", "Enchanting", "Engineering",
	"First Aid", "Fishing", "Herbalism", "Inscription", "Jewelcrafting",
	"Leatherworking", "Mining", "Skinning", "Tailoring",
}
local MATRIX_PROFESSION_SET = {}
for _, name in ipairs(MATRIX_PROFESSIONS) do
	MATRIX_PROFESSION_SET[name] = true
end

-- Retail keeps the old-world lines as "Classic Tailoring" and so on. Tally
-- stores the plain name; this maps a name read from the client or old data.
local function CanonicalProfession(name)
	local fn = ns.ProfessionCanonicalName
	if fn then
		return fn(name)
	end
	return name
end

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

-- Skill gained per character level, from the live skill-ups Core records.
-- Levels between the first gain and the current level are listed even when
-- nothing was gained, so "level 13 and 14 gained 0" is visible.
--
-- The table carries one right-hand column per learned row profession, not a
-- fixed three. Card offsets are set for six columns; SkillLevelRows fills only
-- the columns in `names`, and FillCardRows hides the rest.
local LEVEL_FIELDS = { "mid5", "mid4", "mid3", "mid2", "mid", "right" }

local function LevelFields(names)
	local fields = {}
	local start = #LEVEL_FIELDS - #names + 1
	for index = 1, #names do
		fields[index] = LEVEL_FIELDS[start + index - 1]
	end
	return fields
end

local function LevelRow(names, values, colors, left, leftColor)
	local row = { left = left, leftColor = leftColor }
	local fields = LevelFields(names)
	for index = 1, #names do
		local field = fields[index]
		row[field] = values[index] or 0
		row[field.."Color"] = colors and colors[index] or nil
	end
	return row
end

-- The profession columns a character should see: every profession Tally
-- knows, filtered to the ones the character actually has. Saved data is used
-- for offline alts; the live character can also ask GetProfessions.
local function MatrixProfessions(char)
	local names = {}
	if not char then
		return names
	end
	local known = {}
	local store = char.professions
	if type(store) == "table" then
		for _, skill in ipairs(store.skills or {}) do
			if type(skill) == "table" and skill.name then
				known[CanonicalProfession(skill.name)] = true
			end
		end
		for name in pairs(store.recipes or {}) do
			known[CanonicalProfession(name)] = true
		end
		for name in pairs(store.crafts or {}) do
			known[CanonicalProfession(name)] = true
		end
		for name in pairs(store.learned or {}) do
			known[CanonicalProfession(name)] = true
		end
		for _, gains in pairs(store.byLevel or {}) do
			if type(gains) == "table" then
				for name in pairs(gains) do
					known[CanonicalProfession(name)] = true
				end
			end
		end
	end
	for name in pairs(char.gathering or {}) do
		known[CanonicalProfession(name)] = true
	end
	local fishing = char.fishing
	if type(fishing) == "table"
		and ((tonumber(fishing.casts) or 0) > 0
			or (tonumber(fishing.catches) or 0) > 0
			or next(fishing.items or {}) ~= nil) then
		known.Fishing = true
	end
	if char == ns.GetChar()
		and type(GetProfessions) == "function"
		and type(GetProfessionInfo) == "function" then
		local ok, professions = pcall(GetProfessions)
		if ok and type(professions) == "table" then
			for _, index in ipairs(professions) do
				local okInfo, name = pcall(GetProfessionInfo, index)
				if okInfo and type(name) == "string" then
					known[CanonicalProfession(name)] = true
				end
			end
		end
	end
	-- Classic has no GetProfessions; the skill lines still name the learned
	-- professions, including the gathering ones.
	if char == ns.GetChar()
		and type(GetNumSkillLines) == "function"
		and type(GetSkillLineInfo) == "function" then
		local ok, count = pcall(GetNumSkillLines)
		if ok and type(count) == "number" then
			for index = 1, count do
				local okLine, name, isHeader = pcall(GetSkillLineInfo, index)
				local canonical = CanonicalProfession(name)
				if okLine and not isHeader and canonical and MATRIX_PROFESSION_SET[canonical] then
					known[canonical] = true
				end
			end
		end
	end
	for _, name in ipairs(MATRIX_PROFESSIONS) do
		if known[name] and MATRIX_PROFESSION_SET[name] then
			names[#names + 1] = name
		end
	end
	if #names > 6 then
		-- The matrix draws six columns. Keep the six with the most recorded
		-- skill gain, then the highest rank, so an active profession is not
		-- lost to an untouched one; then restore the fixed column order.
		local gainTotals, rankTotals = {}, {}
		if type(store) == "table" then
			for _, gains in pairs(store.byLevel or {}) do
				if type(gains) == "table" then
					for name, value in pairs(gains) do
						local key = CanonicalProfession(name)
						gainTotals[key] = (gainTotals[key] or 0) + (tonumber(value) or 0)
					end
				end
			end
			for _, skill in ipairs(store.skills or {}) do
				if type(skill) == "table" and skill.name then
					local key = CanonicalProfession(skill.name)
					rankTotals[key] = math.max(rankTotals[key] or 0, tonumber(skill.rank) or 0)
				end
			end
		end
		table.sort(names, function(a, b)
			local ag, bg = gainTotals[a] or 0, gainTotals[b] or 0
			if ag ~= bg then
				return ag > bg
			end
			local ar, br = rankTotals[a] or 0, rankTotals[b] or 0
			if ar ~= br then
				return ar > br
			end
			return a < b
		end)
		while #names > 6 do
			table.remove(names)
		end
		table.sort(names)
	end
	return names
end

local function CanonicalGains(byLevel)
	local result = {}
	for level, gains in pairs(type(byLevel) == "table" and byLevel or {}) do
		if type(level) == "number" and type(gains) == "table" then
			local row = {}
			for name, value in pairs(gains) do
				local key = CanonicalProfession(name)
				row[key] = (row[key] or 0) + (tonumber(value) or 0)
			end
			result[level] = row
		end
	end
	return result
end

local function SkillLevelRows(char, names, order)
	local store = char and char.professions
	local byLevel = type(store) == "table" and store.byLevel or {}
	if type(byLevel) ~= "table" then
		byLevel = {}
	end
	byLevel = CanonicalGains(byLevel)
	names = names or {}
	if #names == 0 then
		return nil
	end
	local firstLevel, lastLevel
	for level, gains in pairs(byLevel) do
		if type(level) == "number" and type(gains) == "table" then
			for index = 1, #names do
				if (tonumber(gains[names[index]]) or 0) > 0 then
					if not firstLevel or level < firstLevel then
						firstLevel = level
					end
					if not lastLevel or level > lastLevel then
						lastLevel = level
					end
					break
				end
			end
		end
	end
	local current = tonumber(char and char.level) or 0
	if current > (lastLevel or 0) then
		lastLevel = current
	end
	if not firstLevel and #names > 0 and current > 0 then
		-- A learned profession with no recorded gain yet still gets its
		-- columns: show the current level as a +0 row rather than an empty
		-- card. This is what "professions you have" means here.
		firstLevel = current
		lastLevel = current
	end
	if not firstLevel or not lastLevel or lastLevel < firstLevel then
		return nil
	end
	local stats = {
		firstLevel = firstLevel, lastLevel = lastLevel,
		levelCount = lastLevel - firstLevel + 1,
		totalGains = 0,
		levelTotals = {}, levelLines = {}, professionTotals = {},
	}
	-- Current ranks, and a working copy that walks backwards through the
	-- levels: the rank at the end of the current level is the rank now; the
	-- rank at the end of the level below is that minus the gain above it.
	local storeSkills = type(store) == "table" and store.skills or {}
	local skillByName = {}
	for index = 1, #storeSkills do
		local skill = storeSkills[index]
		if type(skill) == "table" and skill.name then
			skillByName[CanonicalProfession(skill.name)] = skill
		end
	end
	local currentRanks, maxRanks, rankAtLevel = {}, {}, {}
	for index = 1, #names do
		local name = names[index]
		local skill = skillByName[name]
		local rank = skill and tonumber(skill.rank) or 0
		local maxRank = skill and tonumber(skill.maxRank) or 0
		currentRanks[name] = rank
		maxRanks[name] = maxRank
		rankAtLevel[name] = rank
	end

	local rows = {}
	if #names == 1 then
		rows[1] = {
			left = "Level", right = names[1].." gained",
			leftColor = ACCENT, rightColor = ACCENT,
		}
	else
		local colors = {}
		for index = 1, #names do
			colors[index] = ACCENT
		end
		rows[1] = LevelRow(names, names, colors, "Level", ACCENT)
	end
	for level = lastLevel, firstLevel, -1 do
		local gains = type(byLevel[level]) == "table" and byLevel[level] or {}
		local values, colors, lines = {}, {}, {}
		local levelTotal = 0
		for index = 1, #names do
			local name = names[index]
			local gain = tonumber(gains[name]) or 0
			local after = tonumber(rankAtLevel[name]) or 0
			local before = math.max(0, after - gain)
			local maxRank = maxRanks[name] or 0
			local capHit, milestone
			if gain > 0 then
				if maxRank > 0 and after >= maxRank and before < maxRank then
					capHit = true
					milestone = maxRank
				end
				-- Every 25 rank points is a milestone. The highest one the
				-- gain reached or passed names the row.
				local firstMultiple = math.floor(before / 25) + 1
				local highestMultiple = math.floor(after / 25) * 25
				if highestMultiple >= 25 and firstMultiple * 25 <= after then
					capHit = true
					if not milestone or highestMultiple > milestone then
						milestone = highestMultiple
					end
				end
			end
			local rankText = maxRank > 0 and (" ("..after.."/"..maxRank..")") or ""
			values[index] = "+"..gain..rankText
			colors[index] = capHit and AMBER or (gain > 0 and GREEN or ROW_DETAIL_DIM)
			local line = name.."  +"..gain..rankText
			if capHit and milestone then
				line = line.."  ·  "..(after == milestone and "reached " or "passed ")..milestone
			end
			lines[index] = { text = line }
			levelTotal = levelTotal + gain
			stats.professionTotals[name] = (stats.professionTotals[name] or 0) + gain
			rankAtLevel[name] = before
		end
		stats.totalGains = stats.totalGains + levelTotal
		stats.levelTotals[level] = levelTotal
		stats.levelLines[level] = lines
		if not stats.bestLevel or levelTotal > stats.bestLevelGains
			or (levelTotal == stats.bestLevelGains and level > stats.bestLevel) then
			stats.bestLevel, stats.bestLevelGains = level, levelTotal
		end
		local row = LevelRow(names, values, colors, "Level "..level)
		row.tip = {
			kind = "note", title = "Level "..level,
			lines = lines,
			note = "Only skill-ups Tally saw happen are counted here. The bracket is the rank at that level out of the current cap; amber marks a 25-point milestone.",
			key = "skillLevel|"..level.."|"..table.concat(names, ","),
		}
		rows[#rows + 1] = row
	end
	stats.average = stats.levelCount > 0 and (stats.totalGains / stats.levelCount) or 0
	stats.ranks, stats.maxRanks = currentRanks, maxRanks
	-- Ranks are reconstructed from the current level downwards, so the rows
	-- are always built in that order. Ascending display only reverses the data
	-- rows; the header stays where it is.
	if order == "low" then
		local left, right = 2, #rows
		while left < right do
			rows[left], rows[right] = rows[right], rows[left]
			left = left + 1
			right = right - 1
		end
	end
	for index = 1, #names do
		local name = names[index]
		local total = stats.professionTotals[name] or 0
		local rank = currentRanks[name] or 0
		local maxRank = maxRanks[name] or 0
		if not stats.highestProfession or total > (stats.highestGains or 0) then
			stats.highestProfession, stats.highestGains = name, total
		end
		if not stats.lowestProfession or total < (stats.lowestGains or 0) then
			stats.lowestProfession, stats.lowestGains = name, total
		end
		if maxRank > 0 then
			if not stats.highestRankName or rank > (stats.highestRank or 0) then
				stats.highestRankName, stats.highestRank, stats.highestRankMax = name, rank, maxRank
			end
			if not stats.lowestRankName or rank < (stats.lowestRank or 0) then
				stats.lowestRankName, stats.lowestRank, stats.lowestRankMax = name, rank, maxRank
			end
		end
	end
	return rows, stats
end

local function AttachRecipeCard(card, store, offsetField, refresh, noToggle)
	AddCardScrollbar(card, store, offsetField, refresh)
	MakeCardScrollable(card, store, offsetField, refresh)
	WireRecipeCard(card, refresh)
	card.store = store
	card.offsetField = offsetField
	card.viewMode = card.viewMode or "recipes"
	if noToggle then
		return card
	end
	local button = CreateCornerButton(card)
	card.viewButton = button
	local function Label()
		SetCornerLabel(button, card.viewMode == "levels" and "recipes" or "by level")
	end
	Label()
	button:SetScript("OnClick", function()
		card.viewMode = card.viewMode == "levels" and "recipes" or "levels"
		Label()
		store[offsetField] = 0
		refresh()
	end)
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Profession view", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Switch between the recipe list and the skill gained at each character level. Only skill-ups Tally saw happen are counted by level.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	return card
end

local function BuildRecipeCard(parent, x, y, width, height, store, offsetField, refresh, title)
	local card = CreateListCard(parent, x, y, width, height, title or "Recipes")
	AddCardTitleNote(card, title or "Recipes",
		"Ranks are read at login and on every skill-up; recipes, counts and cooldowns are read while that profession's window is open. Hover a recipe for its reagents, and click it to show it in the game's own profession window. The corner button switches to the skill gained at each character level.")
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
	if card.viewMode == "levels" then
		local title = CharTitle(char, skillName.." by level")
		card.noteTitle = title
		local rows = SkillLevelRows(char, { skillName })
		if not rows then
			ShowCardText(card, "No live skill gains recorded per level yet.")
			return
		end
		if FillScrollingLines(card, rows, card.store, card.offsetField, title, 44) == 0 then
			ShowCardText(card, "No live skill gains recorded per level yet.")
		end
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

local function AddLevelTileTip(tile)
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

local function RefreshLevelTiles(card, names, stats)
	local tiles = card and card.tiles
	if not tiles or #tiles == 0 then
		return
	end
	if not stats or not names or #names == 0 then
		for index = 1, #tiles do
			SetTile(tiles[index], "-", "")
			tiles[index].tipInfo = nil
		end
		return
	end

	SetTile(tiles[1], string.format("%.1f", stats.average or 0),
		stats.levelCount..(stats.levelCount == 1 and " level" or " levels"))
	tiles[1].tipInfo = {
		kind = "note", title = "Average skill per level",
		lines = {
			{ text = ns.FormatNumber(stats.totalGains or 0).." skill points in total" },
			{ text = "Across "..stats.levelCount..(stats.levelCount == 1 and " level" or " levels") },
			{ text = "From level "..stats.firstLevel.." to level "..stats.lastLevel },
		},
		note = "Total skill gained divided by the number of levels listed, including levels with +0.",
	}

	if stats.bestLevel then
		SetTile(tiles[2], "+"..ns.FormatNumber(stats.bestLevelGains or 0), "Level "..stats.bestLevel)
		tiles[2].tipInfo = {
			kind = "note", title = "Most skill gains",
			lines = stats.levelLines[stats.bestLevel] or {},
			note = "Level "..stats.bestLevel.." had the most skill gained across all listed professions.",
		}
	else
		SetTile(tiles[2], "-", "no level yet")
		tiles[2].tipInfo = nil
	end

	if stats.highestRankName then
		SetTile(tiles[3], (stats.highestRank or 0).."/"..(stats.highestRankMax or 0),
			CutRowText(stats.highestRankName, 18).." · +"..ns.FormatNumber(stats.highestGains or 0))
		tiles[3].tipInfo = {
			kind = "note", title = stats.highestRankName,
			lines = {
				{ text = "Current rank "..(stats.highestRank or 0).."/"..(stats.highestRankMax or 0) },
				{ text = ns.FormatNumber(stats.highestGains or 0).." skill gained since Tally started counting" },
				{ text = "The highest current rank of the listed professions" },
			},
			note = "The big figure is the current rank; the line under it is the live skill gained.",
		}
	else
		SetTile(tiles[3], "-", "no rank yet")
		tiles[3].tipInfo = nil
	end

	if stats.lowestRankName then
		SetTile(tiles[4], (stats.lowestRank or 0).."/"..(stats.lowestRankMax or 0),
			CutRowText(stats.lowestRankName, 18).." · +"..ns.FormatNumber(stats.lowestGains or 0))
		tiles[4].tipInfo = {
			kind = "note", title = stats.lowestRankName,
			lines = {
				{ text = "Current rank "..(stats.lowestRank or 0).."/"..(stats.lowestRankMax or 0) },
				{ text = ns.FormatNumber(stats.lowestGains or 0).." skill gained since Tally started counting" },
				{ text = "The lowest current rank of the listed professions" },
			},
			note = "The big figure is the current rank; the line under it is the live skill gained.",
		}
	else
		SetTile(tiles[4], "-", "no rank yet")
		tiles[4].tipInfo = nil
	end
end

local function BuildLevelCard(parent, x, y, width, height, store, offsetField, refresh, title)
	store.tiles = store.tiles or {}
	CreateTileRow(parent, -4, { "Average per level", "Most skill gains", "Highest profession", "Lowest profession" }, store.tiles, false)
	for index = 1, #store.tiles do
		AddLevelTileTip(store.tiles[index])
	end

	local card = CreateListCard(parent, x, y - 84, width, math.max(120, height - 92), title or "Professions by level")
	card.tiles = store.tiles
	-- Room for up to six learned profession columns.
	card.rowMidRight = 105
	card.rowMid2Right = 210
	card.rowMid3Right = 315
	card.rowMid4Right = 420
	card.rowMid5Right = 525
	AddCardTitleNote(card, title or "Professions by level",
		"One column per profession this character has, and one row per character level. Rows start highest level first; the corner button switches between descending and ascending, and levels are the only thing they are sorted by. Each cell is the skill gained at that level, from the skill-ups Tally actually saw, with the rank and current cap in brackets. Levels with no gain are kept as +0 so a gap is visible. Amber marks a 25-point milestone. Ranks are read at login; this view is about the live gains, not the rank itself.")
	AddCardScrollbar(card, store, offsetField, refresh)
	MakeCardScrollable(card, store, offsetField, refresh)
	card.store = store
	card.offsetField = offsetField
	card.levelOrder = card.levelOrder or "high"
	local orderButton = CreateCornerButton(card)
	local function OrderLabel()
		return card.levelOrder == "low" and "level: asc" or "level: desc"
	end
	SetCornerLabel(orderButton, OrderLabel())
	orderButton:SetScript("OnClick", function()
		card.levelOrder = card.levelOrder == "low" and "high" or "low"
		SetCornerLabel(orderButton, OrderLabel())
		store[offsetField] = 0
		refresh()
	end)
	orderButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Order of the levels", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to switch between highest level first (descending) and lowest level first (ascending). The rows are only ever sorted by level.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	orderButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	return card
end

local function RefreshLevelCard(card, char)
	if not card then
		return
	end
	if not char then
		RefreshLevelTiles(card, {}, nil)
		ShowCardText(card, "No character selected.")
		return
	end
	local names = MatrixProfessions(char)
	local title = CharTitle(char, "Professions by level")
	card.noteTitle = title
	local rows, stats = SkillLevelRows(char, names, card.levelOrder)
	RefreshLevelTiles(card, names, stats)
	if not rows then
		ShowCardText(card, "No live skill gains recorded per level yet.")
		return
	end
	if FillScrollingLines(card, rows, card.store, card.offsetField, title, 44) == 0 then
		ShowCardText(card, "No live skill gains recorded per level yet.")
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
ns.ProfessionUIBuildLevelCard = BuildLevelCard
ns.ProfessionUIRefreshLevelCard = RefreshLevelCard

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
ns.professionsUI.BuildLevelCard = ns.ProfessionUIBuildLevelCard
ns.professionsUI.RefreshLevelCard = ns.ProfessionUIRefreshLevelCard
ns.professionsUI.RefreshViews = ns.ProfessionUIRefreshViews
