-- Tally - the shared paginated list. No wheel and no scrollbar: the user asked
-- for real page buttons on the Total log and the Character timeline.
local addonName, ns = ...

local CreateListCard, FillCardRows, ShowCardText, RowHoverTick, ACCENT =
	ns.CreateListCard, ns.FillCardRows, ns.ShowCardText, ns.RowHoverTick, ns.ACCENT

local function PageButton(parent, text)
	local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
	button:SetSize(52, 18)
	button:SetText(text)
	return button
end

-- Builds a card and a control strip under it. The caller owns the line data:
-- state.SetLines(lines, resetPage) replaces it and redraws.
function ns.BuildPagedList(parent, x, y, width, height, title, pageSize)
	local card = CreateListCard(parent, x, y, width, height, title)
	local bar = CreateFrame("Frame", nil, parent)
	bar:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y - height - 4)
	bar:SetSize(width, 22)

	local first = PageButton(bar, "first")
	first:SetPoint("LEFT", 0, 0)
	local prev = PageButton(bar, "prev")
	prev:SetPoint("LEFT", first, "RIGHT", 4, 0)
	local nextButton = PageButton(bar, "next")
	nextButton:SetPoint("RIGHT", -60, 0)
	local last = PageButton(bar, "last")
	last:SetPoint("RIGHT", 0, 0)

	local label = bar:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	label:SetPoint("CENTER", bar, "CENTER", 0, 0)
	label:SetTextColor(0.72, 0.72, 0.72)

	card:SetScript("OnUpdate", function()
		RowHoverTick(card)
	end)
	card:SetScript("OnLeave", function()
		card.hoverKey = nil
		if GameTooltip:IsOwned(card) then
			GameTooltip:Hide()
		end
	end)

	local state = {
		page = 1,
		pageSize = pageSize or 20,
		lines = {},
		card = card,
	}
	local function Enable(button, enabled)
		button:SetAlpha(enabled and 1 or 0.35)
		button:EnableMouse(enabled)
	end
	local function Draw()
		local total = #state.lines
		local pageCount = math.max(1, math.ceil(total / state.pageSize))
		if state.page < 1 then
			state.page = 1
		elseif state.page > pageCount then
			state.page = pageCount
		end
		local startIndex = (state.page - 1) * state.pageSize + 1
		local endIndex = math.min(total, startIndex + state.pageSize - 1)
		local window = {}
		for index = startIndex, endIndex do
			window[#window + 1] = state.lines[index]
		end
		if #window == 0 then
			ShowCardText(card, "No events recorded yet.")
		else
			FillCardRows(card, window, 92, false)
		end
		label:SetText(string.format("page %d / %d  ·  %d-%d of %d",
			state.page, pageCount, total > 0 and startIndex or 0,
			total > 0 and endIndex or 0, total))
		Enable(first, state.page > 1)
		Enable(prev, state.page > 1)
		Enable(nextButton, state.page < pageCount)
		Enable(last, state.page < pageCount)
	end
	first:SetScript("OnClick", function()
		state.page = 1
		Draw()
	end)
	prev:SetScript("OnClick", function()
		state.page = math.max(1, state.page - 1)
		Draw()
	end)
	nextButton:SetScript("OnClick", function()
		state.page = state.page + 1
		Draw()
	end)
	last:SetScript("OnClick", function()
		state.page = math.max(1, math.ceil(#state.lines / state.pageSize))
		Draw()
	end)

	function state.SetLines(lines, resetPage)
		state.lines = lines or {}
		if resetPage then
			state.page = 1
		end
		Draw()
	end
	function state.Reset()
		state.page = 1
		Draw()
	end
	Draw()
	return state
end
