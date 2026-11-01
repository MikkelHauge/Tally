-- Tally - the canonical event log and record book.
--
-- One important event per first, milestone crossing, level-up, session and
-- record. Routine kills, loot, money, zones, quests, crafts and auctions keep
-- a bounded recent ring (500 entries). Both lists use one per-character event
-- id space, so a reference cannot collide.
local addonName, ns = ...

local RECENT_CAP = 500
local IMPORTANT_CAP = 5000

local function Ensure(record)
	if type(record) ~= "table" then
		return nil
	end
	if type(record.events) ~= "table" then
		record.events = {}
	end
	if type(record.events.list) ~= "table" then
		record.events.list = {}
	end
	if type(record.events.seq) ~= "number" then
		record.events.seq = 0
	end
	if type(record.recentEvents) ~= "table" then
		record.recentEvents = {}
	end
	if type(record.records) ~= "table" then
		record.records = {}
	end
	return record.events
end

local function Make(record, kind, fields)
	local log = Ensure(record)
	if not log or not kind then
		return nil
	end
	fields = fields or {}
	local id = log.seq + 1
	log.seq = id
	return {
		id = id,
		kind = kind,
		at = tonumber(fields.at) or ns.Now(),
		zone = type(fields.zone) == "string" and fields.zone ~= "" and fields.zone or nil,
		zoneKind = fields.zoneKind,
		how = fields.how,
		evidence = fields.evidence,
		observed = fields.observed,
		data = fields.data or {},
	}
end

-- One important event, kept for good (with a generous safety cap).
function ns.NoteEventFor(record, kind, fields)
	local event = Make(record, kind, fields)
	if not event then
		return nil
	end
	local log = record.events
	log.list[#log.list + 1] = event
	if #log.list > IMPORTANT_CAP then
		table.remove(log.list, 1)
	end
	return event
end

-- One routine event, kept only in the recent ring.
function ns.NoteRecentEventFor(record, kind, fields)
	local event = Make(record, kind, fields)
	if not event then
		return nil
	end
	local ring = record.recentEvents
	ring[#ring + 1] = event
	while #ring > RECENT_CAP do
		table.remove(ring, 1)
	end
	return event
end

function ns.NoteEvent(kind, fields)
	return ns.NoteEventFor(ns.GetChar(), kind, fields)
end

function ns.NoteRecentEvent(kind, fields)
	return ns.NoteRecentEventFor(ns.GetChar(), kind, fields)
end

function ns.AllEventsFor(record)
	if type(record) ~= "table" then
		return {}
	end
	Ensure(record)
	local merged, seen = {}, {}
	for _, event in ipairs(record.events.list) do
		if type(event) == "table" and event.id and not event.superseded and not seen[event.id] then
			seen[event.id] = true
			merged[#merged + 1] = event
		end
	end
	for _, event in ipairs(record.recentEvents) do
		if type(event) == "table" and event.id and not event.superseded and not seen[event.id] then
			seen[event.id] = true
			merged[#merged + 1] = event
		end
	end
	table.sort(merged, function(a, b)
		if (a.at or 0) ~= (b.at or 0) then
			return (a.at or 0) > (b.at or 0)
		end
		return (a.id or 0) > (b.id or 0)
	end)
	return merged
end

function ns.AllEvents(record)
	return ns.AllEventsFor(record or ns.GetChar())
end

function ns.RecentEventsFor(record)
	if type(record) ~= "table" then
		return {}
	end
	Ensure(record)
	local list = {}
	for index = #record.recentEvents, 1, -1 do
		local event = record.recentEvents[index]
		if type(event) == "table" and not event.superseded then
			list[#list + 1] = event
		end
	end
	return list
end

function ns.RecentEvents(record)
	return ns.RecentEventsFor(record or ns.GetChar())
end

local FIRST_LABELS = {
	profession = "First profession",
	professionDropped = "First profession dropped",
	quest = "First quest",
	boss = "First boss",
	raidBoss = "First raid boss",
	soloBoss = "First solo boss",
	eliteKill = "First elite kill",
	rareKill = "First rare kill",
	epicReceived = "First epic item",
	crafted = "First item crafted",
	craftedUncommon = "First uncommon crafted",
	craftedRare = "First rare crafted",
	epicCrafted = "First epic crafted",
	guild = "First guild",
	auctionSale = "First auction sale",
	auctionBuy = "First auction purchase",
	mount = "First mount",
}

local THRESHOLD_GROUPS = {
	quests = { label = "Quests completed", format = "number" },
	gold = { label = "Gold held", format = "money" },
	goldSpent = { label = "Gold spent", format = "money" },
	kills = { label = "Enemies killed", format = "number" },
	deaths = { label = "Deaths", format = "number" },
	dungeons = { label = "Dungeon runs", format = "number" },
	bosses = { label = "Bosses killed", format = "number" },
	loot = { label = "Items looted", format = "number" },
	crafted = { label = "Items crafted", format = "number" },
	distance = { label = "Distance walked", format = "distance" },
	recipes = { label = "Recipes learned", format = "number" },
	professionSkills = { label = "Profession skill", format = "number" },
}

local RECORD_LABELS = {
	["combat.bestFight"] = "Best fight",
	["combat.best10"] = "Best 10 minutes",
	["xp.bestWindow"] = "Best XP rate",
	["sessions.longest"] = "Longest session",
	["loot.bestFind"] = "Best find",
	["auction.bestSale"] = "Most valuable sale",
	["auction.bestBuy"] = "Most expensive purchase",
}

local function RecordValue(key, value)
	if key == "sessions.longest" then
		return ns.FormatDuration(value, true)
	elseif key == "xp.bestWindow" then
		return ns.FormatCompact(value).." XP/h"
	elseif key == "combat.bestFight" or key == "combat.best10" then
		return ns.FormatNumber(value)..(value == 1 and " kill" or " kills")
	elseif key == "loot.bestFind" or key == "auction.bestSale" or key == "auction.bestBuy" then
		return ns.MoneyString(value, 15)
	end
	return ns.FormatNumber(value)
end

local function ThresholdText(data)
	data = data or {}
	local group = THRESHOLD_GROUPS[data.group]
	local threshold = tonumber(data.threshold)
	if not group or not threshold then
		return ((data.group and tostring(data.group)) or "Milestone")..(threshold and (" "..tostring(threshold)) or "")
	end
	local formatted
	if group.format == "money" then
		formatted = ns.FormatMoneyBig(threshold)
	elseif group.format == "distance" then
		formatted = ns.FormatDistance(threshold * 1000)
	else
		formatted = ns.FormatNumber(threshold)
	end
	if data.group == "professionSkills" and data.key then
		return tostring(data.key).." skill "..formatted
	elseif data.group == "recipes" and data.key then
		return tostring(data.key).." recipes "..formatted
	end
	return group.label.." "..formatted
end

-- A short, plain line for the log. The tooltip carries the full context.
function ns.EventText(event)
	if type(event) ~= "table" then
		return "Event"
	end
	local data = event.data or {}
	local kind = event.kind or "event"
	if kind == "first" then
		local label = data.label or FIRST_LABELS[data.kind or ""] or "First"
		if data.name and data.name ~= label and not (data.kind == "quest" and type(data.name) == "string" and string.find(data.name, "^First")) then
			return label.." · "..tostring(data.name)
		end
		return label
	elseif kind == "threshold" then
		return ThresholdText(data)
	elseif kind == "level_up" then
		local text = "Level "..tostring(data.level or "?")..(data.partial and " (partial)" or "")
		if event.zone then
			text = text.." · "..tostring(event.zone)
		end
		return text
	elseif kind == "session" then
		local seconds = tonumber(data.seconds) or 0
		return "Session "..tostring(data.endedReason or "ended").." · "..ns.FormatDuration(seconds, true)
			..(data.durationKnown == false and " (at least)" or "")
	elseif kind == "kill" then
		return "Killed "..tostring(data.name or "?")
	elseif kind == "loot" then
		local count = tonumber(data.count) or 1
		return "Looted "..tostring(data.name or "?")..(count > 1 and (" x"..ns.FormatNumber(count)) or "")
	elseif kind == "money" then
		local delta = tonumber(data.delta) or 0
		return "Money "..tostring(data.category or "change").." "..ns.FormatMoneyDelta(delta)
	elseif kind == "zone" then
		return "Entered "..tostring(data.name or event.zone or "a zone")
	elseif kind == "quest" then
		return "Quest turned in"..(data.count and (" ("..tostring(data.count).." total)") or "")
	elseif kind == "craft" then
		local count = tonumber(data.count) or 1
		return "Crafted "..tostring(data.name or "?")..(count > 1 and (" x"..ns.FormatNumber(count)) or "")
		..(data.profession and (" · "..tostring(data.profession)) or "")
	elseif kind == "boss" then
		return "Boss · "..tostring(data.name or "?")
	elseif kind == "auction" then
		return "Auction "..tostring(data.action or "event")..(data.name and (" · "..tostring(data.name)) or "")
	elseif kind == "record" then
		local label = RECORD_LABELS[data.key] or tostring(data.key or "Record")
		return "New record · "..label..": "..RecordValue(data.key, tonumber(data.value) or 0)
	end
	return tostring(data.name or kind)
end

-- How a level-up's XP arrived. `experience` is the old fallback and is not a
-- cause; it is shown as "not recorded" so it does not pretend to be one.
function ns.LevelSourceText(source)
	if source == "quest" then
		return "quest"
	elseif source == "mob kill" then
		return "mob kill"
	elseif source == "exploration" or source == "discovery" then
		return "exploration"
	elseif source == "pvp" then
		return "PvP"
	elseif source == "unknown" or source == "experience" or source == nil then
		return "not recorded"
	end
	return tostring(source)
end

function ns.EventTip(event)
	if type(event) ~= "table" then
		return nil
	end
	local data = event.data or {}
	local lines = {
		{ text = "When: "..ns.FormatDateTime(event.at) },
		{ text = "Where: "..(event.zone or "not recorded") },
		{ text = "How: "..tostring(event.how or "unknown").."  ·  "..tostring(event.evidence or "unknown") },
		{ text = "Observed: "..tostring(event.observed or "unknown") },
	}
	if event.kind == "threshold" then
		lines[#lines + 1] = { text = "Crossed at: "..ns.FormatNumber(tonumber(data.value) or 0) }
	elseif event.kind == "level_up" then
		if data.total then
			lines[#lines + 1] = { text = "Lifetime played: "..ns.FormatDuration(data.total) }
		end
		if data.levelTime then
			lines[#lines + 1] = { text = "On this level: "..ns.FormatDuration(data.levelTime) }
		end
	elseif event.kind == "record" and data.previous ~= nil then
		lines[#lines + 1] = { text = "Previous: "..RecordValue(data.key, tonumber(data.previous) or 0) }
	elseif event.kind == "loot" and data.name then
		lines[#lines + 1] = { text = "Item: "..tostring(data.name).." x"..tostring(data.count or 1) }
	elseif event.kind == "kill" and data.name then
		lines[#lines + 1] = { text = "Creature: "..tostring(data.name) }
	elseif event.kind == "craft" and data.name then
		lines[#lines + 1] = { text = "Recipe: "..tostring(data.name)..(data.profession and (" · "..tostring(data.profession)) or "") }
	elseif event.kind == "session" and data.start then
		lines[#lines + 1] = { text = "Started: "..ns.FormatDateTime(data.start) }
		if data.stop then
			lines[#lines + 1] = { text = "Finished: "..ns.FormatDateTime(data.stop) }
		end
	end
	lines[#lines + 1] = { text = "Event #"..tostring(event.id) }
	return {
		kind = "note",
		title = ns.EventText(event),
		lines = lines,
		key = "event|"..tostring(event.id),
	}
end

-- Records are set once and only move when a real figure beats them. The value
-- is the current best, `at` is when it was set, and `previous` keeps the one
-- it replaced so a repair or a review can see what happened.
function ns.NoteRecordFor(record, key, value, at, data, higherIsBetter)
	if type(record) ~= "table" or not key or type(value) ~= "number" then
		return nil
	end
	Ensure(record)
	local old = record.records[key]
	local better
	if higherIsBetter == false then
		better = not old or value < (old.value or 0)
	else
		better = not old or value > (old.value or 0)
	end
	if not better then
		return old
	end
	at = at or ns.Now()
	local recordValue = {
		key = key, value = value, at = at,
		previous = old and old.value or nil,
	}
	record.records[key] = recordValue
	local event = ns.NoteEventFor(record, "record", {
		at = at, how = "record_set", evidence = "api_baseline",
		observed = "live",
		data = { key = key, value = value, previous = recordValue.previous },
	})
	if event then
		recordValue.event = event.id
	end
	return recordValue
end

function ns.NoteRecord(key, value, at, data, higherIsBetter)
	return ns.NoteRecordFor(ns.GetChar(), key, value, at, data, higherIsBetter)
end
