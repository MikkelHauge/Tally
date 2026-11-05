-- Tally - loot: item values, quality, best finds, the per-item tally and the
-- loot messages that feed them.
--
-- One character subtree is owned here: char.loot. The item cache helpers are
-- here too, because the value, the tally and the reports all read the same
-- item data.
local addonName, ns = ...

local Now, TUNING = ns.Now, ns.TUNING

-- Items whose value the game had not cached yet, by item id:
-- [itemID] = { count, tries, name, quality }
local pendingLoot = {}

-------------------------------------------------------------------------------
-- Loot
-------------------------------------------------------------------------------

local QUALITY_BY_COLOR = {
	ff9d9d9d = 0,   -- poor
	ffffffff = 1,   -- common
	ff1eff00 = 2,   -- uncommon
	ff0070dd = 3,   -- rare
	ffa335ee = 4,   -- epic
	ffff8000 = 5,   -- legendary
	ffe6cc80 = 6,   -- artifact
}

local function InsertBestLoot(entry)
	local char = ns.GetChar()
	if not char then
		return
	end
	local best = char.loot.best
	for index = 1, #best do
		if best[index].id == entry.id then
			return -- keep the first sighting of each item
		end
	end
	best[#best + 1] = entry
	table.sort(best, function(a, b)
		return (a.value or 0) > (b.value or 0)
	end)
	while #best > TUNING.bestLootCap do
		table.remove(best)
	end
end

-- The item-info accessor, resolved once. This client has no global
-- GetItemInfo. When neither form exists, item counts are still recorded
-- but item values are not, and ns.itemValueAvailable lets the UI mark
-- values as unavailable rather than zero.
local ItemInfoFn
if type(GetItemInfo) == "function" then
	ItemInfoFn = GetItemInfo
elseif type(C_Item) == "table" and type(C_Item.GetItemInfo) == "function" then
	ItemInfoFn = C_Item.GetItemInfo
end
ns.itemValueAvailable = (ItemInfoFn ~= nil)

-- Whether the item belongs to the quest class. Read from the same cache as the
-- name and quality; an item the cache has not met yet is treated as ordinary,
-- which is what it will be in almost every case.
local function IsQuestItem(itemID)
	if not ItemInfoFn or type(itemID) ~= "number" then
		return false
	end
	local ok, _, _, _, _, _, itemClass = pcall(ItemInfoFn, itemID)
	return ok and itemClass == "Quest" or false
end

-- A disenchant yields trade goods/reagents. When the cache can say what the
-- item is, only those can be an Enchanting gain; when it cannot, the short
-- disenchant window remains the fallback.
local function IsEnchantingMaterial(itemID)
	if not ItemInfoFn or type(itemID) ~= "number" then
		return true
	end
	local ok, _, _, _, _, _, itemClass, itemSubClass = pcall(ItemInfoFn, itemID)
	if not ok or not itemClass then
		return true
	end
	return itemClass == "Trade Goods" or itemClass == "Reagent" or itemSubClass == "Enchanting"
end

-- Name, link, quality and vendor price for an item id, straight from the
-- client's item cache. Returns nil when the client has not cached the item, so
-- a caller can leave a value unlabelled rather than guessed; the price is the
-- same field the loot value is worked out from, so a "most looted item" box
-- and the loot totals cannot disagree.
function ns.ItemInfo(itemID)
	if not ItemInfoFn or type(itemID) ~= "number" then
		return nil
	end
	local ok, name, link, quality, _, _, _, _, _, _, _, sellPrice = pcall(ItemInfoFn, itemID)
	if not ok or type(name) ~= "string" then
		return nil
	end
	return name, link, quality, sellPrice
end

-- Name lookups through the same API the id lookups use. On a client where
-- only C_Item.GetItemInfo is present the plain GetItemInfo global is nil, and
-- a name could not be resolved at all; keeping both paths on ItemInfoFn means
-- one fallback works wherever the other does.
function ns.ItemInfoByName(name)
	if type(name) ~= "string" then
		return nil
	end
	local function Ask(fn)
		if type(fn) ~= "function" then
			return nil
		end
		local ok, itemName, link, quality = pcall(fn, name)
		if ok and type(itemName) == "string" then
			return itemName, link, quality
		end
		return nil
	end
	local itemName, link, quality = Ask(ItemInfoFn)
	if itemName then
		return itemName, link, quality
	end
	if type(C_Item) == "table" and C_Item.GetItemInfo ~= ItemInfoFn then
		return Ask(C_Item.GetItemInfo)
	end
	return nil
end

-- The item id behind a name the cache knows, where the client offers it.
function ns.ItemIDForName(name)
	if type(name) ~= "string" then
		return nil
	end
	if type(C_Item) == "table" and type(C_Item.GetItemIDForItemInfo) == "function" then
		local ok, itemID = pcall(C_Item.GetItemIDForItemInfo, name)
		if ok and type(itemID) == "number" and itemID > 0 then
			return itemID
		end
	end
	return nil
end

-- Items the player is carrying, by name: the one source that can name an
-- item the auction mail only named and the cache would not resolve. Bags are
-- read through whichever container API the game offers. Returns
-- name -> { id, quality }; callers may cache it for one report.
function ns.BagItemIndex()
	local index = {}
	local function LinkAt(bag, slot)
		if type(C_Container) == "table" and type(C_Container.GetContainerItemLink) == "function" then
			local ok, link = pcall(C_Container.GetContainerItemLink, bag, slot)
			if ok and type(link) == "string" then
				return link
			end
		end
		if type(GetContainerItemLink) == "function" then
			local ok, link = pcall(GetContainerItemLink, bag, slot)
			if ok and type(link) == "string" then
				return link
			end
		end
		return nil
	end
	local function Slots(bag)
		if type(C_Container) == "table" and type(C_Container.GetContainerNumSlots) == "function" then
			local ok, count = pcall(C_Container.GetContainerNumSlots, bag)
			if ok and type(count) == "number" then
				return count
			end
		end
		if type(GetContainerNumSlots) == "function" then
			local ok, count = pcall(GetContainerNumSlots, bag)
			if ok and type(count) == "number" then
				return count
			end
		end
		return 0
	end
	for bag = 0, 5 do
		local count = Slots(bag)
		for slot = 1, count do
			local link = LinkAt(bag, slot)
			if link then
				local name, _, quality = ns.ItemInfoByName(link)
				if name then
					local itemID = tonumber(string.match(link, "item:(%d+)"))
					local known = index[name]
					if not known then
						known = {}
						index[name] = known
					end
					if known.id == nil then
						known.id = itemID
					end
					if known.quality == nil then
						known.quality = quality
					end
				end
			end
		end
	end
	return index
end

-- Item data can arrive a moment late on this client; returns true once the
-- value has been accounted for (or once there is nothing to account for).
local function ResolveLootValue(itemID, count, fallbackName, fallbackQuality)
	local char = ns.GetChar()
	if not char or not ns.Tracks("loot") then
		-- Loot is switched off: report the value as not accounted for, so a
		-- pending entry is kept rather than dropped and valued later, when
		-- the tab is switched back on.
		return false
	end
	if not ItemInfoFn then
		return true -- no item API here: nothing to add up and nothing to retry
	end
	local ok, name, _, quality, _, _, _, _, _, _, _, sellPrice = pcall(ItemInfoFn, itemID)
	if not ok or not name then
		return false -- refused or not cached yet; the caller retries
	end
	local value = sellPrice or 0
	char.loot.value = char.loot.value + value * count
	char.loot.valueAt = Now()
	char.loot.valueEvidence = "item_cache"
	if value > 0 then
		char.loot.pricedItems = (char.loot.pricedItems or 0) + count
	else
		char.loot.unpricedItems = (char.loot.unpricedItems or 0) + count
	end
	if ns.Touch then
		ns.Touch(char, "loot.value", char.loot.valueAt)
	end
	local session = char.sessions.current
	if session then
		session.itemValue = (session.itemValue or 0) + value * count
	end
	if fallbackQuality and quality and fallbackQuality ~= quality then
		-- The loot message's colour is only a hint (white when the message
		-- carries none); the item API is authoritative. Move the count to
		-- its true quality bucket so the breakdown matches the name shown
		-- in Best finds.
		char.loot.quality[fallbackQuality] = math.max(0, (char.loot.quality[fallbackQuality] or 0) - count)
		char.loot.quality[quality] = (char.loot.quality[quality] or 0) + count
		if ns.NoteLootQualityMilestone then
			ns.NoteLootQualityMilestone(quality, char.loot.quality[quality])
		end
	end
	if value > 0 then
		InsertBestLoot({
			id = itemID,
			name = fallbackName or name,
			-- Prefer the API's quality: the fallback is white whenever the
			-- message carried no colour.
			quality = quality or fallbackQuality or 1,
			value = value,
			at = Now(),
			count = count,
		})
		if ns.NoteRecord then
			ns.NoteRecord("loot.bestFind", value, Now())
		end
	end
	return true
end

-- Queues stored best-loot entries for a quality repair pass. Entries may
-- predate the stored quality (rendered white), or have come from a loot
-- message without colour. At login every stored find is queued; the pass
-- processes a few per tick, retries while the item cache warms, and drops
-- an entry for the session if the client never answers for its id.
local lootQualityQueue = nil
local lootQualityQueued = false
local LOOT_QUALITY_PER_TICK = 4
local LOOT_QUALITY_TRIES = 30

local function QueueLootQualityRepair()
	if lootQualityQueued then
		return
	end
	lootQualityQueued = true
	lootQualityQueue = {}
	if not (ns.db and ns.db.chars) then
		return
	end
	for _, char in pairs(ns.db.chars) do
		local best = char.loot and char.loot.best
		if best then
			for index = 1, #best do
				local entry = best[index]
				if entry and entry.id then
					lootQualityQueue[#lootQualityQueue + 1] = { entry = entry, tries = 0 }
				end
			end
		end
	end
	if #lootQualityQueue > 0 then
		ns.Trace("loot quality repair: "..#lootQualityQueue.." stored finds queued")
	end
end

local function StepLootQualityRepair()
	local queue = lootQualityQueue
	if not queue or #queue == 0 then
		return
	end
	local keep = {}
	local checked = 0
	for index = 1, #queue do
		local item = queue[index]
		if checked >= LOOT_QUALITY_PER_TICK then
			keep[#keep + 1] = item
		else
			checked = checked + 1
			item.tries = item.tries + 1
			local resolved
			if ItemInfoFn then
				local ok, _, _, quality = pcall(ItemInfoFn, item.entry.id)
				if ok and type(quality) == "number" then
					resolved = quality
				end
			end
			if resolved then
				item.entry.quality = resolved
			elseif item.tries < LOOT_QUALITY_TRIES then
				keep[#keep + 1] = item
			end
		end
	end
	lootQualityQueue = #keep > 0 and keep or nil
	if lootQualityQueue == nil then
		ns.Trace("loot quality repair: finished")
	end
end

-- Per-character item tally (itemID -> { name, count, error }) that answers
-- which item was looted most. It is a fixed-size top list, not a record of
-- everything: when it is full the smallest entry makes way for a new item and
-- lends that item its count, so the true heavy hitters always stay in it and
-- an inherited count is reported as a lower bound. Grey and quest items are
-- not ranked at all.
local LOOT_ITEM_CAP = 40

-- Trims a tally that is over the cap, which only an old record can be: it used
-- to hold sixty before the sketch below existed. The smallest counts go.
local function PruneLootTally(char)
	local counts = char.loot.itemCounts
	local total = 0
	for _ in pairs(counts) do
		total = total + 1
	end
	if total <= LOOT_ITEM_CAP then
		return
	end
	local list = {}
	for id, tally in pairs(counts) do
		list[#list + 1] = { id = id, tally = tally }
	end
	table.sort(list, function(a, b)
		return (a.tally.count or 0) > (b.tally.count or 0)
	end)
	for index = LOOT_ITEM_CAP + 1, #list do
		counts[list[index].id] = nil
	end
end

-- The figure to show for a looted item: exact when the tally never inherited
-- a count, and a lower bound when its entry was made by evicting another - the
-- sketch lends a count it cannot see, so the true figure is somewhere between
-- count - inherited and count. Returns the safe figure and whether it is a
-- bound.
function ns.LootTallyCount(tally)
	local count = math.max(0, (tally and tally.count) or 0)
	local inherited = (tally and tally.error) or 0
	if count <= 0 then
		return 0, false
	end
	return math.max(1, count - inherited), inherited > 0
end

local function NoteLoot(itemID, linkName, quality, count)
	local char = ns.GetChar()
	if not char or not ns.Tracks("loot") then
		return
	end
	local at = Now()
	quality = quality or 1
	count = count or 1
	if quality == 4 and ns.NoteMilestoneFirst then
		ns.NoteMilestoneFirst("epicReceived", { name = linkName, itemID = itemID })
	end
	char.loot.items = char.loot.items + count
	char.loot.firstAt = char.loot.firstAt or at
	char.loot.lastAt = at
	char.loot.itemsEvidence = "chat_loot"
	if ns.Touch then
		ns.Touch(char, "loot.items", at)
	end
	if ns.NoteRecentEvent then
		ns.NoteRecentEvent("loot", {
			at = at, zone = ns.CurrentZone and ns.CurrentZone() or nil,
			how = "loot", evidence = "chat_loot",
			data = { itemID = itemID, name = linkName, count = count, quality = quality },
		})
	end
	if ns.NoteLootMilestone then
		ns.NoteLootMilestone(char.loot.items)
	end
	char.loot.quality[quality] = (char.loot.quality[quality] or 0) + count
	if ns.NoteLootQualityMilestone then
		ns.NoteLootQualityMilestone(quality, char.loot.quality[quality])
	end
	-- The last fifty drops, one entry per drop, newest last. It is the log
	-- behind the Loot tab's "Most recent loot" view; the item's own tally and
	-- the best-finds list are separate, aggregated views.
	local recent = char.loot.recent
	if not recent then
		recent = {}
		char.loot.recent = recent
	end
	recent[#recent + 1] = { id = itemID, name = linkName, quality = quality, count = count, at = at }
	while #recent > 50 do
		table.remove(recent, 1)
	end
	local counts = char.loot.itemCounts
	if not counts then
		-- Characters recorded before the tally existed: start it now.
		counts = {}
		char.loot.itemCounts = counts
	end
	-- The tally behind "Most looted" is a top-40 sketch. Grey items and quest
	-- items are left out - they are noise rather than loot, and a quest item
	-- that arrives in a stack of twenty would win the list outright. When the
	-- table is full the smallest entry makes way for the newcomer and lends it
	-- its count, which is the standard way to keep the true heavy hitters in
	-- a fixed amount of space.
	if quality ~= 0 and not IsQuestItem(itemID) then
		local tally = counts[itemID]
		if tally then
			tally.count = tally.count + count
		else
			local total = 0
			for _ in pairs(counts) do
				total = total + 1
			end
			if total < LOOT_ITEM_CAP then
				counts[itemID] = { name = linkName, count = count }
			else
				local victimID, victim
				for id, other in pairs(counts) do
					if not victim or (other.count or 0) < (victim.count or 0) then
						victimID, victim = id, other
					end
				end
				if victim then
					counts[victimID] = nil
					counts[itemID] = {
						name = linkName,
						count = (victim.count or 0) + count,
						error = victim.count or 0,
					}
				else
					counts[itemID] = { name = linkName, count = count }
				end
			end
		end
		PruneLootTally(char)
	end
	local session = char.sessions.current
	if session then
		session.items = (session.items or 0) + count
	end
	if not ResolveLootValue(itemID, count, linkName, quality) then
		local pending = pendingLoot[itemID]
		if pending then
			pending.count = pending.count + count
		else
			pendingLoot[itemID] = { count = count, tries = 0, name = linkName, quality = quality }
		end
	end
end

-- "You receive loot: |cff1eff00|Hitem:2592:...|h[Wool Cloth]|h|r x5."
-- The same chat channel carries every group member's loot line ("<name>
-- receives loot: ..."), so in a raid one boss drop arrives dozens of times.
-- Only the player's own loot is counted: the line that begins "You receive"
-- or one whose looter is the player. Everything else is another character's
-- loot and is not this character's record.
--
-- "You receive item: ..." is the client's pushed-item line, used by vendors,
-- mail and rewards. It is not loot and must not enter the loot tally; a
-- stack bought from a vendor would otherwise win "most looted item".
local function OnLootMessage(text, looter)
	if not text then
		return
	end
	-- Some clients report a destroy on the loot channel rather than as a
	-- system line.
	if string.find(text, "^You destroy") then
		ns.NoteDestroyedMessage(text)
		return
	end
	local own = string.find(text, "^You receive loot")
	if not own and looter then
		local player = UnitName("player")
		own = (player and looter == player and string.find(text, "receives loot")) or false
	end
	if not own then
		return
	end
	local itemID = tonumber(string.match(text, "|Hitem:(%d+)"))
	if not itemID then
		return
	end
	local linkName = string.match(text, "%[([^%]]+)%]")
	local color = string.match(text, "|c(%x%x%x%x%x%x%x%x)|H")
	local count = tonumber(string.match(text, "|h|r%s*x(%d+)")) or 1
	local quality = 1
	if color then
		quality = QUALITY_BY_COLOR[string.lower(color)] or 1
	else
		-- The client's loot message can arrive without the item's colour.
		-- The raw text is traced; the item API is then the source of
		-- quality, and the count moves to its true bucket when it answers.
		ns.Trace("loot message without colour: "..string.gsub(text, "|", "^"))
	end
	NoteLoot(itemID, linkName, quality, count)
	-- A material looted inside the disenchant window is also a profession
	-- gain, and is counted as crafted Enchanting output.
	if ns.NoteEnchantingGain and IsEnchantingMaterial(itemID) then
		ns.NoteEnchantingGain(itemID, linkName, quality, count)
	end
end

-- Destroyed items are kept separately from loot: nothing was gained, and the
-- loot totals must not move. The client prints "You destroy [Item]." as a
-- system message; UI_INFO_MESSAGE is the fallback on clients that use it.
local lastMessageDestroyKey, lastMessageDestroyAt
local lastCursorDestroyKey, lastCursorDestroyAt
local destroyMessagesSeen = false
local lastCursorItem

local function NoteDestroyed(itemID, name, quality, count, source)
	local char = ns.GetChar()
	if not char or not ns.Tracks("loot") then
		return
	end
	if ns.IsEnchantingGainWindow and ns.IsEnchantingGainWindow() then
		ns.Trace("destroyed: ignored during an enchant gain window")
		return
	end
	name = name or (itemID and select(1, ns.ItemInfo(itemID))) or "?"
	if not itemID and ns.ItemIDForName then
		local ok, found = pcall(ns.ItemIDForName, name)
		if ok then
			itemID = found
		end
	end
	if not quality and itemID then
		quality = select(3, ns.ItemInfo(itemID))
	end
	quality = tonumber(quality) or 1
	count = math.max(1, tonumber(count) or 1)
	local now = Now()
	local key = tostring(itemID or name)
	-- The two message forms for one destroy arrive together; a cursor fallback
	-- can also precede the message. Distinct destroys of the same item are
	-- never suppressed, so there is no 3-second "one item only" limit.
	if source == "message" then
		if lastMessageDestroyKey == key and now - (lastMessageDestroyAt or 0) < 0.5 then
			return
		end
		if lastCursorDestroyKey == key and now - (lastCursorDestroyAt or 0) < 2 then
			lastMessageDestroyKey, lastMessageDestroyAt = key, now
			return
		end
		lastMessageDestroyKey, lastMessageDestroyAt = key, now
	else
		lastCursorDestroyKey, lastCursorDestroyAt = key, now
	end
	local loot = char.loot
	local destroyed = loot.destroyed
	if type(destroyed) ~= "table" then
		destroyed = {}
		loot.destroyed = destroyed
	end
	destroyed.items = (tonumber(destroyed.items) or 0) + count
	destroyed.firstAt = destroyed.firstAt or now
	destroyed.lastAt = now
	if type(destroyed.quality) ~= "table" then
		destroyed.quality = {}
	end
	destroyed.quality[quality] = (tonumber(destroyed.quality[quality]) or 0) + count
	if type(destroyed.itemCounts) ~= "table" then
		destroyed.itemCounts = {}
	end
	local tally = destroyed.itemCounts[key]
	if type(tally) ~= "table" then
		tally = { name = name, itemID = itemID, quality = quality, count = 0, firstAt = now }
		destroyed.itemCounts[key] = tally
	end
	tally.name = tally.name or name
	tally.itemID = tally.itemID or itemID
	tally.quality = tally.quality or quality
	tally.count = (tonumber(tally.count) or 0) + count
	tally.lastAt = now
	ns.Trace("destroyed: "..tostring(name).." x"..count)
end

function ns.NoteDestroyedMessage(text)
	if type(text) ~= "string" then
		return
	end
	local plain = string.lower(ns.StripColors(text))
	if not string.find(plain, "you destroy", 1, true)
		and not string.find(plain, "destroyed", 1, true) then
		return
	end
	ns.Trace("destroyed text: "..string.gsub(text, "|", "^"))
	local itemID = tonumber(string.match(text, "|Hitem:(%d+)"))
	local linkName = string.match(text, "%[([^%]]+)%]")
	local color = string.match(text, "|c(%x%x%x%x%x%x%x%x)|H")
	local quality = color and QUALITY_BY_COLOR[string.lower(color)] or nil
	local count = tonumber(string.match(text, "|h|r%s*x(%d+)")) or 1
	if not linkName then
		-- Some clients name the item without an item link or brackets.
		local plainName = string.match(ns.StripColors(text), "[Yy]ou destroy%s+(.+)")
		if plainName then
			plainName = string.gsub(plainName, "|H.-|h", "")
			plainName = string.gsub(plainName, "|h", "")
			plainName = string.gsub(plainName, "%.%s*$", "")
			plainName = string.match(plainName, "^%s*(.-)%s*$") or plainName
			if plainName ~= "" then
				linkName = plainName
			end
		end
	end
	if not linkName and itemID then
		linkName = select(1, ns.ItemInfo(itemID))
	end
	if not itemID and linkName and ns.ItemIDForName then
		local ok, found = pcall(ns.ItemIDForName, linkName)
		if ok then
			itemID = found
		end
	end
	if not itemID and not linkName then
		ns.Trace("destroyed message without an item: "..string.gsub(text, "|", "^"))
		return
	end
	-- The client does print destroy lines. From here on the cursor fallback
	-- stays out of the way; the message is authoritative for every destroy.
	destroyMessagesSeen = true
	NoteDestroyed(itemID, linkName, quality, count, "message")
end

local function ResolvePendingLoot()
	for itemID, pending in pairs(pendingLoot) do
		pending.tries = pending.tries + 1
		if pending.tries > 10 or ResolveLootValue(itemID, pending.count, pending.name, pending.quality) then
			pendingLoot[itemID] = nil
		end
	end
end

-- The item-info event may answer for one item at a time; the caller only has
-- the item id, so the pending entry is looked up here.
function ns.ResolvePendingLootFor(itemID)
	local pending = itemID and pendingLoot[itemID]
	if not pending or not ns.Tracks("loot") then
		return
	end
	if ResolveLootValue(itemID, pending.count, pending.name, pending.quality) then
		pendingLoot[itemID] = nil
	end
end

ns.OnLootMessage = OnLootMessage
ns.ResolvePendingLoot = ResolvePendingLoot

function ns.LootDebug()
	local char = ns.GetChar()
	local destroyed = char and char.loot and char.loot.destroyed or {}
	local kinds = 0
	for _ in pairs(destroyed.itemCounts or {}) do
		kinds = kinds + 1
	end
	return "loot: destroyed="..tostring(destroyed.items or 0)..", kinds="..kinds
		..", destroyMessagesSeen="..tostring(destroyMessagesSeen)
		..", cursorItem="..(lastCursorItem and tostring(lastCursorItem.id or lastCursorItem.name) or "nil")
end

-- Clients that report a destroy through UI_INFO_MESSAGE rather than chat.
ns.On("UI_INFO_MESSAGE", function(_, _, message)
	if type(message) == "string" then
		ns.NoteDestroyedMessage(message)
	end
end, "Loot")

-- Last-resort destroy path: remember the item on the cursor, then record it
-- when the client's delete function is used. The chat message normally gets
-- there first; the two-second dedupe in NoteDestroyed keeps them apart.
ns.On("UPDATE_CURSOR", function()
	if type(GetCursorInfo) ~= "function" then
		return
	end
	local kind, itemID, itemLink = GetCursorInfo()
	if kind == "item" and type(itemID) == "number" then
		lastCursorItem = { id = itemID, link = itemLink }
	end
end, "Loot")

if type(DeleteCursorItem) == "function" and type(hooksecurefunc) == "function" then
	pcall(hooksecurefunc, "DeleteCursorItem", function()
		-- Only for clients that never print a destroy line. Once one has been
		-- seen, the message path is authoritative and there is no time limit
		-- on how often items may be destroyed.
		if destroyMessagesSeen then
			return
		end
		local item = lastCursorItem
		lastCursorItem = nil
		if not item then
			ns.Trace("destroyed: DeleteCursorItem without a cached item")
			return
		end
		local link = item.link
		local itemID = item.id or tonumber(type(link) == "string" and string.match(link, "item:(%d+)") or nil)
		local name = item.name
		if not name and type(link) == "string" then
			name = string.match(link, "%[([^%]]+)%]")
		end
		local color = type(link) == "string" and string.match(link, "|c(%x%x%x%x%x%x%x%x)|H") or nil
		local quality = color and QUALITY_BY_COLOR[string.lower(color)] or nil
		NoteDestroyed(itemID, name, quality, 1, "cursor")
	end)
end

-- The confirmation popup is another chance to learn which item is about to be
-- deleted, on clients where the item is not left on the cursor.
if type(StaticPopup_Show) == "function" and type(hooksecurefunc) == "function" then
	pcall(hooksecurefunc, "StaticPopup_Show", function(which, textArg1, textArg2, data)
		if which ~= "DELETE_ITEM" and which ~= "DELETE_GOOD_ITEM" then
			return
		end
		if type(GetCursorInfo) == "function" then
			local kind, itemID, itemLink = GetCursorInfo()
			if kind == "item" and type(itemID) == "number" then
				lastCursorItem = { id = itemID, link = itemLink }
				return
			end
		end
		local values = { textArg1, textArg2, data }
		for index = 1, #values do
			local value = values[index]
			if type(value) == "string" then
				local id = tonumber(string.match(value, "item:(%d+)"))
				local name = string.match(value, "%[([^%]]+)%]")
				if id or name then
					lastCursorItem = { id = id, link = value, name = name }
					ns.Trace("destroyed: delete popup cached "..tostring(id or name))
					return
				end
			end
		end
	end)
end

-- Item values still waiting for the client's item cache belong to the
-- character that looted them; a character switch must not resolve them into
-- the next character's totals.
function ns.ClearPendingLoot()
	pendingLoot = {}
end
ns.StepLootQualityRepair = StepLootQualityRepair
ns.QueueLootQualityRepair = QueueLootQualityRepair
-- Owner namespace. Every field references the flat API; itemValueAvailable
-- stays a flat flag because it is mutable state, not a function.
ns.loot = {}
ns.loot.ItemInfo = ns.ItemInfo
ns.loot.ItemInfoByName = ns.ItemInfoByName
ns.loot.ItemIDForName = ns.ItemIDForName
ns.loot.BagItemIndex = ns.BagItemIndex
ns.loot.TallyCount = ns.LootTallyCount
ns.loot.OnMessage = ns.OnLootMessage
ns.loot.NoteDestroyedMessage = ns.NoteDestroyedMessage
ns.loot.ResolvePending = ns.ResolvePendingLoot
ns.loot.ResolvePendingFor = ns.ResolvePendingLootFor
ns.loot.ClearPending = ns.ClearPendingLoot
ns.loot.StepQualityRepair = ns.StepLootQualityRepair
ns.loot.QueueQualityRepair = ns.QueueLootQualityRepair
