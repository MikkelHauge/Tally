-- Tally - the Total tab's economy graph: the daily balance of the character
-- selected in the viewer.
--
-- One line per ticked character: each day's end-of-day balance over the chosen
-- window. The corner shows the combined balance and daily average.
local addonName, ns = ...

local ACCENT, TILE_BACKDROP, ClassColorCode, CharColor, DisplayChar, CreateListCard, SetCornerLabel, CreateCornerButton, AddCardTitleNote, CanRotate, ColorMarkup, economyWidgets, MONTH_COLORS, GRAPH_DAYS_MAX, GRAPH_DAYS_DEFAULT =
	ns.ACCENT, ns.TILE_BACKDROP, ns.ClassColorCode, ns.CharColor, ns.DisplayChar, ns.CreateListCard, ns.SetCornerLabel, ns.CreateCornerButton, ns.AddCardTitleNote, ns.CanRotate, ns.ColorMarkup, ns.economyWidgets, ns.MONTH_COLORS, ns.GRAPH_DAYS_MAX, ns.GRAPH_DAYS_DEFAULT

-------------------------------------------------------------------------------
-- Daily balance graph (Total, ECONOMY GRAPH sub-view)
-------------------------------------------------------------------------------

-- The selected character's end-of-day balance over the window chosen by the
-- sliders under the graph: how many days to draw and how far back it ends.
-- Points come from ns.GoldTracks, which walks the daily ledger back from the
-- last known balance.

local function DailySegment(index)
	local segment = economyWidgets.segments[index]
	if not segment then
		segment = economyWidgets.plot:CreateTexture(nil, "ARTWORK")
		economyWidgets.segments[index] = segment
	end
	segment:Show()
	return segment
end

local function DailyMarker(index)
	local marker = economyWidgets.markers[index]
	if not marker then
		marker = CreateFrame("Frame", nil, economyWidgets.plot)
		marker.tex = marker:CreateTexture(nil, "OVERLAY")
		marker.tex:SetPoint("CENTER", 0, 0)
		marker:EnableMouse(true)
		marker:SetScript("OnEnter", function(self)
			-- Hovering any point on a day shows that day's balance: one row
			-- for the character, with name, class and gold, so the point and
			-- the exact number agree. The name takes the colour of its line
			-- and the class its class colour. The client's tooltip font is
			-- proportional, so the columns are padded in characters and line
			-- up only roughly.
			local rows = self.slot and economyWidgets.dayRows and economyWidgets.dayRows[self.slot]
			if not rows or #rows == 0 then
				local info = self.info
				if not info then
					return
				end
				GameTooltip:SetOwner(self, "ANCHOR_TOP")
				GameTooltip:AddLine(info.title, info.color[1], info.color[2], info.color[3])
				GameTooltip:AddLine(info.text, 1, 1, 1)
				if info.note then
					GameTooltip:AddLine(info.note, 0.7, 0.7, 0.7, true)
				end
				GameTooltip:Show()
				return
			end
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			GameTooltip:AddLine(ns.FormatDate(rows.stamp), ACCENT[1], ACCENT[2], ACCENT[3])
			local anyLive = false
			for index = 1, #rows do
				local row = rows[index]
				local name = string.format("%-12s", string.sub(row.name or "?", 1, 12))
				local class = string.format("%-11s", string.sub(row.class or "?", 1, 11))
				if row.live then
					anyLive = true
					name = "* "..string.sub(name, 3)
				end
				GameTooltip:AddLine(ColorMarkup(row.color)..name.."|r "
					..(ClassColorCode(row.classFile) or "")..class.."|r "
					..string.format("%12s", ns.FormatMoneyPlain(row.value)), 1, 1, 1)
			end
			if anyLive then
				GameTooltip:AddLine("* the character being played", 0.7, 0.7, 0.7)
			end
			GameTooltip:Show()
		end)
		marker:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		economyWidgets.markers[index] = marker
	end
	marker:Show()
	return marker
end

-- The axis has about 46 pixels. A full "1,234g 56s" never fits, so a tick is
-- shortened to gold only: 250, 1.2k, 12k, 1.2M. The card is about gold
-- balances, so the unit is understood from context.
local function GraphMoneyLabel(copper)
	local gold = (tonumber(copper) or 0) / 10000
	if gold >= 1000000 then
		return string.format("%.1fM", gold / 1000000)
	elseif gold >= 10000 then
		return string.format("%.0fk", gold / 1000)
	elseif gold >= 1000 then
		return string.format("%.1fk", gold / 1000)
	end
	return tostring(math.floor(gold + 0.5))
end

-- One line for every character ticked, for the combined view. Each day is
-- the sum of the balances those characters had at the end of it; a day no
-- selected character has a figure for stays a hole rather than becoming 0.
local function CombineTracks(tracks, dayCount)	local combined = {
		name = "All selected",
		combined = true,
		color = ACCENT,
		points = {},
		daySet = {},
		income = 0,
		live = false,
		seen = 0,
		char = {},
	}
	local hasBalance = false
	for index = 1, #tracks do
		local track = tracks[index]
		if track.balance ~= nil then
			combined.balance = (combined.balance or 0) + track.balance
			hasBalance = true
		end
		combined.income = combined.income + (track.income or 0)
		if track.live then
			combined.live = true
		end
		if (track.seen or 0) > combined.seen then
			combined.seen = track.seen
		end
		for day in pairs(track.daySet or {}) do
			combined.daySet[day] = true
		end
		-- The points arrays are sparse: a character has no point before the
		-- day Tally first watched it, so `#points` is not the window length.
		-- Walk the whole window explicitly or the sum stops at the first hole.
		for slot = 1, dayCount do
			local value = track.points and track.points[slot]
			if value then
				combined.points[slot] = (combined.points[slot] or 0) + value
			end
		end
	end
	if not hasBalance then
		combined.balance = nil
	end
	return combined
end

local function RefreshEconomyGraph()
	if not economyWidgets.plot then
		return
	end
	-- The graph now lives on another Total sub-view, so a tick in the picker
	-- can arrive while it is hidden. Drawing then would read a card with no
	-- laid-out size, so the redraw is deferred: clearing the signature makes
	-- the next show draw it from scratch.
	if not (economyWidgets.graphCard and economyWidgets.graphCard:IsShown()) then
		economyWidgets.graphSignature = nil
		return
	end
	local plot = economyWidgets.plot
	local card = economyWidgets.graphCard
	if not economyWidgets.segments then
		economyWidgets.segments = {}
		economyWidgets.markers = {}
	end
	-- Rebuilt whenever the drawing changes: the hover of any point on a day
	-- shows that day's table, so it must match the lines currently drawn.
	local graph = economyWidgets.graph

	local windowDays = economyWidgets.graphWindowDays or GRAPH_DAYS_DEFAULT
	local backDays = economyWidgets.graphBackDays or 0
	windowDays = math.max(1, math.min(GRAPH_DAYS_MAX, math.floor(windowDays + 0.5)))
	backDays = math.max(0, math.min(GRAPH_DAYS_MAX - windowDays + 1, math.floor(backDays + 0.5)))
	local data = ns.GoldTracks(windowDays, backDays)

	-- Every character ticked in the Total picker, the same selection the
	-- levelling graph and the combined figures use.
	local shown = {}
	for index = 1, #data.tracks do
		local candidate = data.tracks[index]
		if ns.TotalIncludes(candidate.key) then
			candidate.color = CharColor(candidate.char)
			shown[#shown + 1] = candidate
		end
	end
	local combinedMode = ns.db and ns.db.settings and ns.db.settings.graphCombined and true or false
	local drawn = shown
	if combinedMode and #shown > 1 then
		drawn = { CombineTracks(shown, #(data.days or {})) }
	end
	economyWidgets.graphShown = shown
	economyWidgets.graphSelected = shown[1]
	local function CardLabel()
		local days = #(data.days or {})
		local newest = days > 0 and data.days[days] or nil
		if not newest then
			return "Economy graph"
		end
		local span = days == 1 and " day" or " days"
		if backDays == 0 then
			return "Economy graph - last "..days..span
		end
		return "Economy graph - "..days..span.." ending "..ns.FormatDate(newest.stamp)
	end
	local function CardNotes()
		if combinedMode and #shown > 1 then
			return "One combined end-of-day balance for the "..#shown.." characters ticked in the Total picker, walked back from each last known balance."
		end
		if #shown > 0 then
			return "End-of-day balances for the characters ticked in the Total picker, walked back from each last known balance."
		end
		return "No ticked character has a drawable balance in this window."
	end
	if card then
		card.noteTitle = CardLabel()
		card.noteText = CardNotes()
	end

	-- The corner sums the drawn lines: their combined balance and their
	-- combined daily income over the days that have data.
	if economyWidgets.graphTotal then
		if #shown > 0 then
			local balance, income = 0, 0
			local daySet, dayCount = {}, 0
			for index = 1, #shown do
				local track = shown[index]
				balance = balance + (track.balance or 0)
				income = income + (track.income or 0)
				for day in pairs(track.daySet or {}) do
					if not daySet[day] then
						daySet[day] = true
						dayCount = dayCount + 1
					end
				end
			end
			local label
			if combinedMode and #shown > 1 then
				label = "All selected"
			elseif #shown == 1 then
				label = shown[1].name
			else
				label = #shown.." characters"
			end
			local text = label.."  "..ns.MoneyColored(balance)
			if dayCount > 0 then
				text = text.."   |cff8f8f8f·|r   "..ns.MoneyColored(math.floor(income / dayCount + 0.5))
					.."|cff8f8f8f a day over "..dayCount..(dayCount == 1 and " day|r" or " days|r")
			end
			economyWidgets.graphTotal:SetText(text)
		else
			economyWidgets.graphTotal:SetText("|cff8f8f8fNo ticked character has a balance|r")
		end
	end
	economyWidgets.graphTotalData = data
	if economyWidgets.graphCombinedButton then
		SetCornerLabel(economyWidgets.graphCombinedButton, combinedMode and "combined" or "separate")
	end

	if #drawn == 0 then
		plot:Hide()
		if graph.footer then
			graph.footer:SetText("")
		end
		if card then
			card.title:SetText(CardLabel())
			card.noteText = CardNotes()
			card.body:SetText("Nothing to draw for the ticked characters: no balance has been recorded yet, or the daily ledger has a hole in it. Tick another character in the Total picker, or log in with this one so Tally can read its balance.")
		end
		return
	end
	-- A signature of everything drawn; an unchanged signature returns early,
	-- so lines are rebuilt only when the data moves. The window's length and
	-- its day buckets are part of it: changing the days button changes what is
	-- on the axes without moving a single balance, and that has to redraw.
	local signature = #drawn * 1000003
	signature = signature + (combinedMode and 7654321 or 0)
	signature = signature + windowDays * 611953
	signature = signature + backDays * 1498307
	signature = signature + #(data.days or {}) * 15485863
	-- The window can shift by a day at midnight without changing its length.
	-- The first and last date keys are part of the signature so the labels
	-- move with it.
	local oldestDay = data.days and data.days[1]
	local newestDay = data.days and data.days[#data.days]
	if oldestDay then
		for position = 1, #oldestDay.key do
			signature = signature + string.byte(oldestDay.key, position) * (position + 3)
		end
	end
	if newestDay then
		for position = 1, #newestDay.key do
			signature = signature + string.byte(newestDay.key, position) * (position + 7)
		end
	end
	-- The selected characters themselves are part of it: swapping one for
	-- another with identical totals must still refresh the names and hover.
	for index = 1, #shown do
		local key = shown[index].key or shown[index].name or ""
		for position = 1, #key do
			signature = signature + string.byte(key, position) * position
		end
	end
	for index = 1, #drawn do
		local total = 0
		local points = drawn[index].points
		for position = 1, #(data.days or {}) do
			total = total + (points[position] or 0)
		end
		signature = signature + (total % 99991) * (index + 1)
	end
	-- The viewed character is part of the signature, so switching the viewer
	-- rebuilds the legend even when the numbers coincide.
	local report = DisplayChar()
	if report then
		local key = (report.name or "?").."-"..(report.realm or "?")
		for position = 1, #key do
			signature = signature + string.byte(key, position) * position
		end
	end
	if signature == economyWidgets.graphSignature then
		return
	end
	economyWidgets.graphSignature = signature
	economyWidgets.dayRows = {}

	-- The per-character toggles that used to sit under the title are gone: the
	-- plot takes the whole card and the body text is cleared.
	if card then
		card.body:SetText("")
	end
	plot:Show()

	local height = plot:GetHeight() or 0
	local width = plot:GetWidth() or 0
	-- Plot geometry: axisW pixels on the left for money labels and floorY
	-- underneath for the dates.
	local axisW = 46
	local floorY = 16
	local drawW = math.max(10, width - axisW - 8)
	local drawH = math.max(24, height - floorY - 10)
	local daysShown = #data.days

	local xs = {}
	for slot = 1, daysShown do
		if daysShown == 1 then
			xs[slot] = axisW + drawW / 2
		else
			xs[slot] = axisW + ((slot - 1) / (daysShown - 1)) * drawW
		end
	end

	-- One shared vertical scale for every line, from zero up to the largest
	-- drawn value: a higher point is more money throughout.
	local windowMax = 0
	for index = 1, #drawn do
		local points = drawn[index].points
		for position = 1, daysShown do
			local value = points[position]
			if value and value > windowMax then
				windowMax = value
			end
		end
	end
	local gridMax = math.max(1, windowMax)
	if card then
		card.title:SetText(CardLabel())
	end

	if not graph.grid then
		graph.grid = {}
		graph.gridLabels = {}
		graph.vgrid = {}
		graph.slotLabels = {}
		graph.labelHits = {}
		graph.dayHits = {}
		graph.baseline = plot:CreateTexture(nil, "BACKGROUND")
		graph.baseline:SetColorTexture(1, 1, 1, 0.16)
		graph.baseline:SetHeight(1)
		for index = 1, 3 do
			local line = plot:CreateTexture(nil, "BACKGROUND")
			line:SetColorTexture(1, 1, 1, 0.08)
			line:SetHeight(1)
			graph.grid[index] = line
			local label = plot:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
			label:SetJustifyH("RIGHT")
			label:SetTextColor(0.5, 0.5, 0.5)
			graph.gridLabels[index] = label
		end
	end
	for index = 1, 3 do
		local fraction = (3 - index) / 2
		local y = floorY + drawH * fraction
		local line = graph.grid[index]
		line:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", axisW, y)
		line:SetWidth(drawW)
		local label = graph.gridLabels[index]
		label:SetPoint("RIGHT", plot, "BOTTOMLEFT", axisW - 8, y)
		if index == 1 then
			label:SetText(GraphMoneyLabel(gridMax))
		elseif index == 3 then
			label:SetText("0")
		else
			label:SetText(GraphMoneyLabel(math.floor(gridMax / 2)))
		end
	end
	graph.baseline:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", axisW, floorY)
	graph.baseline:SetWidth(drawW)

	local stepW = (daysShown > 1) and (drawW / (daysShown - 1)) or drawW
	local previousMonth
	for slot = 1, daysShown do
		local key = data.days[slot].key
		local month = string.sub(key, 6, 7)
		local day = string.sub(key, 9, 10)
		-- Each month has a colour of its own, so a window that crosses a month
		-- boundary reads as two runs, and the day a month starts on carries its
		-- name as well as its number.
		local color = MONTH_COLORS[((tonumber(month) or 1) - 1) % #MONTH_COLORS + 1]
		local monthStart = (day == "01") or (slot == 1) or (previousMonth ~= month)
		previousMonth = month

		local guide = graph.vgrid[slot]
		if not guide then
			guide = plot:CreateTexture(nil, "BACKGROUND")
			guide:SetColorTexture(1, 1, 1, 0.045)
			guide:SetWidth(1)
			graph.vgrid[slot] = guide
		end
		guide:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", xs[slot], floorY)
		guide:SetHeight(drawH)
		-- A year of guides would read as a filled grid: on a dense window only
		-- the month boundaries carry one.
		guide:SetShown(stepW >= 8 or monthStart)

		local label = graph.slotLabels[slot]
		if not label then
			label = plot:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
			label:SetJustifyH("CENTER")
			graph.slotLabels[slot] = label
		end
		label:SetPoint("TOP", plot, "BOTTOMLEFT", xs[slot], -3)
		label:SetTextColor(color[1], color[2], color[3])
		if monthStart then
			label:SetText(day.." "..date("%b", data.days[slot].stamp))
		else
			label:SetText(day)
		end
		-- A year of dates would overlap; when points are closer than 20 pixels
		-- only the first day and each new month are named.
		label:SetShown(stepW >= 20 or monthStart)

		-- A hit area over the label, so hovering a date names it in full.
		local hit = graph.labelHits[slot]
		if not hit then
			hit = CreateFrame("Frame", nil, plot)
			hit:SetSize(34, 16)
			hit:EnableMouse(true)
			hit:SetScript("OnEnter", function(self)
				local info = self.info
				if not info then
					return
				end
				GameTooltip:SetOwner(self, "ANCHOR_TOP")
				GameTooltip:AddLine(info.text, info.color[1], info.color[2], info.color[3])
				GameTooltip:Show()
			end)
			hit:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
			graph.labelHits[slot] = hit
		end
		hit:ClearAllPoints()
		hit:SetPoint("TOP", plot, "BOTTOMLEFT", xs[slot], 2)
		-- The hit area follows the label spacing, so adjacent dates do not
		-- steal each other's hover.
		hit:SetSize(math.max(8, math.min(34, stepW - 1)), 16)
		hit.info = { text = ns.FormatDate(data.days[slot].stamp), color = color }
		hit:SetShown(label:IsShown())
	end
	for index = daysShown + 1, #graph.vgrid do
		graph.vgrid[index]:Hide()
	end
	for index = daysShown + 1, #graph.slotLabels do
		graph.slotLabels[index]:Hide()
	end
	for index = daysShown + 1, #graph.labelHits do
		graph.labelHits[index]:Hide()
	end

	-- One hover frame per day, showing the exact balance of every drawn line
	-- side by side. Point markers sit above these frames, so a marker answers
	-- for its own character.
	for slot = 1, daysShown do
		local hit = graph.dayHits[slot]
		if not hit then
			hit = CreateFrame("Frame", nil, plot)
			hit:EnableMouse(true)
			hit:SetScript("OnEnter", function(self)
				local info = self.info
				if not info then
					return
				end
				GameTooltip:SetOwner(self, "ANCHOR_TOP")
				GameTooltip:AddLine(info.title, ACCENT[1], ACCENT[2], ACCENT[3])
				if #info.tracks == 0 then
					GameTooltip:AddLine("Every line is switched off.", 0.7, 0.7, 0.7)
				end
				for index = 1, #info.tracks do
					local track = info.tracks[index]
					local value = track.points[info.slot]
					if value then
						GameTooltip:AddLine(track.name.."   "..ns.MoneyColored(value), track.color[1], track.color[2], track.color[3])
					else
						GameTooltip:AddLine(track.name.."   not watched yet", 0.55, 0.55, 0.55)
					end
				end
				local total, counted = 0, 0
				for index = 1, #info.tracks do
					local value = info.tracks[index].points[info.slot]
					if value then
						total = total + value
						counted = counted + 1
					end
				end
				if counted > 0 then
					GameTooltip:AddLine(" ")
					GameTooltip:AddLine("Total   "..ns.MoneyColored(total), 1, 1, 1)
				end
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine("Balance at the end of this day. Hover a point for the exact number.", 0.7, 0.7, 0.7, true)
				GameTooltip:AddLine("Daily balance per day is the sum of what was collected for that date.", 0.7, 0.7, 0.7, true)
				GameTooltip:AddLine("A character starts above 0 because it has earned gold before the day was over.", 0.7, 0.7, 0.7, true)
				GameTooltip:Show()
			end)
			hit:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
			graph.dayHits[slot] = hit
		end
		hit.info = { title = ns.FormatDate(data.days[slot].stamp), slot = slot, tracks = drawn }
		local left = xs[slot] - stepW / 2
		local right = xs[slot] + stepW / 2
		if left < 0 then left = 0 end
		if right > width then right = width end
		hit:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", left, 0)
		-- The days tile edge to edge. A minimum width would make a year's
		-- hits overlap, and the last one would answer for every day.
		hit:SetSize(math.max(1, right - left), height)
		hit:Show()
	end
	for index = daysShown + 1, #graph.dayHits do
		graph.dayHits[index]:Hide()
	end

	-- Draws each character as one path. A missing point breaks the path
	-- rather than joining across it.
	local canRotate = CanRotate(plot, economyWidgets)
	local segmentIndex, markerIndex = 0, 0
	for index = 1, #drawn do
		local track = drawn[index]
		local color = track.color
		local previousX, previousY
		for slot = 1, daysShown do
			local value = track.points[slot]
			if value then
				-- The first day this character has a point: the line begins
				-- here, at that day's end, because Tally has no figure for
				-- anything before the first day it watched.
				if not track.firstSlot then
					track.firstSlot = slot
				end
				local x = xs[slot]
				local y = floorY + (value / gridMax) * drawH
				if previousX then
					segmentIndex = segmentIndex + 1
					local segment = DailySegment(segmentIndex)
					segment:ClearAllPoints()
					if canRotate then
						local dx, dy = x - previousX, y - previousY
						segment:SetPoint("CENTER", plot, "BOTTOMLEFT", (previousX + x) / 2, (previousY + y) / 2)
						segment:SetSize(math.sqrt(dx * dx + dy * dy) + 1, 2)
						segment:SetColorTexture(color[1], color[2], color[3], 0.95)
						segment:SetRotation(math.atan2(dy, dx))
					else
						-- No rotation here, so the connection is drawn as a
						-- horizontal and a vertical segment instead.
						segment:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", previousX, previousY)
						segment:SetSize(math.max(1, x - previousX), 1)
						segment:SetColorTexture(color[1], color[2], color[3], 0.95)
						segmentIndex = segmentIndex + 1
						local vertical = DailySegment(segmentIndex)
						vertical:ClearAllPoints()
						vertical:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", x, math.min(previousY, y))
						vertical:SetSize(1, math.max(1, math.abs(y - previousY)))
						vertical:SetColorTexture(color[1], color[2], color[3], 0.95)
					end
				end
				markerIndex = markerIndex + 1
				local marker = DailyMarker(markerIndex)
				marker:ClearAllPoints()
				marker:SetPoint("CENTER", plot, "BOTTOMLEFT", x, y)
				marker:SetSize(11, 11)
				-- A year of 6-pixel dots would read as a thick line. Dense
				-- windows draw smaller dots and leave the mouse to the day
				-- columns underneath.
				local dot = math.max(2, math.min(6, stepW * 0.5))
				marker.tex:SetSize(dot, dot)
				marker.tex:SetColorTexture(color[1], color[2], color[3], 1)
				marker:EnableMouse(stepW >= 8)
				local title
				if track.combined then
					title = "All selected characters"
				else
					title = string.format("%s - %s %s", track.name, track.char.level or 0, track.char.class or "?")
				end
				local note = track.combined and "The sum of every ticked character's balance at the end of this day. " or ""
				if slot == track.firstSlot then
					note = note.."The first day Tally watched this character, so this point is that day's end: it holds whatever was already in the purse. "
				end
				if slot == daysShown and backDays == 0 then
					note = note..(track.live and "the balance Tally is watching now"
						or ("last known balance - Tally last saw this character "..ns.FormatDate(track.seen or 0)))
				else
					note = note.."The end-of-day balance for this date."
				end
				marker.info = {
					title = title,
					text = ns.FormatDate(data.days[slot].stamp).." - "..ns.MoneyColored(value),
					color = color,
					note = note,
				}
				-- The day's own table, for the hover: every ticked character
				-- with a value that day, in the order the lines are drawn.
				marker.slot = slot
				local rows = economyWidgets.dayRows[slot]
				if not rows then
					rows = { stamp = data.days[slot].stamp }
					economyWidgets.dayRows[slot] = rows
				end
				rows[#rows + 1] = {
					name = track.name, class = track.char.class, classFile = track.char.classFile,
					color = color, value = value, live = track.live,
				}
				previousX, previousY = x, y
			else
				previousX, previousY = nil, nil
			end
		end
	end
	for index = segmentIndex + 1, #economyWidgets.segments do
		economyWidgets.segments[index]:Hide()
	end
	for index = markerIndex + 1, #economyWidgets.markers do
		economyWidgets.markers[index]:Hide()
	end

	if not graph.footer then
		graph.footer = plot:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		graph.footer:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, -32)
		-- Anchored on both bottom corners, so the caption wraps to the plot's
		-- width.
		graph.footer:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, -32)
		graph.footer:SetJustifyH("LEFT")
		graph.footer:SetTextColor(0.62, 0.62, 0.62)
	end
	local viewer = DisplayChar()
	local pileText
	if combinedMode and #shown > 1 then
		pileText = "All selected characters"
	else
		pileText = viewer and (viewer.name or "this character") or "this character"
	end
	local footerNote = combinedMode and #shown > 1
		and "points are the sum of their end-of-day balances, walked back from each last known balance\nhover a day for the exact total, or a point for the line's number"
		or "points are end-of-day balances, walked back from the last known one\nhover a day for the exact balance, or a point for this character's number"
	graph.footer:SetText(pileText.."  ·  "..footerNote)
end

local function BuildEconomyGraph(daily)
	local card = CreateListCard(daily, 0, -4, 730, 398, "Economy graph")
	AddCardTitleNote(card, "Economy graph",
		"End-of-day balances for the characters ticked in the Total picker, walked back from each last known balance. Drag the sliders under the graph to choose the window, up to 365 days. Hover a day for the exact balances, or a point for one character's number.")
	local plot = CreateFrame("Frame", nil, card)
	plot:SetPoint("TOPLEFT", card, "TOPLEFT", 14, -48)
	plot:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -14, 52)
	economyWidgets.graphCard = card
	economyWidgets.plot = plot

	-- The title row's right edge shows the pile total: the combined balance
	-- of every character on this realm and faction, drawn or not.
	economyWidgets.graphTotal = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	economyWidgets.graphTotal:SetPoint("TOPRIGHT", card, "TOPRIGHT", -12, -8)
	economyWidgets.graphTotal:SetJustifyH("RIGHT")

	local totalHit = CreateFrame("Frame", nil, card)
	totalHit:EnableMouse(true)
	totalHit:SetPoint("TOPLEFT", economyWidgets.graphTotal, "TOPLEFT", -8, 4)
	totalHit:SetPoint("BOTTOMRIGHT", economyWidgets.graphTotal, "BOTTOMRIGHT", 4, -4)
	totalHit:SetScript("OnEnter", function(self)
		local shown = economyWidgets.graphShown or {}
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		GameTooltip:AddLine("Economy graph", ACCENT[1], ACCENT[2], ACCENT[3])
		if #shown == 0 then
			GameTooltip:AddLine("No balance has been recorded for the ticked characters yet.", 1, 1, 1)
		else
			local total, hasBalance = 0, false
			for index = 1, #shown do
				local track = shown[index]
				local color = track.color or CharColor(track.char)
				GameTooltip:AddLine(track.name, color[1], color[2], color[3])
				if track.balance == nil then
					GameTooltip:AddLine("No balance recorded yet.", 0.7, 0.7, 0.7, true)
				elseif track.gap then
					GameTooltip:AddLine(ns.MoneyColored(track.balance).."|cff9f9f9f - line not drawn (ledger gap)|r", 1, 1, 1)
					total = total + track.balance
					hasBalance = true
				else
					GameTooltip:AddLine(ns.MoneyColored(track.balance), 1, 1, 1)
					total = total + track.balance
					hasBalance = true
				end
			end
			if hasBalance then
				GameTooltip:AddLine(" ")
				GameTooltip:AddLine("Total   "..ns.MoneyColored(total), 1, 1, 1)
			end
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("The graph follows the characters ticked in the Total picker.", 0.7, 0.7, 0.7, true)
		GameTooltip:AddLine("Hover a day for the exact balances, or a point for one character's number.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	totalHit:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	economyWidgets.totalHit = totalHit

	-- The window controls, in a strip under the graph: how many days to draw,
	-- and how far back the window ends, both in days and with a box beside the
	-- slider. A month is the default; a year is the longest the ledger keeps.
	economyWidgets.graphWindowDays = economyWidgets.graphWindowDays or GRAPH_DAYS_DEFAULT
	economyWidgets.graphBackDays = economyWidgets.graphBackDays or 0
	local strip = CreateFrame("Frame", nil, daily, "BackdropTemplate")
	strip:SetBackdrop(TILE_BACKDROP)
	strip:SetBackdropColor(0, 0, 0, 0.35)
	strip:SetBackdropBorderColor(1, 0.72, 0.25, 0.12)
	strip:SetPoint("TOPLEFT", daily, "TOPLEFT", 0, -406)
	strip:SetSize(730, 26)
	economyWidgets.graphStrip = strip

	-- The two values are tied: together they cannot reach further back than
	-- the year the ledger keeps. Clamping here means the sliders, the boxes and
	-- the drawn window always agree.
	local function ClampGraphRange()
		local window = math.floor((economyWidgets.graphWindowDays or GRAPH_DAYS_DEFAULT) + 0.5)
		local back = math.floor((economyWidgets.graphBackDays or 0) + 0.5)
		window = math.max(1, math.min(GRAPH_DAYS_MAX, window))
		back = math.max(0, math.min(GRAPH_DAYS_MAX - window + 1, back))
		economyWidgets.graphWindowDays = window
		economyWidgets.graphBackDays = back
		return window, back
	end

	local function SyncGraphRange()
		economyWidgets.graphRangeSyncing = true
		local window, back = ClampGraphRange()
		if economyWidgets.graphWindowSlider then
			economyWidgets.graphWindowSlider:SetValue(window)
			economyWidgets.graphWindowBox:SetText(tostring(window))
			economyWidgets.graphBackSlider:SetValue(back)
			economyWidgets.graphBackBox:SetText(tostring(back))
		end
		economyWidgets.graphRangeSyncing = false
	end

	local function ApplyGraphRange()
		economyWidgets.graphSignature = nil
		SyncGraphRange()
		ns.RefreshEconomyGraph()
	end

	local function AddRangeControl(label, x, which)
		local text = strip:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		text:SetPoint("LEFT", x, 0)
		text:SetText(label)
		text:SetTextColor(0.62, 0.62, 0.62)
		local slider = CreateFrame("Slider", nil, strip, "OptionsSliderTemplate")
		slider:SetPoint("LEFT", text, "RIGHT", 6, 0)
		slider:SetWidth(150)
		slider:SetHeight(16)
		if which == "window" then
			slider:SetMinMaxValues(1, GRAPH_DAYS_MAX)
		else
			slider:SetMinMaxValues(0, GRAPH_DAYS_MAX)
		end
		slider:SetValueStep(1)
		if slider.SetObeyStepOnDrag then
			slider:SetObeyStepOnDrag(true)
		end
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
		box:SetSize(38, 18)
		box:SetPoint("LEFT", slider, "RIGHT", 8, 0)
		box:SetAutoFocus(false)
		box:SetMaxLetters(3)
		box:SetJustifyH("CENTER")

		local function Apply(value)
			value = math.floor((tonumber(value) or 0) + 0.5)
			if which == "window" then
				economyWidgets.graphWindowDays = math.max(1, math.min(GRAPH_DAYS_MAX, value))
			else
				economyWidgets.graphBackDays = math.max(0, value)
			end
			local window, back = ClampGraphRange()
			ns.Trace("daily graph: "..window.." days, ending "..back.." days ago")
			ApplyGraphRange()
		end

		slider:SetScript("OnValueChanged", function(_, value)
			if economyWidgets.graphRangeSyncing then
				return
			end
			Apply(value)
		end)
		box:SetScript("OnEnterPressed", function(self)
			local value = tonumber(self:GetText()) or 0
			self:ClearFocus()
			Apply(value)
		end)
		box:SetScript("OnEscapePressed", function(self)
			self:ClearFocus()
			SyncGraphRange()
		end)
		slider:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_TOP")
			if which == "window" then
				GameTooltip:AddLine("Days drawn", ACCENT[1], ACCENT[2], ACCENT[3])
				GameTooltip:AddLine("How many days the graph draws, up to 365. The daily ledger keeps a year, so the whole window is stored balances rather than a guess.", 1, 1, 1, true)
			else
				GameTooltip:AddLine("Where the window ends", ACCENT[1], ACCENT[2], ACCENT[3])
				GameTooltip:AddLine("How many days before today the window ends. 0 ends it today; slide it back to look at an older stretch. The two sliders together stay within a year.", 1, 1, 1, true)
			end
			GameTooltip:Show()
		end)
		slider:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		if which == "window" then
			economyWidgets.graphWindowSlider, economyWidgets.graphWindowBox = slider, box
		else
			economyWidgets.graphBackSlider, economyWidgets.graphBackBox = slider, box
		end
	end

	AddRangeControl("days", 12, "window")
	AddRangeControl("back", 260, "back")

	local monthButton = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
	monthButton:SetSize(104, 18)
	monthButton:SetPoint("LEFT", 500, 0)
	monthButton:SetText("recent month")
	monthButton:SetScript("OnClick", function()
		economyWidgets.graphWindowDays = GRAPH_DAYS_DEFAULT
		economyWidgets.graphBackDays = 0
		ns.Trace("daily graph: recent month")
		ApplyGraphRange()
	end)
	economyWidgets.graphMonthButton = monthButton

	local yearButton = CreateFrame("Button", nil, strip, "UIPanelButtonTemplate")
	yearButton:SetSize(104, 18)
	yearButton:SetPoint("LEFT", monthButton, "RIGHT", 8, 0)
	yearButton:SetText("365 days")
	yearButton:SetScript("OnClick", function()
		economyWidgets.graphWindowDays = GRAPH_DAYS_MAX
		economyWidgets.graphBackDays = 0
		ns.Trace("daily graph: 365 days")
		ApplyGraphRange()
	end)
	economyWidgets.graphYearButton = yearButton

	SyncGraphRange()

	-- The characters button opens the same Total picker every other Total
	-- view uses; its ticks drive this graph too.
	local charsButton = CreateCornerButton(card, -12, -26)
	SetCornerLabel(charsButton, "characters")
	charsButton:SetScript("OnClick", function()
		ns.ShowCharPicker("levels", not (ns.charPickers.levels and ns.charPickers.levels.shown))
	end)
	charsButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Characters", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Tick the characters to draw. The same ticks drive the combined figures, the levelling graph and this one.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	charsButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	-- One line for all ticked characters, or one line each. The label names
	-- the view currently drawn; the click flips it.
	local combinedButton = CreateCornerButton(card, -12, -26)
	combinedButton:ClearAllPoints()
	combinedButton:SetPoint("RIGHT", charsButton, "LEFT", -6, 0)
	local function CombinedLabel()
		local on = ns.db and ns.db.settings and ns.db.settings.graphCombined
		return on and "combined" or "separate"
	end
	SetCornerLabel(combinedButton, CombinedLabel())
	combinedButton:SetScript("OnClick", function()
		local settings = ns.db and ns.db.settings
		if not settings then
			return
		end
		settings.graphCombined = not settings.graphCombined
		SetCornerLabel(combinedButton, CombinedLabel())
		economyWidgets.graphSignature = nil
		ns.Trace("daily graph: "..(settings.graphCombined and "combined" or "separate").." view")
		ns.RefreshEconomyGraph()
	end)
	combinedButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Graph view", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("combined draws one line: the sum of every ticked character's end-of-day balance. separate draws one line per character. Hover a day for the exact figures either way.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	combinedButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	economyWidgets.graphCombinedButton = combinedButton
end

ns.BuildEconomyGraph, ns.RefreshEconomyGraph = BuildEconomyGraph, RefreshEconomyGraph
