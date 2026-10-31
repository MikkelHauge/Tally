-- Tally - cooldown notification options.
--
-- A small panel opened from the Economy professions page. It writes the
-- account-wide notification settings and the displayed character's
-- per-cooldown opt-outs; it never stores a second copy of any figure.
local addonName, ns = ...

local ACCENT, TILE_BACKDROP, AMBER, DisplayChar, ShowCharPicker, CutRowText =
	ns.ACCENT, ns.TILE_BACKDROP, ns.AMBER, ns.DisplayChar, ns.ShowCharPicker, ns.CutRowText

local PNPanel
local PNCheckboxes = {}
local PNDropdowns = {}
local PNEditBoxes = {}
local PNVolume
local PNVolumeText
local PNSelection
local PNListTitle
local PNListContent
local PNListNone
local PNRows = {}
local PNSyncing = false

local function PNSettings()
	return ns.ProfessionNotify.Settings()
end

-- A message-colour entry is drawn in the colour it names, using the same
-- |cff escape the chat message uses.
local function PNEntryLabel(entry)
	if not entry then
		return ""
	end
	if entry.r and entry.g and entry.b then
		return string.format("|cff%02x%02x%02x%s|r",
			math.floor(entry.r * 255 + 0.5),
			math.floor(entry.g * 255 + 0.5),
			math.floor(entry.b * 255 + 0.5),
			entry.label or entry.key or "")
	end
	return entry.label or entry.key or ""
end

local function PNRefreshRows()
	if ns.ScanItemCooldowns then
		ns.ScanItemCooldowns()
	end
	local char = DisplayChar()
	local settings = PNSettings()
	local list = char and ns.ProfessionCooldowns(char, {
		includeKnown = true,
		includeItems = settings.items ~= false,
	}) or {}
	local now = ns.Now()
	for index = 1, #list do
		local cd = list[index]
		local row = PNRows[index]
		if not row then
			row = CreateFrame("CheckButton", nil, PNListContent, "InterfaceOptionsCheckButtonTemplate")
			row:SetSize(20, 20)
			row:SetPoint("TOPLEFT", 0, -((index - 1) * 20))
			row.label = PNListContent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
			row.label:SetPoint("LEFT", row, "RIGHT", 2, 0)
			row:SetScript("OnClick", function(self)
				local owner, entry = self.ownerChar, self.ownerCd
				if owner and entry then
					ns.ProfessionNotify.SetEnabled(owner, entry.key, self:GetChecked() and true or false)
				end
				ns.PlayUISound(self:GetChecked() and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
				PNRefreshRows()
			end)
			row:SetScript("OnEnter", function(self)
				local entry = self.ownerCd
				if not entry then
					return
				end
				local ready = entry.readyAt and entry.readyAt > ns.Now()
					and ("Ready "..ns.FormatDateTime(entry.readyAt))
					or "Ready now."
				GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
				GameTooltip:AddLine(entry.name or "?", ACCENT[1], ACCENT[2], ACCENT[3])
				GameTooltip:AddLine((entry.profession or "?").." · "..ready, 1, 1, 1)
				GameTooltip:AddLine("Untick to keep this cooldown out of the notification for this character. The cooldown is still tracked and shown.", 0.7, 0.7, 0.7, true)
				GameTooltip:Show()
			end)
			row:SetScript("OnLeave", function()
				GameTooltip:Hide()
			end)
			PNRows[index] = row
		end
		row.ownerChar = char
		row.ownerCd = cd
		row:SetChecked(ns.ProfessionNotify.IsEnabled(char, cd.key))
		local state = "ready"
		if cd.readyAt and cd.readyAt > now then
			state = ns.FormatDuration(cd.readyAt - now, true).." left"
		end
		row.label:SetText(CutRowText((cd.name or "?")..(cd.profession and ("  ·  "..cd.profession) or "")..(cd.known and "" or ("  ·  "..state)), 58))
		row:Show()
	end
	for index = #list + 1, #PNRows do
		PNRows[index]:Hide()
	end
	PNListContent:SetHeight(math.max(1, #list * 20))
	PNListNone:SetShown(#list == 0)
end

local function PNRefresh()
	if not PNPanel then
		return
	end
	local settings = PNSettings()
	PNSyncing = true
	for key, checkbox in pairs(PNCheckboxes) do
		checkbox:SetChecked(checkbox.getter() and true or false)
	end
	PNEditBoxes.interval:SetText(tostring(settings.intervalValue or 30))
	PNEditBoxes.loginDelay:SetText(tostring(settings.loginDelay or 20))
	local units = { minutes = "minutes", hours = "hours", days = "days" }
	UIDropDownMenu_SetText(PNDropdowns.unit, units[settings.intervalUnit] or "minutes")
	local colourLabel = PNEntryLabel(ns.ProfessionNotify.Colours[1])
	for index = 1, #ns.ProfessionNotify.Colours do
		if ns.ProfessionNotify.Colours[index].key == settings.colourKey then
			colourLabel = PNEntryLabel(ns.ProfessionNotify.Colours[index])
			break
		end
	end
	UIDropDownMenu_SetText(PNDropdowns.colour, colourLabel)
	local chimeLabel = "No sound"
	local chimes = ns.ProfessionNotify.GetChimeEntries()
	for index = 1, #chimes do
		if chimes[index].key == settings.chimeKey then
			chimeLabel = chimes[index].label
			break
		end
	end
	UIDropDownMenu_SetText(PNDropdowns.chime, chimeLabel)
	if PNVolume then
		local volume = tonumber(settings.chimeVolume) or 0.8
		PNVolume:SetValue(volume)
		if PNVolumeText then
			PNVolumeText:SetText(tostring(math.floor(volume * 100 + 0.5)).."%")
		end
	end
	local selected = ns.charKey and ns.TotalIncludes(ns.charKey)
	PNSelection:SetText(selected and "Current character is selected." or "Current character is not selected - its cooldowns are not notified.")
	PNSelection:SetTextColor(selected and 0.65 or AMBER[1], selected and 0.65 or AMBER[2], selected and 0.65 or AMBER[3])
	local char = DisplayChar()
	PNListTitle:SetText(char and ("Cooldowns for "..(char.name or "this character")) or "Cooldowns")
	PNSyncing = false
	PNRefreshRows()
end

local function PNAddCheckbox(parent, x, y, label, key, getter, setter, tip)
	local checkbox = CreateFrame("CheckButton", nil, parent, "InterfaceOptionsCheckButtonTemplate")
	checkbox:SetSize(20, 20)
	checkbox:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	local text = parent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	text:SetPoint("LEFT", checkbox, "RIGHT", 3, 0)
	text:SetText(label)
	checkbox.getter = getter
	checkbox:SetScript("OnClick", function(self)
		setter(self:GetChecked() and true or false)
		ns.PlayUISound(self:GetChecked() and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
		PNRefresh()
	end)
	if tip then
		checkbox:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(label, ACCENT[1], ACCENT[2], ACCENT[3])
			GameTooltip:AddLine(tip, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		checkbox:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
	end
	PNCheckboxes[key] = checkbox
	return checkbox
end

local function PNAddEdit(parent, x, y, label, width, getter, setter, tip)
	local text = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	text:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y)
	text:SetText(label)
	local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
	box:SetSize(width or 42, 18)
	box:SetPoint("LEFT", text, "RIGHT", 8, 0)
	box:SetAutoFocus(false)
	box:SetMaxLetters(4)
	box:SetJustifyH("CENTER")
	box:SetScript("OnEnterPressed", function(self)
		local value = tonumber(self:GetText())
		if value and value >= 0 then
			setter(math.floor(value))
		end
		self:ClearFocus()
		PNRefresh()
	end)
	box:SetScript("OnEscapePressed", function(self)
		self:ClearFocus()
		PNRefresh()
	end)
	if tip then
		box:SetScript("OnEnter", function(self)
			GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
			GameTooltip:AddLine(label, ACCENT[1], ACCENT[2], ACCENT[3])
			GameTooltip:AddLine(tip, 1, 1, 1, true)
			GameTooltip:Show()
		end)
		box:SetScript("OnLeave", function()
			GameTooltip:Hide()
		end)
	end
	return box
end

local function PNAddDropdown(parent, x, y, label, width, getEntries, getter, setter)
	local text = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	text:SetPoint("TOPLEFT", parent, "TOPLEFT", x, y + 4)
	text:SetText(label)
	local dropdown = CreateFrame("Frame", nil, parent, "UIDropDownMenuTemplate")
	dropdown:SetPoint("LEFT", text, "RIGHT", -4, -2)
	UIDropDownMenu_SetWidth(dropdown, width or 110)
	UIDropDownMenu_Initialize(dropdown, function()
		local entries = getEntries()
		for index = 1, #entries do
			local entry = entries[index]
			local label = PNEntryLabel(entry)
			local info = UIDropDownMenu_CreateInfo()
			info.text = label
			info.value = entry.key
			info.checked = (entry.key == getter())
			info.func = function()
				setter(entry.key)
				UIDropDownMenu_SetText(dropdown, label)
				PNRefresh()
			end
			UIDropDownMenu_AddButton(info)
		end
	end)
	return dropdown
end

local function PNBuild(parent)
	PNPanel = CreateFrame("Frame", "TallyProfessionNotifyPanel", parent, "BackdropTemplate")
	PNPanel:SetSize(500, 440)
	PNPanel:SetPoint("CENTER", parent, "CENTER", 0, 0)
	PNPanel:SetFrameStrata("DIALOG")
	PNPanel:SetBackdrop(TILE_BACKDROP)
	PNPanel:SetBackdropColor(0.04, 0.04, 0.06, 0.98)
	PNPanel:SetBackdropBorderColor(1, 0.72, 0.25, 0.45)
	PNPanel:EnableMouse(true)
	PNPanel:Hide()
	if UISpecialFrames then
		local listed = false
		for index = 1, #UISpecialFrames do
			if UISpecialFrames[index] == "TallyProfessionNotifyPanel" then
				listed = true
				break
			end
		end
		if not listed then
			table.insert(UISpecialFrames, "TallyProfessionNotifyPanel")
		end
	end

	local title = PNPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
	title:SetPoint("TOPLEFT", 16, -12)
	title:SetText("Profession cooldown notifications")
	title:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])

	local note = PNPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	note:SetPoint("TOPLEFT", 18, -34)
	note:SetWidth(460)
	note:SetJustifyH("LEFT")
	note:SetTextColor(0.68, 0.68, 0.68)
	note:SetText("These options only control the ready message for profession cooldowns.")

	local close = CreateFrame("Button", nil, PNPanel, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", PNPanel, "TOPRIGHT", -6, -4)
	close:SetScript("OnClick", function()
		PNPanel:Hide()
	end)

	PNSelection = PNPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	PNSelection:SetPoint("TOPLEFT", 18, -64)
	PNSelection:SetWidth(310)
	PNSelection:SetJustifyH("LEFT")

	local chars = CreateFrame("Button", nil, PNPanel, "UIPanelButtonTemplate")
	chars:SetSize(86, 18)
	chars:SetPoint("TOPRIGHT", PNPanel, "TOPRIGHT", -46, -60)
	chars:SetText("characters")
	chars:SetScript("OnClick", function()
		-- The picker is a page-level window; closing the panel first keeps
		-- the two from covering each other. The ticks are the same wherever
		-- the picker is opened.
		PNPanel:Hide()
		ShowCharPicker("levels", true)
	end)

	PNAddCheckbox(PNPanel, 18, -92, "Notify for this character", "thisChar",
		function() return PNSettings().thisChar end,
		function(value) PNSettings().thisChar = value end,
		"Send a ready message for the character being played. That character must also be ticked in the Total picker.")
	PNAddCheckbox(PNPanel, 18, -118, "Other selected characters", "allSelected",
		function() return PNSettings().allSelected end,
		function(value) PNSettings().allSelected = value end,
		"Also include every other character ticked in the Total picker, not only the one being played.")
	PNAddCheckbox(PNPanel, 18, -144, "Include cooldown items", "items",
		function() return PNSettings().items ~= false end,
		function(value) PNSettings().items = value end,
		"Include bag-item cooldowns such as the Salt Shaker, alongside crafting recipes.")
	PNAddCheckbox(PNPanel, 270, -92, "Send chat message", "chat",
		function() return PNSettings().chat ~= false end,
		function(value) PNSettings().chat = value end,
		"Print the ready list in chat.")
	PNAddCheckbox(PNPanel, 270, -118, "Play chime", "chime",
		function() return PNSettings().chime ~= false end,
		function(value) PNSettings().chime = value end,
		"Play a chime with the ready list.")
	PNAddCheckbox(PNPanel, 270, -144, "Check once after login", "loginNotify",
		function() return PNSettings().loginNotify ~= false end,
		function(value) PNSettings().loginNotify = value end,
		"Check for ready cooldowns once shortly after you enter the world. The wait is the box below.")
	PNAddCheckbox(PNPanel, 270, -170, "Warn before ready", "near",
		function() return PNSettings().near ~= false end,
		function(value) PNSettings().near = value end,
		"Warn 30 minutes and then 10 minutes before a cooldown is ready, not only when it is ready.")

	PNEditBoxes.interval = PNAddEdit(PNPanel, 18, -202, "Repeat every", 42,
		function() return PNSettings().intervalValue end,
		function(value) PNSettings().intervalValue = value end,
		"How often the same ready cooldown is mentioned again while it stays ready.")
	PNDropdowns.unit = PNAddDropdown(PNPanel, 150, -202, "", 82,
		function()
			return {
				{ key = "minutes", label = "minutes" },
				{ key = "hours", label = "hours" },
				{ key = "days", label = "days" },
			}
		end,
		function() return PNSettings().intervalUnit end,
		function(value) PNSettings().intervalUnit = value end)
	-- Sit the unit dropdown against the number box, on the same line, rather
	-- than at a fixed x that only looked aligned by accident.
	PNDropdowns.unit:ClearAllPoints()
	PNDropdowns.unit:SetPoint("LEFT", PNEditBoxes.interval, "RIGHT", 8, 0)
	PNEditBoxes.loginDelay = PNAddEdit(PNPanel, 270, -202, "Wait after login", 42,
		function() return PNSettings().loginDelay end,
		function(value) PNSettings().loginDelay = value end,
		"Tally starts checking this many seconds after you enter the world, once the client has finished loading.")
	local delayUnit = PNPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	delayUnit:SetPoint("LEFT", PNEditBoxes.loginDelay, "RIGHT", 6, 0)
	delayUnit:SetText("seconds")

	PNDropdowns.chime = PNAddDropdown(PNPanel, 18, -234, "Chime sound", 110,
		function() return ns.ProfessionNotify.GetChimeEntries() end,
		function() return PNSettings().chimeKey end,
		function(value) PNSettings().chimeKey = value end)
	PNDropdowns.colour = PNAddDropdown(PNPanel, 270, -234, "Message colour", 90,
		function() return ns.ProfessionNotify.Colours end,
		function() return PNSettings().colourKey end,
		function(value) PNSettings().colourKey = value end)

	local volumeLabel = PNPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	volumeLabel:SetPoint("TOPLEFT", 18, -268)
	volumeLabel:SetText("Chime volume")
	PNVolume = CreateFrame("Slider", nil, PNPanel, "OptionsSliderTemplate")
	PNVolume:SetPoint("LEFT", volumeLabel, "RIGHT", 8, 0)
	PNVolume:SetWidth(150)
	PNVolume:SetHeight(16)
	PNVolume:SetMinMaxValues(0, 1)
	PNVolume:SetValueStep(0.05)
	if PNVolume.SetObeyStepOnDrag then
		PNVolume:SetObeyStepOnDrag(true)
	end
	if PNVolume.Low then PNVolume.Low:SetText("") end
	if PNVolume.High then PNVolume.High:SetText("") end
	if PNVolume.Text then PNVolume.Text:SetText("") end
	PNVolumeText = PNPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	PNVolumeText:SetPoint("LEFT", PNVolume, "RIGHT", 8, 0)
	PNVolumeText:SetText("80%")
	PNVolume:SetScript("OnValueChanged", function(_, value)
		if PNSyncing then
			return
		end
		PNSettings().chimeVolume = value
		if PNVolumeText then
			PNVolumeText:SetText(tostring(math.floor((tonumber(value) or 0) * 100 + 0.5)).."%")
		end
	end)

	PNListTitle = PNPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	PNListTitle:SetPoint("TOPLEFT", 18, -296)
	PNListTitle:SetTextColor(ACCENT[1], ACCENT[2], ACCENT[3])

	local scroll = CreateFrame("ScrollFrame", nil, PNPanel, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 16, -314)
	scroll:SetPoint("BOTTOMRIGHT", -34, 14)
	PNListContent = CreateFrame("Frame", nil, scroll)
	PNListContent:SetWidth(420)
	PNListContent:SetHeight(1)
	scroll:SetScrollChild(PNListContent)
	PNListNone = PNListContent:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
	PNListNone:SetPoint("TOPLEFT", 2, 0)
	PNListNone:SetText("No cooldowns tracked for this character yet.")

	PNPanel:SetScript("OnShow", PNRefresh)
	return PNPanel
end

function ns.BuildProfessionNotifyPanel(parent)
	if PNPanel then
		return PNPanel
	end
	return PNBuild(parent)
end

function ns.OpenProfessionNotifyPanel()
	if not PNPanel then
		return
	end
	if PNPanel:IsShown() then
		PNPanel:Hide()
	else
		PNRefresh()
		PNPanel:Show()
	end
end

function ns.RefreshProfessionNotifyPanel()
	if PNPanel and PNPanel:IsShown() then
		PNRefresh()
	end
end

ns.ProfessionUIBuildNotify = ns.BuildProfessionNotifyPanel
ns.ProfessionUIOpenNotify = ns.OpenProfessionNotifyPanel
ns.ProfessionUIRefreshNotify = ns.RefreshProfessionNotifyPanel
ns.professionsUI.BuildNotify = ns.ProfessionUIBuildNotify
ns.professionsUI.OpenNotify = ns.ProfessionUIOpenNotify
ns.professionsUI.RefreshNotify = ns.ProfessionUIRefreshNotify
