-- Tally - the window itself and the wiring behind it.
--
-- This is the controller: it owns the frame, the tab bar, which tab is
-- open, the minimap icon, the viewer warning, the paused pill, the copy
-- window, and it hands each tab to its own file to build and refresh.
local addonName, ns = ...

local TABS, TAB_BY_ID, pages = ns.TABS, ns.TAB_BY_ID, ns.pages
local settingsWidgets = ns.settingsWidgets

-- Helpers and constants from the files loaded above (see Tally.toc).
local ACCENT, TILE_BACKDROP, RED, AMBER, ClassColorCode, GetAddonVersion, WINDOW_WIDTH, WINDOW_HEIGHT, ApplyIconPosition, ApplyTallyIcon, CreateIconButton, BuildCharacterPage, RefreshOverview, BuildSettingsPage, RefreshSettings, BuildPlaytimePage, BuildEconomyPage, BuildCombatPage, BuildLootPage, BuildExplorePage, BuildTotalPage, ShowCharPicker, charPickers, economyWidgets, pageRefresh =
	ns.ACCENT, ns.TILE_BACKDROP, ns.RED, ns.AMBER, ns.ClassColorCode, ns.GetAddonVersion, ns.WINDOW_WIDTH, ns.WINDOW_HEIGHT, ns.ApplyIconPosition, ns.ApplyTallyIcon, ns.CreateIconButton, ns.BuildCharacterPage, ns.RefreshOverview, ns.BuildSettingsPage, ns.RefreshSettings, ns.BuildPlaytimePage, ns.BuildEconomyPage, ns.BuildCombatPage, ns.BuildLootPage, ns.BuildExplorePage, ns.BuildTotalPage, ns.ShowCharPicker, ns.charPickers, ns.economyWidgets, ns.pageRefresh

-- The Character tab's refresh is owned by its shell; the fallback keeps the
-- old overview draw working if that file ever fails to load.
local function RefreshCharacterPage()
	if ns.RefreshCharacter then
		ns.RefreshCharacter()
	else
		RefreshOverview()
	end
end
-- Handles to widgets created further down, set by the build functions and
-- read by the refreshers and the slash commands.
local mainFrame
local contentFrame
local tabButtons = {}
local activeTab = "overview"
local reportDropdown
local selectedReportType = "overview"
-- While another character is being looked at, the window says so twice: an
-- orange line around it and a red button naming the character being played,
-- which is the way back. The name itself is not written into the title.
local viewerWarning
-- Names the tab whose recording is switched off, beside the title, and
-- opens the setting that turned it off.
local pausedPill
local charDropdown
local copyFrame
local copyBox
-------------------------------------------------------------------------------
-- Tabs
-------------------------------------------------------------------------------

local function UpdateTabs()
	for id, button in pairs(tabButtons) do
		local isActive = (id == activeTab)
		button.underline:SetShown(isActive)
		if isActive then
			button.text:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])
		elseif button.tab.track and not ns.Tracks(id) then
			-- A paused tab stays readable but visibly quieter than the rest.
			button.text:SetTextColor(0.55, 0.55, 0.55)
		else
			button.text:SetTextColor(0.8, 0.8, 0.8)
		end
	end
end

-- The recording pill beside the title. It names what is not being recorded,
-- so a paused tab is visible from every page, and a click goes to the setting
-- that turned it off. Overview and Total show every area, so there it names
-- each paused area rather than one tab.
local function RefreshPausedPill()
	if not pausedPill then
		return
	end
	local tab = TAB_BY_ID[activeTab]
	local paused = {}
	if tab and tab.track then
		if not ns.Tracks(tab.id) then
			paused[1] = tab.title
		end
	elseif activeTab == "overview" or activeTab == "total" then
		for index = 1, #TABS do
			local entry = TABS[index]
			if entry.track and not ns.Tracks(entry.id) then
				paused[#paused + 1] = entry.title
			end
		end
	end
	if #paused == 0 then
		pausedPill:Hide()
		return
	end
	pausedPill.text:SetText("Recording is off for "..table.concat(paused, ", ").." - click to change")
	pausedPill:SetWidth(pausedPill.text:GetStringWidth() + 18)
	pausedPill:ClearAllPoints()
	if viewerWarning and viewerWarning:IsShown() then
		pausedPill:SetPoint("LEFT", viewerWarning, "RIGHT", 8, 0)
	else
		pausedPill:SetPoint("LEFT", mainFrame.TitleText, "RIGHT", 12, 0)
	end
	pausedPill:Show()
end

-- Called after a tracking switch changes: the tab colours and the pill both
-- depend on which areas are being recorded.
function ns.RefreshTrackingUI()
	UpdateTabs()
	RefreshPausedPill()
end

local function SelectTab(id)
	if not TAB_BY_ID[id] then
		return
	end
	activeTab = id
	-- The characters picker belongs to the view that opened it; changing tab
	-- closes it rather than leaving a window over a page it does not describe.
	if charPickers.panel and charPickers.panel.shown then
		ShowCharPicker(charPickers.panel.kind or "daily", false)
	end
	UpdateTabs()
	RefreshPausedPill()
	for pageId, page in pairs(pages) do
		page:SetShown(pageId == id)
	end
	if id == "overview" then
		RefreshCharacterPage()
	elseif id == "settings" then
		RefreshSettings()
	elseif pageRefresh[id] then
		pageRefresh[id]()
	end
end

-- Opens the Settings tab from anywhere in the window. Notes that point at a
-- setting use it, so the way to the setting is one click.
function ns.OpenSettings()
	SelectTab("settings")
end

local function CreateTabButton(parent, tab, x)
	local button = CreateFrame("Button", nil, parent)
	button.tab = tab
	button:SetHeight(20)
	button.text = button:CreateFontString(nil, "ARTWORK", "GameFontNormal")
	button.text:SetPoint("LEFT", 0, 0)
	button.text:SetText(tab.title)
	button:SetWidth(button.text:GetStringWidth() + 26)
	button:SetPoint("TOPLEFT", parent, "TOPLEFT", x, -34)

	button.underline = button:CreateTexture(nil, "ARTWORK")
	button.underline:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
	button.underline:SetHeight(2)
	button.underline:SetPoint("TOPLEFT", button.text, "BOTTOMLEFT", -2, -2)
	button.underline:SetPoint("TOPRIGHT", button.text, "BOTTOMRIGHT", 2, -2)
	button.underline:Hide()

	button:RegisterForClicks("LeftButtonUp")
	button:SetScript("OnClick", function()
		SelectTab(tab.id)
	end)
	button:SetScript("OnEnter", function(self)
		local paused = tab.track and not ns.Tracks(tab.id)
		if (not tab.desc or tab.desc == "") and not paused then
			return
		end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine(tab.title, ACCENT[1], ACCENT[2], ACCENT[3])
		if tab.desc and tab.desc ~= "" then
			GameTooltip:AddLine(tab.desc, 1, 1, 1, true)
		end
		if paused then
			GameTooltip:AddLine("Recording is off for this tab - what is stored is kept. Turn it back on in Settings.", 0.95, 0.72, 0.3, true)
		end
		GameTooltip:Show()
	end)
	button:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	return button
end

-------------------------------------------------------------------------------
-- The character viewer: the banner and the picker
------------------------------------------------------------------------------

-- Keeps the viewer's warning in step with ns.ViewChar(). Read-only: it says
-- which character the numbers belong to and offers the way back.
local function RefreshViewer()
	if not mainFrame then
		return
	end
	local viewed = ns.ViewChar()
	local live = ns.GetChar()
	local function ColoredName(char, fallback)
		local color = char and ClassColorCode(char.classFile)
		return (color or "")..((char and ns.DisplayName(char)) or fallback)..(color and "|r" or "")
	end
	local liveName = ColoredName(live, "this character")
	-- The line around the window and the button beside the title, both shown
	-- only while the window is describing somebody other than the character
	-- being played.
	local edges = mainFrame.viewerEdges or {}
	for index = 1, #edges do
		edges[index]:SetShown(viewed ~= nil)
	end
	if viewerWarning then
		if viewed then
			-- Short and specific: the button names the character a click goes
			-- back to, so there is no doubt about what it does.
			viewerWarning.text:SetText("select '"..((live and ns.DisplayName(live)) or "this character").."'")
			viewerWarning:SetWidth(viewerWarning.text:GetStringWidth() + 18)
			viewerWarning:Show()
		else
			viewerWarning:Hide()
		end
	end
	if charDropdown then
		if viewed then
			UIDropDownMenu_SetText(charDropdown, ColoredName(viewed, "?").." (not live)")
		else
			UIDropDownMenu_SetText(charDropdown, liveName.." (this character)")
		end
	end
	if settingsWidgets.deleteButton then
		settingsWidgets.deleteButton:SetShown(viewed ~= nil)
	end
	RefreshPausedPill()
end

-- The single entry point that changes what the window looks at: sets the
-- viewer and re-renders the open tab. Any tooltip a card owns is dropped, so
-- a hover left over from the last character cannot outlive the switch.
local function ApplyView(key)
	ns.SetView(key)
	local cards = economyWidgets.profCards or {}
	for index = 1, #cards do
		cards[index].hoverKey = nil
		if GameTooltip:IsOwned(cards[index]) then
			GameTooltip:Hide()
		end
	end
	local secondary = economyWidgets.secondaryCard
	if secondary then
		secondary.hoverKey = nil
		if GameTooltip:IsOwned(secondary) then
			GameTooltip:Hide()
		end
	end
	if ns.ClearTotalProfessionsHover then
		ns.ClearTotalProfessionsHover()
	end
	RefreshViewer()
	if activeTab then
		SelectTab(activeTab)
	end
end

------------------------------------------------------------------------------
-- The main window
-------------------------------------------------------------------------------

local function SelectReportType(key, silent)
	if not ns.reports.IsType(key) then
		key = "overview"
	end
	selectedReportType = key
	if reportDropdown then
		UIDropDownMenu_SetSelectedValue(reportDropdown, key)
		-- The dropdown picks the report that Print and Copy produce; it does
		-- not switch tabs.
		UIDropDownMenu_SetText(reportDropdown, "Print/Copy: "..ns.reports.Title(key))
	end
	if not silent then
		ns.PlayUISound("IG_MAINMENU_OPTION_CHECKBOX_ON")
	end
end

local function CreateMainFrame()
	local frame = CreateFrame("Frame", "TallyFrame", UIParent, "BasicFrameTemplateWithInset")
	mainFrame = frame
	-- The page files drag the window through this handle, so it is shared.
	ns.mainFrame = frame
	frame:SetSize(WINDOW_WIDTH, WINDOW_HEIGHT)
	frame:SetPoint("CENTER")
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:Hide()
	if frame.TitleText then
		frame.TitleText:SetText("Tally "..GetAddonVersion())
	end
	-- The stock title band is 18 pixels tall, shorter than the 22 pixel
	-- icon, so the icon used to hang over the inset and look like it was
	-- falling out of the bar. Give the band the icon's height, and put the
	-- icon on the overlay layer so the frame's own border art cannot cover
	-- it.
	if frame.TitleBg then
		frame.TitleBg:SetHeight(24)
	end
	local titleIcon = frame:CreateTexture(nil, "OVERLAY", nil, 1)
	ApplyTallyIcon(titleIcon)
	titleIcon:SetSize(22, 22)
	titleIcon:SetPoint("TOPLEFT", frame, "TOPLEFT", 10, -2)
	table.insert(UISpecialFrames, "TallyFrame")

	-- Small screens: shrink the whole window just enough to stay usable.
	local screenHeight = (UIParent and UIParent:GetHeight()) or (GetScreenHeight and GetScreenHeight()) or 768
	if screenHeight < WINDOW_HEIGHT + 120 then
		local scale = math.max(0.8, (screenHeight - 100) / WINDOW_HEIGHT)
		if scale < 0.995 then
			frame:SetScale(scale)
		end
	end

	-- Tab bar.
	local x = 22
	for index = 1, #TABS do
		local tab = TABS[index]
		local button = CreateTabButton(frame, tab, x)
		tabButtons[tab.id] = button
		x = x + button:GetWidth() + 6
	end

	-- The viewer's warning: an orange line just inside the window's own border
	-- and a red button beside the title naming the character a click goes back
	-- to. Both are hidden while the window describes the character being
	-- played; the name is not written into the title itself.
	frame.viewerEdges = {}
	local function AddEdge(pointA, pointB, offsetA, offsetB, isTop)
		local line = frame:CreateTexture(nil, "OVERLAY")
		line:SetColorTexture(1, 0.55, 0.1, 0.9)
		if isTop then
			line:SetHeight(2)
		else
			line:SetWidth(2)
		end
		line:SetPoint(pointA, frame, pointA, offsetA[1], offsetA[2])
		line:SetPoint(pointB, frame, pointB, offsetB[1], offsetB[2])
		line:Hide()
		frame.viewerEdges[#frame.viewerEdges + 1] = line
	end
	AddEdge("TOPLEFT", "TOPRIGHT", { 3, -3 }, { -3, -3 }, true)
	AddEdge("BOTTOMLEFT", "BOTTOMRIGHT", { 3, 3 }, { -3, 3 }, true)
	AddEdge("TOPLEFT", "BOTTOMLEFT", { 3, -3 }, { 3, 3 }, false)
	AddEdge("TOPRIGHT", "BOTTOMRIGHT", { -3, -3 }, { -3, 3 }, false)

	viewerWarning = CreateFrame("Button", nil, frame, "BackdropTemplate")
	viewerWarning:SetHeight(16)
	viewerWarning:SetBackdrop(TILE_BACKDROP)
	viewerWarning:SetBackdropColor(0.55, 0.08, 0.08, 0.95)
	viewerWarning:SetBackdropBorderColor(1, 0.4, 0.4, 0.5)
	viewerWarning.text = viewerWarning:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	viewerWarning.text:SetPoint("LEFT", 7, 0)
	viewerWarning.text:SetTextColor(1, 1, 1)
	viewerWarning:SetPoint("LEFT", frame.TitleText, "RIGHT", 12, 0)
	viewerWarning:RegisterForClicks("LeftButtonUp")
	viewerWarning:SetScript("OnClick", function()
		ApplyView(nil)
	end)
	viewerWarning:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("You are looking at another character", ACCENT[1], ACCENT[2], ACCENT[3])
		local viewed = ns.ViewChar()
		local seen = viewed and ns.LastSeen(viewed)
		GameTooltip:AddLine("Last seen: "..(seen and ns.FormatDateTime(seen) or "unknown")..".", 1, 1, 1, true)
		GameTooltip:AddLine("These are the last numbers Tally recorded for them, not live data - Tally cannot see a character who is not logged in.", 1, 1, 1, true)
		GameTooltip:AddLine("Click to go back to the character you are playing.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	viewerWarning:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	viewerWarning:Hide()

	-- The recording pill, in the same row as the viewer warning. Amber rather
	-- than red: nothing is wrong, a tab is simply not being recorded.
	pausedPill = CreateFrame("Button", nil, frame, "BackdropTemplate")
	pausedPill:SetHeight(16)
	pausedPill:SetBackdrop(TILE_BACKDROP)
	pausedPill:SetBackdropColor(0.45, 0.32, 0.05, 0.95)
	pausedPill:SetBackdropBorderColor(0.95, 0.72, 0.3, 0.55)
	pausedPill.text = pausedPill:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	pausedPill.text:SetPoint("LEFT", 7, 0)
	pausedPill.text:SetTextColor(1, 1, 1)
	pausedPill:SetPoint("LEFT", frame.TitleText, "RIGHT", 12, 0)
	pausedPill:RegisterForClicks("LeftButtonUp")
	pausedPill:SetScript("OnClick", function()
		SelectTab("settings")
	end)
	pausedPill:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Recording is off", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Nothing is deleted: the figures already stored are still shown, and nothing new is being written. Click to open Settings and switch the recording back on.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	pausedPill:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)
	pausedPill:Hide()

	-- Content area: every page fills this frame.
	contentFrame = CreateFrame("Frame", nil, frame)
	ns.contentFrame = contentFrame
	contentFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -62)
	contentFrame:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 58)

	-- Every page fills the content frame and starts hidden: a frame is drawn
	-- as soon as it is created, so the pages would otherwise be stacked on
	-- one another until the first SelectTab runs.
	local function NewPage(id)
		local page = CreateFrame("Frame", nil, contentFrame)
		page:SetAllPoints(contentFrame)
		page:Hide()
		pages[id] = page
		return page
	end

	BuildCharacterPage(NewPage("overview"))
	BuildSettingsPage(NewPage("settings"))

	-- The character tabs. Each build function registers its own refresh in
	-- pageRefresh, which SelectTab calls when the tab is opened.
	local characterTabs = {
		{ id = "playtime", build = BuildPlaytimePage },
		{ id = "economy", build = BuildEconomyPage },
		{ id = "combat", build = BuildCombatPage },
		{ id = "loot", build = BuildLootPage },
		{ id = "explore", build = BuildExplorePage },
		{ id = "total", build = BuildTotalPage },
	}
	for index = 1, #characterTabs do
		local spec = characterTabs[index]
		local page = NewPage(spec.id)
		-- One page failing to build must not take the rest of the window with
		-- it, and it must not leave a half-built page on screen.
		local ok, err = pcall(spec.build, page)
		if not ok then
			ns.Trace("build: the "..spec.id.." page failed and was left empty: "..tostring(err))
		end
	end

	-- Footer: the character the window describes stays on the left, as the
	-- picker shows a name; everything else - the report picker, Print and
	-- Copy - is right-aligned around the corner button.
	local separator = frame:CreateTexture(nil, "ARTWORK")
	separator:SetColorTexture(1, 1, 1, 0.06)
	separator:SetHeight(1)
	separator:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 14, 52)
	separator:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 52)

	local copyButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	copyButton:SetSize(80, 22)
	copyButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -14, 16)
	copyButton:SetText("Copy")
	copyButton:SetScript("OnClick", function()
		ns.reports.Copy(selectedReportType)
	end)

	local printButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	printButton:SetSize(80, 22)
	printButton:SetPoint("BOTTOMRIGHT", copyButton, "BOTTOMLEFT", -8, 0)
	printButton:SetText("Print")
	printButton:SetScript("OnClick", function()
		ns.reports.Print(selectedReportType)
	end)

	reportDropdown = CreateFrame("Frame", "TallyReportDropDown", frame, "UIDropDownMenuTemplate")
	-- Right-aligned: the picker sits to the left of Print. The dropdown
	-- template keeps a margin of its own around the text, so the frame's
	-- right edge is pulled in past the button by a few pixels.
	reportDropdown:SetPoint("BOTTOMRIGHT", printButton, "BOTTOMLEFT", -6, -2)
	UIDropDownMenu_SetWidth(reportDropdown, 150)
	UIDropDownMenu_Initialize(reportDropdown, function()
		for index = 1, #ns.REPORT_ORDER do
			local key = ns.REPORT_ORDER[index]
			local info = UIDropDownMenu_CreateInfo()
			info.text = ns.reports.Title(key)
			info.value = key
			info.checked = (key == selectedReportType)
			info.func = function()
				SelectReportType(key)
			end
			UIDropDownMenu_AddButton(info)
		end
	end)
	SelectReportType("overview", true)

	-- Character picker, left-aligned: this is the name the window describes.
	-- Tally can show any character it has recorded; this only changes what is
	-- on screen, never what is written.
	charDropdown = CreateFrame("Frame", "TallyCharacterDropDown", frame, "UIDropDownMenuTemplate")
	charDropdown:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 4, 12)
	UIDropDownMenu_SetWidth(charDropdown, 196)
	UIDropDownMenu_Initialize(charDropdown, function()
		local known = ns.KnownCharacters()
		for index = 1, #known do
			local entry = known[index]
			local char = entry.char
			local info = UIDropDownMenu_CreateInfo()
			local nameColor = ClassColorCode(char.classFile) or ""
			local nameText = nameColor..ns.DisplayName(char)..(nameColor ~= "" and "|r" or "")
			if entry.live then
				info.text = string.format("%s (this character)", nameText)
			else
				info.text = string.format("%s - %s %s, seen %s", nameText, char.level or 0, char.class or "?", entry.seen and ns.FormatDate(entry.seen) or "?")
			end
			info.checked = (entry.key == ns.viewKey) or (entry.live and not ns.IsViewing())
			info.func = function()
				ApplyView(entry.live and nil or entry.key)
			end
			UIDropDownMenu_AddButton(info)
		end
	end)
	charDropdown:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		GameTooltip:AddLine("Which character Tally shows", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("This is every character Tally has watched - the game gives an addon no way to read a character who has not logged in with it loaded.", 1, 1, 1, true)
		GameTooltip:AddLine("Looking at another character is read-only: you see the last numbers Tally recorded for them, and nothing is written to them.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	charDropdown:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	frame:SetScript("OnShow", function()
		SelectTab(activeTab == "overview" and "overview" or activeTab)
		RefreshCharacterPage()
		RefreshSettings()
		RefreshViewer()
	end)

	SelectTab("overview")
	RefreshViewer()
end

-- A scroll frame that clips its content; the content frame is moved up and
-- down by hand from the scrollbar value. Returns host, content, bar,
-- ApplyScroll and UpdateBar.
local function CreateScrollArea(parent, left, top, right, bottom)
	local host = CreateFrame("ScrollFrame", nil, parent)
	host:SetPoint("TOPLEFT", parent, "TOPLEFT", left, top)
	host:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", right, bottom)
	host:EnableMouse(true)
	host:EnableMouseWheel(true)

	local content = CreateFrame("Frame", nil, host)
	content:SetPoint("TOPLEFT", 0, 0)
	content:SetPoint("TOPRIGHT", 0, 0)
	content:SetHeight(2)

	local bar = CreateFrame("Slider", nil, host, "UIPanelScrollBarTemplate")
	bar:SetPoint("TOPLEFT", host, "TOPRIGHT", 4, -16)
	bar:SetPoint("BOTTOMLEFT", host, "BOTTOMRIGHT", 4, 16)
	bar:SetMinMaxValues(0, 1000)
	bar:SetValueStep(1)
	bar:SetValue(0)

	local function ApplyScroll(value)
		if not value or value < 0 then
			value = 0
		elseif value > 1000 then
			value = 1000
		end
		local maxOffset = (content:GetHeight() or 0) - (host:GetHeight() or 0)
		local offset = 0
		if maxOffset > 0 then
			offset = math.floor(maxOffset / 1000 * value + 0.5)
		end
		content:ClearAllPoints()
		content:SetPoint("TOPLEFT", 0, offset)
		content:SetPoint("TOPRIGHT", 0, offset)
	end

	local function UpdateBar()
		local overflow = (content:GetHeight() or 0) > (host:GetHeight() or 0) + 2
		bar:SetShown(overflow)
		if not overflow then
			bar:SetValue(0)
			ApplyScroll(0)
		end
	end

	bar:SetScript("OnValueChanged", function(_, value)
		ApplyScroll(value)
	end)
	host:SetScript("OnMouseWheel", function(_, delta)
		if not bar:IsShown() then
			return
		end
		local maxOffset = (content:GetHeight() or 0) - (host:GetHeight() or 0)
		if maxOffset <= 0 then
			return
		end
		local value = bar:GetValue() - delta * (60 / maxOffset) * 1000
		if value < 0 then
			value = 0
		elseif value > 1000 then
			value = 1000
		end
		bar:SetValue(value)
	end)

	if host.SetScrollChild then
		host:SetScrollChild(content)
	end

	return host, content, bar, ApplyScroll, UpdateBar
end

-------------------------------------------------------------------------------
-- Copy window: a selectable EditBox holding the report text, for clients
-- that keep CopyToClipboard for Blizzard code. The player selects the text
-- and presses Ctrl+C.
-------------------------------------------------------------------------------

local function CreateCopyFrame()
	local frame = CreateFrame("Frame", "TallyCopyFrame", UIParent, "BasicFrameTemplateWithInset")
	copyFrame = frame
	frame:SetSize(520, 440)
	frame:SetPoint("CENTER", UIParent, "CENTER", -40, 0)
	frame:SetMovable(true)
	frame:EnableMouse(true)
	frame:RegisterForDrag("LeftButton")
	frame:SetScript("OnDragStart", frame.StartMoving)
	frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
	frame:SetFrameStrata("HIGH")
	frame:SetToplevel(true)
	frame:Hide()
	frame.TitleText:SetText("Copy a Tally report")
	table.insert(UISpecialFrames, "TallyCopyFrame")

	local hint = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	hint:SetPoint("TOPLEFT", frame, "TOPLEFT", 18, -36)
	hint:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -18, -36)
	hint:SetJustifyH("LEFT")
	hint:SetTextColor(0.66, 0.66, 0.66)
	hint:SetText("The text below is already selected - press Ctrl+C to copy it, then close this window.")

	local scroll = CreateFrame("ScrollFrame", "TallyCopyScroll", frame, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", frame, "TOPLEFT", 20, -58)
	scroll:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -36, 50)

	copyBox = CreateFrame("EditBox", nil, scroll)
	copyBox:SetMultiLine(true)
	copyBox:SetFontObject(ChatFontNormal)
	copyBox:SetWidth(430)
	copyBox:SetAutoFocus(false)
	copyBox:SetMaxLetters(4000)
	copyBox:SetTextColor(0.88, 0.88, 0.88)
	copyBox:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
	end)
	scroll:SetScrollChild(copyBox)

	local selectButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	selectButton:SetSize(90, 22)
	selectButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -104, 18)
	selectButton:SetText("Select all")
	selectButton:SetScript("OnClick", function()
		copyBox:SetFocus()
		copyBox:HighlightText()
	end)

	local closeButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
	closeButton:SetSize(80, 22)
	closeButton:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -18, 18)
	closeButton:SetText("Close")
	closeButton:SetScript("OnClick", function()
		frame:Hide()
	end)

	frame:SetScript("OnShow", function()
		copyBox:SetFocus()
		copyBox:HighlightText()
	end)
end

function ns.OpenCopyWindow(title, text)
	if not copyFrame then
		return false
	end
	text = tostring(text or "")
	if copyFrame.TitleText then
		copyFrame.TitleText:SetText("Copy: "..(title or "report"))
	end
	-- The box is sized to the text it is handed, capped at 60000 letters
	-- (reports are far shorter; the /tally trace dump is not).
	local letters = #text + 100
	if letters > 60000 then
		letters = 60000
	end
	copyBox:SetMaxLetters(letters)
	copyBox:SetText(text)
	copyBox:SetCursorPosition(0)
	copyFrame:Show()
	copyBox:SetFocus()
	copyBox:HighlightText()
	return true
end

-------------------------------------------------------------------------------
-- Popups
-------------------------------------------------------------------------------

StaticPopupDialogs["TALLY_RESET_CHARACTER"] = {
	text = "Erase every statistic Tally has recorded for %s? This cannot be undone.",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		ns.ResetCharStats()
		ns.Print("Statistics for this character were reset.")
		RefreshSettings()
		RefreshCharacterPage()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

-- Deleting a character's record outright. The popup names the full character
-- (name and realm) and says exactly what goes, because nothing can bring it
-- back: it is the only way to clear a record whose character is gone.
StaticPopupDialogs["TALLY_DELETE_CHARACTER"] = {
	text = "Delete ALL DATA Tally has recorded for %s (%s)? Every statistic, every session, every quest and every ledger entry goes. This cannot be undone.",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		ns.DeleteViewedRecord()
		ns.Print("The record for that character was deleted.")
		RefreshSettings()
		RefreshCharacterPage()
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

-- The posting repair. It only lowers counts whose auctions cannot be
-- accounted for, and asks for the mail and the owned list to be current
-- first, since the still-up count is what completes the figure.
StaticPopupDialogs["TALLY_REPAIR_AUCTIONS"] = {
	text = "Lower this character's auction postings from %s to %s? The extra ones have no sale, expiry or cancellation behind them. Sales, purchases and finds are not touched. Collect every auction mail and open the auction house first, so the still-up count is current.",
	button1 = YES,
	button2 = NO,
	OnAccept = function()
		local char = ns.pendingAuctionRepair
		ns.pendingAuctionRepair = nil
		if not char then
			return
		end
		local removed = ns.RepairAuctionPostings(char)
		ns.Print(removed.." posting"..(removed == 1 and "" or "s")
			.." removed; the count now matches the auctions Tally saw end or still up.")
		if ns.OnDataTick then
			ns.OnDataTick()
		end
		RefreshSettings()
		RefreshCharacterPage()
	end,
	OnCancel = function()
		ns.pendingAuctionRepair = nil
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
}

-------------------------------------------------------------------------------
-- Public entry points (called from Core and the slash commands)
-------------------------------------------------------------------------------

function ns.ToggleMainWindow()
	if not mainFrame then
		return
	end
	if mainFrame:IsShown() then
		mainFrame:Hide()
	else
		ns.PlayUISound("IG_MAINMENU_OPEN")
		mainFrame:Show()
	end
end

-- Called by Core on every ticker step and after data changes; only redraws
-- while the window is shown.
function ns.OnDataTick()
	if mainFrame and mainFrame:IsShown() then
		if activeTab == "overview" then
			RefreshCharacterPage()
		elseif pageRefresh[activeTab] then
			-- Redraws the open character tab as well; its figures move while
			-- the character is played.
			pageRefresh[activeTab]()
		end
	end
end

function ns.BuildUI()
	ns.Trace("build: minimap icon")
	CreateIconButton()
	ns.Trace("build: main window")
	CreateMainFrame()
	ns.Trace("build: copy window")
	CreateCopyFrame()
	ns.Trace("build: icon state")
	ns.UpdateIconState()
	ApplyIconPosition()
	ns.Trace("build: done")
end

ns.Trace("ui file load done")

