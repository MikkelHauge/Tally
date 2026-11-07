-- Tally - gathering: ore, herbs and leather, by character level and zone.
--
-- The client has no "you gathered" event carrying the item. A successful
-- Mining, Herbalism or Skinning cast is followed by a loot window or loot
-- message; that short window is credited to the profession. The spell ids are
-- the same ones Analyst uses across the supported clients. Fishing has its own
-- module and is deliberately ignored here.
--
-- One character subtree is owned here: char.gathering[Profession].
local addonName, ns = ...

local Now = ns.Now

local GATHERING_SPELLS = {
	[7620] = "Fishing", [7731] = "Fishing", [7732] = "Fishing", [18248] = "Fishing",
	[2366] = "Herbalism", [2368] = "Herbalism", [3570] = "Herbalism", [11993] = "Herbalism",
	[2575] = "Mining", [2576] = "Mining", [3564] = "Mining", [10248] = "Mining",
	[8613] = "Skinning", [8617] = "Skinning", [8618] = "Skinning", [10768] = "Skinning",
}
local GATHER_ORDER = { "Fishing", "Mining", "Herbalism", "Skinning" }
local GATHER_SET = {}
for _, name in ipairs(GATHER_ORDER) do
	GATHER_SET[name] = true
end

-- A node or corpse is looted immediately after the successful gather. The
-- window is generous enough for a slow loot click but short enough that an
-- unrelated loot window is not pulled in.
local GATHER_WINDOW = 15

local activeProfession
local activeUntil = 0
local activeAt = 0
local activeGUID
local lootRecorded = {}
local windowMatched = false
-- A vendor is open. Buying something pushes the item into the bags with the
-- same chat wording a loot line can use, so loot chat is ignored while a
-- merchant window is up. A node or corpse cannot be looted then, and the
-- loot-window path below is untouched if it ever could.
local merchantOpen = false

local function SafeString(value)
	if type(value) ~= "string" then
		return nil
	end
	if type(issecretvalue) == "function" and issecretvalue(value) then
		return nil
	end
	return value
end

-- The skinned corpse is the player's target during the cast. Its GUID lets
-- the loot window and chat lines be matched to that corpse instead of any
-- other loot that happens to arrive while the gather context is open.
local function TargetGUID()
	if type(UnitGUID) ~= "function" then
		return nil
	end
	local ok, guid = pcall(UnitGUID, "target")
	if not ok then
		return nil
	end
	return SafeString(guid)
end

-- The spell name through whichever API this client has.
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

local function ProfessionForName(name)
	name = SafeString(name)
	if name == "Mining" or name == "Herbalism" or name == "Skinning" or name == "Fishing" then
		return name
	end
	return nil
end

local function ProfessionForSpell(spellID)
	local ok, id = pcall(tonumber, spellID)
	if not ok or not id then
		return nil
	end
	return GATHERING_SPELLS[id] or ProfessionForName(SpellName(id))
end

-- Modern clients send (unit, castGUID, spellID); older ones can include the
-- spell name and rank before the id. Scan both shapes without trusting one.
local function EventProfession(...)
	local args = { ... }
	local byName = ProfessionForName(args[1])
	if byName then
		return byName
	end
	for index = 2, #args do
		local profession = ProfessionForSpell(args[index])
		if profession then
			return profession
		end
	end
	return nil
end

local function Ensure(char)
	if not char then
		return nil
	end
	if type(char.gathering) ~= "table" then
		char.gathering = {}
	end
	return char.gathering
end

local function EnsureProfession(char, profession)
	local store = Ensure(char)
	if not store then
		return nil
	end
	local entry = store[profession]
	if type(entry) ~= "table" then
		entry = {}
		store[profession] = entry
	end
	if type(entry.items) ~= "table" then
		entry.items = {}
	end
	if type(entry.zones) ~= "table" then
		entry.zones = {}
	end
	if type(entry.levels) ~= "table" then
		entry.levels = {}
	end
	entry.attempts = tonumber(entry.attempts) or 0
	entry.gathered = tonumber(entry.gathered) or 0
	return entry
end

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

local function RecordGather(profession, itemID, name, quality, count, at)
	local char = ns.GetChar()
	if not char or not itemID or not profession then
		return false
	end
	local entry = EnsureProfession(char, profession)
	if not entry then
		return false
	end
	local zone = CurrentZone()
	local level = CurrentLevel()
	local itemName, _, itemQuality, sellPrice = ns.ItemInfo(itemID)
	name = SafeString(itemName) or SafeString(name) or ("item "..tostring(itemID))
	local okQuality, numericQuality = pcall(tonumber, quality)
	quality = itemQuality or (okQuality and numericQuality) or 1
	at = at or Now()
	count = math.max(1, tonumber(count) or 1)
	local okPrice, price = pcall(tonumber, sellPrice)
	sellPrice = (okPrice and price) or 0

	local item = entry.items[itemID]
	if type(item) ~= "table" then
		item = {
			name = name, quality = quality, count = 0,
			zones = {}, levels = {}, firstAt = at, unitValue = sellPrice,
		}
		entry.items[itemID] = item
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
	entry.zones[zone] = (tonumber(entry.zones[zone]) or 0) + count
	entry.levels[level] = (tonumber(entry.levels[level]) or 0) + count
	entry.gathered = (tonumber(entry.gathered) or 0) + count

	local pile = (tonumber(item.unitValue) or 0) * count
	if pile > (tonumber(entry.best and entry.best.value) or 0) then
		entry.best = {
			id = itemID, name = name, quality = quality, count = count,
			value = pile, at = at, zone = zone,
		}
	end
	ns.Trace("gathering: "..profession.." "..name.." x"..count.." in "..zone.." at level "..level)
	return true
end

-- The loot window and the chat line can both report one gather. Each path
-- reports a total quantity for this gather, so only the part not already
-- counted is added.
local function RecordOnce(profession, itemID, name, quality, quantity, at)
	if not itemID or not profession then
		return false
	end
	at = at or Now()
	quantity = math.max(1, math.floor(tonumber(quantity) or 1))
	local prior = lootRecorded[itemID]
	local counted = prior and prior.quantity or 0
	if quantity <= counted then
		return false
	end
	lootRecorded[itemID] = { quantity = quantity, at = at }
	return RecordGather(profession, itemID, name, quality, quantity - counted, at)
end

local function Clear()
	activeProfession = nil
	activeAt = 0
	activeUntil = 0
	activeGUID = nil
	lootRecorded = {}
	windowMatched = false
end

local function BeginGather(profession, attempt)
	if ns.fishing and ns.fishing.Clear then
		ns.fishing.Clear()
	end
	local now = Now()
	activeProfession = profession
	activeAt = now
	activeUntil = now + GATHER_WINDOW
	activeGUID = TargetGUID()
	lootRecorded = {}
	windowMatched = false
	if attempt then
		local entry = EnsureProfession(ns.GetChar(), profession)
		if entry then
			entry.attempts = (tonumber(entry.attempts) or 0) + 1
		end
	end
end

local function OnGatherStart(event, unit, ...)
	if unit and unit ~= "player" then
		return
	end
	if not ns.Tracks("loot") then
		return
	end
	local profession = EventProfession(...)
	if not profession or profession == "Fishing" then
		return
	end
	BeginGather(profession, false)
	ns.Trace("gathering: "..profession.." start")
end

local function OnGatherSuccess(event, unit, ...)
	if unit and unit ~= "player" then
		return
	end
	if not ns.Tracks("loot") then
		return
	end
	local profession = EventProfession(...)
	if not profession or profession == "Fishing" then
		return
	end
	BeginGather(profession, true)
	-- The target is settled by the time the cast succeeds; use it when the
	-- start event fired before the corpse was targeted.
	activeGUID = TargetGUID() or activeGUID
	ns.Trace("gathering: "..profession.." gather")
end

local function OnGatherFailed(event, unit, ...)
	if unit and unit ~= "player" then
		return
	end
	local profession = EventProfession(...)
	if profession and profession == activeProfession then
		Clear()
	end
end

local function LootSource()
	if type(GetLootSource) ~= "function" then
		return nil, nil
	end
	local ok, source = pcall(GetLootSource)
	source = ok and SafeString(source) or nil
	if not source then
		return nil, nil
	end
	if string.find(source, "^GameObject", 1, true) then
		return source, "GameObject"
	end
	if string.find(source, "^Creature", 1, true) or string.find(source, "^Player", 1, true) then
		return source, "Unit"
	end
	return source, nil
end

-- Compare a loot source with the skinned corpse's GUID. Both normally carry
-- the full "Creature-..." string; a suffix check covers clients that trim it.
local function GUIDMatches(source, guid)
	if source == guid then
		return true
	end
	if #source < 10 or #guid < 10 then
		return false
	end
	if #source < #guid then
		return string.sub(guid, -#source) == source
	end
	return string.sub(source, -#guid) == guid
end

-- Is this loot the gather that is currently open? Skinning has to be the
-- corpse that was skinned, not another corpse looted in the same window. A
-- node has to come from a game object, not a corpse.
local function SourceAllowed(profession, source, sourceType)
	if profession == "Skinning" then
		if source and activeGUID then
			return GUIDMatches(source, activeGUID)
		end
		if sourceType then
			return sourceType == "Unit"
		end
		return true
	end
	if profession == "Mining" or profession == "Herbalism" then
		if sourceType == "Unit" then
			return false
		end
	end
	return true
end

local function OnLootWindow()
	if not ns.Tracks("loot") or not activeProfession then
		return
	end
	local now = Now()
	if now > activeUntil then
		activeProfession = nil
		return
	end
	-- A fishing loot window belongs to the Fishing module, even if a gather
	-- happened shortly before it.
	if type(IsFishingLoot) == "function" then
		local ok, isFishing = pcall(IsFishingLoot)
		if ok and isFishing then
			activeProfession = nil
			activeUntil = 0
			return
		end
	end
	local source, sourceType = LootSource()
	if not SourceAllowed(activeProfession, source, sourceType) then
		return
	end

	local okCount, count = pcall(GetNumLootItems)
	if not okCount or type(count) ~= "number" or count <= 0 then
		return
	end
	-- The gather window we were waiting for. One window is enough: after it
	-- closes the context ends, so a corpse looted later cannot be mistaken
	-- for the skinned one.
	windowMatched = true
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
		RecordOnce(activeProfession, itemID, entry.name, entry.quality, entry.quantity, now)
	end
end

local function OnLootClosed()
	if windowMatched then
		-- The gather's loot window has been read. Keeping the context alive
		-- after it was the reason a corpse looted afterwards was credited to
		-- Skinning.
		Clear()
	end
end

local function OnLoot(event, text, looter)
	if not ns.Tracks("loot") or not activeProfession then
		return
	end
	local now = Now()
	if now > activeUntil then
		activeProfession = nil
		return
	end
	if merchantOpen then
		-- A purchase, not the gather this window was opened for. The trace
		-- names the case that would otherwise have been credited.
		ns.Trace("gathering: ignored loot chat while a vendor was open")
		return
	end
	if type(text) ~= "string" then
		return
	end
	if type(issecretvalue) == "function" and issecretvalue(text) then
		return
	end
	if string.find(text, "^You receive item") or string.find(text, "^You create") then
		return
	end
	local source, sourceType = LootSource()
	if not SourceAllowed(activeProfession, source, sourceType) then
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
	RecordOnce(activeProfession, itemID, name, quality, count, now)
end

-- The gathering professions the character has, in display order. Saved data
-- covers offline alts; the live character can also ask the client.
local function LearnedProfessions(char)
	local names = {}
	if not char then
		return names
	end
	local known = {}
	local store = char.professions
	if type(store) == "table" then
		for _, skill in ipairs(store.skills or {}) do
			if type(skill) == "table" and skill.name then
				known[skill.name] = true
			end
		end
		for name in pairs(store.recipes or {}) do
			known[name] = true
		end
		for name in pairs(store.crafts or {}) do
			known[name] = true
		end
		for name in pairs(store.learned or {}) do
			known[name] = true
		end
		for _, gains in pairs(store.byLevel or {}) do
			if type(gains) == "table" then
				for name in pairs(gains) do
					known[name] = true
				end
			end
		end
	end
	for name in pairs(char.gathering or {}) do
		known[name] = true
	end
	local fishing = char.fishing
	if type(fishing) == "table"
		and ((tonumber(fishing.casts) or 0) > 0
			or (tonumber(fishing.catches) or 0) > 0
			or next(fishing.items or {}) ~= nil) then
		known.Fishing = true
	end
	if char == ns.GetChar()
		and type(GetProfessions) == "function"
		and type(GetProfessionInfo) == "function" then
		local ok, professions = pcall(GetProfessions)
		if ok and type(professions) == "table" then
			for _, index in ipairs(professions) do
				local okInfo, name = pcall(GetProfessionInfo, index)
				if okInfo and type(name) == "string" then
					known[name] = true
				end
			end
		end
	end
	if char == ns.GetChar()
		and type(GetNumSkillLines) == "function"
		and type(GetSkillLineInfo) == "function" then
		local ok, count = pcall(GetNumSkillLines)
		if ok and type(count) == "number" then
			for index = 1, count do
				local okLine, name, isHeader = pcall(GetSkillLineInfo, index)
				if okLine and not isHeader and type(name) == "string" and GATHER_SET[name] then
					known[name] = true
				end
			end
		end
	end
	for _, name in ipairs(GATHER_ORDER) do
		if known[name] and GATHER_SET[name] then
			names[#names + 1] = name
		end
	end
	return names
end

ns.gathering = {
	Ensure = Ensure,
	EnsureProfession = EnsureProfession,
	Record = RecordGather,
	Professions = LearnedProfessions,
	Clear = Clear,
	Order = GATHER_ORDER,
}

ns.On("UNIT_SPELLCAST_START", OnGatherStart, "Gathering")
ns.On("UNIT_SPELLCAST_CHANNEL_START", OnGatherStart, "Gathering")
ns.On("UNIT_SPELLCAST_SUCCEEDED", OnGatherSuccess, "Gathering")
ns.On("UNIT_SPELLCAST_INTERRUPTED", OnGatherFailed, "Gathering")
ns.On("UNIT_SPELLCAST_FAILED", OnGatherFailed, "Gathering")
ns.On("LOOT_READY", OnLootWindow, "Gathering")
ns.On("LOOT_OPENED", OnLootWindow, "Gathering")
ns.On("LOOT_CLOSED", OnLootClosed, "Gathering")
ns.On("CHAT_MSG_LOOT", OnLoot, "Gathering")
ns.On("MERCHANT_SHOW", function()
	merchantOpen = true
end, "Gathering")
ns.On("MERCHANT_CLOSED", function()
	merchantOpen = false
end, "Gathering")
ns.On("PLAYER_ENTERING_WORLD", function()
	-- A close event can be missed (a reload with the vendor up, a client
	-- quirk); every zone change clears the flag as well, so a stuck value
	-- cannot silence loot chat for the rest of the session.
	merchantOpen = false
end, "Gathering")
ns.On("PLAYER_LOGIN", function()
	activeProfession = nil
	activeAt = 0
	activeUntil = 0
	activeGUID = nil
	lootRecorded = {}
	windowMatched = false
	merchantOpen = false
end, "Gathering")
