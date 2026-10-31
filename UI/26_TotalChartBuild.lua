-- Tally - the Total tab's level-times card, range controls and picker.
local addonName, ns = ...

local ACCENT, TILE_BACKDROP, CreateListCard, CreateInfoButton, AddCardTitleNote, MakeCardScrollable, CreateCornerButton, SetCornerLabel, RowHoverTick, BuildCharPicker, ShowCharPicker, charPickers, RefreshTotalChart, totalWidgets =
	ns.ACCENT, ns.TILE_BACKDROP, ns.CreateListCard, ns.CreateInfoButton, ns.AddCardTitleNote, ns.MakeCardScrollable, ns.CreateCornerButton, ns.SetCornerLabel, ns.RowHoverTick, ns.BuildCharPicker, ns.ShowCharPicker, ns.charPickers, ns.RefreshTotalChart, ns.totalWidgets

local LEVELS_INFO = {
	"One line per character: a point sits where that character reached a level, and its height is the time spent on the level before it - lower is faster.",
	"Times come from the game's own /played figure; a point that cannot be measured is left out and said so, and the estimate in Settings (off by default) fills such gaps faintly. Drag the sliders to choose the levels drawn, and click a name under the title to switch that character's line on or off.",
}

local function BuildTotalChart(levels)
	totalWidgets.chartCard = CreateListCard(levels, 0, -4, 730, 200, "Levelling graph")
	local chart = totalWidgets.chartCard
	AddCardTitleNote(chart, "Levelling graph",
		"One line per character. The title shows the level range; the counts of switched-off, undrawn and no-level-up characters are in this hover. Hover a point for its exact time.")
	local plot = CreateFrame("Frame", nil, chart)
	plot:SetPoint("TOPLEFT", chart, "TOPLEFT", 12, -48)
	plot:SetPoint("BOTTOMRIGHT", chart, "BOTTOMRIGHT", -12, 22)
	totalWidgets.plot = plot

	-- The level range, in a strip under the chart: two sliders with a box
	-- beside each, the switch that takes the range to the characters' current
	-- levels, and a reset back to the span of the data. Every one of them
	-- redraws the chart.
	totalWidgets.rangeMode = "auto"
	local strip = CreateFrame("Frame", nil, levels, "BackdropTemplate")
	strip:SetBackdrop(TILE_BACKDROP)
	strip:SetBackdropColor(0, 0, 0, 0.35)
	strip:SetBackdropBorderColor(1, 0.72, 0.25, 0.12)
	strip:SetPoint("TOPLEFT", levels, "TOPLEFT", 0, -208)
	strip:SetSize(730, 26)
	totalWidgets.rangeStrip = strip

	-- The controls show the range the chart resolved, so the data's own span
	-- and the current-levels switch are both visible in them. Setting them
	-- from here must not be read as the user moving a slider.
	local function SyncRangeControls()
		totalWidgets.rangeSyncing = true
		local from = totalWidgets.rangeFrom or 1
		local to = totalWidgets.rangeTo or from
		if totalWidgets.rangeFromSlider then
			totalWidgets.rangeFromSlider:SetValue(from)
			totalWidgets.rangeFromBox:SetText(tostring(from))
			totalWidgets.rangeToSlider:SetValue(to)
			totalWidgets.rangeToBox:SetText(tostring(to))
		end
		if totalWidgets.currentButton then
			totalWidgets.currentButton:SetText(totalWidgets.rangeMode == "current" and "current levels: on" or "current levels: off")
		end
		totalWidgets.rangeSyncing = false
	end
	-- The chart's refresh calls this, so the sliders always show the range the
	-- chart actually used (a switch, or a slider taken to the data's edge).
	totalWidgets.syncRangeControls = SyncRangeControls

	local function AddRangeControl(label, x, which)
		local text = strip:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		text:SetPoint("LEFT", x, 0)
		text:SetText(label)
		text:SetTextColor(0.62, 0.62, 0.62)
		local slider = CreateFrame("Slider", nil, strip, "OptionsSliderTemplate")
		slider:SetPoint("LEFT", text, "RIGHT", 6, 0)
		slider:SetWidth(150)
		slider:SetHeight(16)
		-- The two ends have different ranges: "from" can never be the cap (a
		-- single-level range is not a graph), and "to" can never be level 1.
		local rangeMin = (which == "from") and 1 or 2
		local rangeMax = (which == "from") and 59 or 60
		slider:SetMinMaxValues(rangeMin, rangeMax)
		slider:SetValueStep(1)
		if slider.SetObeyStepOnDrag then
			slider:SetObeyStepOnDrag(true)
		end
		-- OptionsSliderTemplate names its own regions after the frame; the
		-- boxes beside the sliders carry the numbers here.
		if slider.Low then
			slider.Low:SetText("")
		end
		if slider.High then
			slider.High:SetText("")
		end
		if slider.Text then
			slider.Text:SetText("")
		end
		local box = CreateFrame("EditBox", nil, strip, "InputBoxTemplate")
		box:SetSize(34, 18)
		box:SetPoint("LEFT", slider, "RIGHT", 8, 0)
		box:SetAutoFocus(false)
		box:SetMaxLetters(2)
		box:SetJustifyH("CENTER")
		slider:SetScript("OnValueChanged", function(_, value)
			if totalWidgets.rangeSyncing then
				return
			end
			local number = math.floor((value or 1) + 0.5)
			totalWidgets.rangeMode = "manual"
			if which == "from" then
				totalWidgets.rangeFrom = number
				if (totalWidgets.rangeTo or 0) < number then
					totalWidgets.rangeTo = number
				end
			else
				totalWidgets.rangeTo = number
				if (totalWidgets.rangeFrom or 1) > number then
					totalWidgets.rangeFrom = number
				end
			end
			SyncRangeControls()
			RefreshTotalChart()
		end)
		box:SetScript("OnEnterPressed", function(self)
			local number = math.max(rangeMin, math.min(rangeMax, math.floor(tonumber(self:GetText()) or rangeMin)))
			self:ClearFocus()
			totalWidgets.rangeMode = "manual"
			if which == "from" then
				totalWidgets.rangeFrom = number
			else
				totalWidgets.rangeTo = number
			end
			SyncRangeControls()
			RefreshTotalChart()
		end)
		box:SetScript("OnEscapePressed", function(self)
			self:ClearFocus()
			SyncRangeControls()
		end)
		if which == "from" then
			totalWidgets.rangeFromSlider, totalWidgets.rangeFromBox = slider, box
		else
			totalWidgets.rangeToSlider, totalWidgets.rangeToBox = slider, box
		end
	end

	AddRangeControl("from", 12, "from")
	AddRangeControl("to", 260, "to")

	local currentButton = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
	currentButton:SetSize(150, 18)
	currentButton:SetPoint("LEFT", 470, 0)
	currentButton:SetScript("OnClick", function()
		if totalWidgets.rangeMode == "current" then
			totalWidgets.rangeMode = "auto"
		else
			totalWidgets.rangeMode = "current"
		end
		ns.Trace("level chart range: "..totalWidgets.rangeMode)
		SyncRangeControls()
		RefreshTotalChart()
	end)
	totalWidgets.currentButton = currentButton

	local resetButton = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
	resetButton:SetSize(90, 18)
	resetButton:SetPoint("LEFT", currentButton, "RIGHT", 8, 0)
	resetButton:SetText("whole range")
	resetButton:SetScript("OnClick", function()
		totalWidgets.rangeMode = "auto"
		ns.Trace("level chart range: auto (the span of the data)")
		SyncRangeControls()
		RefreshTotalChart()
	end)
	totalWidgets.resetRangeButton = resetButton
	SyncRangeControls()

	-- The top-right corner: the Info button at the right edge, with the
	-- characters picker to its left. The page arrows are gone - the range strip
	-- under the chart is what chooses the levels now.
	local chartInfo = CreateInfoButton(chart, "Levelling graph", LEVELS_INFO, -8, -5)
	local chartCharacters = CreateCornerButton(chart, -8, -5)
	SetCornerLabel(chartCharacters, "characters")
	chartCharacters:ClearAllPoints()
	chartCharacters:SetPoint("TOPRIGHT", chartInfo, "TOPLEFT", -6, 0)
	chartCharacters:SetScript("OnClick", function()
		ShowCharPicker("levels", not (charPickers.levels and charPickers.levels.shown))
	end)
	chartCharacters:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Which characters are drawn", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("One row per character this chart can draw - the ones ticked in the Total tab's own character list - both sides of the realm, each with the colour of its line.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	chartCharacters:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	totalWidgets.chartCharactersButton = chartCharacters

	-- The exact-times table: every level in the range, newest first, in a
	-- scrolling window.
	totalWidgets.table = CreateListCard(levels, 0, -238, 730, 196, "Exact times")
	AddCardTitleNote(totalWidgets.table, "Exact times",
		"The same numbers the chart draws, one row per level, fastest character first. An amber (!) marks a figure that is not a full measurement - hover the row to see why - and (est.) marks one filled by the estimate in Settings.")
	-- The rows explain themselves on hover, and the wheel walks the list.
	MakeCardScrollable(totalWidgets.table, totalWidgets, "exactScrollOffset", RefreshTotalChart)
	totalWidgets.table:SetScript("OnUpdate", function()
		RowHoverTick(totalWidgets.table)
	end)
	totalWidgets.table:SetScript("OnLeave", function()
		totalWidgets.table.hoverKey = nil
		if GameTooltip:IsOwned(totalWidgets.table) then
			GameTooltip:Hide()
		end
	end)

	-- The level-times characters picker, the same window the daily graph has.
	BuildCharPicker(ns.contentFrame, "levels")
end

ns.BuildTotalChart = BuildTotalChart
