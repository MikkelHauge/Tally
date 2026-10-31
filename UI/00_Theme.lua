-- Tally - colours, sizes and the small formatters every page uses.
--
-- Nothing here reads saved data or touches a frame: constants and pure
-- formatting, so every other UI file can call it safely.
local addonName, ns = ...
local ACCENT = { 1.0, 0.72, 0.25 }

-- The book icon: a file ID on clients that accept one, and the texture
-- path to fall back to.
local ICON_FILE_ID = 133739
local ICON_PATH = "Interface\\Icons\\INV_Misc_Book_09"

-- Window metrics. The overview shows four rows of four tiles (TILE_WIDTH by
-- TILE_HEIGHT, TILE_GAP apart) above a full-width card.
local WINDOW_WIDTH, WINDOW_HEIGHT = 760, 580
local TILE_WIDTH = 177
local TILE_HEIGHT = 70
local TILE_GAP = 8
local ROW_START = -48

local TILE_BACKDROP = {
	bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
	edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
	tile = true,
	tileSize = 16,
	edgeSize = 16,
	insets = { left = 4, right = 4, top = 4, bottom = 4 },
}

local VALUE_COLOR = { 0.95, 0.95, 0.95 }
local GREEN = { 0.25, 0.85, 0.25 }
local RED = { 1.0, 0.42, 0.42 }
local AMBER = { 1.0, 0.72, 0.25 }

-- A card title's grey, and the same grey as an escape code for a title that
-- mixes in a class colour: a plain "|r" would leave the rest of the title in
-- the colour of the line it is drawn on rather than the card's grey.
local CARD_TITLE_DIM = { 0.62, 0.62, 0.62 }
local CARD_TITLE_DIM_CODE = string.format("|cff%02x%02x%02x",
	math.floor(CARD_TITLE_DIM[1] * 255 + 0.5),
	math.floor(CARD_TITLE_DIM[2] * 255 + 0.5),
	math.floor(CARD_TITLE_DIM[3] * 255 + 0.5))

local CATEGORY_LABELS = {
	loot = "loot",
	quest = "quests",
	vendor = "vendors",
	training = "training",
	mail = "mail",
	trade = "trade",
	auction = "auction",
	repair = "repairs",
}

-- "|cff68ccff" for the character's class, or nil when the client has no
-- class colours table.
local function ClassColorCode(classFile)
	local classColor = classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
	if not classColor then
		return nil
	end
	local r, g, b
	if classColor.GetRGB then
		r, g, b = classColor:GetRGB()
	else
		r, g, b = classColor.r, classColor.g, classColor.b
	end
	if not r or not g or not b then
		return nil
	end
	return string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
end

-- Class colour for a character record as plain rgb, for swatches, bars and
-- tooltip lines. Falls back to near-white when the class is unknown.
local function CharColor(char)
	local info = char and char.classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[char.classFile]
	if not info then
		return { 0.9, 0.9, 0.9 }
	end
	if info.GetRGB then
		local r, g, b = info:GetRGB()
		if r then
			return { r, g, b }
		end
	end
	return { info.r or 0.9, info.g or 0.9, info.b or 0.9 }
end

-- "|cffrrggbb" for an rgb table, so a coloured line can be built without
-- repeating the escape format in every view.
local function ColorMarkup(rgb)
	return string.format("|cff%02x%02x%02x",
		math.floor((rgb[1] or 1) * 255 + 0.5),
		math.floor((rgb[2] or 1) * 255 + 0.5),
		math.floor((rgb[3] or 1) * 255 + 0.5))
end

local function SumBucket(bucket)
	local total = 0
	for _, value in pairs(bucket or {}) do
		total = total + value
	end
	return total
end

-- The biggest categories of a gold bucket as "name value · name value".
local function TopCategoryText(bucket, limit)
	local list = {}
	for key, value in pairs(bucket or {}) do
		list[#list + 1] = { name = CATEGORY_LABELS[key] or key, value = value }
	end
	table.sort(list, function(a, b)
		return a.value > b.value
	end)
	local parts = {}
	for index = 1, math.min(#list, limit or 3) do
		parts[#parts + 1] = list[index].name.." "..ns.MoneyColored(list[index].value)
	end
	return table.concat(parts, " · ")
end

-- The same categories by name only, for a tile that has room to say what was
-- spent on but not what each part cost.
local function CategoryNames(bucket, limit)
	local list = {}
	for key, value in pairs(bucket or {}) do
		list[#list + 1] = { name = CATEGORY_LABELS[key] or key, value = value }
	end
	table.sort(list, function(a, b)
		return a.value > b.value
	end)
	local parts = {}
	for index = 1, math.min(#list, limit or 3) do
		parts[#parts + 1] = list[index].name
	end
	return table.concat(parts, ", ")
end

local function TopDeathZone(char)
	local bestName, bestCount
	for name, count in pairs(char.combat.deathsByZone or {}) do
		if not bestCount or count > bestCount then
			bestName, bestCount = name, count
		end
	end
	if not bestName then
		return "none yet"
	end
	return bestName.." x"..bestCount
end

-- Handed to every page file; see Tally.toc for the load order.
ns.ACCENT, ns.WINDOW_WIDTH, ns.WINDOW_HEIGHT = ACCENT, WINDOW_WIDTH, WINDOW_HEIGHT
ns.ICON_FILE_ID, ns.ICON_PATH = ICON_FILE_ID, ICON_PATH
ns.TILE_WIDTH, ns.TILE_HEIGHT, ns.TILE_GAP, ns.ROW_START = TILE_WIDTH, TILE_HEIGHT, TILE_GAP, ROW_START
ns.TILE_BACKDROP = TILE_BACKDROP
ns.VALUE_COLOR, ns.GREEN, ns.RED, ns.AMBER = VALUE_COLOR, GREEN, RED, AMBER
ns.CARD_TITLE_DIM, ns.CARD_TITLE_DIM_CODE = CARD_TITLE_DIM, CARD_TITLE_DIM_CODE
ns.CATEGORY_LABELS = CATEGORY_LABELS
ns.ClassColorCode, ns.CharColor = ClassColorCode, CharColor
ns.ColorMarkup = ColorMarkup
ns.SumBucket, ns.TopCategoryText, ns.CategoryNames = SumBucket, TopCategoryText, CategoryNames
ns.TopDeathZone = TopDeathZone
