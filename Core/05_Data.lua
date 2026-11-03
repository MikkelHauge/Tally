-- Tally - the data contract: closed vocabularies, the context factory, the
-- timestamp helpers and the saved-data audit.
--
-- This file owns no saved subtree. It is the single place that decides what a
-- valid `how` and `evidence` value is, and it is the only intended writer of
-- char.meta.stamps. Nothing here changes an existing record on load.
local addonName, ns = ...

local function Set(list)
	local set = {}
	for index = 1, #list do
		set[list[index]] = true
	end
	return set
end

-- `how` says what happened. Keep one spelling per meaning; the UI never shows
-- these strings raw.
local HOW_ORDER = {
	-- lifecycle and meta
	"created", "login", "logout", "reload", "migration", "manual", "unknown",
	-- progression
	"level_up", "quest", "quest_reward", "exploration", "discovery",
	"instance_entry", "instance_exit", "death", "resurrect",
	-- combat
	"kill", "elite_kill", "rare_kill", "world_boss_kill", "dungeon_boss_kill",
	"raid_boss_kill", "solo_kill", "group_kill", "pet_kill", "pvp_kill", "aura",
	-- loot and items
	"loot", "corpse_loot", "chest_loot", "container_loot", "fishing",
	"pickpocket", "item_received", "item_crafted", "item_equipped", "item_seen",
	-- professions
	"profession_learned", "profession_dropped", "profession_skill",
	"recipe_learned", "craft", "enchant", "disenchant", "prospect", "mill",
	"salvage", "cooldown_started", "cooldown_ready",
	-- economy
	"vendor_sale", "vendor_purchase", "repair", "trainer", "mail_send",
	"mail_receive", "mail_cod", "trade", "auction_post", "auction_sale",
	"auction_purchase", "auction_deposit", "auction_cut", "auction_expired",
	"auction_cancelled", "taxi", "bank", "guild", "refund", "money_change",
	-- social and world
	"group_joined", "party_joined", "raid_joined", "guild_joined",
	"mount_summoned", "mount_learned", "riding_skill", "zone_entered",
	"zone_left", "flight_started", "flight_ended", "battleground_entered",
	"arena_entered", "pet_summoned", "tame",
	-- records and milestones
	"milestone_first", "milestone_threshold", "record_set",
}

-- `evidence` says how Tally knew. It is deliberately separate from `how`:
-- "quest" is the meaning, "chat_xp" is the detector.
local EVIDENCE_ORDER = {
	"chat_xp", "chat_loot", "chat_money", "chat_skill", "chat_system",
	"chat_faction", "chat_combat",
	"party_kill_event", "unit_died_event", "nameplate_health",
	"nameplate_classification", "threat_list", "pet_target", "instance_xp_line",
	"instance_loot_window", "encounter_end", "zone_event", "instance_info",
	"quest_event", "group_event", "guild_event", "level_event",
	"unit_level", "unit_class", "unit_race", "unit_faction", "unit_position",
	"unit_on_taxi", "is_mounted", "money_poll", "money_window",
	"spell_cooldown", "spell_cast", "spell_learned", "aura_scan",
	"spell_tooltip",
	"item_link", "item_cache", "inventory_scan", "loot_message", "loot_window",
	"bag_scan", "merchant_quote", "auction_invoice", "mail_invoice",
	"trade_window", "trainer_window", "craft_event", "trade_skill_window",
	"login_snapshot", "api_baseline", "migration", "manual", "estimate",
	"unknown",
}

local OBSERVED_ORDER = { "live", "login", "migration", "estimate", "unknown" }

-- The vocabulary the UI and reports read. `how` and `evidence` are sets for
-- O(1) validation; the *_ORDER lists keep a stable order for a picker or a
-- legend later.
ns.dataContract = {
	how = Set(HOW_ORDER),
	howOrder = HOW_ORDER,
	evidence = Set(EVIDENCE_ORDER),
	evidenceOrder = EVIDENCE_ORDER,
	observed = Set(OBSERVED_ORDER),
	observedOrder = OBSERVED_ORDER,
}

local warned = {}

local function Validate(kind, value, fallback)
	local set = ns.dataContract[kind]
	if type(value) == "string" and set[value] then
		return value
	end
	local key = kind..":"..tostring(value)
	if not warned[key] then
		warned[key] = true
		ns.Trace("data: invalid "..kind.." "..tostring(value).." - using "..fallback)
	end
	return fallback
end

-- One event's context. Only real values are copied; no "Unknown" placeholder
-- is stored. Callers pass `zone` only when the current place is meaningful.
function ns.Context(how, evidence, opts)
	opts = opts or {}
	local context = {
		at = tonumber(opts.at) or ns.Now(),
		how = Validate("how", how, "unknown"),
		evidence = Validate("evidence", evidence, "unknown"),
		observed = Validate("observed", opts.observed, "live"),
	}
	if opts.observedAt then
		context.observedAt = tonumber(opts.observedAt) or context.at
	end
	if type(opts.zone) == "string" and opts.zone ~= "" then
		context.zone = opts.zone
	end
	if type(opts.zoneKind) == "string" and opts.zoneKind ~= "" then
		context.zoneKind = opts.zoneKind
	end
	return context
end

-- Every character gets one meta table. The stamp map covers counters that are
-- still stored as plain numbers, so the existing readers do not change.
local function EnsureMeta(char)
	if type(char) ~= "table" then
		return nil
	end
	if type(char.meta) ~= "table" then
		char.meta = {}
	end
	if type(char.meta.stamps) ~= "table" then
		char.meta.stamps = {}
	end
	return char.meta
end

-- Create or move one field's stamps. Callers call this only after a real write.
function ns.Touch(char, path, at, firstAt)
	local meta = EnsureMeta(char)
	if not meta or type(path) ~= "string" or path == "" then
		return nil
	end
	at = tonumber(at) or ns.Now()
	local stamp = meta.stamps[path]
	if type(stamp) ~= "table" then
		stamp = {
			firstAt = tonumber(firstAt) or at,
			lastAt = at,
			updatedAt = at,
		}
		meta.stamps[path] = stamp
		return stamp
	end
	if not stamp.firstAt then
		stamp.firstAt = tonumber(firstAt) or at
	elseif stamp.firstAt > at then
		stamp.firstAt = at
	end
	if not stamp.lastAt or at > stamp.lastAt then
		stamp.lastAt = at
	end
	stamp.updatedAt = at
	return stamp
end

-- Compare first, write only on a real change. Returns true when the value was
-- different and the stamp moved.
function ns.TouchIf(char, path, oldValue, newValue, at)
	if oldValue == newValue then
		return false
	end
	ns.Touch(char, path, at)
	return true
end

function ns.Stamp(char, path)
	local meta = EnsureMeta(char)
	return meta and meta.stamps[path] or nil
end

-------------------------------------------------------------------------------
-- First-seen snapshot
-------------------------------------------------------------------------------

local function FirstSeenZone()
	local zone, kind
	if type(GetRealZoneText) == "function" then
		local ok, value = pcall(GetRealZoneText)
		if ok and type(value) == "string" and value ~= "" then
			zone = value
		end
	end
	if not zone and ns.CurrentZone then
		zone = ns.CurrentZone()
	end
	if type(GetInstanceInfo) == "function" then
		local ok, _, instanceType = pcall(GetInstanceInfo)
		if ok and type(instanceType) == "string" then
			kind = instanceType
		end
	end
	return zone, kind
end

local function FirstSeenGear()
	if type(GetInventoryItemID) ~= "function" then
		return nil
	end
	local gear = {}
	for slot = 1, 19 do
		local ok, itemID = pcall(GetInventoryItemID, "player", slot)
		if ok and type(itemID) == "number" and itemID > 0 then
			local name, link, quality = ns.ItemInfo(itemID)
			if not name and type(GetInventoryItemLink) == "function" then
				local okLink, itemLink = pcall(GetInventoryItemLink, "player", slot)
				if okLink and type(itemLink) == "string" then
					link = itemLink
					if ns.ItemInfoByName then
						local foundName, foundLink, foundQuality = ns.ItemInfoByName(itemLink)
						name = name or foundName
						link = link or foundLink
						quality = quality or foundQuality
					end
				end
			end
			if name then
				gear[slot] = {
					itemID = itemID, name = name, link = link, quality = quality, slot = slot,
				}
			end
		end
	end
	return next(gear) and gear or nil
end

local function FirstSeenProfessions(char)
	local list = {}
	for _, skill in ipairs((char.professions and char.professions.skills) or {}) do
		if type(skill) == "table" and skill.name then
			list[#list + 1] = {
				name = skill.name, rank = skill.rank, maxRank = skill.maxRank,
			}
		end
	end
	return #list > 0 and list or nil
end

-- One immutable snapshot of the character as Tally first met it. It is an
-- anchor, not a claim about levels played before Tally was installed. Existing
-- records get it once, marked migration; a new record gets it live.
function ns.EnsureFirstSeen(char)
	char = char or ns.GetChar()
	if not char or type(char.firstSeen) == "table" then
		return char and char.firstSeen or nil
	end
	local now = ns.Now()
	local zone, zoneKind = FirstSeenZone()
	local played = char.played or {}
	local xp, xpMax
	if type(UnitXP) == "function" then
		local ok, value = pcall(UnitXP, "player")
		if ok and type(value) == "number" then
			xp = value
		end
	end
	if type(UnitXPMax) == "function" then
		local ok, value = pcall(UnitXPMax, "player")
		if ok and type(value) == "number" then
			xpMax = value
		end
	end
	local live = char.created and ns.loginAt and char.created >= (ns.loginAt - 5)
	char.firstSeen = {
		at = now,
		observed = live and "live" or "migration",
		level = char.level,
		zone = zone,
		zoneKind = zoneKind,
		playedTotal = played.total,
		playedLevel = played.levelTime,
		playedLevelNumber = played.level,
		xp = xp,
		xpMax = xpMax,
		gear = FirstSeenGear(),
		professions = FirstSeenProfessions(char),
		classFile = char.classFile,
		faction = ns.CharFaction and ns.CharFaction(char) or nil,
	}
	-- The first level entry can be anchored only when the snapshot is for the
	-- same level and is not later than that entry.
	local first = char.levels and char.levels.history and char.levels.history[1]
	if first and first.level == char.level and not first.startedAt
		and first.at and now <= first.at then
		first.startedAt = now
	end
	return char.firstSeen
end

-- A level-up that happened while Tally was not running, or whose event was
-- missed, leaves the history one or more levels behind the client. Record the
-- current level once, marked as a migration, so it is not lost. The date is the
-- moment Tally saw it, not a claim about when it happened, and no zone or cause
-- is invented.
function ns.RepairMissingLevel(char)
	char = char or ns.GetChar()
	if not char or not char.level then
		return
	end
	if not char.levels then
		char.levels = { history = {} }
	end
	if not char.levels.history then
		char.levels.history = {}
	end
	local history = char.levels.history
	local last = history[#history]
	if not last or (last.level or 0) >= char.level then
		return
	end
	local at = ns.Now()
	local entry = {
		level = char.level, at = at,
		observed = "migration", partial = true, timingMissing = true,
	}
	history[#history + 1] = entry
	if ns.NoteEvent then
		local event = ns.NoteEvent("level_up", {
			at = at, how = "level_up", evidence = "migration",
			observed = "migration",
			data = { level = char.level, partial = true },
		})
		if event then
			entry.event = event.id
		end
	end
	ns.Trace("level history: recorded level "..tostring(char.level).." first seen at login")
end

-- A level-up interrupted by a reload can leave its pending row in the history
-- and collect a second, finished row for the same level from the next /played
-- reply. They describe one level, so keep the pending row's real level-up time
-- and zone, take the finished row's /played figures, and drop the duplicate.
-- Only adjacent rows where the first is still pending are touched; nothing is
-- invented and a second run finds nothing to merge.
function ns.RepairDuplicateLevels(char)
	char = char or ns.GetChar()
	local history = char and char.levels and char.levels.history
	if type(history) ~= "table" then
		return 0
	end
	local merged = 0
	local index = 1
	while index < #history do
		local first, second = history[index], history[index + 1]
		if first and second and first.level == second.level and second.total
			and (first.pending or first.timingMissing or not first.total) then
			-- The finished reply is the authority for the measured figures.
			first.total = second.total
			first.levelTime = second.levelTime
			first.levelTimeUnknown = second.levelTimeUnknown
			first.gap = second.gap
			first.partial = second.partial
			first.timingMissing = second.timingMissing
			first.endedAt = second.endedAt or first.endedAt
			first.startedAt = first.at or second.startedAt
			first.zone = first.zone or second.zone
			first.zoneKind = first.zoneKind or second.zoneKind
			first.pending = nil
			-- A seconds figure on the duplicate was measured against the
			-- pending row's own start, so it belongs to the level that ended
			-- there, not to this one.
			if second.seconds then
				local previous = history[index - 1]
				if previous and not previous.seconds then
					previous.seconds = second.seconds
					previous.secondsPartial = second.secondsPartial
				end
			end
			if second.event and char.events and type(char.events.list) == "table" then
				for eventIndex = 1, #char.events.list do
					local event = char.events.list[eventIndex]
					if event.id == second.event then
						event.superseded = true
						break
					end
				end
			end
			if first.event and char.events and type(char.events.list) == "table" then
				for eventIndex = 1, #char.events.list do
					local event = char.events.list[eventIndex]
					if event.id == first.event then
						event.data = event.data or {}
						event.data.total = first.total
						event.data.levelTime = first.levelTime
						event.data.gap = first.gap
						event.data.partial = first.partial
						break
					end
				end
			end
			table.remove(history, index + 1)
			merged = merged + 1
		else
			index = index + 1
		end
	end
	if merged > 0 then
		ns.Trace("level history: merged "..merged.." duplicate level row"..(merged == 1 and "" or "s"))
	end
	return merged
end

-------------------------------------------------------------------------------
-- Saved-data audit
-------------------------------------------------------------------------------

local MAX_DEPTH = 5
local MAX_MAP_CHILDREN = 24
local MAX_ARRAY_CHILDREN = 3

local function SortedKeys(value)
	local keys = {}
	for key in pairs(value) do
		keys[#keys + 1] = key
	end
	table.sort(keys, function(a, b)
		local ta, tb = type(a), type(b)
		if ta ~= tb then
			return ta < tb
		end
		if ta == "number" or ta == "string" then
			return a < b
		end
		return tostring(a) < tostring(b)
	end)
	return keys
end

local function IsArray(value)
	local count = 0
	for key in pairs(value) do
		if type(key) ~= "number" then
			return false
		end
		count = count + 1
	end
	return count > 0 and count == #value
end

local function ApproxBytes(value, depth)
	local kind = type(value)
	if kind == "string" then
		return #value + 2
	elseif kind == "number" then
		return #tostring(value)
	elseif kind == "boolean" then
		return 5
	elseif kind ~= "table" then
		return 4
	end
	if depth > 3 then
		return 24
	end
	local total = 2
	local count = 0
	for key, child in pairs(value) do
		count = count + 1
		if count > 60 then
			return total + 60
		end
		total = total + ApproxBytes(key, depth + 1) + ApproxBytes(child, depth + 1) + 2
	end
	return total
end

local STAMP_FIELDS = {
	"firstAt", "lastAt", "updatedAt", "at", "observedAt", "created",
	"start", "stop", "lastSeenAt", "first", "last",
}

local function StampSummary(value)
	local parts = {}
	for index = 1, #STAMP_FIELDS do
		local field = STAMP_FIELDS[index]
		if value[field] ~= nil then
			parts[#parts + 1] = field.."="..tostring(value[field])
		end
	end
	if #parts == 0 then
		return ""
	end
	return "  {"..table.concat(parts, ", ").."}"
end

local function ShortValue(value)
	local kind = type(value)
	if kind == "string" then
		if #value > 48 then
			return string.format("%q...(%d)", string.sub(value, 1, 45), #value)
		end
		return string.format("%q", value)
	elseif kind == "number" or kind == "boolean" then
		return tostring(value)
	elseif kind == "nil" then
		return "nil"
	end
	return "<"..kind..">"
end

local function Walk(path, value, depth, out, seen)
	if type(value) ~= "table" then
		out[#out + 1] = path.." = "..ShortValue(value)
		return
	end
	if seen[value] then
		out[#out + 1] = path.." = <cycle>"
		return
	end
	seen[value] = true
	local keys = SortedKeys(value)
	out[#out + 1] = string.format("%s  [table, %d entries, ~%d bytes]%s",
		path, #keys, ApproxBytes(value, 0), StampSummary(value))
	if depth >= MAX_DEPTH then
		out[#out + 1] = path.."  ... depth limit"
		seen[value] = nil
		return
	end
	local array = IsArray(value)
	local limit = array and MAX_ARRAY_CHILDREN or MAX_MAP_CHILDREN
	local shown = 0
	for index = 1, #keys do
		if shown >= limit then
			out[#out + 1] = string.format("%s  ... %d more", path, #keys - shown)
			break
		end
		local key = keys[index]
		shown = shown + 1
		Walk(path.."."..tostring(key), value[key], depth + 1, out, seen)
	end
	seen[value] = nil
end

-- Every figure the window draws, and the saved path behind it. This is the
-- map the audit uses to prove a displayed number has a source. It is data,
-- not code: adding a tile should add its path here.
ns.dataContract.displaySources = {
	overview = {
		"char.played.total", "char.played.at", "char.tracked", "char.created",
		"char.level", "char.xp.current", "char.xp.max", "char.xp.currentAt",
		"char.gold.balance", "char.gold.income", "char.gold.expenses",
		"char.combat.fights", "char.combat.deaths", "char.loot.items",
		"char.loot.value", "char.sessions.count", "char.explore.zones",
		"char.explore.dungeons", "char.explore.bosses",
		"char.explore.distance", "char.explore.flightSeconds",
		"char.explore.recent", "char.explore.recentFirsts",
		"char.sessions.current", "char.sessions.history",
	},
	playtime = {
		"char.played.total", "char.played.at", "char.played.levelTime",
		"char.tracked", "char.alive", "char.afk", "char.sessions.count",
		"char.sessions.seconds", "char.sessions.longest",
		"char.sessions.history", "char.levels.history",
	},
	milestones = {
		"char.firstLevel", "char.created", "char.levels.history",
		"char.milestones.firsts", "char.milestones.firstEquip",
		"char.milestones.firstSlot", "char.milestones.firstWeapon",
		"char.milestones.fullSets", "char.milestones.firstGroup",
		"char.milestones.firstGroupByClass", "char.milestones.firstMount",
		"char.milestones.riding", "char.milestones.thresholds",
	},
	economy = {
		"char.gold.balance", "char.gold.first", "char.gold.income",
		"char.gold.expenses", "char.gold.unclassified", "char.gold.daily",
		"char.gold.tx", "char.currency", "char.sessions.history",
	},
	professions = {
		"char.professions.skills", "char.professions.crafts",
		"char.professions.crafted", "char.professions.recipes",
		"char.professions.cooldownStats", "char.professions.itemCooldowns",
		"char.gathering",
	},
	combat = {
		"char.combat.fights", "char.combat.combatSeconds", "char.combat.deaths",
		"char.combat.deathsByZone", "char.combat.deathLog",
		"char.combat.kills", "char.combat.killTypes", "char.combat.killInfo",
		"char.combat.killsByZone", "char.combat.killSessions",
		"char.combat.killingFights", "char.combat.bestFight",
		"char.combat.bestFightAt", "char.combat.bestFightZone",
		"char.combat.best10", "char.combat.best10At",
		"char.auras.buffs", "char.auras.debuffs", "char.auras.camp",
	},
	loot = {
		"char.loot.items", "char.loot.value", "char.loot.quality",
		"char.loot.qualityUnknown", "char.loot.best", "char.loot.itemCounts",
	},
	explore = {
		"char.explore.zones", "char.explore.dungeons", "char.explore.bosses",
		"char.explore.recent", "char.explore.recentFirsts",
		"char.explore.distance", "char.explore.flights",
		"char.explore.flightSeconds", "char.explore.mountedSeconds",
		"char.quests", "char.questXp", "char.gold.income.quest",
	},
	auction = {
		"char.ah.days", "char.ah.items", "char.ah.recent", "char.ah.buys",
		"char.ah.live", "char.ah.best", "char.ah.bestBuy",
	},
}

local function AddCharacterAudit(lines, key, char)
	lines[#lines + 1] = ""
	lines[#lines + 1] = "== "..tostring(key).." =="
	lines[#lines + 1] = string.format("name=%s realm=%s level=%s class=%s created=%s",
		tostring(char.name), tostring(char.realm), tostring(char.level),
		tostring(char.classFile), tostring(char.created))
	local roots = SortedKeys(char)
	for index = 1, #roots do
		local root = roots[index]
		if type(char[root]) ~= "function" then
			Walk(tostring(root), char[root], 1, lines, {})
		end
	end
end

function ns.BuildDataAuditText()
	local lines = {}
	lines[#lines + 1] = "Tally data audit"
	lines[#lines + 1] = "build: "..tostring(ns.BUILD)
	lines[#lines + 1] = "schema: "..tostring(ns.SchemaVersion and ns.SchemaVersion() or "?")
	lines[#lines + 1] = "generated: "..date("%Y-%m-%d %H:%M:%S")
	lines[#lines + 1] = ""
	lines[#lines + 1] = "This is a schema and context inventory, not a save editor."
	lines[#lines + 1] = "Stamps shown in braces are the fields present on that table."
	local chars = {}
	for key, char in pairs((ns.db and ns.db.chars) or {}) do
		chars[#chars + 1] = { key = key, char = char }
	end
	table.sort(chars, function(a, b)
		return tostring(a.key) < tostring(b.key)
	end)
	if #chars == 0 then
		lines[#lines + 1] = "No character records."
	end
	for index = 1, #chars do
		AddCharacterAudit(lines, chars[index].key, chars[index].char)
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "== displayed sources =="
	local tabs = {}
	for tab in pairs(ns.dataContract.displaySources) do
		tabs[#tabs + 1] = tab
	end
	table.sort(tabs)
	for index = 1, #tabs do
		local tab = tabs[index]
		lines[#lines + 1] = tab..":"
		local paths = ns.dataContract.displaySources[tab]
		for pathIndex = 1, #paths do
			lines[#lines + 1] = "  "..paths[pathIndex]
		end
	end
	return table.concat(lines, "\n")
end

function ns.AuditData()
	if not ns.db then
		return
	end
	ns.db.lastAuditAt = ns.Now()
	local text = ns.BuildDataAuditText()
	local count = 0
	for _ in pairs(ns.db.chars or {}) do
		count = count + 1
	end
	ns.Print("Data audit: "..count..(count == 1 and " character" or " characters")..". The full inventory is in the copy window.")
	if ns.OpenCopyWindow then
		ns.OpenCopyWindow("Data audit", text)
	else
		ns.Print(text)
	end
end

-------------------------------------------------------------------------------
-- Text export
-------------------------------------------------------------------------------

-- A full text export for a clean start. It is deliberately plain text: it is a
-- backup, not a re-importable SavedVariables file. Every report for the
-- character in view (or the live character) is followed by the complete audit
-- of every stored character.
function ns.BuildDataExportText()
	if ns.db then
		ns.db.lastExportAt = ns.Now()
	end
	local lines = {}
	lines[#lines + 1] = "Tally data export"
	lines[#lines + 1] = "build: "..tostring(ns.BUILD)
	lines[#lines + 1] = "schema: "..tostring(ns.SchemaVersion and ns.SchemaVersion() or "?")
	lines[#lines + 1] = "generated: "..date("%Y-%m-%d %H:%M:%S")
	lines[#lines + 1] = "This text is a backup. It cannot be imported back into Tally."
	lines[#lines + 1] = ""
	-- Every known character, not only the one in view: a backup that silently
	-- skipped the other characters would be worse than no backup.
	local savedView = ns.viewKey
	local ok, err = pcall(function()
		local known = ns.KnownCharacters and ns.KnownCharacters() or {}
		for charIndex = 1, #known do
			local entry = known[charIndex]
			ns.viewKey = (entry.key ~= ns.charKey) and entry.key or nil
			local char = ns.ReportChar()
			if char then
				lines[#lines + 1] = "== Character: "..tostring(ns.DisplayName(char)).." ("..tostring(entry.key)..") =="
				lines[#lines + 1] = "Level "..tostring(char.level or 0).." "..tostring(char.class or "?")
					..", realm "..tostring(char.realm or "?")
				lines[#lines + 1] = ""
				for index = 1, #(ns.REPORT_ORDER or {}) do
					local reportType = ns.REPORT_ORDER[index]
					lines[#lines + 1] = "-- "..tostring(ns.ReportTitle and ns.ReportTitle(reportType) or reportType).." --"
					local report = ns.BuildReport(reportType) or {}
					for lineIndex = 1, #report do
						lines[#lines + 1] = ns.StripColors(report[lineIndex])
					end
					lines[#lines + 1] = ""
				end
			end
		end
	end)
	ns.viewKey = savedView
	if not ok then
		ns.Trace("data export: "..tostring(err))
		lines[#lines + 1] = "Export error: "..tostring(err)
	end
	lines[#lines + 1] = ns.BuildDataAuditText()
	return table.concat(lines, "\n")
end

function ns.ExportData()
	if not ns.db then
		return
	end
	local text = ns.BuildDataExportText()
	if ns.db.settings.copyDirect and type(CopyToClipboard) == "function" then
		local ok = pcall(CopyToClipboard, text, false)
		if ok then
			ns.Print("The data export is on your clipboard ("..#text.." characters).")
			return
		end
		ns.Print("The clipboard refused the text - opening the copy window instead.")
	end
	if #text > 59000 then
		ns.Print("This export is "..#text.." characters, longer than the copy window's 60k limit. Turn on \"Copy straight to the system clipboard\" in Settings for the full text.")
	end
	if ns.OpenCopyWindow then
		ns.OpenCopyWindow("Data export", text)
		ns.Print("The data export is in the copy window - press Ctrl+C there.")
	else
		ns.Print(text)
	end
end
