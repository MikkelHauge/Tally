-- Tally - the Economy tab's professions sub-view: the figures for the
-- character being shown and its two primary professions.
--
-- The cards are drawn by the shared kit in 22_ProfessionsKit.lua. This file
-- only lays out the tiles, chooses the two professions and fills the figures.
-- Nothing here writes saved data.
local addonName, ns = ...

local ACCENT, TILE_WIDTH, GREEN, RED, DisplayChar, CreateTileRow, SetTile,
	CreateListCard, ShowCardText, AddCardTitleNote, CutRowText, QualityCode, QUALITY_COLORS,
	economyWidgets =
	ns.ACCENT, ns.TILE_WIDTH, ns.GREEN, ns.RED, ns.DisplayChar, ns.CreateTileRow, ns.SetTile,
	ns.CreateListCard, ns.ShowCardText, ns.AddCardTitleNote, ns.CutRowText, ns.QualityCode, ns.QUALITY_COLORS,
	ns.economyWidgets

local function NotifyStatus()
	local settings = ns.ProfessionNotify.Settings()
	local chat = settings.chat ~= false
	local chime = settings.chime ~= false
	return (chat or chime), chat, chime, settings
end

local function RefreshNotifyTile()
	local tile = economyWidgets.profTiles and economyWidgets.profTiles[4]
	if not tile then
		return
	end
	local on = NotifyStatus()
	SetTile(tile, "Options", on and "notifications on" or "notifications off",
		ACCENT, on and GREEN or RED)
	tile.subRight:SetText("")
end

local function PrimaryProfessions(char)
	local out = {}
	local store = char and char.professions
	local skills = (type(store) == "table" and store.skills) or {}
	for index = 1, #skills do
		local skill = skills[index]
		if not ns.professions.IsSecondary(skill.name) and not ns.professions.IsIgnored(skill.name) then
			out[#out + 1] = skill
		end
	end
	return out
end

local function CraftTotals(char)
	local store = char and char.professions
	local crafts = (type(store) == "table" and store.crafts) or {}
	local total, professions = 0, 0
	for _, count in pairs(crafts) do
		if type(count) == "number" and count > 0 then
			total = total + count
			professions = professions + 1
		end
	end
	return total, professions, crafts
end

local function MostCraftedItem(char)
	local store = char and char.professions
	local crafted = (type(store) == "table" and store.crafted) or {}
	local best
	for _, tally in pairs(crafted) do
		local count = tally.count or 0
		if count > 0 then
			local betterTie = best and count == best.count and (tally.name or "") < (best.name or "")
			if not best or count > best.count or betterTie then
				best = { name = tally.name or "?", count = count, itemID = tally.itemID, quality = tally.quality }
			end
		end
	end
	return best
end

-- Every cooldown that has actually been read for this character, ready ones
-- first: the most recently started ready cooldown at the top, then the
-- shortest wait. A recipe Tally knows but has never seen cooling is not here;
-- the board on the Total tab is where the whole known list lives.
local function TrackedCooldowns(char)
	local settings = ns.ProfessionNotify.Settings()
	local list = ns.ProfessionCooldowns(char, {
		includeKnown = false,
		includeItems = settings.items ~= false,
	})
	local now = ns.Now()
	local kept = {}
	for index = 1, #list do
		local entry = list[index]
		if not entry.known then
			entry.ready = (entry.readyAt or 0) <= now
			entry.left = math.max(0, (entry.readyAt or 0) - now)
			kept[#kept + 1] = entry
		end
	end
	list = kept
	table.sort(list, function(a, b)
		if a.ready ~= b.ready then
			return a.ready
		end
		if a.ready then
			if (a.startedAt or 0) ~= (b.startedAt or 0) then
				return (a.startedAt or 0) > (b.startedAt or 0)
			end
		elseif a.left ~= b.left then
			return a.left < b.left
		end
		return tostring(a.name) < tostring(b.name)
	end)
	return list
end

local function CooldownText(entry)
	if entry.ready then
		return "ready"
	end
	return ns.FormatDuration(entry.left, true).." left"
end

local function ItemName(entry, limit)
	local name = limit and CutRowText(entry.name or "?", limit) or (entry.name or "?")
	local colour = entry.quality ~= nil and QualityCode(entry.quality) or nil
	return (colour and (colour..name.."|r") or name)
end

local function RefreshCooldownTile(char)
	local tile = economyWidgets.profTiles[3]
	if not tile then
		return
	end
	local list = char and TrackedCooldowns(char) or {}
	local ready = {}
	for index = 1, #list do
		if list[index].ready then
			ready[#ready + 1] = list[index]
		end
	end
	tile.tipRows = list
	if #list == 0 then
		SetTile(tile, "none", "no cooldowns tracked yet")
		tile.barBg:Hide()
		tile.barFill:Hide()
		return
	end
	if #ready > 0 then
		local first = ready[1]
		SetTile(tile, ns.FormatNumber(#ready).." ready",
			ItemName(first, 15), nil, first.quality ~= nil and QUALITY_COLORS[first.quality] or nil,
			tostring(first.profession or ""))
		tile.barBg:Hide()
		tile.barFill:Hide()
		return
	end
	local nextReady = list[1]
	SetTile(tile, CooldownText(nextReady), ItemName(nextReady, 15), nil,
		nextReady.quality ~= nil and QUALITY_COLORS[nextReady.quality] or nil,
		tostring(nextReady.profession or ""))
	if nextReady.span and nextReady.span > 0 then
		local fraction = nextReady.left / nextReady.span
		if fraction < 0 then fraction = 0 elseif fraction > 1 then fraction = 1 end
		tile.barBg:Show()
		tile.barFill:Show()
		tile.barFill:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.75)
		tile.barFill:SetWidth((TILE_WIDTH - 20) * fraction)
	else
		tile.barBg:Hide()
		tile.barFill:Hide()
	end
end

local function RefreshCraftTiles(char)
	local tiles = economyWidgets.profTiles or {}
	local total, professions, crafts = CraftTotals(char)
	SetTile(tiles[1], ns.FormatNumber(total), "",
		nil, nil, professions > 0 and (ns.FormatNumber(professions)..(professions == 1 and " profession" or " professions")) or nil)
	tiles[1].tipCrafts = crafts

	local best = MostCraftedItem(char)
	if best then
		local name = (best.quality ~= nil and QualityCode(best.quality) or "")..CutRowText(best.name, 17).."|r"
		SetTile(tiles[2], name, ns.FormatNumber(best.count).." crafted", nil,
			best.quality ~= nil and QUALITY_COLORS[best.quality] or nil)
		tiles[2].tipItem = best
	else
		SetTile(tiles[2], "-", "nothing crafted yet")
		tiles[2].tipItem = nil
	end
end

local function RefreshProfessionCards(char)
	local cards = economyWidgets.profCards or {}
	local skills = PrimaryProfessions(char)
	for index = 1, 2 do
		local card = cards[index]
		local skill = skills[index]
		if not card then
			break
		elseif skill then
			ns.professionsUI.RefreshRecipeCard(card, char, skill.name)
		elseif index == 2 then
			ShowCardText(card, "No second primary profession recorded for this character.")
		else
			ShowCardText(card, "No primary profession recorded for this character yet.")
		end
	end
end

local function RefreshEconomyProfessions()
	if not economyWidgets.profTiles then
		return
	end
	local char = DisplayChar()
	local scrollKey = (char and char.name or "").."|"..(char and char.realm or "")
	if economyWidgets.profCharKey ~= scrollKey then
		economyWidgets.profCharKey = scrollKey
		economyWidgets.profScrollOffset = 0
		economyWidgets.profScrollOffset2 = 0
	end
	RefreshCraftTiles(char)
	RefreshCooldownTile(char)
	RefreshNotifyTile()
	RefreshProfessionCards(char)
end

local function BuildEconomyProfessions(page)
	economyWidgets.profTiles = {}
	CreateTileRow(page, -4, { "Items crafted", "Most crafted", "Cooldowns", "Cooldown alerts" },
		economyWidgets.profTiles, false)
	local tiles = economyWidgets.profTiles

	-- The fourth tile is the way into the notification options. It is a
	-- button in a tile's clothes: same figure area, same hover, one click.
	tiles[4]:EnableMouse(true)
	tiles[4]:SetScript("OnMouseUp", function(_, button)
		if button == "LeftButton" then
			ns.OpenProfessionNotifyPanel()
		end
	end)
	tiles[4]:SetScript("OnEnter", function(self)
		local on, chat, chime, settings = NotifyStatus()
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Cooldown notifications", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddDoubleLine("Notifications", on and "on" or "off",
			on and GREEN[1] or RED[1], on and GREEN[2] or RED[2], on and GREEN[3] or RED[3],
			on and GREEN[1] or RED[1], on and GREEN[2] or RED[2], on and GREEN[3] or RED[3])
		GameTooltip:AddDoubleLine("Chat message", chat and "on" or "off",
			0.9, 0.9, 0.9, chat and GREEN[1] or RED[1], chat and GREEN[2] or RED[2], chat and GREEN[3] or RED[3])
		GameTooltip:AddDoubleLine("Chime", chime and "on" or "off",
			0.9, 0.9, 0.9, chime and GREEN[1] or RED[1], chime and GREEN[2] or RED[2], chime and GREEN[3] or RED[3])
		GameTooltip:AddDoubleLine("This character", settings.thisChar and "on" or "off",
			0.9, 0.9, 0.9, settings.thisChar and GREEN[1] or RED[1], settings.thisChar and GREEN[2] or RED[2], settings.thisChar and GREEN[3] or RED[3])
		GameTooltip:AddDoubleLine("All selected characters", settings.allSelected and "on" or "off",
			0.9, 0.9, 0.9, settings.allSelected and GREEN[1] or RED[1], settings.allSelected and GREEN[2] or RED[2], settings.allSelected and GREEN[3] or RED[3])
		GameTooltip:AddDoubleLine("Cooldown items", settings.items ~= false and "on" or "off",
			0.9, 0.9, 0.9, settings.items ~= false and GREEN[1] or RED[1], settings.items ~= false and GREEN[2] or RED[2], settings.items ~= false and GREEN[3] or RED[3])
		GameTooltip:AddDoubleLine("After login", settings.loginNotify ~= false and "on" or "off",
			0.9, 0.9, 0.9, settings.loginNotify ~= false and GREEN[1] or RED[1], settings.loginNotify ~= false and GREEN[2] or RED[2], settings.loginNotify ~= false and GREEN[3] or RED[3])
		GameTooltip:AddDoubleLine("Near-ready warning", settings.near ~= false and "on" or "off",
			0.9, 0.9, 0.9, settings.near ~= false and GREEN[1] or RED[1], settings.near ~= false and GREEN[2] or RED[2], settings.near ~= false and GREEN[3] or RED[3])
		GameTooltip:AddDoubleLine("Repeat after", tostring(settings.intervalValue or 30).." "..tostring(settings.intervalUnit or "minutes"), 0.9, 0.9, 0.9, 1, 1, 1)
		GameTooltip:AddLine("Click to open the options.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	tiles[4]:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	tiles[1]:EnableMouse(true)
	tiles[1]:SetScript("OnEnter", function(self)
		local crafts = self.tipCrafts
		if not crafts then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Items crafted", ACCENT[1], ACCENT[2], ACCENT[3])
		local names = {}
		for name, count in pairs(crafts) do
			if type(count) == "number" and count > 0 then
				names[#names + 1] = { name = name, count = count }
			end
		end
		table.sort(names, function(a, b)
			if a.count ~= b.count then
				return a.count > b.count
			end
			return a.name < b.name
		end)
		if #names == 0 then
			GameTooltip:AddLine("Nothing crafted yet.", 0.7, 0.7, 0.7, true)
		end
		for index = 1, #names do
			GameTooltip:AddDoubleLine(names[index].name, ns.FormatNumber(names[index].count), 0.9, 0.9, 0.9, 1, 1, 1)
		end
		GameTooltip:Show()
	end)
	tiles[1]:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	tiles[2]:EnableMouse(true)
	tiles[2]:SetScript("OnEnter", function(self)
		local best = self.tipItem
		if not best then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(ItemName(best), ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine(ns.FormatNumber(best.count).." crafted", 1, 1, 1)
		GameTooltip:Show()
	end)
	tiles[2]:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	tiles[3]:EnableMouse(true)
	tiles[3]:SetScript("OnEnter", function(self)
		local rows = self.tipRows
		if not rows then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Cooldowns", ACCENT[1], ACCENT[2], ACCENT[3])
		if #rows == 0 then
			GameTooltip:AddLine("No cooldowns tracked for this character yet.", 0.7, 0.7, 0.7, true)
		else
			for index = 1, #rows do
				local entry = rows[index]
				GameTooltip:AddDoubleLine(ItemName(entry).." - "..tostring(entry.profession or "?"),
					CooldownText(entry), 0.9, 0.9, 0.9, 1, 1, 1)
			end
			GameTooltip:AddLine("Ready cooldowns come first, then the soonest to finish. The bar follows the first row.", 0.7, 0.7, 0.7, true)
		end
		GameTooltip:Show()
	end)
	tiles[3]:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	economyWidgets.profCards = {}
	economyWidgets.profCards[1] = CreateListCard(page, 0, -80, 359, 354, "First profession")
	economyWidgets.profCards[2] = CreateListCard(page, 371, -80, 359, 354, "Second profession")
	for index = 1, 2 do
		local card = economyWidgets.profCards[index]
		AddCardTitleNote(card, index == 1 and "First profession" or "Second profession",
			"Ranks are read at login and on every skill-up; recipes, counts and cooldowns are read while that profession's window is open. Hover a recipe for its reagents, and click it to show it in the game's own profession window.")
	end
	ns.professionsUI.AttachRecipeCard(economyWidgets.profCards[1], economyWidgets, "profScrollOffset", RefreshEconomyProfessions)
	ns.professionsUI.AttachRecipeCard(economyWidgets.profCards[2], economyWidgets, "profScrollOffset2", RefreshEconomyProfessions)

	ns.BuildProfessionNotifyPanel(page)
	RefreshEconomyProfessions()
end

ns.BuildEconomyProfessions = BuildEconomyProfessions
ns.RefreshEconomyProfessions = RefreshEconomyProfessions
ns.ProfessionUIBuildEconomy = ns.BuildEconomyProfessions
ns.ProfessionUIRefreshEconomy = ns.RefreshEconomyProfessions
ns.professionsUI.BuildEconomy = ns.ProfessionUIBuildEconomy
ns.professionsUI.RefreshEconomy = ns.ProfessionUIRefreshEconomy
