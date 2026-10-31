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
	sortMode = "category",
	showMode = "all",
	showHidden = false,
}

local SORT_MODES = { "newest", "oldest", "category", "alpha" }
local SHOW_MODES = { "all", "firsts", "counts" }

local function NextMode(list, current)
	for index = 1, #list do
		if list[index] == current then
			return list[index % #list + 1]
		end
	end
	return list[1]
end

local function SortLabel(mode)
	if mode == "oldest" then return "sort: oldest" end
	if mode == "category" then return "sort: category" end
	if mode == "alpha" then return "sort: A-Z" end
	return "sort: newest"
end

local function ShowLabel(mode)
	if mode == "firsts" then return "show: firsts" end
	if mode == "counts" then return "show: counts" end
	return "show: all"
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
	local function AddCount(category, label, value, entry)
		if entry then
			local extra = {}
			if entry.observed == "login" or entry.observed == "migration" then
				extra[#extra + 1] = {
					text = "Number is estimated: Tally first saw this milestone already reached; the date is when it was first seen, not when it was crossed.",
					color = ROW_DETAIL_DIM,
				}
			end
			AddItem(items, category, label, entry.at, NoticeTip(label, entry, extra))
			items[#items].count = true
		elseif showHidden then
			AddItem(items, category, label.." (not yet)", 0, nil, true)
			items[#items].count = true
		end
	end
	local function Emit(group, key, labelFn, valueFn)
		local bucket = thresholds[group] and thresholds[group][key] or {}
		local thresholdsFor = ns.milestoneThresholds[group] or {}
		for _, threshold in ipairs(thresholdsFor) do
			AddCount("General", labelFn(threshold), valueFn(threshold), bucket[threshold])
		end
	end
	Emit("quests", "quests", function(t) return "Quests "..ns.FormatNumber(t) end,
		function(t) return ns.FormatNumber(t) end)
	Emit("gold", "balance", function(t) return "Gold "..ns.FormatMoneyBig(t) end,
		function(t) return ns.FormatMoneyBig(t) end)
	Emit("goldSpent", "gold", function(t) return "Gold spent "..ns.FormatMoneyBig(t) end,
		function(t) return ns.FormatMoneyBig(t) end)
	Emit("kills", "kills", function(t) return "Enemies killed "..ns.FormatNumber(t) end,
		function(t) return ns.FormatNumber(t) end)
	-- The first death is the Deaths 1 count row, with the zone it happened in.
	-- There is no separate "First death" row in Combat any more: the event
	-- belongs with the count it produces.
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
		AddCount("General", label, ns.FormatNumber(threshold), record)
	end
	Emit("dungeons", "dungeons", function(t) return "Dungeon runs "..ns.FormatNumber(t) end,
		function(t) return ns.FormatNumber(t) end)
	Emit("bosses", "bosses", function(t) return "Bosses killed "..ns.FormatNumber(t) end,
		function(t) return ns.FormatNumber(t) end)
	Emit("loot", "loot", function(t) return "Items looted "..ns.FormatNumber(t) end,
		function(t) return ns.FormatNumber(t) end)
	Emit("crafted", "crafted", function(t) return "Items crafted "..ns.FormatNumber(t) end,
		function(t) return ns.FormatNumber(t) end)
	Emit("distance", "distance", function(t) return "Distance "..ns.FormatNumber(t).." km" end,
		function(t) return tostring(t) end)
	for profession, byThreshold in pairs(thresholds.recipes or {}) do
		for _, threshold in ipairs(ns.milestoneThresholds.recipes) do
			AddCount("General", profession.." "..threshold.." recipes", tostring(threshold), byThreshold[threshold])
		end
	end
	for profession, byThreshold in pairs(thresholds.professionSkills or {}) do
		for _, threshold in ipairs(ns.milestoneThresholds.professionSkills) do
			AddCount("General", profession.." skill "..threshold, tostring(threshold), byThreshold[threshold])
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
	LevelItems(items, char)
	CombatItems(items, milestones)
	ExplorationItems(items, char, milestones)
	EconomyItems(items, char, milestones)
	CountItems(items, char, milestones, milestoneWidgets.showHidden)

	local show = milestoneWidgets.showMode
	if show == "firsts" then
		local kept = {}
		for index = 1, #items do
			if not items[index].count then
				kept[#kept + 1] = items[index]
			end
		end
		items = kept
	elseif show == "counts" then
		local kept = {}
		for index = 1, #items do
			if items[index].count then
				kept[#kept + 1] = items[index]
			end
		end
		items = kept
	end

	local mode = milestoneWidgets.sortMode
	table.sort(items, function(a, b)
		if (a.hidden and true or false) ~= (b.hidden and true or false) then
			return not a.hidden
		end
		if mode == "newest" then
			if a.at ~= b.at then return a.at > b.at end
		elseif mode == "oldest" then
			if a.at ~= b.at then return a.at < b.at end
		elseif mode == "category" then
			local ar = a.category == "General" and 0 or 1
			local br = b.category == "General" and 0 or 1
			if ar ~= br then return ar < br end
			if a.category ~= b.category then return a.category < b.category end
			-- Inside General, keep the one-time firsts before the counts, then
			-- show each section newest first.
			if a.category == "General" then
				local ac = a.count and 1 or 0
				local bc = b.count and 1 or 0
				if ac ~= bc then return ac < bc end
			end
			if a.at ~= b.at then return a.at > b.at end
		else
			if a.label ~= b.label then return a.label < b.label end
		end
		return a.label < b.label
	end)

	local lines = {}
	-- General holds firsts and counts; show the two groups with their own
	-- subheadings when both are present, without making them categories.
	local generalFirsts, generalCounts = false, false
	if mode == "category" then
		for index = 1, #items do
			if items[index].category == "General" then
				if items[index].count then
					generalCounts = true
				else
					generalFirsts = true
				end
			end
		end
	end
	local splitGeneral = generalFirsts and generalCounts
	local generalSection
	local category
	for index = 1, #items do
		local item = items[index]
		if mode == "category" and item.category ~= category then
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
		if mode == "category" and item.category == "General" and splitGeneral
			and not milestoneWidgets.collapsed[item.category] then
			local section = item.count and "counts" or "firsts"
			if generalSection ~= section then
				generalSection = section
				lines[#lines + 1] = {
					left = "   "..(section == "firsts" and "Firsts" or "Counts"),
					leftColor = CATEGORY_HEAD_COLOR,
				}
			end
		end
		if mode ~= "category" or not milestoneWidgets.collapsed[item.category] then
			local right = item.at and item.at > 0 and ns.FormatDateTime(item.at) or "not yet"
			lines[#lines + 1] = {
				left = (mode == "category" and "   " or "")..item.label,
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
	if milestoneWidgets.showButton then
		SetCornerLabel(milestoneWidgets.showButton, ShowLabel(show))
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
		"One-time events and general counts for this character. In category order, click a category to collapse or expand it. Hover any row for when, where, how and whether it was seen live or at login. Item names carry their item tooltip.")
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
		GameTooltip:AddLine("Newest first, oldest first, grouped by category, or alphabetical.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	sortButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	local showButton = CreateCornerButton(milestoneWidgets.card)
	milestoneWidgets.showButton = showButton
	SetCornerLabel(showButton, ShowLabel(milestoneWidgets.showMode))
	showButton:ClearAllPoints()
	showButton:SetPoint("RIGHT", sortButton, "LEFT", -6, 0)
	showButton:SetScript("OnClick", function()
		milestoneWidgets.showMode = NextMode(SHOW_MODES, milestoneWidgets.showMode)
		milestoneWidgets.milestoneOffset = 0
		RefreshMilestones()
	end)
	showButton:SetScript("OnEnter", function(self)
		GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
		GameTooltip:AddLine("Which milestones", ACCENT[1], ACCENT[2], ACCENT[3])
		GameTooltip:AddLine("All, firsts only, or counts only.", 1, 1, 1, true)
		GameTooltip:Show()
	end)
	showButton:SetScript("OnLeave", function()
		GameTooltip:Hide()
	end)

	local hiddenButton = CreateCornerButton(milestoneWidgets.card)
	milestoneWidgets.hiddenButton = hiddenButton
	SetCornerLabel(hiddenButton, "hidden: off")
	hiddenButton:ClearAllPoints()
	hiddenButton:SetPoint("RIGHT", showButton, "LEFT", -6, 0)
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
