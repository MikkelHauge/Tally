-- Tally - fishing: what was pulled out of the water, where and at what level.
--
-- The client has no "you caught a fish" event. A catch is inferred from a
-- Fishing cast and loot arriving in the seconds after it: the line goes in,
-- the channel stops, and the loot follows. A cast with nothing on the hook
-- still counts as a cast; only loot inside the window counts as a catch.
--
-- One character subtree is owned here: char.fishing.
local addonName, ns = ...

local Now = ns.Now

-- The cast's spell id differs between clients and expansions: 7620 is the
-- classic skill, and retail has used 131474 and 158743 for the cast itself.
-- The name check below is the real fallback, so a client this list misses is
-- still recognised when GetSpellInfo/GetC_SpellInfo can name it.
local FISHING_SPELL_IDS = {
	[7620] = true,
	[131474] = true,
	[158743] = true,
	[110410] = true,
	[51294] = true,
	[7731] = true,
	[18248] = true,
}
local fishingSpellName

-- How long a cast may sit in the water before the client is treated as done.
-- The fishing channel itself is 30 seconds, and a slow bite needs a margin.
local CAST_WINDOW = 60
-- After the channel stops the catch loot is a moment behind; this is the
-- window in which loot is attributed to the cast. It is deliberately more
-- generous than a click: auto-loot and a manual right-click both take time.
local LOOT_GRACE = 15

local casting = false
local channelSeen = false
local castStartedAt = 0
local lastCastAt = 0
local catchUntil = 0
local unknownCastLogged = false
local lootRecorded = {}
local lastLootRecordAt = 0
-- A vendor is open. Buying something pushes the item into the bags with the
-- same chat wording a loot line can use ("You receive item"), so loot chat is
-- ignored while a merchant window is up. A bobber's loot cannot arrive then:
-- the two windows never share the screen.
local merchantOpen = false

local function Clear()
	casting = false
	channelSeen = false
	castStartedAt = 0
	lastCastAt = 0
	catchUntil = 0
	lootRecorded = {}
	lastLootRecordAt = 0
end

local function Ensure(char)
	if not char then
		return nil
	end
	local fishing = char.fishing
	if type(fishing) ~= "table" then
		fishing = {}
		char.fishing = fishing
	end
	if type(fishing.items) ~= "table" then
		fishing.items = {}
	end
	if type(fishing.zones) ~= "table" then
		fishing.zones = {}
	end
	if type(fishing.levels) ~= "table" then
		fishing.levels = {}
	end
	fishing.casts = tonumber(fishing.casts) or 0
	fishing.catches = tonumber(fishing.catches) or 0
	return fishing
end

-- A string from the client can be a secret value on newer clients, where any
-- pattern or comparison throws. Such a value is treated as unknown.
local function SafeString(value)
	if type(value) ~= "string" then
		return nil
	end
	if type(issecretvalue) == "function" and issecretvalue(value) then
		return nil
	end
	return value
end

-- The name of a spell, through whichever API this client has. Retail 11+
-- exposes C_Spell.GetSpellInfo; older clients expose the global function.
local function SpellName(spellID)
	local id = tonumber(spellID)
	if not id then
		return nil
	end
	if type(C_Spell) == "table" and type(C_Spell.GetSpellInfo) == "function" then
		local ok, info = pcall(C_Spell.GetSpellInfo, id)
		if ok and type(info) == "table" then
			local name = SafeString(info.name)
			if name then
				return name
			end
		elseif ok then
			local name = SafeString(info)
			if name then
				return name
			end
		end
	end
	if type(GetSpellInfo) == "function" then
		local ok, name = pcall(GetSpellInfo, id)
		if ok then
			return SafeString(name)
		end
	end
	return nil
end

-- The fishing spell's localized name. The cast event's spell id is not the
-- same on every client, so the name is the portable answer.
local function RefreshFishingName()
	fishingSpellName = SpellName(7620)
		or SpellName(131474)
		or SpellName(158743)
		or "Fishing"
end

local function IsFishingName(name)
	name = SafeString(name)
	if not name or name == "" then
		return false
	end
	if name == "Fishing" or name == fishingSpellName then
		return true
	end
	-- Some clients append a rank or a qualifier to the channel name.
	if fishingSpellName and #fishingSpellName >= 4 and string.find(name, fishingSpellName, 1, true) then
		return true
	end
	return false
end

local function IsFishingSpell(spellID)
	local ok, id = pcall(tonumber, spellID)
	if not ok or not id then
		return false
	end
	if FISHING_SPELL_IDS[id] then
		return true
	end
	return IsFishingName(SpellName(id))
end

-- Event payloads differ by client: modern clients send
-- (unit, castGUID, spellID, castBarID), old ones send
-- (unit, spellName, rank, castGUID, spellID). The rest of the arguments are
-- scanned for a fishing spell id so both shapes work.
local function EventSpellID(...)
	local args = { ... }
	-- The old signature puts the spell name first; use it even when the id
	-- is missing or unknown.
	if IsFishingName(args[1]) then
		return 0
	end
	if IsFishingSpell(args[2]) then
		return tonumber(args[2])
	end
	if IsFishingSpell(args[4]) then
		return tonumber(args[4])
	end
	for index = 1, #args do
		if IsFishingSpell(args[index]) then
			return tonumber(args[index])
		end
	end
	return nil
end

-- Last resort: ask the client what the player is casting now. This catches a
-- client that sends a cast event without a usable spell id.
local function CurrentFishingSpell()
	local function Ask(fn)
		if type(fn) ~= "function" then
			return nil
		end
		local ok, info, _, _, _, _, _, _, spellID = pcall(fn, "player")
		if not ok or info == nil then
			return nil
		end
		local name = info
		if type(info) == "table" then
			name = info.name
			spellID = info.spellID or spellID
		end
		if not IsFishingName(name) then
			return nil
		end
		local okID, id = pcall(tonumber, spellID)
		return (okID and id) or 0
	end
	local spellID = Ask(UnitChannelInfo)
	if spellID then
		return spellID
	end
	return Ask(UnitCastingInfo)
end

RefreshFishingName()

local function CurrentZone()
	if type(GetRealZoneText) == "function" then
		local ok, zone = pcall(GetRealZoneText)
		zone = ok and SafeString(zone) or nil
		if zone and zone ~= "" then
			return zone
		end
	end
	local zone = ns.CurrentZone and SafeString(ns.CurrentZone()) or nil
	if zone and zone ~= "" then
		return zone
	end
	return "Unknown"
end

local function CurrentLevel()
	if type(UnitLevel) == "function" then
		local ok, value = pcall(UnitLevel, "player")
		local level = ok and tonumber(value) or nil
		if level and level > 0 then
			return level
		end
	end
	local char = ns.GetChar()
	return tonumber(char and char.level) or 0
end

-- Adds one catch. `count` is the stack the loot line carried, so three fish
-- from one line are three catches. The pile's vendor value is what the "most
-- valuable catch" figure compares.
local function RecordCatch(itemID, name, quality, count, at)
	local char = ns.GetChar()
	if not char or not itemID or not ns.Tracks("loot") then
		return false
	end
	local fishing = Ensure(char)
	if not fishing then
		return false
	end
	local zone = CurrentZone()
	local level = CurrentLevel()
	local itemName, _, itemQuality, sellPrice = ns.ItemInfo(itemID)
	name = SafeString(itemName) or SafeString(name) or ("item "..tostring(itemID))
	quality = itemQuality or tonumber(quality) or 1
	at = at or Now()
	count = math.max(1, tonumber(count) or 1)
	sellPrice = tonumber(sellPrice) or 0

	local item = fishing.items[itemID]
	if type(item) ~= "table" then
		item = {
			name = name, quality = quality, count = 0,
			zones = {}, levels = {}, firstAt = at, unitValue = sellPrice,
		}
		fishing.items[itemID] = item
	end
	if type(item.zones) ~= "table" then
		item.zones = {}
	end
	if type(item.levels) ~= "table" then
		item.levels = {}
	end
	item.name = name
	item.quality = quality
	if sellPrice > 0 then
		item.unitValue = sellPrice
	end
	item.count = (tonumber(item.count) or 0) + count
	item.lastAt = at
	item.zones[zone] = (tonumber(item.zones[zone]) or 0) + count
	item.levels[level] = (tonumber(item.levels[level]) or 0) + count
	fishing.zones[zone] = (tonumber(fishing.zones[zone]) or 0) + count
	fishing.levels[level] = (tonumber(fishing.levels[level]) or 0) + count
	fishing.catches = (tonumber(fishing.catches) or 0) + count

	local pile = (tonumber(item.unitValue) or 0) * count
	if pile > (tonumber(fishing.best and fishing.best.value) or 0) then
		fishing.best = {
			id = itemID, name = name, quality = quality, count = count,
			value = pile, at = at, zone = zone,
		}
	end
	ns.Trace("fishing: caught "..name.." x"..count.." in "..zone.." at level "..level)
	return true
end

-- The same fish can be seen by the loot window (LOOT_READY/LOOT_OPENED), by
-- the chat loot line, and by a fast-loot addon. Each path reports a total
-- quantity for this cast, so only the part not already counted is added.
local function RecordOnce(itemID, name, quality, quantity, at)
	if not itemID then
		return
	end
	at = at or Now()
	quantity = math.max(1, math.floor(tonumber(quantity) or 1))
	-- A missed cast start must not make the next cast's identical fish look
	-- like the same bobber. Loot from one bobber arrives together; a gap this
	-- long is a new cast.
	if lastLootRecordAt > 0 and (at - lastLootRecordAt) > 10 then
		lootRecorded = {}
	end
	local prior = lootRecorded[itemID]
	local counted = prior and prior.quantity or 0
	if quantity <= counted then
		return
	end
	lastLootRecordAt = at
	lootRecorded[itemID] = { quantity = quantity, at = at }
	RecordCatch(itemID, name, quality, quantity - counted, at)
end

local function OnCastStart(event, unit, ...)
	if unit and unit ~= "player" then
		return
	end
	if not ns.Tracks("loot") then
		return
	end
	local spellID = EventSpellID(...)
	if not spellID then
		spellID = CurrentFishingSpell()
	end
	if not spellID then
		if not unknownCastLogged and event == "UNIT_SPELLCAST_CHANNEL_START" and (not unit or unit == "player") then
			unknownCastLogged = true
			local args = { ... }
			local a1 = SafeString(args[1]) or type(args[1])
			local a2 = SafeString(args[2]) or type(args[2])
			ns.Trace("fishing: unrecognised channel start ("..tostring(a1)..", "..tostring(a2)..")")
		end
		return
	end
	if ns.gathering and ns.gathering.Clear then
		ns.gathering.Clear()
	end
	if event == "UNIT_SPELLCAST_CHANNEL_START" then
		channelSeen = true
	end
	local now = Now()
	-- Some clients raise both START and CHANNEL_START for one cast; the
	-- second arrival a moment later is the same lure, not another one, even
	-- when a stop arrived in between.
	if castStartedAt > 0 and (now - castStartedAt) < 2 then
		return
	end
	casting = true
	castStartedAt = now
	lastCastAt = now
	catchUntil = now + CAST_WINDOW
	lootRecorded = {}
	local fishing = Ensure(ns.GetChar())
	if fishing then
		fishing.casts = (tonumber(fishing.casts) or 0) + 1
	end
	ns.Trace("fishing: cast start id="..tostring(spellID).." name="..tostring(SpellName(spellID)).." in "..CurrentZone())
end

local function OnCastStop(event, unit, ...)
	if unit and unit ~= "player" then
		return
	end
	local spellID = EventSpellID(...)
	if not spellID then
		-- An event signature this client does not use can still end an open
		-- channel; the channel stop is unambiguous.
		if not (casting and event == "UNIT_SPELLCAST_CHANNEL_STOP") then
			return
		end
		spellID = 0
	end
	-- A stop with no cast behind it (logging in mid-cast) closes nothing.
	if castStartedAt <= 0 then
		return
	end
	-- When the client raises channel events for a cast the generic pair
	-- arrives alongside them, and the generic STOP can land while the line is
	-- still in the water. Only the channel stop closes the window then.
	if event ~= "UNIT_SPELLCAST_CHANNEL_STOP" and channelSeen then
		return
	end
	casting = false
	channelSeen = false
	-- Never shorten an open catch window. A generic stop can arrive while the
	-- lure is still in the water, and the channel stop can arrive after the
	-- loot: only extend the window in both cases.
	local graceUntil = Now() + LOOT_GRACE
	if graceUntil > catchUntil then
		catchUntil = graceUntil
	end
	ns.Trace("fishing: cast stop id="..tostring(spellID))
end

-- The same own-loot filter the Loot tab uses. Only this character's loot is
-- counted, and only while a cast is open; a fish taken from mail or a trade
-- has no cast behind it.
local function OnLoot(event, text, looter)
	local now = Now()
	if not ns.Tracks("loot") then
		return
	end
	if merchantOpen then
		-- A purchase, not a catch (see merchantOpen). The trace only fires
		-- when a cast window was open, which is exactly the case that used to
		-- put bought items on the fishing page.
		if now <= catchUntil then
			ns.Trace("fishing: ignored loot chat while a vendor was open")
		end
		return
	end
	if now > catchUntil then
		-- A cast event may be missed (or a client may not send one). If the
		-- player is channeling Fishing right now, this loot is still a catch:
		-- open the window, count the cast once, and record it.
		if not CurrentFishingSpell() then
			if lastCastAt > 0 and (now - lastCastAt) <= 120 then
				ns.Trace("fishing: loot outside the catch window by "..tostring(now - catchUntil).."s")
			end
			return
		end
		if lastCastAt <= 0 or (now - lastCastAt) > 90 then
			local fishing = Ensure(ns.GetChar())
			if fishing then
				fishing.casts = (tonumber(fishing.casts) or 0) + 1
			end
		end
		lastCastAt = now
		catchUntil = now + LOOT_GRACE
		ns.Trace("fishing: catch while channeling, no cast event seen")
	end
	if type(text) ~= "string" then
		return
	end
	if type(issecretvalue) == "function" and issecretvalue(text) then
		return
	end
	-- "You receive item" is the client's wording for something pushed into
	-- the bags - a vendor purchase, mail, the auction house - and "You
	-- create" is a craft. Neither is ever a bobber, and counting them was how
	-- bought items ended up on the fishing page whenever a cast window
	-- happened to be open.
	if string.find(text, "^You receive item") or string.find(text, "^You create") then
		if now <= catchUntil then
			ns.Trace("fishing: ignored a pushed item (vendor, mail or craft), not a catch")
		end
		return
	end
	local own = string.find(text, "^You receive loot")
	if not own and looter then
		local player = UnitName("player")
		local secret = type(issecretvalue) == "function" and issecretvalue(looter)
		own = (not secret and player and looter == player) or false
	end
	if not own then
		return
	end
	local itemID = tonumber(string.match(text, "|Hitem:(%d+)"))
	if not itemID then
		return
	end
	local name = string.match(text, "%[([^%]]+)%]")
	local count = tonumber(string.match(text, "|h|r%s*x(%d+)")) or 1
	local quality = 1
	local _, _, itemQuality = ns.ItemInfo(itemID)
	if itemQuality then
		quality = itemQuality
	end
	RecordOnce(itemID, name, quality, count, now)
end

-- The client's own answer for a fishing loot window. This is the strongest
-- signal available: it does not depend on the cast event, on chat wording, or
-- on the timing of the channel. Use it on LOOT_READY and LOOT_OPENED.
local function OnLootWindow()
	if not ns.Tracks("loot") then
		return
	end
	local now = Now()
	local verified = false
	if type(IsFishingLoot) == "function" then
		local ok, isFishing = pcall(IsFishingLoot)
		verified = ok and isFishing and true or false
		if not verified then
			return
		end
	elseif now <= catchUntil then
		-- No IsFishingLoot on this client: trust only the open fishing cast.
		verified = true
	end
	if not verified then
		return
	end

	if now > catchUntil then
		-- A verified fishing window with no cast event: count the cast once and
		-- give the rest of this bobber's loot a window. If the previous cast was
		-- more than a few seconds ago this is a new bobber, so the per-cast
		-- dedupe starts fresh.
		if lastCastAt <= 0 or (now - lastCastAt) > 10 then
			lootRecorded = {}
			if lastCastAt <= 0 or (now - lastCastAt) > 90 then
				local fishing = Ensure(ns.GetChar())
				if fishing then
					fishing.casts = (tonumber(fishing.casts) or 0) + 1
				end
			end
		end
		lastCastAt = now
		catchUntil = now + LOOT_GRACE
		ns.Trace("fishing: verified loot window without a cast event")
	end

	local okCount, count = pcall(GetNumLootItems)
	if not okCount or type(count) ~= "number" or count <= 0 then
		return
	end
	local found = {}
	for slot = 1, count do
		local okLink, link = pcall(GetLootSlotLink, slot)
		if okLink and type(link) == "string" then
			local secret = type(issecretvalue) == "function" and issecretvalue(link)
			if not secret then
				local itemID = tonumber(string.match(link, "item:(%d+)"))
				if itemID then
					local okInfo, _, name, quantity, _, quality = pcall(GetLootSlotInfo, slot)
					if okInfo then
						local entry = found[itemID]
						if not entry then
							entry = { name = name, quality = quality, quantity = 0 }
							found[itemID] = entry
						end
						local okQty, qty = pcall(tonumber, quantity)
						entry.quantity = entry.quantity + ((okQty and qty) or 1)
					end
				end
			end
		end
	end
	for itemID, entry in pairs(found) do
		RecordOnce(itemID, entry.name, entry.quality, entry.quantity, now)
	end
end

ns.fishing = {
	Ensure = Ensure,
	RecordCatch = RecordCatch,
	Clear = Clear,
}

ns.On("UNIT_SPELLCAST_CHANNEL_START", OnCastStart, "Fishing")
ns.On("UNIT_SPELLCAST_CHANNEL_STOP", OnCastStop, "Fishing")
ns.On("UNIT_SPELLCAST_START", OnCastStart, "Fishing")
ns.On("UNIT_SPELLCAST_STOP", OnCastStop, "Fishing")
ns.On("CHAT_MSG_LOOT", OnLoot, "Fishing")
ns.On("LOOT_READY", OnLootWindow, "Fishing")
ns.On("LOOT_OPENED", OnLootWindow, "Fishing")
ns.On("MERCHANT_SHOW", function()
	merchantOpen = true
end, "Fishing")
ns.On("MERCHANT_CLOSED", function()
	merchantOpen = false
end, "Fishing")
ns.On("PLAYER_LOGIN", function()
	casting = false
	channelSeen = false
	castStartedAt = 0
	lastCastAt = 0
	catchUntil = 0
	lootRecorded = {}
	lastLootRecordAt = 0
	unknownCastLogged = false
	merchantOpen = false
	RefreshFishingName()
end, "Fishing")
