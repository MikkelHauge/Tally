-- Tally - versioned saved-data migrations.
--
-- Each step runs once, in order, when TallyDB.schemaVersion is lower. A step
-- is idempotent and checks the old one-time flag before doing its repair, so
-- an existing save that already ran the old repair does nothing here. The old
-- flags are left in place: an older build can still read the same data.
local addonName, ns = ...

local CURRENT_SCHEMA = 10
local MIGRATIONS = {}

-- 1: the minimap icon moved from a free position to the minimap's ring.
MIGRATIONS[1] = function(db)
	if (db.settings.icon.ringRevision or 0) < 2 then
		db.settings.icon.ringRevision = 2
		db.settings.icon.angle = 240
	end
end

-- 2: quest counts taken before only real turn-ins were counted.
MIGRATIONS[2] = function(db)
	if (db.questCountNote or 0) < 1 then
		-- Counts written before this build counted every QUEST_FINISHED, an
		-- event this client also raises for a quest that was only accepted or
		-- whose log entry changed, so a figure can be far too high. Those
		-- events cannot be told apart afterwards, so the counts start again
		-- from the builds that count real turn-ins only. Nothing else about a
		-- character's record is touched.
		db.questCountNote = 1
		local cleared = 0
		for _, record in pairs(db.chars or {}) do
			if (record.quests or 0) > 0 then
				cleared = cleared + record.quests
				record.quests = 0
			end
		end
		if cleared > 0 then
			ns.Trace("quests: "..cleared.." cleared from counts taken before turn-ins were counted")
		end
	end
end

-- 3: loot recorded before item qualities were tracked.
MIGRATIONS[3] = function(db)
	if (db.lootQualityNote or 0) < 1 then
		-- Migrates loot recorded before qualities were tracked. That loot
		-- is filed under quality 1 because its loot message carried no
		-- colour. Its per-item quality was never stored, so the pile
		-- cannot be split and is parked in qualityUnknown, still counted
		-- in "items looted". Stored best finds are the exception: each has
		-- an item id and a quality the item API confirms, so those counts
		-- move to their real buckets.
		db.lootQualityNote = 1
		local parked = 0
		for _, record in pairs(db.chars or {}) do
			local loot = record.loot
			if loot and type(loot.quality) == "table" then
				local unknown = loot.quality[1] or 0
				loot.quality[1] = 0
				local best = loot.best or {}
				for index = 1, #best do
					local entry = best[index]
					local count = entry and (entry.count or 1) or 0
					if entry and type(entry.quality) == "number" and count > 0 and unknown >= count then
						unknown = unknown - count
						loot.quality[entry.quality] = (loot.quality[entry.quality] or 0) + count
					end
				end
				loot.qualityUnknown = unknown
				parked = parked + unknown
			end
		end
		ns.Trace("loot quality: "..parked.." earlier items parked as quality-unknown")
	end
end

-- 4: combat-log kills that carried no first, last or zone.
MIGRATIONS[4] = function(db)
	if (db.killNote or 0) < 1 then
		-- Kills written from the combat log, when it was briefly on, carry no
		-- first/last/zone and cannot feed the open-world record. They are
		-- replaced once by a clean slate; every other statistic is untouched.
		db.killNote = 1
		local cleared = 0
		for _, record in pairs(db.chars or {}) do
			local combat = record.combat
			if combat then
				cleared = cleared + (combat.kills or 0)
				combat.kills = 0
				combat.killTypes = {}
				combat.killInfo = {}
				combat.killsByZone = {}
				combat.killSessions = 0
				combat.killingFights = 0
				combat.bestFight = 0
				combat.bestFightAt = nil
				combat.bestFightZone = nil
				combat.best10 = 0
				combat.best10At = nil
				combat.currentFightKills = 0
				combat.currentFightLastAt = nil
				combat.currentFightZone = nil
				combat.inFight = false
				combat.killsHeard = false
				combat.logHeard = false
				combat.killsAvailable = false
				combat.killBaseFights = combat.fights or 0
				combat.killBaseCombat = combat.combatSeconds or 0
				combat.killBaseTracked = record.tracked or 0
				if record.sessions and record.sessions.current then
					record.sessions.current.kills = 0
				end
			end
		end
		if cleared > 0 then
			ns.Trace("kills: "..cleared.." old combat-log kills cleared for the nameplate record")
		end
	end
end

-- 5: the data-model labels. This step does not invent a date or a place. It
-- normalises the old boolean/string observed values, labels records whose
-- writer is known, stamps existing crossings, and removes two kinds of data
-- that were stored under the wrong identity:
--   * CastBar-* rows in the crafted tally (a cast frame name, not a recipe);
--   * auction ids stored where an item id belongs (the old snapshot passed the
--     posting's id to the item row).
MIGRATIONS[5] = function(db)
	db.dataModelNote = 1
	local function Table(value)
		return type(value) == "table" and value or {}
	end
	local function label(entry, how, evidence, observed, trueValue, falseValue)
		if type(entry) ~= "table" then
			return
		end
		if entry.observed == true then
			entry.observed = trueValue or "live"
		elseif entry.observed == false then
			entry.observed = falseValue or "unknown"
		elseif type(entry.observed) ~= "string" then
			entry.observed = observed
		end
		if entry.how == nil and how then
			entry.how = how
		end
		if entry.evidence == nil and evidence then
			entry.evidence = evidence
		end
		if entry.at and entry.updatedAt == nil then
			entry.updatedAt = entry.at
		end
	end
	for _, record in pairs(db.chars or {}) do
		if type(record.meta) ~= "table" then
			record.meta = {}
		end
		if type(record.meta.stamps) ~= "table" then
			record.meta.stamps = {}
		end
		local milestones = record.milestones
		if type(milestones) == "table" then
			for _, entry in pairs(Table(milestones.firsts)) do
				label(entry, "milestone_first", "unknown", "migration")
			end
			for _, group in pairs(Table(milestones.thresholds)) do
				if type(group) == "table" then
					for _, key in pairs(group) do
						if type(key) == "table" then
							for _, crossing in pairs(key) do
								label(crossing, "milestone_threshold", "unknown", "live", "login", "unknown")
							end
						end
					end
				end
			end
			for _, set in pairs(Table(milestones.fullSets)) do
				label(set, "item_equipped", "inventory_scan", "migration", "login", "unknown")
			end
			for _, entry in pairs(Table(milestones.firstSlot)) do
				label(entry, "item_equipped", "inventory_scan", "migration", "login", "live")
			end
			for _, bySlot in pairs(Table(milestones.firstEquip)) do
				if type(bySlot) == "table" then
					for _, entry in pairs(bySlot) do
						label(entry, "item_equipped", "inventory_scan", "migration", "login", "live")
					end
				end
			end
			for _, entry in pairs(Table(milestones.firstWeapon)) do
				label(entry, "item_equipped", "inventory_scan", "migration")
			end
			label(milestones.firstGroup, "group_joined", "group_event", "migration")
			for _, entry in pairs(Table(milestones.firstGroupByClass)) do
				label(entry, "group_joined", "group_event", "migration")
			end
			label(milestones.firstMount, "mount_summoned", "spell_cast", "migration")
			for _, entry in pairs(Table(milestones.riding)) do
				label(entry, "riding_skill", "chat_skill", "migration")
			end
		end
		-- Remove the CastBar rows and take their counts back out of the
		-- profession totals, so the craft count is not left inflated.
		local store = record.professions
		if type(store) == "table" then
			for _, skill in ipairs(Table(store.skills)) do
				if type(skill) == "table" then
					skill.lastSeenAt = skill.lastSeenAt or skill.at
					skill.updatedAt = skill.updatedAt or skill.at
					if skill.observed == true then
						skill.observed = "live"
					elseif skill.observed == false then
						skill.observed = "unknown"
					elseif skill.observed == nil then
						skill.observed = "login"
					end
					skill.evidence = skill.evidence or "login_snapshot"
				end
			end
			for _, book in pairs(Table(store.recipes)) do
				if type(book) == "table" then
					book.updatedAt = book.updatedAt or book.at
					book.lastSeenAt = book.lastSeenAt or book.at
					book.evidence = book.evidence or "trade_skill_window"
				end
			end
		end
		if type(store) == "table" and type(store.crafted) == "table" then
			for name, tally in pairs(store.crafted) do
				if type(name) == "string" and string.find(name, "^CastBar%-") then
					local profession = type(tally) == "table" and tally.profession or nil
					if profession and type(store.crafts) == "table" and store.crafts[profession] then
						store.crafts[profession] = math.max(0, (store.crafts[profession] or 0) - (tally.count or 0))
					end
					store.crafted[name] = nil
				end
			end
		end
		-- An auction id is not an item id. The old snapshot wrote the posting
		-- id into the item row; anything above 100 million is that mistake.
		local ah = record.ah
		if type(ah) == "table" then
			local function fixID(entry)
				if type(entry) == "table" and type(entry.id) == "number" and entry.id > 100000000 then
					entry.id = nil
				end
			end
			fixID(ah.best)
			fixID(ah.bestBuy)
			for _, entry in pairs(Table(ah.items)) do
				fixID(entry)
			end
			for _, entry in pairs(Table(ah.recent)) do
				fixID(entry)
			end
			for _, entry in pairs(Table(ah.buys)) do
				fixID(entry)
			end
		end
		-- Sessions written before the end metadata existed keep their start;
		-- the end is labelled unknown rather than treated as a clean logout.
		local sessions = record.sessions
		if type(sessions) == "table" then
			for _, session in ipairs(Table(sessions.history)) do
				if type(session) == "table" then
					session.lastSeenAt = session.lastSeenAt or session.stop or session.start
					session.endedObserved = session.endedObserved == true
					session.endedReason = session.endedReason or "unknown"
					session.durationKnown = session.durationKnown == true
				end
			end
			local current = sessions.current
			if type(current) == "table" then
				current.lastSeenAt = current.lastSeenAt or current.last
				current.endedObserved = current.endedObserved == true
				current.durationKnown = current.durationKnown == true
			end
		end
		-- The first reading is anchored by the earliest session, which is the
		-- only exact timestamp already stored for it.
		local gold = record.gold
		if type(gold) == "table" and gold.firstAt == nil then
			local sessions = record.sessions
			local first = sessions and sessions.history and sessions.history[1]
			local start = first and first.start or (sessions and sessions.current and sessions.current.start)
			if start then
				gold.firstAt = start
				gold.firstSource = "session_start"
				gold.firstEvidence = "money_poll"
			end
		end
		-- Kills and deaths have exact first/last evidence in their own logs.
		local combat = record.combat
		if type(combat) == "table" then
			local firstAt, lastAt
			for _, info in pairs(Table(combat.killInfo)) do
				if type(info) == "table" then
					if info.first and (not firstAt or info.first < firstAt) then
						firstAt = info.first
					end
					if info.last and (not lastAt or info.last > lastAt) then
						lastAt = info.last
					end
				end
			end
			if firstAt and combat.killsFirstAt == nil then
				combat.killsFirstAt = firstAt
			end
			if lastAt and combat.killsLastAt == nil then
				combat.killsLastAt = lastAt
			end
			local log = combat.deathLog
			if type(log) == "table" and #log > 0 then
				local first = log[1]
				local last = log[#log]
				if type(first) == "table" and first.at and combat.deathsFirstAt == nil then
					combat.deathsFirstAt = first.at
				end
				if type(last) == "table" and last.at and combat.deathsLastAt == nil then
					combat.deathsLastAt = last.at
				end
			end
		end
	end
end

-- 6: repair the totals left by the CastBar rows removed in schema 5. Those
-- rows belonged to the last open profession but did not store that field, so
-- their counts could not be taken back out of `crafts`. When one profession
-- remains, every old tally entry lacks `profession`, and the difference is
-- small, the known-recipe sum is the honest total. A large difference is a
-- pruned long tail and is left alone. This also gives old tally entries their
-- profession and dates the first unclassified change.
MIGRATIONS[6] = function(db)
	if db.craftTallyRepairNote then
		return
	end
	db.craftTallyRepairNote = 1
	for _, record in pairs(db.chars or {}) do
		local store = record.professions
		if type(store) == "table"
			and type(store.crafts) == "table" and type(store.crafted) == "table" then
			local professions = {}
			for profession in pairs(store.crafts) do
				professions[#professions + 1] = profession
			end
			local only = #professions == 1 and professions[1] or nil
			local sum, oldEntries = 0, 0
			for _, tally in pairs(store.crafted) do
				if type(tally) == "table" then
					sum = sum + (tally.count or 0)
					if tally.profession == nil then
						oldEntries = oldEntries + 1
					end
				end
			end
			if only then
				for _, tally in pairs(store.crafted) do
					if type(tally) == "table" and tally.profession == nil then
						tally.profession = only
					end
				end
				local total = store.crafts[only] or 0
				if oldEntries > 0 and sum > 0 and total > sum and (total - sum) <= 10 then
					ns.Trace("crafts: "..only.." "..total.." -> "..sum.." (old cast-bar rows were not attributed)")
					store.crafts[only] = sum
				end
			end
		end
		local gold = record.gold
		if type(gold) == "table" and type(gold.unclassified) == "table"
			and gold.unclassified.firstAt == nil then
			local first
			for _, tx in ipairs(gold.tx or {}) do
				if type(tx) == "table" and tx.c == "unclassified" and tx.t
					and (not first or tx.t < first) then
					first = tx.t
				end
			end
			if first then
				gold.unclassified.firstAt = first
			end
		end
		local milestones = record.milestones
		if type(milestones) == "table" then
			local function FixItemHow(entry)
				if type(entry) == "table" and entry.observed == "login" and entry.how == "item_equipped" then
					entry.how = "item_seen"
				end
			end
			for _, entry in pairs(milestones.firstSlot or {}) do
				FixItemHow(entry)
			end
			for _, bySlot in pairs(milestones.firstEquip or {}) do
				if type(bySlot) == "table" then
					for _, entry in pairs(bySlot) do
						FixItemHow(entry)
					end
				end
			end
			for _, entry in pairs(milestones.firstWeapon or {}) do
				FixItemHow(entry)
			end
			for _, set in pairs(milestones.fullSets or {}) do
				FixItemHow(set)
			end
		end
	end
end

-- 7: level spans. Every history entry already knows the moment the level was
-- reached (`at`); the next entry gives the moment it ended. The first entry has
-- no start unless the first-seen snapshot is for the same level, so it stays
-- nil rather than borrowing a date it never had.
MIGRATIONS[7] = function(db)
	if db.levelSpanNote then
		return
	end
	db.levelSpanNote = 1
	for _, record in pairs(db.chars or {}) do
		local history = record.levels and record.levels.history
		if type(history) == "table" then
			for index = 1, #history do
				local entry = history[index]
				if type(entry) == "table" then
					local nextEntry = history[index + 1]
					entry.endedAt = nextEntry and nextEntry.at or nil
					if index > 1 then
						entry.startedAt = entry.at
					end
					entry.observed = entry.observed or "migration"
				end
			end
		end
	end
end

-- 8: turn the old firsts, thresholds, level-ups and sessions into events, and
-- seed the record book from the best fields that already exist. Old dates and
-- zones are kept; a missing one stays missing.
MIGRATIONS[8] = function(db)
	if db.eventLogNote then
		return
	end
	db.eventLogNote = 1
	local function Note(record, kind, fields)
		if ns.NoteEventFor then
			return ns.NoteEventFor(record, kind, fields)
		end
		return nil
	end
	for _, record in pairs(db.chars or {}) do
		local milestones = record.milestones
		if type(milestones) == "table" then
			for kind, entry in pairs(milestones.firsts or {}) do
				if type(entry) == "table" and entry.event == nil and entry.at then
					entry.kind = entry.kind or kind
					local event = Note(record, "first", {
						at = entry.at, zone = entry.zone, zoneKind = entry.zoneKind,
						how = entry.how or "milestone_first",
						evidence = entry.evidence or "unknown",
						observed = entry.observed or "migration",
						data = entry,
					})
					if event then
						entry.event = event.id
					end
				end
			end
			for group, bucket in pairs(milestones.thresholds or {}) do
				if type(bucket) == "table" then
					for key, entry in pairs(bucket) do
						if type(entry) == "table" then
							for threshold, crossing in pairs(entry) do
								if type(crossing) == "table" and crossing.event == nil and crossing.at then
									local event = Note(record, "threshold", {
										at = crossing.at, zone = crossing.zone,
										how = crossing.how or "milestone_threshold",
										evidence = crossing.evidence or "unknown",
										observed = crossing.observed or "migration",
										data = {
											group = group, key = key,
											threshold = threshold, value = crossing.value,
										},
									})
									if event then
										crossing.event = event.id
									end
								end
							end
						end
					end
				end
			end
		end
		local history = record.levels and record.levels.history
		if type(history) == "table" then
			for _, entry in ipairs(history) do
				if type(entry) == "table" and entry.event == nil and entry.at then
					local event = Note(record, "level_up", {
						at = entry.at, zone = entry.zone, zoneKind = entry.zoneKind,
						how = "level_up", evidence = "level_event",
						observed = entry.observed or "migration",
						data = {
							level = entry.level, total = entry.total,
							levelTime = entry.levelTime, gap = entry.gap,
							partial = entry.partial,
							source = entry.source, sourceText = entry.sourceText,
						},
					})
					if event then
						entry.event = event.id
					end
				end
			end
		end
		local sessions = record.sessions
		if type(sessions) == "table" and type(sessions.history) == "table" then
			for _, entry in ipairs(sessions.history) do
				if type(entry) == "table" and entry.event == nil and entry.start then
					local event = Note(record, "session", {
						at = entry.stop or entry.lastSeenAt or entry.start,
						zone = entry.endZone or entry.startZone,
						how = entry.endedReason == "logout" and "logout" or "disconnect",
						evidence = "login_snapshot",
						observed = entry.endedObserved and "live" or "migration",
						data = {
							start = entry.start, stop = entry.stop,
							seconds = entry.seconds, endedReason = entry.endedReason,
							durationKnown = entry.durationKnown,
						},
					})
					if event then
						entry.event = event.id
					end
				end
			end
		end
		if type(record.records) ~= "table" then
			record.records = {}
		end
		local function Seed(key, value, at, higherIsBetter)
			if type(value) ~= "number" or value <= 0 then
				return
			end
			local old = record.records[key]
			if old then
				local oldValue = tonumber(old.value) or 0
				if (higherIsBetter == false and oldValue <= value)
					or (higherIsBetter ~= false and oldValue >= value) then
					return
				end
			end
			record.records[key] = {
				key = key, value = value, at = at or record.created,
				observed = "migration",
			}
		end
		local combat = record.combat or {}
		Seed("combat.bestFight", combat.bestFight, combat.bestFightAt)
		Seed("combat.best10", combat.best10, combat.best10At)
		local xp = record.xp or {}
		if type(xp.bestWindow) == "table" then
			Seed("xp.bestWindow", xp.bestWindow.rate, xp.bestWindow.at)
		end
		local longestSeconds, longestStart
		for _, session in ipairs((sessions and sessions.history) or {}) do
			if type(session) == "table" and (session.seconds or 0) > (longestSeconds or 0) then
				longestSeconds = session.seconds
				longestStart = session.start
			end
		end
		Seed("sessions.longest", longestSeconds, longestStart)
		local bestFind
		for _, find in ipairs((record.loot and record.loot.best) or {}) do
			if type(find) == "table" and (find.value or 0) > (bestFind and bestFind.value or 0) then
				bestFind = find
			end
		end
		if bestFind then
			Seed("loot.bestFind", bestFind.value, bestFind.at)
		end
		local ah = record.ah or {}
		if type(ah.best) == "table" then
			Seed("auction.bestSale", ah.best.price, ah.best.at)
		end
		if type(ah.bestBuy) == "table" then
			Seed("auction.bestBuy", ah.bestBuy.price, ah.bestBuy.at)
		end
	end
end

-- 9: level events created before the source was put into the event data now
-- borrow it from the level-history entry. Nothing is invented; only a value
-- that already exists in the history is copied.
MIGRATIONS[9] = function(db)
	if db.levelEventNote then
		return
	end
	db.levelEventNote = 1
	for _, record in pairs(db.chars or {}) do
		local history = record.levels and record.levels.history
		local events = record.events and record.events.list
		if type(history) == "table" and type(events) == "table" then
			local byID = {}
			for _, event in ipairs(events) do
				if type(event) == "table" and event.id then
					byID[event.id] = event
				end
			end
			for _, entry in ipairs(history) do
				local event = type(entry) == "table" and entry.event and byID[entry.event] or nil
				if event and event.kind == "level_up" and type(event.data) == "table" then
					event.data.source = event.data.source or entry.source
					event.data.sourceText = event.data.sourceText or entry.sourceText
					event.data.total = event.data.total or entry.total
					event.data.levelTime = event.data.levelTime or entry.levelTime
					event.data.gap = event.data.gap or entry.gap
					event.data.partial = event.data.partial or entry.partial
					event.zone = event.zone or entry.zone
					event.zoneKind = event.zoneKind or entry.zoneKind
				end
			end
		end
	end
end

-- 10: the login cooldown check now runs fifteen seconds after entering the
-- world. 20 was the old default, so a save still on it moves to the new one;
-- any other value was chosen by the player and is left alone.
MIGRATIONS[10] = function(db)
	local settings = db.settings and db.settings.professionNotify
	if type(settings) == "table" and settings.loginDelay == 20 then
		settings.loginDelay = 15
	end
end

function ns.RunMigrations(db)
	local from = db.schemaVersion or 0
	if from >= CURRENT_SCHEMA then
		return
	end
	for version = from + 1, CURRENT_SCHEMA do
		local ok, err = pcall(MIGRATIONS[version], db)
		if not ok then
			ns.Trace("schema: migration "..version.." failed: "..tostring(err))
			ns.Print("Tally could not finish updating its saved data; the old figures are unchanged.")
			return
		end
		db.schemaVersion = version
		ns.Trace("schema: migrated to "..version)
	end
end

function ns.SchemaVersion()
	return ns.db and ns.db.schemaVersion or 0
end

ns.SCHEMA_VERSION = CURRENT_SCHEMA
ns.migrations = {}
ns.migrations.Run = ns.RunMigrations
ns.migrations.SchemaVersion = ns.SchemaVersion
ns.migrations.Current = ns.SCHEMA_VERSION
