-- Tally - the Playtime tab: per-level times and the session history.
local addonName, ns = ...

-- Helpers and constants from the files loaded above (see Tally.toc).
local ACCENT, VALUE_COLOR, SetTile, CreateTileRow, DisplayChar, PercentText, SessionTileText, CreateListCard, TALL_ROW_STEP, FillCardRows, ShowCardText, AddCardTitleNote, pageRefresh, ROW_DETAIL_DIM =
	ns.ACCENT, ns.VALUE_COLOR, ns.SetTile, ns.CreateTileRow, ns.DisplayChar, ns.PercentText, ns.SessionTileText, ns.CreateListCard, ns.TALL_ROW_STEP, ns.FillCardRows, ns.ShowCardText, ns.AddCardTitleNote, ns.pageRefresh, ns.ROW_DETAIL_DIM
-------------------------------------------------------------------------------
-- Playtime page
-------------------------------------------------------------------------------

local playtimeWidgets = { tiles = {} }

local function ObservedText(value)
	if value == "login" then
		return "seen at login"
	elseif value == "migration" then
		return "from an older record"
	elseif value == "estimate" then
		return "estimated"
	elseif value == "unknown" or value == nil then
		return "not recorded"
	end
	return "seen live"
end

local function LevelWhere(entry)
	if not entry or not entry.zone or entry.zone == "" then
		return nil
	end
	local zone = entry.zone
	if entry.zoneKind == "dungeon" then
		zone = zone.." (dungeon)"
	elseif entry.zoneKind == "raid" then
		zone = zone.." (raid)"
	end
	return "Where: "..zone
end

local function RefreshPlaytime()
	if not playtimeWidgets.sessions then
		return
	end
	local char = DisplayChar()
	if not char then
		for index = 1, #playtimeWidgets.tiles do
			SetTile(playtimeWidgets.tiles[index], "-", "")
		end
		ShowCardText(playtimeWidgets.sessions, "No data yet.")
		playtimeWidgets.levels.title:SetText("Level-ups")
		ShowCardText(playtimeWidgets.levels, "No data yet.")
		return
	end

	local viewing = ns.IsViewing()
	-- Opening a different character resets the level scroll to the newest
	-- level-ups; the key is name plus realm.
	local scrollKey = (char.name or "").."|"..(char.realm or "")
	if playtimeWidgets.levelScrollKey ~= scrollKey then
		playtimeWidgets.levelScrollKey = scrollKey
		playtimeWidgets.levelScrollOffset = 0
	end
	local played = char.played
	local playedText, playedSub = "-", "waiting for a sync"
	if played.total then
		playedText = ns.FormatDuration(played.total)
		playedSub = "tracked by server"
		if not viewing and played.at and (ns.Now() - played.at) > 900 then
			-- A /played can only be read from the logged-in character.
			playedSub = "tracked by server - type /played to refresh"
		end
	elseif ns.db.settings.playedSyncBlocked then
		playedSub = viewing and "no /played recorded for this character" or "type /played to sync"
	end
	SetTile(playtimeWidgets.tiles[1], playedText, playedSub)
	SetTile(playtimeWidgets.tiles[2], ns.FormatDuration(char.tracked), "since "..ns.FormatDate(char.created))

	local sessions = char.sessions
	-- sessions.current is live only for the character being played; a stored
	-- open session from another character is not shown as live.
	local liveSession = (not viewing) and sessions.current or nil
	-- The session open now, or the longest finished one, on the left; the
	-- average of the finished sessions against the right edge.
	local sessionSub, sessionAvg = SessionTileText(sessions, liveSession)
	SetTile(playtimeWidgets.tiles[3], ns.FormatNumber(sessions.count), sessionSub, nil, nil, sessionAvg)
	-- A session that ended without a logout (crash, disconnect or the client
	-- being killed) has no length to record, so it is counted beside the
	-- total rather than in it: the card's title carries the count, which
	-- keeps the tile's line to the two figures it was asked for.
	local sessionTitle = "Recent sessions"
	if (sessions.unfinished or 0) > 0 then
		sessionTitle = sessionTitle.." - "..sessions.unfinished.." ended without a logout"
	end
	playtimeWidgets.sessions.title:SetText(sessionTitle)
	-- The card's hover follows the title it is drawn with.
	playtimeWidgets.sessions.noteTitle = sessionTitle
	SetTile(playtimeWidgets.tiles[4], ns.FormatDuration(char.alive), PercentText(char.alive, char.tracked).." of tracked time")

	-- A session's own time breakdown, shown when its row is hovered. AFK is
	-- listed separately because it overlaps alive and dead rather than being
	-- a fourth slice of the session.
	local function SessionTip(session, title)
		local seconds = session.seconds or 0
		local alive = math.min(session.alive or 0, seconds)
		local dead = math.max(0, seconds - alive)
		-- AFK is not clamped to the length: while the setting leaves AFK out
		-- of played time, a session can hold more AFK than length.
		local afk = session.afk or 0
		local inCombat = math.min(session.combatSeconds or 0, seconds)
		local finish
		if session.stop then
			finish = (session.endedObserved and "Finished: " or "Last seen: ")..ns.FormatDateTime(session.stop)
		else
			finish = "Finished: still open"
		end
		local note
		if session.stop and session.endedObserved == false then
			note = "The client did not report a logout; the length is a lower bound to the last tick."
		elseif ns.db.settings.excludeAfk then
			note = "AFK is counted here but left out of the length while the setting is on."
		else
			note = "AFK can overlap the other figures: it is time spent flagged away, alive or dead."
		end
		return {
			kind = "note",
			-- Seconds are part of the key, so an open session's hover follows
			-- its clock instead of freezing on the first figure.
			key = "session|"..title.."|"..seconds.."|"..alive.."|"..afk.."|"..inCombat,
			title = title,
			lines = {
				{ text = "Started: "..ns.FormatDateTime(session.start) },
				{ text = finish },
				{ text = "Length: "..ns.FormatDuration(seconds, true)..(session.durationKnown == false and " (at least)" or "") },
				{ text = "Alive: "..ns.FormatDuration(alive, true) },
				{ text = "Dead or ghost: "..ns.FormatDuration(dead, true) },
				{ text = "AFK: "..ns.FormatDuration(afk, true) },
				{ text = "In combat: "..ns.FormatDuration(inCombat, true) },
			},
			note = note,
		}
	end

	-- The live session is listed with the finished ones; without it a first
	-- session would show no rows at all.
	local sessionEntries = {}
	if liveSession then
		local entry = {
			left = "playing now",
			leftColor = ACCENT,
			right = ns.FormatDuration(liveSession.seconds, true),
			rightColor = VALUE_COLOR,
			tip = SessionTip(liveSession, "This session (still open)"),
		}
		if liveSession.goldStart then
			entry.right = entry.right.."  ·  "..ns.FormatMoneyDelta((char.gold.balance or liveSession.goldStart) - liveSession.goldStart)
		end
		sessionEntries[#sessionEntries + 1] = entry
	end
	for index = #sessions.history, math.max(1, #sessions.history - 13), -1 do
		local session = sessions.history[index]
		local right = ns.FormatDuration(session.seconds, true)
		if session.goldStart then
			right = right.."  ·  "..ns.FormatMoneyDelta((session.goldEnd or session.goldStart) - session.goldStart)
		end
		sessionEntries[#sessionEntries + 1] = {
			left = ns.FormatDate(session.start)..(session.unfinished and "  (never logged out)" or ""),
			right = right,
			tip = SessionTip(session, ns.FormatDateTime(session.start)),
		}
	end
	if FillCardRows(playtimeWidgets.sessions, sessionEntries, 30) == 0 then
		if liveSession then
			ShowCardText(playtimeWidgets.sessions, "This is your first recorded session - it is still open.")
		else
			ShowCardText(playtimeWidgets.sessions, "No finished sessions yet.")
		end
	end

	-- The level-ups card is drawn with tall rows: the first line carries the
	-- level, the dim line under it the numbers. The top row is the level
	-- being played now, so "current level" appears once instead of a "now"
	-- and a "so far" line saying the same thing twice.
	local levelEntries = {}
	local level = char.level or 0
	local xpBook = char.xp or {}
	local byLevel = xpBook.byLevel or {}
	local currentBucket = byLevel[level]
	local rate = ns.XpRate(char)
	local percent = (not viewing) and ns.LevelPercent() or nil
	local detailParts = {}
	if rate then
		detailParts[#detailParts + 1] = ns.FormatCompact(rate.gained).." XP in "..ns.FormatDuration(rate.seconds, true)
		detailParts[#detailParts + 1] = ns.FormatCompact(rate.perHour).." XP/h"
		if rate.scope == "recent" then
			detailParts[#detailParts + 1] = "last "..rate.minutes..(rate.minutes == 1 and " minute" or " minutes")
		elseif rate.scope ~= "level" then
			detailParts[#detailParts + 1] = "across levels"
		end
	elseif currentBucket and (currentBucket.seconds or 0) > 0 then
		-- Too little sampled yet for a rate, but the samples themselves are
		-- worth showing.
		detailParts[#detailParts + 1] = ns.FormatCompact(currentBucket.gained or 0).." XP in "..ns.FormatDuration(currentBucket.seconds, true)
	end
	if played.levelTime and played.levelTime >= 60 and (played.level or -1) == level then
		-- The client's own /played for this level: a second measurement of
		-- the same level, so it sits beside Tally's sample rather than
		-- replacing it.
		detailParts[#detailParts + 1] = ns.FormatDuration(played.levelTime).." on this level"
	end
	local levelRight = tostring(level)
	if percent then
		levelRight = levelRight.."  ·  "..percent.."% to "..(level + 1)
	end
	-- One row per finished level, from ns.LevelPoints: the client's own
	-- /played reading where it answered, Tally's count where it did not.
	local levelPoints = ns.LevelPoints(char)
	local historyByLevel = {}
	for index = 1, #(((char.levels or {}).history) or {}) do
		local entry = char.levels.history[index]
		if entry and entry.level then
			historyByLevel[entry.level] = entry
		end
	end
	-- The level being played now began at the newest level-up reading; with
	-- none yet, the day Tally first saw the character is the best anchor
	-- there is, and the hover says so.
	local newestPoint = levelPoints[#levelPoints]
	local currentStart = newestPoint and newestPoint.at or (char.firstSeen and char.firstSeen.observed == "live" and char.firstSeen.at) or char.created
	-- How long this level has been running: the client's own /played figure
	-- when it is for this level, otherwise Tally's sample of the same level.
	local soFar
	if played.levelTime and played.levelTime >= 60 and (played.level or -1) == level then
		soFar = played.levelTime
	elseif currentBucket and (currentBucket.seconds or 0) > 0 then
		soFar = currentBucket.seconds
	end
		levelEntries[#levelEntries + 1] = {
		left = "current level",
		right = levelRight,
		detail = table.concat(detailParts, "  ·  "),
		tip = {
			kind = "note",
			key = "level|current|"..level.."|"..tostring(currentStart).."|"..tostring(soFar),
			title = "Level "..level.." (still playing)",
			lines = {
				{ text = currentStart and ("Started: "..ns.FormatDateTime(currentStart)) or "Started: not recorded" },
				{ text = "Reached: not yet" },
				{ text = soFar and ("So far: "..ns.FormatDuration(soFar)) or "So far: just started" },
				{ text = "How: level_up" },
				{ text = "Observed: "..ObservedText((historyByLevel[level] or {}).observed) },
			},
			note = (not newestPoint) and "No level-up has been recorded yet, so this is when Tally first saw the character." or nil,
		},
	}
	if #levelPoints > 0 then
		levelEntries[#levelEntries + 1] = { left = "" }
	end
	-- The level window: as many rows as fit under the rows above, from the
	-- newest back. The offset is the number of rows walked back by the wheel
	-- and is clamped to the list's length here, so it can never point past
	-- either end.
	local room = math.max(1, math.floor((playtimeWidgets.levels:GetHeight() - 46) / TALL_ROW_STEP) - #levelEntries)
	local maxOffset = math.max(0, #levelPoints - room)
	local offset = math.min(math.max(playtimeWidgets.levelScrollOffset or 0, 0), maxOffset)
	playtimeWidgets.levelScrollOffset = offset
	local newest = #levelPoints - offset
	-- XP credited while the character was on a level: the sampler files each
	-- gain under the level it happened on, so a finished level's figure is
	-- the bucket one below the level the row reaches.
	local function BucketText(levelOn)
		local bucket = levelOn and byLevel[levelOn]
		if not bucket or (bucket.gained or 0) <= 0 then
			return nil
		end
		return ns.FormatCompact(bucket.gained).." XP"
	end
	for index = newest, math.max(1, newest - room + 1), -1 do
		local point = levelPoints[index]
		local right
		local tip
		if point.gap then
			right = "no reading"
			local reached = historyByLevel[point.level]
			local previous = historyByLevel[point.level - 1]
			tip = {
				kind = "note",
				key = "level|"..point.level.."|gap|"..tostring(point.at),
				title = "Level "..(point.level - 1).." to "..point.level,
				lines = {
					{ text = previous and previous.at and ("Started: "..ns.FormatDateTime(previous.at)) or "Started: not recorded" },
					{ text = (reached and reached.at) and ("Reached: "..ns.FormatDateTime(reached.at)) or "Reached: not recorded" },
					{ text = "Took: not recorded" },
					{ text = LevelWhere(reached) or "Where: not recorded" },
					{ text = "How: level_up" },
					{ text = "Observed: "..ObservedText(reached and reached.observed) },
				},
				note = "The game gave no reading for this level, so no time is invented for it.",
			}
		else
			right = ns.FormatDuration(point.seconds)
			if point.estimated then
				right = right.." (est.)"
			end
			if point.partial then
				right = right.." (!)"
			end
			local reached = historyByLevel[point.level]
			local previous = historyByLevel[point.level - 1]
			local endedAt = point.at
			local startedAt = (previous and (previous.startedAt or previous.at)) or (endedAt and (endedAt - (point.seconds or 0))) or nil
			local tipLines = {
				{ text = startedAt and ("Started: "..ns.FormatDateTime(startedAt)) or "Started: not recorded" },
				{ text = endedAt and ("Reached: "..ns.FormatDateTime(endedAt)) or "Reached: not recorded" },
				{ text = "Took: "..ns.FormatDuration(point.seconds)..(point.estimated and " (estimated)" or "") },
				{ text = LevelWhere(reached) or "Where: not recorded" },
				{ text = "How: level_up" },
				{ text = "Observed: "..ObservedText(reached and reached.observed) },
			}
			tip = {
				kind = "note",
				key = "level|"..point.level.."|"..tostring(point.seconds).."|"..tostring(endedAt),
				title = "Level "..(point.level - 1).." to "..point.level,
				lines = tipLines,
				note = point.partial and "The start is a lower bound: Tally may have been running for only part of this level." or nil,
			}
		end
		levelEntries[#levelEntries + 1] = {
			left = (point.level - 1).." to "..point.level,
			right = right,
			detail = BucketText(point.level - 1),
			-- The date the client reported the level reached; the ledger
			-- and the deaths list carry the same stamp.
			detailRight = point.at and ns.FormatDateTime(point.at) or nil,
			tip = tip,
		}
	end
	-- The title names the level range on screen; with nothing to scroll it
	-- stays the plain "Level-ups".
	local title = "Level-ups"
	if #levelPoints > room and newest >= 1 then
		local oldestShown = levelPoints[math.max(1, newest - room + 1)]
		local newestShown = levelPoints[newest]
		local topLevel = levelPoints[#levelPoints]
		title = string.format("Level-ups - levels %d-%d of %d",
			oldestShown and (oldestShown.level - 1) or 0, newestShown and newestShown.level or 0, topLevel and topLevel.level or 0)
	end
	playtimeWidgets.levels.title:SetText(title)
	if #levelEntries > 0 then
		FillCardRows(playtimeWidgets.levels, levelEntries, 20, true)
	else
		ShowCardText(playtimeWidgets.levels, "No level-ups recorded yet.")
	end
end

local function BuildPlaytimePage(page)
	CreateTileRow(page, -4, { "Lifetime played", "Tracked by Tally", "Sessions", "Alive time" }, playtimeWidgets.tiles, false)
	playtimeWidgets.sessions = CreateListCard(page, 0, -88, 359, 372, "Recent sessions")
	AddCardTitleNote(playtimeWidgets.sessions, "Recent sessions",
		"One row per finished session, newest first, with its length and what the purse did over it. Hover a session for how its time was spent, and note that a session that ended without a logout has no length to record.")
	-- Hovering a session shows its own breakdown. The rows are not
	-- mouse-enabled, so the card tracks the cursor itself; mouse on the card
	-- would swallow the window drag, so the drag is handed back.
	playtimeWidgets.sessions:EnableMouse(true)
	playtimeWidgets.sessions:RegisterForDrag("LeftButton")
	playtimeWidgets.sessions:SetScript("OnDragStart", function()
		if ns.mainFrame then
			ns.mainFrame:StartMoving()
		end
	end)
	playtimeWidgets.sessions:SetScript("OnDragStop", function()
		if ns.mainFrame then
			ns.mainFrame:StopMovingOrSizing()
		end
	end)
	playtimeWidgets.sessions:SetScript("OnUpdate", function()
		if ns.RowHoverTick then
			ns.RowHoverTick(playtimeWidgets.sessions)
		end
	end)
	playtimeWidgets.sessions:SetScript("OnLeave", function()
		local card = playtimeWidgets.sessions
		card.hoverKey = nil
		if GameTooltip:IsOwned(card) then
			GameTooltip:Hide()
		end
	end)
	playtimeWidgets.levels = CreateListCard(page, 371, -88, 359, 372, "Level-ups")
	AddCardTitleNote(playtimeWidgets.levels, "Level-ups",
		"One row per finished level, newest first: the level, the time it took, the experience Tally sampled on it and the date it was reached. Hover a row for its timestamps; a lower bound carries (!), and a level filled by the estimate in Settings is marked (est.).")
	-- The card shows as many level-ups as fit; the wheel walks the window
	-- back through the older ones.
	playtimeWidgets.levels:EnableMouse(true)
	playtimeWidgets.levels:EnableMouseWheel(true)
	-- A mouse-enabled card swallows drags, so the drag is handed back to the
	-- main frame.
	playtimeWidgets.levels:RegisterForDrag("LeftButton")
	playtimeWidgets.levels:SetScript("OnDragStart", function()
		if ns.mainFrame then
			ns.mainFrame:StartMoving()
		end
	end)
	playtimeWidgets.levels:SetScript("OnDragStop", function()
		if ns.mainFrame then
			ns.mainFrame:StopMovingOrSizing()
		end
	end)
	playtimeWidgets.levels:SetScript("OnMouseWheel", function(_, delta)
		local offset = playtimeWidgets.levelScrollOffset or 0
		playtimeWidgets.levelScrollOffset = offset + (delta > 0 and -1 or 1)
		RefreshPlaytime()
	end)
	-- Hovering a level row shows when it began, when it ended and how long it
	-- took. The rows are tall, so RowAtCursor uses the tall step.
	playtimeWidgets.levels:SetScript("OnUpdate", function()
		if ns.RowHoverTick then
			ns.RowHoverTick(playtimeWidgets.levels)
		end
	end)
	playtimeWidgets.levels:SetScript("OnLeave", function()
		local card = playtimeWidgets.levels
		card.hoverKey = nil
		if GameTooltip:IsOwned(card) then
			GameTooltip:Hide()
		end
	end)
	pageRefresh.playtime = RefreshPlaytime
end

-- Handed to the shell, which builds and refreshes every tab.
ns.BuildPlaytimePage, ns.RefreshPlaytime = BuildPlaytimePage, RefreshPlaytime
