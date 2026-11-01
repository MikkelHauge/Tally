-- Tally - the Character tab's Milestones sub-view: one-time events and general
-- counts for the character the window describes.
local addonName, ns = ...

local ACCENT, ClassColorCode, QualityCode, CreateListCard, AddCardTitleNote,
	AddCardScrollbar, MakeCardScrollable, FillScrollingLines, ShowCardText,
	CreateCornerButton, SetCornerLabel, RowAtCursor, RowHoverTick, DisplayChar, ROW_DETAIL_DIM, CATEGORY_HEAD_COLOR =
	ns.ACCENT, ns.ClassColorCode, ns.QualityCode, ns.CreateListCard, ns.AddCardTitleNote,
	ns.AddCardScrollbar, ns.MakeCardScrollable, ns.FillScrollingLines, ns.ShowCardText,
	ns.CreateCornerButton, ns.SetCornerLabel, ns.RowAtCursor, ns.RowHoverTick, ns.DisplayChar, ns.ROW_DETAIL_DIM, ns.CATEGORY_HEAD_COLOR

local milestoneWidgets = {
	categorySort = true,
	collapsed = {},
	sortMode = "low",

	showHidden = false,
}

local SORT_MODES = { "low", "high" }


local function NextMode(list, current)
	for index = 1, #list do
		if list[index] == current then
			return list[index % #list + 1]
		end
	end
	return list[1]
end

local function SortLabel(mode)
	if mode == "high" then
		return "order: high-low"
	end
	return "order: low-high"
end



local function ZoneText(zone, kind)
	if not zone or zone == "" then
		return ""
	end
	if kind == "dungeon" then
		return zone.." (dungeon)"
	elseif kind == "raid" then
		return zone.." (raid)"
	end
	return zone
end

local function ItemName(record)
	local code = QualityCode(record.quality or 1)
	return code..(record.item or "?").."|r"
end

local function ObservedLabel(value)
	if value == "login" then
		return "seen at login; the real event is earlier"
	elseif value == "migration" then
		return "from an older record; the real date is unknown"
	elseif value == "estimate" then
		return "estimated"
	elseif value == "unknown" or value == nil then
		return "not recorded"
	end
	return "seen live"
end

local function ClassDisplay(classFile)
	if not classFile then
		return "?"
	end
	local names = LOCALIZED_CLASS_NAMES_MALE
	local name = names and names[classFile] or classFile
	local color = ClassColorCode and ClassColorCode(classFile) or nil
	return (color or "")..name..(color and "|r" or "")
end

local HOW_TEXT = {
	created = "character created", login = "logged in", logout = "logged out",
	reload = "UI reload", migration = "older record", manual = "entered by hand",
	unknown = "not recorded",
	level_up = "level-up", quest = "quest", quest_reward = "quest reward",
	exploration = "exploration", discovery = "discovery",
	instance_entry = "entered an instance", instance_exit = "left an instance",
	death = "death", resurrect = "resurrected",
	kill = "kill", elite_kill = "elite kill", rare_kill = "rare kill",
	world_boss_kill = "world boss kill", dungeon_boss_kill = "dungeon boss kill",
	raid_boss_kill = "raid boss kill", solo_kill = "solo kill",
	group_kill = "group kill", pet_kill = "pet kill", pvp_kill = "PvP kill",
	loot = "loot", corpse_loot = "corpse loot", chest_loot = "chest loot",
	container_loot = "container loot", fishing = "fishing catch",
	item_received = "item received", item_crafted = "item crafted",
	item_equipped = "equipped", item_seen = "seen at login",
	profession_learned = "profession learned", profession_dropped = "profession dropped",
	profession_skill = "skill-up", recipe_learned = "recipe learned",
	craft = "craft", enchant = "enchant", disenchant = "disenchant",
	vendor_sale = "vendor sale", vendor_purchase = "vendor purchase",
	repair = "repair", trainer = "trainer", mail_send = "mail sent",
	mail_receive = "mail received", trade = "trade", bank = "bank",
	auction_post = "auction posted", auction_sale = "auction sale",
	auction_purchase = "auction purchase", auction_deposit = "auction deposit",
	auction_cut = "auction cut", taxi = "flight",
	group_joined = "joined a group", party_joined = "joined a party",
	raid_joined = "joined a raid", guild_joined = "joined a guild",
	mount_summoned = "mount summoned", mount_learned = "mount learned",
	riding_skill = "riding skill", zone_entered = "entered a zone",
	zone_left = "left a zone", flight_started = "flight started",
	flight_ended = "flight ended", battleground_entered = "entered a battleground",
	arena_entered = "entered an arena", pet_summoned = "pet summoned",
	tame = "tamed a pet",
	milestone_first = "first time seen", milestone_threshold = "count threshold",
	record_set = "record set",
}

local EVIDENCE_TEXT = {
	chat_xp = "experience line", chat_loot = "loot line", chat_money = "money line",
	chat_skill = "skill message", chat_system = "system message",
	chat_faction = "reputation message", chat_combat = "combat message",
	party_kill_event = "kill event", unit_died_event = "death event",
	nameplate_health = "nameplate", nameplate_classification = "nameplate",
	threat_list = "threat list", pet_target = "pet target",
	instance_xp_line = "instance XP line", instance_loot_window = "instance loot",
	encounter_end = "encounter end", zone_event = "zone change",
	instance_info = "instance info", quest_event = "quest event",
	group_event = "group change", guild_event = "guild event",
	level_event = "level-up event", unit_level = "unit level",
	unit_class = "unit class", unit_race = "unit race", unit_faction = "unit faction",
	unit_position = "position", unit_on_taxi = "taxi state", is_mounted = "mount state",
	money_poll = "money reading", money_window = "money window",
	spell_cooldown = "spell cooldown", spell_cast = "spell cast",
	spell_learned = "spell learned", aura_scan = "aura scan",
	spell_tooltip = "spell tooltip", item_link = "item link",
	item_cache = "item cache", inventory_scan = "inventory scan",
	loot_message = "loot message", loot_window = "loot window",
	bag_scan = "bag scan", merchant_quote = "merchant quote",
	auction_invoice = "auction invoice", mail_invoice = "mail invoice",
	trade_window = "trade window", trainer_window = "trainer window",
	craft_event = "craft event", trade_skill_window = "profession window",
	login_snapshot = "login snapshot", api_baseline = "baseline reading",
	migration = "older record", estimate = "estimate",
	unknown = "not recorded",
}

local function PrettyValue(value)
	local text = tostring(value or "unknown"):gsub("_", " ")
	return (text:gsub("^%l", string.upper))
end

local function HowText(value)
	return HOW_TEXT[value] or PrettyValue(value)
end

local function EvidenceText(value)
	return EVIDENCE_TEXT[value] or PrettyValue(value)
end

local function ContextLines(record, extra)
	local lines = {}
	if record.at then
		lines[#lines + 1] = { text = "When: "..ns.FormatDateTime(record.at) }
	end
	local where = ZoneText(record.zone, record.zoneKind)
	if where ~= "" then
		lines[#lines + 1] = { text = "Where: "..where }
	end
	if record.how then
		lines[#lines + 1] = {
			text = "How: "..HowText(record.how).." - "..EvidenceText(record.evidence),
		}
	end
	if record.observed then
		lines[#lines + 1] = {
			text = "Observed: "..ObservedLabel(record.observed),
			color = ROW_DETAIL_DIM,
		}
	end
	if extra then
		for index = 1, #extra do
			lines[#lines + 1] = extra[index]
		end
	end
	return lines
end

local function NoticeTip(title, record, extra)
	return {
		kind = "note",
		title = title,
		lines = ContextLines(record, extra),
		key = "milestone|"..title.."|"..tostring(record.at).."|"..tostring(record.observed or ""),
	}
end

local function ItemTip(record, extra)
	return {
		kind = "item",
		name = record.item or record.name,
		id = record.itemID,
		extra = ContextLines(record, extra),
	}
end

local function AddItem(items, category, label, at, tip, hidden, observed)
	if at == nil then
		return
	end
	items[#items + 1] = {
		category = category, label = label, at = at, tip = tip, hidden = hidden,
		observed = observed,
	}
end

local function LevelItems(items, char)
	if char.firstLevel and char.firstLevel > 1 then
		local firstSeen = char.firstSeen
		local text = "Starting level "..char.firstLevel
		if firstSeen and firstSeen.observed == "live" and firstSeen.zone then
			text = text.." - "..firstSeen.zone
		end
		local record = firstSeen or { at = char.created, observed = "migration" }
		AddItem(items, "Levels", text, record.at or char.created,
			NoticeTip(text, record), nil, record.observed)
	end
	local history = (char.levels and char.levels.history) or {}
	for index = 1, #history do
		local entry = history[index]
		if entry.at and entry.level then
			local parts = { "Level "..entry.level }
			local zone = ZoneText(entry.zone, entry.zoneKind)
			if zone ~= "" then
				parts[#parts + 1] = zone
			end
			local label = table.concat(parts, " - ")
			local extra = {
				{ text = entry.startedAt and ("Started: "..ns.FormatDateTime(entry.startedAt)) or "Started: not recorded" },
				{ text = entry.endedAt and ("Finished: "..ns.FormatDateTime(entry.endedAt)) or "Finished: still this level" },
				{ text = entry.seconds and ("Measured: "..ns.FormatDuration(entry.seconds)) or "Measured: not recorded" },
			}
			if not entry.zone or entry.zone == "" then
				extra[#extra + 1] = {
					text = "Where: not recorded",
					color = ROW_DETAIL_DIM,
				}
			end
			AddItem(items, "Levels", label, entry.at, NoticeTip(label, entry, extra), nil, entry.observed)
		end
	end
end

local function CombatItems(items, milestones)
	local firsts = milestones.firsts or {}
	if firsts.eliteKill then
		local label = "First elite kill - "..(firsts.eliteKill.name or "?")
		AddItem(items, "General", label, firsts.eliteKill.at, NoticeTip(label, firsts.eliteKill), nil, firsts.eliteKill.observed)
	end
	if firsts.rareKill then
		local label = "First rare kill - "..(firsts.rareKill.name or "?")
		AddItem(items, "General", label, firsts.rareKill.at, NoticeTip(label, firsts.rareKill), nil, firsts.rareKill.observed)
	end
	if firsts.boss then
		local label = "First boss - "..(firsts.boss.name or "?")
		AddItem(items, "General", label, firsts.boss.at, NoticeTip(label, firsts.boss), nil, firsts.boss.observed)
	end
	if firsts.soloBoss then
		local label = "First solo boss - "..(firsts.soloBoss.name or "?")
		AddItem(items, "General", label, firsts.soloBoss.at, NoticeTip(label, firsts.soloBoss), nil, firsts.soloBoss.observed)
	end
	if firsts.raidBoss then
		local label = "First raid boss - "..(firsts.raidBoss.name or "?")
		AddItem(items, "General", label, firsts.raidBoss.at, NoticeTip(label, firsts.raidBoss), nil, firsts.raidBoss.observed)
	end
end

local function ExplorationItems(items, char, milestones)
	local firsts = milestones.firsts or {}
	local explore = char.explore or {}
	local firstZone, firstDungeon
	for name, entry in pairs(explore.zones or {}) do
		if entry.first and (not firstZone or entry.first < firstZone.at) then
			firstZone = { name = name, at = entry.first }
		end
	end
	for name, entry in pairs(explore.dungeons or {}) do
		if entry.first and (not firstDungeon or entry.first < firstDungeon.at) then
			firstDungeon = { name = name, at = entry.first }
		end
	end
	if firstZone then
		local label = "First zone - "..firstZone.name
		AddItem(items, "General", label, firstZone.at,
			NoticeTip(label, { at = firstZone.at, zone = firstZone.name, how = "zone_entered", evidence = "zone_event", observed = "unknown" }))
	end
	if firstDungeon then
		local label = "First dungeon - "..firstDungeon.name
		AddItem(items, "General", label, firstDungeon.at,
			NoticeTip(label, { at = firstDungeon.at, zone = firstDungeon.name, zoneKind = "dungeon", how = "instance_entry", evidence = "instance_info", observed = "unknown" }))
	end
	if milestones.firstMount then
		local label = "First mount - "..(milestones.firstMount.name or "a mount")
		AddItem(items, "General", label, milestones.firstMount.at,
			NoticeTip(label, milestones.firstMount), nil, milestones.firstMount.observed)
	end
	if milestones.firstGroup then
		local label = "First group - "..(milestones.firstGroup.name or "?")
		AddItem(items, "General", label, milestones.firstGroup.at,
			NoticeTip(label, milestones.firstGroup), nil, milestones.firstGroup.observed)
	end
	if firsts.guild then
		local label = "First guild - "..(firsts.guild.name or "?")
		AddItem(items, "General", label, firsts.guild.at,
			NoticeTip(label, firsts.guild), nil, firsts.guild.observed)
	end
	if firsts.quest then
		local label = "First quest completed"
		AddItem(items, "General", label, firsts.quest.at,
			NoticeTip(label, firsts.quest), nil, firsts.quest.observed)
	end
	local groupClasses = {}
	for classFile in pairs(milestones.firstGroupByClass or {}) do
		groupClasses[#groupClasses + 1] = classFile
	end
	table.sort(groupClasses)
	for index = 1, #groupClasses do
		local record = milestones.firstGroupByClass[groupClasses[index]]
		local label = "First group with "..ClassDisplay(record.classFile).." - "..(record.name or "?")
			..(record.level and (" - level "..record.level) or "")
		AddItem(items, "General", label, record.at, NoticeTip(label, record), nil, record.observed)
	end
end

local function EconomyItems(items, char, milestones)
	local firsts = milestones.firsts or {}
	-- One row per profession Tally has seen, with the rank it was first seen
	-- at: "Engineering 1/75" for one learned while Tally was running, or
	-- "Engineering 300/300" for one already trained when Tally met the
	-- character. The profession name is part of the record and the label.
	local learned = (char.professions and char.professions.learned) or {}
	local learnedNames = {}
	for profession, record in pairs(learned) do
		learnedNames[profession] = true
		local label = profession.." "..tostring(record.rank or 0).."/"..tostring(record.maxRank or 0)
		local extra = {}
		if record.observed == "login" or record.observed == "migration" then
			extra[#extra + 1] = {
				text = "First seen at this rank when Tally met the character; the exact learning date is not known.",
				color = ROW_DETAIL_DIM,
			}
		end
		AddItem(items, "General", label, record.at,
			NoticeTip(label, record, extra), nil, record.observed)
	end
	if firsts.profession and not learnedNames[firsts.profession.name] then
		local suffix = firsts.profession.rank
			and (" "..tostring(firsts.profession.rank).."/"..tostring(firsts.profession.maxRank or "?"))
			or ""
		local label = "First profession - "..(firsts.profession.name or "?")..suffix
		AddItem(items, "General", label, firsts.profession.at,
			NoticeTip(label, firsts.profession), nil, firsts.profession.observed)
	end
	if firsts.professionDropped then
		local label = "First profession dropped - "..(firsts.professionDropped.name or "?")
		AddItem(items, "General", label, firsts.professionDropped.at,
			NoticeTip(label, firsts.professionDropped), nil, firsts.professionDropped.observed)
	end
	for _, key in ipairs({ "epicCrafted", "craftedRare", "craftedUncommon", "crafted" }) do
		local record = firsts[key]
		if record then
			local prefix = key == "epicCrafted" and "First epic crafted"
				or key == "craftedRare" and "First rare crafted"
				or key == "craftedUncommon" and "First uncommon crafted"
				or "First item crafted"
			local label = prefix.." - "..(record.name or "?")
			AddItem(items, "General", label, record.at, ItemTip(record), nil, record.observed)
		end
	end
	if firsts.epicReceived then
		local label = "First epic received - "..(firsts.epicReceived.name or "?")
		AddItem(items, "General", label, firsts.epicReceived.at,
			ItemTip(firsts.epicReceived), nil, firsts.epicReceived.observed)
	end
	if firsts.auctionSale then
		local label = "First auction sale - "..(firsts.auctionSale.name or "?")
		AddItem(items, "General", label, firsts.auctionSale.at,
			NoticeTip(label, firsts.auctionSale), nil, firsts.auctionSale.observed)
	end
	if firsts.auctionBuy then
		local label = "First auction purchase - "..(firsts.auctionBuy.name or "?")
		AddItem(items, "General", label, firsts.auctionBuy.at,
			NoticeTip(label, firsts.auctionBuy), nil, firsts.auctionBuy.observed)
	end
end

local function CountItems(items, char, milestones, showHidden)
	local thresholds = milestones.thresholds or {}
	local function AddCount(category, metric, threshold, label, entry)
		if type(entry) == "table" then
			local extra = {}
			if entry.observed == "login" or entry.observed == "migration" then
				extra[#extra + 1] = {
					text = "Number is estimated: this count was already reached when Tally started; the date is when it was noticed, not when it was crossed.",
					color = ROW_DETAIL_DIM,
				}
			end
			if entry.at and char.created and entry.at > char.created then
				local days = (entry.at - char.created) / 86400
				if days >= 0.5 then
					extra[#extra + 1] = {
						text = string.format("Reached %.0f days after the record began", days),
						color = ROW_DETAIL_DIM,
					}
					if entry.value and entry.value > 0 then
						local average = entry.value / days
						if string.find(label, "Gold", 1, true) then
							extra[#extra + 1] = {
								text = "About "..ns.FormatMoneyBig(math.floor(average + 0.5)).." per day since then",
								color = ROW_DETAIL_DIM,
							}
						else
							extra[#extra + 1] = {
								text = "About "..ns.FormatNumber(math.floor(average + 0.5)).." per day since then",
								color = ROW_DETAIL_DIM,
							}
						end
					end
				end
			end
			local before = #items
			AddItem(items, category, label, entry.at, NoticeTip(label, entry, extra))
			-- A crossing with no date is not listed; do not decorate the item
			-- above it as though it had been added.
			if #items == before then
				return
			end
		elseif showHidden then
			AddItem(items, category, label, 0, nil, true)
		else
			return
		end
		items[#items].count = true
		items[#items].metric = metric
		items[#items].threshold = threshold
	end

	-- One category per domain, each with a fixed metric order. The sort
	-- button only walks the thresholds low-to-high or high-to-low inside that
	-- order; the label is never used for sorting.
	local function Emit(category, metric, group, key, labelFn)
		local bucket = thresholds[group] and thresholds[group][key] or {}
		local ladder = ns.milestoneThresholds[group] or {}
		for _, threshold in ipairs(ladder) do
			AddCount(category, metric, threshold, labelFn(threshold), bucket[threshold])
		end
	end

	Emit("Combat", 1, "kills", "kills", function(t) return "Enemies killed "..ns.FormatNumber(t) end)

	-- Deaths keep their own first-death zone on the one-death row.
	local deathsBucket = thresholds.deaths and thresholds.deaths.deaths or {}
	local firstDeath = char.combat and char.combat.deathLog and char.combat.deathLog[1] or nil
	if not firstDeath and char.combat and (char.combat.deaths or 0) == 1 then
		firstDeath = char.combat.lastDeath
	end
	for _, threshold in ipairs(ns.milestoneThresholds.deaths or {}) do
		local entry = deathsBucket[threshold]
		local label = "Deaths "..ns.FormatNumber(threshold)
		local record = entry
		if threshold == 1 then
			local zone = (firstDeath and firstDeath.zone) or (entry and entry.zone) or nil
			if zone and zone ~= "" then
				label = label.." - "..zone
			end
			if firstDeath and firstDeath.at then
				record = {
					at = firstDeath.at,
					zone = firstDeath.zone or (entry and entry.zone),
					zoneKind = firstDeath.zoneKind or (entry and entry.zoneKind),
					observed = firstDeath.observed or (entry and entry.observed) or "live",
					how = firstDeath.how or "unit_died_event",
					evidence = firstDeath.evidence or "unit_died_event",
					value = 1,
				}
			end
		end
		AddCount("Combat", 2, threshold, label, record)
	end

	Emit("Combat", 3, "dungeons", "dungeons", function(t) return "Dungeon runs "..ns.FormatNumber(t) end)
	Emit("Combat", 4, "bosses", "bosses", function(t) return "Bosses killed "..ns.FormatNumber(t) end)

	Emit("Exploration", 1, "quests", "quests", function(t) return "Quests completed "..ns.FormatNumber(t) end)
	Emit("Exploration", 2, "distance", "distance", function(t) return "Distance "..ns.FormatNumber(t).." km" end)
	Emit("Exploration", 3, "distanceOnFoot", "distanceOnFoot", function(t) return "Distance on foot "..ns.FormatNumber(t).." km" end)
	Emit("Exploration", 4, "distanceMounted", "distanceMounted", function(t) return "Distance mounted "..ns.FormatNumber(t).." km" end)

	Emit("Time", 1, "afk", "afk", function(t) return "AFK time "..math.floor(t / 3600).."h" end)
	Emit("Time", 2, "flightTime", "flightTime", function(t) return "Flight time "..math.floor(t / 3600).."h" end)

	Emit("Loot", 1, "loot", "loot", function(t) return "Items looted "..ns.FormatNumber(t) end)
	-- Poor through legendary only: artifact and heirloom are retail-only
	-- qualities this client does not use.
	local qualityNames = { [0] = "Poor", [1] = "Common", [2] = "Uncommon", [3] = "Rare",
		[4] = "Epic", [5] = "Legendary" }
	local qualityThresholds = thresholds.lootQuality or {}
	for quality = 0, 5 do
		local bucket = qualityThresholds[tostring(quality)] or {}
		local name = qualityNames[quality]
		for _, threshold in ipairs(ns.milestoneThresholds.lootQuality or {}) do
			AddCount("Loot", 2 + quality, threshold, name.." items "..ns.FormatNumber(threshold), bucket[threshold])
		end
	end

	Emit("Economy", 1, "gold", "balance", function(t) return "Gold held "..ns.FormatMoneyBig(t) end)
	Emit("Economy", 2, "goldSpent", "gold", function(t) return "Gold spent "..ns.FormatMoneyBig(t) end)
	Emit("Economy", 3, "crafted", "crafted", function(t) return "Items crafted "..ns.FormatNumber(t) end)

	-- Professions, alphabetically, with the skill ladder before the recipe
	-- ladder for each one.
	local professionNames, seenProfession = {}, {}
	local function AddProfession(name)
		if name and not seenProfession[name] then
			seenProfession[name] = true
			professionNames[#professionNames + 1] = name
		end
	end
	for profession in pairs(thresholds.recipes or {}) do
		AddProfession(profession)
	end
	for profession in pairs(thresholds.professionSkills or {}) do
		AddProfession(profession)
	end
	table.sort(professionNames)
	for index = 1, #professionNames do
		local profession = professionNames[index]
		local skills = (thresholds.professionSkills or {})[profession] or {}
		for _, threshold in ipairs(ns.milestoneThresholds.professionSkills or {}) do
			AddCount("Professions", index, threshold, profession.." skill "..threshold, skills[threshold])
		end
		local recipes = (thresholds.recipes or {})[profession] or {}
		for _, threshold in ipairs(ns.milestoneThresholds.recipes or {}) do
			AddCount("Professions", index, 10000 + threshold, profession.." "..threshold.." recipes", recipes[threshold])
		end
	end
end

local function RefreshMilestones()
	local card = milestoneWidgets.card
	if not card then
		return
	end
	local char = DisplayChar()
	if not char then
		ShowCardText(card, "No character selected.")
		return
	end
	local milestones = char.milestones or {}
	local items = {}
	CountItems(items, char, milestones, milestoneWidgets.showHidden)

	local mode = milestoneWidgets.sortMode
	-- Fixed category and metric order; only the thresholds inside a metric
	-- walk low-to-high or high-to-low. Labels are never sorted: "1.000" would
	-- land next to "10" otherwise.
	local CATEGORY_ORDER = { Combat = 1, Exploration = 2, Time = 3, Loot = 4, Economy = 5, Professions = 6 }
	table.sort(items, function(a, b)
		if (a.hidden and true or false) ~= (b.hidden and true or false) then
			return not a.hidden
		end
		if a.category ~= b.category then
			local ao = CATEGORY_ORDER[a.category] or 99
			local bo = CATEGORY_ORDER[b.category] or 99
			if ao ~= bo then
				return ao < bo
			end
			return a.category < b.category
		end
		if (a.metric or 0) ~= (b.metric or 0) then
			return (a.metric or 0) < (b.metric or 0)
		end
		if (a.threshold or 0) ~= (b.threshold or 0) then
			if mode == "high" then
				return (a.threshold or 0) > (b.threshold or 0)
			end
			return (a.threshold or 0) < (b.threshold or 0)
		end
		return a.label < b.label
	end)

	local lines = {}
	local category
	for index = 1, #items do
		local item = items[index]
		if item.category ~= category then
			category = item.category
			local headerCategory = category
			local count = 0
			for other = 1, #items do
				if items[other].category == category then count = count + 1 end
			end
			local collapsed = milestoneWidgets.collapsed[category]
			lines[#lines + 1] = {
				left = (collapsed and "[+] " or "[-] ")..category.." ("..count..")",
				leftColor = ACCENT,
				click = function()
					milestoneWidgets.collapsed[headerCategory] = not milestoneWidgets.collapsed[headerCategory]
					RefreshMilestones()
				end,
				tip = {
					kind = "note",
					title = category,
					lines = {
						{ text = collapsed and "Click to expand this category." or "Click to collapse this category." },
					},
					key = "milestone-category|"..category.."|"..(collapsed and "closed" or "open"),
				},
			}
		end

		if not milestoneWidgets.collapsed[item.category] then
			local right = item.hidden and "Not reached"
				or (item.at and item.at > 0 and ns.FormatDateTime(item.at) or "Not reached")
			lines[#lines + 1] = {
				left = "   "..item.label,
				right = right,
				tip = item.tip,
			}
		end
	end

	if milestoneWidgets.count then
		milestoneWidgets.count:SetText(#items.." recorded")
	end
	if milestoneWidgets.sortButton then
		SetCornerLabel(milestoneWidgets.sortButton, SortLabel(mode))
	end

	if FillScrollingLines(card, lines, milestoneWidgets, "milestoneOffset", "Milestones", 54) == 0 then
		ShowCardText(card, "No milestones recorded yet.")
	end
end

local function BuildMilestonesPage(page)
	milestoneWidgets.count = page:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	milestoneWidgets.count:SetPoint("TOPLEFT", page, "TOPLEFT", 2, -2)
	milestoneWidgets.count:SetTextColor(0.7, 0.7, 0.7)

	milestoneWidgets.card = CreateListCard(page, 0, -20, 730, 414, "Milestones")
	AddCardTitleNote(milestoneWidgets.card, "Milestones",
		"Counts for this character. In category order, click a category to collapse or expand it. Hover a row for when it was reached, how long the record had been running and the average per day.")
	AddCardScrollbar(milestoneWidgets.card, milestoneWidgets, "milestoneOffset", RefreshMilestones)
	MakeCardScrollable(milestoneWidgets.card, milestoneWidgets, "milestoneOffset", RefreshMilestones)
	milestoneWidgets.card:SetScript("OnUpdate", function()
		RowHoverTick(milestoneWidgets.card)
	end)
	milestoneWidgets.card:SetScript("OnLeave", function()
		milestoneWidgets.card.hoverKey = nil
		if GameTooltip:IsOwned(milestoneWidgets.card) then
			GameTooltip:Hide()
		end
	end)

	local sortButton = CreateCornerButton(milestoneWidgets.card)
	milestoneWidgets.sortButton = sortButton
	SetCornerLabel(sortButton, SortLabel(milestoneWidgets.sortMode))
	sortButton:SetScript("OnClick", function()
		milestoneWidgets.sortMode = NextMode(SORT_MODES, milestoneWidgets.sortMode)
		milestoneWidgets.milestoneOffset = 0
		RefreshMilestones()
	end)
	sortButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Milestone order", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Milestones are grouped by category. Click to walk the thresholds inside each one from low to high or high to low.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	sortButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	local hiddenButton = CreateCornerButton(milestoneWidgets.card)
	milestoneWidgets.hiddenButton = hiddenButton
	SetCornerLabel(hiddenButton, "hidden: off")
	hiddenButton:ClearAllPoints()
	hiddenButton:SetPoint("RIGHT", sortButton, "LEFT", -6, 0)
	hiddenButton:SetScript("OnClick", function()
		milestoneWidgets.showHidden = not milestoneWidgets.showHidden
		SetCornerLabel(hiddenButton, milestoneWidgets.showHidden and "hidden: on" or "hidden: off")
		RefreshMilestones()
	end)
	hiddenButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Ungained general counts", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("Show every count threshold, including those not reached yet.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	hiddenButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	-- Category headers are rows with a click action. The card's rows are not
	-- mouse-enabled, so the card resolves the row under the cursor itself.
	milestoneWidgets.card:SetScript("OnMouseDown", function(self, button)
		if button == "LeftButton" then
			self.pressX, self.pressY = GetCursorPosition()
		end
	end)
	milestoneWidgets.card:SetScript("OnMouseUp", function(self, button)
		local pressX, pressY = self.pressX, self.pressY
		self.pressX, self.pressY = nil, nil
		if button ~= "LeftButton" or not pressX then
			return
		end
		local cursorX, cursorY = GetCursorPosition()
		local slack = 5 * (self:GetEffectiveScale() or 1)
		if math.abs(cursorX - pressX) > slack or math.abs(cursorY - pressY) > slack then
			return
		end
		local row = RowAtCursor(self)
		if row and row.click then
			row.click()
		end
	end)
	RefreshMilestones()
end

ns.BuildMilestonesPage = BuildMilestonesPage
ns.RefreshMilestones = RefreshMilestones
