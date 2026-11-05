-- Tally - professions: skills, recipe books, cooldowns, crafts and the
-- profession events that feed them.
--
-- One character subtree is owned here: char.professions. The page reads it
-- through ns; Core delegates the profession events to HandleProfessionEvent.
local addonName, ns = ...

local Now = ns.Now

-- The three secondary professions this game has. Archaeology is ignored even
-- if an old record still carries it.
local SECONDARY_PROFESSIONS = { "Cooking", "Fishing", "First Aid" }
local SECONDARY_ORDER = { Cooking = 1, Fishing = 2, ["First Aid"] = 3 }
local IGNORED_PROFESSIONS = { Archaeology = true }
-- These are the profession skill lines Classic's fallback is allowed to read.
-- Weapons and languages are deliberately absent, so they can never become a
-- profession; the list is the matrix the UI shows.
local SKILL_LINE_PROFESSIONS = {
	Cooking = true, Fishing = true, ["First Aid"] = true,
	Mining = true, Herbalism = true, Skinning = true,
}

-- Retail keeps the old-world profession lines beside the modern ones and
-- calls them "Classic Cooking" and so on. Tally's cards know the plain names,
-- so map the aliases before a reading is stored. On Classic these names never
-- appear and the map is unused.
local PROFESSION_ALIASES = {
	["Classic Alchemy"] = "Alchemy",
	["Classic Blacksmithing"] = "Blacksmithing",
	["Classic Cooking"] = "Cooking",
	["Classic Enchanting"] = "Enchanting",
	["Classic Engineering"] = "Engineering",
	["Classic Fishing"] = "Fishing",
	["Classic Herbalism"] = "Herbalism",
	["Classic Inscription"] = "Inscription",
	["Classic Jewelcrafting"] = "Jewelcrafting",
	["Classic Leatherworking"] = "Leatherworking",
	["Classic Mining"] = "Mining",
	["Classic Skinning"] = "Skinning",
	["Classic Tailoring"] = "Tailoring",
}
local aliasTraced = {}

local function CanonicalProfessionName(name)
	if type(name) ~= "string" then
		return name
	end
	local canonical = PROFESSION_ALIASES[name]
	if canonical then
		if not aliasTraced[name] and ns.Trace then
			aliasTraced[name] = true
			ns.Trace("profession alias: "..name.." -> "..canonical)
		end
		return canonical
	end
	return name
end

-- The four Classic/Forever profession ranks. `level` is the level needed to
-- learn that rank; Apprentice has no requirement and 300 is the last cap.
local PROFESSION_RANKS = {
	{ name = "Apprentice", from = 1, to = 75, level = 0, nextLevel = 10, nextName = "Journeyman" },
	{ name = "Journeyman", from = 75, to = 150, level = 10, nextLevel = 20, nextName = "Expert" },
	{ name = "Expert", from = 150, to = 225, level = 20, nextLevel = 35, nextName = "Artisan" },
	{ name = "Artisan", from = 225, to = 300, level = 35 },
}

local function RankTier(rank)
	rank = tonumber(rank) or 0
	for index = 1, #PROFESSION_RANKS do
		if rank <= PROFESSION_RANKS[index].to then
			return PROFESSION_RANKS[index]
		end
	end
	return PROFESSION_RANKS[#PROFESSION_RANKS]
end

-- The rank whose cap is exactly this number. RankTier(75) answers Journeyman,
-- because 75 is inside that rank's range; a character sitting at 75/75 is
-- still an Apprentice at its cap and must be told that, not told about the
-- Journeyman cap at 150.
local function TierByCap(cap)
	cap = tonumber(cap) or 0
	for index = 1, #PROFESSION_RANKS do
		if PROFESSION_RANKS[index].to == cap then
			return PROFESSION_RANKS[index]
		end
	end
	return nil
end

local function IsSecondary(name)
	return SECONDARY_ORDER[name] ~= nil
end

local function IsIgnored(name)
	return IGNORED_PROFESSIONS[name] == true
end

local function SecondaryOrder(name)
	return SECONDARY_ORDER[name]
end

-- Professions
-------------------------------------------------------------------------------

-- Profession data kept per character, created on first use:
--   skills  - the client's own list, re-read at login and on each skill-up:
--             { { name, rank, maxRank, at }, ... }
--   crafts  - successfully crafted items, per profession name:
--             { ["Tailoring"] = 132, ... }
--   crafted - the same crafts tallied per recipe:
--             { ["Bolt of Linen Cloth"] = { name, itemID, quality, count } }
--   recipes - recipe names and the item each makes, read while a profession
--             window is open, the only time the client lists them:
--             { ["Tailoring"] = { at = stamp, list = { names... },
--                                 items = { [name] = itemID } } }
local function CleanCraftTally(store)
	if type(store) ~= "table" or type(store.crafted) ~= "table" then
		return
	end
	local removed = 0
	for name, tally in pairs(store.crafted) do
		if type(name) == "string" and string.find(name, "^CastBar%-") then
			local profession = type(tally) == "table" and tally.profession or nil
			if not profession and type(store.crafts) == "table" then
				local only
				for candidate in pairs(store.crafts) do
					if only then
						only = nil
						break
					end
					only = candidate
				end
				profession = only
			end
			if profession and type(store.crafts) == "table" and store.crafts[profession] then
				local tallyCount = type(tally) == "table" and (tonumber(tally.count) or 0) or 0
				store.crafts[profession] = math.max(0, (store.crafts[profession] or 0) - tallyCount)
			end
			store.crafted[name] = nil
			removed = removed + 1
		end
	end
	if removed > 0 then
		ns.Trace("craft: removed "..removed.." cast-bar rows from the crafted tally")
	end
end

local function EnsureProfessions(char)
	local store = char.professions
	if type(store) ~= "table" then
		store = {}
		char.professions = store
	end
	if type(store.skills) ~= "table" then
		store.skills = {}
	end
	if type(store.learned) ~= "table" then
		store.learned = {}
	end
	if type(store.byLevel) ~= "table" then
		store.byLevel = {}
	end
	if type(store.capWarned) ~= "table" then
		store.capWarned = {}
	end
	if type(store.capNearWarned) ~= "table" then
		store.capNearWarned = {}
	end
	if type(store.crafts) ~= "table" then
		store.crafts = {}
	end
	if type(store.recipes) ~= "table" then
		store.recipes = {}
	end
	if type(store.crafted) ~= "table" then
		store.crafted = {}
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
	if type(store.cooldownStats) ~= "table" then
		store.cooldownStats = {}
	end
	if type(store.disenchants) ~= "table" then
		store.disenchants = { count = 0 }
	end
	store.disenchants.count = tonumber(store.disenchants.count) or 0
	if type(store.enchantingByLevel) ~= "table" then
		store.enchantingByLevel = {}
	end
	CleanCraftTally(store)
	return store
end

-- The client reports only the seconds left, so a scan taken mid-cooldown
-- cannot know the total length. Keep the largest reading for the same
-- cooldown occurrence: the first sighting is usually near the start, and
-- every later scan is smaller. A ready time that jumped by more than ten
-- minutes is a new use, so its length starts over.
local function CooldownSpan(char, profession, name, readyAt, span)
	span = tonumber(span) or 0
	if span < 0 then
		span = 0
	end
	local store = char and char.professions
	local book = type(store) == "table" and store.recipes and store.recipes[profession]
	local old = type(book) == "table" and book.cooldowns and book.cooldowns[name]
	if type(old) == "table" and type(old.readyAt) == "number" and type(old.span) == "number"
		and math.abs(old.readyAt - readyAt) <= 600 then
		span = math.max(span, old.span)
	end
	return span
end

-- The total length, when the game can report it. C_Spell is the same source
-- Mastercraft and CraftSim use; the trade-skill call gives only the seconds
-- left, which made a 24-hour cooldown look like a few minutes after a later
-- scan.
local function SpellDuration(recipeID, fallback)
	if type(C_Spell) == "table" and type(C_Spell.GetSpellCooldown) == "function" then
		local ok, info = pcall(C_Spell.GetSpellCooldown, recipeID)
		if ok and type(info) == "table" and type(info.duration) == "number" and info.duration > 0 then
			return info.duration
		end
	end
	if type(GetSpellCooldown) == "function" then
		local ok, start, duration = pcall(GetSpellCooldown, recipeID)
		if ok and type(duration) == "number" and duration > 0 then
			return duration
		end
	end
	return fallback
end

-- Writes one cooldown reading into the profession subtree. The cooldown
-- scanner in Core/92 uses this so the saved data still has one owner.
function ns.SetProfessionCooldown(profession, name, recipeID, readyAt, span, itemID)
	local char = ns.GetChar()
	if not char or not profession or not name then
		return
	end
	local store = EnsureProfessions(char)
	local book = store.recipes[profession]
	if type(book) ~= "table" then
		book = {}
		store.recipes[profession] = book
	end
	if type(book.cooldowns) ~= "table" then
		book.cooldowns = {}
	end
	local old = book.cooldowns[name]
	span = tonumber(span) or 0
	if span <= 0 and type(old) == "table" and type(old.span) == "number" then
		span = old.span
	end
	local now = Now()
	local active = type(readyAt) == "number" and readyAt > now
	local total = active and CooldownSpan(char, profession, name, readyAt, span) or span
	local key = "recipe:"..profession..":"..name
	local stats = store.cooldownStats[key]
	if type(stats) ~= "table" then
		stats = { uses = 0, offSeconds = 0, longestOff = 0, onSeconds = 0 }
		store.cooldownStats[key] = stats
	end
	stats.name = name
	stats.profession = profession
	stats.span = total > 0 and total or stats.span
	stats.itemID = itemID or (type(old) == "table" and old.itemID) or stats.itemID
	if stats.itemID then
		local _, _, quality = ns.ItemInfo(stats.itemID)
		stats.quality = quality or stats.quality
	end
	local wasActive = type(old) == "table" and type(old.readyAt) == "number" and old.readyAt > now
	if not active and not stats.offSince then
		-- A cooldown that was running has just finished at old.readyAt; count
		-- the off time from then, not from whenever this scan happened.
		if type(old) == "table" and type(old.readyAt) == "number" and old.readyAt > 0 and old.readyAt <= now then
			stats.offSince = old.readyAt
		else
			stats.offSince = now
		end
	end
	if active then
		local oldStarted = type(old) == "table" and old.startedAt or nil
		local newStarted = readyAt - total
		local newUse = not wasActive or not oldStarted or math.abs(newStarted - oldStarted) > 60
		if newUse then
			-- If no scan caught the ready moment, the old entry's ready time
			-- is still the end of the off stretch.
			if not stats.offSince and type(old) == "table" and type(old.readyAt) == "number"
				and old.readyAt > 0 and old.readyAt <= now then
				stats.offSince = old.readyAt
			end
			if stats.offSince then
				local offEnd = total > 0 and newStarted or now
				local off = math.max(0, offEnd - stats.offSince)
				stats.offSeconds = (stats.offSeconds or 0) + off
				if off > (stats.longestOff or 0) then
					stats.longestOff = off
				end
				if stats.shortestOff == nil or off < stats.shortestOff then
					stats.shortestOff = off
				end
				stats.offSince = nil
			end
			stats.uses = (stats.uses or 0) + 1
			stats.onSeconds = (tonumber(stats.onSeconds) or 0) + total
			stats.lastUsedAt = now
		end
		stats.offSince = nil
	end
	if active then
		book.cooldowns[name] = {
			readyAt = readyAt,
			span = total,
			startedAt = readyAt - total,
			itemID = itemID or (type(old) == "table" and old.itemID) or nil,
			recipeID = recipeID or (type(old) == "table" and old.recipeID) or nil,
			profession = profession,
		}
	else
		-- Ready: keep the total length if the game still reports one, and
		-- leave a reading the board can show without inventing a cooldown.
		local entry = type(old) == "table" and old or {}
		entry.readyAt = 0
		entry.span = span > 0 and span or entry.span
		entry.itemID = itemID or entry.itemID
		entry.recipeID = recipeID or entry.recipeID
		entry.profession = profession
		-- Keep startedAt: it identifies the use that has just finished, so
		-- the ready notification still has a marker to compare against.
		book.cooldowns[name] = entry
	end
end

local function CapMessagesEnabled()
	local notify = ns.ProfessionNotify
	if notify and notify.Settings then
		local settings = notify.Settings()
		if settings and settings.caps == false then
			return false
		end
	end
	return true
end

local function PlayCapChime()
	if ns.ProfessionNotify and ns.ProfessionNotify.PlayChime then
		ns.ProfessionNotify.PlayChime()
	end
end

local function CheckCapWarning(store, name, newRank, maxRank, level)
	if not CapMessagesEnabled() then
		return
	end
	if not (ns.MerchantsFavorAvailable and ns.MerchantsFavorAvailable()) then
		return
	end
	local tier = TierByCap(newRank)
	if not tier or not tier.nextLevel then
		return
	end
	-- The player has already trained past this cap; the message would be stale.
	if (tonumber(maxRank) or 0) > tier.to then
		return
	end
	if type(store.capWarned) ~= "table" then
		store.capWarned = {}
	end
	local warned = store.capWarned[name]
	if warned and newRank < warned then
		store.capWarned[name] = nil
		warned = nil
	end
	if warned == tier.to then
		return
	end
	store.capWarned[name] = tier.to
	if level >= tier.nextLevel then
		ns.Print("Your "..name.." skill is at its cap of "..tier.to.."/"..tier.to..". Visit your "..name.." trainer.")
	else
		ns.Print("Your "..name.." skill is at its cap of "..tier.to.."/"..tier.to..". Reach level "..tier.nextLevel..", then visit your "..name.." trainer.")
	end
	ns.Trace("profession cap: "..name.." "..tier.to.."/"..tier.to.." at level "..level)
	PlayCapChime()
end

-- Twenty-five points before a rank's cap the trainer can raise the ceiling,
-- provided the character is high enough level. No message at 275: Artisan has
-- no next rank, so there is nothing to train.
local function CheckNearCapWarning(store, name, oldRank, newRank, maxRank, level)
	if not CapMessagesEnabled() then
		return
	end
	if not (ns.MerchantsFavorAvailable and ns.MerchantsFavorAvailable()) then
		return
	end
	local tier = TierByCap(maxRank) or RankTier(newRank)
	if not tier or not tier.nextLevel then
		return
	end
	local threshold = tier.to - 25
	if newRank < threshold or oldRank >= threshold or newRank >= tier.to then
		return
	end
	if (tonumber(maxRank) or 0) > tier.to then
		return
	end
	if type(store.capNearWarned) ~= "table" then
		store.capNearWarned = {}
	end
	local warned = store.capNearWarned[name]
	if warned and newRank < warned - 25 then
		store.capNearWarned[name] = nil
		warned = nil
	end
	if warned == tier.to then
		return
	end
	store.capNearWarned[name] = tier.to
	if level >= tier.nextLevel then
		ns.Print("Your "..name.." skill is nearing its cap of "..tier.to..". Visit your "..name.." trainer.")
	else
		ns.Print("Your "..name.." skill is nearing its cap of "..tier.to..". At level "..tier.nextLevel..", visit your "..name.." trainer.")
	end
	ns.Trace("profession near cap: "..name.." "..newRank.."/"..tier.to.." at level "..level)
	PlayCapChime()
end

-- Thirty seconds after the level that opens a rank, remind only the
-- professions that are already within 25 points of that rank's skill cap and
-- have not been trained past it yet.
local function CheckLevelTrainerReminder(level)
	level = tonumber(level) or 0
	if level ~= 10 and level ~= 20 and level ~= 35 then
		return
	end
	if not CapMessagesEnabled() then
		return
	end
	if not (ns.MerchantsFavorAvailable and ns.MerchantsFavorAvailable()) then
		return
	end
	local char = ns.GetChar and ns.GetChar() or nil
	if not char then
		return
	end
	local store = EnsureProfessions(char)
	local lines = {}
	for _, skill in ipairs(store.skills or {}) do
		local name = CanonicalProfessionName(skill.name)
		local rank = tonumber(skill.rank) or 0
		local maxRank = tonumber(skill.maxRank) or 0
		local tier = TierByCap(maxRank) or RankTier(rank)
		if tier and tier.nextLevel == level
			and rank >= tier.to - 25
			and rank <= tier.to then
			lines[#lines + 1] = "Your "..name.." skill ("..rank.."/"..tier.to
				..") can be trained to "..tier.nextName..". Visit your "..name.." trainer."
		end
	end
	if #lines == 0 then
		return
	end
	for index = 1, #lines do
		ns.Print(lines[index])
	end
	ns.Trace("profession trainer reminder: level "..level.." ("..#lines..")")
	PlayCapChime()
end

-- One live skill-up, credited to the character level it happened at. The
-- login snapshot and the first-ever reading never reach here, so a character
-- met at rank 300 does not appear to have gained it at level 12.
local function NoteSkillGain(char, store, name, gained, at)
	gained = tonumber(gained) or 0
	if gained <= 0 or not name then
		return
	end
	local level = 0
	if type(UnitLevel) == "function" then
		local ok, value = pcall(UnitLevel, "player")
		level = ok and (tonumber(value) or 0) or 0
	end
	if level <= 0 then
		level = tonumber(char and char.level) or 0
	end
	if level <= 0 then
		return
	end
	if type(store.byLevel) ~= "table" then
		store.byLevel = {}
	end
	local row = store.byLevel[level]
	if type(row) ~= "table" then
		row = {}
		store.byLevel[level] = row
	end
	row[name] = (tonumber(row[name]) or 0) + gained
	local skill
	for index = 1, #store.skills do
		local candidate = store.skills[index]
		if type(candidate) == "table" and CanonicalProfessionName(candidate.name) == name then
			skill = candidate
			break
		end
	end
	if skill then
		local oldRank = tonumber(skill.rank) or 0
		local newRank = oldRank + gained
		local maxRank = tonumber(skill.maxRank) or 0
		CheckNearCapWarning(store, name, oldRank, newRank, maxRank, level)
		CheckCapWarning(store, name, newRank, maxRank, level)
	end
	ns.Trace("profession skill: "..name.." +"..gained.." at level "..level)
end

-- Writes one profession reading into the skill list. The window scans and the
-- Classic skill-line fallback both use it, because Classic has no
-- GetProfessions/GetProfessionInfo. Existing first-seen stamps are kept; only
-- the rank moves.
-- Records the level at which a profession's skill ceiling was raised. The
-- current maxRank alone cannot tell an old row what the cap was then; the
-- by-level view uses this history where it exists and falls back to the rank
-- path for records written before it was kept.
local function NoteCapChange(skill, oldMax, newMax, at)
	if type(skill) ~= "table" then
		return
	end
	oldMax = tonumber(oldMax) or 0
	newMax = tonumber(newMax) or 0
	if newMax <= oldMax then
		return
	end
	local level = (UnitLevel and UnitLevel("player"))
		or (ns.GetChar() and ns.GetChar().level) or 0
	local history = skill.capHistory
	if type(history) ~= "table" then
		history = {}
		skill.capHistory = history
	end
	local last = history[#history]
	if last and (tonumber(last.maxRank) or 0) == newMax then
		return
	end
	history[#history + 1] = {
		level = level, maxRank = newMax, at = at or Now(),
	}
end

-- Writes one profession reading into the skill list. The window scans and the
-- Classic skill-line fallback both use it, because Classic has no
-- GetProfessions/GetProfessionInfo. Existing first-seen stamps are kept; only
-- the rank moves.
local function RecordSkillReading(char, name, rank, maxRank, evidence, observed)
	if not char or not ns.Tracks("economy") then
		return false
	end
	if type(name) ~= "string" or name == "" then
		return false
	end
	name = CanonicalProfessionName(name)
	if type(rank) ~= "number" or type(maxRank) ~= "number" or maxRank <= 0 then
		return false
	end
	if rank < 0 or rank > maxRank then
		return false
	end
	local store = EnsureProfessions(char)
	local at = Now()
	local found
	for index = 1, #store.skills do
		if CanonicalProfessionName(store.skills[index].name) == name then
			found = store.skills[index]
			break
		end
	end
	if found then
		found.lastSeenAt = at
		if observed ~= "login" and type(found.rank) == "number" and rank < found.rank then
			-- A stale or alternate source must not lower a live rank. Retail
			-- reports the modern Cooking line (often rank 1) next to the
			-- classic line; the higher classic rank is the one being played.
			-- The login snapshot still resynchronises a genuinely lower rank.
			rank = found.rank
			if (tonumber(found.maxRank) or 0) > maxRank then
				maxRank = found.maxRank
			end
		end
		if observed ~= "login" and type(found.rank) == "number" and rank > found.rank then
			NoteSkillGain(char, store, name, rank - found.rank, at)
		end
		if maxRank > (tonumber(found.maxRank) or 0) then
			NoteCapChange(found, found.maxRank, maxRank, at)
		end
		if found.rank ~= rank or found.maxRank ~= maxRank then
			found.rank = rank
			found.maxRank = maxRank
			found.lastRankAt = at
			found.updatedAt = at
		end
		found.observed = found.observed or "live"
		found.evidence = found.evidence or evidence
	else
		found = {
			name = name, rank = rank, maxRank = maxRank, at = at,
			firstAt = at, lastSeenAt = at, lastRankAt = at, updatedAt = at,
			observed = "live", evidence = evidence or "trade_skill_window",
		}
		NoteCapChange(found, 0, maxRank, at)
		store.skills[#store.skills + 1] = found
	end
	if not store.learned[name] then
		local zone, zoneKind
		if ns.MilestoneContext then
			zone, zoneKind = ns.MilestoneContext()
		end
		store.learned[name] = {
			name = name,
			rank = rank,
			maxRank = maxRank,
			at = found.firstAt or at,
			zone = zone,
			zoneKind = zoneKind,
			observed = "live",
			how = "profession_learned",
			evidence = found.evidence,
			updatedAt = at,
		}
		ns.Trace("profession learned: "..name.." "..rank.."/"..maxRank)
	end
	store.at = at
	store.updatedAt = at
	return true
end

-- Reads the rank from the open profession window. Classic reports it only
-- there, and a craft can raise the rank while the window stays open; the
-- CHAT_MSG_SKILL path is not guaranteed to fire on every client.
local rankRefreshPending = false
local rankRefreshProfession

local function ReadOpenRank(char, expected)
	if not char or not ns.Tracks("economy") then
		return false
	end
	local name, rank, maxRank
	if type(GetTradeSkillLine) == "function" then
		local ok, named, current, maximum = pcall(GetTradeSkillLine)
		if ok and type(named) == "string" and named ~= "UNKNOWN"
			and type(current) == "number" and type(maximum) == "number" and maximum > 0 then
			name, rank, maxRank = named, current, maximum
		end
	end
	if not name and type(GetCraftDisplaySkillLine) == "function" then
		local ok, named, current, maximum = pcall(GetCraftDisplaySkillLine)
		if ok and type(named) == "string" and named ~= "UNKNOWN"
			and type(current) == "number" and type(maximum) == "number" and maximum > 0 then
			name, rank, maxRank = named, current, maximum
		end
	end
	if not name then
		return false
	end
	if expected then
		local got = CanonicalProfessionName(name)
		local want = CanonicalProfessionName(expected)
		if got ~= want then
			return false
		end
	end
	return RecordSkillReading(char, name, rank, maxRank, "open_window_rank", "live")
end

-- The craft event can arrive before the window has refreshed its rank, so
-- read once now and once just after. A single delayed read serves a burst of
-- crafts, and reading the same rank twice changes nothing.
local function ScheduleOpenRank(char, profession)
	ReadOpenRank(char, profession)
	rankRefreshProfession = profession
	if rankRefreshPending then
		return
	end
	rankRefreshPending = true
	local function Refresh()
		rankRefreshPending = false
		if ns.GetChar() == char then
			ReadOpenRank(char, rankRefreshProfession)
		end
	end
	if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
		C_Timer.After(0.5, Refresh)
	else
		Refresh()
	end
end

-- Classic's skill lines carry the same name/rank/max-rank as the modern
-- profession list, but they also list weapons and languages. Only names
-- Tally already learned from a profession window are accepted, so a weapon
-- skill can never appear as a profession. On clients with GetProfessions this
-- is never used.
local function SnapshotSkillLines(char, observed)
	if not char or type(GetNumSkillLines) ~= "function" or type(GetSkillLineInfo) ~= "function" then
		return 0
	end
	local store = EnsureProfessions(char)
	if type(store) ~= "table" then
		return 0
	end
	local known = {}
	for index = 1, #store.skills do
		local skill = store.skills[index]
		if skill and skill.name then
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
	for name in pairs(SKILL_LINE_PROFESSIONS) do
		known[name] = true
	end
	if next(known) == nil then
		return 0
	end
	local ok, count = pcall(GetNumSkillLines)
	if not ok or type(count) ~= "number" then
		return 0
	end
	local updated = 0
	for index = 1, count do
		local okLine, name, isHeader, _, rank, _, _, maxRank = pcall(GetSkillLineInfo, index)
		local canonical = CanonicalProfessionName(name)
		if okLine and canonical and not isHeader and known[canonical] then
			if RecordSkillReading(char, canonical, rank, maxRank, "skill_line", observed) then
				updated = updated + 1
			end
		end
	end
	return updated
end

-- Reads the client's profession list. A client that refuses records nothing
-- rather than a guess. Only name and ranks are kept: the recipe count the
-- client returns does not match what a profession window lists (engineering
-- returned 1 for nine recipes), so counts come from the window scans below.
local function SnapshotProfessions(char, observed)
	if not char or not ns.Tracks("economy") then
		return
	end
	observed = observed or "live"
	if not (GetProfessions and GetProfessionInfo) then
		-- Classic: the profession list is read from the skill lines instead.
		-- Only professions already met from a window are updated, so the
		-- weapon and language lines stay out of the profession cards.
		local updated = SnapshotSkillLines(char, observed)
		ns.Trace("professions: no GetProfessions/GetProfessionInfo; skill lines updated "..updated)
		return
	end
	local ok, skills = pcall(function()
		local found = {}
		local profs = { GetProfessions() }
		for index = 1, 7 do
			local profIndex = profs[index]
			if profIndex and profIndex > 0 then
				local name, _, rank, maxRank = GetProfessionInfo(profIndex)
				name = CanonicalProfessionName(name)
				if name then
					found[#found + 1] = {
						name = name,
						rank = rank or 0,
						maxRank = maxRank or 0,
						at = Now(),
					}
				end
			end
		end
		return found
	end)
	if not ok then
		ns.Trace("professions: the client refused the read ("..tostring(skills)..")")
		return
	end
	local store = char.professions
	if #skills == 0 and type(store) ~= "table" then
		-- Nothing to keep and nothing kept: do not create a record for it.
		return
	end
	store = EnsureProfessions(char)
	-- The client returns a fresh list, but the saved entries are where the
	-- first-seen and rank-change stamps live. Carry them across before the
	-- list is replaced.
	if #skills > 0 then
		local oldByName = {}
		for index = 1, #store.skills do
			local old = store.skills[index]
			if old and old.name then
				oldByName[old.name] = old
			end
		end
		for index = 1, #skills do
			local skill = skills[index]
			local at = skill.at or Now()
			local old = oldByName[skill.name]
			if observed ~= "login" and old and type(old.rank) == "number" and skill.rank < old.rank then
				-- Retail reports the modern Cooking line next to the classic
				-- one. A lower modern rank must not replace the classic rank
				-- the character is actually raising; the login snapshot still
				-- resynchronises a genuinely lower rank.
				skill.rank = old.rank
				if (tonumber(old.maxRank) or 0) > skill.maxRank then
					skill.maxRank = old.maxRank
				end
			end
			if old then
				skill.capHistory = old.capHistory
				if (tonumber(skill.maxRank) or 0) > (tonumber(old.maxRank) or 0) then
					NoteCapChange(skill, old.maxRank, skill.maxRank, at)
				end
			else
				NoteCapChange(skill, 0, skill.maxRank, at)
			end
			if observed ~= "login" and old and type(old.rank) == "number" and skill.rank > old.rank then
				NoteSkillGain(char, store, skill.name, skill.rank - old.rank, at)
			end
			skill.firstAt = old and old.firstAt or at
			skill.lastSeenAt = at
			local oldObserved = old and old.observed or nil
			if oldObserved == true then
				oldObserved = "live"
			elseif oldObserved == false then
				oldObserved = "unknown"
			end
			skill.observed = oldObserved or observed
			skill.evidence = observed == "login" and "login_snapshot" or "chat_skill"
			if old and old.rank == skill.rank and old.maxRank == skill.maxRank then
				skill.updatedAt = old.updatedAt or at
				skill.lastRankAt = old.lastRankAt or at
			else
				skill.updatedAt = at
				skill.lastRankAt = at
			end
			-- The first rank Tally ever saw for this profession, kept even if
			-- the profession is later dropped. It answers "Engineering 1/75"
			-- for a profession learned while Tally was running, and
			-- "Engineering 300/300" when Tally first met an already-trained
			-- character.
			if not store.learned[skill.name] then
				local zone, zoneKind
				if ns.MilestoneContext then
					zone, zoneKind = ns.MilestoneContext()
				end
				store.learned[skill.name] = {
					name = skill.name,
					rank = skill.rank,
					maxRank = skill.maxRank,
					at = skill.firstAt or at,
					zone = zone,
					zoneKind = zoneKind,
					observed = skill.observed,
					how = "profession_learned",
					evidence = skill.evidence,
					updatedAt = at,
				}
				ns.Trace("profession learned: "..skill.name.." "..skill.rank.."/"..skill.maxRank)
			end
		end
	end
	-- An empty answer when a list was recorded before is a stale client
	-- moment; the old list is kept.
	if #skills > 0 or #store.skills == 0 then
		store.skills = skills
		store.at = Now()
		store.updatedAt = store.at
	end
	-- A profession that is no longer on the character must not keep a
	-- cooldown or a notification toggle alive. Recipe history stays; only the
	-- transient cooldown and its settings go.
	if #skills > 0 then
		local current = {}
		for index = 1, #skills do
			current[skills[index].name] = true
			if ns.NoteProfessionFirst then
				ns.NoteProfessionFirst(skills[index].name, observed, skills[index].rank, skills[index].maxRank)
			end
			if ns.NoteProfessionSkill then
				ns.NoteProfessionSkill(skills[index].name, skills[index].rank, observed == "login")
			end
		end
		for name, entry in pairs(store.recipes) do
			if type(entry) == "table" and not current[name] then
				entry.cooldowns = nil
				if ns.NoteMilestoneFirst then
					ns.NoteMilestoneFirst("professionDropped", { name = name })
				end
			end
		end
		for key in pairs(store.notifyOff or {}) do
			local profession = string.match(key, "^recipe:([^:]+):")
			if profession and not current[profession] then
				store.notifyOff[key] = nil
			end
		end
		for key in pairs(store.notifyState or {}) do
			local profession = string.match(key, "^recipe:([^:]+):")
			if profession and not current[profession] then
				store.notifyState[key] = nil
			end
		end
		for itemID, entry in pairs(store.itemCooldowns or {}) do
			if type(entry) == "table" and entry.profession and not current[entry.profession] then
				store.itemCooldowns[itemID] = nil
				store.notifyOff["item:"..itemID] = nil
				store.notifyState["item:"..itemID] = nil
			end
		end
	end
	-- Retail's GetProfessions list does not include the old-world
	-- "Classic Cooking" style lines. Read the skill lines as well; at login
	-- this syncs their ranks silently, and on a live skill-up it records the
	-- gain under the plain profession name.
	local updatedLines = SnapshotSkillLines(char, observed)
	local parts = {}
	for index = 1, #skills do
		local skill = skills[index]
		parts[#parts + 1] = skill.name.." "..skill.rank.."/"..skill.maxRank
	end
	ns.Trace("professions: "..(#parts > 0 and table.concat(parts, " · ") or "none recorded")
		.."; skill lines updated "..updatedLines)
end

-- Quality the client holds for an item id, or nil when it has not been seen
-- yet. A nil leaves the name uncoloured rather than picking a colour.
local function ItemQualityOf(itemID)
	if not itemID then
		return nil
	end
	local name, _, quality = ns.ItemInfo(itemID)
	if name and quality then
		return quality
	end
	return nil
end

-- Recipe names, read from an open profession window. The open window also
-- decides where counted crafts go, and the name set distinguishes a craft
-- from an ordinary spell cast with the window open. Each recipe keeps the
-- item it makes, so a counted craft can carry the item's quality colour.
local tradeSkillOpen, craftOpen = false, false
local windowRecipes = {}
local windowRecipeIDs = {}
local lastWindowProfession
local pendingCraftSpell
local pendingCraftName

-- `total` is the number of recipes the profession has, learnt or not. Only
-- the modern client reports it, so it stays nil elsewhere and the card uses
-- the list length. `filtered` marks runs where the window's filter or search
-- box narrowed the list: `total` then covers only what was shown, and the
-- card labels it as such. `book` is one read: list (the learnt names), items
-- (name to the item it makes), ids (name to recipe ID), cats/catOf (the
-- client's categories and each recipe's own), line (the client's own id for
-- the profession) and total/filtered. Fields the read cannot see are nil.
local function KeepRecipeList(char, profession, book)
	local store = EnsureProfessions(char)
	lastWindowProfession = profession
	local entry = store.recipes[profession]
	if not entry then
		entry = {}
		store.recipes[profession] = entry
	end
	local list = book.list or {}
	entry.at = Now()
	-- A read happened. This is what lets the card say "no recipes found" for a
	-- gathering profession instead of asking for a window that has already
	-- been opened: the window was read and it holds nothing.
	entry.read = true
	entry.list = list
	if ns.NoteRecipeMilestone then
		ns.NoteRecipeMilestone(profession, #list)
	end
	entry.items = book.items or {}
	entry.ids = book.ids or {}
	-- The categories the client files the recipes under, in its own order,
	-- and the category each recipe belongs to. Absent from the reads that
	-- cannot see categories.
	entry.cats = book.cats
	entry.catOf = book.catOf
	-- The open window's recipe ids, so a successful cast can be recognised
	-- even when the client will not name the spell id it reports.
	windowRecipeIDs = {}
	for name, recipeID in pairs(entry.ids or {}) do
		local id = tonumber(recipeID)
		if id then
			windowRecipeIDs[id] = name
		end
	end
	-- The client's own id for the profession, so a later click can ask it to
	-- open that window.
	entry.line = book.line
	entry.total = book.total
	entry.filtered = book.filtered and true or nil
	windowRecipes = {}
	for index = 1, #list do
		windowRecipes[list[index]] = profession
	end
end

-- Expands every category before a scan, since a collapsed category hides its
-- recipes and a scan of a half-open tree would undercount. Returns which
-- header positions were expanded, for CloseTradeSkillTree to restore.
-- Headers are counted from the end, which survives the list shifting during
-- expansion.
-- The trade-skill list belongs to a window; asking after it closes returns
-- nil on this client, which would make the numeric for loop throw.
local function TradeSkillCount()
	if type(GetNumTradeSkills) ~= "function" then
		return 0
	end
	local ok, count = pcall(GetNumTradeSkills)
	if ok and type(count) == "number" then
		return count
	end
	return 0
end

local function OpenTradeSkillTree()
	local opened = {}
	local headers = 0
	for index = TradeSkillCount(), 1, -1 do
		local okInfo, _, skillType, _, isExpanded = pcall(GetTradeSkillInfo, index)
		if okInfo and (skillType == "header" or skillType == "subheader") then
			headers = headers + 1
			if not isExpanded and ExpandTradeSkillSubClass then
				pcall(ExpandTradeSkillSubClass, index)
				opened[headers] = true
			end
		end
	end
	return opened
end

local function CloseTradeSkillTree(opened)
	local headers = 0
	for index = TradeSkillCount(), 1, -1 do
		local okInfo, _, skillType = pcall(GetTradeSkillInfo, index)
		if okInfo and (skillType == "header" or skillType == "subheader") then
			headers = headers + 1
			if opened[headers] and CollapseTradeSkillSubClass then
				pcall(CollapseTradeSkillSubClass, index)
			end
		end
	end
end

-- True when the window's filter or search box narrows the list, which would
-- make a scan record a wrong count. The filter belongs to the player, so a
-- filtered window is skipped rather than changed.
local function TradeSkillFiltered()
	if GetTradeSkillSubClassFilter and not GetTradeSkillSubClassFilter(0) then
		return true
	end
	if GetTradeSkillInvSlotFilter and not GetTradeSkillInvSlotFilter(0) then
		return true
	end
	return false
end

-- Reads recipes from the trade skill window (every profession but
-- enchanting). Returns true once the list is recorded. The window needs a
-- moment to fill after opening, so a miss returns false and the caller
-- retries.
local function CaptureTradeSkillRecipes(char)
	if not (GetTradeSkillLine and GetNumTradeSkills and GetTradeSkillInfo) then
		-- Traced so an empty card has an answer in the log.
		ns.Trace("recipes: this client has no GetTradeSkillLine/GetNumTradeSkills/GetTradeSkillInfo")
		return false
	end
	if not char then
		return false
	end
	local ok, profession, rank, maxRank = pcall(GetTradeSkillLine)
	if not ok or not profession or profession == "UNKNOWN" then
		ns.Trace("recipes: the trade skill window did not name its profession yet ("..tostring(profession)..")")
		return false
	end
	-- The window names the profession and its rank directly, which is how a
	-- Classic client reports a profession at all. Recorded even for a
	-- gathering profession, whose list is empty.
	RecordSkillReading(char, profession, rank, maxRank, "trade_skill_window")
	if (GetNumTradeSkills() or 0) == 0 then
		-- The window named its profession and lists nothing: a gathering
		-- profession, or one still filling. Either way the read is recorded as
		-- empty and marked as read, so the card can say "no recipes found"
		-- rather than asking for a window that is already open; a later read
		-- with names in it replaces this one.
		ns.Trace("recipes: the "..profession.." window listed nothing")
		KeepRecipeList(char, profession, { list = {} })
		return true
	end
	if TradeSkillFiltered() then
		ns.Trace("recipes: "..profession.." has a filter set - left alone rather than recorded short")
		return true
	end
	local opened = OpenTradeSkillTree()
	local list, items, cooldowns = {}, {}, {}
	local okList = pcall(function()
		for index = 1, GetNumTradeSkills() do
			local name, skillType = GetTradeSkillInfo(index)
			if name and skillType ~= "header" and skillType ~= "subheader" then
				list[#list + 1] = name
				local itemID
				if GetTradeSkillItemLink then
					local okLink, link = pcall(GetTradeSkillItemLink, index)
					if okLink and link then
						itemID = tonumber(string.match(link, "item:(%d+)"))
						if itemID then
							items[name] = itemID
						end
					end
				end
				-- The trade-skill window reports the seconds left on a recipe
				-- directly. Only a real duration is kept; a client that
				-- refuses says nothing and the recipe stays untimed.
				if type(GetTradeSkillCooldown) == "function" then
					local okCooldown, remaining = pcall(GetTradeSkillCooldown, index)
					if okCooldown and type(remaining) == "number" and remaining > 0
						and remaining <= 31 * 24 * 60 * 60 then
						local readyAt = Now() + remaining
						local span = CooldownSpan(char, profession, name, readyAt, remaining)
						cooldowns[name] = {
							readyAt = readyAt,
							span = span,
							startedAt = readyAt - span,
							itemID = itemID,
							profession = profession,
						}
					end
				end
			end
		end
	end)
	CloseTradeSkillTree(opened)
	if not okList or #list == 0 then
		return false
	end
	KeepRecipeList(char, profession, { list = list, items = items })
	if next(cooldowns) then
		local store = EnsureProfessions(char)
		local entry = store.recipes[profession]
		if entry then
			entry.cooldowns = entry.cooldowns or {}
			for name, value in pairs(cooldowns) do
				entry.cooldowns[name] = value
			end
		end
	end
	ns.Trace("recipes: "..profession.." "..#list.." recipes read from the window")
	return true
end

-- Name to file the enchanter's recipes under. The craft API never names it,
-- so the stored skill list is searched for a name containing "nchant";
-- "Enchanting" is the fallback.
local function EnchantingName(char)
	local store = char.professions
	local skills = (type(store) == "table" and store.skills) or {}
	for index = 1, #skills do
		if string.find(skills[index].name or "", "nchant", 1, true) then
			return skills[index].name
		end
	end
	return "Enchanting"
end

local function CaptureCraftRecipes(char)
	if not GetCraftInfo then
		ns.Trace("recipes: this client has no GetCraftInfo (the enchanter's window)")
		return false
	end
	if not char then
		return false
	end
	local total
	if type(GetNumCrafts) == "function" then
		local ok, count = pcall(GetNumCrafts)
		if ok and type(count) == "number" then
			total = count
		end
	end
	if (not total or total == 0) and type(GetNumCraftSpells) == "function" then
		local ok, count = pcall(GetNumCraftSpells)
		if ok and type(count) == "number" then
			total = count
		end
	end
	if not total or total == 0 then
		ns.Trace("recipes: the craft window listed nothing yet")
		return false
	end
	local list = {}
	local items = {}
	local okList = pcall(function()
		for index = 1, total do
			local name, _, craftType = GetCraftInfo(index)
			if name and craftType ~= "header" and craftType ~= "subheader" then
				list[#list + 1] = name
				if GetCraftItemLink then
					local okLink, link = pcall(GetCraftItemLink, index)
					if okLink and link then
						local itemID = tonumber(string.match(link, "item:(%d+)"))
						if itemID then
							items[name] = itemID
						end
					end
				end
			end
		end
	end)
	if not okList or #list == 0 then
		return false
	end
	local profession = EnchantingName(char)
	if GetCraftDisplaySkillLine then
		local ok, named, rank, maxRank = pcall(GetCraftDisplaySkillLine)
		if ok and named and named ~= "UNKNOWN" then
			profession = named
			RecordSkillReading(char, named, rank, maxRank, "craft_window")
		end
	end
	KeepRecipeList(char, profession, { list = list, items = items })
	ns.Trace("recipes: "..profession.." "..#list.." recipes read from the craft window")
	return true
end

-- ---------------------------------------------------------------------------
-- Modern client recipe read (C_TradeSkillUI)
--
-- Clients built on this API removed the old trade skill globals and answer
-- through C_TradeSkillUI. This read is preferred: it returns the profession's
-- full recipe list, learnt and unlearnt, so a count reads "N of M recipes"
-- rather than whatever the window listed; each recipe names the item it
-- makes; a recipe on cooldown reports the time left; and each carries the
-- source the client recorded. The old reads above remain for clients without
-- this API.
--
-- The list is read from GetFilteredRecipeIDs, the call the client's own
-- window uses (Professions.GenerateCraftingDataProvider). GetAllRecipeIDs,
-- documented on the wiki, is absent here and is only a fallback. The open
-- profession is resolved through GetChildProfessionInfo, whose professionID
-- is 0 while no window is open; GetTradeSkillLine is absent here too and is
-- only a last resort for another client.
-- ---------------------------------------------------------------------------
local TradeSkillUI = type(C_TradeSkillUI) == "table" and C_TradeSkillUI or nil

local function HasModernRecipeRead()
	if not (TradeSkillUI and TradeSkillUI.GetRecipeInfo) then
		return false
	end
	return TradeSkillUI.GetFilteredRecipeIDs ~= nil or TradeSkillUI.GetAllRecipeIDs ~= nil
end

-- Recipe ids of the open window, plus the name of the call that answered.
-- GetFilteredRecipeIDs is tried first (it is what the client's own window
-- uses and it respects the window's filters, hence the filtered flag below);
-- GetAllRecipeIDs is the fallback. Returns ids, callName or nil, nil.
local function ModernRecipeIDs()
	if not TradeSkillUI then
		return nil, nil
	end
	local attempts = { "GetFilteredRecipeIDs", "GetAllRecipeIDs" }
	for index = 1, #attempts do
		local call = attempts[index]
		if TradeSkillUI[call] then
			local ok, ids = pcall(TradeSkillUI[call])
			if ok and type(ids) == "table" then
				return ids, call
			end
		end
	end
	return nil, nil
end

-- The profession in the open window, resolved as the client's own window
-- resolves it. professionID is 0 while no window is open (Blizzard's own
-- test). A child profession is named by its parent. Returns name and
-- skillLineID, or nil.
local function ModernProfessionInfo()
	if not TradeSkillUI then
		return nil
	end
	local info
	if TradeSkillUI.GetChildProfessionInfo then
		local ok, child = pcall(TradeSkillUI.GetChildProfessionInfo)
		if ok and type(child) == "table" and (child.professionID or 0) ~= 0 then
			info = child
		end
	end
	if not info and TradeSkillUI.GetBaseProfessionInfo then
		local ok, base = pcall(TradeSkillUI.GetBaseProfessionInfo)
		if ok and type(base) == "table" and (base.professionID or 0) ~= 0 then
			info = base
		end
	end
	if not info then
		return nil
	end
	local name = info.parentProfessionName or info.professionName
	local skillLineID = info.parentProfessionID or info.professionID
	if (type(name) ~= "string" or name == "") and skillLineID and TradeSkillUI.GetTradeSkillDisplayName then
		local ok, display = pcall(TradeSkillUI.GetTradeSkillDisplayName, skillLineID)
		if ok and type(display) == "string" then
			name = display
		end
	end
	if type(name) ~= "string" or name == "" then
		return nil
	end
	return name, skillLineID
end

-- The name the stored skills list uses for a profession. The card looks the
-- recipe book up by this name, so the window's name is matched to it: exact
-- first, then case-insensitively, so a case difference cannot hide a
-- profession's recipes. Returns the stored name or nil.
local function StoredSkillName(char, profession)
	local store = char and char.professions
	local skills = (type(store) == "table" and store.skills) or {}
	for index = 1, #skills do
		if skills[index].name == profession then
			return skills[index].name
		end
	end
	if type(profession) == "string" then
		local lowered = string.lower(profession)
		for index = 1, #skills do
			local name = skills[index].name
			if type(name) == "string" and string.lower(name) == lowered then
				return name
			end
		end
	end
	return nil
end

-- The window's search-box text, or nil. While a search is active the client
-- lists matches from every profession, so such a list is not the open
-- profession's and is not stored.
local function ModernSearchText()
	if not (TradeSkillUI and TradeSkillUI.GetRecipeItemNameFilter) then
		return nil
	end
	local ok, text = pcall(TradeSkillUI.GetRecipeItemNameFilter)
	if ok and type(text) == "string" and text ~= "" then
		return text
	end
	return nil
end

-- Whether the window's dropdown filters narrow the list, tested through
-- Professions.IsUsingDefaultFilters. nil means the client will not say; the
-- count is then left unlabelled rather than guessed.
local function ModernListIsFiltered()
	local api = Professions
	if not (type(api) == "table" and type(api.IsUsingDefaultFilters) == "function") then
		return nil
	end
	local ok, isDefault = pcall(api.IsUsingDefaultFilters, true)
	if not ok then
		return nil
	end
	return not isDefault
end

-- The item a recipe makes: the output item data first, then the link the
-- recipe itself carries.
local function RecipeOutputItemID(recipeID, info)
	if TradeSkillUI and TradeSkillUI.GetRecipeOutputItemData then
		local ok, data = pcall(TradeSkillUI.GetRecipeOutputItemData, recipeID)
		if ok and type(data) == "table" and data.itemID then
			return data.itemID
		end
	end
	local link = info and info.hyperlink
	if type(link) == "string" then
		return tonumber(string.match(link, "item:(%d+)"))
	end
	return nil
end

-- Timestamp when a cooling recipe becomes ready, on Tally's clock (the
-- client's clock does not survive a reload). A recipe counts as cooling only
-- when Professions.IsRecipeOnCooldown returns true, so a number reported for
-- an already-ready recipe is not stored as a wait. Returns the ready-at
-- timestamp and the length of the wait in seconds, or nil.
local function RecipeCooldownUntil(recipeID)
	local cooldown, isDayCooldown, charges
	-- The modern profession API reports the remaining seconds directly. The
	-- Forever client uses C_TradeSkillUI; the older path is kept for a game
	-- that only has TradeSkillUI.
	if type(C_TradeSkillUI) == "table" and type(C_TradeSkillUI.GetRecipeCooldown) == "function" then
		local ok, value = pcall(C_TradeSkillUI.GetRecipeCooldown, recipeID)
		if ok then
			cooldown = value
		end
	end
	if (type(cooldown) ~= "number" or cooldown <= 0) then
		local legacy = type(_G.TradeSkillUI) == "table" and _G.TradeSkillUI or nil
		if legacy and type(legacy.GetRecipeCooldown) == "function" then
			local ok, value, day, chargeCount = pcall(legacy.GetRecipeCooldown, recipeID)
			if ok then
				cooldown, isDayCooldown, charges = value, day, chargeCount
			end
		end
	end
	if type(cooldown) ~= "number" or cooldown <= 0 then
		return nil
	end
	-- A month exceeds any real cooldown; a larger number is not a duration
	-- and is traced rather than stored.
	if cooldown > 31 * 24 * 60 * 60 then
		ns.Trace("cooldown: "..tostring(cooldown).." is not a duration (day "..tostring(isDayCooldown)..", charges "..tostring(charges)..")")
		return nil
	end
	return Now() + cooldown, SpellDuration(recipeID, cooldown)
end

-- The reagents one recipe takes, as { { itemID, count }, ... }, read from the
-- client's recipe schematic when a card asks (on hover) so nothing extra is
-- saved. A slot names every item that satisfies it; the first is the one the
-- client shows. Returns nil when the client will not answer for the recipe,
-- and says so once in the trace so a hover with no reagents has an answer.
local reagentsTraced = false

function ns.RecipeReagents(recipeID)
	if type(recipeID) ~= "number" then
		return nil
	end
	local api = TradeSkillUI
	if not (type(api) == "table" and type(api.GetRecipeSchematic) == "function") then
		if not reagentsTraced then
			reagentsTraced = true
			ns.Trace("reagents: this client has no GetRecipeSchematic")
		end
		return nil
	end
	local ok, schematic = pcall(api.GetRecipeSchematic, recipeID, false)
	if not ok or type(schematic) ~= "table" then
		if not reagentsTraced then
			reagentsTraced = true
			ns.Trace("reagents: the client did not answer GetRecipeSchematic for recipe "..recipeID)
		end
		return nil
	end
	local slots = schematic.reagentSlotSchematics
	if type(slots) ~= "table" then
		return nil
	end
	local reagents = {}
	for index = 1, #slots do
		local slot = slots[index]
		local list = type(slot) == "table" and slot.reagents or nil
		local first = type(list) == "table" and list[1] or nil
		if type(first) == "table" and first.itemID then
			local count = tonumber(slot.quantityRequired) or 1
			reagents[#reagents + 1] = { itemID = first.itemID, count = count }
		end
	end
	if #reagents == 0 then
		return nil
	end
	return reagents
end

-- Histogram of the source types the client reports for a profession's
-- recipes. The field's values are undocumented, so this is traced rather
-- than displayed.
local function SourceHistogram(sources)
	local parts = {}
	for source, count in pairs(sources) do
		parts[#parts + 1] = tostring(source).." x"..count
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

-- The ready-at timestamp and the length of a stored cooldown entry, in
-- seconds. Records written before the wait's length was kept hold the
-- timestamp alone, which is why this reads either shape.
local function CooldownParts(value)
	if type(value) == "number" then
		return value, nil
	end
	if type(value) == "table" then
		return value.readyAt, value.span
	end
	return nil, nil
end
ns.CooldownParts = CooldownParts

local COOLDOWN_RECIPES_CAP = 20

-- Merges newly seen cooldowns into a profession's stored entry, so a recipe
-- seen cooling is remembered and the card can later show it as ready. When
-- the book exceeds COOLDOWN_RECIPES_CAP, ready entries are discarded first.
local function KeepCooldowns(entry, found)
	if type(entry) ~= "table" or type(found) ~= "table" or not next(found) then
		return
	end
	local kept = type(entry.cooldowns) == "table" and entry.cooldowns or {}
	entry.cooldowns = kept
	for name, value in pairs(found) do
		kept[name] = value
	end
	local count = 0
	for _ in pairs(kept) do
		count = count + 1
	end
	if count <= COOLDOWN_RECIPES_CAP then
		return
	end
	local ready = {}
	for name, value in pairs(kept) do
		local untilAt = CooldownParts(value)
		if untilAt and untilAt <= Now() then
			ready[#ready + 1] = name
		end
	end
	table.sort(ready)
	for index = 1, #ready do
		if count <= COOLDOWN_RECIPES_CAP then
			break
		end
		kept[ready[index]] = nil
		count = count - 1
	end
end

-- The client's name and display order for one recipe category, or nil when
-- the client keeps no such category. The window groups its recipe list by
-- these, so a card can group the stored names the same way.
local function ModernCategoryInfo(categoryID)
	if type(categoryID) ~= "number" then
		return nil
	end
	local api = TradeSkillUI
	if not (api and type(api.GetCategoryInfo) == "function") then
		return nil
	end
	local ok, info = pcall(api.GetCategoryInfo, categoryID)
	if not ok or type(info) ~= "table" then
		return nil
	end
	local name = info.name
	if type(name) ~= "string" or name == "" then
		return nil
	end
	return { id = categoryID, name = name, order = tonumber(info.uiOrder) or 0 }
end

-- Modern read of an open profession window: all recipes of the profession,
-- with learnt ones counted, stored and timed.
local function CaptureModernRecipes(char)
	if not HasModernRecipeRead() or not char then
		return false
	end
	local profession, skillLineID = ModernProfessionInfo()
	if not profession then
		ns.Trace("recipes: no modern profession window is open")
		return false
	end
	local ids, via = ModernRecipeIDs()
	if not ids then
		ns.Trace("recipes: "..profession.." - the client refused its recipe list")
		return false
	end
	-- A window search lists matches from every profession, so it is not
	-- this profession's list and nothing is stored from it.
	if ModernSearchText() then
		ns.Trace("recipes: "..profession.." - the window's search box is filtering the list, so nothing is stored")
		return false
	end
	-- The card looks the book up by the skills-list name, so recipes are
	-- stored under it; a name mismatch would leave the card empty, hence
	-- the trace when the names differ.
	local stored = StoredSkillName(char, profession) or profession
	if stored ~= profession then
		ns.Trace("recipes: the client calls it "..profession..", stored as "..stored)
	end
	local list, items, storedIDs, cooldowns, sources = {}, {}, {}, {}, {}
	local catOf, cats, catSeen = {}, {}, {}
	local learnt, total = 0, 0
	local okList = pcall(function()
		for _, recipeID in pairs(ids) do
			local info = TradeSkillUI.GetRecipeInfo(recipeID)
			if type(info) == "table" and info.name then
				total = total + 1
				if info.sourceType ~= nil then
					sources[info.sourceType] = (sources[info.sourceType] or 0) + 1
				end
				if info.learned then
					learnt = learnt + 1
					list[#list + 1] = info.name
					local recipeKey = info.recipeID or recipeID
					storedIDs[info.name] = recipeKey
					local categoryID = info.categoryID
					if type(categoryID) == "number" then
						catOf[info.name] = categoryID
						if not catSeen[categoryID] then
							catSeen[categoryID] = true
							local category = ModernCategoryInfo(categoryID)
							if category then
								cats[#cats + 1] = category
							end
						end
					end
					local outputID = RecipeOutputItemID(recipeKey, info)
					if outputID then
						items[info.name] = outputID
					end
					local untilAt, span = RecipeCooldownUntil(recipeKey)
					if untilAt then
						local totalSpan = CooldownSpan(char, stored, info.name, untilAt, span)
						cooldowns[info.name] = {
							readyAt = untilAt,
							span = totalSpan,
							startedAt = untilAt - totalSpan,
							itemID = outputID,
							recipeID = recipeKey,
							profession = stored,
						}
						ns.Trace("cooldown: "..stored.." "..info.name.." ready in "..math.floor(untilAt - Now()).."s"..(totalSpan > 0 and (" (a "..math.floor(totalSpan).."s wait)") or ""))
					end
				end
			end
		end
	end)
	if not okList then
		ns.Trace("recipes: "..stored.." - the client refused the recipe list")
		return false
	end
	if total == 0 then
		ns.Trace("recipes: the "..stored.." window listed nothing yet (via "..via..")")
		return false
	end
	local filtered = ModernListIsFiltered()
	table.sort(cats, function(a, b)
		if a.order == b.order then
			return a.name < b.name
		end
		return a.order < b.order
	end)
	KeepRecipeList(char, stored, {
		list = list,
		items = items,
		ids = storedIDs,
		total = total,
		filtered = filtered,
		cats = #cats > 0 and cats or nil,
		catOf = next(catOf) and catOf or nil,
		line = skillLineID,
	})
	KeepCooldowns(char.professions.recipes[stored], cooldowns)
	ns.Trace("recipes: "..stored.." "..learnt.." of "..total.." recipes learnt (via "..via..")")
	if filtered then
		ns.Trace("recipes: "..stored.." - the window is filtering its list, so "..total.." is what it is showing")
	end
	if #cats > 0 then
		local counts = {}
		for _, id in pairs(catOf) do
			counts[id] = (counts[id] or 0) + 1
		end
		local parts = {}
		for index = 1, #cats do
			parts[#parts + 1] = cats[index].name.." x"..(counts[cats[index].id] or 0)
		end
		ns.Trace("recipe categories: "..stored.." - "..table.concat(parts, ", "))
	end
	if next(sources) then
		ns.Trace("recipe sources: "..SourceHistogram(sources))
	end
	return true
end

-- Scans whichever profession window is open and retries briefly when the
-- client was not ready the first time. A window closed before the retry
-- records nothing.
local recipeRetry = false

local function ScanOpenProfessionWindow()
	local char = ns.GetChar()
	if not char then
		return
	end
	local got
	if tradeSkillOpen or craftOpen then
		if HasModernRecipeRead() then
			got = CaptureModernRecipes(char)
		elseif tradeSkillOpen then
			got = CaptureTradeSkillRecipes(char)
		else
			got = CaptureCraftRecipes(char)
		end
	else
		return
	end
	if not got and not recipeRetry then
		recipeRetry = true
		ns.After(1.5, function()
			recipeRetry = false
			ScanOpenProfessionWindow()
		end)
	end
end

-- A pending scan absorbs further requests, so a burst of list updates is
-- read once rather than once per event.
local scanPending = false

local function ScheduleRecipeScan(delay)
	if scanPending or not ns.Tracks("economy") then
		return
	end
	scanPending = true
	ns.After(delay, function()
		scanPending = false
		ScanOpenProfessionWindow()
	end)
end

-- The recipes card's click: ask the client's own crafting window to show one
-- recipe. This is the one place Tally drives the client's UI rather than
-- reading it, at the user's request - `CraftingPage:SelectRecipe` is the
-- client's own method, so the call reaches into its frames - and it is made
-- only from an explicit click, never from a timer of Tally's own. The recipe
-- info handed over comes from the client's own GetRecipeInfo, the same call
-- the window's list itself is built from. Nothing is remembered from the
-- call beyond a trace line.

-- The client's crafting page, or nil when it is not loaded or does not carry
-- the method this needs.
local function ClientCraftingPage()
	if not ProfessionsFrame then
		return nil
	end
	local page = ProfessionsFrame.CraftingPage
	if type(page) ~= "table" or type(page.SelectRecipe) ~= "function" then
		return nil
	end
	return page
end

-- True while the client's window is showing the given profession, compared
-- by the skill line id the client itself reports for the open window.
local function ClientShowsSkillLine(line)
	local _, openLine = ModernProfessionInfo()
	return line ~= nil and openLine == line
end

-- Shows one recipe in the client's own window. Returns true when the call
-- went through, false when the recipe or the page could not be resolved or
-- the client raised. A true answer means the call was made, not that the
-- window changed.
local function SelectRecipeInClient(recipeID)
	if not (TradeSkillUI and TradeSkillUI.GetRecipeInfo) then
		return false
	end
	local okInfo, recipeInfo = pcall(TradeSkillUI.GetRecipeInfo, recipeID)
	if not okInfo or type(recipeInfo) ~= "table" or not recipeInfo.recipeID then
		return false
	end
	local page = ClientCraftingPage()
	if not page then
		return false
	end
	return pcall(page.SelectRecipe, page, recipeInfo) and true or false
end

-- The client's own id for a stored profession, read while its window was
-- last open, or nil when that has never happened.
local function StoredSkillLine(char, profession)
	local store = char and char.professions
	local books = type(store) == "table" and store.recipes or nil
	local book = type(books) == "table" and books[profession] or nil
	local line = type(book) == "table" and book.line or nil
	return type(line) == "number" and line or nil
end

-- A window the client was just asked to open builds its list asynchronously,
-- so the selection is asked again once shortly after. One attempt per click:
-- this never schedules a second.
local OPEN_SELECT_DELAY = 0.7

local function SelectAfterOpen(line, recipeID, profession)
	ns.After(OPEN_SELECT_DELAY, function()
		if not ClientShowsSkillLine(line) then
			ns.Trace("recipe click: "..profession.." is not the window showing then, so nothing was selected")
			return
		end
		if SelectRecipeInClient(recipeID) then
			ns.Trace("recipe click: showed "..recipeID.." in "..profession)
		else
			ns.Trace("recipe click: the client refused the selection in "..profession)
		end
	end)
end

-- The recipes card's click. Returns nil when the request was made, or a
-- sentence saying why it could not be, for the caller to report. Two cases
-- are deliberately silent (traced, nothing printed): a recipe with no id of
-- its own, and a profession whose client id Tally has not read yet. Neither
-- is a failure the player can act on, and the row's hover says as much.
function ns.ShowRecipe(profession, recipeID)
	if type(profession) ~= "string" or type(recipeID) ~= "number" then
		ns.Trace("recipe click: no recipe id for "..tostring(profession)..", nothing asked")
		return nil
	end
	local line = StoredSkillLine(ns.GetChar(), profession)
	if not line then
		ns.Trace("recipe click: no client id read for "..profession.." yet, nothing asked")
		return nil
	end
	if ClientShowsSkillLine(line) then
		if SelectRecipeInClient(recipeID) then
			return nil
		end
		return "The game would not show that "..profession.." recipe, so nothing changed."
	end
	if not (TradeSkillUI and TradeSkillUI.OpenTradeSkill) then
		return "This game gives Tally no way to open "..profession..", so open its window yourself."
	end
	local okOpen, opened = pcall(TradeSkillUI.OpenTradeSkill, line)
	if not okOpen or not opened then
		return "The game would not open "..profession.." for Tally."
	end
	ns.Trace("recipe click: asked the client to open "..profession.." for recipe "..recipeID)
	SelectAfterOpen(line, recipeID, profession)
	return nil
end

-- The name of a spell id, however this client answers.
local function SpellName(spellID)
	if not spellID then
		return nil
	end
	if type(spellID) == "string" then
		-- Some clients report the cast as the spell's name, not its id.
		return spellID
	end
	if C_Spell and C_Spell.GetSpellInfo then
		local info = C_Spell.GetSpellInfo(spellID)
		if info and info.name then
			return info.name
		end
	end
	if GetSpellInfo then
		local ok, name = pcall(GetSpellInfo, spellID)
		if ok and name then
			return name
		end
	end
	return nil
end

-- Disenchanting is a profession action but not a recipe craft. A successful
-- cast opens a short window in which the materials the client loots belong to
-- Enchanting; they are counted as crafted output for the profession.
local DISENCHANT_SPELL_ID = 13262
local enchantingGainUntil = 0

local function HasEnchanting(store)
	for _, skill in ipairs(type(store) == "table" and store.skills or {}) do
		if type(skill) == "table" and (tonumber(skill.rank) or 0) > 0
			and CanonicalProfessionName(skill.name) == "Enchanting" then
			return true
		end
	end
	return false
end

local function IsDisenchantSpell(spellID)
	if tonumber(spellID) == DISENCHANT_SPELL_ID then
		return true
	end
	local name = SpellName(spellID)
	return type(name) == "string" and string.lower(name) == "disenchant"
end

-- Returns true when the spell was a Disenchant, so the normal craft counter
-- does not also try to read it as a recipe.
local function NoteDisenchantCast(spellID)
	if not IsDisenchantSpell(spellID) then
		return false
	end
	if not ns.Tracks("economy") then
		return true
	end
	local char = ns.GetChar()
	if not char then
		return true
	end
	local store = EnsureProfessions(char)
	if not HasEnchanting(store) then
		return true
	end
	local at = Now()
	local stats = store.disenchants
	stats.count = (tonumber(stats.count) or 0) + 1
	stats.firstAt = stats.firstAt or at
	stats.lastAt = at
	stats.updatedAt = at
	enchantingGainUntil = at + 3
	ns.Trace("disenchant: cast succeeded; gain window open ("
		..tostring(SpellName(spellID) or spellID)..")")
	return true
end

function ns.IsEnchantingGainWindow()
	return Now() <= enchantingGainUntil
end

-- Called by the loot module for an item looted while the disenchant window is
-- open. It is counted exactly like a crafted Enchanting item, and also kept
-- under the character level it happened at for the by-level materials view.
function ns.NoteEnchantingGain(itemID, name, quality, count)
	if not name or Now() > enchantingGainUntil or not ns.Tracks("economy") then
		return false
	end
	local char = ns.GetChar()
	if not char then
		return false
	end
	local store = EnsureProfessions(char)
	if not HasEnchanting(store) then
		return false
	end
	count = math.max(1, tonumber(count) or 1)
	local at = Now()
	store.crafts["Enchanting"] = (store.crafts["Enchanting"] or 0) + count
	local tally = store.crafted[name]
	if type(tally) ~= "table" then
		tally = {
			name = name, itemID = itemID, quality = quality, count = 0,
			profession = "Enchanting", source = "disenchant",
			firstAt = at, lastAt = at, updatedAt = at,
			evidence = "disenchant_loot",
		}
		store.crafted[name] = tally
	end
	tally.count = (tonumber(tally.count) or 0) + count
	tally.profession = tally.profession or "Enchanting"
	tally.source = tally.source or "disenchant"
	tally.itemID = itemID or tally.itemID
	tally.quality = quality or tally.quality
	tally.firstAt = tally.firstAt or at
	tally.lastAt = at
	tally.updatedAt = at
	local level = (type(UnitLevel) == "function" and UnitLevel("player")) or char.level or 0
	level = tonumber(level) or 0
	if level > 0 then
		local row = store.enchantingByLevel[level]
		if type(row) ~= "table" then
			row = {}
			store.enchantingByLevel[level] = row
		end
		row[name] = (tonumber(row[name]) or 0) + count
	end
	if ns.NoteCraftMilestone then
		ns.NoteCraftMilestone(char)
	end
	if ns.Touch then
		ns.Touch(char, "professions.crafts.Enchanting", at)
	end
	ns.Trace("enchanting gain: "..name.." x"..count.." at level "..level)
	return true
end

-- Records a successful cast made while a profession window is open. The
-- spell counts as a craft only when it is one of that window's recipes
-- (ordinary spells can be cast with the window open, so the recipe list is
-- the filter). A spell that cannot be named is ignored. The craft is also
-- added to the per-recipe tally that the records read.
local CRAFT_ITEM_CAP = 40

-- Pruned like the loot tally: the records card reads only the top of the
-- list, so the long tail is discarded.
local function PruneCraftTally(char)
	local counts = char.professions.crafted
	local total = 0
	for _ in pairs(counts) do
		total = total + 1
	end
	if total <= CRAFT_ITEM_CAP + 20 then
		return
	end
	local list = {}
	for _, tally in pairs(counts) do
		list[#list + 1] = tally
	end
	table.sort(list, function(a, b)
		return a.count > b.count
	end)
	local fresh = {}
	for index = 1, math.min(#list, CRAFT_ITEM_CAP) do
		local tally = list[index]
		fresh[tally.name] = tally
	end
	char.professions.crafted = fresh
end

local CRAFT_CREDIT_WINDOW = 5
local craftSourceCredits = {}

local function RecipeNameKnown(store, profession, name)
	if not profession or not name or type(store) ~= "table" then
		return false
	end
	local entry = type(store.recipes) == "table" and store.recipes[profession] or nil
	if type(entry) ~= "table" then
		return false
	end
	if type(entry.items) == "table" and entry.items[name] ~= nil then
		return true
	end
	local list = entry.list
	if type(list) == "table" then
		for index = 1, #list do
			if list[index] == name then
				return true
			end
		end
	end
	return false
end

local function CountCraft(spellID)
	if not (tradeSkillOpen or craftOpen) or not ns.Tracks("economy") then
		return
	end
	local name = windowRecipeIDs[spellID] or SpellName(spellID)
	if not name and pendingCraftSpell == spellID then
		name = pendingCraftName
	end
	-- A cast bar is not a recipe. Some clients report the frame name as the
	-- spell, and the old fallback credited it to the last open profession,
	-- which is how "CastBar-..." rows appeared in the crafted tally.
	if type(name) ~= "string" or name == "" or string.find(name, "^CastBar%-") then
		return
	end
	local char = ns.GetChar()
	if not char then
		return
	end
	local store = EnsureProfessions(char)
	local profession = windowRecipes[name]
	if not profession then
		profession = lastWindowProfession
		-- Only a name the profession's own recipe list knows can be a craft.
		if not RecipeNameKnown(store, profession, name) then
			ns.Trace("craft ignored: "..tostring(name).." is not in the "..tostring(profession or "?").." recipe list")
			return
		end
	end
	if not profession then
		return
	end
	local at = Now()
	store.crafts[profession] = (store.crafts[profession] or 0) + 1
	if ns.NoteCraftMilestone then
		ns.NoteCraftMilestone(char)
	end
	local entry = store.recipes[profession]
	local itemID = type(entry) == "table" and type(entry.items) == "table" and entry.items[name] or nil
	if not itemID and ns.ItemIDForName then
		-- The recipe map can be incomplete on a fresh scan. The item name is
		-- enough to find the id elsewhere, and the id is what the credit
		-- ledger uses to stop the item event counting the same craft again.
		local okID, foundID = pcall(ns.ItemIDForName, name)
		if okID and foundID then
			itemID = foundID
		end
	end
	local tally = store.crafted[name]
	if tally then
		tally.count = tally.count + 1
		tally.profession = tally.profession or profession
		tally.firstAt = tally.firstAt or at
		tally.lastAt = at
		tally.updatedAt = at
		tally.evidence = "spell_cast"
	else
		store.crafted[name] = {
			name = name,
			itemID = itemID,
			quality = itemID and ItemQualityOf(itemID) or nil,
			count = 1,
			profession = profession,
			firstAt = at, lastAt = at, updatedAt = at,
			evidence = "spell_cast",
		}
	end
	if ns.Touch then
		ns.Touch(char, "professions.crafts."..profession, at)
	end
	-- The cast is already counted here. Mark one event and one chat line as
	-- belonging to it, so a client that sends those as well cannot count the
	-- same craft again.
	if itemID then
		local credits = craftSourceCredits[itemID]
		if not credits or (Now() - credits.at) > CRAFT_CREDIT_WINDOW then
			credits = { at = Now(), event = 0, chat = 0 }
			craftSourceCredits[itemID] = credits
		end
		credits.at = Now()
		credits.event = credits.event + 1
		credits.chat = credits.chat + 1
	end
	PruneCraftTally(char)
	ScheduleOpenRank(char, profession)
	if ns.NoteRecentEvent then
		ns.NoteRecentEvent("craft", {
			at = at, zone = ns.CurrentZone and ns.CurrentZone() or nil,
			how = "craft", evidence = "spell_cast",
			data = { name = name, itemID = itemID, count = 1, profession = profession },
		})
	end
	if ns.OnDataTick then
		local ok, err = pcall(ns.OnDataTick)
		if not ok then
			ns.Trace("craft: redraw failed: "..tostring(err))
		end
	end
	ns.Trace("craft counted: "..profession.." "..name.." by cast")
end

-- Credits one craft to a known profession and recipe name. This is the path
-- used when the recipe window has named the item, so it does not depend on
-- the item-to-recipe map being complete.
local function CountNamedCraft(profession, name, itemID, quantity)
	local char = ns.GetChar()
	if not char or not profession or not name or not ns.Tracks("economy") then
		return false
	end
	local store = EnsureProfessions(char)
	local count = tonumber(quantity) or 1
	if count < 1 then
		count = 1
	end
	local at = Now()
	store.crafts[profession] = (store.crafts[profession] or 0) + count
	if ns.NoteCraftMilestone then
		ns.NoteCraftMilestone(char)
	end
	if ns.NoteFirstCraft then
		ns.NoteFirstCraft(name, itemID)
	end
	if itemID then
		local _, _, quality = ns.ItemInfo(itemID)
		if quality == 2 then
			ns.NoteMilestoneFirst("craftedUncommon", { name = name, itemID = itemID })
		elseif quality == 3 then
			ns.NoteMilestoneFirst("craftedRare", { name = name, itemID = itemID })
		elseif quality == 4 then
			ns.NoteMilestoneFirst("epicCrafted", { name = name, itemID = itemID })
		end
	end
	local tally = store.crafted[name]
	if tally then
		tally.count = tally.count + count
		tally.profession = tally.profession or profession
		if not tally.itemID and itemID then
			tally.itemID = itemID
			tally.quality = ItemQualityOf(itemID)
		end
		tally.firstAt = tally.firstAt or at
		tally.lastAt = at
		tally.updatedAt = at
		tally.evidence = "craft_event"
	else
		store.crafted[name] = {
			name = name,
			itemID = itemID,
			quality = itemID and ItemQualityOf(itemID) or nil,
			count = count,
			profession = profession,
			firstAt = at, lastAt = at, updatedAt = at,
			evidence = "craft_event",
		}
	end
	if ns.Touch then
		ns.Touch(char, "professions.crafts."..profession, at)
	end
	PruneCraftTally(char)
	ScheduleOpenRank(char, profession)
	if ns.NoteRecentEvent then
		ns.NoteRecentEvent("craft", {
			at = at, zone = ns.CurrentZone and ns.CurrentZone() or nil,
			how = "craft", evidence = "craft_event",
			data = { name = name, itemID = itemID, count = count, profession = profession },
		})
	end
	if ns.OnDataTick then
		local ok, err = pcall(ns.OnDataTick)
		if not ok then
			ns.Trace("craft: redraw failed: "..tostring(err))
		end
	end
	return true
end

-- Records a craft reported by the modern client. The event carries the item
-- produced (and its quantity), not the recipe, so the recipe is looked up by
-- the item it makes, as stored by the window scans. An item no scanned
-- recipe makes is traced rather than credited to a guess.
local function CountCraftedItem(itemID, quantity)
	local char = ns.GetChar()
	if not char or not itemID or not ns.Tracks("economy") then
		return false
	end
	local store = EnsureProfessions(char)
	local count = quantity
	if type(count) ~= "number" or count < 1 then
		count = 1
	end
	for profession, entry in pairs(store.recipes) do
		if type(entry) == "table" and type(entry.items) == "table" then
			for name, made in pairs(entry.items) do
				if made == itemID then
					return CountNamedCraft(profession, name, itemID, count)
				end
			end
		end
	end
	ns.Trace("craft: an item no scanned recipe makes came out of the window (item "..tostring(itemID)..")")
	return false
end

-- A craft can reach Tally twice: once through the client's crafted-item event
-- and once through the "You create:" loot line. The same craft must count
-- once. A short ledger per item pairs the two sources whichever arrives
-- first; whatever is left over is a genuinely separate craft.
local function TakeCraftCredit(itemID, quantity, source)
	itemID = tonumber(itemID)
	if not itemID then
		return quantity
	end
	local now = Now()
	local credits = craftSourceCredits[itemID]
	if credits and (now - credits.at) > CRAFT_CREDIT_WINDOW then
		credits = nil
	end
	if not credits then
		credits = { at = now, event = 0, chat = 0 }
		craftSourceCredits[itemID] = credits
	end
	credits.at = now
	local other = source == "chat" and "event" or "chat"
	local matched = math.min(quantity, credits[other])
	credits[other] = credits[other] - matched
	return quantity - matched
end

local function AddCraftCredit(itemID, quantity, source)
	itemID = tonumber(itemID)
	if not itemID or quantity <= 0 then
		return
	end
	local credits = craftSourceCredits[itemID]
	if not credits then
		credits = { at = Now(), event = 0, chat = 0 }
		craftSourceCredits[itemID] = credits
	end
	if source == "chat" then
		credits.chat = credits.chat + quantity
	else
		credits.event = credits.event + quantity
	end
end

local function CreditCraftItem(itemID, quantity, source)
	quantity = tonumber(quantity)
	if not quantity or quantity < 1 then
		quantity = 1
	end
	local remaining = TakeCraftCredit(itemID, quantity, source)
	if remaining <= 0 then
		return true
	end
	if not CountCraftedItem(itemID, remaining) then
		return false
	end
	AddCraftCredit(itemID, remaining, source)
	return true
end

-- The chat line carries the item name, and the open recipe window knows
-- which profession that name belongs to. Crediting by name works even when
-- the item-to-recipe map is incomplete.
local function CreditNamedCraft(profession, name, itemID, quantity, source)
	quantity = tonumber(quantity)
	if not quantity or quantity < 1 then
		quantity = 1
	end
	local remaining = TakeCraftCredit(itemID, quantity, source)
	if remaining <= 0 then
		return true
	end
	if not CountNamedCraft(profession, name, itemID, remaining) then
		return false
	end
	AddCraftCredit(itemID, remaining, source)
	return true
end

-- Fallback for a client that reports the craft only in the loot line:
-- "You create: [item]." or "You create: [item] x5."
local function NoteCraftMessage(text)
	if type(text) ~= "string" or not ns.Tracks("economy") then
		return
	end
	local plain = string.lower(ns.StripColors(text))
	if not string.find(plain, "you create", 1, true) then
		return
	end
	local itemID = tonumber(string.match(text, "|Hitem:(%d+)"))
	local shown = ns.StripColors(text)
	local name = string.match(shown, "|h%[(.-)%]|h")
	if not name then
		name = string.match(shown, "[Yy]ou create:%s*(.-)%.?$")
	end
	if not itemID and name and ns.ItemIDForName then
		itemID = ns.ItemIDForName(name)
	end
	local count = tonumber(string.match(plain, "x(%d+)")) or 1
	local profession = name and windowRecipes[name] or nil
	if not profession and name then
		local char = ns.GetChar()
		local store = char and char.professions
		local books = type(store) == "table" and store.recipes or nil
		for professionName, entry in pairs(books or {}) do
			local list = type(entry) == "table" and entry.list or nil
			for index = 1, list and #list or 0 do
				if list[index] == name then
					profession = professionName
					break
				end
			end
			if profession then
				break
			end
		end
	end
	-- The window that is open is the profession the craft belongs to, even
	-- when the stone's wording of the item name differs from the recipe list.
	if not profession and name and (tradeSkillOpen or craftOpen) then
		profession = lastWindowProfession
	end
	local credited = false
	if profession and name then
		credited = CreditNamedCraft(profession, name, itemID, count, "chat")
	elseif itemID then
		credited = CreditCraftItem(itemID, count, "chat")
	end
	ns.Trace("craft line: "..tostring(name).." / item "..tostring(itemID)
		.." / "..tostring(profession).." x"..tostring(count).." -> "..(credited and "counted" or "not a known recipe"))
end

-- Traces a recipe learnt while Tally is watching, including its source type
-- (see SourceHistogram).
local function NoteLearnedRecipe(recipeID)
	if not (TradeSkillUI and TradeSkillUI.GetRecipeInfo) or not recipeID then
		return
	end
	local ok, info = pcall(TradeSkillUI.GetRecipeInfo, recipeID)
	if ok and type(info) == "table" and info.name then
		ns.Trace("recipe learned: "..info.name.." (source "..tostring(info.sourceType)..")")
	end
end

-- Traces clicks on the create button, with the recipe and cast count. If a
-- client never reports a successful craft cast, this is the event the craft
-- counter could be moved onto instead.
if type(hooksecurefunc) == "function" then
	pcall(hooksecurefunc, "DoTradeSkill", function(index, casts)
		if not (tradeSkillOpen or craftOpen) then
			return
		end
		local name
		if craftOpen and GetCraftInfo then
			name = GetCraftInfo(index)
		elseif GetTradeSkillInfo then
			name = GetTradeSkillInfo(index)
		end
		ns.Trace("craft clicked: "..tostring(name).." x"..tostring(casts or 1))
	end)

end

-- Profession events are owned here so the page state (open windows, the
-- recipes read from the last window) stays private to this file. Core asks
-- IsProfessionEvent once per event and then delegates.
local PROFESSION_EVENTS = {
	CHAT_MSG_SKILL = true,
	TRADE_SKILL_SHOW = true,
	TRADE_SKILL_UPDATE = true,
	TRADE_SKILL_LIST_UPDATE = true,
	NEW_RECIPE_LEARNED = true,
	TRADE_SKILL_CRAFT_BEGIN = true,
	TRADE_SKILL_ITEM_CRAFTED_RESULT = true,
	TRADE_SKILL_DATA_SOURCE_CHANGED = true,
	TRADE_SKILL_CLOSE = true,
	CRAFT_SHOW = true,
	CRAFT_UPDATE = true,
	CRAFT_CLOSE = true,
	UNIT_SPELLCAST_SUCCEEDED = true,
	UNIT_SPELLCAST_SENT = true,
}

local function IsProfessionEvent(event)
	return PROFESSION_EVENTS[event] == true
end

local function HandleProfessionEvent(event, ...)
	if event == "CHAT_MSG_SKILL" then
		-- A skill-up changes the client's profession list (rank and max
		-- rank). No recipe scan runs here: expanding the whole tree during
		-- crafting would reorder the list under the player's clicks, so
		-- recipe names are read when a window opens.
		local char = ns.GetChar()
		-- The chat line names the profession and the new rank. Reading it
		-- first catches clients whose profession list lags or omits the line,
		-- such as a secondary profession on a custom client. The live
		-- no-downgrade rule keeps a stale snapshot from undoing the gain.
		local text = ...
		if char and type(text) == "string" then
			local plain = string.gsub(text, "|c%x%x%x%x%x%x%x%x", "")
			plain = string.gsub(plain, "|r", "")
			local name, rank = string.match(plain, "^Your skill in (.-) has increased to (%d+)")
			rank = tonumber(rank)
			if name and rank then
				local store = char.professions
				if type(store) == "table" then
					for index = 1, #store.skills do
						local skill = store.skills[index]
						if CanonicalProfessionName(skill.name) == CanonicalProfessionName(name)
							and (tonumber(skill.maxRank) or 0) > 0 then
							if rank > (tonumber(skill.rank) or 0) then
								RecordSkillReading(char, name, rank, skill.maxRank, "chat_skill", "live")
							end
							break
						end
					end
				end
			end
		end
		SnapshotProfessions(char)
		-- Some clients deliver the chat line a moment before the profession
		-- list shows the new rank. A second read half a second later catches
		-- that case without ever counting the same rank twice.
		if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
			C_Timer.After(0.5, function()
				if char and ns.GetChar() == char then
					SnapshotProfessions(char)
				end
			end)
		end
		-- The Character tab's Professions view is open on this data, so let it
		-- redraw at once rather than waiting for the next ticker step.
		if ns.OnDataTick then
			ns.OnDataTick()
		end
	elseif event == "TRADE_SKILL_SHOW" then
		tradeSkillOpen = true
		-- Drops the previous window's recipe list: until this window is
		-- read, an uncounted craft is better than one counted against the
		-- wrong profession.
		windowRecipes = {}
		windowRecipeIDs = {}
		SnapshotProfessions(ns.GetChar())
		ScheduleRecipeScan(0.5)
	elseif event == "TRADE_SKILL_UPDATE" or event == "TRADE_SKILL_LIST_UPDATE" then
		-- Either event means a window is open, even on a game that never
		-- sends TRADE_SKILL_SHOW. The modern read is passive and may run on
		-- every change; the old read expands the whole tree and would
		-- reorder the list under the player's clicks, so it runs only while
		-- no list has been read yet.
		if not tradeSkillOpen then
			tradeSkillOpen = true
			windowRecipes = {}
			windowRecipeIDs = {}
		end
		if tradeSkillOpen then
			local char = ns.GetChar()
			if char then
				ReadOpenRank(char)
			end
		end
		if tradeSkillOpen and (HasModernRecipeRead() or next(windowRecipes) == nil) then
			ScheduleRecipeScan(0.5)
		end
	elseif event == "NEW_RECIPE_LEARNED" then
		-- A recipe learnt from a trainer or a pattern: the log records its
		-- source number.
		NoteLearnedRecipe(...)
	elseif event == "TRADE_SKILL_CRAFT_BEGIN" then
		local spellID = ...
		if type(spellID) == "number" then
			pendingCraftSpell = spellID
			pendingCraftName = windowRecipeIDs[spellID] or SpellName(spellID)
			ns.Trace("craft begin: "..tostring(pendingCraftName).." ("..spellID..")")
		end
	elseif event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
		local data = ...
		if type(data) == "table" then
			CreditCraftItem(data.itemID, data.quantity, "event")
		elseif type(data) == "number" then
			-- A client that sends the item id and quantity as plain
			-- arguments rather than the documented result table.
			local itemID, quantity = ...
			CreditCraftItem(itemID, quantity, "event")
		end
		-- The craft may have started a cooldown on the recipe behind it.
		if tradeSkillOpen or craftOpen then
			ScheduleRecipeScan(1)
		end
	elseif event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
		if tradeSkillOpen then
			ScheduleRecipeScan(0.5)
		end
	elseif event == "TRADE_SKILL_CLOSE" then
		tradeSkillOpen = false
		windowRecipes = {}
		windowRecipeIDs = {}
		pendingCraftSpell, pendingCraftName = nil, nil
	elseif event == "CRAFT_SHOW" then
		craftOpen = true
		windowRecipes = {}
		windowRecipeIDs = {}
		SnapshotProfessions(ns.GetChar())
		ScheduleRecipeScan(0.5)
	elseif event == "CRAFT_UPDATE" then
		if not craftOpen then
			craftOpen = true
			windowRecipes = {}
			windowRecipeIDs = {}
			ScheduleRecipeScan(0.5)
		end
	elseif event == "CRAFT_CLOSE" then
		craftOpen = false
		windowRecipes = {}
		windowRecipeIDs = {}
		pendingCraftSpell, pendingCraftName = nil, nil
	elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
		local unit, castGUID, spellID = ...
		if type(spellID) ~= "number" then
			local arguments = select("#", ...)
			spellID = select(arguments, ...)
		end
		if unit == "player" then
			if tradeSkillOpen or craftOpen then
				ns.Trace("cast succeeded with a profession window open: "..tostring(SpellName(spellID) or spellID))
			end
			local disenchant = NoteDisenchantCast(spellID)
			if not disenchant then
				CountCraft(spellID)
			end
			pendingCraftSpell = nil
			pendingCraftName = nil
		end
	elseif event == "UNIT_SPELLCAST_SENT" then
		-- Not counted, since a "sent" cast can still fail; traced so the
		-- log shows which of the two events this game reports crafts on.
		local unit = ...
		local arguments = select("#", ...)
		local spellID = select(arguments, ...)
		if unit == "player" then
			-- Open the gain window before the cast finishes: the loot line can
			-- arrive just before UNIT_SPELLCAST_SUCCEEDED.
			if IsDisenchantSpell(spellID) then
				enchantingGainUntil = Now() + 3
				ns.Trace("disenchant: cast sent; gain window open")
			end
			if tradeSkillOpen or craftOpen then
				ns.Trace("cast sent with a profession window open: "..tostring(SpellName(spellID) or spellID))
			end
		end
	end
end

function ns.CraftedProfession(char, tally)
	if not tally then
		return nil
	end
	if tally.profession then
		return tally.profession
	end
	local store = char and char.professions
	local books = type(store) == "table" and store.recipes or nil
	if type(books) ~= "table" then
		return nil
	end
	for profession, entry in pairs(books) do
		if type(entry) == "table" and type(entry.items) == "table" and entry.items[tally.name] then
			return profession
		end
	end
	for profession, entry in pairs(books) do
		local list = type(entry) == "table" and entry.list or nil
		for index = 1, list and #list or 0 do
			if list[index] == tally.name then
				return profession
			end
		end
	end
	return nil
end

-- The most crafted item in each profession, from the per-item tally. Old
-- tallies that predate the profession field are matched by the stored recipe
-- lists, so the card and records can use them too.
function ns.MostCraftedByProfession(char)
	local store = char and char.professions
	local crafted = type(store) == "table" and store.crafted or nil
	local out = {}
	if type(crafted) ~= "table" then
		return out
	end
	for _, tally in pairs(crafted) do
		local count = tally.count or 0
		local profession = ns.CraftedProfession(char, tally)
		if profession and count > 0 then
			local best = out[profession]
			local betterTie = best and count == best.count and (tally.name or "") < (best.name or "")
			if not best or count > best.count or betterTie then
				local quality = tally.quality
				if quality == nil and tally.itemID then
					local _, _, found = ns.ItemInfo(tally.itemID)
					quality = found
				end
				out[profession] = {
					name = tally.name, itemID = tally.itemID, quality = quality,
					count = count, profession = profession,
				}
			end
		end
	end
	return out
end

function ns.MostCraftedFor(char, profession)
	if not profession then
		return nil
	end
	return ns.MostCraftedByProfession(char)[profession]
end

ns.SnapshotProfessions = SnapshotProfessions

-- The level that opens a rank is easy to miss if it arrives mid-fight, so the
-- trainer reminder waits thirty seconds and then names only the professions
-- that are already at the skill threshold and still below the rank's cap.
ns.On("PLAYER_LEVEL_UP", function(level)
	level = tonumber(level)
	if level ~= 10 and level ~= 20 and level ~= 35 then
		return
	end
	local expected = level
	local function Remind()
		local current = 0
		if type(UnitLevel) == "function" then
			local ok, value = pcall(UnitLevel, "player")
			current = ok and (tonumber(value) or 0) or 0
		end
		-- If the character has moved on to another level, the reminder for
		-- this threshold would be stale.
		if current >= expected then
			CheckLevelTrainerReminder(expected)
		end
	end
	if type(C_Timer) == "table" and type(C_Timer.After) == "function" then
		C_Timer.After(30, Remind)
	else
		Remind()
	end
end, "Professions")

-- Retail can raise a skill-line change without a usable CHAT_MSG_SKILL for
-- the old-world "Classic Cooking" style lines. Snapshot on the event where
-- the client offers it; ns.On drops an unknown event safely on older clients.
ns.On("SKILL_LINES_CHANGED", function()
	local char = ns.GetChar()
	if char and ns.Tracks("economy") then
		SnapshotProfessions(char)
		if ns.OnDataTick then
			ns.OnDataTick()
		end
	end
end, "Professions")
ns.HasModernRecipeRead = HasModernRecipeRead
ns.ScheduleRecipeScan = ScheduleRecipeScan
ns.SpellName = SpellName
ns.CountCraft = CountCraft
ns.CountCraftedItem = CountCraftedItem
ns.NoteCraftMessage = NoteCraftMessage
ns.NoteLearnedRecipe = NoteLearnedRecipe
ns.IsProfessionEvent = IsProfessionEvent
ns.HandleProfessionEvent = HandleProfessionEvent
-- Owner namespace. Every field references the flat API above.
ns.professions = {}
ns.professions.ShowRecipe = ns.ShowRecipe
ns.professions.RecipeReagents = ns.RecipeReagents
ns.professions.CooldownParts = ns.CooldownParts
ns.professions.Snapshot = ns.SnapshotProfessions
ns.professions.CraftedProfession = ns.CraftedProfession
ns.professions.MostCraftedByProfession = ns.MostCraftedByProfession
ns.professions.MostCraftedFor = ns.MostCraftedFor
ns.professions.HasModernRecipeRead = ns.HasModernRecipeRead
ns.professions.ScheduleScan = ns.ScheduleRecipeScan
ns.professions.SpellName = ns.SpellName
ns.professions.CountCraft = ns.CountCraft
ns.professions.CountCraftedItem = ns.CountCraftedItem
ns.professions.NoteCraftMessage = ns.NoteCraftMessage
ns.professions.NoteLearnedRecipe = ns.NoteLearnedRecipe
ns.professions.IsEnchantingGainWindow = ns.IsEnchantingGainWindow
ns.professions.NoteEnchantingGain = ns.NoteEnchantingGain
ns.professions.IsEvent = ns.IsProfessionEvent
ns.professions.HandleEvent = ns.HandleProfessionEvent
ns.ProfessionSecondary = SECONDARY_PROFESSIONS
ns.ProfessionRanks = PROFESSION_RANKS
ns.ProfessionRankTier = RankTier
ns.ProfessionIsSecondary = IsSecondary
ns.ProfessionIsIgnored = IsIgnored
ns.ProfessionSecondaryOrder = SecondaryOrder
ns.ProfessionCanonicalName = CanonicalProfessionName
ns.professions.Secondary = ns.ProfessionSecondary
ns.professions.IsSecondary = ns.ProfessionIsSecondary
ns.professions.IsIgnored = ns.ProfessionIsIgnored
ns.professions.SecondaryOrder = ns.ProfessionSecondaryOrder
