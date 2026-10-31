-- Tally - the Overview tab: headline statistics for one character.
local addonName, ns = ...

-- Helpers and constants from the files loaded above (see Tally.toc).
local ACCENT, TILE_WIDTH, ROW_START, TILE_BACKDROP, VALUE_COLOR, GREEN, RED, ROW_DIM, overviewWidgets, ClassColorCode, SetTile, CreateTileRow, DisplayChar, SessionTileText, ReadPlayerXP, CreateInfoButton, TopDeathZone, PercentText, ShortWhen, pageRefresh =
	ns.ACCENT, ns.TILE_WIDTH, ns.ROW_START, ns.TILE_BACKDROP, ns.VALUE_COLOR, ns.GREEN, ns.RED, ns.ROW_DIM, ns.overviewWidgets, ns.ClassColorCode, ns.SetTile, ns.CreateTileRow, ns.DisplayChar, ns.SessionTileText, ns.ReadPlayerXP, ns.CreateInfoButton, ns.TopDeathZone, ns.PercentText, ns.ShortWhen, ns.pageRefresh
-------------------------------------------------------------------------------
-- Overview page
-------------------------------------------------------------------------------

-- Hover text for the overview's Info button: what the figures cover, what a
-- session is, and how to clear the record.
local OVERVIEW_INFO = {
	'Tally records played time, gold, combat, loot and exploration for every character that logs in with it loaded.',
	"AFK time counts as played time unless you switch it off in Settings, and a reset there cannot be undone.",
	'Anything that happens while Tally is not running cannot be tracked.',
}

-- Both the bar figures and the XP/h rate use the same compact form, so a
-- large number never sits beside an abbreviated one on the same line.
local function XpFigure(value)
	return ns.FormatCompact(value)
end

local function BuildOverviewPage(page)
	local widgets = overviewWidgets

	widgets.name = page:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	widgets.name:SetPoint("TOPLEFT", 2, 0)
	widgets.name:SetTextColor(VALUE_COLOR[1], VALUE_COLOR[2], VALUE_COLOR[3])

	widgets.detail = page:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	widgets.detail:SetPoint("TOPLEFT", 2, -22)
	widgets.detail:SetTextColor(0.8, 0.8, 0.8)

	-- Corner text: the recorded-since line sits to the left of the Info
	-- button, with the data-point count on the line below.
	widgets.since = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	widgets.since:SetTextColor(0.55, 0.55, 0.55)

	widgets.points = page:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	widgets.points:SetPoint("TOPRIGHT", -2, -22)
	widgets.points:SetTextColor(0.55, 0.55, 0.55)

	widgets.info = CreateInfoButton(page, "About the overview", OVERVIEW_INFO)
	widgets.since:SetPoint("TOPRIGHT", widgets.info, "TOPLEFT", -8, -3)

	widgets.hero = {}
	CreateTileRow(page, ROW_START, { "Lifetime played", "Tracked played time", "This session", "Level" }, widgets.hero)
	local levelTile = widgets.hero[4]
	levelTile.progress = levelTile:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	levelTile.progress:SetPoint("TOPLEFT", levelTile, "TOPLEFT", 10, -42)
	levelTile.progress:SetJustifyH("LEFT")
	levelTile.progress:SetTextColor(0.55, 0.55, 0.55)
	levelTile.rate = levelTile:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	levelTile.rate:SetPoint("TOPRIGHT", levelTile, "TOPRIGHT", -10, -42)
	levelTile.rate:SetJustifyH("RIGHT")
	levelTile.rate:SetTextColor(0.55, 0.55, 0.55)
	levelTile.progress:SetPoint("RIGHT", levelTile.rate, "LEFT", -4, 0)
	levelTile.progress:Hide()
	levelTile.rate:Hide()
	levelTile:EnableMouse(true)
	levelTile:SetScript("OnEnter", function(self)
		local char = DisplayChar()
		local level = char and (char.level or 0) or 0
		-- At the highest level there is no next level to estimate, so the box
		-- has nothing to add on hover.
		if level >= ns.MaxLevel() then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_TOP")
		if ns.IsViewing() then
			local book = char and char.xp
			GameTooltip:AddLine("Last known experience", ACCENT[1], ACCENT[2], ACCENT[3])
			GameTooltip:AddLine("Level "..level, 1, 1, 1)
			if book and book.current and book.max and book.currentLevel == level and book.max > 0 then
				GameTooltip:AddLine(XpFigure(book.current).." / "..XpFigure(book.max).." XP", 1, 1, 1)
				GameTooltip:AddLine("Read "..ns.FormatDateTime(book.currentAt or 0)..".", 0.7, 0.7, 0.7, true)
				GameTooltip:AddLine("Live XP is only available for the character being played.", 0.7, 0.7, 0.7, true)
			else
				GameTooltip:AddLine("Tally has no XP reading for this character at this level yet.", 0.7, 0.7, 0.7, true)
			end
			GameTooltip:Show()
			return
		end
		GameTooltip:AddLine("Estimated time to level up!", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Level "..level, 1, 1, 1)
		local xp, xpMax = ReadPlayerXP()
		if xp and xpMax then
			GameTooltip:AddLine(XpFigure(xp).." / "..XpFigure(xpMax).." XP", 1, 1, 1)
			local okRate, rate = pcall(ns.XpRate, char)
			if not okRate then
				rate = nil
			end
			if rate and rate.perHour > 0 then
				local scope = rate.scope == "recent" and (" over the last "..rate.minutes..(rate.minutes == 1 and " minute" or " minutes")) or (rate.scope == "level" and " on this level" or " overall")
				GameTooltip:AddLine(ns.FormatCompact(rate.perHour).." XP/h"..scope, 1, 1, 1)
				local remaining = math.max(0, xpMax - xp)
				GameTooltip:AddLine("Estimated time to level up: "..ns.FormatDuration(remaining / rate.perHour * 3600), 0.7, 0.7, 0.7, true)
			else
				GameTooltip:AddLine("XP rate is not available yet; more XP history is needed for an estimate.", 0.7, 0.7, 0.7, true)
			end
		else
			GameTooltip:AddLine("XP is not available here.", 0.7, 0.7, 0.7, true)
		end
		GameTooltip:Show()
	end)
	levelTile:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	widgets.goldRow = {}
	CreateTileRow(page, ROW_START - 72, { "Gold", "Gold this session", "Total earned", "Total spent" }, widgets.goldRow)
	widgets.activity = {}
	CreateTileRow(page, ROW_START - 144, { "Fights", "Deaths", "Items looted", "Sessions" }, widgets.activity)
	widgets.world = {}
	CreateTileRow(page, ROW_START - 216, { "Zones Visited", "Dungeons", "Distance", "Flight time" }, widgets.world)

	local card = CreateFrame("Frame", nil, page, "BackdropTemplate")
	card:SetBackdrop(TILE_BACKDROP)
	card:SetBackdropColor(0, 0, 0, 0.35)
	card:SetBackdropBorderColor(1, 0.72, 0.25, 0.12)
	card:SetPoint("TOPLEFT", 0, ROW_START - 288)
	card:SetPoint("BOTTOMLEFT", 0, 0)
	card:SetPoint("BOTTOMRIGHT", 0, 0)

	-- The two headings sit at the top of the card; the old grey "Recent
	-- activity" title is gone, which leaves the card free for more rows.
	local sessionsLabel = card:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	sessionsLabel:SetPoint("TOPLEFT", 12, -6)
	sessionsLabel:SetText("Sessions")
	sessionsLabel:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])

	-- The card's two halves each hold twelve two-column rows: date on the
	-- left, duration and money on the right. x and rightOffset give each
	-- column its position.
	local function CreateRecentRows(into, x, rightOffset)
		for index = 1, 12 do
			local row = {}
			local y = -22 - (index - 1) * 16
			row.left = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.left:SetPoint("TOPLEFT", card, "TOPLEFT", x, y)
			row.left:SetJustifyH("LEFT")
			row.left:SetTextColor(0.68, 0.68, 0.68)
			row.right = card:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.right:SetPoint("TOPRIGHT", card, "TOPRIGHT", rightOffset, y)
			row.right:SetJustifyH("RIGHT")
			row.right:SetTextColor(VALUE_COLOR[1], VALUE_COLOR[2], VALUE_COLOR[3])
			into[#into + 1] = row
		end
	end
	widgets.sessionRows = {}
	CreateRecentRows(widgets.sessionRows, 12, -380)
	widgets.firstRows = {}
	CreateRecentRows(widgets.firstRows, 368, -24)

	local firstsLabel = card:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	firstsLabel:SetPoint("TOPLEFT", 368, -6)
	firstsLabel:SetText("Recently explored")
	firstsLabel:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
	widgets.visitsLabel = firstsLabel

	-- The right half walks the recently explored places on the wheel: twelve
	-- rows fit, and a long list stays readable without a second card.
	widgets.visitOffset = 0
	local visitArea = CreateFrame("Frame", nil, card)
	visitArea:SetPoint("TOPLEFT", card, "TOPLEFT", 360, -18)
	visitArea:SetPoint("BOTTOMRIGHT", card, "BOTTOMRIGHT", -8, 8)
	visitArea:EnableMouse(true)
	visitArea:EnableMouseWheel(true)
	visitArea:SetScript("OnMouseWheel", function(_, delta)
		widgets.visitOffset = (widgets.visitOffset or 0) + (delta > 0 and -1 or 1)
		ns.RefreshOverview()
	end)
end

local function BuildRecentSessionLines(char)
	local entries = {}
	local function LevelText(count)
		if not count or count <= 0 then
			return nil
		end
		return count..(count == 1 and " level gained" or " levels gained")
	end
	-- ns.IsViewing() is false only for the character being played, whose
	-- current session is the live one; a stored open session is not shown.
	local current = (not ns.IsViewing()) and char.sessions.current or nil
	if current then
		local right = ns.FormatDuration(current.seconds, true).." so far"
		if current.goldStart then
			right = right.."  ·  "..ns.FormatMoneyDelta((char.gold.balance or current.goldStart) - current.goldStart)
		end
		local levels = LevelText(current.levelCount)
		if levels then
			right = right.."  ·  "..levels
		end
		entries[#entries + 1] = { left = "playing now", right = right }
	end
	local history = char.sessions.history
	local wanted = current and 11 or 12
	for index = #history, math.max(1, #history - wanted + 1), -1 do
		local session = history[index]
		local right = ns.FormatDuration(session.seconds, true)
		if session.goldStart then
			-- session.goldStart is the first balance reading; a session
			-- with none shows no money figure.
			right = right.."  ·  "..ns.FormatMoneyDelta((session.goldEnd or session.goldStart) - session.goldStart)
		end
		local levels = LevelText(session.levels)
		if levels then
			right = right.."  ·  "..levels
		end
		entries[#entries + 1] = { left = ns.FormatDate(session.start), right = right }
	end
	if #entries == 0 then
		entries[1] = { left = "No finished sessions yet." }
	end
	return entries
end

-- What kind of place a visit was. Older entries only know "instance"; they
-- read as instance rather than being guessed to be a dungeon or a raid.
local function VisitSuffix(entry, kind)
	if not entry.instance then
		return ""
	end
	kind = kind or entry.kind
	if kind == "raid" then
		return "  ·  raid"
	end
	if kind == "party" or kind == "scenario" then
		return "  ·  dungeon"
	end
	if kind == "pvp" then
		return "  ·  battleground"
	end
	if kind == "arena" then
		return "  ·  arena"
	end
	return "  ·  instance"
end

local function BuildRecentVisitLines(char)
	local entries = {}
	local explore = char.explore or {}
	local recent = explore.recent or {}
	local seenPlaces = {}
	for index = 1, #recent do
		local entry = recent[index]
		-- One row per place: the list is "where have I been lately", not a
		-- log of every step. recent is newest first, so the first sighting is
		-- the latest visit to that place.
		if not seenPlaces[entry.name] then
			seenPlaces[entry.name] = true
			-- Older visit entries have no kind; if the instance table has since
			-- learned it, use that rather than showing a vague "instance".
			local kind = entry.kind
			if entry.instance and not kind and explore.dungeons then
				local dungeon = explore.dungeons[entry.name]
				kind = dungeon and dungeon.kind or nil
			end
			entries[#entries + 1] = {
				left = entry.name..VisitSuffix(entry, kind),
				right = ns.ShortWhen(entry.at),
			}
		end
	end
	if #entries == 0 then
		-- A record written before the visit log existed still knows when each
		-- place was last seen, so the card starts with those rather than with
		-- nothing: one line per place, newest first.
		local places = {}
		local seen = {}
		-- Instances first, so an instance that is also in the zone time table
		-- is listed once, with its kind.
		for name, dungeon in pairs(explore.dungeons or {}) do
			if dungeon.last then
				places[#places + 1] = { name = name, at = dungeon.last, instance = true, kind = dungeon.kind }
				seen[name] = true
			end
		end
		for name, zone in pairs(explore.zones or {}) do
			if zone.last and not seen[name] then
				places[#places + 1] = { name = name, at = zone.last }
			end
		end
		table.sort(places, function(a, b)
			return (a.at or 0) > (b.at or 0)
		end)
		for index = 1, #places do
			local place = places[index]
			entries[#entries + 1] = {
				left = place.name..VisitSuffix(place),
				right = ns.ShortWhen(place.at),
			}
		end
	end
	if #entries == 0 then
		entries[1] = { left = "No places explored yet." }
	end
	return entries
end

local function FillRecentRows(rows, entries)
	for index = 1, #rows do
		local entry = entries and entries[index]
		rows[index].left:SetText(entry and (entry.left or "") or "")
		rows[index].right:SetText(entry and (entry.right or "") or "")
	end
end

-- A signed change for the session box, in the game's coin colours: the usual
-- "+12g 40s 22c", or the short form once the figure is large enough that the
-- full one would run into the next box.
local function SignedMoney(copper)
	local value = math.floor(copper or 0)
	return (value < 0 and "-" or "+")..ns.MoneyColored(math.abs(value))
end

local function RefreshOverview()
	local widgets = overviewWidgets
	if not widgets.hero[1] then
		return
	end
	local char = DisplayChar()
	if not char then
		widgets.name:SetText("Tally")
		widgets.detail:SetText("waiting for the character to log in")
		widgets.since:SetText("")
		widgets.points:SetText("")
		for index = 1, #widgets.all do
			SetTile(widgets.all[index], "-", "")
		end
		FillRecentRows(widgets.sessionRows, { { left = "No finished sessions yet." } })
		FillRecentRows(widgets.firstRows, { { left = "No places explored yet." } })
		return
	end

	local nameColor = ClassColorCode(char.classFile)
	widgets.name:SetText((nameColor or "")..ns.FullName(char)..(nameColor and "|r" or ""))
	local detailText = "Level "..(char.level or 0)
	if char.race then
		detailText = detailText.." "..char.race
	end
	if char.class then
		detailText = detailText.." "..(nameColor or "")..char.class..(nameColor and "|r" or "")
	end
	widgets.detail:SetText(detailText)
	local firstSeen = char.firstSeen
	local sinceAt = (firstSeen and firstSeen.observed == "live" and firstSeen.at) or char.created
	local sinceText = "recorded since "..ns.FormatDate(sinceAt)
	if firstSeen and firstSeen.level then
		sinceText = sinceText.." · first seen at level "..tostring(firstSeen.level)
	end
	widgets.since:SetText(sinceText)
	local points = ns.DataPoints(char)
	widgets.points:SetText(ns.FormatNumber(points)..(points == 1 and " point of data tracked" or " points of data tracked"))

	local played = char.played
	local gold = char.gold
	-- As on the sessions card: only the character being played has a live
	-- session.
	local session = (not ns.IsViewing()) and char.sessions.current or nil

	-- Row 1: the hero numbers.
	local playedText, playedSub = "-", "waiting for a sync"
	if played.total then
		playedText = ns.FormatDuration(played.total)
		-- The figure is the client's own lifetime total; Tally only reads it,
		-- so the line says where it comes from rather than how fresh it is.
		playedSub = "tracked by server"
		if not ns.IsViewing() and played.at and (ns.Now() - played.at) > 900 then
			playedSub = "tracked by server - type /played to refresh"
		end
	elseif ns.db.settings.playedSyncBlocked and not ns.IsViewing() then
		playedSub = "type /played to sync"
	end
	SetTile(widgets.hero[1], playedText, playedSub)
	SetTile(widgets.hero[2], ns.FormatDuration(char.tracked), "since "..ns.FormatDate(char.created))
	if session then
		SetTile(widgets.hero[3], ns.FormatDuration(session.seconds), "started "..ShortWhen(session.start))
	else
		SetTile(widgets.hero[3], "-", "no session active")
	end

	local level = char.level or 0
	local levelTile = widgets.hero[4]
	local maxLevel = ns.MaxLevel()
	local xp, xpMax, rate, lastKnownAt
	if ns.IsViewing() then
		-- A viewed character has no live XP. Show the last reading Tally took
		-- while that character was played, but only if it belongs to this
		-- level; an older level's bar would be a lie.
		local book = char.xp
		if level < maxLevel and book and book.current and book.max
			and book.currentLevel == level and book.max > 0 then
			xp, xpMax, lastKnownAt = book.current, book.max, book.currentAt
		end
	elseif level < maxLevel then
		xp, xpMax = ReadPlayerXP()
		local okRate, value = pcall(ns.XpRate, char)
		rate = okRate and value or nil
	end

	if xp and xpMax and xpMax > 0 then
		levelTile.barBg:Show()
		levelTile.barFill:Show()
		-- Rested experience fills the bar blue; without it the bar is purple,
		-- which is what the character's own XP bar does. A stored reading has
		-- no live rested figure, so it stays purple and says it is stored.
		local rested = 0
		if not lastKnownAt and type(GetXPExhaustion) == "function" then
			local okRested, value = pcall(GetXPExhaustion)
			if okRested and type(value) == "number" then
				rested = value
			end
		end
		if type(rested) ~= "number" or rested < 0 then
			rested = 0
		end
		if rested > 0 then
			levelTile.barFill:SetColorTexture(0.25, 0.55, 0.95, 0.9)
		else
			levelTile.barFill:SetColorTexture(0.62, 0.35, 0.95, 0.9)
		end
		local fraction = xp / xpMax
		if fraction < 0 then fraction = 0 elseif fraction > 1 then fraction = 1 end
		levelTile.barFill:SetWidth((TILE_WIDTH - 20) * fraction)
		SetTile(levelTile, tostring(level), "")
		levelTile.sub:Hide()
		levelTile.progress:SetText(XpFigure(xp).." / "..XpFigure(xpMax).." XP")
		levelTile.progress:Show()
		if lastKnownAt then
			levelTile.rate:SetText("seen "..ns.FormatDate(lastKnownAt))
		else
			levelTile.rate:SetText(rate and (ns.FormatCompact(rate.perHour).." XP/h") or "- XP/h")
		end
		levelTile.rate:Show()
	elseif level >= maxLevel then
		-- No bar at the cap: there is no next level to be a fraction of.
		levelTile.barBg:Hide()
		levelTile.barFill:Hide()
		levelTile.progress:Hide()
		levelTile.rate:Hide()
		levelTile.sub:Show()
		SetTile(levelTile, tostring(level), "highest level")
	elseif ns.IsViewing() then
		levelTile.barBg:Hide()
		levelTile.barFill:Hide()
		levelTile.progress:Hide()
		levelTile.rate:Hide()
		levelTile.sub:Show()
		SetTile(levelTile, tostring(level), "no XP reading yet")
	else
		levelTile.barBg:Hide()
		levelTile.barFill:Hide()
		levelTile.progress:Hide()
		levelTile.rate:Hide()
		levelTile.sub:Show()
		SetTile(levelTile, tostring(level), "XP unavailable")
	end

	-- Row 2: gold. The balance tile's line is the first reading Tally ever took
	-- for this character, which is not the same as the character's creation -
	-- Tally may not have been installed then - so it is worded as a reading.
	-- A reading of 0c is shown like any other: "Tally first saw this character
	-- with nothing" is a fact about the record, not a missing figure, and it
	-- is often the whole point of the line.
	local firstReading = ns.money.FirstReading(char)
	if gold.balance then
		local sub = "first reading pending"
		if firstReading then
			-- A first reading of nothing is a fact about the record, not a
			-- figure worth the line: it says only that Tally met the
			-- character with an empty purse.
			sub = firstReading > 0 and ("First reading: "..ns.MoneyColored(firstReading)) or ""
		end
		SetTile(widgets.goldRow[1], ns.MoneyColored(gold.balance), sub)
	else
		SetTile(widgets.goldRow[1], "-", "first reading pending")
	end
	if session and session.goldStart then
		local delta = (gold.balance or session.goldStart) - session.goldStart
		-- The line names the session, not the character: this balance is the
		-- purse when the session opened, which for the first session is also
		-- the first reading but for every later one is simply the purse that
		-- day. A purse this size needs the short form, or it runs into the
		-- next box.
		SetTile(widgets.goldRow[2], SignedMoney(delta),
			"session opened with "..ns.MoneyColored(session.goldStart),
			delta > 0 and GREEN or (delta < 0 and RED or nil))
	elseif session then
		SetTile(widgets.goldRow[2], "-", "balance not read yet")
	else
		SetTile(widgets.goldRow[2], "-", "no session active")
	end
	-- The totals are everything that moved since Tally started watching this
	-- character, and they include money the flags could not classify. The
	-- category split belongs on the Economy tab, so the line here is only the
	-- period.
	local earned, spent = ns.money.Totals(gold)
	SetTile(widgets.goldRow[3], earned > 0 and ("+"..ns.MoneyColored(earned)) or ns.MoneyColored(0), "since tracking", earned > 0 and GREEN or nil)
	SetTile(widgets.goldRow[4], spent > 0 and ("-"..ns.MoneyColored(spent)) or ns.MoneyColored(0), "since tracking", spent > 0 and RED or nil)

	local activityRow = widgets.activity
	if not activityRow[1].hoverReady then
		activityRow[1].hoverReady = true
		activityRow[1]:EnableMouse(true)
		activityRow[1]:SetScript("OnEnter", function(self)
			if not self.tipLines or #self.tipLines == 0 then
				return
			end
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(self.tipTitle or "Fights", ACCENT[1], ACCENT[2], ACCENT[3])
			for index = 1, #self.tipLines do
				local line = self.tipLines[index]
				local color = line.color or VALUE_COLOR
				GameTooltip:AddLine(line.text, color[1], color[2], color[3])
			end
			GameTooltip:Show()
		end)
		activityRow[1]:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
	end
	-- Row 3: activity. Fights are counted from the entering/leaving-combat
	-- events, which every client raises; the combat log is not available.
	local inCombat = math.floor((char.combat.combatSeconds or 0) + 0.5)
	if inCombat > char.tracked then
		inCombat = char.tracked
	end
	local outOfCombat = math.max(0, char.tracked - inCombat)
	SetTile(widgets.activity[1], ns.FormatNumber(char.combat.fights or 0), "in combat "..PercentText(inCombat, char.tracked).." of tracked time")
	-- The hover carries the split the Combat tab states in full: time in
	-- combat and time out of it, with AFK as its own figure rather than a
	-- fourth slice (a flagged player is still in one of the two).
	local fightTips = {
		{ text = "In combat   "..ns.FormatDuration(inCombat).."  ·  "..PercentText(inCombat, char.tracked), color = VALUE_COLOR },
		{ text = "Out of combat   "..ns.FormatDuration(outOfCombat).."  ·  "..PercentText(outOfCombat, char.tracked), color = VALUE_COLOR },
	}
	if (char.afk or 0) > 0 then
		fightTips[#fightTips + 1] = { text = "AFK   "..ns.FormatDuration(char.afk), color = ROW_DIM }
	end
	fightTips[#fightTips + 1] = { text = ns.FormatDuration(char.tracked).." tracked in all", color = ROW_DIM }
	widgets.activity[1].tipTitle = "Fights"
	widgets.activity[1].tipLines = fightTips
	local deathsSub = "no deaths yet"
	if (char.combat.deaths or 0) > 0 then
		deathsSub = "most in "..TopDeathZone(char)
	end
	SetTile(widgets.activity[2], ns.FormatNumber(char.combat.deaths), deathsSub)
	if ns.itemValueAvailable == false then
		SetTile(widgets.activity[3], ns.FormatNumber(char.loot.items), "item values unavailable here")
	else
		-- The name reads from the left and the figure from the right, as the
		-- sessions box does with its current and average.
		SetTile(widgets.activity[3], ns.FormatNumber(char.loot.items), "Vendor value", nil, nil, ns.MoneyColored(char.loot.value))
	end
	local sessionSub, sessionAvg = SessionTileText(char.sessions, session)
	SetTile(widgets.activity[4], ns.FormatNumber(char.sessions.count), sessionSub, nil, nil, sessionAvg)

	-- Row 4: the world.
	local explore = char.explore
	local zoneCount = ns.CountTable(explore.zones)
	local latest = explore.recentFirsts[#explore.recentFirsts]
	SetTile(widgets.world[1], tostring(zoneCount), latest and ("Latest: "..latest.name) or "none yet")
	local runs, bosses, dungeonCount = 0, explore.bosses or 0, 0
	for _, dungeon in pairs(explore.dungeons) do
		runs = runs + (dungeon.entered or 0)
		dungeonCount = dungeonCount + 1
	end
	SetTile(widgets.world[2], tostring(runs), dungeonCount > 0 and (dungeonCount.." dungeons · "..bosses.." bosses") or "none entered yet")
	SetTile(widgets.world[3], ns.FormatDistance(explore.distance), "approximate, on foot")
	SetTile(widgets.world[4], ns.FormatDuration(explore.flightSeconds, true), explore.flights > 0 and (explore.flights.." flights") or "no flights yet")

	FillRecentRows(widgets.sessionRows, BuildRecentSessionLines(char))
	local visitLines = BuildRecentVisitLines(char)
	local visibleVisits = 12
	local maxOffset = math.max(0, #visitLines - visibleVisits)
	local offset = math.min(math.max(widgets.visitOffset or 0, 0), maxOffset)
	widgets.visitOffset = offset
	local visitWindow = {}
	for index = offset + 1, math.min(#visitLines, offset + visibleVisits) do
		visitWindow[#visitWindow + 1] = visitLines[index]
	end
	FillRecentRows(widgets.firstRows, visitWindow)
	if widgets.visitsLabel then
		if #visitLines > visibleVisits then
			widgets.visitsLabel:SetText("Recently explored - "..(offset + 1).."-"..math.min(#visitLines, offset + visibleVisits).." of "..#visitLines)
		else
			widgets.visitsLabel:SetText("Recently explored")
		end
	end
end

-- Handed to the shell, which builds and refreshes every tab.
ns.BuildOverviewPage, ns.RefreshOverview = BuildOverviewPage, RefreshOverview
