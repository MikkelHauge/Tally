-- Tally - the Settings tab: what Tally records, what the window does,
-- and the two buttons that remove data.
local addonName, ns = ...

-- The checkboxes the refresher rewrites when a setting changes.
local settingsWidgets = { refreshers = {} }

-- Helpers and constants from the files loaded above (see Tally.toc).
local ACCENT, ClassColorCode, AddPageNote, pageRefresh =
	ns.ACCENT, ns.ClassColorCode, ns.AddPageNote, ns.pageRefresh
-------------------------------------------------------------------------------
-- Settings page
-------------------------------------------------------------------------------

local function AddDividerHeading(parent, text, y)
	local header = parent:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	header:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y)
	header:SetText(text)
	header:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
	local line = parent:CreateTexture(nil, "ARTWORK")
	line:SetColorTexture(1, 1, 1, 0.08)
	line:SetHeight(1)
	line:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, y - 20)
	line:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -8, y - 20)
	return y - 28
end

-- How many stored values were first seen at login or came from an older
-- record. Settings says so plainly; the audit has the full list.
local function CountLoginValues(char)
	local count = 0
	local function Check(entry)
		if type(entry) == "table"
			and (entry.observed == "login" or entry.observed == "migration") then
			count = count + 1
		end
	end
	local milestones = char.milestones or {}
	for _, entry in pairs(milestones.firsts or {}) do
		Check(entry)
	end
	for _, bucket in pairs(milestones.thresholds or {}) do
		if type(bucket) == "table" then
			for _, byThreshold in pairs(bucket) do
				if type(byThreshold) == "table" then
					for _, entry in pairs(byThreshold) do
						Check(entry)
					end
				end
			end
		end
	end
	for _, entry in ipairs((char.levels and char.levels.history) or {}) do
		Check(entry)
	end
	if type(char.firstSeen) == "table" then
		Check(char.firstSeen)
	end
	return count
end

-- One setting: a label on the left, its checkbox on the right edge of the
-- column, and an optional hover note. indent pushes the label in, for a
-- setting that belongs to the one above it.
local function AddCheckboxRow(parent, y, title, getter, setter, tip, indent)
	local label = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
	label:SetPoint("TOPLEFT", parent, "TOPLEFT", 12 + (indent or 0), y)
	label:SetText(title)

	local checkbox = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
	checkbox:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -14, y + 2)
	checkbox:SetScript("OnClick", function(self)
		local checked = self:GetChecked() and true or false
		if checked then
			ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON")
		else
			ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_OFF")
		end
		setter(checked)
	end)
	-- A setting whose label cannot say everything it means explains itself
	-- on hover, so the note under it stays short enough for the column.
	if tip then
		checkbox:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(title, ACCENT[1], ACCENT[2], ACCENT[3])
			GameTooltip:AddLine(tip, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		checkbox:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
	end
	settingsWidgets.refreshers[#settingsWidgets.refreshers + 1] = function()
		checkbox:SetChecked(getter() and true or false)
	end
	return y - 28
end

-- Two columns keep every row short enough to scan: what the window does on
-- the left, what Tally records and reports on the right. The character's own
-- notes run across the foot, above the buttons.
local function BuildSettingsPage(page)
	local left = CreateFrame("Frame", nil, page)
	left:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	left:SetSize(355, 300)

	local right = CreateFrame("Frame", nil, page)
	right:SetPoint("TOPLEFT", page, "TOPLEFT", 377, 0)
	right:SetSize(355, 300)

	local y = -4
	y = AddDividerHeading(left, "Window", y)
	-- Puts the button back where it starts, for anyone who has dragged it
	-- somewhere they no longer like. It rides the heading row, so the column
	-- below keeps its height.
	local resetIconButton = CreateFrame("Button", nil, left, "UIPanelButtonTemplate")
	resetIconButton:SetSize(120, 20)
	resetIconButton:SetPoint("TOPRIGHT", left, "TOPRIGHT", -8, -2)
	resetIconButton:SetText("Reset minimap")
	resetIconButton:SetScript("OnClick", function()
		ns.ResetIconPosition()
		ns.Print("Minimap button back at its default spot.")
	end)
	y = AddCheckboxRow(left, y, "Show the minimap button", function()
		return ns.db.settings.icon.shown
	end, function(value)
		ns.db.settings.icon.shown = value
		ns.UpdateIconState()
	end, "The round button that opens Tally and shows the minimap. Hidden, /tally still opens the window.")
	y = AddCheckboxRow(left, y, "Lock the minimap button in place", function()
		return ns.db.settings.icon.locked
	end, function(value)
		ns.db.settings.icon.locked = value
	end, "Stops the button being dragged around the minimap. Unlock it to move it again.")

	local chatHeadingY = y
	y = AddDividerHeading(left, "Chat", y)
	-- The notification options cover chat and chimes as well as cooldowns, so
	-- they sit on the Chat heading where players look for message settings.
	local notifyButton = CreateFrame("Button", nil, left, "UIPanelButtonTemplate")
	notifyButton:SetSize(160, 20)
	notifyButton:SetPoint("TOPRIGHT", left, "TOPRIGHT", -8, chatHeadingY - 2)
	notifyButton:SetText("Profession notifications")
	notifyButton:SetScript("OnClick", function()
		if ns.OpenProfessionNotifyPanel then
			ns.OpenProfessionNotifyPanel()
		end
	end)
	notifyButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Profession notifications", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Cooldown ready alerts, skill-cap messages and trainer reminders, with their chime and character list.", 1, 1, 1, true)
		GameTooltip:AddLine("Click to open the options.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	notifyButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	y = AddCheckboxRow(left, y, "Print data on level up", function()
		return ns.db.settings.announceLevelUps
	end, function(value)
		ns.db.settings.announceLevelUps = value
	end, "A short line in chat when you level, with the time it took.")
	y = AddCheckboxRow(left, y, "Quiet login message", function()
		return ns.db.settings.quiet
	end, function(value)
		ns.db.settings.quiet = value
	end, "Stops the \"loaded\" line when you log in. Errors and warnings are still printed.")

	y = AddDividerHeading(left, "Played time", y)
	y = AddCheckboxRow(left, y, "Ask the game for /played automatically", function()
		return ns.db.settings.autoPlayedSync
	end, function(value)
		ns.db.settings.autoPlayedSync = value
		if value then
			-- Clears playedSyncBlocked and requests a /played reading now.
			ns.db.settings.playedSyncBlocked = false
			ns.RequestPlayedSync()
		end
	end, "The game answers by printing your played time. Tally reads that line and keeps its own request's answer off the chat frame, so the refresh is silent; a /played you type yourself is always shown.")
	AddPageNote(left, 12, y, 331, "The only way to account for time Tally was not running for.")
	y = y - 26
	y = AddCheckboxRow(left, y, "Estimate levels Tally did not see", function()
		return ns.db.settings.levelEstimate
	end, function(value)
		ns.db.settings.levelEstimate = value
	end, "Off by default. When Tally was not running for a stretch of levels, the game still measures that stretch as one total: this shares it equally between the levels inside it, draws the points faint and marks them (est.), and the filled seconds add back up to the game's own figure. A stretch Tally watched in full keeps its measured split. The levels before Tally's first reading are shared out too, assuming the character began at level 1; a class that begins above level 1 is left out.")
	-- AFK time is counted by default, so tracked time and the server's
	-- /played stay close. The switch is there for anyone who wants only the
	-- time they were actually at the keyboard.
	y = AddCheckboxRow(left, y, "Leave AFK time out of played time", function()
		return ns.db.settings.excludeAfk
	end, function(value)
		ns.db.settings.excludeAfk = value
	end, "Off by default: time flagged AFK still counts, so Tally's tracked time stays close to the server's /played figure. Tick it to count only time at the keyboard; XP per hour and session averages then ignore AFK as well.")
	local r = -4
	-- One row per primary tab. The label names the tab; the hover says what
	-- stops, since a narrow column cannot carry a note under every row.
	local function AddTrackRow(title, area, tip)
		r = AddCheckboxRow(right, r, title, function()
			return ns.Tracks(area)
		end, function(value)
			ns.SetTracked(area, value)
			if ns.RefreshTrackingUI then
				ns.RefreshTrackingUI()
			end
		end, tip)
	end

	r = AddDividerHeading(right, "What Tally records", r)
	AddTrackRow("Playtime - sessions and level-ups", "playtime", "Sessions, the time Tally watches, level-ups and the experience it samples. Off stops the clock, the /played sync and the level-up line; money still records the purse, but a session is playtime's record, so per-session figures stop too. Nothing already recorded is deleted.")
	AddTrackRow("Economy - gold, professions and auctions", "economy", "The gold balance and its ledger, the professions, and the auction house: what was posted, what sold and for how much. Off stops reading the purse, so money that moves meanwhile is booked as unclassified when it comes back. Nothing already recorded is deleted.")
	AddTrackRow("Combat - fights, kills, deaths and auras", "combat", "Fights, kills, deaths and the buffs and debuffs Tally watches. Off stops counting them, including the nameplate and combat-log reads. Nothing already recorded is deleted.")
	if ns.CombatLogUsable and ns.CombatLogUsable() then
		r = AddCheckboxRow(right, r, "Read kills from the combat log", function()
			return ns.db.settings.combatLogRead
		end, function(value)
			ns.db.settings.combatLogRead = value
			if ns.ApplyCombatLogSetting then
				ns.ApplyCombatLogSetting()
			end
		end, "Only used while Combat is recorded. Where the game offers it, the combat log gives the most accurate kills, including instances. Where it does not, Tally uses the game's kill events and, inside instances, experience lines and looted corpses. This is off by default because some clients refuse the read with a blocked-action popup.", 14)
	else
		AddPageNote(right, 26, r, 317, "This game does not hand the combat log to addons; world kills come from the game's kill events and instance kills from experience lines and looted corpses.")
		r = r - 26
	end
	AddTrackRow("Loot - items and finds", "loot", "Items looted, by quality, the best finds and what they were worth. Off freezes these figures where they are: nothing more is counted or valued, and the loot already recorded stays exactly as it is. Nothing already recorded is deleted.")
	AddTrackRow("Explore - zones, travel and quests", "explore", "Zones visited, instances entered, bosses, travel, time on a mount - and the quests turned in, since they share the tab. Off stops counting them; the places and quests already recorded stay. Nothing already recorded is deleted.")
	AddPageNote(right, 12, r, 331, "Off stops only that tab and deletes nothing: no other tab's figures are touched, and what is stored stays on screen. Only the reset and delete buttons remove a character's record.")
	r = r - 44
	r = AddDividerHeading(right, "Reports", r)
	r = AddCheckboxRow(right, r, "Copy straight to the system clipboard", function()
		return ns.db.settings.copyDirect
	end, function(value)
		ns.db.settings.copyDirect = value
	end, "Copy puts the chosen report on the clipboard at once. With it off, a window shows the text so it can be copied by hand, which is the way out when the game refuses clipboard writes.")

	-- The character's own notes run across the foot, one column wide so a
	-- long line wraps at the full width instead of in a narrow half.
	settingsWidgets.charNote = AddPageNote(page, 12, -312, 660, "")
	settingsWidgets.dataNote = AddPageNote(page, 12, -324, 660, "")
	settingsWidgets.helpNote = AddPageNote(page, 12, -362, 660, "Tally records only characters who log in with it loaded; everything is stored locally in TallyDB.")
	settingsWidgets.unclassNote = AddPageNote(page, 12, -382, 660, "")
	settingsWidgets.healthNote = AddPageNote(page, 12, -402, 660, "")

	-- The buttons sit on the page's own bottom edge, so no column can push
	-- them past it into the window's footer.
	local resetButton = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
	resetButton:SetSize(260, 22)
	resetButton:SetPoint("BOTTOMLEFT", page, "BOTTOMLEFT", 12, 8)
	resetButton:SetText("Reset selected characters data")
	resetButton:SetScript("OnClick", function()
		local char = ns.GetChar()
		StaticPopup_Show("TALLY_RESET_CHARACTER", char and ns.DisplayName(char) or "this character")
	end)

	-- The way to clear a record whose character no longer exists. It acts on
	-- the character in the viewer (the foot bar), not the one being played:
	-- on that one it is the same as the reset button beside it. The popup
	-- names the full character and says that everything goes.
	local deleteButton = CreateFrame("Button", nil, page, "UIPanelButtonTemplate")
	deleteButton:SetSize(300, 22)
	deleteButton:SetPoint("LEFT", resetButton, "RIGHT", 8, 0)
	deleteButton:SetText("Delete all data for the selected character...")
	deleteButton:Hide()
	settingsWidgets.deleteButton = deleteButton
	deleteButton:SetScript("OnClick", function()
		local viewed = ns.ViewChar()
		local target = viewed or ns.GetChar()
		if not target then
			return
		end
		StaticPopup_Show("TALLY_DELETE_CHARACTER", ns.FullName(target), viewed and "the character in view" or "the character you are playing")
	end)
	deleteButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Delete a character's data", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Acts on the character in the viewer - pick one in the foot bar first. Used on the character you are playing it resets that character, exactly as the button on the left does.", 1, 1, 1, true)
		GameTooltip:AddLine("This cannot be undone.", 0.7, 0.7, 0.7, true)
		GameTooltip:Show()
	end)
	deleteButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	-- Which build this is, in the page's bottom-right corner: the title bar
	-- and the login line no longer carry the version.
	local versionText = page:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
	versionText:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", -14, 14)
	versionText:SetText("v"..ns.GetAddonVersion())
end

local function RefreshSettings()
	if not settingsWidgets.charNote then
		return
	end
	for index = 1, #settingsWidgets.refreshers do
		settingsWidgets.refreshers[index]()
	end
	local char = ns.GetChar()
	if not char then
		settingsWidgets.charNote:SetText("No character loaded yet.")
		settingsWidgets.dataNote:SetText("")
		settingsWidgets.unclassNote:SetText("")
		settingsWidgets.healthNote:SetText("")
		return
	end
	local charNameColor = ClassColorCode(char.classFile)
	local charNote = string.format("%s%s|r - %s, Level %d %s%s|r", charNameColor or "", ns.DisplayName(char), char.realm or "?", char.level or 0, ClassColorCode(char.classFile) or "", char.class or "?")
	if ns.IsViewing() then
		charNote = charNote.." (the character you are playing - the viewer does not change this page)"
	end
	settingsWidgets.charNote:SetText(charNote)
	local dataText = "Recording since "..ns.FormatDate(char.created).." - "..ns.FormatDuration(char.tracked).." tracked over "..char.sessions.count.." sessions."
	if ns.db.settings.playedSyncBlocked then
		dataText = dataText.." Automatic /played sync is off in this game; type /played to refresh the lifetime number."
	end
	if ns.killSource == "nameplate" then
		dataText = dataText.." World kills come from the game's kill events; inside instances Tally reads the experience lines and looted corpses."
	elseif ns.killSource == "log" then
		dataText = dataText.." Kills are counted from the combat log."
	elseif ns.CombatLogUsable and ns.CombatLogUsable() then
		dataText = dataText.." Kill tracking is off."
	end
	settingsWidgets.dataNote:SetText(dataText)
	if char.gold.unclassified.count > 0 then
		local cashIn, cashOut = ns.UnclassifiedTotals(char.gold)
		settingsWidgets.unclassNote:SetText("Heads-up: "..char.gold.unclassified.count.." money changes could not be classified ("..ns.MoneyColored(cashIn).." in, "..ns.MoneyColored(cashOut).." out). They are counted in the totals under \"unclassified\", never blamed on the wrong bucket.")
	else
		settingsWidgets.unclassNote:SetText("Every money change so far was classified.")
	end
	local lastAudit = ns.db.lastAuditAt and ns.FormatDate(ns.db.lastAuditAt) or "never"
	local lastBackup = ns.db.lastExportAt and ns.FormatDate(ns.db.lastExportAt) or "never"
	local loginValues = CountLoginValues(char)
	local health = "Schema "..tostring(ns.SchemaVersion and ns.SchemaVersion() or "?")
		.." · last audit "..lastAudit
		.." · last backup "..lastBackup
	if loginValues > 0 then
		health = health.." · "..loginValues..(loginValues == 1 and " value" or " values").." first seen at login"
	end
	health = health.." · use /tally export before a reset."
	settingsWidgets.healthNote:SetText(health)
end
ns.settingsWidgets = settingsWidgets
--@ENDFOOTER

-- Handed to the shell, which builds and refreshes every tab.
ns.BuildSettingsPage, ns.RefreshSettings = BuildSettingsPage, RefreshSettings
