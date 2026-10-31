-- Tally - the Combat tab's kills sub-view: creatures and zones.
local addonName, ns = ...

local ACCENT, SetTile, CreateTileRow, DisplayChar, CreateListCard, CATEGORY_HEAD_COLOR, FillScrollingLines, ShowCardText, AddCardTitleNote, MakeCardScrollable, CreateCornerButton, SetCornerLabel, RowHoverTick, CutRowText, ROW_DIM, combatWidgets =
	ns.ACCENT, ns.SetTile, ns.CreateTileRow, ns.DisplayChar, ns.CreateListCard, ns.CATEGORY_HEAD_COLOR, ns.FillScrollingLines, ns.ShowCardText, ns.AddCardTitleNote, ns.MakeCardScrollable, ns.CreateCornerButton, ns.SetCornerLabel, ns.RowHoverTick, ns.CutRowText, ns.ROW_DIM, ns.combatWidgets

-- The Kills tab's two lists share these orders: count both ways, then name.
local KILL_SORTS = { "most", "fewest", "az", "za" }

local function KillSortLabel(mode)
	if mode == "fewest" then
		return "fewest kills"
	end
	if mode == "az" then
		return "A-Z"
	end
	if mode == "za" then
		return "Z-A"
	end
	return "most kills"
end

local function NextKillSort(mode)
	for index = 1, #KILL_SORTS do
		if KILL_SORTS[index] == mode then
			return KILL_SORTS[(index % #KILL_SORTS) + 1]
		end
	end
	return KILL_SORTS[1]
end

local function SortedKillList(bucket, mode)
	local list = {}
	for name, count in pairs(bucket or {}) do
		list[#list + 1] = { name = name, count = count }
	end
	table.sort(list, function(a, b)
		if mode == "az" then
			return a.name < b.name
		end
		if mode == "za" then
			return a.name > b.name
		end
		if a.count ~= b.count then
			if mode == "fewest" then
				return a.count < b.count
			end
			return a.count > b.count
		end
		return a.name < b.name
	end)
	return list
end

local function KillAverage(value)
	if not value or value <= 0 then
		return "-"
	end
	return string.format("%.1f", value)
end

local function RefreshCombatKills()
	local tiles = combatWidgets.killsTiles
	local creatureCard = combatWidgets.killsCreature
	local zoneCard = combatWidgets.killsZone
	if not (tiles and tiles[1] and creatureCard and zoneCard) then
		return
	end
	local char = DisplayChar()
	if not char then
		for index = 1, #tiles do
			SetTile(tiles[index], "-", "")
		end
		ShowCardText(creatureCard, "No character selected.")
		ShowCardText(zoneCard, "")
		return
	end
	local combat = char.combat or {}
	local kills = combat.kills or 0
	local types = combat.killTypes or {}
	local session = char.sessions and char.sessions.current
	local sessionKills = (session and session.kills) or 0
	local killingSessions = combat.killSessions or 0
	local perSession = killingSessions > 0 and kills / killingSessions or nil
	local mostName, mostCount = nil, 0
	for name, count in pairs(types) do
		if count > mostCount or (count == mostCount and (not mostName or name < mostName)) then
			mostName, mostCount = name, count
		end
	end
	SetTile(tiles[1], ns.FormatNumber(kills),
		sessionKills > 0 and (ns.FormatNumber(sessionKills).." this session") or "none this session")
	if mostName then
		SetTile(tiles[2], ns.CutRowText(mostName, 18), "x"..ns.FormatNumber(mostCount))
	else
		SetTile(tiles[2], "-", "nothing killed yet")
	end
	SetTile(tiles[3], perSession and KillAverage(perSession) or "-",
		killingSessions > 0
			and (ns.FormatNumber(killingSessions)..(killingSessions == 1 and " killing session" or " killing sessions"))
			or "no killing sessions yet")
	local bestFight = combat.bestFight or 0
	if bestFight > 0 then
		SetTile(tiles[4], ns.FormatNumber(bestFight), ns.FormatDate(combat.bestFightAt or 0))
	else
		SetTile(tiles[4], "-", "no fight with a kill yet")
	end

	-- Zones. The stored totals are exact even when a creature row has been
	-- pruned; older records without the map fall back to the per-creature
	-- zones so nothing is invented.
	local selected = combatWidgets.killZone
	local zoneTotals = {}
	for zone, count in pairs(combat.killsByZone or {}) do
		if count > 0 then
			zoneTotals[zone] = count
		end
	end
	if next(zoneTotals) == nil then
		for _, info in pairs(combat.killInfo or {}) do
			for zone, count in pairs(info.zones or {}) do
				zoneTotals[zone] = (zoneTotals[zone] or 0) + count
			end
		end
	end
	if selected and not zoneTotals[selected] then
		selected = nil
		combatWidgets.killZone = nil
	end
	local counts = {}
	if selected then
		for name, info in pairs(combat.killInfo or {}) do
			local count = info.zones and info.zones[selected] or 0
			if count > 0 then
				counts[name] = count
			end
		end
	else
		for name, count in pairs(types) do
			counts[name] = count
		end
	end
	local creatureList = SortedKillList(counts, combatWidgets.killSort or "most")

	local creatureLines = {}
	local title = "Kills by creature"
	if selected then
		title = title.." - "..selected
	end
	creatureLines[#creatureLines + 1] = { left = "Creatures killed", leftColor = CATEGORY_HEAD_COLOR }
	if not ns.killSource then
		creatureLines[#creatureLines + 1] = { left = "Kills cannot be read on this client.", leftColor = ROW_DIM }
	elseif ns.killSource == "nameplate" then
		local shown = true
		if type(C_CVar) == "table" and type(C_CVar.GetCVarBool) == "function" then
			local ok, value = pcall(C_CVar.GetCVarBool, "nameplateShowEnemies")
			if ok then
				shown = value ~= false
			end
		end
		if not shown then
			creatureLines[#creatureLines + 1] = { left = "Enemy nameplates are off: kills can still count, but names may be missing.", leftColor = ROW_DIM }
		end
	end
	for index = 1, #creatureList do
		local row = creatureList[index]
		local info = combat.killInfo and combat.killInfo[row.name]
		local lines = {
			{ text = ns.FormatNumber(row.count)..(row.count == 1 and " kill" or " kills")..(selected and (" in "..selected) or "") },
		}
		if info and info.first then
			lines[#lines + 1] = { text = "First "..ns.FormatDateTime(info.first), color = ROW_DIM }
		end
		if info and info.last then
			lines[#lines + 1] = { text = "Last "..ns.FormatDateTime(info.last), color = ROW_DIM }
		end
		if info and info.zones then
			local zones = {}
			for zone, count in pairs(info.zones) do
				zones[#zones + 1] = { zone = zone, count = count }
			end
			table.sort(zones, function(a, b)
				if a.count ~= b.count then
					return a.count > b.count
				end
				return a.zone < b.zone
			end)
			for zoneIndex = 1, #zones do
				lines[#lines + 1] = {
					text = zones[zoneIndex].zone.."  x"..ns.FormatNumber(zones[zoneIndex].count),
					color = ROW_DIM,
				}
			end
		end
		if not info then
			lines[#lines + 1] = { text = "First, last and zone were not recorded for this creature.", color = ROW_DIM }
		end
		creatureLines[#creatureLines + 1] = {
			left = row.name,
			right = "x"..ns.FormatNumber(row.count),
			tip = {
				kind = "note",
				title = row.name,
				lines = lines,
				note = ns.killSource == "nameplate"
					and "World kills come from the game's kill events; inside instances, from experience lines and looted corpses." or nil,
				key = "kill|"..row.name.."|"..tostring(selected or ""),
			},
		}
	end
	if #creatureList == 0 then
		creatureLines[#creatureLines + 1] = {
			left = selected and "No creature names kept for this zone." or "No kills recorded yet.",
			leftColor = ROW_DIM,
		}
	end
	if FillScrollingLines(creatureCard, creatureLines, combatWidgets, "killCreatureOffset", title, 34) == 0 then
		ShowCardText(creatureCard, "No kills recorded yet.")
	end

	local zoneList = SortedKillList(zoneTotals, combatWidgets.killZoneSort or "most")
	local zoneLines = {}
	zoneLines[#zoneLines + 1] = {
		left = (selected and "" or "> ").."All zones",
		leftColor = selected and nil or ACCENT,
		right = "x"..ns.FormatNumber(kills),
		rightColor = selected and nil or ACCENT,
		tip = {
			kind = "note",
			title = "All zones",
			clear = true,
			lines = { { text = "Every creature, across every zone.", color = ROW_DIM } },
			key = "kill-zone-all",
		},
	}
	for index = 1, #zoneList do
		local row = zoneList[index]
		local chosen = (selected == row.name)
		zoneLines[#zoneLines + 1] = {
			left = (chosen and "> " or "")..row.name,
			leftColor = chosen and ACCENT or nil,
			right = "x"..ns.FormatNumber(row.count),
			rightColor = chosen and ACCENT or nil,
			tip = {
				kind = "note",
				title = row.name,
				zone = row.name,
				lines = {
					{ text = ns.FormatNumber(row.count)..(row.count == 1 and " kill" or " kills"), color = ROW_DIM },
					{ text = chosen and "Click again to show every zone." or "Click to show only creatures killed here.", color = ROW_DIM },
				},
				key = "kill-zone|"..row.name,
			},
		}
	end
	if #zoneList == 0 then
		zoneLines[#zoneLines + 1] = { left = "No zones with kills yet.", leftColor = ROW_DIM }
	end
	if FillScrollingLines(zoneCard, zoneLines, combatWidgets, "killZoneOffset", "Kills by zone", 30) == 0 then
		ShowCardText(zoneCard, "No zones with kills yet.")
	end
end

local function BuildCombatKills(kills)
	combatWidgets.killsTiles = {}
	combatWidgets.killSort = "most"
	combatWidgets.killZoneSort = "most"
	combatWidgets.killZone = nil
	CreateTileRow(kills, -4, { "Total kills", "Most killed", "Kills per session", "Best combat" }, combatWidgets.killsTiles, false)
	combatWidgets.killsCreature = CreateListCard(kills, 0, -88, 359, 372, "Kills by creature")
	combatWidgets.killsZone = CreateListCard(kills, 371, -88, 359, 372, "Kills by zone")
	AddCardTitleNote(combatWidgets.killsCreature, "Kills by creature",
		"One row per creature killed, with first and last kill and every zone; world kills come from the game's kill events and instance kills from experience lines and looted corpses. The order button sorts by kills or name.")
	AddCardTitleNote(combatWidgets.killsZone, "Kills by zone",
		"Kills per open-world zone. Click a zone to show only the creatures killed there, or All zones to clear the filter. The order button sorts by kills or name.")
	MakeCardScrollable(combatWidgets.killsCreature, combatWidgets, "killCreatureOffset", RefreshCombatKills)
	MakeCardScrollable(combatWidgets.killsZone, combatWidgets, "killZoneOffset", RefreshCombatKills)
	for _, card in ipairs({ combatWidgets.killsCreature, combatWidgets.killsZone }) do
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
	-- The zone rows are clickable: a click picks the zone whose creatures the
	-- creature list should show, and All zones clears it. The card itself reads
	-- the row under the cursor through the shared helper.
	combatWidgets.killsZone:EnableMouse(true)
	combatWidgets.killsZone:SetScript("OnMouseUp", function(self, button)
		if button ~= "LeftButton" or not ns.RowAtCursor then
			return
		end
		local row = ns.RowAtCursor(self)
		local tip = row and row.tip
		if not tip then
			return
		end
		if tip.clear then
			combatWidgets.killZone = nil
		elseif tip.zone then
			combatWidgets.killZone = (combatWidgets.killZone == tip.zone) and nil or tip.zone
		else
			return
		end
		combatWidgets.killCreatureOffset = 0
		ns.Trace("kill zone: "..tostring(combatWidgets.killZone or "all"))
		RefreshCombatKills()
	end)

	local creatureSort = CreateCornerButton(combatWidgets.killsCreature)
	SetCornerLabel(creatureSort, KillSortLabel(combatWidgets.killSort))
	creatureSort:SetScript("OnClick", function()
		combatWidgets.killSort = NextKillSort(combatWidgets.killSort)
		combatWidgets.killCreatureOffset = 0
		SetCornerLabel(creatureSort, KillSortLabel(combatWidgets.killSort))
		RefreshCombatKills()
	end)
	creatureSort:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("The order of the creature list", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to cycle: most kills, fewest kills, A-Z and Z-A. The wheel walks the rows in any order.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	creatureSort:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	local zoneSort = CreateCornerButton(combatWidgets.killsZone)
	SetCornerLabel(zoneSort, KillSortLabel(combatWidgets.killZoneSort))
	zoneSort:SetScript("OnClick", function()
		combatWidgets.killZoneSort = NextKillSort(combatWidgets.killZoneSort)
		combatWidgets.killZoneOffset = 0
		SetCornerLabel(zoneSort, KillSortLabel(combatWidgets.killZoneSort))
		RefreshCombatKills()
	end)
	zoneSort:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("The order of the zone list", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to cycle: most kills, fewest kills, A-Z and Z-A.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	zoneSort:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
end

ns.BuildCombatKills, ns.RefreshCombatKills = BuildCombatKills, RefreshCombatKills
