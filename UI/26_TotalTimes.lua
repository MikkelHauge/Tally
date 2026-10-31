-- Tally - the Total tab's exact-times table: the same level figures the
-- chart draws, one row per level.
local addonName, ns = ...

local ColorMarkup, FillScrollingLines, ShowCardText, totalWidgets =
	ns.ColorMarkup, ns.FillScrollingLines, ns.ShowCardText, ns.totalWidgets

local EXACT_TIMES_NAMES = 4   -- names listed per row in the exact-times table
local EXACT_TIMES_LEVEL_WIDTH = 12  -- width of the table's level column

local function RefreshExactTimes(series, levels)
	-- The exact numbers as text, highest level first. Within a level the
	-- characters run fastest first, so the row itself shows who was quickest,
	-- and only the first few names fit: the rest are counted and listed in the
	-- hover. A figure that is not a full measurement - a level whose start
	-- Tally did not watch, or a level-up that happened while Tally was not
	-- running - carries an amber (!), and every row explains itself on hover.
	-- Every level the chart covers, newest first: the table is a scrolling
	-- window, so it no longer stops where the chart's page does.
	local lines = {}
	-- A character first read above level 1 has no level-1 anchor. Show the
	-- starting level as its own row, with no invented time for the levels it
	-- never played under Tally's eyes (or never played at all, for a special
	-- character that begins higher).
	for index = 1, #series do
		local entry = series[index]
		local start = entry.char and entry.char.firstLevel or 1
		if start > 1 then
			local colour = entry.color or { 0.8, 0.8, 0.8 }
			lines[#lines + 1] = {
				left = "Starting level · "..ColorMarkup(colour)..ns.FullName(entry.char).."|r · "..start,
				tip = {
					kind = "note",
					title = "Starting level "..start,
					lines = {
						{ text = "Tally first read "..ns.FullName(entry.char).." at level "..start..".", color = colour },
						{ text = "No time is claimed for levels below it: the character may have started there, or may have played them before Tally was installed.", color = { 0.7, 0.7, 0.7 } },
					},
				},
			}
		end
	end
	for slot = #levels, 1, -1 do
		local level = levels[slot]
		local measured, gaps = {}, {}
		for index = 1, #series do
			local point = series[index].byLevel[level]
			if point then
				if point.anchor then
					-- The level-1 anchor is the start of the line, not a
					-- measurement: it has no row of its own.
				elseif point.seconds then
					measured[#measured + 1] = {
						name = ns.FullName(series[index].char), color = series[index].color,
						seconds = point.seconds, partial = point.partial and true or false,
						sampled = point.sampled and true or false,
						estimated = point.estimated and true or false,
						head = point.head and true or false,
					}
				else
					gaps[#gaps + 1] = { name = ns.FullName(series[index].char), color = series[index].color }
				end
			end
		end
		table.sort(measured, function(a, b)
			if a.seconds == b.seconds then
				return a.name < b.name
			end
			return a.seconds < b.seconds
		end)
		if #measured + #gaps > 0 then
			local measuredParts, gapParts, tipLines, special = {}, {}, {}, false
			for index = 1, #measured do
				local entry = measured[index]
				local text = ColorMarkup(entry.color)..entry.name.."|r "..ns.FormatDuration(entry.seconds, true)
				local detail = entry.name.." - "..ns.FormatDuration(entry.seconds, true)
				if entry.estimated then
					text = text.." (est.)"
					if entry.head then
						detail = detail.." (estimated - the lifetime total from level 1 to Tally's first reading, shared equally)"
					else
						detail = detail.." (estimated - an equal share of a stretch the game measured as one)"
					end
				end
				if entry.partial then
					special = true
					text = text.." (!)"
					detail = detail.." (!)"
				elseif entry.sampled then
					detail = detail.." (split by Tally's count)"
				end
				measuredParts[#measuredParts + 1] = text
				tipLines[#tipLines + 1] = { text = detail, color = entry.color }
			end
			for index = 1, #gaps do
				local entry = gaps[index]
				special = true
				gapParts[#gapParts + 1] = ColorMarkup(entry.color)..entry.name.."|r (gap) (!)"
				tipLines[#tipLines + 1] = {
					text = entry.name.." - no time: the game gave no reading for this level, and Tally has no count of its own",
					color = entry.color,
				}
			end
			local allParts = {}
			for index = 1, #measuredParts do
				allParts[#allParts + 1] = measuredParts[index]
			end
			for index = 1, #gapParts do
				allParts[#allParts + 1] = gapParts[index]
			end
			local shownParts = math.min(#allParts, EXACT_TIMES_NAMES)
			local names = table.concat(allParts, "  ·  ", 1, shownParts)
			if #allParts > shownParts then
				-- The marker stays visible even when the figure it belongs to
				-- did not fit on the row.
				names = names.."  |cff9f9f9f+"..(#allParts - shownParts).." more|r"..(special and "  |cffffd100(!)|r" or "")
			end
			-- The level column is padded so every row's names start in the same
			-- place, a few spaces in from the level, rather than being flung to
			-- the right-hand edge.
			local levelText = (level - 1).." to "..level
			if #levelText < EXACT_TIMES_LEVEL_WIDTH then
				levelText = levelText..string.rep(" ", EXACT_TIMES_LEVEL_WIDTH - #levelText)
			end
			-- One grey line explaining the marker, then one line per
			-- character: full name, and the time that character took.
			if special then
				table.insert(tipLines, 1, {
					text = "Levels marked with (!) are lower bounds: the game did not say when the level started, or Tally's own count fell short of the stretch the game measured.",
					color = { 0.7, 0.7, 0.7 },
				})
			end
			lines[#lines + 1] = {
				left = levelText..names,
				tip = {
					kind = "note",
					title = "Level "..(level - 1).." to "..level,
					lines = tipLines,
				},
			}
		end
	end
	if FillScrollingLines(totalWidgets.table, lines, totalWidgets, "exactScrollOffset", "Exact times", 12) == 0 then
		ShowCardText(totalWidgets.table, "No levelling data to show for these characters yet.")
	end
end

ns.RefreshExactTimes = RefreshExactTimes
