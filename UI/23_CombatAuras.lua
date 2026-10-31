-- Tally - the Combat tab's buffs and debuffs sub-view.
local addonName, ns = ...

local ACCENT, SetTile, CreateTileRow, DisplayChar, CreateListCard, FillScrollingLines, ShowCardText, AddCardTitleNote, MakeCardScrollable, CreateCornerButton, SetCornerLabel, RowHoverTick, combatWidgets =
	ns.ACCENT, ns.SetTile, ns.CreateTileRow, ns.DisplayChar, ns.CreateListCard, ns.FillScrollingLines, ns.ShowCardText, ns.AddCardTitleNote, ns.MakeCardScrollable, ns.CreateCornerButton, ns.SetCornerLabel, ns.RowHoverTick, ns.combatWidgets

-- The hover text for the two aura cards. Both say how the figures are made,
-- and that the group Tally works out for each aura is kept but not shown.
local BUFFS_NOTE = "Every buff Tally has watched on this character, with how often it came and how long it ran. Hover a row for the game's own spell tooltip; the order button sorts by time, times gained or name."
local DEBUFFS_NOTE = "Every debuff Tally has watched on this character, with how often it landed and how long it ran. Hover a row for the game's own spell tooltip; the order button sorts by time, times landed or name."

-- The orders the two aura cards can be listed in, and the short label their
-- buttons carry. They follow the sort buttons the other long lists have: the
-- time both ways, the times gained, and the names both ways.
local AURA_SORTS = { "time", "least", "gained", "az", "za" }

local function NextAuraSort(mode)
	for index = 1, #AURA_SORTS do
		if AURA_SORTS[index] == mode then
			return AURA_SORTS[index % #AURA_SORTS + 1]
		end
	end
	return AURA_SORTS[1]
end

local function AuraSortLabel(mode)
	if mode == "least" then
		return "least time"
	end
	if mode == "gained" then
		return "most gained"
	end
	if mode == "az" then
		return "A-Z"
	end
	if mode == "za" then
		return "Z-A"
	end
	return "most time"
end

-- One aura card: every aura Tally has watched on this character, one row each,
-- naming it, how often it was gained and how long it has run. The window is
-- scrolled like every other long list, and the order button walks the sorts
-- above. Each aura's stored group - the character's own class or racial
-- ability, a gathering ability, or anything else - is still recorded with the
-- aura, but is not shown: a name missing from Tally's built-in lists landed in
-- the wrong group, so the groups are held back until they can be trusted.
local function FillAuraCard(card, bucket, offsetField, title, earlier, mode)
	local names = {}
	for name in pairs(bucket or {}) do
		names[#names + 1] = name
	end
	local function Less(a, b)
		local one, two = bucket[a] or {}, bucket[b] or {}
		-- "az"/"za" order the names themselves.
		if mode == "az" or mode == "za" then
			if mode == "za" then
				return a > b
			end
			return a < b
		end
		if mode == "gained" then
			if (one.count or 0) == (two.count or 0) then
				return a < b
			end
			return (one.count or 0) > (two.count or 0)
		end
		if (one.seconds or 0) == (two.seconds or 0) then
			return a < b
		end
		if mode == "least" then
			return (one.seconds or 0) < (two.seconds or 0)
		end
		return (one.seconds or 0) > (two.seconds or 0)
	end
	table.sort(names, Less)
	local lines = {}
	for index = 1, #names do
		local name = names[index]
		local entry = bucket[name]
		lines[#lines + 1] = {
			left = name,
			mid = "x"..ns.FormatNumber(entry.count or 0),
			right = ns.FormatDuration(entry.seconds or 0, true),
			-- The hover hands over what the game itself said about this aura
			-- while it was on the character, with the spell id as a fallback for
			-- auras seen before that text was kept.
			tip = {
				kind = "spell",
				name = name,
				spellID = entry.spellID,
				description = entry.desc,
				descFrom = entry.descFrom,
				count = entry.count or 0,
				seconds = entry.seconds or 0,
			},
		}
	end
	if earlier and (earlier.names or 0) > 0 then
		-- The cap's fuse: the least-used auras folded into one honest total.
		lines[#lines + 1] = {
			left = ns.FormatNumber(earlier.names).." earlier "..string.lower(title),
			mid = "x"..ns.FormatNumber(earlier.count or 0),
			right = ns.FormatDuration(earlier.seconds or 0, true),
		}
	end
	if FillScrollingLines(card, lines, combatWidgets, offsetField, title, 30) == 0 then
		ShowCardText(card, "No "..string.lower(title).." recorded yet - they are counted while they are on the character.")
	end
end

local function RefreshCombatAuras()
	if not combatWidgets.buffs then
		return
	end
	local char = DisplayChar()
	local tiles = combatWidgets.aurasTiles
	if not char then
		for index = 1, #tiles do
			SetTile(tiles[index], "-", "")
		end
		ShowCardText(combatWidgets.buffs, "No data yet.")
		ShowCardText(combatWidgets.debuffs, "No data yet.")
		return
	end
	local auras = char.auras or {}
	local camp = auras.camp or {}
	SetTile(tiles[1], ns.FormatDuration(camp.seconds or 0), "welcoming fire time")
	SetTile(tiles[2], ns.FormatNumber(camp.visits or 0), camp.visits == 1 and "visit to the fire" or "visits to the fire")
	SetTile(tiles[3], ns.FormatNumber(camp.benefits or 0), "times the benefits buff arrived")
	local auraCount = ns.CountTable(auras.buffs) + ns.CountTable(auras.debuffs)
	auraCount = auraCount + ((auras.earlierBuffs and auras.earlierBuffs.names) or 0) + ((auras.earlierDebuffs and auras.earlierDebuffs.names) or 0)
	SetTile(tiles[4], ns.FormatNumber(auraCount), "distinct buffs and debuffs")
	FillAuraCard(combatWidgets.buffs, auras.buffs, "buffScrollOffset", "Buffs", auras.earlierBuffs, combatWidgets.buffSort)
	FillAuraCard(combatWidgets.debuffs, auras.debuffs, "debuffScrollOffset", "Debuffs", auras.earlierDebuffs, combatWidgets.debuffSort)
	if combatWidgets.buffSortButton then
		SetCornerLabel(combatWidgets.buffSortButton, AuraSortLabel(combatWidgets.buffSort))
	end
	if combatWidgets.debuffSortButton then
		SetCornerLabel(combatWidgets.debuffSortButton, AuraSortLabel(combatWidgets.debuffSort))
	end
end

local function BuildCombatAuras(auras)
	CreateTileRow(auras, -4, { "Campfire time", "Campfire visits", "Camp benefits", "Auras tracked" }, combatWidgets.aurasTiles, false)
	combatWidgets.buffs = CreateListCard(auras, 0, -88, 359, 372, "Buffs")
	combatWidgets.debuffs = CreateListCard(auras, 371, -88, 359, 372, "Debuffs")
	AddCardTitleNote(combatWidgets.buffs, "Buffs", BUFFS_NOTE)
	AddCardTitleNote(combatWidgets.debuffs, "Debuffs", DEBUFFS_NOTE)
	MakeCardScrollable(combatWidgets.buffs, combatWidgets, "buffScrollOffset", function() ns.RefreshCombat() end)
	MakeCardScrollable(combatWidgets.debuffs, combatWidgets, "debuffScrollOffset", function() ns.RefreshCombat() end)

	-- One order button per aura card, the same widget the other long lists
	-- have: most time, least time, most gained, A-Z, Z-A.
	local function AddAuraSortButton(card, modeField, offsetField, buttonField)
		combatWidgets[modeField] = "time"
		local button = CreateCornerButton(card)
		SetCornerLabel(button, AuraSortLabel(combatWidgets[modeField]))
		button:SetScript("OnClick", function()
			combatWidgets[modeField] = NextAuraSort(combatWidgets[modeField])
			combatWidgets[offsetField] = 0
			ns.Trace("aura order: "..combatWidgets[modeField])
			ns.RefreshCombat()
		end)
		button:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
			GameTooltip:AddLine("The order of the list", ACCENT[1], ACCENT[2], ACCENT[3])
			GameTooltip:AddLine("Click to cycle: most time first, least time first, most times gained, A-Z and Z-A. The wheel walks the rows in any order.", 1, 1, 1, true)
			GameTooltip:Show()
		end)
		button:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
		combatWidgets[buttonField] = button
	end
	AddAuraSortButton(combatWidgets.buffs, "buffSort", "buffScrollOffset", "buffSortButton")
	AddAuraSortButton(combatWidgets.debuffs, "debuffSort", "debuffScrollOffset", "debuffSortButton")

	-- Hovering a row shows the client's own spell tooltip for that aura (the
	-- card rows are not mouse-enabled, so the card tracks the cursor itself).
	for _, card in ipairs({ combatWidgets.buffs, combatWidgets.debuffs }) do
		card:SetScript("OnUpdate", function()
			RowHoverTick(card)
		end)
		card:SetScript("OnLeave", function()
			card.hoverKey = nil
			if GameTooltip:IsOwned(card) then
				GameTooltip:Hide()
			end
		end)
	end
end

ns.BuildCombatAuras, ns.RefreshCombatAuras = BuildCombatAuras, RefreshCombatAuras
