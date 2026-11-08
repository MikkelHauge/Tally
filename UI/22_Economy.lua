-- Tally - the Economy tab: page shell, sub-view frames and selection.
--
-- The ledger, the professions books and the auction page each own a file;
-- the daily balance graph now lives on the Total tab. This file only builds
-- their frames, switches between them and delegates a refresh to the visible
-- one.
local addonName, ns = ...

local ACCENT, economyWidgets, BuildEconomyLedger, RefreshEconomyLedger, BuildEconomyProfessions, RefreshEconomyProfessions, BuildEconomySecondary, RefreshEconomySecondary, BuildEconomyFavor, RefreshEconomyFavor, BuildEconomyUndermine, RefreshEconomyUndermine, pageRefresh =
	ns.ACCENT, ns.economyWidgets, ns.BuildEconomyLedger, ns.RefreshEconomyLedger, ns.BuildEconomyProfessions, ns.RefreshEconomyProfessions, ns.BuildEconomySecondary, ns.RefreshEconomySecondary, ns.BuildEconomyFavor, ns.RefreshEconomyFavor, ns.BuildEconomyUndermine, ns.RefreshEconomyUndermine, ns.pageRefresh

-- The economy page's sub-views: "ledger", "professions", "secondary",
-- "favor", "undermine" and "auction" (economyWidgets.subview).
-- SelectEconomySubview sets which is shown. The daily balance graph now lives
-- on the Total tab.
local function RefreshEconomy()
	if not economyWidgets.ledgerFrame then
		return
	end
	if economyWidgets.subview == "professions" then
		RefreshEconomyProfessions()
	elseif economyWidgets.subview == "secondary" then
		RefreshEconomySecondary()
	elseif economyWidgets.subview == "favor" then
		RefreshEconomyFavor()
	elseif economyWidgets.subview == "undermine" then
		RefreshEconomyUndermine()
	elseif economyWidgets.subview == "auction" then
		ns.RefreshAuctionView(economyWidgets.auctionStore)
	else
		RefreshEconomyLedger()
	end
end

-- A card that owns the tooltip must drop it as soon as its sub-view is left,
-- or a hover from the old page can outlive the switch.
local function ClearCardHover(card)
	if not card then
		return
	end
	card.hoverKey = nil
	if GameTooltip:IsOwned(card) then
		GameTooltip:Hide()
	end
end

local function SelectEconomySubview(name)
	economyWidgets.subview = name
	if economyWidgets.ledgerFrame then
		economyWidgets.ledgerFrame:SetShown(name == "ledger")
	end
	if economyWidgets.professionsFrame then
		economyWidgets.professionsFrame:SetShown(name == "professions")
	end
	if economyWidgets.secondaryFrame then
		economyWidgets.secondaryFrame:SetShown(name == "secondary")
	end
	if economyWidgets.favorFrame then
		economyWidgets.favorFrame:SetShown(name == "favor")
	end
	if economyWidgets.undermineFrame then
		economyWidgets.undermineFrame:SetShown(name == "undermine")
	end
	if economyWidgets.auctionFrame then
		economyWidgets.auctionFrame:SetShown(name == "auction")
	end
	-- The recipe cards own the tooltip while the cursor is over them, and
	-- their per-frame hover stops as soon as their sub-view is hidden.
	if name ~= "professions" then
		local cards = economyWidgets.profCards or {}
		for index = 1, #cards do
			ClearCardHover(cards[index])
		end
	end
	if name ~= "secondary" then
		ClearCardHover(economyWidgets.secondaryCard)
	end
	if name ~= "favor" then
		ClearCardHover(economyWidgets.favorCard)
	end
	if name ~= "undermine" then
		ClearCardHover(economyWidgets.undermineCard)
	end
	local buttons = economyWidgets.subButtons or {}
	for id, button in pairs(buttons) do
		local active = (id == name)
		button.underline:SetShown(active)
		button.text:SetTextColor(active and ACCENT[1] or 0.62, active and ACCENT[2] or 0.62, active and ACCENT[3] or 0.62)
	end
	RefreshEconomy()
end

local function BuildEconomyPage(page)
	-- Sub-view switch, the same widget the Total page uses.
	economyWidgets.subButtons = {}
	local x = 2
	local function AddSubButton(id, title)
		local button = CreateFrame("Button", nil, page)
		button:SetHeight(18)
		button.text = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		button.text:SetPoint("LEFT", 0, 0)
		button.text:SetText(title)
		button:SetWidth(button.text:GetStringWidth() + 20)
		button:SetPoint("TOPLEFT", page, "TOPLEFT", x, -2)
		button.underline = button:CreateTexture(nil, "ARTWORK")
		button.underline:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
		button.underline:SetHeight(2)
		button.underline:SetPoint("TOPLEFT", button.text, "BOTTOMLEFT", -2, -2)
		button.underline:SetPoint("TOPRIGHT", button.text, "BOTTOMRIGHT", 2, -2)
		button:RegisterForClicks("LeftButtonUp")
		button:SetScript("OnClick", function()
			SelectEconomySubview(id)
		end)
		economyWidgets.subButtons[id] = button
		x = x + button:GetWidth() + 10
	end
	AddSubButton("ledger", "Ledger")
	local hasFavor = ns.MerchantsFavorAvailable and ns.MerchantsFavorAvailable()
	if hasFavor then
		AddSubButton("favor", "Merchant's Favor")
	end
	local hasUndermine = ns.UndermineRealAvailable and ns.UndermineRealAvailable()
	if hasUndermine then
		AddSubButton("undermine", "Undermine Real")
	end
	AddSubButton("professions", "Professions")
	AddSubButton("secondary", "Secondary")
	AddSubButton("auction", "Auctions")

	local ledger = CreateFrame("Frame", nil, page)
	ledger:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	ledger:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	economyWidgets.ledgerFrame = ledger
	BuildEconomyLedger(ledger)

	if hasFavor then
		local favor = CreateFrame("Frame", nil, page)
		favor:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
		favor:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
		favor:Hide()
		economyWidgets.favorFrame = favor
		BuildEconomyFavor(favor)
	end

	if hasUndermine and BuildEconomyUndermine then
		local undermine = CreateFrame("Frame", nil, page)
		undermine:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
		undermine:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
		undermine:Hide()
		economyWidgets.undermineFrame = undermine
		BuildEconomyUndermine(undermine)
	end

	-- The professions sub-view: four tiles above two primary cards. The
	-- fourth tile opens the cooldown notification options.
	local professions = CreateFrame("Frame", nil, page)
	professions:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	professions:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	professions:Hide()
	economyWidgets.professionsFrame = professions
	BuildEconomyProfessions(professions)

	-- Secondary professions: one full-width card for Cooking, Fishing and
	-- First Aid. Its own sub-view, because it describes a different set of
	-- skills from the two primary cards.
	local secondary = CreateFrame("Frame", nil, page)
	secondary:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	secondary:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	secondary:Hide()
	economyWidgets.secondaryFrame = secondary
	BuildEconomySecondary(secondary)

	-- The auction house: the same page the Total tab draws, describing the
	-- character this tab is showing. The view keeps its own day range and
	-- order, so leaving the sub-view and coming back does not reset them.
	local auction = CreateFrame("Frame", nil, page)
	auction:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	auction:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	auction:Hide()
	economyWidgets.auctionFrame = auction
	economyWidgets.auctionStore = ns.BuildAuctionView(auction, { strip = page, combined = false })

	SelectEconomySubview("ledger")
	pageRefresh.economy = RefreshEconomy
end

-- Handed to the shell, which builds and refreshes every tab.
ns.BuildEconomyPage, ns.RefreshEconomy = BuildEconomyPage, RefreshEconomy
