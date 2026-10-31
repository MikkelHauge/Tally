-- Tally - the Economy tab's secondary professions: Cooking, Fishing and
-- First Aid on one full-width card.
--
-- Archaeology is deliberately absent: it is not tracked, shown or notified.
-- The card is drawn by the shared kit so it cannot drift from the primary
-- profession cards.
local addonName, ns = ...

local DisplayChar, CreateListCard, AddCardTitleNote, economyWidgets =
	ns.DisplayChar, ns.CreateListCard, ns.AddCardTitleNote, ns.economyWidgets

local function RefreshEconomySecondary()
	local card = economyWidgets.secondaryCard
	if not card then
		return
	end
	local char = DisplayChar()
	local scrollKey = (char and char.name or "").."|"..(char and char.realm or "")
	if economyWidgets.secondaryCharKey ~= scrollKey then
		economyWidgets.secondaryCharKey = scrollKey
		economyWidgets.secondaryScrollOffset = 0
	end
	ns.professionsUI.RefreshSecondaryCard(card, char)
end

local function BuildEconomySecondary(page)
	-- One card, full width, matching the height of the two primary cards.
	local card = CreateListCard(page, 0, -4, 730, 434, "Secondary professions")
	economyWidgets.secondaryCard = card
	AddCardTitleNote(card, "Secondary professions",
		"Cooking, Fishing and First Aid, in that order, for the character being shown. Ranks are read at login; recipes and cooldowns are read while the profession's window is open. Archaeology is not tracked.")
	ns.professionsUI.AttachRecipeCard(card, economyWidgets, "secondaryScrollOffset", RefreshEconomySecondary)
	RefreshEconomySecondary()
end

ns.BuildEconomySecondary = BuildEconomySecondary
ns.RefreshEconomySecondary = RefreshEconomySecondary
ns.ProfessionUIBuildSecondary = ns.BuildEconomySecondary
ns.ProfessionUIRefreshSecondary = ns.RefreshEconomySecondary
ns.professionsUI.BuildSecondary = ns.ProfessionUIBuildSecondary
ns.professionsUI.RefreshSecondary = ns.ProfessionUIRefreshSecondary
