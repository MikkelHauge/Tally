-- Tally - shared row interaction and graph helpers.
--
-- A card whose rows are not mouse-enabled finds the row under the cursor
-- here, and the same place renders the row's tooltip. The cooldown bar
-- animation and the Texture:SetRotation probe are shared by the pages that
-- draw bars and lines. Keeping these out of the Economy page means Combat
-- and Total do not have to depend on it.
local addonName, ns = ...

local ACCENT, VALUE_COLOR, ROW_DIM, ROW_STEP, TALL_ROW_STEP, QUALITY_COLORS =
	ns.ACCENT, ns.VALUE_COLOR, ns.ROW_DIM, ns.ROW_STEP, ns.TALL_ROW_STEP, ns.QUALITY_COLORS

local RECIPE_ROW_TOP = 30    -- the first row starts this far below the top

-- Cached probe for Texture:SetRotation, which some clients lack; the graphs
-- draw a step connection when it is missing. The cache lives on the view's
-- own widget table, so the two graphs probe once each.
local function CanRotate(plot, store)
	if not plot then
		return false
	end
	if store.canRotate == nil then
		local probe = plot:CreateTexture(nil, "BACKGROUND")
		store.canRotate = (probe.SetRotation ~= nil)
		if store.canRotate then
			probe:Hide()
		end
	end
	return store.canRotate
end

-- The card's hover and its click both need the row under the cursor. Its
-- rows are not mouse-enabled - that would take the card's wheel and its
-- window drag - so the card works the row out from the cursor position: the
-- first row starts RECIPE_ROW_TOP below the card's top and they carry on
-- ROW_STEP apart. Returns the row frame with a tip, or nil.
local function RowAtCursor(card)
	if not (card:IsShown() and not card.hoverSuppressed and card:IsMouseOver()) then
		return nil
	end
	local left, top = card:GetLeft(), card:GetTop()
	if not (left and top) then
		return nil
	end
	local scale = card:GetEffectiveScale()
	local cursorX, cursorY = GetCursorPosition()
	local relY = top - cursorY / scale
	local relX = cursorX / scale - left
	if relY < RECIPE_ROW_TOP + 2 or relX < 8 or relX > (card:GetWidth() or 0) - 8 then
		return nil
	end
	-- Tall cards (the level-ups list) are stepped further apart than the
	-- short ones; the card knows which it is from the rows it drew.
	local step = card.rowStep or ((card.rowTall and (TALL_ROW_STEP or 27)) or ROW_STEP)
	local rowIndex = math.floor((relY - RECIPE_ROW_TOP) / step) + 1
	local row = card.rowLines and card.rowLines[rowIndex]
	if row and row:IsShown() and (row.tip or row.click) then
		return row
	end
	return nil
end

-- Shows the tooltip for the row under the cursor. Each drawn row carries the
-- tip table FillCardRows put there, and the tooltip is rebuilt only when the
-- hovered row changes, so a card's once-a-second redraw does not flicker it.
-- A tip is either a recipe (kind = "recipe", with its reagents) or a note
-- (kind = "note", with a title, coloured lines and a closing remark).
local function RowHoverTick(card)
	local row = RowAtCursor(card)
	local tip = row and row.tip
	-- Keyed on what the tooltip is built from, so the per-second redraw does
	-- not rebuild an unchanged one, and two professions' recipes of the same
	-- name are still told apart.
	local key
	if tip then
		-- A tip may carry its own key: the session list uses one so two
		-- sessions on the same day are still told apart, and so the open
		-- session's tooltip follows its clock.
		key = tip.key or (tostring(tip.kind or "recipe").."|"..tostring(tip.name or tip.title or "").."|"..tostring(tip.recipeID or tip.spellID or ""))
	end
	if key == card.hoverKey then
		return
	end
	card.hoverKey = key
	if not tip then
		if GameTooltip:IsOwned(card) then
			GameTooltip:Hide()
		end
		return
	end
	if tip.kind == "spell" then
		-- What the game itself says about this aura, read while it was on the
		-- character (the aura tooltip's own data, not the spell's entry - the
		-- spell entry carries the spellbook wording and the cast details).
		GameTooltip:SetOwner(card, "ANCHOR_CURSOR")
		if tip.description then
			GameTooltip:AddLine(tip.name, 1, 1, 1)
			GameTooltip:AddLine(tip.description, 0.85, 0.85, 0.85, true)
		elseif tip.spellID and GameTooltip.SetHyperlink and pcall(GameTooltip.SetHyperlink, GameTooltip, "spell:"..tip.spellID) then
			-- The aura's own words are not known yet - it has not been on the
			-- character since this was added, or the client would not give them
			-- - so the spell's entry stands in, with a line saying which it is.
			-- A description in the hand beats an apology.
			GameTooltip:AddLine("Tally has not read this aura's own text, so this is the spell's entry.", 0.7, 0.7, 0.7, true)
		else
			GameTooltip:AddLine(tip.name, 1, 1, 1)
			GameTooltip:AddLine("Tally has no description for this one: its text is read while the aura is on the character, and that has not happened yet.", 0.7, 0.7, 0.7, true)
		end
		GameTooltip:AddLine(" ")
		GameTooltip:AddLine("Tally: gained "..ns.FormatNumber(tip.count or 0)..((tip.count == 1) and " time" or " times")..", "..ns.FormatDuration(tip.seconds or 0, true).." in total", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:Show()
		return
	end
	if tip.kind == "item" then
		ns.ItemTooltip(card, tip.name, tip.id, tip.extra)
		return
	end
	if tip.kind == "note" then
		GameTooltip:SetOwner(card, "ANCHOR_CURSOR")
		GameTooltip:AddLine(tip.title, ACCENT[1], ACCENT[2], ACCENT[3], true)
		local lines = tip.lines or {}
		for index = 1, #lines do
			local line = lines[index]
			local color = line.color or VALUE_COLOR
			GameTooltip:AddLine(line.text, color[1], color[2], color[3], true)
		end
		if tip.note then
			GameTooltip:AddLine(tip.note, 0.7, 0.7, 0.7, true)
		end
		GameTooltip:Show()
		return
	end
	local color = QUALITY_COLORS[tip.quality] or ROW_DIM
	GameTooltip:SetOwner(card, "ANCHOR_CURSOR")
	GameTooltip:AddLine(tip.name, color[1], color[2], color[3])
	if tip.itemID then
		local itemName, itemLink = ns.ItemInfo(tip.itemID)
		if itemName and itemName ~= tip.name then
			GameTooltip:AddLine(itemLink or itemName, 0.7, 0.7, 0.7)
		end
	end
	GameTooltip:AddLine(" ")
	GameTooltip:AddLine("Reagents", ACCENT[1], ACCENT[2], ACCENT[3])
	local reagents = tip.recipeID and ns.professions.RecipeReagents(tip.recipeID) or nil
	if reagents then
		for reagentIndex = 1, #reagents do
			local reagent = reagents[reagentIndex]
			local name, link = ns.ItemInfo(reagent.itemID)
			GameTooltip:AddLine((link or name or ("item "..reagent.itemID.." (not cached)")).." x"..reagent.count, 1, 1, 1)
		end
	elseif tip.recipeID then
		GameTooltip:AddLine("The game did not name this recipe's reagents.", 0.7, 0.7, 0.7, true)
	else
		GameTooltip:AddLine("No recipe id was read for this one, so its reagents are not known.", 0.7, 0.7, 0.7, true)
	end
	-- What a click will do, in the tooltip rather than in chat: the client's
	-- profession window can only ever be the playing character's.
	if ns.IsViewing() then
		GameTooltip:AddLine("This recipe belongs to another character.", 0.7, 0.7, 0.7, true)
	elseif tip.recipeID and tip.profession then
		GameTooltip:AddLine("Click to show this recipe in the game's own profession window.", 0.7, 0.7, 0.7, true)
	else
		GameTooltip:AddLine("Tally has no id for this one yet, so a click cannot open it.", 0.7, 0.7, 0.7, true)
	end
	GameTooltip:Show()
end

-- The bar's colour walks from red, through orange and yellow, to green as the
-- wait runs out, so a row can be read at a glance without the number. The
-- stops are evenly spaced along the wait.
local BAR_COLORS = {
	{ 0.90, 0.16, 0.16 },   -- full: the wait has just begun
	{ 1.00, 0.55, 0.10 },   -- orange
	{ 0.95, 0.88, 0.20 },   -- yellow
	{ 0.28, 0.85, 0.35 },   -- nearly done
}

local function BarColor(fraction)
	-- fraction is the share of the wait still to run: 1 at the start, 0 when
	-- it is ready.
	local position = (1 - fraction) * (#BAR_COLORS - 1) + 1
	local index = math.min(#BAR_COLORS - 1, math.floor(position))
	local t = position - index
	local first, second = BAR_COLORS[index], BAR_COLORS[index + 1]
	return first[1] + (second[1] - first[1]) * t,
		first[2] + (second[2] - first[2]) * t,
		first[3] + (second[3] - first[3]) * t
end

-- Walks the cooldown bars left between the card's once-a-second redraws, so
-- a wait reads as a bar running down rather than a jump a second. Only the
-- rows FillCardRows gave a bar to are touched.
local function CooldownBarTick(card)
	local rows = card.rowLines
	if not rows then
		return
	end
	local width = (card:GetWidth() or 0) - 24
	local now = ns.Now()
	for index = 1, #rows do
		local row = rows[index]
		local bar = row:IsShown() and row.barData or nil
		if bar then
			local fraction = (bar.span and bar.span > 0) and ((bar.readyAt - now) / bar.span) or 0
			if fraction < 0 then
				fraction = 0
			elseif fraction > 1 then
				fraction = 1
			end
			row.barFill:SetWidth(math.max(0, math.floor(width * fraction + 0.5)))
			-- Half-transparent, so the row's own text stays readable over it.
			local red, green, blue = BarColor(fraction)
			row.barFill:SetColorTexture(red, green, blue, 0.6)
		end
	end
end

ns.CanRotate, ns.RowAtCursor = CanRotate, RowAtCursor
ns.RowHoverTick, ns.CooldownBarTick = RowHoverTick, CooldownBarTick
