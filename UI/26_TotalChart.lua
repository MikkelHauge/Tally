-- Tally - the Total tab's level-times chart and exact-times table.
local addonName, ns = ...

local ACCENT, TILE_BACKDROP, CharColor, DailyColors, FillCardRows, LayoutLegend, CanRotate, ColorMarkup, RefreshExactTimes, charPickers, totalWidgets =
	ns.ACCENT, ns.TILE_BACKDROP, ns.CharColor, ns.DailyColors, ns.FillCardRows, ns.LayoutLegend, ns.CanRotate, ns.ColorMarkup, ns.RefreshExactTimes, ns.charPickers, ns.totalWidgets

-- Hover text for the Level times card's Info button.


-- The series the level-times graph draws, from ns.LevelSeries(true). The
-- legend is the selection itself: one name for each character ticked in the
-- picker, and no others. A ticked character can be switched off from the
-- legend, which is a state of this view alone - it greys the name and leaves
-- the tick where it was - so the two always name the same characters. A
-- selected series with no points is counted (withoutData), not plotted.
-- Returns shown, withPoints, withoutData, hiddenCount and overflow.
local function ChartSeries()
	local all = ns.LevelSeries(true)
	-- Colours come from the full list by the same rule the picker uses, so a
	-- row and its line always match and a second character of one class gets a
	-- colour of its own.
	local colors = DailyColors(all)
	local withPoints = {}
	local noPoints = {}
	local withoutData = 0
	local picked = 0
	for index = 1, #all do
		local series = all[index]
		series.color = colors[series.key] or CharColor(series.char)
		-- A character who began at level 1 has no time behind it, so the line
		-- starts on the floor at level 1 instead of appearing out of nowhere
		-- at level 2. A class that begins above level 1 gets no anchor: its
		-- first level is not level 1.
		if #series.points > 0 and (series.char.firstLevel or 1) <= 1
			and series.points[1].level and series.points[1].level > 1 then
			local anchor = { level = 1, seconds = 0, at = series.char.created, anchor = true }
			table.insert(series.points, 1, anchor)
			series.byLevel[1] = anchor
		end
		if not ns.TotalIncludes(series.key) then
			-- Not picked: not drawn, and not listed in the legend at all.
			series.hidden = true
		else
			picked = picked + 1
			if #series.points > 0 then
				-- Greyed, but still in the legend and still ticked, until the
				-- picker is used again.
				series.hidden = (charPickers.greyed and charPickers.greyed[series.key]) and true or false
				withPoints[#withPoints + 1] = series
			else
				-- Ticked, but with no level-up recorded yet: there is no line
				-- to draw. The character still gets a legend entry, dimmed and
				-- not clickable, so the legend names exactly the picker's
				-- characters.
				series.noLine = true
				withoutData = withoutData + 1
				noPoints[#noPoints + 1] = series
			end
		end
	end
	-- How many characters the selection covers, so the empty chart can say
	-- whether nothing is ticked or nothing has been recorded.
	totalWidgets.pickedCount = picked
	table.sort(withPoints, function(a, b)
		if a.tracked == b.tracked then
			return tostring(a.name) < tostring(b.name)
		end
		return a.tracked > b.tracked
	end)
	-- The characters with nothing to draw are listed after the drawn ones, in
	-- name order, which is stable between refreshes.
	table.sort(noPoints, function(a, b)
		return tostring(a.name) < tostring(b.name)
	end)
	-- Every character in the selection gets a line; a character with no
	-- level-ups has nothing to draw and is listed without one. Hidden ones are
	-- counted separately, for the card's own note.
	local shown = {}
	local hiddenCount = 0
	for index = 1, #withPoints do
		local series = withPoints[index]
		if series.hidden then
			hiddenCount = hiddenCount + 1
		else
			shown[#shown + 1] = series
		end
	end
	return shown, withPoints, withoutData, hiddenCount, 0, noPoints
end

-- Cached probe for Texture:SetRotation, which some clients lack; the graphs

-- One line segment, a pooled texture in totalWidgets.segments. Returns the
-- segment, shown.
local function ChartSegment(index)
	local segment = totalWidgets.segments[index]
	if not segment then
		segment = totalWidgets.plot:CreateTexture(nil, "ARTWORK")
		totalWidgets.segments[index] = segment
	end
	segment:Show()
	return segment
end

-- One data point marker, a pooled frame in totalWidgets.markers. Hovering it
-- shows marker.info (title, text, color, note).
local function ChartMarker(index)
	local marker = totalWidgets.markers[index]
	if not marker then
		marker = CreateFrame("Frame", nil, totalWidgets.plot)
		marker.tex = marker:CreateTexture(nil, "OVERLAY")
		marker.tex:SetPoint("CENTER", 0, 0)
		marker:EnableMouse(true)
		marker:SetScript("OnEnter", function(self)
			local info = self.info
			if not info then
				return
			end
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine(info.title, info.color[1], info.color[2], info.color[3])
			GameTooltip:AddLine(info.text, 1, 1, 1, true)
			if info.note then
				GameTooltip:AddLine(info.note, 0.7, 0.7, 0.7, true)
			end
			GameTooltip:Show()
		end)
		marker:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		totalWidgets.markers[index] = marker
	end
	marker:Show()
	return marker
end

-- Collects the series and level list the chart and the table share: every
-- level with data, oldest first, and the page of LEVELS_PER_PAGE on screen.
-- Returns series, levels, first, last and pages.
-- The levels the chart draws: every level in the chosen range, oldest first.
-- (The range itself is chosen by the strip under the chart.) Returns the
-- series and the level list.
local function LevelWindow()
	local series, withPoints, withoutData, hiddenCount, overflow, noPoints = ChartSeries()
	totalWidgets.series = series
	totalWidgets.withPoints = withPoints
	totalWidgets.noPoints = noPoints
	totalWidgets.withoutData = withoutData
	totalWidgets.hiddenCount = hiddenCount
	totalWidgets.overflow = overflow

	-- The span of the data, and the highest level a drawn character is on now.
	local lowest, highest, currentMax
	for index = 1, #withPoints do
		local line = withPoints[index]
		-- Only lines that are drawn set the range: an unticked character keeps
		-- its legend entry, but must not stretch the axes.
		if not line.hidden then
			local now = line.level or 0
			if now > 0 and (not currentMax or now > currentMax) then
				currentMax = now
			end
			local points = line.points
			for position = 1, #points do
				local level = points[position].level
				if level then
					if not lowest or level < lowest then
						lowest = level
					end
					if not highest or level > highest then
						highest = level
					end
				end
			end
		end
	end

	local from, to
	local mode = totalWidgets.rangeMode or "auto"
	if mode == "manual" then
		from, to = totalWidgets.rangeFrom, totalWidgets.rangeTo
	elseif mode == "current" then
		-- The data's own lowest level and the highest level a drawn character
		-- is on now.
		from, to = lowest, currentMax or highest
	else
		from, to = lowest, highest
	end
	if not from then
		from = lowest or 1
	end
	if not to then
		to = highest or from
	end
	-- Levels run 1 to 60 here, which is what the sliders offer; the maths is
	-- clamped rather than trusting them.
	from = math.max(1, math.min(60, math.floor(from)))
	to = math.max(from, math.min(60, math.floor(to)))
	totalWidgets.rangeFrom, totalWidgets.rangeTo = from, to

	local levels = {}
	for level = from, to do
		levels[#levels + 1] = level
	end
	totalWidgets.levels = levels
	return series, levels
end

-- The level-times chart's own refresher: declared above with the other
-- forward declarations, because the characters picker for it (defined near the
-- top of the file) calls it when a tick changes, as do the range controls.
local function RefreshTotalChart()
	if not totalWidgets.plot then
		return
	end
	-- While the levelling sub-view is hidden the plot has no real size; a
	-- draw now would cache degenerate geometry under the current signature.
	-- The plot itself may be hidden because the previous refresh found
	-- nothing to draw; that must not stop the next refresh, which shows it
	-- again once there is a line.
	local levelsFrame = totalWidgets.levelsFrame
	if levelsFrame and not levelsFrame:IsShown() then
		totalWidgets.chartSignature = nil
		return
	end
	local plot = totalWidgets.plot
	local card = totalWidgets.chartCard
	local series, levels = LevelWindow()
	local first, last = 1, #levels

	local function PageLabel()
		if #levels > 0 then
			return string.format("Levelling graph - levels %d to %d", levels[1], levels[#levels])
		end
		return "Levelling graph"
	end
	local function PageNotes(fullBar)
		local notes = {}
		if totalWidgets.hiddenCount and totalWidgets.hiddenCount > 0 then
			notes[#notes + 1] = totalWidgets.hiddenCount.." switched off"
		end
		if totalWidgets.overflow and totalWidgets.overflow > 0 then
			notes[#notes + 1] = totalWidgets.overflow.." not drawn (too many lines)"
		end
		if totalWidgets.withoutData and totalWidgets.withoutData > 0 then
			notes[#notes + 1] = totalWidgets.withoutData.." with no level-ups yet"
		end
		if totalWidgets.rangeMode == "current" then
			notes[#notes + 1] = "to current levels"
		end
		if fullBar then
			notes[#notes + 1] = "the top of the scale is "..ns.FormatDuration(fullBar, true)
		end
		return table.concat(notes, " · ")
	end

	-- A signature of everything the graph draws; an unchanged signature
	-- returns early, so the lines are rebuilt only when the data moves. The
	-- range is part of it: moving a slider changes the axes without moving a
	-- number, and that has to redraw.
	local signature = (totalWidgets.rangeFrom or 0) * 1000003 + (totalWidgets.rangeTo or 0) * 15485863
	signature = signature + ((totalWidgets.rangeMode == "auto") and 1 or 2) * 3571
	signature = signature + #series + #levels
	signature = signature + (totalWidgets.withoutData or 0) * 7919
	signature = signature + (totalWidgets.hiddenCount or 0) * 104729
	signature = signature + (totalWidgets.overflow or 0) * 1299709
	for index = 1, #series do
		local total = 0
		local points = series[index].points
		for position = 1, #points do
			total = total + (points[position].seconds or 0)
		end
		-- The character identity is part of it too: two characters with the
		-- same numbers would otherwise keep the old legend and name.
		local key = series[index].key or series[index].name or ""
		for position = 1, #key do
			signature = signature + string.byte(key, position) * position
		end
		signature = signature + index * 7919 + #points * 131 + (total % 100003) + ((series[index].tracked or 0) % 99991)
	end
	if signature == totalWidgets.chartSignature then
		return
	end
	totalWidgets.chartSignature = signature

	if totalWidgets.earlier then
		totalWidgets.earlier:Hide()
		totalWidgets.later:Hide()
	end
	if #levels == 0 or first > last or #(totalWidgets.withPoints or {}) == 0 then
		-- Everything drawn is parented to the plot, so hiding it is enough.
		plot:Hide()
		for index = 1, #totalWidgets.legend do
			totalWidgets.legend[index].button:Hide()
		end
		if card and card.legendNote then
			card.legendNote:Hide()
		end
		if card then
			local label = PageLabel()
			card.title:SetText(label)
			card.noteTitle = label
			totalWidgets.chartNotes = PageNotes()
			card.noteText = totalWidgets.chartNotes
			if (totalWidgets.pickedCount or 0) == 0 then
				card.body:SetText("No characters are ticked in the character list, so there is nothing to draw. Use characters in the corner to pick some.")
			else
				card.body:SetText("No level-ups recorded for the characters in this total yet. Tally measures a level from the game's own /played total when it is reached.")
			end
		end
		if totalWidgets.table then
			-- Clears any rows a previous refresh drew, then says why.
			FillCardRows(totalWidgets.table, {})
			totalWidgets.table.body:SetText("No levelling data to show for these characters yet.")
		end
		if totalWidgets.holeNote then
			totalWidgets.holeNote:Hide()
		end
		return
	end
	if card then
		card.body:SetText("")
	end
	plot:Show()

	-- A level with no point between two levels that have one is a hole the
	-- chart cannot draw, and nothing else on the page says why. The card's
	-- bottom strip says how many there are; while the estimate is off, the
	-- note is also the way to switch it on.
	local estimateOn = ns.db and ns.db.settings and ns.db.settings.levelEstimate
	local holeCount = 0
	for slot = 1, #levels do
		local level = levels[slot]
		local hasPoint, below, above = false, false, false
		for index = 1, #series do
			local line = series[index]
			if not line.hidden then
				if line.byLevel[level] then
					hasPoint = true
				end
				for position = 1, #line.points do
					local other = line.points[position].level
					if other and other < level then
						below = true
					elseif other and other > level then
						above = true
					end
				end
			end
		end
		if not hasPoint and below and above then
			holeCount = holeCount + 1
		end
	end
	local holeNote = totalWidgets.holeNote
	if not holeNote then
		holeNote = CreateFrame("Button", nil, card)
		holeNote:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", 12, 6)
		holeNote:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -12, 6)
		holeNote:SetHeight(12)
		holeNote.text = holeNote:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		holeNote.text:SetAllPoints(holeNote)
		holeNote.text:SetJustifyH("LEFT")
		holeNote:SetScript("OnClick", function()
			if ns.OpenSettings then
				ns.OpenSettings()
			end
		end)
		holeNote:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine("Levels with no time recorded", ACCENT[1], ACCENT[2], ACCENT[3])
			GameTooltip:AddLine("The game measures a stretch of levels as one total. Tally can share such a stretch equally between the levels in it, drawn faint and marked (est.): that is the 'Estimate levels Tally did not see' setting under Played time in Settings.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		holeNote:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		totalWidgets.holeNote = holeNote
	end
	if holeCount > 0 then
		local levelWord = (holeCount == 1) and "level has" or "levels have"
		if estimateOn then
			holeNote.text:SetText(holeCount.." "..levelWord.." no time recorded - there is nothing to share out between them.")
			holeNote.text:SetTextColor(0.55, 0.55, 0.55)
			holeNote:EnableMouse(false)
		else
			holeNote.text:SetText(holeCount.." "..levelWord.." no time recorded. Click to switch on the estimate in Settings.")
			holeNote.text:SetTextColor(0.95, 0.72, 0.3)
			holeNote:EnableMouse(true)
		end
		holeNote:Show()
	else
		holeNote:Hide()
	end

	-- A character with one measured level is a dot, not a line. Nothing on the
	-- page said so, which made a young character look like missing data.
	local loneNames = {}
	for index = 1, #series do
		local line = series[index]
		if not line.hidden and #line.points == 1 and line.points[1].seconds then
			loneNames[#loneNames + 1] = line.name
		end
	end
	if #loneNames > 0 then
		local who = #loneNames == 1 and loneNames[1] or (#loneNames.." characters")
		local verb = #loneNames == 1 and " has" or " have"
		local text = who..verb.." one level measured so far - a line needs two."
		if holeCount > 0 then
			holeNote.text:SetText(holeNote.text:GetText().."   ·   "..text)
		else
			holeNote.text:SetText(text)
			holeNote.text:SetTextColor(0.55, 0.55, 0.55)
			holeNote:EnableMouse(false)
		end
		holeNote:Show()
	end

	-- One legend button per ticked character, in the picker's own order and
	-- colours. Clicking one switches that line off in this view alone: the
	-- name stays where it is, greyed, and the same click draws it again. The
	-- picker's ticks are not touched, so the legend and the picker always
	-- list the same characters. Characters with no level-up yet are listed
	-- last, dimmed, because there is no line to switch.
	local legendList = {}
	for index = 1, #(totalWidgets.withPoints or {}) do
		legendList[#legendList + 1] = totalWidgets.withPoints[index]
	end
	for index = 1, #(totalWidgets.noPoints or {}) do
		legendList[#legendList + 1] = totalWidgets.noPoints[index]
	end
	local legendButtons = {}
	for index = 1, #legendList do
		local line = legendList[index]
		local entry = totalWidgets.legend[index]
		if not entry then
			entry = {}
			-- A framed legend button, raised above the card (frame level
			-- + 4). The plot's markers are one frame level higher and its
			-- top edge reaches into the last legend row, so without the
			-- lift they would take part of the names' click area.
			entry.button = CreateFrame("Button", nil, card, "BackdropTemplate")
			entry.button:SetHeight(18)
			entry.button:SetFrameLevel((card:GetFrameLevel() or 1) + 4)
			entry.button:SetBackdrop(TILE_BACKDROP)
			entry.button:SetBackdropColor(0.06, 0.06, 0.08, 0.6)
			entry.button:SetBackdropBorderColor(1, 1, 1, 0.12)
			entry.swatch = entry.button:CreateTexture(nil, "ARTWORK")
			entry.swatch:SetSize(9, 9)
			entry.swatch:SetPoint("LEFT", 7, 0)
			entry.text = entry.button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
			entry.text:SetPoint("LEFT", entry.swatch, "RIGHT", 5, 0)
			entry.hover = entry.button:CreateTexture(nil, "HIGHLIGHT")
			entry.hover:SetAllPoints(entry.button)
			entry.hover:SetColorTexture(1, 1, 1, 0.09)
			entry.button:RegisterForClicks("LeftButtonUp")
			entry.button:SetScript("OnClick", function(self)
				local series = self.series
				if not series or series.noLine then
					-- Nothing is drawn for this character yet, so there is
					-- nothing to switch off.
					return
				end
				-- This switches the line off in the picture only. The tick is
				-- left alone, so the picker keeps showing this character as
				-- picked and the legend keeps its name - greyed, and the way
				-- back.
				charPickers.greyed = charPickers.greyed or {}
				local drawn = not charPickers.greyed[series.key]
				charPickers.greyed[series.key] = (not drawn) or nil
				ns.PlayUISound(drawn and "IG_MAINMENU_OPTION_CHECKBOX_OFF" or "IG_MAINMENU_OPTION_CHECKBOX_ON")
				RefreshTotalChart()
			end)
			entry.button:SetScript("OnEnter", function(self)
				local series = self.series
				if not series then
					return
				end
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine(string.format("%s - %s %s", series.name, series.level or 0, series.char.class or "?"), series.color[1], series.color[2], series.color[3])
				if series.noLine then
					GameTooltip:AddLine("Ticked, but Tally has no level-up for this character yet, so there is no line to draw. The tick is untouched.", 1, 1, 1, true)
				elseif series.hidden then
					GameTooltip:AddLine("Switched off in this graph. Click to draw the line again; its tick in the character list stays.", 1, 1, 1, true)
				else
					GameTooltip:AddLine("Click to switch this line off in the graph. It stays ticked in the character list.", 1, 1, 1, true)
				end
				GameTooltip:AddLine(ns.FormatDuration(series.tracked).." tracked by Tally.", 0.7, 0.7, 0.7, true)
				GameTooltip:Show()
			end)
			entry.button:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
			totalWidgets.legend[index] = entry
		end
		entry.button.series = line
		entry.text:SetText(line.noLine and (line.name.."  (none yet)") or line.name)
		if line.noLine then
			-- Dim and inert: there is no line to switch off, but the name
			-- stays so the legend matches the character list.
			entry.text:SetTextColor(0.42, 0.42, 0.42)
			entry.swatch:SetColorTexture(line.color[1], line.color[2], line.color[3], 0.13)
			entry.button:SetBackdropColor(0, 0, 0, 0.25)
			entry.button:SetBackdropBorderColor(1, 1, 1, 0.05)
		elseif line.hidden then
			entry.text:SetTextColor(0.5, 0.5, 0.5)
			entry.swatch:SetColorTexture(line.color[1], line.color[2], line.color[3], 0.22)
			entry.button:SetBackdropColor(0, 0, 0, 0.35)
			entry.button:SetBackdropBorderColor(1, 1, 1, 0.06)
		else
			-- The class colour doubles as the line's colour.
			entry.text:SetTextColor(line.color[1], line.color[2], line.color[3])
			entry.swatch:SetColorTexture(line.color[1], line.color[2], line.color[3], 1)
			entry.button:SetBackdropColor(0.06, 0.06, 0.08, 0.6)
			entry.button:SetBackdropBorderColor(1, 1, 1, 0.16)
		end
		entry.button:SetWidth(7 + 9 + 5 + entry.text:GetStringWidth() + 9)
		legendButtons[#legendButtons + 1] = entry.button
	end
	local _, legendPlaced = LayoutLegend(card, plot, legendButtons, 12, -48, 22, 100)
	for index = legendPlaced + 1, #totalWidgets.legend do
		totalWidgets.legend[index].button:Hide()
	end

	-- With every line switched off, this notice sits in the centre of the
	-- empty plot, clear of the legend buttons.
	if not totalWidgets.allOffNote then
		totalWidgets.allOffNote = plot:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		totalWidgets.allOffNote:SetPoint("CENTER", plot, "CENTER", 0, 6)
		totalWidgets.allOffNote:SetTextColor(0.62, 0.62, 0.62)
		totalWidgets.allOffNote:SetText("Every line is switched off  -  click a name under the title to draw one again.")
	end
	totalWidgets.allOffNote:SetShown(#series == 0)

	local height = plot:GetHeight() or 0
	local width = plot:GetWidth() or 0
	-- Plot geometry: axisW pixels on the left for value labels and floorY
	-- underneath for the level numbers.
	local axisW = 46
	local floorY = 16
	local drawW = math.max(10, width - axisW - 8)
	local drawH = math.max(24, height - floorY - 10)
	local levelsShown = last - first + 1

	-- Where each level sits along the x axis.
	local xs = {}
	for slot = first, last do
		if last == first then
			xs[slot] = axisW + drawW / 2
		else
			xs[slot] = axisW + ((slot - first) / (last - first)) * drawW
		end
	end

	-- One shared vertical scale for every line, taken from the largest value
	-- in the level window: a lower line is a faster character throughout.
	local windowMax = 0
	for slot = first, last do
		local level = levels[slot]
		for index = 1, #series do
			local point = series[index].byLevel[level]
			if point and point.seconds and point.seconds > windowMax then
				windowMax = point.seconds
			end
		end
	end
	local gridMax = math.max(1, windowMax)
	if card then
		local label = PageLabel()
		card.title:SetText(label)
		card.noteTitle = label
		totalWidgets.chartNotes = PageNotes(windowMax)
		card.noteText = totalWidgets.chartNotes
	end

	-- Gridlines and the value labels down the left edge, behind the lines.
	if not totalWidgets.grid then
		totalWidgets.grid = {}
		totalWidgets.gridLabels = {}
		totalWidgets.vgrid = {}
		totalWidgets.baseline = plot:CreateTexture(nil, "BACKGROUND")
		totalWidgets.baseline:SetColorTexture(1, 1, 1, 0.16)
		totalWidgets.baseline:SetHeight(1)
		for index = 1, 3 do
			local line = plot:CreateTexture(nil, "BACKGROUND")
			line:SetColorTexture(1, 1, 1, 0.08)
			line:SetHeight(1)
			totalWidgets.grid[index] = line
			local label = plot:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
			label:SetJustifyH("RIGHT")
			label:SetTextColor(0.5, 0.5, 0.5)
			totalWidgets.gridLabels[index] = label
		end
	end
	for index = 1, 3 do
		local fraction = (3 - index) / 2
		local y = floorY + drawH * fraction
		local line = totalWidgets.grid[index]
		line:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", axisW, y)
		line:SetWidth(drawW)
		local label = totalWidgets.gridLabels[index]
		label:SetPoint("RIGHT", plot, "BOTTOMLEFT", axisW - 8, y)
		if index == 1 then
			label:SetText(ns.FormatDuration(gridMax, true))
		elseif index == 3 then
			label:SetText("0")
		else
			label:SetText(ns.FormatDuration(math.floor(gridMax / 2), true))
		end
	end
	totalWidgets.baseline:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", axisW, floorY)
	totalWidgets.baseline:SetWidth(drawW)

	local stepW = (levelsShown > 1) and (drawW / (last - first)) or drawW
	for slot = first, last do
		local index = slot - first + 1
		local guide = totalWidgets.vgrid[index]
		if not guide then
			guide = plot:CreateTexture(nil, "BACKGROUND")
			guide:SetColorTexture(1, 1, 1, 0.045)
			guide:SetWidth(1)
			totalWidgets.vgrid[index] = guide
		end
		guide:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", xs[slot], floorY)
		guide:SetHeight(drawH)
		guide:Show()

		local label = totalWidgets.slotLabels[index]
		if not label then
			label = plot:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
			label:SetJustifyH("CENTER")
			label:SetTextColor(0.6, 0.6, 0.6)
			totalWidgets.slotLabels[index] = label
		end
		label:SetPoint("TOP", plot, "BOTTOMLEFT", xs[slot], -3)
		label:SetText(tostring(levels[slot]))
		-- A label every so many levels, so the numbers never collide however
		-- wide the chosen range is; the run is counted from the range's start.
		local labelEvery = math.max(1, math.ceil(28 / math.max(1, stepW)))
		-- The ends of the range are always named, whatever the interval lands
		-- on, so the highest level asked for is visible at the right edge.
		label:SetShown(slot == first or slot == last or stepW >= 24 or ((levels[slot] - levels[first]) % labelEvery) == 0)
	end
	for index = levelsShown + 1, #totalWidgets.vgrid do
		totalWidgets.vgrid[index]:Hide()
	end
	for index = levelsShown + 1, #totalWidgets.slotLabels do
		totalWidgets.slotLabels[index]:Hide()
	end

	-- Draws each series as one path. A missing point, or a step that skips a
	-- level, breaks the path.
	local canRotate = CanRotate(totalWidgets.plot, totalWidgets)
	local segmentIndex, markerIndex = 0, 0
	for index = 1, #series do
		local color = series[index].color
		local previousX, previousY, previousPartial, previousEstimated
		for slot = first, last do
			local level = levels[slot]
			local point = series[index].byLevel[level]
			if point and point.seconds then
				local x = xs[slot]
				local y = floorY + (point.seconds / gridMax) * drawH
				if previousX and levels[slot - 1] == level - 1 then
					local alpha = (point.partial or previousPartial) and 0.45 or 0.95
					-- An estimated point is a share of a stretch the client
					-- measured as one, not a measurement of its own: the line
					-- through it is drawn faint so it never passes for one.
					if point.estimated or previousEstimated then
						alpha = 0.3
					end
					segmentIndex = segmentIndex + 1
					local segment = ChartSegment(segmentIndex)
					segment:ClearAllPoints()
					if canRotate then
						local dx, dy = x - previousX, y - previousY
						segment:SetPoint("CENTER", plot, "BOTTOMLEFT", (previousX + x) / 2, (previousY + y) / 2)
						segment:SetSize(math.sqrt(dx * dx + dy * dy) + 1, 2)
						segment:SetColorTexture(color[1], color[2], color[3], alpha)
						segment:SetRotation(math.atan2(dy, dx))
					else
						-- No rotation here, so the connection is drawn as a
						-- horizontal and a vertical segment instead.
						segment:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", previousX, previousY)
						segment:SetSize(math.max(1, x - previousX), 1)
						segment:SetColorTexture(color[1], color[2], color[3], alpha)
						segmentIndex = segmentIndex + 1
						local vertical = ChartSegment(segmentIndex)
						vertical:ClearAllPoints()
						vertical:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x, math.min(previousY, y))
						vertical:SetSize(1, math.max(1, math.abs(y - previousY)))
						vertical:SetColorTexture(color[1], color[2], color[3], alpha)
					end
				end
				markerIndex = markerIndex + 1
				local marker = ChartMarker(markerIndex)
				marker:ClearAllPoints()
				marker:SetPoint("CENTER", plot, "BOTTOMLEFT", x, y)
				marker:SetSize(11, 11)
				-- A character with one measured level has a single point and no
				-- line; the dot is drawn larger so that state reads as a mark
				-- rather than as an empty graph.
				local lone = (#series[index].points == 1)
				local size = point.anchor and 4 or (point.estimated and 4 or (lone and 9 or (point.partial and 5 or 6)))
				marker.tex:SetSize(size, size)
				marker.tex:SetColorTexture(color[1], color[2], color[3],
					point.anchor and 0.7 or (point.estimated and 0.6 or (point.partial and 0.5 or 1)))
				if point.anchor then
					marker.info = {
						title = series[index].name.." - level 1",
						text = "The character began here; there is no time before level 1.",
						color = color,
					}
				else
					local note
					if point.estimated and point.head then
						note = "estimated - the lifetime total from level 1 to Tally's first reading, shared equally between the levels it covers"
					elseif point.estimated then
						note = "estimated - an equal share of a stretch the game measured as one"
						if point.partial then
							note = "estimated, and at least - the game did not say when the first level of the stretch started"
						end
					elseif point.partial then
						note = "at least - the game did not say when this level started"
					elseif point.sampled then
						note = "split by Tally's count of the seconds played on this level"
					end
					marker.info = {
						-- The title names the point that is hovered. It used to
						-- name the character's current level, which reads as the
						-- wrong number when the point is an earlier level.
						title = string.format("%s - level %d to %d", series[index].name, level - 1, level),
						text = ns.FormatDuration(point.seconds).." on level "..(level - 1)
							..(point.estimated and " (est.)" or "")
							.."  ·  now level "..(series[index].level or 0).." "..(series[index].char.class or "?"),
						color = color,
						note = note,
					}
				end
				previousX, previousY, previousPartial, previousEstimated = x, y, point.partial and true or false, point.estimated and true or false
			else
				-- A hole is a level the game measured as part of a longer
				-- stretch Tally cannot divide. It has no time, so no line can
				-- pass through it - but a small hollow mark at the floor says
				-- the level exists and the plot is not simply empty.
				if point and point.gap then
					markerIndex = markerIndex + 1
					local marker = ChartMarker(markerIndex)
					marker:ClearAllPoints()
					marker:SetPoint("CENTER", plot, "BOTTOMLEFT", xs[slot], floorY)
					marker:SetSize(11, 11)
					marker.tex:SetSize(5, 5)
					marker.tex:SetColorTexture(color[1], color[2], color[3], 0.3)
					marker.info = {
						title = string.format("%s - level %d", series[index].name, level),
						text = "No time recorded for this level.",
						color = color,
						note = "The game measured a longer stretch as one total and Tally cannot divide it, so nothing is invented here.",
					}
				end
				previousX, previousY, previousPartial, previousEstimated = nil, nil, nil, nil
			end
		end
	end
	for index = segmentIndex + 1, #totalWidgets.segments do
		totalWidgets.segments[index]:Hide()
	end
	for index = markerIndex + 1, #totalWidgets.markers do
		totalWidgets.markers[index]:Hide()
	end

	RefreshExactTimes(series, levels)

	-- The range controls are brought in line with what was drawn.
	if totalWidgets.syncRangeControls then
		totalWidgets.syncRangeControls()
	end
end

ns.RefreshTotalChart = RefreshTotalChart
