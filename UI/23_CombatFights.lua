-- Tally - the Combat tab's fights and deaths sub-view.
local addonName, ns = ...

local ACCENT, SetTile, CreateTileRow, DisplayChar, PercentText, CreateListCard, CATEGORY_HEAD_COLOR, FillCardRows, ShowCardText, AddCardTitleNote, FillScrollingLines, MakeCardScrollable, CreateCornerButton, SetCornerLabel, ROW_DIM, combatWidgets =
	ns.ACCENT, ns.SetTile, ns.CreateTileRow, ns.DisplayChar, ns.PercentText, ns.CreateListCard, ns.CATEGORY_HEAD_COLOR, ns.FillCardRows, ns.ShowCardText, ns.AddCardTitleNote, ns.FillScrollingLines, ns.MakeCardScrollable, ns.CreateCornerButton, ns.SetCornerLabel, ns.ROW_DIM, ns.combatWidgets

-- The orders the deaths-by-zone card can be listed in, and the short label
-- its button carries for each. It cycles them, like the records card's.
local DEATH_SORTS = { "most", "least", "az", "za" }

local function NextDeathSort(mode)
	for index = 1, #DEATH_SORTS do
		if DEATH_SORTS[index] == mode then
			return DEATH_SORTS[index % #DEATH_SORTS + 1]
		end
	end
	return DEATH_SORTS[1]
end

local function DeathSortLabel(mode)
	if mode == "least" then
		return "least"
	end
	if mode == "az" then
		return "A-Z"
	end
	if mode == "za" then
		return "Z-A"
	end
	return "most"
end

local function KillAverage(value)
	if not value or value <= 0 then
		return "-"
	end
	return string.format("%.1f", value)
end

-- The combat records that used to sit at the top of the Kills sub-view. They
-- belong beside the time breakdown: both describe the fighting itself, while
-- the Kills tab is the per-creature and per-zone lists.
local function AppendKillRecords(entries, combat, fights, tracked)
	local kills = combat.kills or 0
	local fightsSince = math.max(0, fights - (combat.killBaseFights or 0))
	local perFight = (kills > 0 and fightsSince > 0) and (kills / fightsSince) or nil
	local bestFight = combat.bestFight or 0
	local bestLine = bestFight > 0
		and ("x"..ns.FormatNumber(bestFight)..(combat.bestFightAt and ("  ·  "..ns.FormatDate(combat.bestFightAt)) or ""))
		or "none yet"
	entries[#entries + 1] = { divider = true }
	entries[#entries + 1] = { left = "Records", leftColor = CATEGORY_HEAD_COLOR }
	entries[#entries + 1] = {
		left = "Best combat",
		right = bestLine,
		tip = {
			kind = "note",
			title = "Best combat",
			lines = {
				{ text = bestFight > 0 and (ns.FormatNumber(bestFight).." kills in one fight") or "No fight with a kill yet." },
				{ text = combat.bestFightAt and ("When "..ns.FormatDateTime(combat.bestFightAt)) or "When not read", color = ROW_DIM },
				{ text = combat.bestFightZone and ("Zone "..combat.bestFightZone) or "Zone not read", color = ROW_DIM },
			},
			key = "kill-record-combat",
		},
	}
	entries[#entries + 1] = {
		left = "Average per fight",
		right = perFight and KillAverage(perFight) or "-",
		tip = {
			kind = "note",
			title = "Average per fight",
			lines = {
				{ text = perFight and (KillAverage(perFight).." kills per fight") or "No fight since kill tracking began." },
				{ text = ns.FormatNumber(fightsSince)..(fightsSince == 1 and " fight" or " fights").." counted since then", color = ROW_DIM },
			},
			key = "kill-record-fight",
		},
	}
	local best10 = combat.best10 or 0
	entries[#entries + 1] = {
		left = "Best 10 minutes",
		right = best10 > 0
			and ("x"..ns.FormatNumber(best10)..(combat.best10At and ("  ·  "..ns.FormatDate(combat.best10At)) or ""))
			or "none yet",
		tip = {
			kind = "note",
			title = "Best 10 minutes",
			lines = {
				{ text = best10 > 0 and (ns.FormatNumber(best10).." kills in ten minutes") or "No ten-minute window has a kill yet." },
				{ text = combat.best10At and ("When "..ns.FormatDateTime(combat.best10At)) or "When not read", color = ROW_DIM },
			},
			key = "kill-record-ten",
		},
	}
	local trackedSince = math.max(0, (tracked or 0) - (combat.killBaseTracked or 0))
	local combatSince = math.max(0, (combat.combatSeconds or 0) - (combat.killBaseCombat or 0))
	local perTracked = (kills > 0 and trackedSince > 0) and (kills / trackedSince * 600) or nil
	local perCombat = (kills > 0 and combatSince > 0) and (kills / combatSince * 600) or nil
	local rate = "-"
	if perTracked and perCombat then
		rate = KillAverage(perTracked).." tracked  ·  "..KillAverage(perCombat).." in combat"
	elseif perTracked then
		rate = KillAverage(perTracked).." tracked"
	elseif perCombat then
		rate = KillAverage(perCombat).." in combat"
	end
	entries[#entries + 1] = {
		left = "Per 10 minutes",
		right = rate,
		tip = {
			kind = "note",
			title = "Kills per 10 minutes",
			lines = {
				{ text = "Tracked time "..(perTracked and (KillAverage(perTracked).." kills per 10 minutes") or "not read"), color = ROW_DIM },
				{ text = "Combat time "..(perCombat and (KillAverage(perCombat).." kills per 10 minutes") or "not read"), color = ROW_DIM },
			},
			key = "kill-record-rate",
		},
	}
end

local function RefreshCombatFights()
	if not combatWidgets.first then
		return
	end
	local char = DisplayChar()
	if not char then
		for index = 1, #combatWidgets.tiles do
			SetTile(combatWidgets.tiles[index], "-", "")
		end
		ShowCardText(combatWidgets.first, "No data yet.")
		ShowCardText(combatWidgets.deaths, "No data yet.")
		return
	end

	-- Fights and the in/out-of-combat split come from the
	-- entering/leaving-combat events. Kills come from the combat log where it
	-- is usable, and otherwise from visible creature nameplates.
	local combat = char.combat
	local tracked = char.tracked
	local fights = combat.fights or 0
	local inCombat = math.floor((combat.combatSeconds or 0) + 0.5)
	if inCombat > tracked then
		inCombat = tracked
	end
	local outOfCombat = math.max(0, tracked - inCombat)
	local dead = math.max(0, tracked - char.alive)

	SetTile(combatWidgets.tiles[1], ns.FormatNumber(fights), fights > 0 and ("avg "..ns.FormatDuration(math.floor(inCombat / fights + 0.5), true).." each") or "no fights yet")
	SetTile(combatWidgets.tiles[2], ns.FormatNumber(combat.deaths), "since "..ns.FormatDate(char.created))
	local inCombatSub = PercentText(inCombat, tracked).." of tracked time"
	if UnitAffectingCombat and UnitAffectingCombat("player") then
		inCombatSub = "in combat right now"
	end
	SetTile(combatWidgets.tiles[3], ns.FormatDuration(inCombat), inCombatSub)
	SetTile(combatWidgets.tiles[4], ns.FormatDuration(char.alive), PercentText(char.alive, tracked).." of tracked time")

	-- The most recent deaths, newest first: zone on the left, date and time on
	-- the right. Fifty are kept and the first is never dropped; ten are listed
	-- on the time-breakdown card, and the first death is named when it is
	-- older than those. The killer only ever comes from the combat log, so on
	-- a client without it the line is just the zone.
	local deathLog = combat.deathLog or {}
	if #deathLog == 0 and combat.lastDeath then
		-- Records written before the log was kept still hold the most recent
		-- death, which is a real reading and is listed as such.
		deathLog = { combat.lastDeath }
	end
	local shownDeaths = 10
	local recentDeaths = {}
	local function DeathLine(death, prefix)
		local left = (prefix or "")..(death.zone or "?")
		if death.killer then
			left = left.."  ·  "..death.killer
		end
		recentDeaths[#recentDeaths + 1] = {
			left = left,
			right = ns.FormatDateTime(death.at),
		}
	end
	for index = #deathLog, math.max(1, #deathLog - shownDeaths + 1), -1 do
		DeathLine(deathLog[index], nil)
	end
	if #deathLog > shownDeaths then
		-- The first death is kept for good, so it is named even when it is
		-- older than the window above.
		DeathLine(deathLog[1], "first death: ")
	end
	local function AppendRecentDeaths(entries)
		if #recentDeaths == 0 then
			return
		end
		entries[#entries + 1] = { divider = true }
		entries[#entries + 1] = { left = "Recent deaths", leftColor = CATEGORY_HEAD_COLOR }
		for index = 1, #recentDeaths do
			entries[#entries + 1] = recentDeaths[index]
		end
	end

	combatWidgets.first.title:SetText("Time breakdown")
	combatWidgets.first.noteTitle = "Time breakdown"
	-- Two-column rows: the label on the left, duration and percentage on
	-- the right. Only the rows that add up to tracked time carry a
	-- percentage, so the shares above the AFK line total 100%.
	--
	-- AFK is not a fourth slice: a flagged player is still alive or dead,
	-- so its time is already inside the four rows above. It is listed as
	-- a duration with no percentage of its own, because a share there
	-- would make the column look like it should be summed.
	local afk = char.afk or 0
	local breakdown = {
		{ left = "In combat", right = ns.FormatDuration(inCombat).."  ·  "..PercentText(inCombat, tracked) },
		{ left = "Out of combat", right = ns.FormatDuration(outOfCombat).."  ·  "..PercentText(outOfCombat, tracked) },
		{ left = "Alive", right = ns.FormatDuration(char.alive).."  ·  "..PercentText(char.alive, tracked) },
		{ left = "Dead or ghost", right = ns.FormatDuration(dead).."  ·  "..PercentText(dead, tracked) },
	}
	if afk > 0 then
		breakdown[#breakdown + 1] = { left = "" }
		breakdown[#breakdown + 1] = {
			left = ns.db.settings.excludeAfk and "AFK, outside the time above" or "AFK, within the time above",
			right = ns.FormatDuration(afk),
			leftColor = CATEGORY_HEAD_COLOR,
		}
	end
	breakdown[#breakdown + 1] = { left = "" }
	breakdown[#breakdown + 1] = { left = "Fights", right = ns.FormatNumber(fights)..(fights > 0 and ("  ·  average "..ns.FormatDuration(math.floor(inCombat / fights + 0.5), true)) or "") }
	breakdown[#breakdown + 1] = { left = "Deaths", right = ns.FormatNumber(combat.deaths) }
	AppendKillRecords(breakdown, combat, fights, tracked)
	AppendRecentDeaths(breakdown)
	FillCardRows(combatWidgets.first, breakdown, 50)

	-- The deaths card is the per-zone count, every zone that has one, in a
	-- scrolling window; the last few deaths themselves are listed on the left
	-- card, with the date and time. The card's own order button picks the
	-- sort order.
	local mode = combatWidgets.deathSort or "most"
	local zoneList = {}
	for name, count in pairs(combat.deathsByZone or {}) do
		zoneList[#zoneList + 1] = { name = name, count = count }
	end
	table.sort(zoneList, function(a, b)
		if mode == "least" then
			if a.count == b.count then
				return a.name < b.name
			end
			return a.count < b.count
		elseif mode == "az" then
			return a.name < b.name
		elseif mode == "za" then
			return a.name > b.name
		end
		-- "most" is the default: most deaths first, ties broken by name so
		-- the list does not reshuffle between refreshes.
		if a.count == b.count then
			return a.name < b.name
		end
		return a.count > b.count
	end)
	local zoneEntries = {}
	for index = 1, #zoneList do
		zoneEntries[#zoneEntries + 1] = { left = zoneList[index].name, right = "x"..zoneList[index].count }
	end
	if FillScrollingLines(combatWidgets.deaths, zoneEntries, combatWidgets, "deathZoneScrollOffset", "Deaths by zone", 30) == 0 then
		ShowCardText(combatWidgets.deaths, "No deaths recorded - keep it that way.")
	end
	if combatWidgets.deathSortButton then
		SetCornerLabel(combatWidgets.deathSortButton, DeathSortLabel(mode))
	end
end

local function BuildCombatFights(fights)
	CreateTileRow(fights, -4, { "Fights", "Deaths", "In combat", "Alive time" }, combatWidgets.tiles, false)
	combatWidgets.first = CreateListCard(fights, 0, -88, 359, 372, "Time breakdown")
	combatWidgets.deaths = CreateListCard(fights, 371, -88, 359, 372, "Deaths by zone")
	AddCardTitleNote(combatWidgets.first, "Time breakdown",
		"A fight is one uninterrupted stretch in combat; in combat and out of combat add up to tracked time, and AFK is shown beside them. Below the time, the combat records and the recent deaths. The per-creature and per-zone kill lists are on the Kills sub-view.")
	AddCardTitleNote(combatWidgets.deaths, "Deaths by zone",
		"One count per zone or instance the character died in; a death inside a dungeon is counted there, not in the zone outside. The order button sorts by most, fewest, A-Z or Z-A.")
	-- Every zone is kept, so this card takes the wheel rather than dropping
	-- the tail of the list.
	MakeCardScrollable(combatWidgets.deaths, combatWidgets, "deathZoneScrollOffset", function() ns.RefreshCombat() end)

	-- Order button, top right: most deaths, fewest deaths, A-Z, Z-A.
	combatWidgets.deathSort = "most"
	local deathSort = CreateCornerButton(combatWidgets.deaths)
	SetCornerLabel(deathSort, DeathSortLabel(combatWidgets.deathSort))
	deathSort:SetScript("OnClick", function()
		combatWidgets.deathSort = NextDeathSort(combatWidgets.deathSort)
		combatWidgets.deathZoneScrollOffset = 0
		ns.Trace("death order: "..combatWidgets.deathSort)
		ns.RefreshCombat()
	end)
	deathSort:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("The order of the deaths", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Click to cycle: most deaths first, fewest deaths first, A-Z and Z-A. The wheel walks the zones in any order.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	deathSort:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	combatWidgets.deathSortButton = deathSort
end

ns.BuildCombatFights, ns.RefreshCombatFights = BuildCombatFights, RefreshCombatFights
