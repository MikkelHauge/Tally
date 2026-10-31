-- Tally - the Total tab: page shell, sub-view frames and selection.
--
-- The combined figures, the level-times chart and the records table each own
-- a file. This file builds their frames, switches between them and delegates
-- a refresh to the visible one.
local addonName, ns = ...

local ACCENT, ShowCharPicker, charPickers, totalWidgets, RefreshTotalChart, RefreshTotalCombined, RefreshTotalRecords, BuildTotalChart, BuildTotalCombined, BuildTotalRecords, RefreshEconomyGraph, pageRefresh =
	ns.ACCENT, ns.ShowCharPicker, ns.charPickers, ns.totalWidgets, ns.RefreshTotalChart, ns.RefreshTotalCombined, ns.RefreshTotalRecords, ns.BuildTotalChart, ns.BuildTotalCombined, ns.BuildTotalRecords, ns.RefreshEconomyGraph, ns.pageRefresh

local function RefreshTotal()
	local subview = totalWidgets.subview
	if subview == "levels" then
		RefreshTotalChart()
	elseif subview == "records" then
		RefreshTotalRecords()
	elseif subview == "professions" then
		ns.RefreshTotalProfessions()
	elseif subview == "log" then
		ns.RefreshTotalLog()
	elseif subview == "auction" then
		ns.RefreshAuctionView(totalWidgets.auctionStore)
	elseif subview == "graph" then
		RefreshEconomyGraph()
	else
		RefreshTotalCombined()
	end
end

-- The picker, which is built before this, asks for a redraw of whatever the
-- Total tab is showing when a tick changes.
ns.RefreshCombinedNow = RefreshTotal

local function SelectTotalSubview(name)
	totalWidgets.subview = name
	if totalWidgets.combinedFrame then
		totalWidgets.combinedFrame:SetShown(name == "combined")
	end
	if totalWidgets.levelsFrame then
		totalWidgets.levelsFrame:SetShown(name == "levels")
	end
	if totalWidgets.recordsFrame then
		totalWidgets.recordsFrame:SetShown(name == "records")
	end
	if totalWidgets.professionsFrame then
		totalWidgets.professionsFrame:SetShown(name == "professions")
	end
	if totalWidgets.logFrame then
		totalWidgets.logFrame:SetShown(name == "log")
	end
	if totalWidgets.auctionFrame then
		totalWidgets.auctionFrame:SetShown(name == "auction")
	end
	if totalWidgets.graphFrame then
		totalWidgets.graphFrame:SetShown(name == "graph")
	end
	local buttons = totalWidgets.subButtons or {}
	for id, button in pairs(buttons) do
		local active = (id == name)
		button.underline:SetShown(active)
		button.text:SetTextColor(active and ACCENT[1] or 0.62, active and ACCENT[2] or 0.62, active and ACCENT[3] or 0.62)
	end
	-- The exact-times card owns the tooltip while the cursor is over it, so
	-- it is dropped as the sub-view is left.
	if name ~= "levels" and totalWidgets.table then
		totalWidgets.table.hoverKey = nil
		if GameTooltip:IsOwned(totalWidgets.table) then
			GameTooltip:Hide()
		end
	end
	if name ~= "levels" and charPickers.levels and charPickers.levels.shown then
		ShowCharPicker("levels", false)
	end
	if name ~= "professions" and ns.ClearTotalProfessionsHover then
		ns.ClearTotalProfessionsHover()
	end
	RefreshTotal()
end

local function BuildTotalPage(page)
	-- Sub-view switch, styled like the tab bar.
	totalWidgets.subButtons = {}
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
			SelectTotalSubview(id)
		end)
		totalWidgets.subButtons[id] = button
		x = x + button:GetWidth() + 10
	end
	AddSubButton("combined", "Combined")
	AddSubButton("levels", "Levelling graph")
	AddSubButton("graph", "Economy graph")
	AddSubButton("professions", "Professions")
	AddSubButton("records", "Records")
	AddSubButton("log", "Log")
	AddSubButton("auction", "Auctions")

	local combined = CreateFrame("Frame", nil, page)
	combined:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	combined:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	totalWidgets.combinedFrame = combined
	BuildTotalCombined(combined)

	-- The economy graph, moved here from the Economy tab: the same selected
	-- characters, drawn as end-of-day balances over the chosen window.
	local graph = CreateFrame("Frame", nil, page)
	graph:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	graph:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	graph:Hide()
	totalWidgets.graphFrame = graph
	ns.BuildEconomyGraph(graph)

	-- Professions: the selected-character summary and the cooldown board.
	-- Both read the Total picker's ticks, so a change there redraws them.
	local professions = CreateFrame("Frame", nil, page)
	professions:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	professions:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	professions:Hide()
	totalWidgets.professionsFrame = professions
	ns.BuildTotalProfessions(professions)

	-- Level times: a line chart over the exact numbers, with a table below.
	local levels = CreateFrame("Frame", nil, page)
	levels:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	levels:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	totalWidgets.levelsFrame = levels
	BuildTotalChart(levels)

	-- Records: the cross-character bests, on their own sub-view.
	local records = CreateFrame("Frame", nil, page)
	records:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	records:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	totalWidgets.recordsFrame = records
	BuildTotalRecords(records)

	-- The paginated log: every stored event across the ticked characters.
	local log = CreateFrame("Frame", nil, page)
	log:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	log:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	log:Hide()
	totalWidgets.logFrame = log
	ns.BuildTotalLog(log)

	-- Auctions: the same page the Economy tab draws, covering every ticked
	-- character. The characters button in its strip opens the one picker, so
	-- the ticks here are the ticks everywhere else.
	local auction = CreateFrame("Frame", nil, page)
	auction:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	auction:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	auction:Hide()
	totalWidgets.auctionFrame = auction
	totalWidgets.auctionStore = ns.BuildAuctionView(auction, {
		strip = page,
		combined = true,
		list = function()
			local out = {}
			local known = ns.KnownCharacters()
			for index = 1, #known do
				local entry = known[index]
				if ns.TotalIncludes(entry.key) then
					out[#out + 1] = {
						key = entry.key, char = entry.char,
						name = ns.DisplayName(entry.char),
					}
				end
			end
			return out
		end,
	})

	SelectTotalSubview("combined")
	pageRefresh.total = RefreshTotal
end

-- Handed to the shell, which builds and refreshes every tab.
ns.BuildTotalPage, ns.RefreshTotal = BuildTotalPage, RefreshTotal
