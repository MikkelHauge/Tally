-- Tally - profession cooldowns and their notifications.
--
-- Cooldown data still belongs to char.professions (Core/90_Professions.lua).
-- This file reads it, adds the Forever cooldown items, and owns the
-- notification settings and ticker. It does not build UI.
local addonName, ns = ...

local Now = ns.Now

-- The Forever crafting cooldowns, from ProfessionMaster's models. The names
-- are used when a recipe has not been read yet; a stored recipe name wins.
local FOREVER_RECIPES = {
	[18560] = { name = "Mooncloth", profession = "Tailoring" },
	[17187] = { name = "Transmute: Arcanite", profession = "Alchemy" },
	[1317279] = { name = "Transmute: Legionite", profession = "Alchemy" },
	[11479] = { name = "Transmute: Iron to Gold", profession = "Alchemy" },
	[11480] = { name = "Transmute: Mithril to Truesilver", profession = "Alchemy" },
	[17559] = { name = "Transmute: Air to Fire", profession = "Alchemy" },
	[17560] = { name = "Transmute: Fire to Earth", profession = "Alchemy" },
	[17561] = { name = "Transmute: Earth to Water", profession = "Alchemy" },
	[17562] = { name = "Transmute: Water to Air", profession = "Alchemy" },
	[17563] = { name = "Transmute: Undeath to Water", profession = "Alchemy" },
	[17564] = { name = "Transmute: Water to Undeath", profession = "Alchemy" },
	[17565] = { name = "Transmute: Life to Earth", profession = "Alchemy" },
	[17566] = { name = "Transmute: Earth to Life", profession = "Alchemy" },
}

-- Bag-item cooldowns. Salt Shaker is the one ProfessionMaster lists for
-- Forever; more can be added without touching the scanner.
local ITEM_COOLDOWNS = {
	[15846] = { name = "Salt Shaker", profession = "Leatherworking", spellID = 19566, maxDuration = 255600 },
}

local MESSAGE_COLOURS = {
	{ key = "yellow", label = "Yellow (default)", r = 1.00, g = 0.92, b = 0.20 },
	{ key = "gold", label = "Gold", r = 1.00, g = 0.76, b = 0.25 },
	{ key = "amber", label = "Amber", r = 1.00, g = 0.62, b = 0.30 },
	{ key = "lavender", label = "Lavender", r = 0.80, g = 0.73, b = 1.00 },
	{ key = "violet", label = "Violet", r = 0.63, g = 0.45, b = 1.00 },
	{ key = "indigo", label = "Indigo", r = 0.45, g = 0.52, b = 1.00 },
	{ key = "purple", label = "Purple", r = 0.76, g = 0.32, b = 1.00 },
	{ key = "magenta", label = "Magenta", r = 0.95, g = 0.38, b = 0.95 },
	{ key = "sky", label = "Sky", r = 0.45, g = 0.78, b = 1.00 },
	{ key = "cyan", label = "Cyan", r = 0.30, g = 0.88, b = 1.00 },
	{ key = "turquoise", label = "Turquoise", r = 0.30, g = 1.00, b = 0.78 },
}

local CHIME_POOL = {
	{ key = "PING", label = "Ping" },
	{ key = "RAID_WARNING", label = "Raid Warning" },
	{ key = "ALARM_CLOCK_WARNING_1", label = "Alarm One" },
	{ key = "ALARM_CLOCK_WARNING_2", label = "Alarm Two" },
	{ key = "ALARM_CLOCK_WARNING_3", label = "Alarm Three" },
	{ key = "IG_MAINMENU_OPEN", label = "Menu Click" },
	{ key = "IG_MAINMENU_CLOSE", label = "Menu Close" },
	{ key = "IG_CHARACTER_INFO_OPEN", label = "Character Sheet" },
	{ key = "IG_SPELLBOOK_OPEN", label = "Spellbook" },
	{ key = "IG_QUEST_LIST_OPEN", label = "Quest Log" },
	{ key = "IG_BACKPACK_OPEN", label = "Bag Open" },
	{ key = "MONEY_FRAME_OPEN", label = "Coin Purse" },
	{ key = "LEVEL_UP", label = "Level Up" },
}

local function NotifySettings()
	local settings = ns.db and ns.db.settings and ns.db.settings.professionNotify
	if type(settings) ~= "table" then
		settings = {}
		if ns.db and ns.db.settings then
			ns.db.settings.professionNotify = settings
		end
	end
	return settings
end

local function IntervalSeconds()
	local settings = NotifySettings()
	local units = { minutes = 60, hours = 3600, days = 86400 }
	local value = tonumber(settings.intervalValue) or 0
	if value < 0 then
		value = 0
	end
	return math.floor(value * (units[settings.intervalUnit] or 60))
end

local function Colour()
	local settings = NotifySettings()
	for index = 1, #MESSAGE_COLOURS do
		if MESSAGE_COLOURS[index].key == settings.colourKey then
			return MESSAGE_COLOURS[index]
		end
	end
	return MESSAGE_COLOURS[1]
end

local function ColourCode(entry)
	if not entry then
		return nil
	end
	return string.format("|cff%02x%02x%02x",
		math.floor((entry.r or 1) * 255 + 0.5),
		math.floor((entry.g or 1) * 255 + 0.5),
		math.floor((entry.b or 1) * 255 + 0.5))
end

local function ChimeEntries()
	local entries = { { key = "none", label = "No sound" } }
	for index = 1, #CHIME_POOL do
		local candidate = CHIME_POOL[index]
		if candidate.key == "PING" or (SOUNDKIT and SOUNDKIT[candidate.key] ~= nil) then
			entries[#entries + 1] = candidate
		end
	end
	return entries
end

local function ResolveChime(key)
	if not key or key == "none" then
		return nil
	end
	if key == "PING" then
		return (SOUNDKIT and (SOUNDKIT.MAP_PING or SOUNDKIT.RAID_WARNING)) or 3175
	end
	return SOUNDKIT and SOUNDKIT[key] or nil
end

local originalDialogVolume
local restoringVolume = false

local function PlayChime()
	local settings = NotifySettings()
	if not settings.chime then
		return
	end
	local kit = ResolveChime(settings.chimeKey)
	if not kit then
		return
	end
	local volume = tonumber(settings.chimeVolume) or 0.8
	if volume < 0 then volume = 0 elseif volume > 1 then volume = 1 end
	if type(GetCVar) == "function" and type(SetCVar) == "function" and C_Timer and C_Timer.After then
		local current = tonumber(GetCVar("Sound_DialogVolume") or "")
		if current then
			local scale = current > 1.5 and 100 or 1
			if not restoringVolume then
				originalDialogVolume = current
				restoringVolume = true
			end
			pcall(SetCVar, "Sound_DialogVolume", tostring(volume * scale))
			C_Timer.After(0.6, function()
				if restoringVolume and originalDialogVolume then
					pcall(SetCVar, "Sound_DialogVolume", tostring(originalDialogVolume))
					restoringVolume = false
					originalDialogVolume = nil
				end
			end)
		end
	end
	local played = pcall(PlaySound, kit, "Dialog")
	if not played then
		pcall(PlaySound, kit)
	end
end

local function SelectedCharacters()
	local selected = {}
	local known = ns.KnownCharacters()
	for index = 1, #known do
		local entry = known[index]
		if ns.TotalIncludes(entry.key) then
			selected[#selected + 1] = {
				key = entry.key,
				char = entry.char,
				name = ns.DisplayName(entry.char),
				live = entry.live,
			}
		end
	end
	return selected
end

-- Which characters a notification may cover. "This character" means the one
-- being played, and only while it is ticked in the Total picker. "All
-- selected characters" covers every ticked character. With both off there is
-- nothing to announce, so the engine stays quiet.
local function NotifyTargets()
	local settings = NotifySettings()
	local selected = SelectedCharacters()
	if settings.allSelected then
		return selected
	end
	local out = {}
	if settings.thisChar then
		for index = 1, #selected do
			if selected[index].key == ns.charKey then
				out[1] = selected[index]
				break
			end
		end
	end
	return out
end

local function StoreFor(char)
	local store = char and char.professions
	if type(store) ~= "table" then
		return nil
	end
	if type(store.itemCooldowns) ~= "table" then
		store.itemCooldowns = {}
	end
	if type(store.notifyOff) ~= "table" then
		store.notifyOff = {}
	end
	if type(store.notifyState) ~= "table" then
		store.notifyState = {}
	end
	return store
end

local function IsEnabled(char, key)
	local store = StoreFor(char)
	return not (store and store.notifyOff[key])
end

local function SetEnabled(char, key, enabled)
	local store = StoreFor(char)
	if not store then
		return
	end
	if enabled then
		store.notifyOff[key] = nil
	else
		store.notifyOff[key] = true
	end
end

local function CooldownReadyAt(value)
	if type(value) == "table" then
		return ns.professions.CooldownParts(value)
	end
	return value, nil
end

local function BuildCooldownList(char, opts)
	opts = opts or {}
	local out = {}
	local store = char and char.professions
	local skills = (type(store) == "table" and store.skills) or {}
	local recipes = (type(store) == "table" and store.recipes) or {}
	local now = Now()
	local includeKnown = opts.includeKnown ~= false
	local includeItems = opts.includeItems ~= false
	local current = {}

	for index = 1, #skills do
		local skill = skills[index]
		if not ns.professions.IsIgnored(skill.name) then
			current[skill.name] = true
			local book = recipes[skill.name]
			local cooldowns = type(book) == "table" and book.cooldowns or nil
			local seen = {}
			if type(cooldowns) == "table" then
				for name, stored in pairs(cooldowns) do
					local readyAt, span = CooldownReadyAt(stored)
					if readyAt then
						local itemID = type(stored) == "table" and stored.itemID or nil
						if not itemID and type(book) == "table" and type(book.items) == "table" then
							itemID = book.items[name]
						end
						local quality = type(stored) == "table" and stored.quality or nil
						if not quality and itemID then
							quality = select(3, ns.ItemInfo(itemID))
						end
						local startedAt = type(stored) == "table" and stored.startedAt or nil
						if not startedAt and readyAt and readyAt > 0 and span then
							startedAt = readyAt - span
						end
						local neverSeen = not startedAt and (not readyAt or readyAt <= 0)
						out[#out + 1] = {
							key = "recipe:"..skill.name..":"..name,
							kind = "recipe",
							name = name,
							profession = skill.name,
							readyAt = readyAt,
							span = span,
							startedAt = startedAt,
							itemID = itemID,
							quality = quality,
							known = neverSeen or false,
							ready = readyAt <= now,
						}
						seen[name] = true
					end
				end
			end
			if includeKnown and type(book) == "table" and type(book.ids) == "table" then
				local byID = {}
				for name, recipeID in pairs(book.ids) do
					local id = tonumber(recipeID)
					if id then
						byID[id] = name
					end
				end
				for spellID, info in pairs(FOREVER_RECIPES) do
					if info.profession == skill.name and not seen[info.name] and byID[spellID] then
						local name = byID[spellID] or info.name
						local itemID = type(book.items) == "table" and book.items[name] or nil
						out[#out + 1] = {
							key = "recipe:"..skill.name..":"..name,
							kind = "recipe",
							name = name,
							profession = skill.name,
							readyAt = 0,
							span = nil,
							startedAt = nil,
							itemID = itemID,
							quality = itemID and select(3, ns.ItemInfo(itemID)) or nil,
							known = true,
							ready = false,
						}
					end
				end
			end
		end
	end

	if includeItems and type(store) == "table" and type(store.itemCooldowns) == "table" then
		for itemID, entry in pairs(store.itemCooldowns) do
			if type(entry) == "table" and (not entry.profession or current[entry.profession]) then
				out[#out + 1] = {
					key = "item:"..itemID,
					kind = "item",
					name = entry.name or ("Item "..itemID),
					profession = entry.profession,
					readyAt = entry.readyAt or 0,
					span = entry.span,
					startedAt = entry.startedAt,
					cycle = entry.cycle,
					itemID = itemID,
					quality = entry.quality,
					known = false,
					ready = (entry.readyAt or 0) <= now,
				}
			end
		end
	end

	if opts.key then
		for index = 1, #out do
			out[index].ownerKey = opts.key
			out[index].ownerName = opts.name
			out[index].classFile = opts.classFile
			out[index].live = opts.live and true or false
		end
	end
	return out
end

local function ScanItemCooldowns()
	local char = ns.GetChar()
	local store = char and StoreFor(char)
	if not store then
		return
	end
	-- Bags are scanned slot by slot, as ProfessionMaster does, so the
	-- client's own enable flag and the item's maximum duration can both be
	-- checked. GetItemCooldown(itemID) is only a fallback for a client
	-- without the container API.
	local getSlots = type(C_Container) == "table" and C_Container.GetContainerNumSlots or GetContainerNumSlots
	local getItem = type(C_Container) == "table" and C_Container.GetContainerItemID or GetContainerItemID
	local getCooldown = type(C_Container) == "table" and C_Container.GetContainerItemCooldown or GetContainerItemCooldown
	if type(getSlots) ~= "function" or type(getItem) ~= "function" then
		return
	end
	local now = Now()
	local uptime = GetTime and GetTime() or 0
	local found, cooling = {}, {}
	for bag = 0, (NUM_BAG_SLOTS or 4) do
		local okSlots, slots = pcall(getSlots, bag)
		if okSlots and type(slots) == "number" then
			for slot = 1, slots do
				local okItem, itemID = pcall(getItem, bag, slot)
				local info = okItem and itemID and ITEM_COOLDOWNS[itemID] or nil
				if info then
					found[itemID] = true
					local entry = store.itemCooldowns[itemID]
					if not entry then
						entry = {
							name = info.name,
							profession = info.profession,
							quality = select(3, ns.ItemInfo(itemID)),
						}
						store.itemCooldowns[itemID] = entry
					end
					local startTime, duration, enable
					if type(getCooldown) == "function" then
						local ok, start, span, ready = pcall(getCooldown, bag, slot)
						if ok then
							startTime, duration, enable = start, span, ready
						end
					elseif type(GetItemCooldown) == "function" then
						local ok, start, span = pcall(GetItemCooldown, itemID)
						if ok then
							startTime, duration = start, span
						end
					end
					-- enable ~= 1 means the client has not filled the slot's
					-- cooldown in yet; the stored reading is safer than a 0.
					if enable ~= nil and enable ~= 1 then
						-- wait for the next scan
					elseif type(startTime) == "number" and type(duration) == "number"
						and startTime > 0 and duration > 0 then
						if info.maxDuration and duration > info.maxDuration * 1.1 then
							-- A duration past the item's real maximum is not a
							-- reading; leave the stored one alone.
						else
							local remaining = duration - (uptime - startTime)
							if remaining > duration then remaining = duration elseif remaining < 0 then remaining = 0 end
							entry.readyAt = now + remaining
							entry.span = duration
							entry.startedAt = now + remaining - duration
							-- The client's own start time identifies this use
							-- of the item. It stays fixed while the cooldown
							-- runs, unlike readyAt, which moves by a few
							-- milliseconds each scan.
							entry.cycle = startTime
							cooling[itemID] = true
						end
					elseif not cooling[itemID] then
						entry.readyAt = 0
					end
				end
			end
		end
	end
	for itemID in pairs(store.itemCooldowns) do
		if not found[itemID] then
			store.itemCooldowns[itemID] = nil
		end
	end
end

local function Marker(cd)
	if cd.cycle then
		return cd.cycle
	end
	return cd.startedAt or cd.readyAt or 0
end

local notifyPending = {}
local loginAt
local initialScanDone = false
local ScanProfessionCooldowns

local function FullKey(cd)
	return tostring(cd.ownerKey or "?").."|"..tostring(cd.key or "?")
end

local function Queue(cd, now)
	local settings = NotifySettings()
	if not cd or cd.known or not cd.ownerKey then
		return
	end
	if cd.readyAt and cd.readyAt > now then
		return
	end
	local char = (ns.db and ns.db.chars and ns.db.chars[cd.ownerKey]) or nil
	if not char or not IsEnabled(char, cd.key) then
		return
	end
	local marker = Marker(cd)
	if marker == 0 then
		return
	end
	local store = StoreFor(char)
	local state = store and store.notifyState[cd.key]
	local interval = IntervalSeconds()
	if state and state.marker == marker then
		if interval <= 0 or (now - (state.at or 0)) < interval then
			return
		end
	end
	notifyPending[FullKey(cd)] = cd
end

local function MarkNotified(cd, now)
	local char = ns.db and ns.db.chars and ns.db.chars[cd.ownerKey]
	local store = char and StoreFor(char)
	if store then
		store.notifyState[cd.key] = { marker = Marker(cd), at = now }
	end
end

local function SortPending(list)
	table.sort(list, function(a, b)
		if a.live ~= b.live then
			return a.live
		end
		if a.ownerName ~= b.ownerName then
			return tostring(a.ownerName) < tostring(b.ownerName)
		end
		if (a.readyAt or 0) ~= (b.readyAt or 0) then
			return (a.readyAt or 0) < (b.readyAt or 0)
		end
		return tostring(a.name) < tostring(b.name)
	end)
end

local function ItemText(entry, base)
	local colour = ns.QualityCode and entry.quality and ns.QualityCode(entry.quality) or base
	return (colour or "")..tostring(entry.name or "?").."|r"
end

local function CharacterText(entry, base)
	local colour = ns.ClassColorCode and entry.classFile and ns.ClassColorCode(entry.classFile) or base
	return (colour or "")..tostring(entry.ownerName or "?").."|r"
end

local function BuildNotification(list)
	local colour = Colour()
	local base = ColourCode(colour) or "|cffffff00"
	local currentSelected = ns.charKey and ns.TotalIncludes(ns.charKey)
	local messages = {}
	if #list == 1 then
		local entry = list[1]
		messages[1] = base.."Cooldown ready: |r"..ItemText(entry, base)..base.." - "
			..tostring(entry.profession or "?").."|r"..base.." - on "
			..CharacterText(entry, base)
	else
		messages[1] = base.."You have the following cooldowns ready:|r"
		for index = 1, #list do
			local entry = list[index]
			messages[#messages + 1] = ItemText(entry, base)..base.." - "
				..tostring(entry.profession or "?").."|r"..base.." - on "
				..CharacterText(entry, base)
		end
	end
	if not currentSelected then
		messages[#messages + 1] = base.."Current character is not selected - its cooldowns are not notified.|r"
	end
	return messages, colour
end

-- A cooldown that is nearly ready is useful before it reaches zero. The two
-- thresholds are fixed at 30 and 10 minutes; the option only turns the
-- warnings on or off. Each occurrence uses the ready timestamp's five-minute
-- bucket as its identity, so a window scan that nudges the timestamp by a few
-- seconds does not repeat a warning.
local function CheckNearCooldowns(targets, now)
	local settings = NotifySettings()
	if settings.near == false then
		return
	end
	local colour = Colour()
	local base = ColourCode(colour) or "|cffffff00"
	local messages = {}
	for targetIndex = 1, #targets do
		local target = targets[targetIndex]
		local list = BuildCooldownList(target.char, {
			includeKnown = false, includeItems = settings.items ~= false,
			key = target.key, name = target.name, classFile = target.char.classFile, live = target.live,
		})
		for index = 1, #list do
			local cd = list[index]
			if not cd.ready and cd.readyAt > now then
				local store = StoreFor(target.char)
				if store then
					local state = store.notifyState[cd.key]
					if not state then
						state = {}
						store.notifyState[cd.key] = state
					end
					local marker = math.floor((cd.readyAt or 0) / 300)
					if state.nearMarker ~= marker then
						state.nearMarker = marker
						state.near30 = nil
						state.near10 = nil
					end
					local remaining = cd.readyAt - now
					local warn = false
					if remaining <= 600 and not state.near10 then
						state.near10 = true
						state.near30 = true
						warn = true
					elseif remaining <= 1800 and not state.near30 then
						state.near30 = true
						warn = true
					end
					if warn then
						local minutes = math.max(1, math.ceil(remaining / 60))
						local text = base.."Cooldown on "..ItemText(cd, base)
							..base.." is ready in "..minutes.." minutes"
						if cd.ownerKey ~= ns.charKey then
							text = text..", on "..CharacterText(cd, base)
						end
						messages[#messages + 1] = text..".|r"
					end
				end
			end
		end
	end
	if #messages == 0 then
		return
	end
	-- Both channels off still lets the flags advance, so switching them on
	-- later does not immediately replay warnings that passed unseen.
	if settings.chat ~= false and DEFAULT_CHAT_FRAME then
		for index = 1, #messages do
			DEFAULT_CHAT_FRAME:AddMessage(messages[index], colour.r, colour.g, colour.b)
		end
	end
	if settings.chime ~= false then
		PlayChime()
	end
end

local function Flush(now)
	local list = {}
	for _, cd in pairs(notifyPending) do
		if not (cd.readyAt and cd.readyAt > now) then
			list[#list + 1] = cd
		end
	end
	if #list == 0 then
		notifyPending = {}
		return
	end
	local settings = NotifySettings()
	local interval = IntervalSeconds()
	local last = tonumber(settings.lastSentAt) or 0
	-- The interval is a hold-back between messages, not a poll. Anything that
	-- became ready while it ran waits and joins the next message.
	if interval > 0 and last > 0 and (now - last) < interval then
		return
	end
	SortPending(list)
	local messages, colour = BuildNotification(list)
	if settings.chat and DEFAULT_CHAT_FRAME then
		for index = 1, #messages do
			DEFAULT_CHAT_FRAME:AddMessage(messages[index], colour.r, colour.g, colour.b)
		end
	end
	if settings.chime then
		PlayChime()
	end
	for index = 1, #list do
		MarkNotified(list[index], now)
	end
	notifyPending = {}
	settings.lastSentAt = now
end

local function CheckNotifications(now)
	if not (ns.db and ns.db.settings) then
		return
	end
	local char = ns.GetChar()
	if not char then
		return
	end
	local settings = NotifySettings()
	if not loginAt then
		loginAt = now
		initialScanDone = false
	end
	ScanItemCooldowns()
	ScanProfessionCooldowns()
	local selected = NotifyTargets()
	if not initialScanDone then
		if not settings.loginNotify then
			-- Seed the existing ready cooldowns silently. Turning login
			-- notices off must not just postpone every one of them by one
			-- ticker.
			for index = 1, #selected do
				local entry = selected[index]
				local list = BuildCooldownList(entry.char, {
					includeKnown = false, includeItems = settings.items ~= false,
					key = entry.key, name = entry.name, classFile = entry.char.classFile, live = entry.live,
				})
				for cdIndex = 1, #list do
					local cd = list[cdIndex]
					if cd.ready then
						MarkNotified(cd, now)
					end
				end
			end
			initialScanDone = true
		elseif (now - loginAt) < (tonumber(settings.loginDelay) or 0) then
			return
		else
			initialScanDone = true
		end
	end

	for index = 1, #selected do
		local entry = selected[index]
		local list = BuildCooldownList(entry.char, {
			includeKnown = false, includeItems = settings.items ~= false,
			key = entry.key, name = entry.name, classFile = entry.char.classFile, live = entry.live,
		})
		for cdIndex = 1, #list do
			local cd = list[cdIndex]
			if cd.ready then
				Queue(cd, now)
			end
		end
	end
	CheckNearCooldowns(selected, now)
	Flush(now)
end

local function StartTicker()
	if not (C_Timer and C_Timer.NewTicker) then
		return
	end
	C_Timer.NewTicker(10, function()
		local ok, err = pcall(CheckNotifications, Now())
		if not ok then
			ns.Trace("profession notifications: "..tostring(err))
		end
	end)
end

-- Item cooldowns change when the item is used, not on the ticker's schedule.
-- The registrar owns the frames; the ticker stays as a fallback and for
-- notifications.
local function ScanItemsSafely()
	local ok, err = pcall(ScanItemCooldowns)
	if not ok then
		ns.Trace("item cooldowns: "..tostring(err))
	end
end

-- The Forever cooldown recipes can be read by spell id without a profession
-- window, as Mastercraft does. That is also where the real total length comes
-- from: C_Spell.GetSpellCooldown reports the duration, while the trade-skill
-- call reports only the seconds left.
local function SpellCooldown(id)
	if type(C_Spell) == "table" and type(C_Spell.GetSpellCooldown) == "function" then
		local ok, info = pcall(C_Spell.GetSpellCooldown, id)
		if ok and type(info) == "table" then
			return info.startTime, info.duration
		end
	end
	if type(GetSpellCooldown) == "function" then
		local ok, start, duration = pcall(GetSpellCooldown, id)
		if ok then
			return start, duration
		end
	end
end

local function RecipeCooldownInfo(spellID)
	if type(C_TradeSkillUI) == "table" and type(C_TradeSkillUI.GetRecipeCooldown) == "function" then
		local ok, remaining, isDay, charges, maxCharges = pcall(C_TradeSkillUI.GetRecipeCooldown, spellID)
		if ok then
			return tonumber(remaining) or 0, isDay, tonumber(maxCharges) or 0
		end
	end
	return nil
end

local function ScanOneRecipe(profession, name, spellID, now, uptime)
	local remaining, isDay, maxCharges = RecipeCooldownInfo(spellID)
	local start, duration = SpellCooldown(spellID)
	local active = type(start) == "number" and type(duration) == "number" and start > 0 and duration > 2
	local isCooldown = active
		or (remaining and remaining > 0)
		or (isDay == true)
		or (maxCharges and maxCharges > 0)
	if not isCooldown then
		return
	end
	local readyAt, span
	if active then
		local left = duration - (uptime - start)
		span = duration
		readyAt = left > 0 and (now + left) or 0
	else
		-- A ready cooldown recipe still belongs in the list; it just has no
		-- remaining time. C_Spell often reports no duration once ready.
		span = type(duration) == "number" and duration > 2 and duration or 0
		readyAt = 0
	end
	ns.SetProfessionCooldown(profession, name, spellID, readyAt, span)
end

ScanProfessionCooldowns = function()
	local char = ns.GetChar()
	local store = char and char.professions
	if type(store) ~= "table" then
		return
	end
	local now = Now()
	local uptime = GetTime and GetTime() or 0
	local seen = {}
	for profession, book in pairs(store.recipes or {}) do
		if type(book) == "table" and type(book.ids) == "table" then
			local learned = {}
			for index = 1, type(book.list) == "table" and #book.list or 0 do
				learned[book.list[index]] = true
			end
			for name, recipeID in pairs(book.ids) do
				local id = tonumber(recipeID)
				if id and (next(learned) == nil or learned[name]) then
					seen[id] = true
					ScanOneRecipe(profession, name, id, now, uptime)
				end
			end
		end
	end
	-- A recipe the client did not list in its id map can still be known; the
	-- Forever list fills that gap without inventing anything for characters
	-- who do not have it.
	for spellID, info in pairs(FOREVER_RECIPES) do
		if not seen[spellID] and type(IsPlayerSpell) == "function" then
			local ok, known = pcall(IsPlayerSpell, spellID)
			if ok and known then
				ScanOneRecipe(info.profession, info.name, spellID, now, uptime)
			end
		end
	end
end

local function ScanCooldownsSafely()
	local okItems, itemError = pcall(ScanItemCooldowns)
	if not okItems then
		ns.Trace("item cooldowns: "..tostring(itemError))
	end
	local okSpells, spellError = pcall(ScanProfessionCooldowns)
	if not okSpells then
		ns.Trace("profession cooldowns: "..tostring(spellError))
	end
end
ns.On("PLAYER_LOGIN", ScanCooldownsSafely, "Professions")
ns.On("BAG_UPDATE_COOLDOWN", ScanItemsSafely, "Professions")
ns.On("SPELL_UPDATE_COOLDOWN", ScanCooldownsSafely, "Professions")
ns.On("TRADE_SKILL_SHOW", ScanCooldownsSafely, "Professions")
ns.On("TRADE_SKILL_LIST_UPDATE", ScanCooldownsSafely, "Professions")

ns.ScanItemCooldowns = ScanItemCooldowns
ns.ProfessionCooldowns = BuildCooldownList
ns.ProfessionNotify = {}
ns.ProfessionNotify.Settings = NotifySettings
ns.ProfessionNotify.NotifySettings = NotifySettings
ns.ProfessionNotify.Colours = MESSAGE_COLOURS
ns.ProfessionNotify.Chimes = CHIME_POOL
ns.ProfessionNotify.GetChimeEntries = ChimeEntries
ns.ProfessionNotify.ResolveChime = ResolveChime
ns.ProfessionNotify.PlayChime = PlayChime
ns.ProfessionNotify.IntervalSeconds = IntervalSeconds
ns.ProfessionNotify.IsEnabled = IsEnabled
ns.ProfessionNotify.SetEnabled = SetEnabled
ns.ProfessionNotify.SelectedCharacters = SelectedCharacters
ns.ProfessionNotify.Tick = CheckNotifications
ns.ProfessionNotify.Scan = ScanItemCooldowns
ns.professions.Cooldowns = ns.ProfessionCooldowns
ns.professions.Notify = ns.ProfessionNotify

StartTicker()
