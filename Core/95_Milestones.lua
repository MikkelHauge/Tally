-- Tally - one-time character milestones: first quality item per slot, first
-- helm and shoulders, level-up context, riding skill gains, first mount and
-- the first group.
--
-- One character subtree is owned here: char.milestones. Events are registered
-- through the shared registrar; this file never draws anything.
local addonName, ns = ...

local Now = ns.Now
local ZoneInfo
local ItemAt

local function Store()
	local char = ns.GetChar()
	if not char then
		return nil
	end
	if type(char.milestones) ~= "table" then
		char.milestones = {}
	end
	local store = char.milestones
	if type(store.firstEquip) ~= "table" then
		store.firstEquip = {}
	end
	if type(store.firstSlot) ~= "table" then
		store.firstSlot = {}
	end
	if type(store.riding) ~= "table" then
		store.riding = {}
	end
	if type(store.firsts) ~= "table" then
		store.firsts = {}
	end
	if type(store.firstWeapon) ~= "table" then
		store.firstWeapon = {}
	end
	if type(store.fullSets) ~= "table" then
		store.fullSets = {}
	end
	if type(store.firstGroupByClass) ~= "table" then
		store.firstGroupByClass = {}
	end
	if type(store.thresholds) ~= "table" then
		store.thresholds = {}
	end
	if type(store.future) ~= "table" then
		store.future = {}
	end
	for _, key in ipairs({ "quests", "gold", "goldSpent", "recipes", "professionSkills", "kills", "deaths", "dungeons", "bosses", "loot", "crafted", "distance" }) do
		if type(store.thresholds[key]) ~= "table" then
			store.thresholds[key] = {}
		end
	end
	return store
end

ns.milestoneThresholds = {
	quests = { 10, 25, 50, 100, 250, 500, 1000, 2000, 5000, 10000, 25000, 50000 },
	gold = { 10000, 100000, 1000000, 10000000, 100000000, 1000000000, 10000000000, 100000000000, 1000000000000, 10000000000000 },
	goldSpent = { 10000, 50000, 100000, 500000, 1000000, 10000000, 100000000, 1000000000, 10000000000, 10000000000000 },
	recipes = { 10, 25, 50, 100, 200, 300 },
	professionSkills = { 75, 150, 225, 300 },
	kills = { 10, 100, 500, 1000, 5000, 10000, 25000, 50000, 100000, 250000, 500000, 1000000, 2500000, 5000000, 10000000 },
	deaths = { 1, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 },
	dungeons = { 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000 },
	bosses = { 1, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000 },
	loot = { 100, 500, 1000, 5000, 10000, 25000, 50000, 100000, 250000, 500000, 1000000, 2500000, 5000000 },
	crafted = { 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 25000, 50000, 100000 },
	distance = { 10, 100, 500, 1000, 5000, 10000, 25000, 50000, 100000 },
}

local function ObservedValue(value)
	if value == true then
		return "live"
	elseif value == false then
		return "unknown"
	elseif type(value) == "string" and ns.dataContract.observed[value] then
		return value
	end
	return nil
end

function ns.NoteMilestoneFirst(kind, data)
	if not kind then
		return
	end
	local store = Store()
	if not store or store.firsts[kind] then
		return
	end
	data = data or {}
	data.at = data.at or Now()
	if not data.zone then
		data.zone = (ZoneInfo())
	end
	data.observed = ObservedValue(data.observed) or "live"
	data.how = data.how or "milestone_first"
	data.evidence = data.evidence or "unknown"
	data.kind = data.kind or kind
	data.updatedAt = data.at
	store.firsts[kind] = data
	if ns.NoteEvent then
		local event = ns.NoteEvent("first", {
			at = data.at, zone = data.zone, zoneKind = data.zoneKind,
			how = data.how, evidence = data.evidence, observed = data.observed,
			data = data,
		})
		if event then
			data.event = event.id
		end
	end
end

function ns.NoteFutureFirst(kind, data)
	if not kind then
		return
	end
	local store = Store()
	if not store or store.future[kind] then
		return
	end
	data = data or {}
	local zone, zoneKind = ZoneInfo()
	local at = data.at or Now()
	local record = {
		at = at,
		zone = data.zone or zone,
		zoneKind = data.zoneKind or zoneKind,
		observed = ObservedValue(data.observed) or "live",
		how = data.how or kind,
		evidence = data.evidence or "unknown",
		name = data.name,
		amount = data.amount,
		guid = data.guid,
		detail = data.detail,
		updatedAt = at,
	}
	store.future[kind] = record
	ns.Trace("future milestone stored: "..kind..(record.name and (" - "..tostring(record.name)) or ""))
end

function ns.NoteMilestoneThreshold(group, key, value, observed, evidence)
	local store = Store()
	if not store or not group or key == nil or type(value) ~= "number" then
		return
	end
	local bucket = store.thresholds[group]
	if type(bucket) ~= "table" then
		return
	end
	local thresholds = ns.milestoneThresholds[group]
	if not thresholds then
		return
	end
	local entry = bucket[tostring(key)]
	if type(entry) ~= "table" then
		entry = {}
		bucket[tostring(key)] = entry
	end
	for index = 1, #thresholds do
		local threshold = thresholds[index]
		if value >= threshold and not entry[threshold] then
			local zone = ZoneInfo()
			local at = Now()
			local crossing = {
				at = at, value = value, zone = zone,
				observed = observed and "login" or "live",
				how = "milestone_threshold",
				evidence = evidence or "unknown",
				updatedAt = at,
			}
			entry[threshold] = crossing
			if ns.NoteEvent then
				local event = ns.NoteEvent("threshold", {
					at = at, zone = zone, how = crossing.how,
					evidence = crossing.evidence, observed = crossing.observed,
					data = {
						group = group, key = key, threshold = threshold, value = value,
					},
				})
				if event then
					crossing.event = event.id
				end
			end
		end
	end
end

-- Writes the general counts the character has already reached. These are
-- genuine current counters; the date is the first time Tally observed them,
-- so the row is marked as seen rather than pretending to know the old date.
function ns.SeedCountMilestones(char)
	char = char or ns.GetChar()
	if not char then
		return
	end
	if (char.quests or 0) > 0 then
		ns.NoteMilestoneFirst("quest", { name = "First quest completed", observed = "login" })
	end
	for index = 1, #(((char.professions or {}).skills) or {}) do
		local skill = char.professions.skills[index]
		ns.NoteProfessionSkill(skill.name, skill.rank, true)
	end
	ns.NoteMilestoneThreshold("quests", "quests", tonumber(char.quests) or 0, true)
	ns.NoteMilestoneThreshold("gold", "balance", tonumber(char.gold and char.gold.balance) or 0, true)
	ns.NoteGoldSpentMilestone(char, true)
	ns.NoteKillMilestone((char.combat and char.combat.kills) or 0, true)
	ns.NoteDeathMilestone((char.combat and char.combat.deaths) or 0, true)
	ns.NoteBossMilestone((char.explore and char.explore.bosses) or 0, true)
	ns.NoteLootMilestone((char.loot and char.loot.items) or 0, true)
	ns.NoteDungeonMilestone(char, true)
	ns.NoteCraftMilestone(char, true)
	ns.NoteDistanceMilestone((char.explore and char.explore.distance) or 0, true)
	local recipes = (char.professions and char.professions.recipes) or {}
	for profession, book in pairs(recipes) do
		local list = type(book) == "table" and book.list or nil
		if list then
			ns.NoteMilestoneThreshold("recipes", profession, #list, true)
		end
	end
end

function ns.NoteGoldMilestone(balance, at)
	ns.NoteMilestoneThreshold("gold", "balance", tonumber(balance), nil, "money_poll")
end

function ns.NoteQuestMilestone(count)
	ns.NoteMilestoneThreshold("quests", "quests", tonumber(count), nil, "quest_event")
end

function ns.NoteRecipeMilestone(profession, count)
	if not profession then
		return
	end
	ns.NoteMilestoneThreshold("recipes", profession, tonumber(count), nil, "trade_skill_window")
end

function ns.NoteKillMilestone(count, observed)
	ns.NoteMilestoneThreshold("kills", "kills", tonumber(count), observed, "unit_died_event")
end

function ns.NoteDeathMilestone(count, observed)
	ns.NoteMilestoneThreshold("deaths", "deaths", tonumber(count), observed, "unit_died_event")
end

function ns.NoteBossMilestone(count, observed)
	ns.NoteMilestoneThreshold("bosses", "bosses", tonumber(count), observed, "encounter_end")
end

function ns.NoteLootMilestone(count, observed)
	ns.NoteMilestoneThreshold("loot", "loot", tonumber(count), observed, "chat_loot")
end

function ns.NoteDungeonMilestone(char, observed)
	local char = char or ns.GetChar()
	local runs = 0
	for _, dungeon in pairs((char and char.explore and char.explore.dungeons) or {}) do
		runs = runs + (dungeon.entered or 0)
	end
	ns.NoteMilestoneThreshold("dungeons", "dungeons", runs, observed, "instance_info")
end

function ns.NoteCraftMilestone(char, observed)
	local char = char or ns.GetChar()
	local total = 0
	for _, count in pairs((char and char.professions and char.professions.crafts) or {}) do
		total = total + (count or 0)
	end
	ns.NoteMilestoneThreshold("crafted", "crafted", total, observed, "craft_event")
end

function ns.NoteDistanceMilestone(yards, observed)
	local km = (tonumber(yards) or 0) * 0.9144 / 1000
	ns.NoteMilestoneThreshold("distance", "distance", math.floor(km), observed, "unit_position")
end

function ns.NoteGoldSpentMilestone(char, observed)
	local char = char or ns.GetChar()
	local total = 0
	for _, amount in pairs((char and char.gold and char.gold.expenses) or {}) do
		if type(amount) == "number" then
			total = total + amount
		end
	end
	ns.NoteMilestoneThreshold("goldSpent", "gold", total, observed, "money_window")
end

function ns.NoteProfessionFirst(name, observed, rank, maxRank)
	if name then
		ns.NoteMilestoneFirst("profession", {
			name = name, rank = rank, maxRank = maxRank, observed = observed,
		})
	end
end

function ns.NoteEliteKill(name, classification, zone)
	if not name or not classification then
		return
	end
	if classification == "elite" or classification == "rareelite" or classification == "worldboss" then
		ns.NoteMilestoneFirst("eliteKill", {
			name = name, classification = classification, zone = zone or (ZoneInfo()),
		})
	end
	if classification == "rare" or classification == "rareelite" then
		ns.NoteMilestoneFirst("rareKill", {
			name = name, classification = classification, zone = zone or (ZoneInfo()),
		})
	end
end

function ns.NoteFirstQuest(zone, observed)
	ns.NoteMilestoneFirst("quest", { name = "First quest completed", zone = zone or (ZoneInfo()), observed = observed })
end

function ns.NoteFirstCraft(name, itemID)
	if name then
		ns.NoteMilestoneFirst("crafted", { name = name, itemID = itemID })
	end
end

function ns.NoteProfessionSkill(profession, rank, observed)
	if profession and type(rank) == "number" then
		ns.NoteMilestoneThreshold("professionSkills", profession, rank, observed, "chat_skill")
	end
end

function ns.NoteFirstWeapon(name, itemID, weaponType, quality, link, observed)
	if name and weaponType then
		local store = Store()
		if not store then
			return
		end
		if type(store.firstWeapon) ~= "table" then
			store.firstWeapon = {}
		end
		if not store.firstWeapon[weaponType] then
			local at = Now()
			store.firstWeapon[weaponType] = {
				name = name, itemID = itemID, type = weaponType, quality = quality,
				link = link, at = at, zone = (ZoneInfo()),
				how = "milestone_first", evidence = "inventory_scan",
				observed = observed or "live", updatedAt = at,
			}
		end
	end
end


ZoneInfo = function()
	local zone = ns.CurrentZone and ns.CurrentZone() or nil
	local kind = "world"
	if type(GetInstanceInfo) == "function" then
		local ok, name, instanceType = pcall(GetInstanceInfo)
		if ok and type(name) == "string" and name ~= "" then
			zone = zone or name
			if instanceType == "party" then
				kind = "dungeon"
			elseif instanceType == "raid" then
				kind = "raid"
			end
		end
	end
	return zone or "Unknown", kind
end

ItemAt = function(slot)
	if type(GetInventoryItemID) ~= "function" then
		return nil
	end
	local ok, itemID = pcall(GetInventoryItemID, "player", slot)
	if not ok or type(itemID) ~= "number" or itemID <= 0 then
		return nil
	end
	local name, link, quality = ns.ItemInfo(itemID)
	local itemType, itemSubType
	local getter = type(C_Item) == "table" and C_Item.GetItemInfo or GetItemInfo
	if type(getter) == "function" then
		local okInfo, foundName, foundLink, foundQuality, _, _, foundType, foundSubType = pcall(getter, itemID)
		if okInfo then
			name = name or foundName
			link = link or foundLink
			quality = quality or foundQuality
			itemType = foundType
			itemSubType = foundSubType
		end
	end
	if not name or not quality then
		if type(GetInventoryItemLink) == "function" then
			local okLink, itemLink = pcall(GetInventoryItemLink, "player", slot)
			if okLink and type(itemLink) == "string" then
				local foundName, foundLink, foundQuality
				if ns.ItemInfoByName then
					foundName, foundLink, foundQuality = ns.ItemInfoByName(itemLink)
				end
				name = name or foundName
				link = link or foundLink
				quality = quality or foundQuality
			end
		end
	end
	if not name then
		name = "#"..itemID
	end
	return {
		itemID = itemID, name = name, link = link, quality = quality, slot = slot,
		itemType = itemType, itemSubType = itemSubType,
	}
end

local FULL_SET_SLOTS = { 1, 3, 5, 6, 7, 8, 9, 10, 15, 16, 17 }

local function CheckFullSet(store, seenAt)
	for quality = 2, 5 do
		local key = tostring(quality)
		if not store.fullSets[key] then
			local items, complete = {}, true
			for index = 1, #FULL_SET_SLOTS do
				local slot = FULL_SET_SLOTS[index]
				local item = ItemAt(slot)
				if not item or type(item.quality) ~= "number" or item.quality < quality then
					complete = false
					break
				end
				items[#items + 1] = {
					slot = slot, itemID = item.itemID, item = item.name, link = item.link,
					quality = item.quality,
				}
			end
			if complete then
				local at = Now()
				store.fullSets[key] = {
					quality = quality, at = at, zone = (ZoneInfo()),
					items = items,
					how = "milestone_first", evidence = "inventory_scan",
					observed = seenAt == "login" and "login" or "live",
					updatedAt = at,
				}
			end
		end
	end
end

local function RecordEquip(slot, item, seenAt)
	if not item or type(item.quality) ~= "number" then
		return
	end
	local store = Store()
	if not store then
		return
	end
	local zone = ZoneInfo()
	local at = Now()
	local quality = item.quality
	local observed = seenAt == "login" and "login" or "live"
	local how = seenAt == "login" and "item_seen" or "item_equipped"
	if (slot == 1 or slot == 3) and not store.firstSlot[slot] then
		store.firstSlot[slot] = {
			itemID = item.itemID, item = item.name, link = item.link, quality = quality,
			slot = slot, at = at, zone = zone, observed = observed,
			how = how, evidence = "inventory_scan", updatedAt = at,
		}
	end
	if quality < 2 then
		return
	end
	local bySlot = store.firstEquip[tostring(quality)]
	if type(bySlot) ~= "table" then
		bySlot = {}
		store.firstEquip[tostring(quality)] = bySlot
	end
	if not bySlot[slot] then
		bySlot[slot] = {
			itemID = item.itemID, item = item.name, link = item.link, quality = quality,
			slot = slot, at = at, zone = zone, observed = observed,
			how = how, evidence = "inventory_scan", updatedAt = at,
		}
	end
	local subType = item.itemSubType
	if subType and (item.itemType == "Weapon" or subType == "Shields" or subType == "Shield") then
		ns.NoteFirstWeapon(item.name, item.itemID, subType, quality, item.link, observed)
	end
	CheckFullSet(store, seenAt)
end

local function ScanEquipment(seenAt)
	for slot = 1, 19 do
		RecordEquip(slot, ItemAt(slot), seenAt)
	end
end

-- Last experience source, used when a level up arrives. The chat line is the
-- closest thing the client gives to "what gave the last XP"; quest and kill
-- timestamps are fallbacks.
local lastXp
local lastQuestAt, lastKillAt = 0, 0

local function Plain(text)
	return ns.StripColors and ns.StripColors(text or "") or (text or "")
end

local function NoteXp(text)
	local plain = Plain(text)
	local lower = string.lower(plain)
	local kind = "unknown"
	if string.find(lower, "discover", 1, true) or string.find(lower, "explor", 1, true) then
		kind = "exploration"
	elseif string.find(lower, "quest", 1, true) then
		kind = "quest"
	elseif string.find(lower, "battleground", 1, true) or string.find(lower, "arena", 1, true)
		or string.find(lower, "honor", 1, true) or string.find(lower, "pvp", 1, true) then
		kind = "pvp"
	elseif string.find(lower, "kill", 1, true) or string.find(lower, "slain", 1, true) then
		kind = "mob kill"
	end
	lastXp = { at = Now(), kind = kind, text = plain }
end

local function LastXpSource()
	local now = Now()
	if lastXp and now - lastXp.at <= 20 and lastXp.kind ~= "unknown" then
		return lastXp.kind, lastXp.text
	end
	local turnInAt = math.max(lastQuestAt or 0, ns.lastQuestTurnInAt or 0)
	local killAt = math.max(lastKillAt or 0, ns.lastKillAt or 0)
	local discoveryAt = ns.lastDiscoveryAt or 0
	-- The most recent cause wins. A generic "you gain experience" line cannot
	-- tell a quest from a kill or a first discovery, so the latest real cause
	-- within 15 seconds is the one recorded.
	if turnInAt > 0 and now - turnInAt <= 15
		and turnInAt >= killAt and turnInAt >= discoveryAt then
		return "quest", lastXp and lastXp.text or nil
	end
	if discoveryAt > 0 and now - discoveryAt <= 15 and discoveryAt >= killAt then
		return "exploration", lastXp and lastXp.text or nil
	end
	if killAt > 0 and now - killAt <= 15 then
		return "mob kill", lastXp and lastXp.text or nil
	end
	return "unknown", lastXp and lastXp.text or nil
end

-- Core.lua asks this when a level-up arrives; the zone goes onto the same
-- level-history entry Playtime already reads. The cause of the XP is no longer
-- recorded: the client often does not say, and a guessed cause is worse than
-- none.
function ns.MilestoneContext()
	local zone, kind = ZoneInfo()
	return zone, kind
end

local function RecordRiding(value)
	local store = Store()
	if not store or not value then
		return
	end
	local key = tostring(value)
	if store.riding[key] then
		return
	end
	local zone = ZoneInfo()
	local at = Now()
	store.riding[key] = {
		value = value, at = at, zone = zone,
		how = "riding_skill", evidence = "chat_skill",
		observed = "live", updatedAt = at,
	}
end

local function RecordMount(spellID)
	local store = Store()
	if not store or store.firstMount then
		return
	end
	local name
	if type(C_Spell) == "table" and type(C_Spell.GetSpellName) == "function" then
		local ok, value = pcall(C_Spell.GetSpellName, spellID)
		if ok then
			name = value
		end
	end
	if not name and type(GetSpellInfo) == "function" then
		local ok, value = pcall(GetSpellInfo, spellID)
		if ok then
			name = value
		end
	end
	local zone = ZoneInfo()
	local at = Now()
	store.firstMount = {
		at = at, zone = zone, name = name or "a mount", spellID = spellID,
		how = "mount_summoned", evidence = "spell_cast",
		observed = "live", updatedAt = at,
	}
end

local function RecordGroup(observed)
	local store = Store()
	if not store then
		return
	end
	local count = type(GetNumGroupMembers) == "function" and GetNumGroupMembers() or 0
	if count <= 0 then
		return
	end
	local prefix = type(IsInRaid) == "function" and IsInRaid() and "raid" or "party"
	local limit = prefix == "raid" and 40 or 4
	for index = 1, limit do
		local unit = prefix..index
		if UnitExists and UnitExists(unit) and not UnitIsUnit(unit, "player") then
			local name = UnitName(unit)
			if name then
				local _, classFile = UnitClass(unit)
				local zone = ZoneInfo()
				local at = Now()
				local state = observed or "live"
				if not store.firstGroup then
					store.firstGroup = {
						at = at, zone = zone, name = name, classFile = classFile,
						how = "group_joined", evidence = "group_event",
						observed = state, updatedAt = at,
					}
				end
				if classFile and not store.firstGroupByClass[classFile] then
					store.firstGroupByClass[classFile] = {
						at = at, zone = zone, name = name, classFile = classFile,
						level = UnitLevel and UnitLevel(unit) or nil,
						how = "group_joined", evidence = "group_event",
						observed = state, updatedAt = at,
					}
				end
			end
		end
	end
end

local function RecordGuild()
	if not (GetGuildInfo and UnitExists and UnitExists("player")) then
		return
	end
	local ok, guild = pcall(GetGuildInfo, "player")
	if ok and type(guild) == "string" and guild ~= "" then
		ns.NoteMilestoneFirst("guild", {
			name = guild, observed = "login",
			how = "guild_joined", evidence = "login_snapshot",
		})
	end
end

function ns.NoteFirstBoss(name, zone, kind)
	if name then
		ns.NoteMilestoneFirst("boss", { name = name, zone = zone })
		if kind == "raid" then
			ns.NoteMilestoneFirst("raidBoss", { name = name, zone = zone })
		end
		local grouped = (type(GetNumGroupMembers) == "function" and GetNumGroupMembers() > 0)
			or (type(IsInGroup) == "function" and IsInGroup())
		if not grouped then
			ns.NoteMilestoneFirst("soloBoss", { name = name, zone = zone })
		end
	end
end

local function OnPlayerLogin()
	-- Existing equipment is a baseline: it is recorded as "seen at login",
	-- never as a claim that Tally saw the item being equipped.
	local char = ns.GetChar()
	if char and type(char.milestones) ~= "table" then
		Store()
	end
	if ns.After then
		ns.After(2, function()
			ScanEquipment("login")
			RecordGroup("login")
			RecordGuild()
			if ns.SeedCountMilestones then
				ns.SeedCountMilestones()
			end
		end)
	else
		ScanEquipment("login")
		RecordGroup("login")
		RecordGuild()
		if ns.SeedCountMilestones then
			ns.SeedCountMilestones()
		end
	end
end

ns.On("PLAYER_LOGIN", OnPlayerLogin, "Milestones")
ns.On("PLAYER_ENTERING_WORLD", function()
	if ns.After then
		ns.After(1, function()
			ScanEquipment("login")
			RecordGroup("login")
			RecordGuild()
			if ns.SeedCountMilestones then
				ns.SeedCountMilestones()
			end
		end)
	end
end, "Milestones")
ns.On("PLAYER_EQUIPMENT_CHANGED", function(_, slot, hasCurrent)
	if hasCurrent == false then
		return
	end
	if ns.After then
		ns.After(0.25, function()
			local item = ItemAt(slot)
			RecordEquip(slot, item)
		end)
	else
		RecordEquip(slot, ItemAt(slot))
	end
end, "Milestones")
ns.On("CHAT_MSG_COMBAT_XP_GAIN", function(_, text)
	NoteXp(text)
end, "Milestones")
ns.On("QUEST_TURNED_IN", function()
	lastQuestAt = Now()
end, "Milestones")
ns.On("PARTY_KILL", function()
	lastKillAt = Now()
end, "Milestones")
ns.On("CHAT_MSG_SKILL", function(_, text)
	local plain = string.lower(Plain(text))
	local value = tonumber(string.match(plain, "riding.-(%d+)"))
	if value and string.find(plain, "increas", 1, true) then
		RecordRiding(value)
	end
end, "Milestones")
-- The four detector fields Stage 6 may use later. They are stored now, with
-- the same when/where/how/observed fields as the visible firsts, but no UI
-- reads char.milestones.future. Nothing is guessed: a message that cannot be
-- parsed stores nothing.
ns.On("CHAT_MSG_COMBAT_FACTION_CHANGE", function(_, text)
	local plain = Plain(text or "")
	local amount, faction = string.match(plain, "You gain ([%d,]+) reputation with (.+)")
	if not amount then
		faction, amount = string.match(plain, "Your reputation with (.+) has increased by ([%d,]+)")
	end
	if not amount or not faction then
		return
	end
	amount = tonumber((string.gsub(amount, ",", "")))
	if not amount then
		return
	end
	faction = string.gsub(faction, "%.%s*$", "")
	faction = string.gsub(faction, "^%s*(.-)%s*$", "%1")
	if faction == "" then
		return
	end
	ns.NoteFutureFirst("reputation", {
		name = faction, amount = amount,
		observed = "live", how = "reputation_gain", evidence = "chat_faction",
	})
end, "Milestones")
ns.On("UNIT_PET", function(_, unit)
	if unit ~= "player" then
		return
	end
	local name = UnitName and UnitName("pet") or nil
	if not name or name == "" then
		return
	end
	ns.NoteFutureFirst("pet", {
		name = name,
		guid = UnitGUID and UnitGUID("pet") or nil,
		observed = "live", how = "unit_pet", evidence = "unit_pet",
	})
end, "Milestones")
ns.On("LOOT_OPENED", function()
	if type(IsFishing) ~= "function" then
		return
	end
	local ok, fishing = pcall(IsFishing)
	if ok and fishing then
		ns.NoteFutureFirst("fishing", {
			observed = "live", how = "fishing_catch", evidence = "loot_window",
			detail = "loot window opened while fishing",
		})
	end
end, "Milestones")
ns.On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, castGUID, spellID)
	if unit ~= "player" or type(spellID) ~= "number" then
		return
	end
	if type(IsMounted) == "function" and IsMounted() then
		return
	end
	if not ns.After then
		return
	end
	ns.After(0.3, function()
		if type(IsMounted) == "function" and IsMounted() and not (UnitOnTaxi and UnitOnTaxi("player")) then
			RecordMount(spellID)
		end
	end)
end, "Milestones")
ns.On("GROUP_ROSTER_UPDATE", RecordGroup, "Milestones")

ns.milestoneQualities = { 2, 3, 4, 5, 6, 7 }
ns.milestoneQualityNames = { [2] = "green", [3] = "rare", [4] = "epic", [5] = "legendary", [6] = "artifact", [7] = "heirloom" }
ns.milestoneSlotNames = {
	[1] = "Head", [2] = "Neck", [3] = "Shoulder", [4] = "Shirt", [5] = "Chest",
	[6] = "Waist", [7] = "Legs", [8] = "Feet", [9] = "Wrist", [10] = "Hands",
	[11] = "Finger 1", [12] = "Finger 2", [13] = "Trinket 1", [14] = "Trinket 2",
	[15] = "Back", [16] = "Main hand", [17] = "Off hand", [18] = "Ranged", [19] = "Tabard",
}
