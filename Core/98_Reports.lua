-- Tally - reports: the chat report lines, the copy text and the diagnostic
-- dump.
--
-- Reports only read the stored records and the shared helpers. They own no
-- saved subtree; the slash commands and the window ask for a report by name.
local addonName, ns = ...

local FormatClock, FormatCompact, FormatDate, FormatDateTime, FormatDistance, FormatDuration, FormatMoneyPlain, FormatNumber, GetAddonVersion, LastSeen, Now, PopupText, RepairModeLive, repairWatch, TUNING =
	ns.FormatClock, ns.FormatCompact, ns.FormatDate, ns.FormatDateTime, ns.FormatDistance, ns.FormatDuration, ns.FormatMoneyPlain, ns.FormatNumber, ns.GetAddonVersion, ns.LastSeen, ns.Now, ns.PopupText, ns.RepairModeLive, ns.repairWatch, ns.TUNING

-- Reports are flat lists of chat-sized lines. The list feeds the chat
-- print, the clipboard text (markup stripped) and the sharing window
-- (sent line by line, paced to stay under the chat throttle).
local ACC = "|cffffb347"
local GRAY = "|cff9d9d9d"
local GREEN = "|cff40d940"
local RED = "|cffff6b6b"

ns.REPORT_ORDER = { "overview", "session", "playtime", "economy", "combat", "loot", "explore" }
ns.REPORT_TITLES = {
	overview = "Overview",
	session = "Current Session",
	playtime = "Playtime",
	economy = "Economy",
	combat = "Combat",
	loot = "Loot",
	explore = "Exploration",
}

local CATEGORY_NAMES = {
	loot = "loot",
	quest = "quests",
	vendor = "vendors",
	training = "training",
	mail = "mail",
	trade = "trade",
	auction = "auction",
	repair = "repairs",
}

local function IsReportType(reportType)
	for index = 1, #ns.REPORT_ORDER do
		if ns.REPORT_ORDER[index] == reportType then
			return true
		end
	end
	return false
end
ns.IsReportType = IsReportType

local function Label(text)
	return ACC..text.."|r"
end

local function SumCategories(bucket)
	local total = 0
	for _, value in pairs(bucket or {}) do
		total = total + value
	end
	return total
end

-- "loot 890g · quests 210g · vendors 145g"
local function TopCategories(bucket, limit)
	local list = {}
	for key, value in pairs(bucket or {}) do
		list[#list + 1] = { name = CATEGORY_NAMES[key] or key, value = value }
	end
	table.sort(list, function(a, b)
		return a.value > b.value
	end)
	local parts = {}
	for index = 1, math.min(#list, limit or 3) do
		parts[#parts + 1] = list[index].name.." "..FormatMoneyPlain(list[index].value)
	end
	return table.concat(parts, " · ")
end

-- Sorted list of { name, count } from a "name -> count" map.
local function SortedCounts(map, limit)
	local list = {}
	for name, count in pairs(map or {}) do
		list[#list + 1] = { name = name, count = count }
	end
	table.sort(list, function(a, b)
		return a.count > b.count
	end)
	while #list > (limit or 5) do
		table.remove(list)
	end
	return list
end

local function Percent(part, whole)
	if not whole or whole <= 0 then
		return 0
	end
	return math.floor(part / whole * 100 + 0.5)
end

local function BuildOverviewReport(char, lines)
	local played = char.played
	local gold = char.gold
	local firstReading = ns.money.FirstReading(char)
	local session = char.sessions.current

	local playedText = GRAY.."not synced yet|r"
	if played.total then
		playedText = FormatDuration(played.total)
		if played.at then
			playedText = playedText..GRAY.." (tracked by server, synced "..FormatDateTime(played.at)..")|r"
		end
	elseif ns.db.settings.playedSyncBlocked then
		playedText = GRAY.."type /played once and Tally picks it up|r"
	end
	lines[#lines + 1] = Label("Lifetime played:").." "..playedText
	lines[#lines + 1] = Label("Tracked by Tally:").." "..FormatDuration(char.tracked)..GRAY.." since "..FormatDate(char.created).."|r"

	if session then
		lines[#lines + 1] = Label("This session:").." "..FormatDuration(session.seconds)..GRAY.." started "..FormatClock(session.start).."|r"
	else
		lines[#lines + 1] = Label("This session:").." "..GRAY.."no session active|r"
	end

	local balanceText = char.gold.balance and FormatMoneyPlain(char.gold.balance) or GRAY.."unknown|r"
	local balanceNotes = {}
	if session and session.goldStart then
		balanceNotes[#balanceNotes + 1] = "session "..ns.FormatMoneyDelta((char.gold.balance or session.goldStart) - session.goldStart)
	end
	if firstReading and char.gold.balance then
		balanceNotes[#balanceNotes + 1] = "since tracking "..ns.FormatMoneyDelta(char.gold.balance - firstReading)
	end
	local balanceSuffix = ""
	if #balanceNotes > 0 then
		balanceSuffix = GRAY.." ("..table.concat(balanceNotes, ", ")..")|r"
	end
	lines[#lines + 1] = Label("Gold:").." "..balanceText..balanceSuffix

	local combat = char.combat
	local inCombat = math.floor((combat.combatSeconds or 0) + 0.5)
	if inCombat > char.tracked then
		inCombat = char.tracked
	end
	lines[#lines + 1] = Label("Fights / deaths:").." "..FormatNumber(combat.fights or 0).." / "..FormatNumber(combat.deaths)..GRAY.." ("..FormatDuration(inCombat).." in combat, "..FormatDuration(math.max(0, char.tracked - inCombat)).." out)|r"
	if combat.logAvailable ~= false then
		local killsText = (combat.killsHeard or combat.logHeard) and FormatNumber(combat.kills) or GRAY.."waiting for combat data|r"
		lines[#lines + 1] = Label("Kills:").." "..killsText
	end

	lines[#lines + 1] = Label("Items looted:").." "..FormatNumber(char.loot.items)..GRAY.." ("..FormatMoneyPlain(char.loot.value).." vendor value)|r"

	local explore = char.explore
	local runs = 0
	for _, dungeon in pairs(explore.dungeons) do
		runs = runs + (dungeon.entered or 0)
	end
	lines[#lines + 1] = Label("World:").." "..ns.CountTable(explore.zones).." zones, "..runs.." dungeon runs, "..(explore.bosses or 0).." bosses, "..FormatDistance(explore.distance).." travelled"

	if #lines == 0 then
		lines[#lines + 1] = GRAY.."Nothing recorded yet - play a little and check back.|r"
	end
end

local function BuildSessionReport(char, lines)
	local session = char.sessions.current
	if not session then
		lines[#lines + 1] = GRAY.."No session is active right now - Tally starts counting the moment you log in with it loaded.|r"
		return
	end
	lines[#lines + 1] = Label("Started:").." "..FormatDateTime(session.start)
	lines[#lines + 1] = Label("Time in session:").." "..FormatDuration(session.seconds)..GRAY.." ("..FormatDuration(session.alive).." alive)|r"
	if session.goldStart then
		local goldDelta = (char.gold.balance or session.goldStart) - session.goldStart
		lines[#lines + 1] = Label("Gold:").." "..ns.FormatMoneyDelta(goldDelta)..GRAY.." (session opened with "..FormatMoneyPlain(session.goldStart)..")|r"
	else
		lines[#lines + 1] = Label("Gold:").." "..GRAY.."not measured this session yet|r"
	end
	lines[#lines + 1] = Label("Activity:").." "..(session.fights or 0).." fights, "..(session.deaths or 0).." deaths, "..(session.items or 0).." items looted"
	if (session.combatSeconds or 0) > 0 then
		lines[#lines + 1] = Label("In combat:").." "..FormatDuration(session.combatSeconds)..GRAY.." of "..FormatDuration(session.seconds).."|r"
	end
	if (session.afk or 0) > 0 then
		lines[#lines + 1] = Label("AFK:").." "..FormatDuration(session.afk)..GRAY.." (can overlap alive and dead)|r"
	end
	if (session.levelCount or 0) > 0 then
		lines[#lines + 1] = Label("Levels gained:").." "..session.levelCount
	end
	if session.firsts and #session.firsts > 0 then
		lines[#lines + 1] = Label("New zones:").." "..table.concat(session.firsts, ", ")
	end
	local travel = FormatDistance(session.distance)
	if (session.flights or 0) > 0 then
		travel = travel..", "..session.flights.." flights ("..FormatDuration(session.flightSeconds)..")"
	end
	lines[#lines + 1] = Label("Travel:").." "..travel
end

local function BuildPlaytimeReport(char, lines)
	local played = char.played
	local playedText = GRAY.."not synced yet|r"
	if played.total then
		playedText = FormatDuration(played.total)
		if played.at then
			playedText = playedText..GRAY.." (tracked by server, synced "..FormatDateTime(played.at)..")|r"
		end
	elseif ns.db.settings.playedSyncBlocked then
		playedText = GRAY.."not synced yet - the game only answers /played typed by you|r"
	end
	lines[#lines + 1] = Label("Lifetime played:").." "..playedText
	lines[#lines + 1] = Label("Tracked by Tally:").." "..FormatDuration(char.tracked).." over "..char.sessions.count.." sessions"
	lines[#lines + 1] = Label("Alive time:").." "..FormatDuration(char.alive)..GRAY.." ("..Percent(char.alive, char.tracked).."% of tracked)|r"
	if (char.afk or 0) > 0 then
		if ns.db.settings.excludeAfk then
			lines[#lines + 1] = Label("AFK:").." "..FormatDuration(char.afk)..GRAY.." (left out of tracked time)|r"
		else
			lines[#lines + 1] = Label("AFK:").." "..FormatDuration(char.afk)..GRAY.." ("..Percent(char.afk, char.tracked).."% of tracked; can overlap alive and dead)|r"
		end
	end
	if char.sessions.count > 0 then
		lines[#lines + 1] = Label("Session time:").." "..FormatDuration(char.sessions.seconds)..GRAY.." (longest "..FormatDuration(char.sessions.longest)..", average "..FormatDuration(math.floor(char.sessions.seconds / char.sessions.count))..")|r"
	end
	if char.sessions.current then
		lines[#lines + 1] = Label("Session now:").." "..FormatDuration(char.sessions.current.seconds)..GRAY.." so far (started "..FormatDateTime(char.sessions.current.start)..")|r"
	end
	if (char.sessions.unfinished or 0) > 0 then
		lines[#lines + 1] = Label("Ended without logging out:").." "..char.sessions.unfinished..GRAY.." (crash, disconnect or the game closing)|r"
	end
	local gained = (char.level or 0) - (char.firstLevel or char.level or 0)
	lines[#lines + 1] = Label("Levels:").." "..(char.level or 0)..GRAY.." (was "..(char.firstLevel or char.level or 0).." when Tally was installed, +"..gained..")|r"
	local rate = ns.XpRate(char)
	if rate and rate.scope == "level" then
		lines[#lines + 1] = Label("XP on this level:").." "..FormatNumber(rate.gained)..GRAY.." in "..FormatDuration(rate.seconds).." watched ("..FormatCompact(rate.perHour).." XP/hour)|r"
	elseif rate then
		lines[#lines + 1] = Label("XP watched:").." "..FormatNumber(rate.gained)..GRAY.." over "..FormatDuration(rate.seconds).." of samples ("..FormatCompact(rate.perHour).." XP/hour across levels)|r"
	else
		local xp = char.xp or {}
		if (xp.total or 0) > 0 then
			lines[#lines + 1] = Label("XP watched:").." "..FormatNumber(xp.total)..GRAY.." over "..FormatDuration(xp.seconds or 0).." of samples - too little to rate yet|r"
		end
	end
	if played.levelTime and (played.level or -1) == (char.level or 0) then
		-- From the client's /played: time on the current level so far, the
		-- only level time available for a character that has not levelled
		-- since install.
		lines[#lines + 1] = Label("Level "..(char.level or 0).." so far:").." "..FormatDuration(played.levelTime)..GRAY.." on this level (game /played)|r"
	end

	local history = char.levels.history
	if #history > 0 then
		lines[#lines + 1] = Label("Recent level-ups:")..""
		-- The install snapshot is not a level time: it marks where watching
		-- began. When it is the level currently being played, the current
		-- progress into that level is appended.
		local percent = (char == ns.GetChar()) and ns.LevelPercent() or nil
		local byLevel = (char.xp and char.xp.byLevel) or {}
		local function XpText(levelOn)
			local bucket = levelOn and byLevel[levelOn]
			if not bucket or (bucket.gained or 0) <= 0 then
				return ""
			end
			return "  ·  "..FormatCompact(bucket.gained).." XP"
		end
		local function Stamp(at)
			return at and ("  ("..FormatDateTime(at)..")") or ""
		end
		local first = history[1]
		if first and first.partial then
			local text = GRAY.."  "
			if (first.level or 0) <= 1 then
				text = text.."Tracking started"
			else
				text = text.."L"..first.level.." - tracking started"
			end
			if percent and (char.level or 0) == first.level and #history == 1 then
				text = text..", now "..percent.."% into this level"
			end
			lines[#lines + 1] = text..XpText(first.level)..Stamp(first.at).."|r"
		end
		local points = ns.LevelPoints(char)
		local firstShown = math.max(1, #points - 4)
		for index = firstShown, #points do
			local point = points[index]
			local text = GRAY.."  "..(point.level - 1).." to "..point.level.." - "
			if point.gap then
				text = text.."no reading for this level"
			else
				text = text..FormatDuration(point.seconds).." played on the previous level"
				if point.estimated then
					text = text..(point.partial and " (estimated, at least)" or " (estimated)")
				elseif point.partial then
					text = text.." (at least)"
				elseif point.sampled then
					text = text.." (split by Tally's count)"
				end
				text = text..XpText(point.level - 1)
			end
			lines[#lines + 1] = text..Stamp(point.at).."|r"
		end
	end
end

local function BuildEconomyReport(char, lines)
	local gold = char.gold
	local firstReading = ns.money.FirstReading(char)
	lines[#lines + 1] = Label("Balance:").." "..(char.gold.balance and FormatMoneyPlain(char.gold.balance) or GRAY.."unknown|r")
	if firstReading and char.gold.balance then
		lines[#lines + 1] = Label("Since tracking:").." "..ns.FormatMoneyDelta(char.gold.balance - firstReading)..GRAY.." (first reading "..FormatMoneyPlain(firstReading)..")|r"
	end
	-- The totals add in money the flags could not classify, so the bracket
	-- names the categories Tally can name and says so when the total is
	-- larger than the named parts.
	local unclassifiedIn, unclassifiedOut = ns.money.UnclassifiedTotals(gold)
	local earned, spent = ns.money.Totals(gold)
	local incomeText = TopCategories(gold.income, 4)
	if incomeText == "" then
		incomeText = GRAY.."nothing named|r"
	end
	if unclassifiedIn > 0 then
		incomeText = incomeText..GRAY.." · unclassified "..FormatMoneyPlain(unclassifiedIn).."|r"
	end
	lines[#lines + 1] = Label("Total earned:").." "..FormatMoneyPlain(earned, "0c")..GRAY.." ("..incomeText..")|r"
	local expenseText = TopCategories(gold.expenses, 4)
	if expenseText == "" then
		expenseText = GRAY.."nothing named|r"
	end
	if unclassifiedOut > 0 then
		expenseText = expenseText..GRAY.." · unclassified "..FormatMoneyPlain(unclassifiedOut).."|r"
	end
	lines[#lines + 1] = Label("Total spent:").." "..FormatMoneyPlain(spent, "0c")..GRAY.." ("..expenseText..")|r"
	if gold.unclassified.count > 0 then
		local parts = gold.unclassified.count.." changes, "..FormatMoneyPlain(unclassifiedIn).." in, "..FormatMoneyPlain(unclassifiedOut).." out"
		lines[#lines + 1] = Label("Unclassified:").." "..parts..GRAY.." (money that moved while nothing explained it: trainer purchases where the game sends no trainer events, offline sales, mail, and anything else Tally could not attribute)|r"
	else
		lines[#lines + 1] = Label("Unclassified:").." "..GRAY.."none - every copper change was classified|r"
	end
	local today = gold.daily[date("%Y-%m-%d")]
	if today then
		lines[#lines + 1] = Label("Today:").." "..FormatMoneyPlain(today.income, "0c").." in, "..FormatMoneyPlain(today.expense, "0c").." out"
	else
		lines[#lines + 1] = Label("Today:").." "..GRAY.."nothing yet|r"
	end
	if #gold.tx > 0 then
		lines[#lines + 1] = Label("Recent changes:")..""
		local first = math.max(1, #gold.tx - 4)
		for index = #gold.tx, first, -1 do
			local transaction = gold.tx[index]
			lines[#lines + 1] = GRAY.."  "..FormatDateTime(transaction.t).."  "..(CATEGORY_NAMES[transaction.c] or transaction.c).."  "..ns.FormatMoneyDelta(transaction.d).."|r"
		end
	end
end

local function BuildCombatReport(char, lines)
	local combat = char.combat
	local fights = combat.fights or 0
	local inCombat = math.floor((combat.combatSeconds or 0) + 0.5)
	if inCombat > char.tracked then
		inCombat = char.tracked
	end
	local outOfCombat = math.max(0, char.tracked - inCombat)
	local averageFight = fights > 0 and (inCombat / fights) or 0
	lines[#lines + 1] = Label("Fights:").." "..FormatNumber(fights)..GRAY.." (times pulled into combat"..(fights > 0 and (", average "..FormatDuration(math.floor(averageFight + 0.5))) or "")..")|r"
	lines[#lines + 1] = Label("In combat:").." "..FormatDuration(inCombat)..GRAY.." ("..Percent(inCombat, char.tracked).."% of tracked time)|r"
	lines[#lines + 1] = Label("Out of combat:").." "..FormatDuration(outOfCombat)..GRAY.." ("..Percent(outOfCombat, char.tracked).."% of tracked time)|r"
	local afk = char.afk or 0
	if afk > 0 then
		if ns.db.settings.excludeAfk then
			lines[#lines + 1] = Label("AFK:").." "..FormatDuration(afk)..GRAY.." (left out of tracked time)|r"
		else
			lines[#lines + 1] = Label("AFK:").." "..FormatDuration(afk)..GRAY.." ("..Percent(afk, char.tracked).."% of tracked time; can overlap the figures above)|r"
		end
	end
	if combat.killsHeard or combat.logHeard then
		lines[#lines + 1] = Label("Kills:").." "..FormatNumber(combat.kills)..GRAY.." ("..ns.CountTable(combat.killTypes).." creature types)|r"
		local top = SortedCounts(combat.killTypes, 5)
		if #top > 0 then
			lines[#lines + 1] = Label("Most killed:")..""
			for _, entry in ipairs(top) do
				lines[#lines + 1] = GRAY.."  "..entry.name.." x"..entry.count.."|r"
			end
		end
	elseif combat.killsAvailable then
		lines[#lines + 1] = GRAY.."Kills are counted from the game's kill events; none recorded yet.|r"
	end
	if ns.killSource == "nameplate" then
		lines[#lines + 1] = GRAY.."World kills come from the game's kill events; instance kills from experience lines and looted corpses.|r"
	end
	lines[#lines + 1] = Label("Deaths:").." "..FormatNumber(combat.deaths)
	local deathZones = SortedCounts(combat.deathsByZone)
	if #deathZones > 0 then
		lines[#lines + 1] = Label("Deaths by zone:")..""
		for _, entry in ipairs(deathZones) do
			lines[#lines + 1] = GRAY.."  "..entry.name.." x"..entry.count.."|r"
		end
	end
	-- The last few deaths with their dates and times, as the card lists them.
	-- A record written before the log was kept still holds the last death.
	local deathLog = combat.deathLog or {}
	if #deathLog == 0 and combat.lastDeath then
		deathLog = { combat.lastDeath }
	end
	if #deathLog > 0 then
		lines[#lines + 1] = Label("Recent deaths:")..""
		local firstShown = math.max(1, #deathLog - 4)
		for index = #deathLog, firstShown, -1 do
			local death = deathLog[index]
			local killer = death.killer and (" - killed by "..death.killer) or ""
			lines[#lines + 1] = GRAY.."  "..FormatDateTime(death.at).." in "..(death.zone or "?").." at level "..(death.level or "?")..killer.."|r"
		end
	end
	-- Buffs and debuffs: the campfire figures, then the longest-running of
	-- each kind. The window has the whole list, split into class and other.
	local auras = char.auras
	if auras then
		local camp = auras.camp or {}
		lines[#lines + 1] = Label("Campfire:").." "..FormatDuration(camp.seconds or 0)..GRAY.." at the fire, "..(camp.visits or 0).." visits, "..(camp.benefits or 0).." camp benefits|r"
		local function TopAuras(bucket, label)
			local list = {}
			for name, entry in pairs(bucket or {}) do
				list[#list + 1] = { name = name, count = entry.count or 0, seconds = entry.seconds or 0 }
			end
			if #list == 0 then
				return
			end
			table.sort(list, function(a, b)
				if a.seconds == b.seconds then
					return a.name < b.name
				end
				return a.seconds > b.seconds
			end)
			lines[#lines + 1] = Label(label)..""
			for index = 1, math.min(#list, 6) do
				lines[#lines + 1] = GRAY.."  "..list[index].name.." x"..list[index].count.." - "..FormatDuration(list[index].seconds, true).."|r"
			end
			if #list > 6 then
				lines[#lines + 1] = GRAY.."  and "..(#list - 6).." more in the window|r"
			end
		end
		TopAuras(auras.buffs, "Buffs:")
		TopAuras(auras.debuffs, "Debuffs:")
	end
	lines[#lines + 1] = Label("Alive time:").." "..FormatDuration(char.alive)..GRAY.." ("..Percent(char.alive, char.tracked).."% of tracked time)|r"
end

local QUALITY_NAMES = { [0] = "Poor", [1] = "Common", [2] = "Uncommon", [3] = "Rare", [4] = "Epic", [5] = "Legendary", [6] = "Artifact" }
-- The loot window's own colours, so a best find reads as the item it is.
local QUALITY_COLORS = {
	[0] = { 0.62, 0.62, 0.62 },
	[1] = { 1.0, 1.0, 1.0 },
	[2] = { 0.12, 1.0, 0.0 },
	[3] = { 0.0, 0.44, 0.87 },
	[4] = { 0.64, 0.21, 0.93 },
	[5] = { 1.0, 0.5, 0.0 },
	[6] = { 0.9, 0.8, 0.5 },
}

local function QualityCode(quality)
	local color = QUALITY_COLORS[quality] or QUALITY_COLORS[1]
	return string.format("|cff%02x%02x%02x", math.floor(color[1] * 255 + 0.5), math.floor(color[2] * 255 + 0.5), math.floor(color[3] * 255 + 0.5))
end

local function BuildLootReport(char, lines)
	local loot = char.loot
	if ns.itemValueAvailable == false then
		lines[#lines + 1] = Label("Items looted:").." "..FormatNumber(loot.items)..GRAY.." (item values are not available in this game, so the vendor value cannot be worked out)|r"
	else
		lines[#lines + 1] = Label("Items looted:").." "..FormatNumber(loot.items)..GRAY.." ("..FormatMoneyPlain(loot.value).." vendor value)|r"
	end
	local qualityParts = {}
	for quality = 0, 6 do
		local count = loot.quality[quality] or 0
		if count > 0 then
			qualityParts[#qualityParts + 1] = (QUALITY_NAMES[quality] or quality).." "..count
		end
	end
	if #qualityParts > 0 then
		lines[#lines + 1] = Label("By quality:").." "..table.concat(qualityParts, " · ")
	end
	local qualityUnknown = loot.qualityUnknown or 0
	if qualityUnknown > 0 then
		-- Items whose per-item quality was never recorded: included in the
		-- "items looted" count above, not assigned a quality here.
		lines[#lines + 1] = GRAY.."  "..FormatNumber(qualityUnknown).." earlier items - quality unknown.|r"
	end
	if #loot.best > 0 then
		lines[#lines + 1] = Label("Best finds:")..""
		for _, entry in ipairs(loot.best) do
			-- The item name uses its loot-window quality colour, matching
			-- the lists in the window.
			lines[#lines + 1] = GRAY.."  "..QualityCode(entry.quality)..(entry.name or "?").."|r"..GRAY.." ("..(QUALITY_NAMES[entry.quality] or "?")..") - "..FormatMoneyPlain(entry.value).." - "..FormatDate(entry.at).."|r"
		end
	else
		lines[#lines + 1] = GRAY.."Nothing with a sell value has been looted yet.|r"
	end
end

local function BuildExploreReport(char, lines)
	local explore = char.explore
	local zoneCount = ns.CountTable(explore.zones)
	local recent = explore.recentFirsts[#explore.recentFirsts]
	local latestText = ""
	if recent then
		latestText = GRAY..", latest "..recent.name.." on "..FormatDate(recent.at).."|r"
	end
	lines[#lines + 1] = Label("Zones visited:").." "..zoneCount..latestText

	-- The quests block, in the same words the boxes use: quests completed, the
	-- experience read after a turn-in, and the reward money booked under its
	-- own window. Both figures are only what the client actually reported.
	local questGold = char.gold and char.gold.income and char.gold.income.quest
	lines[#lines + 1] = Label("Quests completed:").." "..(char.quests or 0)
	if char.questXp then
		lines[#lines + 1] = Label("Quest experience:").." "..FormatNumber(char.questXp)..GRAY.." (read within "..TUNING.questXpWindow.."s of a turn-in)|r"
	else
		lines[#lines + 1] = Label("Quest experience:").." "..GRAY.."none read yet|r"
	end
	if questGold then
		lines[#lines + 1] = Label("Quest reward gold:").." "..FormatMoneyPlain(questGold)..GRAY.." (money arriving within "..TUNING.questGoldWindow.."s of a turn-in)|r"
	else
		lines[#lines + 1] = Label("Quest reward gold:").." "..GRAY.."none booked yet|r"
	end

	-- Per-zone time, which the zone count alone cannot show.
	local zoneTime = {}
	for name, entry in pairs(explore.zones) do
		if (entry.seconds or 0) > 0 then
			zoneTime[#zoneTime + 1] = { name = name, seconds = entry.seconds or 0 }
		end
	end
	table.sort(zoneTime, function(a, b)
		if a.seconds == b.seconds then
			return a.name < b.name
		end
		return a.seconds > b.seconds
	end)
	if zoneTime[1] then
		-- Every zone with time on it, not a top three: there are not many,
		-- and the window lists them all too.
		lines[#lines + 1] = Label("Time in zones:")..""
		for index = 1, #zoneTime do
			local zone = zoneTime[index]
			local visits = explore.zones[zone.name] and (explore.zones[zone.name].visits or 0) or 0
			lines[#lines + 1] = GRAY.."  "..zone.name.." - "..FormatDuration(zone.seconds)..(visits > 0 and (", "..visits..(visits == 1 and " visit" or " visits")) or "").."|r"
		end
	end

	if #explore.recentFirsts > 0 then
		lines[#lines + 1] = Label("Recently first visited:")..""
		local first = math.max(1, #explore.recentFirsts - 4)
		for index = #explore.recentFirsts, first, -1 do
			local entry = explore.recentFirsts[index]
			lines[#lines + 1] = GRAY.."  "..entry.name.." - "..FormatDate(entry.at).." (level "..(entry.level or "?")..")|r"
		end
	end

	local dungeonList = {}
	local runs, bosses = 0, 0
	for name, dungeon in pairs(explore.dungeons) do
		runs = runs + (dungeon.entered or 0)
		bosses = bosses + (dungeon.bosses or 0)
		dungeonList[#dungeonList + 1] = { name = name, entered = dungeon.entered or 0, bosses = dungeon.bosses or 0, seconds = dungeon.seconds or 0 }
	end
	table.sort(dungeonList, function(a, b)
		if a.seconds == b.seconds then
			return a.entered > b.entered
		end
		return a.seconds > b.seconds
	end)
	lines[#lines + 1] = Label("Dungeons:").." "..#dungeonList.." entered, "..runs.." runs, "..bosses.." bosses down"
	for index = 1, #dungeonList do
		local dungeon = dungeonList[index]
		lines[#lines + 1] = GRAY.."  "..dungeon.name.." - "..dungeon.entered.." runs, "..dungeon.bosses.." bosses"
			..(dungeon.seconds > 0 and (", "..FormatDuration(dungeon.seconds, true).." inside") or "").."|r"
	end

	lines[#lines + 1] = Label("Distance:").." "..FormatDistance(explore.distance)..GRAY.." (approximate, on foot; flight paths are not counted)|r"
	if (explore.flights or 0) > 0 then
		lines[#lines + 1] = Label("Flights:").." "..explore.flights..GRAY.." ("..FormatDuration(explore.flightSeconds).." in the air)|r"
	end
	lines[#lines + 1] = Label("Recorded since:").." "..FormatDateTime(char.created)
end

-- One-line banner for a printed report that describes a character other
-- than the one being played, marking its figures as a snapshot. Returns
-- nil when the report is about the live character.
function ns.ReportViewNote()
	local viewed = ns.ViewChar()
	if not viewed then
		return nil
	end
	local live = ns.GetChar()
	return string.format("[Not live] %s's figures are the last Tally recorded (%s). You are playing %s.",
		viewed.name or "another character",
		FormatDateTime(LastSeen(viewed) or Now()),
		live and (live.name or "?") or "a different character")
end

------------------------------------------------------------------------------

function ns.BuildReport(reportType)
	if not IsReportType(reportType) then
		reportType = "overview"
	end
	local lines = {}
	local char = ns.ReportChar()
	if not char then
		lines[1] = GRAY.."No data recorded yet for this character.|r"
		return lines
	end
	if reportType == "overview" then
		BuildOverviewReport(char, lines)
	elseif reportType == "session" then
		BuildSessionReport(char, lines)
	elseif reportType == "playtime" then
		BuildPlaytimeReport(char, lines)
	elseif reportType == "economy" then
		BuildEconomyReport(char, lines)
	elseif reportType == "combat" then
		BuildCombatReport(char, lines)
	elseif reportType == "loot" then
		BuildLootReport(char, lines)
	elseif reportType == "explore" then
		BuildExploreReport(char, lines)
	end
	-- A report is a snapshot. It names the tabs that are not being recorded,
	-- so a figure that has stopped moving is not mistaken for a quiet week.
	local paused = {}
	for _, area in ipairs({ "playtime", "economy", "combat", "loot", "explore" }) do
		if not ns.Tracks(area) then
			paused[#paused + 1] = area:sub(1, 1):upper()..area:sub(2)
		end
	end
	if #paused > 0 then
		lines[#lines + 1] = ""
		lines[#lines + 1] = GRAY.."Recording is off for: "..table.concat(paused, ", ")..".|r"
	end
	return lines
end

function ns.ReportTitle(reportType)
	return ns.REPORT_TITLES[reportType] or ns.REPORT_TITLES.overview
end

-- First line of every printed or copied report: "Tally - Overview -
-- Name, Level 42 Human Mage - Realm", with the name in the class colour.
function ns.ReportHeader(reportType, plain)
	local title = ns.ReportTitle(reportType)
	local char = ns.ReportChar()
	if not char then
		return "Tally - "..title
	end
	local level = char.level or 0
	local class = char.class or "?"
	local realmText = char.realm and (" - "..char.realm) or ""
	if plain then
		return string.format("Tally - %s - %s, Level %d %s%s", title, ns.DisplayName(char), level, class, realmText)
	end
	local nameColor = "|cffffffff"
	local classColor = char.classFile and RAID_CLASS_COLORS and RAID_CLASS_COLORS[char.classFile]
	if classColor then
		local r, g, b
		if classColor.GetRGB then
			r, g, b = classColor:GetRGB()
		else
			r, g, b = classColor.r, classColor.g, classColor.b
		end
		if r and g and b then
			nameColor = string.format("|cff%02x%02x%02x", math.floor(r * 255 + 0.5), math.floor(g * 255 + 0.5), math.floor(b * 255 + 0.5))
		end
	end
	return string.format("|cffffb347Tally|r |cff9d9d9d-|r %s - %s%s|r, Level %d %s%s", title, nameColor, ns.DisplayName(char), level, class, realmText)
end

-- Print: one report, straight into the chat frame. Lines are indented so
-- they read as one block under the header.
function ns.PrintReport(reportType)
	if not IsReportType(reportType) then
		reportType = "overview"
	end
	if not DEFAULT_CHAT_FRAME then
		return
	end
	DEFAULT_CHAT_FRAME:AddMessage(ns.ReportHeader(reportType, false))
	local viewNote = ns.ReportViewNote()
	if viewNote then
		DEFAULT_CHAT_FRAME:AddMessage("   |cffffb347"..viewNote.."|r")
	end
	local lines = ns.BuildReport(reportType)
	for index = 1, #lines do
		DEFAULT_CHAT_FRAME:AddMessage("   "..lines[index])
	end
end

-- Copy: the same report with markup stripped. CopyToClipboard is
-- Blizzard-only on some clients, so unless direct copying is enabled the
-- report is placed in a window with the text pre-selected; a Ctrl+C there
-- puts it on the system clipboard through a user action.
function ns.CopyReport(reportType)
	if not IsReportType(reportType) then
		reportType = "overview"
	end
	local lines = ns.BuildReport(reportType)
	local text = ns.ReportHeader(reportType, true)
	local viewNote = ns.ReportViewNote()
	if viewNote then
		text = text.."\n   "..viewNote
	end
	for index = 1, #lines do
		text = text.."\n   "..ns.StripColors(lines[index])
	end
	local title = ns.ReportTitle(reportType)
	if ns.db and ns.db.settings.copyDirect and type(CopyToClipboard) == "function" then
		local ok = pcall(CopyToClipboard, text, false)
		if ok then
			ns.Print("The "..title.." report is on your clipboard.")
			return true
		end
		ns.Print("The clipboard refused the text - opening the copy window instead.")
	end
	if ns.OpenCopyWindow then
		ns.OpenCopyWindow(title, text)
		ns.Print("The "..title.." report is in the copy window - press Ctrl+C there.")
	end
	return false
end

-- Full diagnostic dump as plain text for the copy window: build, state
-- flags, the guild panel tab, the loaded addons in list order, every open
-- popup, and the captured trace block. "/tally trace" opens it with the
-- text pre-selected.
function ns.BuildDebugText()
	local lines = {}
	lines[#lines + 1] = "Tally v"..ns.GetAddonVersion().." - diagnostic dump"
	lines[#lines + 1] = "build: "..tostring(ns.BUILD)
	lines[#lines + 1] = "schema: "..tostring(ns.SchemaVersion and ns.SchemaVersion() or 0).." of "..tostring(ns.SCHEMA_VERSION or "?")
	lines[#lines + 1] = ""
	lines[#lines + 1] = "autoPlayedSync = "..tostring(ns.db.settings.autoPlayedSync)
	lines[#lines + 1] = "playedSyncBlocked = "..tostring(ns.db.settings.playedSyncBlocked)
	lines[#lines + 1] = "copyDirect = "..tostring(ns.db.settings.copyDirect)
	lines[#lines + 1] = "levelEstimate = "..tostring(ns.db.settings.levelEstimate)
	lines[#lines + 1] = "excludeAfk = "..tostring(ns.db.settings.excludeAfk)
	lines[#lines + 1] = "combatLogRead = "..tostring(ns.db.settings.combatLogRead)
	lines[#lines + 1] = "track: playtime="..tostring(ns.Tracks("playtime"))..", economy="..tostring(ns.Tracks("economy"))..", combat="..tostring(ns.Tracks("combat"))..", loot="..tostring(ns.Tracks("loot"))..", explore="..tostring(ns.Tracks("explore"))
	lines[#lines + 1] = "repair: quote="..tostring(repairWatch.cost)..", quoteBlocked="..tostring(repairWatch.blocked)..", buttonAt="..tostring(repairWatch.paidAt)..", inRepairMode="..tostring(RepairModeLive())
	-- Read-only probe of which combat-log accessors exist; none is called.
	lines[#lines + 1] = "accessors: CombatLogGetCurrentEventInfo="..tostring(CombatLogGetCurrentEventInfo ~= nil)..", C_CombatLog="..tostring(C_CombatLog ~= nil)..", C_CombatLogSecure="..tostring(C_CombatLogSecure ~= nil)
	if C_CombatLog then
		lines[#lines + 1] = "C_CombatLog.GetCurrentEventInfo = "..tostring(C_CombatLog.GetCurrentEventInfo ~= nil)
	end
	lines[#lines + 1] = "item API: GetItemInfo="..tostring(type(GetItemInfo) == "function")..", C_Item="..tostring(type(C_Item) == "table")..", C_Item.GetItemInfo="..tostring(type(C_Item) == "table" and type(C_Item.GetItemInfo) == "function")..", itemValueAvailable="..tostring(ns.itemValueAvailable)
	local dbgChar = ns.GetChar()
	if ns.IsViewing() then
		local viewed = ns.ViewChar()
		lines[#lines + 1] = "viewing: "..tostring(viewed.name).." ("..tostring(ns.viewKey)..") - live character is "..tostring(ns.charKey)
	end
	if dbgChar then
		lines[#lines + 1] = "combat counters: fights="..tostring(dbgChar.combat.fights or 0)..", combatSeconds="..tostring(dbgChar.combat.combatSeconds or 0)..", tracked="..tostring(dbgChar.tracked)..", inCombatNow="..tostring(UnitAffectingCombat and UnitAffectingCombat("player") and true or false)
		lines[#lines + 1] = "kills: source="..tostring(ns.killSource)..", nameplates="..tostring(ns.kills.NameplatesActive and ns.kills.NameplatesActive())..", heard="..tostring(dbgChar.combat.killsHeard)..", total="..tostring(dbgChar.combat.kills or 0)
		if ns.kills.DebugText then
			lines[#lines + 1] = ns.kills.DebugText()
		end
		-- What the level-times reader makes of this character's readings, so a
		-- figure that looks wrong in the chart can be traced to its source.
		local history = (dbgChar.levels and dbgChar.levels.history) or {}
		lines[#lines + 1] = "played: total="..tostring(dbgChar.played and dbgChar.played.total)..", levelTime="..tostring(dbgChar.played and dbgChar.played.levelTime)..", level="..tostring(dbgChar.played and dbgChar.played.level)..", readings="..#history
		local points = ns.LevelPoints(dbgChar)
		local parts = {}
		for index = math.max(1, #points - 13), #points do
			local point = points[index]
			if point.gap then
				parts[#parts + 1] = tostring(point.level).."=hole"
			else
				parts[#parts + 1] = string.format("%d=%ds%s%s", point.level, point.seconds or 0,
					point.estimated and "(est)" or "", point.partial and "(!)" or "")
			end
		end
		lines[#lines + 1] = "level points ("..ns.DisplayName(dbgChar)..")"..(#points > 14 and ", last 14" or "")..": "..(#parts > 0 and table.concat(parts, " ") or "none")
	end
	if ns.AuctionDebugLines then
		pcall(ns.AuctionDebugLines, lines)
	end
	if GuildControlUI then
		lines[#lines + 1] = "GuildControlUI.selectedTab = "..tostring(GuildControlUI.selectedTab)
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "-- loaded addons (list order, * = loaded) --"
	local okAddons, addonCount = pcall(function()
		if C_AddOns and C_AddOns.GetNumAddOns then
			return C_AddOns.GetNumAddOns()
		end
		if GetNumAddOns then
			return GetNumAddOns()
		end
		return 0
	end)
	if okAddons and addonCount and addonCount > 0 then
		for index = 1, addonCount do
			local okInfo, name = pcall(function()
				if C_AddOns and C_AddOns.GetAddOnInfo then
					return C_AddOns.GetAddOnInfo(index)
				end
				return GetAddOnInfo(index)
			end)
			if okInfo and name and name ~= "" then
				local loaded = false
				if C_AddOns and C_AddOns.IsAddOnLoaded then
					local okLoaded, value = pcall(C_AddOns.IsAddOnLoaded, name)
					loaded = okLoaded and value or false
				elseif IsAddOnLoaded then
					local okLoaded, value = pcall(IsAddOnLoaded, name)
					loaded = okLoaded and value or false
				end
				lines[#lines + 1] = (loaded and "* " or "  ")..tostring(name)
			end
		end
	else
		lines[#lines + 1] = "(addon list unavailable)"
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "-- popups on screen --"
	local foundPopup = false
	local okCapture, captureError = pcall(function()
		if not StaticPopup_ForEachShownDialog then
			return
		end
		StaticPopup_ForEachShownDialog(function(dialog)
			foundPopup = true
			lines[#lines + 1] = "Open popup: "..tostring(dialog.which).." | data="..tostring(dialog.data)
			local text = PopupText(dialog)
			if text then
				lines[#lines + 1] = "  text: "..text
			end
		end)
	end)
	if not okCapture then
		lines[#lines + 1] = "popup capture failed: "..tostring(captureError)
	elseif not foundPopup then
		lines[#lines + 1] = "No static popup is open right now."
	end
	lines[#lines + 1] = ""
	if ns.EventOwners then
		lines[#lines + 1] = "-- event owners --"
		local events = ns.EventOwners()
		for index = 1, #events do
			local row = events[index]
			local label = row.event..(row.unit and (" ["..row.unit.."]") or "")
			lines[#lines + 1] = "  "..label..": "..table.concat(row.owners, ", ").." ("..row.count..")"
		end
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "-- trace ("..tostring(#ns.traceLog).." lines kept) --"
	local log = ns.traceLog
	local first = 1
	if #log > ns.TRACE_DUMP_LINES then
		first = #log - ns.TRACE_DUMP_LINES + 1
	end
	if #log == 0 then
		lines[#lines + 1] = "<empty>"
	else
		for index = first, #log do
			lines[#lines + 1] = ns.StripColors(log[index])
		end
	end
	return table.concat(lines, "\n")
end

-------------------------------------------------------------------------------

-- Owner namespace. REPORT_ORDER and REPORT_TITLES are the same tables, not
-- copies; every other field references the flat function above.
ns.reports = {}
ns.reports.Order = ns.REPORT_ORDER
ns.reports.Titles = ns.REPORT_TITLES
ns.reports.IsType = ns.IsReportType
ns.reports.ViewNote = ns.ReportViewNote
ns.reports.Build = ns.BuildReport
ns.reports.Title = ns.ReportTitle
ns.reports.Header = ns.ReportHeader
ns.reports.Print = ns.PrintReport
ns.reports.Copy = ns.CopyReport
ns.reports.DebugText = ns.BuildDebugText
