-- Tally - the character picker.
--
-- One window shared by every view that offers it. It reads and writes
-- the addon's one selection (ns.TotalIncludes), so a tick anywhere means
-- the same thing everywhere.
local addonName, ns = ...

-- Helpers and constants from the files loaded above (see Tally.toc).
local ACCENT, TILE_BACKDROP, GREEN, RED, ClassColorCode, CharColor, AddPageNote =
	ns.ACCENT, ns.TILE_BACKDROP, ns.GREEN, ns.RED, ns.ClassColorCode, ns.CharColor, ns.AddPageNote
-- Forward declarations: the picker's own helpers live inside a do-block
-- below, which hands its names back at the end. What has to stay outside is
-- what other files call, and those are handed over through ns in the footer.
local RefreshCharPicker
local BuildCharPicker
local ShowCharPicker
local DailyColors
-- The characters picker, one window shared by every view that offers it. It
-- reads and writes the addon's one selection (ns.TotalIncludes), so a tick
-- anywhere means the same thing everywhere.
local charPickers = {}

-- Colours for the daily graph's lines, and the picker that picks them, in one
-- do-block so the picker's own helpers stay private; the four names declared
-- above are the only way in, and they are handed to the other files through ns
-- at the foot of this file.

-- Colours for the daily graph's lines. A class colour identifies the class, so
-- it is used for the first character of that class only: a second one of the
-- same class would be a line of exactly the same colour, which is no use, so it
-- takes one from the palette below. The pick is derived from the character's
-- key, so a line keeps its colour between redraws and across sessions.
do
	-- The characters picker. It replaces the row of per-character toggles that
	-- used to sit under the graph's title: one window listing every character
	-- Tally has read on this realm, both factions under their own heading, each
	-- with the colour its line is drawn in. Rows are ticked rather than names
	-- clicked.
	local DAILY_PANEL_ROWS = 13

	local DUPLICATE_COLORS = {
		{ 0.95, 0.45, 0.15 },  -- orange
		{ 0.35, 0.85, 0.95 },  -- sky
		{ 0.95, 0.35, 0.60 },  -- pink
		{ 0.70, 0.90, 0.35 },  -- lime
		{ 0.60, 0.55, 0.95 },  -- violet
		{ 0.95, 0.85, 0.35 },  -- yellow
		{ 0.40, 0.75, 0.55 },  -- sea green
		{ 0.90, 0.60, 0.90 },  -- orchid
		{ 0.80, 0.80, 0.80 },  -- grey
		{ 0.35, 0.60, 0.95 },  -- blue
	}

	local function KeyHash(key)
		local hash = 7
		key = tostring(key or "?")
		for index = 1, #key do
			hash = (hash * 31 + string.byte(key, index)) % 100003
		end
		return hash
	end

	-- One colour per character, keyed by character key. `list` must be the same
	-- list both times it is used (the graph and the picker), so the two agree.
	DailyColors = function(list)
		local colors, classUsed = {}, {}
		for index = 1, #list do
			local member = list[index]
			local char = member.char or {}
			local classFile = char.classFile or "?"
			local color
			if not classUsed[classFile] then
				classUsed[classFile] = true
				color = CharColor(char)
			else
				local palette = DUPLICATE_COLORS
				local start = (KeyHash(member.key) % #palette) + 1
				for step = 0, #palette - 1 do
					local candidate = palette[((start + step - 1) % #palette) + 1]
					local taken = false
					for _, used in pairs(colors) do
						if used == candidate then
							taken = true
							break
						end
					end
					if not taken then
						color = candidate
						break
					end
				end
				color = color or palette[start]
			end
			colors[member.key] = color
		end
		return colors
	end

	-- The orders the picker can list characters in.
	local DAILY_SORTS = { "name", "nameDesc", "class", "classDesc" }

	local function NextDailySort(mode)
		for index = 1, #DAILY_SORTS do
			if DAILY_SORTS[index] == mode then
				return DAILY_SORTS[index % #DAILY_SORTS + 1]
			end
		end
		return DAILY_SORTS[1]
	end

	local function DailySortLabel(mode)
		if mode == "nameDesc" then
			return "name Z-A"
		end
		if mode == "class" then
			return "class A-Z"
		end
		if mode == "classDesc" then
			return "class Z-A"
		end
		return "name A-Z"
	end

	-- One selection for the whole addon, so a tick here means the same thing in
	-- the Total tab, the daily graph and the level-times chart.
	local function PickerShown(key)
		return ns.TotalIncludes(key)
	end

	local function PickerSet(key, wanted)
		ns.SetTotalIncluded(key, wanted)
	end

	-- The window's rows: everyone Tally has read, with what is known about them
	-- whichever view opened the window. One builder, because there is one
	-- selection and one set of rows.
	local function PickerRows()
		local known = ns.KnownCharacters()
		local colors = DailyColors(known)
		local rows = {}
		for index = 1, #known do
			local entry = known[index]
			local char = entry.char or {}
			local info = (char.level or 0).." "..(ClassColorCode(char.classFile) or "")..(char.class or "?").."|r"
			local tips = {}
			if entry.live then
				info = info.."  ·  playing"
			end
			local balance = char.gold and char.gold.balance
			if balance then
				tips[#tips + 1] = { text = ns.MoneyColored(balance)..(entry.live and " - playing now" or (" - last known, seen "..ns.FormatDate(entry.seen or 0))), color = { 1, 1, 1 } }
			else
				tips[#tips + 1] = { text = "No balance recorded yet.", color = { 0.7, 0.7, 0.7 } }
			end
			tips[#tips + 1] = { text = ns.FormatDuration(char.tracked or 0).." watched by Tally, "..(char.quests or 0).." quests.", color = { 0.7, 0.7, 0.7 } }
			rows[#rows + 1] = {
				key = entry.key, char = char, faction = ns.CharFaction(char),
				name = ns.FullName(char), color = colors[entry.key] or CharColor(char),
				info = info, tips = tips,
			}
		end
		return rows
	end

	-- The window: one of them, whichever view opens it, and the same rows in
	-- every case because there is one selection underneath.
	local PICKER_TITLE = "Characters"
	local PICKER_NOTE = "Tick the characters to use. The same ticks apply everywhere: the combined figures, the economy graph and the level-times chart. Horde is on the left, Alliance on the right. Left-click a row to tick or untick it; the balance under the cursor is in the row's own tooltip."

	-- Both views ask for the same window; the entries differ only in nothing at
	-- all now, since a tick means the same thing everywhere. The table stays so
	-- the call sites read the same way.
	PICKER_INFO = {
		daily = {
			title = PICKER_TITLE,
			note = PICKER_NOTE,
			rows = PickerRows,
			trace = "characters",
			onChange = function()
				ns.RefreshEconomyGraph()
				ns.RefreshTotalChart()
				ns.RefreshCombinedNow()
				ns.RefreshAuctionPages()
				if ns.professionsUI and ns.professionsUI.RefreshViews then
					ns.professionsUI.RefreshViews()
				end
			end,
		},
		levels = {
			title = PICKER_TITLE,
			note = PICKER_NOTE,
			rows = PickerRows,
			trace = "characters",
			onChange = function()
				ns.RefreshEconomyGraph()
				ns.RefreshTotalChart()
				ns.RefreshCombinedNow()
				ns.RefreshAuctionPages()
				if ns.professionsUI and ns.professionsUI.RefreshViews then
					ns.professionsUI.RefreshViews()
				end
			end,
		},
	}

	-- The characters picker. It replaced the row of per-character toggles that
	-- used to sit under the daily graph's title: one window listing every
	-- character, both factions under their own heading, each with the colour its
	-- line is drawn in. Rows are ticked rather than names clicked.
	BuildCharPicker = function(page, kind)
		-- One window, whatever opens it: the second call for the other view
		-- reuses the first, so there is a single picker with a single state.
		-- Both callers pass the frame every page sits in, so it covers any tab.
		if charPickers.panel then
			charPickers[kind] = charPickers.panel
			return
		end
		local pickerInfo = PICKER_INFO[kind]
		local panel = CreateFrame("Frame", nil, page, "BackdropTemplate")
		panel:SetAllPoints(page)
		panel:EnableMouse(true)
		-- Above everything on the page: the cards' own corner buttons are
		-- raised above their cards (frame level + 4), and they used to show
		-- through this window.
		panel:SetFrameLevel(page:GetFrameLevel() + 14)
		panel:SetBackdrop(TILE_BACKDROP)
		-- Fully opaque, and solidly so: the shared tile backdrop is the game's
		-- tooltip texture and reads as translucent however its colour is set,
		-- so a plain black texture is laid behind it. The page behind this
		-- window must not show through at all.
		panel.solid = panel:CreateTexture(nil, "BACKGROUND", nil, -1)
		panel.solid:SetAllPoints(panel)
		panel.solid:SetColorTexture(0.03, 0.03, 0.04, 1)
		panel:SetBackdropColor(0.03, 0.03, 0.04, 1)
		panel:SetBackdropBorderColor(ACCENT[1], ACCENT[2], ACCENT[3], 0.35)
		panel.title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
		panel.title:SetPoint("TOPLEFT", 14, -12)
		panel.title:SetText(PICKER_TITLE)
		panel.title:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
		panel.count = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		panel.count:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -14, -14)
		panel.count:SetTextColor(0.7, 0.7, 0.7)
		panel.note = AddPageNote(panel, 14, -32, 700, pickerInfo.note)
		panel.note:SetWidth(700)
		-- Brighter than the settings page's notes: this one sits on a near
		-- black window and is the first thing read here.
		panel.note:SetTextColor(0.84, 0.84, 0.84)
		local picker = { kind = kind, panel = panel, rows = {}, sort = "name", shown = false }
		-- Both keys point at the one window.
		charPickers.panel = picker
		charPickers[kind] = picker

		panel.rows = {}
		for index = 1, DAILY_PANEL_ROWS * 2 do
			local column = math.floor((index - 1) / DAILY_PANEL_ROWS)
			local slot = (index - 1) % DAILY_PANEL_ROWS
			local row = CreateFrame("Button", nil, panel)
			row:SetHeight(20)
			row:SetWidth(340)
			row:SetPoint("TOPLEFT", panel, "TOPLEFT", 14 + column * 356, -76 - slot * 22)
			row.border = row:CreateTexture(nil, "BORDER")
			row.border:SetSize(16, 16)
			row.border:SetPoint("LEFT", 0, 0)
			row.border:SetColorTexture(1, 1, 1, 0.18)
			row.box = row:CreateTexture(nil, "ARTWORK")
			row.box:SetSize(14, 14)
			row.box:SetPoint("CENTER", row.border, "CENTER", 0, 0)
			row.box:SetColorTexture(0, 0, 0, 0.6)
			row.tick = row:CreateTexture(nil, "OVERLAY")
			row.tick:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
			row.tick:SetSize(15, 15)
			row.tick:SetPoint("CENTER", row.box, "CENTER", 0, 0)
			row.tick:SetTexCoord(0.08, 0.92, 0.08, 0.92)
			row.tick:SetVertexColor(ACCENT[1], ACCENT[2], ACCENT[3])
			row.swatch = row:CreateTexture(nil, "ARTWORK")
			row.swatch:SetSize(9, 9)
			row.swatch:SetPoint("LEFT", row.border, "RIGHT", 6, 0)
			row.name = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.name:SetPoint("LEFT", row.swatch, "RIGHT", 6, 0)
			row.info = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
			row.info:SetPoint("RIGHT", -2, 0)
			row.info:SetJustifyH("RIGHT")
			row.info:SetTextColor(0.72, 0.72, 0.72)
			row.head = row:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
			row.head:SetPoint("LEFT", 0, 0)
			row.head:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
			row.head:Hide()
			row.hover = row:CreateTexture(nil, "HIGHLIGHT")
			row.hover:SetAllPoints(row)
			row.hover:SetColorTexture(1, 1, 1, 0.06)
			row:RegisterForClicks("LeftButtonUp")
			row:SetScript("OnClick", function(self)
				if not self.key then
					return
				end
				local shown = PickerShown(self.key)
				PickerSet(self.key, not shown)
				-- The picker is the selection itself: a change here ends any
				-- greyed names the chart was holding open.
				charPickers.greyed = nil
				ns.PlayUISound(shown and "IG_MAINMENU_OPTION_CHECKBOX_OFF" or "IG_MAINMENU_OPTION_CHECKBOX_ON")
				RefreshCharPicker(kind)
				pickerInfo.onChange()
			end)
			row:SetScript("OnEnter", function(self)
				local entry = self.tooltipRow
				if not entry then
					return
				end
				local char = entry.char or {}
				local color = entry.color or CharColor(char)
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine(entry.name.."  ·  "..(entry.faction or "side unknown"), color[1], color[2], color[3])
				GameTooltip:AddLine(string.format("Level %d %s", char.level or 0, char.class or "?"), 1, 1, 1)
				for tipIndex = 1, #(entry.tips or {}) do
					local tipLine = entry.tips[tipIndex]
					GameTooltip:AddLine(tipLine.text, tipLine.color[1], tipLine.color[2], tipLine.color[3], true)
				end
				GameTooltip:Show()
			end)
			row:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
			panel.rows[index] = row
		end

		-- Each side has its own column and a faint wash of its colour, so the
		-- two sides are told apart at a glance: red on the left for the Horde,
		-- blue on the right for the Alliance. Kept low so the names stay clear.
		panel.washes = {}
		for column = 1, 2 do
			local wash = panel:CreateTexture(nil, "BACKGROUND", nil, 0)
			wash:SetPoint("TOPLEFT", panel, "TOPLEFT", 9 + (column - 1) * 356, -66)
			wash:SetSize(350, DAILY_PANEL_ROWS * 22 + 4)
			if column == 1 then
				wash:SetColorTexture(0.45, 0.08, 0.08, 0.11)
			else
				wash:SetColorTexture(0.08, 0.16, 0.38, 0.11)
			end
			panel.washes[column] = wash
		end

		-- The quick picks and the sort, along the bottom.
		local buttonX = 14
		local function PanelButton(text, width, onClick)
			local button = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
			button:SetSize(width, 22)
			button:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", buttonX, 16)
			button:SetText(text)
			button:SetScript("OnClick", onClick)
			buttonX = buttonX + width + 8
			return button
		end

		local function SetAll(wanted, faction)
			local picker = charPickers[kind]
			local rows = picker and picker.rows or nil
			if not rows then
				return
			end
			for index = 1, #rows do
				local row = rows[index]
				if faction then
					-- A side's button means that side alone: its characters are
					-- ticked and every other character is unticked, so pressing
					-- Alliance with everything already ticked changes the
					-- selection instead of doing nothing.
					PickerSet(row.key, row.faction == faction)
				else
					PickerSet(row.key, wanted)
				end
			end
			charPickers.greyed = nil
			ns.PlayUISound(wanted and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
			if faction then
				ns.Trace(pickerInfo.trace..": "..faction.." only")
			else
				ns.Trace(pickerInfo.trace..": "..(wanted and "ticked" or "unticked").." all characters")
			end
			RefreshCharPicker(kind)
			pickerInfo.onChange()
		end

		PanelButton("all", 60, function() SetAll(true) end)
		PanelButton("alliance", 90, function() SetAll(true, "Alliance") end)
		PanelButton("horde", 90, function() SetAll(true, "Horde") end)
		PanelButton("none", 70, function() SetAll(false) end)

		local sortButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		sortButton:SetSize(150, 22)
		sortButton:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -118, 16)
		sortButton:SetScript("OnClick", function()
			picker.sort = NextDailySort(picker.sort)
			ns.Trace(pickerInfo.trace.." list order: "..picker.sort)
			RefreshCharPicker(kind)
		end)
		panel.sortButton = sortButton

		local doneButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
		doneButton:SetSize(90, 22)
		doneButton:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -14, 16)
		doneButton:SetText("Done")
		doneButton:SetScript("OnClick", function()
			ShowCharPicker(kind, false)
		end)

		panel:Hide()
	end

	-- Draws a picker's rows from the chart's own data, so the two always agree
	-- about who is listed and in what colour.
	RefreshCharPicker = function(kind)
		local picker = charPickers[kind]
		if not picker then
			return
		end
		local pickerInfo = PICKER_INFO[kind]
		local panel = picker.panel
		local rows = pickerInfo.rows()
		picker.rows = rows
		local mode = picker.sort or "name"
		if panel.sortButton then
			panel.sortButton:SetText("sort: "..DailySortLabel(mode))
		end

		-- Grouped by faction, each side under its own heading.
		local groups, other = { Alliance = {}, Horde = {} }, {}
		for index = 1, #rows do
			local row = rows[index]
			if row.faction == "Alliance" or row.faction == "Horde" then
				local group = groups[row.faction]
				group[#group + 1] = row
			else
				other[#other + 1] = row
			end
		end
		local function SortGroup(list)
			table.sort(list, function(a, b)
				if mode == "class" or mode == "classDesc" then
					local one = (a.char and a.char.class) or "?"
					local two = (b.char and b.char.class) or "?"
					if one ~= two then
						if mode == "classDesc" then
							return one > two
						end
						return one < two
					end
				elseif mode == "nameDesc" then
					return tostring(a.name) > tostring(b.name)
				end
				return tostring(a.name) < tostring(b.name)
			end)
		end
		-- Two columns, one per side: Horde on the left, Alliance on the right,
		-- each under its own heading. A character whose side is not known goes
		-- at the foot of the left column, so the right column stays one side.
		local columns = { {}, {} }
		local function AddGroup(target, title, list)
			if #list == 0 then
				return
			end
			SortGroup(list)
			target[#target + 1] = { heading = title }
			for index = 1, #list do
				target[#target + 1] = { entry = list[index] }
			end
		end
		AddGroup(columns[1], "Horde", groups.Horde)
		AddGroup(columns[1], "Side unknown", other)
		AddGroup(columns[2], "Alliance", groups.Alliance)

		local included = 0
		for index = 1, #rows do
			if PickerShown(rows[index].key) then
				included = included + 1
			end
		end
		local countText = included.." of "..#rows.." used"
		if #columns[1] > DAILY_PANEL_ROWS or #columns[2] > DAILY_PANEL_ROWS then
			countText = countText.." - more characters than fit"
		end
		panel.count:SetText(countText)

		for column = 1, 2 do
			local list = columns[column]
			for slot = 1, DAILY_PANEL_ROWS do
				local row = panel.rows[(column - 1) * DAILY_PANEL_ROWS + slot]
				local item = list[slot]
				if row then
					if not item then
						row:Hide()
					elseif item.heading then
						row.key = nil
						row.tooltipRow = nil
						row.head:SetText(item.heading)
						row.head:Show()
						row.border:Hide()
						row.box:Hide()
						row.tick:Hide()
						row.swatch:Hide()
						row.name:Hide()
						row.info:Hide()
						row:Show()
					else
						local entry = item.entry
						local char = entry.char or {}
						local color = entry.color or CharColor(char)
						local shown = PickerShown(entry.key)
						row.key = entry.key
						row.tooltipRow = entry
						row.head:Hide()
						row.border:Show()
						row.box:Show()
						row.swatch:Show()
						row.name:Show()
						row.info:Show()
						row.tick:SetShown(shown)
						if shown then
							row.border:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
						else
							row.border:SetColorTexture(1, 1, 1, 0.18)
						end
						row.swatch:SetColorTexture(color[1], color[2], color[3], shown and 1 or 0.35)
						row.name:SetText(entry.name)
						row.name:SetTextColor(color[1], color[2], color[3])
						row.info:SetText(entry.info or "")
						row:Show()
					end
				end
			end
		end
	end

	ShowCharPicker = function(kind, shown)
		local picker = charPickers[kind]
		if not picker then
			return
		end
		picker.shown = shown and true or false
		if shown then
			RefreshCharPicker(kind)
			picker.panel:Show()
		else
			picker.panel:Hide()
			-- Closing with nobody ticked re-includes the character being
			-- played, so a combined view is never left empty.
			ns.EnsureSomeTotalIncluded()
			PICKER_INFO[kind].onChange()
		end
	end
end
-- Handed to the tabs that open the picker, and to the Total page, which
-- loads after this file and reads DailyColors through ns.
ns.ShowCharPicker, ns.BuildCharPicker = ShowCharPicker, BuildCharPicker
ns.RefreshCharPicker, ns.DailyColors = RefreshCharPicker, DailyColors
ns.charPickers = charPickers
--@ENDFOOTER
