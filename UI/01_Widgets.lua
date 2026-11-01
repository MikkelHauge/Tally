-- Tally - the widgets every page is built from: the minimap icon, the
-- stat tiles, list cards and their rows, info buttons, chart legends and
-- the scrolling that lets a long card answer the wheel.
local addonName, ns = ...

-- Helpers and constants from the files loaded above (see Tally.toc).
local ACCENT, ICON_FILE_ID, ICON_PATH, TILE_WIDTH, TILE_HEIGHT, TILE_GAP, TILE_BACKDROP, VALUE_COLOR, CARD_TITLE_DIM, CATEGORY_LABELS, overviewWidgets =
	ns.ACCENT, ns.ICON_FILE_ID, ns.ICON_PATH, ns.TILE_WIDTH, ns.TILE_HEIGHT, ns.TILE_GAP, ns.TILE_BACKDROP, ns.VALUE_COLOR, ns.CARD_TITLE_DIM, ns.CATEGORY_LABELS, ns.overviewWidgets
local iconButton
local iconTexture
-------------------------------------------------------------------------------
-- Minimap icon
-------------------------------------------------------------------------------

-- The icon rides the minimap's outer edge, the same way Tongues and Ammonia
-- do it: only the angle around the circle is saved, so it comes back to the
-- same spot after a reload. Read as a clock face, the three addons sit at
-- 11 (Tongues), 9 (Ammonia) and 7 (Tally) o'clock down the left side.
local ICON_DEFAULT_ANGLE = 240
local ICON_LEEWAY = 10

-- How far from the middle of the minimap the icon's middle belongs. Worked
-- out whenever it is used, so a resized minimap still gets a ring that hugs
-- its edge; 140 is only the fallback before the minimap is laid out.
local function IconRingRadius()
	local width = Minimap:GetWidth()
	if not width or width <= 0 then
		width = 140
	end
	return width / 2 + ICON_LEEWAY
end

local function ApplyIconPosition()
	if not iconButton then
		return
	end
	local angle = math.rad(ns.db.settings.icon.angle or ICON_DEFAULT_ANGLE)
	local radius = IconRingRadius()
	iconButton:ClearAllPoints()
	iconButton:SetParent(Minimap)
	iconButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end
ns.ApplyIconPosition = ApplyIconPosition

-- Back to the default spot (the Settings page's reset button calls this).
function ns.ResetIconPosition()
	ns.db.settings.icon.angle = ICON_DEFAULT_ANGLE
	ApplyIconPosition()
end

function ns.UpdateIconState()
	if not iconButton then
		return
	end
	iconButton:SetShown(ns.db.settings.icon.shown and true or false)
end

local function ApplyTallyIcon(texture)
	local ok = pcall(texture.SetTexture, texture, ICON_FILE_ID)
	if not ok or not texture:GetTexture() then
		texture:SetTexture(ICON_PATH)
	end
end

local function CreateIconButton()
	local button = CreateFrame("Button", "TallyIcon", Minimap)
	iconButton = button
	button:SetSize(32, 32)
	button:SetFrameStrata("MEDIUM")
	button:SetFrameLevel(8)
	button:SetMovable(true)
	button:EnableMouse(true)
	button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	button:RegisterForDrag("LeftButton")

	-- The classic minimap-button geometry, the same numbers LibDBIcon uses:
	-- the tracking border's ring sits in the upper-left of its 53 pixel
	-- texture, so the disc and the icon are offset down-right to line up with
	-- it. Centring them on the button instead left the icon off-centre in
	-- the ring and its square corners showing outside the circle.
	local overlay = button:CreateTexture(nil, "OVERLAY")
	overlay:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
	overlay:SetSize(53, 53)
	overlay:SetPoint("TOPLEFT", 0, 0)

	local background = button:CreateTexture(nil, "BACKGROUND")
	background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
	background:SetSize(20, 20)
	background:SetPoint("TOPLEFT", 7, -5)

	iconTexture = button:CreateTexture(nil, "ARTWORK")
	ApplyTallyIcon(iconTexture)
	iconTexture:SetSize(17, 17)
	iconTexture:SetPoint("TOPLEFT", 7, -6)
	iconTexture:SetTexCoord(0.05, 0.95, 0.05, 0.95)

	button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

	-- OnMouseDown records the cursor position; a drag that moves more than
	-- 8 pixels sets dragMoved, which swallows the click.
	button:SetScript("OnMouseDown", function(self)
		local x, y = GetCursorPosition()
		self.pressX, self.pressY = x, y
		self.dragMoved = nil
	end)

	button:SetScript("OnDragStart", function(self)
		if ns.db.settings.icon.locked then
			return
		end
		self:SetScript("OnUpdate", function()
			local x, y = GetCursorPosition()
			if not x then
				return
			end
			if self.pressX and math.abs(x - self.pressX) + math.abs(y - self.pressY) > 8 then
				self.dragMoved = true
			end
			-- Both the cursor and the minimap's middle are read in the
			-- minimap's own units, which is what its anchors use too.
			local scale = Minimap:GetEffectiveScale() or 1
			x, y = x / scale, y / scale
			local centerX, centerY = Minimap:GetCenter()
			if not centerX then
				return
			end
			local angle = math.deg(math.atan2(y - centerY, x - centerX))
			ns.db.settings.icon.angle = angle
			local radius = IconRingRadius()
			self:ClearAllPoints()
			self:SetPoint("CENTER", Minimap, "CENTER",
				math.cos(math.rad(angle)) * radius, math.sin(math.rad(angle)) * radius)
		end)
	end)
	button:SetScript("OnDragStop", function(self)
		self:SetScript("OnUpdate", nil)
	end)

	button:SetScript("OnClick", function(self, mouseButton)
		if self.dragMoved then
			return
		end
		if mouseButton == "RightButton" then
			ns.PrintReport("overview")
		else
			ns.ToggleMainWindow()
		end
	end)

	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_LEFT")
		GameTooltip:AddLine("Tally")
		local char = ns.GetChar()
		if char then
			GameTooltip:AddLine(string.format("Level %d %s%s", char.level or 0, char.race and (char.race.." ") or "", char.class or ""), 1, 1, 1)
			if char.played and char.played.total then
				GameTooltip:AddLine("Lifetime played: "..ns.FormatDuration(char.played.total), 1, 1, 1)
			end
			local rate = ns.XpRate(char)
			if rate then
				GameTooltip:AddLine("XP pace: "..ns.FormatCompact(rate.perHour).." XP/h"..(rate.scope == "recent" and (" over the last "..rate.minutes..(rate.minutes == 1 and " minute" or " minutes")) or (rate.scope == "level" and " on this level" or " overall")), 1, 1, 1)
			end
			if char.gold and char.gold.balance then
				GameTooltip:AddLine("Money: "..ns.MoneyColored(char.gold.balance), 1, 1, 1)
			end
			local session = char.sessions and char.sessions.current
			if session and session.goldStart then
				GameTooltip:AddLine("This session: "..ns.FormatMoneyDelta((char.gold.balance or session.goldStart) - session.goldStart), 1, 1, 1)
			end
		end
		GameTooltip:AddLine("Left-click: open the statistics window.", 1, 1, 1)
		GameTooltip:AddLine("Right-click: print the overview to chat.", 1, 1, 1)
		if ns.db.settings.icon.locked then
			GameTooltip:AddLine("Position locked.", 1, 1, 1)
		else
			GameTooltip:AddLine("Drag it around the minimap to move it.", 1, 1, 1)
		end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	ApplyIconPosition()
end

-------------------------------------------------------------------------------
-- Stat tiles
-------------------------------------------------------------------------------

local function CreateTile(parent, labelText)
	local tile = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	tile:SetBackdrop(TILE_BACKDROP)
	tile:SetBackdropColor(0, 0, 0, 0.35)
	tile:SetBackdropBorderColor(1, 0.72, 0.25, 0.12)

	tile.label = tile:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	tile.label:SetPoint("TOPLEFT", 10, -6)
	tile.label:SetPoint("TOPRIGHT", -10, -6)
	tile.label:SetJustifyH("LEFT")
	tile.label:SetTextColor(0.62, 0.62, 0.62)
	tile.label:SetText(labelText)

	tile.value = tile:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	tile.value:SetPoint("TOPLEFT", 10, -20)
	tile.value:SetPoint("TOPRIGHT", -10, -20)
	tile.value:SetJustifyH("LEFT")
	tile.value:SetTextColor(VALUE_COLOR[1], VALUE_COLOR[2], VALUE_COLOR[3])

	tile.sub = tile:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	tile.sub:SetPoint("TOPLEFT", 10, -42)
	tile.sub:SetPoint("TOPRIGHT", -10, -42)
	tile.sub:SetJustifyH("LEFT")
	tile.sub:SetTextColor(0.55, 0.55, 0.55)

	-- A second figure on the same line, hard against the right edge: a label
	-- reads from the left and a quantity from the right, so the number is
	-- found without reading the line.
	tile.subRight = tile:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	tile.subRight:SetPoint("TOPRIGHT", -10, -42)
	tile.subRight:SetJustifyH("RIGHT")
	tile.subRight:SetTextColor(0.55, 0.55, 0.55)

	tile.barBg = tile:CreateTexture(nil, "BACKGROUND")
	tile.barBg:SetPoint("BOTTOMLEFT", 10, 8)
	tile.barBg:SetPoint("BOTTOMRIGHT", -10, 8)
	tile.barBg:SetHeight(4)
	tile.barBg:SetColorTexture(1, 1, 1, 0.08)
	tile.barBg:Hide()

	tile.barFill = tile:CreateTexture(nil, "ARTWORK")
	tile.barFill:SetPoint("BOTTOMLEFT", 10, 8)
	tile.barFill:SetHeight(4)
	tile.barFill:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
	tile.barFill:Hide()
	return tile
end

local function SetTile(tile, value, sub, valueColor, subColor, subRight)
	tile.value:SetText(value or "-")
	if valueColor then
		tile.value:SetTextColor(valueColor[1], valueColor[2], valueColor[3])
	else
		tile.value:SetTextColor(VALUE_COLOR[1], VALUE_COLOR[2], VALUE_COLOR[3])
	end
	tile.sub:SetText(sub or "")
	if subColor then
		tile.sub:SetTextColor(subColor[1], subColor[2], subColor[3])
	else
		tile.sub:SetTextColor(0.55, 0.55, 0.55)
	end
	tile.subRight:SetText(subRight or "")
end

-- track = false keeps the tiles out of overviewWidgets.all, so a page that
-- refreshes its own tiles is not overwritten by the overview. offset starts
-- the pool at into[offset + 1], so two tile rows can share one pool.
local function CreateTileRow(parent, y, labels, into, track, offset)
	offset = offset or 0
	for index = 1, 4 do
		local tile = CreateTile(parent, labels[index])
		tile:SetSize(TILE_WIDTH, TILE_HEIGHT)
		tile:SetPoint("TOPLEFT", parent, "TOPLEFT", (index - 1) * (TILE_WIDTH + TILE_GAP), y)
		into[offset + index] = tile
		if track ~= false then
			overviewWidgets.all[#overviewWidgets.all + 1] = tile
		end
	end
end
-------------------------------------------------------------------------------
-- Shared helpers (used by the overview and the character tabs). They live
-- above every page so no refresher can ever call one before it exists.
-------------------------------------------------------------------------------

-- The character the pages describe: ns.ReportChar(), which is ns.GetChar()
-- while viewing live data and the viewed record otherwise. Read-only; all
-- writes go through ns.GetChar(), so viewing never touches a record.
local function DisplayChar()
	return ns.ReportChar()
end

local QUALITY_NAMES = { [0] = "Poor", [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary", [6] = "Artifact" }
local QUALITY_COLORS = {
	[0] = { 0.62, 0.62, 0.62 },
	[1] = { 1.0, 1.0, 1.0 },
	[2] = { 0.12, 1.0, 0.0 },
	[3] = { 0.0, 0.44, 0.87 },
	[4] = { 0.64, 0.21, 0.93 },
	[5] = { 1.0, 0.5, 0.0 },
	[6] = { 0.9, 0.8, 0.5 },
}

local function PercentText(part, whole)
	if not whole or whole <= 0 then
		return "0%"
	end
	return string.format("%d%%", math.floor((part or 0) / whole * 100 + 0.5))
end

-- The Sessions tile reads the same on the overview and on the playtime page,
-- so its two figures are built in one place: the session open now on the left
-- (or the longest finished one when nothing is open), and the average of the
-- finished sessions against the right edge. The average is over the finished
-- sessions only, because an open session has no length to divide by yet.
local function SessionTileText(sessions, liveSession)
	local sub, average = "no finished sessions yet", nil
	if (sessions.count or 0) > 0 then
		sub = "longest "..ns.FormatDuration(sessions.longest, true)
		average = "avg "..ns.FormatDuration(math.floor((sessions.seconds or 0) / sessions.count), true)
	end
	if liveSession then
		sub = "current: "..ns.FormatDuration(liveSession.seconds, true)
	end
	return sub, average
end

local function ReadPlayerXP()
	if type(UnitXP) ~= "function" or type(UnitXPMax) ~= "function" then
		return nil, nil
	end
	local okXP, xp = pcall(UnitXP, "player")
	local okMax, xpMax = pcall(UnitXPMax, "player")
	if not okXP or not okMax or type(xp) ~= "number" or type(xpMax) ~= "number" or xp < 0 or xpMax <= 0 then
		return nil, nil
	end
	return xp, xpMax
end

local function QualityCode(quality)
	local color = QUALITY_COLORS[quality] or QUALITY_COLORS[1]
	return string.format("|cff%02x%02x%02x", math.floor(color[1] * 255 + 0.5), math.floor(color[2] * 255 + 0.5), math.floor(color[3] * 255 + 0.5))
end

-- The quality an item should be drawn in. A record usually kept the quality
-- it read; a sale invoice states none, so the item's id or name is asked
-- instead. Nil when neither knows, which leaves the item uncoloured rather
-- than guessing.
local function ItemQuality(item)
	if type(item) ~= "table" then
		return nil
	end
	if item.quality ~= nil then
		return item.quality
	end
	if item.id and type(ns.ItemInfo) == "function" then
		local _, _, quality = ns.ItemInfo(item.id)
		if quality ~= nil then
			return quality
		end
	end
	if item.name then
		if type(ns.ItemIDForName) == "function" then
			local foundID = ns.ItemIDForName(item.name)
			if foundID and type(ns.ItemInfo) == "function" then
				local _, _, quality = ns.ItemInfo(foundID)
				if quality ~= nil then
					return quality
				end
			end
		end
		if type(ns.ItemInfoByName) == "function" then
			local _, _, quality = ns.loot.ItemInfoByName(item.name)
			if type(quality) == "number" then
				return quality
			end
		end
	end
	return nil
end

-- A bucket as a list of { name, count } pairs, biggest count first; ties
-- break by name. `limit` trims the list to that many entries.
local function SortedCounts(bucket, limit)
	local list = {}
	for name, count in pairs(bucket or {}) do
		list[#list + 1] = { name = name, count = count }
	end
	table.sort(list, function(a, b)
		if a.count == b.count then
			return a.name < b.name
		end
		return a.count > b.count
	end)
	if limit and #list > limit then
		for index = #list, limit + 1, -1 do
			list[index] = nil
		end
	end
	return list
end

-- Same, for the gold category buckets: { name, value } pairs with the value
-- in copper. Keys are mapped through CATEGORY_LABELS.
local function SortedCategories(bucket, limit)
	local list = {}
	for key, value in pairs(bucket or {}) do
		list[#list + 1] = { name = CATEGORY_LABELS[key] or key, value = value }
	end
	table.sort(list, function(a, b)
		if a.value == b.value then
			return a.name < b.name
		end
		return a.value > b.value
	end)
	if limit and #list > limit then
		for index = #list, limit + 1, -1 do
			list[index] = nil
		end
	end
	return list
end

-- A bordered card at (x, y) from the parent's top-left, `width` by `height`,
-- with a title and a body FontString. Returns the card.
local function CreateListCard(parent, x, y, width, height, title)
	local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	card:SetBackdrop(TILE_BACKDROP)
	card:SetBackdropColor(0, 0, 0, 0.35)
	card:SetBackdropBorderColor(1, 0.72, 0.25, 0.12)
	card:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	card:SetSize(width, height)

	card.title = card:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	card.title:SetPoint("TOPLEFT", 12, -8)
	card.title:SetText(title)
	card.title:SetTextColor(CARD_TITLE_DIM[1], CARD_TITLE_DIM[2], CARD_TITLE_DIM[3])

	card.body = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	card.body:SetPoint("TOPLEFT", 12, -30)
	card.body:SetPoint("BOTTOMRIGHT", -12, 10)
	card.body:SetJustifyH("LEFT")
	card.body:SetJustifyV("TOP")
	card.body:SetTextColor(0.68, 0.68, 0.68)
	card.body:SetSpacing(1)
	return card
end

-- Guarantees a row frame at card.rowLines[index], creating it on first use.
-- A short row is 14 pixels high, stepped by ROW_STEP; a tall row (tall =
-- true) is 26 high, stepped by TALL_ROW_STEP, and adds detail/detailRight
-- FontStrings and a divider texture. The tall flag set when a card's rows
-- are first created applies to every later draw. Every row carries a left,
-- a mid (right-aligned ROW_MID_RIGHT pixels in from the right edge) and a
-- right FontString. A card may set rowStep before its rows are drawn to
-- tighten or loosen the spacing.
local ROW_STEP = 15
local TALL_ROW_STEP = 27
local ROW_MID_RIGHT = 100
local ROW_DIM = { 0.68, 0.68, 0.68 }
local ROW_DETAIL_DIM = { 0.52, 0.52, 0.52 }
-- Recipe category headings, one shade warmer than the row text so they read
-- as labels without competing with the gold profession headings.
local CATEGORY_HEAD_COLOR = { 0.76, 0.71, 0.58 }

local function EnsureRowLine(card, index, tall)
	local rows = card.rowLines
	if not rows then
		rows = {}
		card.rowLines = rows
		card.rowTall = tall and true or false
	end
	local tallRows = card.rowTall
	local step = card.rowStep or (tallRows and TALL_ROW_STEP or ROW_STEP)
	local midRight = card.rowMidRight or ROW_MID_RIGHT
	local mid2Right = card.rowMid2Right
	local row = rows[index]
	if not row then
		row = CreateFrame("Frame", nil, card)
		row:SetHeight(tallRows and 26 or 14)
		row:SetPoint("TOPLEFT", 12, -30 - (index - 1) * step)
		row:SetPoint("RIGHT", card, "RIGHT", card.rowRight or -12, 0)
		row.left = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.left:SetJustifyH("LEFT")
		row.right = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.right:SetJustifyH("RIGHT")
		row.mid = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		row.mid:SetJustifyH("RIGHT")
		-- A second right-aligned column, sitting left of `mid`, for a card
		-- that needs four of them (the records table). It exists only where
		-- the card asked for it, so every other list stays as it was.
		if mid2Right then
			row.mid2 = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.mid2:SetJustifyH("RIGHT")
		end
		-- The cooldown bar: a track across the row with a fill whose width
		-- is reset every frame while a wait runs down (CooldownBarTick).
		row.barTrack = row:CreateTexture(nil, "BACKGROUND")
		row.barTrack:SetPoint("LEFT", 0, 0)
		row.barTrack:SetPoint("RIGHT", 0, 0)
		row.barTrack:SetHeight(13)
		row.barTrack:SetColorTexture(1, 1, 1, 0.05)
		row.barTrack:Hide()
		row.barFill = row:CreateTexture(nil, "BACKGROUND", nil, 1)
		row.barFill:SetPoint("LEFT", 0, 0)
		row.barFill:SetHeight(13)
		row.barFill:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.22)
		row.barFill:Hide()
		if tallRows then
			row.left:SetPoint("TOPLEFT", 0, 0)
			row.right:SetPoint("TOPRIGHT", 0, 0)
			row.mid:SetPoint("TOPRIGHT", -midRight, 0)
			if row.mid2 then
				row.mid2:SetPoint("TOPRIGHT", -mid2Right, 0)
			end
			row.detail = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.detail:SetPoint("TOPLEFT", 0, -14)
			row.detail:SetJustifyH("LEFT")
			row.detail:SetTextColor(ROW_DETAIL_DIM[1], ROW_DETAIL_DIM[2], ROW_DETAIL_DIM[3])
			row.detailRight = row:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.detailRight:SetPoint("TOPRIGHT", 0, -14)
			row.detailRight:SetJustifyH("RIGHT")
			row.detailRight:SetTextColor(ROW_DETAIL_DIM[1], ROW_DETAIL_DIM[2], ROW_DETAIL_DIM[3])
			row.divider = row:CreateTexture(nil, "ARTWORK")
			row.divider:SetHeight(1)
			row.divider:SetPoint("BOTTOMLEFT", 0, 0)
			row.divider:SetPoint("BOTTOMRIGHT", 0, 0)
			row.divider:SetColorTexture(1, 1, 1, 0.07)
		else
			row.left:SetPoint("LEFT", 0, 0)
			row.right:SetPoint("RIGHT", 0, 0)
			row.mid:SetPoint("RIGHT", -midRight, 0)
			if row.mid2 then
				row.mid2:SetPoint("RIGHT", -mid2Right, 0)
			end
			-- Short rows also carry a divider texture, hidden until a
			-- divider entry in FillCardRows asks for it.
			row.divider = row:CreateTexture(nil, "ARTWORK")
			row.divider:SetHeight(1)
			row.divider:SetPoint("BOTTOMLEFT", 0, 0)
			row.divider:SetPoint("BOTTOMRIGHT", 0, 0)
			row.divider:SetColorTexture(1, 1, 1, 0.07)
			row.divider:Hide()
		end
		rows[index] = row
	end
	return row
end

local function SetRowColor(fontString, color)
	if color then
		fontString:SetTextColor(color[1], color[2], color[3])
	else
		fontString:SetTextColor(ROW_DIM[1], ROW_DIM[2], ROW_DIM[3])
	end
end

-- Trims text to maxChars, appending "...". Text containing "|" (colour
-- markup) is never cut, since the codes are part of the string.
local function CutRowText(text, maxChars)
	text = text or ""
	if not maxChars or #text <= maxChars or string.find(text, "|", 1, true) then
		return text
	end
	return string.sub(text, 1, maxChars - 3).."..."
end

-- Trims plain text to a pixel width, with an ellipsis. List rows are drawn in
-- GameFontHighlightSmall, so that is the font measured here; a name fills the
-- column whatever the client's font happens to be, rather than stopping at a
-- fixed number of letters.
local measureFont
local function CutTextToWidth(text, width)
	text = text or ""
	if not width or width <= 0 then
		return ""
	end
	if not measureFont then
		measureFont = UIParent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
		measureFont:Hide()
	end
	measureFont:SetText(text)
	if measureFont:GetStringWidth() <= width then
		return text
	end
	local low, high = 0, #text
	while low < high do
		local mid = math.ceil((low + high) / 2)
		measureFont:SetText(string.sub(text, 1, mid).."...")
		if measureFont:GetStringWidth() <= width then
			low = mid
		else
			high = mid - 1
		end
	end
	return string.sub(text, 1, low).."..."
end

-- Draws rows on a list card. Each entry is { left, right, mid, midColor,
-- detail, detailRight, leftColor, rightColor, divider, tip, bar }; divider
-- draws a blank row whose hairline shows. mid is right-aligned in its own
-- column. detail/detailRight only appear on tall cards. left is trimmed to
-- leftMax characters. tip is handed to the row, where the card's hover can
-- find it (see RowHoverTick). bar = { readyAt, span } gives the row a
-- bar across it, which CooldownBarTick sizes from the time left. Entries
-- past the row capacity collapse into one "... and N more" row, and the
-- card's body text is cleared when any row is drawn. Returns the number of
-- rows drawn, so a caller can fall back to plain body text when it is 0.
-- Put every row back on its normal grid. A card that pins its last row to
-- the bottom (the economy totals) would otherwise leave the previous pinned
-- row behind when the number of rows changes, and the two would overlap.
local function ResetRowAnchors(card)
	local rows = card.rowLines
	if not rows then
		return
	end
	local step = card.rowStep or (card.rowTall and TALL_ROW_STEP or ROW_STEP)
	for index = 1, #rows do
		local row = rows[index]
		row:ClearAllPoints()
		row:SetPoint("TOPLEFT", 12, -30 - (index - 1) * step)
		row:SetPoint("RIGHT", card, "RIGHT", card.rowRight or -12, 0)
	end
end

local function FillCardRows(card, entries, leftMax, tall)
	local step = card.rowStep or (tall and TALL_ROW_STEP or ROW_STEP)
	ResetRowAnchors(card)
	local capacity = math.max(1, math.floor((card:GetHeight() - 46) / step))
	local truncated = #entries > capacity
	local drawn = truncated and math.max(0, capacity - 1) or #entries
	for index = 1, drawn do
		local entry = entries[index]
		local row = EnsureRowLine(card, index, tall)
		if entry.divider then
			-- A blank row whose hairline shows: the rule between two blocks.
			row.left:SetText("")
			row.right:SetText("")
			row.mid:SetText("")
			if row.mid2 then
				row.mid2:SetText("")
			end
			row.tip = nil
			row.click = nil
			row.barData = nil
			row.barTrack:Hide()
			row.barFill:Hide()
			if row.detail then
				row.detail:SetText("")
			end
			if row.detailRight then
				row.detailRight:SetText("")
			end
			if row.divider then
				row.divider:SetShown(true)
			end
		else
			row.left:SetText(CutRowText(entry.left, leftMax or 40))
			SetRowColor(row.left, entry.leftColor)
			row.mid:SetText(entry.mid or "")
			SetRowColor(row.mid, entry.midColor or ROW_DIM)
			if row.mid2 then
				row.mid2:SetText(entry.mid2 or "")
				SetRowColor(row.mid2, entry.mid2Color or ROW_DIM)
			end
			row.right:SetText(entry.right or "")
			SetRowColor(row.right, entry.rightColor or VALUE_COLOR)
			row.tip = entry.tip or nil
			row.click = entry.click or nil
			row.barData = entry.bar or nil
			row.barTrack:SetShown(row.barData ~= nil)
			row.barFill:SetShown(row.barData ~= nil)
			if row.detail then
				row.detail:SetText(entry.detail or "")
			end
			if row.detailRight then
				row.detailRight:SetText(entry.detailRight or "")
			end
			if row.divider and not tall then
				-- A hairline under every row, where the card asked for it.
				row.divider:SetShown(card.rowDividers and true or false)
			end
		end
		row:Show()
	end
	local count = drawn
	if truncated then
		local row = EnsureRowLine(card, drawn + 1, tall)
		row.left:SetText("... and "..(#entries - drawn).." more")
		SetRowColor(row.left, nil)
		row.mid:SetText("")
		row.right:SetText("")
		if row.mid2 then
			row.mid2:SetText("")
		end
		row.tip = nil
		row.click = nil
		row.barData = nil
		row.barTrack:Hide()
		row.barFill:Hide()
		if row.detail then
			row.detail:SetText("")
		end
		if row.detailRight then
			row.detailRight:SetText("")
		end
		row:Show()
		count = drawn + 1
	end
	if card.rowLines then
		for index = count + 1, #card.rowLines do
			card.rowLines[index]:Hide()
		end
		if card.rowTall then
			-- On tall cards the divider sits under every row but the
			-- last.
			for index = 1, count do
				card.rowLines[index].divider:SetShown(index < count)
			end
		end
	end
	if count > 0 then
		card.body:SetText("")
	end
	return count
end

-- Clears the card's rows and sets its plain body text.
local function ShowCardText(card, text)
	FillCardRows(card, {})
	card.body:SetText(text)
	if card.scrollBar then
		local bar = card.scrollBar
		bar.updating = true
		bar:Hide()
		bar:SetValue(0)
		bar.updating = false
	end
end

-- A timestamp for a row: the clock (ns.FormatClock) when `at` is today, the
-- date otherwise, and "?" when `at` is nil.
local function ShortWhen(at)
	if not at then
		return "?"
	end
	if date("%Y-%m-%d", at) == date("%Y-%m-%d") then
		return ns.FormatClock(at)
	end
	return ns.FormatDate(at)
end

-- Adds a mouse hit area over a card's title strip. Hovering it shows a
-- tooltip with `title` and `note`; returns the hit frame. A card whose own
-- title changes while it is drawn can put the current title in
-- card.noteTitle, which is used instead.
local function AddCardTitleNote(card, title, note)
	local hit = CreateFrame("Frame", nil, card)
	hit:EnableMouse(true)
	hit:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -2)
	hit:SetPoint("TOPRIGHT", card, "TOPRIGHT", -8, -2)
	hit:SetHeight(22)
	hit:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		local label = card.noteTitle or title
		local text = (card.noteText and card.noteText ~= "") and card.noteText or note
		GameTooltip:AddLine(label, ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine(text, 1, 1, 1, true)
		GameTooltip:Show()
	end)
	hit:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	return hit
end

-- A small "Info" button pinned to the top-right corner of a card or page.
-- Hovering it shows `title` and each line of `body`; it has no click action.
-- The caller positions the thing it sits next to, using the returned button.
local function CreateInfoButton(parent, title, body, x, y)
	local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
	button:SetHeight(18)
	button:SetFrameLevel((parent:GetFrameLevel() or 1) + 4)
	button:SetBackdrop(TILE_BACKDROP)
	button:SetBackdropColor(0.06, 0.06, 0.08, 0.6)
	button:SetBackdropBorderColor(1, 1, 1, 0.12)
	button:SetPoint("TOPRIGHT", parent, "TOPRIGHT", x or -4, y or 0)
	button.text = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	button.text:SetPoint("LEFT", 9, 0)
	button.text:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
	button.text:SetText("Info")
	button:SetWidth(button.text:GetStringWidth() + 18)
	button.hover = button:CreateTexture(nil, "HIGHLIGHT")
	button.hover:SetAllPoints(button)
	button.hover:SetColorTexture(1, 1, 1, 0.09)
	button:EnableMouse(true)
	button:RegisterForClicks("LeftButtonUp")
	button:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine(title, ACCENT[1], ACCENT[2], ACCENT[3])
		for index = 1, #body do
			GameTooltip:AddLine(body[index], 1, 1, 1, true)
		end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	return button
end

-- Places the legend buttons on a card, left to right, wrapping to a new row
-- of LEGEND_ROW_STEP when the card runs out of width. maxRows is capped so
-- the plot keeps minPlot pixels of height; entries past the cap are counted
-- by a dim "N more" note. The plot is moved down one row per legend row.
-- firstY sets where the first legend row starts, for a card that has
-- something else in its top-right corner. Returns the number of rows used
-- and the number of entries placed.
local LEGEND_ROW_STEP = 20
local function LayoutLegend(card, plot, buttons, plotLeft, plotTop, plotBottom, minPlot, firstY)
	local cardHeight = card:GetHeight() or 0
	local width = card:GetWidth() or 0
	local maxRows = 99
	if plot and minPlot then
		local plotHeight = (cardHeight - plotBottom) + plotTop
		if plotHeight > minPlot then
			maxRows = math.max(1, math.floor((plotHeight - minPlot) / LEGEND_ROW_STEP) + 1)
		end
	end
	local legendX, legendY, rows = 12, firstY or -24, 1
	local placed = 0
	for index = 1, #buttons do
		local button = buttons[index]
		local buttonWidth = button:GetWidth() or 0
		local wraps = legendX > 12 and width > 0 and legendX + buttonWidth > width - 12
		if wraps and rows >= maxRows then
			break
		end
		if wraps then
			legendX = 12
			legendY = legendY - LEGEND_ROW_STEP
			rows = rows + 1
		end
		button:SetPoint("TOPLEFT", card, "TOPLEFT", legendX, legendY)
		button:Show()
		legendX = legendX + buttonWidth + 6
		placed = index
	end
	if buttons[placed + 1] then
		rows = rows + 1
		if not card.legendNote then
			card.legendNote = card:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
			card.legendNote:SetJustifyH("LEFT")
			card.legendNote:SetTextColor(0.55, 0.55, 0.55)
		end
		local missing = #buttons - placed
		card.legendNote:SetPoint("TOPLEFT", card, "TOPLEFT", 12, legendY - LEGEND_ROW_STEP)
		card.legendNote:SetText(missing..(missing == 1 and " name" or " names").." more - not enough room to list every line")
		card.legendNote:Show()
	elseif card.legendNote then
		card.legendNote:Hide()
	end
	if plot then
		plot:SetPoint("TOPLEFT", card, "TOPLEFT", plotLeft, plotTop - (rows - 1) * LEGEND_ROW_STEP)
	end
	return rows, placed
end
local function AddPageNote(parent, x, y, width, text)
	local note = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	note:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	note:SetWidth(width)
	note:SetJustifyH("LEFT")
	note:SetTextColor(0.58, 0.58, 0.58)
	note:SetText(text)
	return note
end
-- Draws one window of `lines` on a card, starting at the value in
-- store[offsetField], which is clamped to the list's length. The title names
-- the window when there is more than a cardful. `tall` matches the rows the
-- entries are drawn with, so the window is counted in the right step.
-- Returns the number of rows FillCardRows drew.
ns.FillScrollingLines = function(card, lines, store, offsetField, title, leftMax, tall)
	local step = card.rowStep or (tall and TALL_ROW_STEP or ROW_STEP)
	local room = math.max(1, math.floor((card:GetHeight() - 46) / step))
	local maxOffset = math.max(0, #lines - room)
	local offset = math.min(math.max(store[offsetField] or 0, 0), maxOffset)
	store[offsetField] = offset
	if card.scrollBar then
		local bar = card.scrollBar
		bar.updating = true
		if maxOffset > 0 then
			bar:SetMinMaxValues(0, maxOffset)
			bar:SetValue(offset)
			bar:Show()
		else
			bar:Hide()
			bar:SetValue(0)
		end
		bar.updating = false
	end
	local first = offset + 1
	local last = math.min(#lines, offset + room)
	if #lines > room then
		card.title:SetText(string.format("%s - %d-%d of %d", title, first, last, #lines))
	else
		card.title:SetText(title)
	end
	local window = {}
	for index = first, last do
		window[#window + 1] = lines[index]
	end
	return FillCardRows(card, window, leftMax, tall)
end

-- Lets a long list on a card take the mouse, so its rows can answer a hover
-- and, with `wheel`, walk the list on the wheel: the offset lives in
-- store[offsetField] and a step asks `refresh` to redraw. A card that takes
-- the mouse also has to hand window drags back.
local function MakeCardScrollable(card, store, offsetField, refresh, wheel)
	card:EnableMouse(true)	card:RegisterForDrag("LeftButton")
	card:SetScript("OnDragStart", function()
		card.hoverSuppressed = true
		card.hoverKey = nil
		if GameTooltip:IsOwned(card) then
			GameTooltip:Hide()
		end
		if ns.mainFrame then
			ns.mainFrame:StartMoving()
		end
	end)
	card:SetScript("OnDragStop", function()
		card.hoverSuppressed = nil
		if ns.mainFrame then
			ns.mainFrame:StopMovingOrSizing()
		end
	end)
	if wheel == false then
		return
	end
	card:EnableMouseWheel(true)
	card:SetScript("OnMouseWheel", function(_, delta)
		store[offsetField] = (store[offsetField] or 0) + (delta > 0 and -3 or 3)
		refresh()
	end)
end

-- A visible scrollbar for a card that draws a window of a long list. The
-- wheel above still works; this makes the overflow obvious and gives a
-- draggable control when a tooltip under the cursor takes the wheel.
local function AddCardScrollbar(card, store, offsetField, refresh)
	-- The rows stop short of the bar so right-aligned text never runs under
	-- it. Set before the first draw.
	card.rowRight = card.rowRight or -22
	local bar = CreateFrame("Slider", nil, card, "UIPanelScrollBarTemplate")
	bar:SetFrameLevel((card:GetFrameLevel() or 1) + 4)
	bar:SetPoint("TOPRIGHT", card, "TOPRIGHT", -2, -28)
	bar:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -2, 8)
	bar:SetWidth(10)
	bar:SetValueStep(1)
	bar:SetMinMaxValues(0, 1)
	bar:Hide()
	bar:SetScript("OnValueChanged", function(self, value)
		if self.updating then
			return
		end
		store[offsetField] = math.floor((tonumber(value) or 0) + 0.5)
		refresh()
	end)
	card.scrollBar = bar
	return bar
end

-- A small framed button in a card's top-right corner, raised above the card
-- so the card's own rows and its wheel cannot take its clicks. The caller
-- sets the label (SetCornerLabel), the hover text and the click.
local function CreateCornerButton(card, x, y)
	local button = CreateFrame("Button", nil, card, "BackdropTemplate")
	button:SetHeight(18)
	button:SetFrameLevel((card:GetFrameLevel() or 1) + 4)
	button:SetBackdrop(TILE_BACKDROP)
	button:SetBackdropColor(0.06, 0.06, 0.08, 0.6)
	button:SetBackdropBorderColor(1, 1, 1, 0.12)
	button:SetPoint("TOPRIGHT", card, "TOPRIGHT", x or -10, y or -6)
	button.text = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	button.text:SetPoint("LEFT", 9, 0)
	button.text:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
	button.hover = button:CreateTexture(nil, "HIGHLIGHT")
	button.hover:SetAllPoints(button)
	button.hover:SetColorTexture(1, 1, 1, 0.09)
	button:EnableMouse(true)
	button:RegisterForClicks("LeftButtonUp")
	return button
end

-- Sets a corner button's label and widens it to fit. A button carrying its own
-- text font string (one from CreateCornerButton) is resized to the label; a
-- template button puts it through its own SetText, which cannot report a width,
-- so it keeps the size it was given. Both are accepted on purpose - mixing the
-- two up once cost a whole page build.
local function SetCornerLabel(button, text)
	if button.text then
		button.text:SetText(text)
		button:SetWidth(button.text:GetStringWidth() + 18)
		return
	end
	button:SetText(text)
end

-- One item's own tooltip, exactly as the game draws it: name, quality, stats
-- and all. The id is tried first, then the name, because a mail invoice names
-- its item but carries no id, and the client's spelling may differ in a
-- capital or an apostrophe. When neither resolves - an item the client has
-- never had in its cache - the name is shown with a line saying why. `extra`
-- is an optional list of { text, color } lines added under the item, for a
-- tile that also has figures of its own to state.
function ns.ItemTooltip(owner, name, itemID, extra)
	if not name then
		return
	end
	GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
	local link
	if itemID and type(ns.ItemInfo) == "function" then
		local _, found = ns.ItemInfo(itemID)
		link = found
	end
	if not link and type(ns.ItemInfoByName) == "function" then
		local _, found = ns.ItemInfoByName(name)
		link = found
	end
	local shown = false
	if link and GameTooltip.SetHyperlink then
		shown = pcall(GameTooltip.SetHyperlink, GameTooltip, link)
	end
	if not shown then
		local quality = ItemQuality({ name = name, id = itemID })
		local color = QUALITY_COLORS[quality] or { 1, 1, 1 }
		GameTooltip:AddLine(name, color[1], color[2], color[3])
	end
	if extra and #extra > 0 then
		GameTooltip:AddLine(" ")
		for index = 1, #extra do
			local line = extra[index]
			local color = line.color or { 1, 1, 1 }
			GameTooltip:AddLine(line.text, color[1], color[2], color[3], true)
		end
	end
	GameTooltip:Show()
end

-- Handed to every page file; see Tally.toc for the load order.
ns.ApplyTallyIcon, ns.CreateIconButton = ApplyTallyIcon, CreateIconButton
ns.CreateTile, ns.SetTile, ns.CreateTileRow = CreateTile, SetTile, CreateTileRow
ns.DisplayChar, ns.PercentText = DisplayChar, PercentText
ns.SessionTileText, ns.ReadPlayerXP = SessionTileText, ReadPlayerXP
ns.QualityCode, ns.ItemQuality = QualityCode, ItemQuality
ns.SortedCounts = SortedCounts
ns.SortedCategories, ns.ShortWhen = SortedCategories, ShortWhen
ns.CreateListCard, ns.EnsureRowLine = CreateListCard, EnsureRowLine
ns.SetRowColor, ns.CutRowText = SetRowColor, CutRowText
ns.CutTextToWidth = CutTextToWidth
ns.FillCardRows, ns.ShowCardText = FillCardRows, ShowCardText
ns.AddCardTitleNote, ns.CreateInfoButton = AddCardTitleNote, CreateInfoButton
ns.LayoutLegend, ns.AddPageNote = LayoutLegend, AddPageNote
ns.MakeCardScrollable, ns.CreateCornerButton = MakeCardScrollable, CreateCornerButton
ns.AddCardScrollbar = AddCardScrollbar
ns.SetCornerLabel = SetCornerLabel
ns.QUALITY_NAMES, ns.QUALITY_COLORS = QUALITY_NAMES, QUALITY_COLORS
ns.ROW_STEP, ns.TALL_ROW_STEP = ROW_STEP, TALL_ROW_STEP
ns.ROW_DIM, ns.ROW_DETAIL_DIM = ROW_DIM, ROW_DETAIL_DIM
ns.CATEGORY_HEAD_COLOR = CATEGORY_HEAD_COLOR
