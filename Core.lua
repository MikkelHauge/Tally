-- Tally - data layer
--
-- Records the statistics a single character generates - playtime and
-- levels, classified gold changes, kills and deaths, looted items and
-- distance walked - in one SavedVariables table (TallyDB), and formats
-- that table into chat-sized reports.
--
-- Every public entry point is stored in the shared "ns" table. The window
-- files under UI/ build from the same table through ns.GetChar(); nothing
-- here depends on the window existing.
--
-- Data sources and semantics:
--   * Missing data stays a gap; an unrecognised money change lands in
--     "unclassified" rather than an inferred category.
--   * /played times come from the client (RequestTimePlayed), read at
--     login, on level-up and every 15 minutes; all other durations are
--     counted by a 1-second ticker. AFK time counts like any other logged-in
--     time by default, so tracked time stays close to the server's figure;
--     a setting can leave it out instead.
--   * Distances come from UnitPosition (world coordinates in yards),
--     exclude flight paths, and are presented as approximate.
local addonName, ns = ...

-- Build string reported by "/tally debug" and the trace block. Set by the
-- maintainer; no logic reads it.
ns.BUILD = "20261103 (Version follows the release date; Forever only.)"

-- In-memory only: key of the character the window and the printed reports
-- describe when it differs from the character being played; nil when none.
-- Every recorder goes through ns.GetChar(), so viewing another character
-- never writes to that character's record.
ns.viewKey = nil

-------------------------------------------------------------------------------
-- Timing constants
-------------------------------------------------------------------------------

-- Session boundary: client world-entry flags distinguish a /reload (the same
-- session continues) from a real login (a new session). When those flags are
-- unavailable, `mergeGap` is the fallback: an interruption shorter than it
-- continues the session, a longer one starts a new one.
--
-- The numbers live in one table rather than one local each because this client
-- refuses to load a file whose main chunk declares more than 200 locals, and
-- Core.lua is one big chunk: a table costs a single local for all of them.
local TUNING = {
	mergeGap = 6,              -- seconds, session-boundary fallback
	playedSync = 900,          -- re-read /played every 15 minutes
	lootWindow = 6,            -- loot money lands within this window
	questWindow = 30,          -- quest reward money lands within this one
	moneyConfirm = 2,          -- seconds a new balance reading must hold
	moneySettle = 10,          -- seconds a session's first reading holds
	moneyReversal = 30,        -- seconds an opposite change cancels the last
	killTypeCap = 60,          -- remembered creature types per character
	sessionHistoryCap = 60,    -- finished sessions kept
	transactionCap = 80,       -- recent gold changes kept
	deathLogCap = 50,          -- deaths kept for the card; the first is never dropped
	xpMinuteCap = 60,          -- per-minute XP buckets kept (an hour)
	xpWindowMinutes = 10,      -- the window a rate is measured over
	bestLootCap = 50,          -- "best finds" list length
	dailyCap = 366,            -- daily ledger days kept (a year, plus today)
	questXpWindow = 5,         -- experience after a turn-in is that quest's
	questGoldWindow = 8,       -- and so is reward money arriving within this
	levelSplitSlack = 2,       -- seconds a count may differ from a /played stretch
	levelRetryFor = 20,        -- seconds a level-up's /played reply is awaited
	levelRetryEvery = 2,       -- and how often it is asked for again
	repairGrace = 30,          -- seconds a repair quote outlives its vendor window
	repairButton = 8,          -- seconds the repair button's own evidence lives
	windowGrace = 5,           -- seconds a closed window still names its money
	errorReports = { events = {} },
}

ns.TUNING = TUNING

ns.SESSION_MERGE_GAP = TUNING.mergeGap
-- How long after a turn-in experience still counts as that quest's: the
-- quests card and the log's hover text both state it, so they state the one
-- the reader in Core actually uses.
ns.QUEST_XP_WINDOW = TUNING.questXpWindow

-------------------------------------------------------------------------------
-- Small shared helpers
-------------------------------------------------------------------------------

function ns.Print(message)
	if DEFAULT_CHAT_FRAME then
		DEFAULT_CHAT_FRAME:AddMessage("|cffffb347[Tally]|r "..tostring(message))
	end
end

-- Diagnostic breadcrumbs; they ignore the quiet setting. Every line is
-- also kept in a small ring buffer so "/tally trace" can place the whole
-- block in the copy window (chat text is not selectable on this client).
ns.TRACE_LOG_KEEP = 600
ns.TRACE_DUMP_LINES = 400
ns.traceLog = {}

-- Buffer-only diagnostic log, read with /tally trace. Each entry is
-- prefixed with seconds since client start, so a pasted dump keeps the
-- order of load and login events. Never prints to chat.
function ns.Trace(message)
	local line = string.format("%7.1f ", (GetTime and GetTime()) or 0)..tostring(message)
	local log = ns.traceLog
	if #log >= ns.TRACE_LOG_KEEP * 2 then
		for index = 1, ns.TRACE_LOG_KEEP do
			log[index] = log[index + ns.TRACE_LOG_KEEP]
		end
		for index = ns.TRACE_LOG_KEEP + 1, ns.TRACE_LOG_KEEP * 2 do
			log[index] = nil
		end
	end
	log[#log + 1] = line
end

-- Blizzard's global functions are never replaced here: on this client that
-- is a taint vector.

function ns.Trim(text)
	return (string.gsub(text or "", "^%s*(.-)%s*$", "%1"))
end

function ns.PlayUISound(sound)
	local ok = pcall(function()
		PlaySound(sound)
	end)
	if not ok and SOUNDKIT and SOUNDKIT.PlaySound then
		pcall(SOUNDKIT.PlaySound, sound)
	end
end

function ns.After(delay, callback)
	if C_Timer and C_Timer.After then
		C_Timer.After(delay, callback)
	else
		-- No C_Timer on this client: run on the next frame instead.
		local frame = CreateFrame("Frame")
		frame:SetScript("OnUpdate", function(self)
			self:SetScript("OnUpdate", nil)
			callback()
		end)
	end
end

local function GetAddonVersion()
	local getMetadata = GetAddOnMetadata
	if C_AddOns and C_AddOns.GetAddOnMetadata then
		getMetadata = C_AddOns.GetAddOnMetadata
	end
	if getMetadata then
		local ok, version = pcall(getMetadata, addonName, "Version")
		if ok and version then
			return version
		end
	end
	return "?"
end
ns.GetAddonVersion = GetAddonVersion

-- Realm time when available (same clock for everyone), local time as the
-- fallback. All timestamps in the saved variables use this.
local function Now()
	if GetServerTime then
		local server = GetServerTime()
		if server and server > 0 then
			return server
		end
	end
	return time()
end
ns.Now = Now

-------------------------------------------------------------------------------
-- Formatting helpers
-------------------------------------------------------------------------------

local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

-- 1234567 -> "1,234,567"
local function FormatNumber(value)
	local number = math.floor(tonumber(value) or 0)
	local sign = ""
	if number < 0 then
		sign = "-"
		number = -number
	end
	local text = tostring(number)
	local last
	repeat
		last = text
		text = string.gsub(text, "^(%d+)(%d%d%d)", "%1,%2")
	until text == last
	return sign..text
end
ns.FormatNumber = FormatNumber

-- Big counts in a tight space: 17600 -> "17.6k". Only for inherently
-- approximate values (XP rates, per-level XP), never for money.
local function FormatCompact(value)
	value = tonumber(value) or 0
	if value >= 1000000 then
		return string.format("%.1fM", value / 1000000)
	end
	if value >= 10000 then
		return string.format("%.0fk", value / 1000)
	end
	if value >= 1000 then
		return string.format("%.1fk", value / 1000)
	end
	return tostring(math.floor(value + 0.5))
end
ns.FormatCompact = FormatCompact

-- "2026-10-17" (the key format of the daily gold ledger) to a timestamp,
-- so those days can be formatted like any other date. nil if unparseable.
local function DayToTime(day)
	local year, month, dayOfMonth = string.match(day or "", "^(%d%d%d%d)-(%d%d)-(%d%d)$")
	if not year then
		return nil
	end
	-- Guarded so the records card still draws (showing "-") on a client
	-- that refuses time(t).
	local ok, stamp = pcall(time, { year = tonumber(year), month = tonumber(month), day = tonumber(dayOfMonth), hour = 12 })
	if ok then
		return stamp
	end
	return nil
end
ns.DayToTime = DayToTime

-- Seconds -> "14d 6h 23m" (with the smaller units kept while they matter).
local function FormatDuration(seconds, short)
	seconds = math.floor(tonumber(seconds) or 0)
	if seconds <= 0 then
		return "0s"
	end
	local days = math.floor(seconds / 86400)
	local hours = math.floor(seconds % 86400 / 3600)
	local minutes = math.floor(seconds % 3600 / 60)
	local secs = math.floor(seconds % 60)
	if short then
		if days > 0 then return string.format("%dd %dh", days, hours) end
		if hours > 0 then return string.format("%dh %dm", hours, minutes) end
		if minutes > 0 then return string.format("%dm", minutes) end
		return string.format("%ds", secs)
	end
	if days > 0 then return string.format("%dd %dh %dm", days, hours, minutes) end
	if hours > 0 then return string.format("%dh %dm", hours, minutes) end
	if minutes > 0 then return string.format("%dm %ds", minutes, secs) end
	return string.format("%ds", secs)
end
ns.FormatDuration = FormatDuration

-- Copper -> "1,234g 56s 78c" - the plain text form used in reports. From ten
-- thousand gold up the gold count is shortened and the silver and copper
-- keep their figures: 260,055g 22c reads "260k g 55s 22c".
local function GoldText(gold)
	if gold >= 10000 then
		return FormatCompact(gold).." g"
	end
	return FormatNumber(gold).."g"
end

local function FormatMoneyPlain(copper, zeroText)
	copper = math.floor(tonumber(copper) or 0)
	if copper == 0 then
		return zeroText or "0c"
	end
	local sign = ""
	if copper < 0 then
		sign = "-"
		copper = -copper
	end
	local gold = math.floor(copper / 10000)
	local silver = math.floor(copper % 10000 / 100)
	local cents = copper % 100
	if gold > 0 then
		-- Once the gold figure is shortened, the copper is dropped: the short
		-- form is used where it has to fit, and the trailing copper was what
		-- pushed it past the line. Silver stays while it is there.
		if gold >= 10000 then
			return sign..GoldText(gold)..(silver > 0 and (" "..silver.."s") or "")
		end
		return string.format("%s%s %ss %sc", sign, GoldText(gold), silver, cents)
	end
	if silver > 0 then
		return string.format("%s%ss %sc", sign, silver, cents)
	end
	return string.format("%s%sc", sign, cents)
end
ns.FormatMoneyPlain = FormatMoneyPlain

-- Signed change: "+12g 40s" / "-3s 20c".
function ns.FormatMoneyDelta(copper)
	copper = math.floor(tonumber(copper) or 0)
	if copper > 0 then
		return "+"..FormatMoneyPlain(copper)
	end
	if copper < 0 then
		return "-"..FormatMoneyPlain(-copper)
	end
	return "0c"
end

-- The coins are the client's own textures, lifted from its coin string rather
-- than drawn by hand, so a shortened gold figure sits beside the same icons as
-- every other box.
local coinIcons = {}

local function CoinIcon(kind, fontHeight)
	local key = kind..tostring(fontHeight)
	if coinIcons[key] ~= nil then
		return coinIcons[key]
	end
	local unit = (kind == "Gold" and 10000) or (kind == "Silver" and 100) or 1
	local text = ns.MoneyString(unit, fontHeight)
	local icon = text and text:match("(|T.-|t)") or ""
	coinIcons[key] = icon
	return icon
end

-- Copper -> a texture string with the little coins, straight from the client
-- when it offers one; plain text otherwise. From one thousand gold up the
-- copper is left off, so 1,234g 56s 78c reads "1,234 [gold] 56 [silver]" and
-- stays on one line; from ten thousand the gold count is shortened too, so
-- 260,055g 22c reads "260k [gold] 55 [silver]".
function ns.MoneyString(copper, fontHeight)
	copper = math.floor(tonumber(copper) or 0)
	fontHeight = fontHeight or 14
	local value = math.abs(copper)
	local gold = math.floor(value / 10000)
	if gold >= 1000 then
		-- Four digits of gold, the sign and the coin icons no longer leave
		-- room for copper in a tile. From 1,000g the copper is left off; the
		-- silver stays while there is any, so the figure stays on one line.
		local sign = copper < 0 and "-" or ""
		local goldText = gold >= 10000 and FormatCompact(gold) or FormatNumber(gold)
		local text = sign..goldText..CoinIcon("Gold", fontHeight)
		local silver = math.floor((value % 10000) / 100)
		if silver > 0 then
			text = text.." "..silver..CoinIcon("Silver", fontHeight)
		end
		return text
	end
	local fn = (C_CurrencyInfo and C_CurrencyInfo.GetCoinTextureString) or GetCoinTextureString
	if fn then
		local ok, text = pcall(fn, copper, fontHeight)
		if ok and text and text ~= "" then
			return text
		end
	end
	return FormatMoneyPlain(copper)
end

-- Balances for graph axes and headers: the shortest form, at most two
-- units, with no cents unless cents are the only unit present.
local function FormatMoneyShort(copper)
	copper = math.floor(tonumber(copper) or 0)
	local sign = ""
	if copper < 0 then
		sign = "-"
		copper = -copper
	end
	local gold = math.floor(copper / 10000)
	local silver = math.floor(copper % 10000 / 100)
	local cents = copper % 100
	if gold > 0 then
		return sign..GoldText(gold)..(silver > 0 and (" "..silver.."s") or "")
	end
	if silver > 0 then
		return sign..silver.."s"..(cents > 0 and (" "..cents.."c") or "")
	end
	return sign..cents.."c"
end
ns.FormatMoneyShort = FormatMoneyShort

-- Kept for the call sites that ask for the shortened form by name. The
-- shortening now lives in MoneyString itself, so every box and row has it.
ns.FormatMoneyBig = ns.MoneyString

-- The amount in the client's money colours, one unit at a time:
-- 1g 2s 24c.
local function MoneyColored(copper)
	copper = math.floor(tonumber(copper) or 0)
	local sign = ""
	if copper < 0 then
		sign = "-"
		copper = -copper
	end
	local gold = math.floor(copper / 10000)
	local silver = math.floor(copper % 10000 / 100)
	local cents = copper % 100
	local abbreviated = gold >= 1000
	local parts = {}
	if gold > 0 then
		parts[#parts + 1] = "|cffffd700"..GoldText(gold).."|r"
	end
	if silver > 0 then
		parts[#parts + 1] = "|cffc7c7cf"..silver.."s|r"
	end
	-- A shortened gold figure leaves the copper out, exactly like
	-- FormatMoneyPlain: it is the unit that made the line too wide.
	if not abbreviated and (cents > 0 or #parts == 0) then
		parts[#parts + 1] = "|cffeda55f"..cents.."c|r"
	end
	return sign..table.concat(parts, " ")
end
ns.MoneyColored = MoneyColored

local function FormatDate(timestamp)
	if not timestamp or timestamp <= 0 then
		return "-"
	end
	local month = tonumber(date("%m", timestamp)) or 1
	return string.format("%d %s %s", tonumber(date("%d", timestamp)) or 1, MONTHS[month] or "?", date("%Y", timestamp))
end
ns.FormatDate = FormatDate

local function FormatDateTime(timestamp)
	if not timestamp or timestamp <= 0 then
		return "-"
	end
	return FormatDate(timestamp)..", "..date("%H:%M", timestamp)
end
ns.FormatDateTime = FormatDateTime

local function FormatClock(timestamp)
	if not timestamp or timestamp <= 0 then
		return "-"
	end
	return date("%H:%M", timestamp)
end
ns.FormatClock = FormatClock

-- Yards -> "412 m" / "1.4 km" / "376 km".
local function FormatDistance(yards)
	yards = tonumber(yards) or 0
	local meters = yards * 0.9144
	if meters >= 1000 then
		return string.format("%.0f km", meters / 1000)
	end
	return string.format("%d m", meters)
end
ns.FormatDistance = FormatDistance

-- Drops chat markup: |cAARRGGBB colours, and |T...|t textures.
function ns.StripColors(text)
	text = string.gsub(text or "", "|c%x%x%x%x%x%x%x%x", "")
	text = string.gsub(text, "|r", "")
	text = string.gsub(text, "|T.-|t", "")
	return text
end

-- Table size, used all over the reports.
function ns.CountTable(tbl)
	local count = 0
	for _ in pairs(tbl or {}) do
		count = count + 1
	end
	return count
end

-------------------------------------------------------------------------------
-- Saved variables
-------------------------------------------------------------------------------

local DEFAULTS = {
	version = 1,
	settings = {
		quiet = false,
		announceLevelUps = true,
		autoPlayedSync = true,
		playedSyncBlocked = false,
		copyDirect = false,
		-- Off by default: levels Tally was not running for are left as holes
		-- unless the owner asks for the stretch the client measured to be
		-- shared out between them.
		levelEstimate = false,
		-- Economy graph: false draws one line per selected character, true
		-- combines them into one line. The corner button on the graph flips
		-- it; nothing is stored per character.
		graphCombined = false,
		-- Off by default: AFK time counts as played time, so tracked time
		-- stays close to the server's own /played figure. Ticking this
		-- counts only time at the keyboard instead.
		excludeAfk = false,
		-- One switch per primary tab, all on. A tab switched off stops being
		-- recorded for every character; nothing already stored is removed.
		track = {
			playtime = true,
			economy = true,
			combat = true,
			loot = true,
			explore = true,
		},
		-- Some clients refuse addon combat-log reads with a "blocked"
		-- popup, so the combat log is only read when this is enabled.
		combatLogRead = false,
		-- Cooldown notifications. These are account-wide settings; the
		-- per-cooldown opt-outs live on each character's profession record.
		professionNotify = {
			thisChar = true,
			allSelected = false,
			items = true,
			chat = true,
			chime = true,
			chimeKey = "PING",
			chimeVolume = 0.8,
			colourKey = "yellow",
			intervalValue = 30,
			intervalUnit = "minutes",
			loginNotify = true,
			loginDelay = 20,
			near = true,
			lastSentAt = 0,
		},
		-- Degrees around the minimap's outer edge; 240 is 7 o'clock.
		-- Tongues sits at 120 (11 o'clock) and Ammonia at 180 (9 o'clock),
		-- so the three line up down the left side of the minimap.
		icon = { shown = true, locked = false, angle = 240 },
	},
	chars = {},
}

local function ApplyDefaults(target, defaults)
	for key, value in pairs(defaults) do
		if type(value) == "table" then
			if type(target[key]) ~= "table" then
				target[key] = {}
			end
			ApplyDefaults(target[key], value)
		elseif target[key] == nil then
			target[key] = value
		end
	end
end
ns.MergeDefaults = ApplyDefaults

-- Whether one area of the record is being collected. The settings page turns
-- each of the five primary tabs on and off; a recorder asks here before it
-- writes, so a paused area stops moving while the figures already stored stay
-- exactly where they are.
function ns.Tracks(area)
	local track = ns.db and ns.db.settings and ns.db.settings.track
	return not (track and track[area] == false)
end

-------------------------------------------------------------------------------
-- Character record
-------------------------------------------------------------------------------

local function CreateCharData(name, realm)
	local className, classFile = UnitClass("player")
	local level = UnitLevel("player") or 1
	return {
		name = name,
		realm = realm,
		class = className,
		classFile = classFile,
		race = UnitRace and UnitRace("player") or nil,
		level = level,
		highLevel = level,
		firstLevel = level,
		created = Now(),
		meta = { stamps = {} },
		played = {},
		xp = { total = 0, seconds = 0, byLevel = {} },
		levels = { history = {} },
		tracked = 0,
		alive = 0,
		afk = 0,
		sessions = { count = 0, seconds = 0, longest = 0, history = {} },
		gold = { income = {}, expenses = {}, unclassified = { count = 0, net = 0 }, daily = {}, tx = {} },
		combat = { kills = 0, killTypes = {}, killInfo = {}, killsByZone = {}, killSessions = 0, killingFights = 0, bestFight = 0, best10 = 0, logAvailable = true, fights = 0, combatSeconds = 0, deaths = 0, deathsByZone = {} },
		loot = { items = 0, value = 0, quality = {}, best = {}, itemCounts = {} },
		quests = 0,
		explore = { zones = {}, dungeons = {}, recentFirsts = {}, distance = 0, flights = 0, flightSeconds = 0 },
	}
end

-- Faction lookup for a character record. The live character's faction is
-- read at each login and stored; a record without it falls back to a
-- race-to-faction match. Money can only change hands within one faction
-- on one realm, so this makes a sum of balances meaningful.
local FACTION_BY_RACE = {
	Human = "Alliance", Dwarf = "Alliance", Gnome = "Alliance", Draenei = "Alliance",
	["Night Elf"] = "Alliance", Nightelf = "Alliance", Worgen = "Alliance",
	Orc = "Horde", Undead = "Horde", Tauren = "Horde", Troll = "Horde",
	Goblin = "Horde", ["Blood Elf"] = "Horde", Bloodelf = "Horde",
}
function ns.CharFaction(char)
	if not char then
		return nil
	end
	if char.faction then
		return char.faction
	end
	local race = char.race
	if not race then
		return nil
	end
	if FACTION_BY_RACE[race] then
		return FACTION_BY_RACE[race]
	end
	for name, faction in pairs(FACTION_BY_RACE) do
		if string.find(race, name, 1, true) then
			return faction
		end
	end
	return nil
end

function ns.GetChar()
	local db = ns.db
	if not db or not ns.charKey then
		return nil
	end
	return db.chars[ns.charKey]
end

-- Timestamp of the newest evidence for a character: the /played sync time
-- when present, otherwise the latest session, level-up or creation time.
-- Data for a logged-out character is a snapshot; this dates it.
local function LastSeen(char)
	if not char then
		return nil
	end
	local best = char.played and char.played.at
	local function Consider(at)
		if at and at > 0 and (not best or at > best) then
			best = at
		end
	end
	local sessions = char.sessions
	if sessions then
		local history = sessions.history
		if history and #history > 0 then
			local last = history[#history]
			Consider(last.stop)
			if last.start then
				Consider(last.start + (last.seconds or 0))
			end
		end
		if sessions.current then
			Consider(sessions.current.last)
		end
	end
	local levels = char.levels and char.levels.history
	if levels and #levels > 0 then
		Consider(levels[#levels].at)
	end
	return best or char.created
end
ns.LastSeen = LastSeen

-- The character the window and the reports describe: the viewed character
-- when a viewer is active, otherwise the one being played. Read-only;
-- recording always targets the logged-in character, the only one the
-- client reports.
function ns.ViewChar()
	if not ns.viewKey or not ns.db then
		return nil
	end
	local char = ns.db.chars[ns.viewKey]
	if not char or ns.viewKey == ns.charKey then
		ns.viewKey = nil
		return nil
	end
	return char
end

function ns.IsViewing()
	return ns.ViewChar() ~= nil
end

-- Switching the viewer. nil (or the character being played) goes back to live
-- data. Never saved: a login always starts on the live character.
function ns.SetView(key)
	if not key or key == ns.charKey or not (ns.db and ns.db.chars[key]) then
		key = nil
	end
	ns.viewKey = key
end

function ns.ReportChar()
	return ns.ViewChar() or ns.GetChar()
end

-- Every character Tally has watched: the live one first, then the rest by
-- most recent evidence. A character that never logged in with Tally loaded
-- cannot appear; the client gives an addon no way to read it.
function ns.KnownCharacters()
	local list = {}
	if not ns.db then
		return list
	end
	for key, char in pairs(ns.db.chars) do
		list[#list + 1] = { key = key, char = char, live = (key == ns.charKey), seen = LastSeen(char) }
	end
	table.sort(list, function(a, b)
		if a.live ~= b.live then
			return a.live
		end
		if (a.seen or 0) ~= (b.seen or 0) then
			return (a.seen or 0) > (b.seen or 0)
		end
		return tostring(a.key) < tostring(b.key)
	end)
	return list
end

-- True when another stored record shares this character's name and class,
-- i.e. the two are indistinguishable by name alone and need a fuller name.
local function NameIsShared(char)
	if not (ns.db and ns.db.chars) then
		return false
	end
	for _, other in pairs(ns.db.chars) do
		if other ~= char and (other.name or "?") == (char.name or "?")
			and (other.classFile or "") == (char.classFile or "") then
			return true
		end
	end
	return false
end

-- Name shown on screen and in reports. Defaults to the first name, what
-- UnitName returns. When another stored record shares that name and class,
-- the full name is used instead, since it is the only field that tells
-- them apart.
function ns.DisplayName(char)
	if not char then
		return "?"
	end
	local name = char.name or "?"
	if NameIsShared(char) then
		if char.surname then
			return name.." "..char.surname
		end
		-- No surname known: append the level, the only differing field,
		-- rather than repeating the same name.
		return name.." (L"..(char.level or 0)..")"
	end
	return name
end

-- The name with the surname, where the client reported one. The overview
-- title uses this; lists keep ns.DisplayName so their rows stay narrow.
function ns.FullName(char)
	if not char then
		return "?"
	end
	local name = char.name or "?"
	if char.surname and char.surname ~= "" then
		return name.." "..char.surname
	end
	return name
end

-- Extracts a surname for the character. UnitName returns the first name
-- only, so GetUnitName (a single string) is tried first and the returns of
-- UnitFullName are the fallback. A value is accepted only when it is a
-- suffix of the display name, not the realm, and not the first name.
-- /tally surname sets it manually when the client gives nothing.
local function DetectSurname(name, realm)
	local display
	if GetUnitName then
		local ok, value = pcall(GetUnitName, "player")
		if ok and type(value) == "string" and value ~= "" then
			display = value
		end
	end
	if type(display) == "string" and #display > #name and string.sub(display, 1, #name) == name then
		local rest = ns.Trim(string.sub(display, #name + 1))
		if rest ~= "" and #rest <= 24 then
			return rest
		end
	end
	if not UnitFullName then
		return nil
	end
	local ok, full, second = pcall(UnitFullName, "player")
	if not ok then
		return nil
	end
	if type(full) == "string" and full ~= name and string.sub(full, 1, #name) == name then
		local rest = ns.Trim(string.sub(full, #name + 1))
		if rest ~= "" and #rest <= 24 then
			return rest
		end
	end
	if type(second) == "string" and second ~= "" and second ~= realm and #second <= 24 then
		-- Some clients put the surname in the slot that normally holds
		-- the realm; accepted because it differs from the reported realm.
		return second
	end
	return nil
end

-- Highest level this record has been seen at, across highLevel, firstLevel
-- and the level-up history. Levels never decrease, so a login below this is
-- evidence of a second character sharing the first name.
local function HighestLevel(char)
	local peak = char.highLevel or char.level or 0
	if (char.firstLevel or 0) > peak then
		peak = char.firstLevel
	end
	local history = (char.levels and char.levels.history) or {}
	for index = 1, #history do
		local levelUp = history[index]
		if (levelUp.level or 0) > peak then
			peak = levelUp.level
		end
	end
	return peak
end

-- A record can predate any subtree a later view indexes. Fill the shape once
-- for the live character at login and for every stored record at load, so no
-- view has to guess whether the save came from a version that created them.
local function EnsureCharShape(char)
	if type(char) ~= "table" then
		return
	end
	if type(char.meta) ~= "table" then
		char.meta = {}
	end
	if type(char.meta.stamps) ~= "table" then
		char.meta.stamps = {}
	end
	if type(char.gold) ~= "table" then
		char.gold = {}
	end
	local goldStore = char.gold
	if type(goldStore.income) ~= "table" then goldStore.income = {} end
	if type(goldStore.expenses) ~= "table" then goldStore.expenses = {} end
	if type(goldStore.daily) ~= "table" then goldStore.daily = {} end
	if type(goldStore.tx) ~= "table" then goldStore.tx = {} end
	if type(goldStore.unclassified) ~= "table" then goldStore.unclassified = {} end
	goldStore.unclassified.count = tonumber(goldStore.unclassified.count) or 0
	goldStore.unclassified.net = tonumber(goldStore.unclassified.net) or 0
	if type(char.loot) ~= "table" then
		char.loot = {}
	end
	char.loot.items = tonumber(char.loot.items) or 0
	char.loot.value = tonumber(char.loot.value) or 0
	if type(char.loot.quality) ~= "table" then char.loot.quality = {} end
	if type(char.loot.best) ~= "table" then char.loot.best = {} end
	if type(char.loot.itemCounts) ~= "table" then char.loot.itemCounts = {} end
	if type(char.explore) ~= "table" then
		char.explore = {}
	end
	if type(char.explore.zones) ~= "table" then char.explore.zones = {} end
	if type(char.explore.dungeons) ~= "table" then char.explore.dungeons = {} end
	if type(char.explore.recentFirsts) ~= "table" then char.explore.recentFirsts = {} end
	char.explore.distance = tonumber(char.explore.distance) or 0
	if type(char.fishing) ~= "table" then
		char.fishing = {}
	end
	if type(char.fishing.items) ~= "table" then char.fishing.items = {} end
	if type(char.fishing.zones) ~= "table" then char.fishing.zones = {} end
	if type(char.fishing.levels) ~= "table" then char.fishing.levels = {} end
	char.fishing.casts = tonumber(char.fishing.casts) or 0
	char.fishing.catches = tonumber(char.fishing.catches) or 0
	if type(char.gathering) ~= "table" then
		char.gathering = {}
	end
	if type(char.currency) ~= "table" then
		char.currency = {}
	end
	if type(char.professions) == "table" and type(char.professions.byLevel) ~= "table" then
		char.professions.byLevel = {}
	end
	if type(char.played) ~= "table" then
		char.played = {}
	end
	if type(char.levels) ~= "table" then
		char.levels = {}
	end
	if type(char.levels.history) ~= "table" then
		char.levels.history = {}
	end
	if type(char.sessions) ~= "table" then
		char.sessions = {}
	end
	if type(char.sessions.history) ~= "table" then
		char.sessions.history = {}
	end
	if type(char.combat) ~= "table" then
		char.combat = {}
	end
	char.quests = tonumber(char.quests) or 0
	char.tracked = tonumber(char.tracked) or 0
	char.alive = tonumber(char.alive) or 0
	char.afk = tonumber(char.afk) or 0
end
ns.EnsureCharShape = EnsureCharShape

local function InitializeCharacter()
	ns.loginAt = Now()
	ns.lastQuestTurnInAt = nil
	ns.lastKillAt = nil
	ns.lastDiscoveryAt = nil
	local name = UnitName("player") or "Unknown"
	local realm = GetRealmName() or "Unknown"
	local baseKey = name.."-"..realm
	local level = UnitLevel("player") or 0
	local className, classFile = UnitClass("player")

	-- Selects the record this login writes to. The base key is
	-- name.."-"..realm unless another character already holds it: two
	-- characters on this client can share the first name, and UnitName
	-- reports the first name only. Identity is decided by the client's
	-- character id ("Player-<realm>-<id>") when one is present; otherwise
	-- a level below the record's highest, or a different class, marks a
	-- second character. That character is filed under "<base>#<n>", never
	-- merged, because a record holds running totals only and a merge is
	-- irreversible. A different id also marks a second character, but only
	-- in that exact "Player-" shape, so an unusual id cannot create a
	-- fresh record on every login.
	local guid = UnitGUID and UnitGUID("player") or nil
	if type(guid) ~= "string" or not string.find(guid, "^Player%-") then
		guid = nil
	end
	local base = ns.db.chars[baseKey]
	local shared = false
	if base then
		if guid and base.guid and base.guid ~= guid then
			shared = true
		elseif level > 0 and HighestLevel(base) > level then
			shared = true
		elseif classFile and base.classFile and base.classFile ~= classFile then
			shared = true
		end
	end
	local key = baseKey
	if shared then
		for slot = 2, 9 do
			local candidateKey = baseKey.."#"..slot
			local candidate = ns.db.chars[candidateKey]
			if not candidate then
				key = candidateKey
				break
			end
			-- The id is exact; the level and class checks below are the
			-- fallback for clients that do not provide one.
			if guid and candidate.guid == guid then
				key = candidateKey
				break
			end
			if (not classFile or not candidate.classFile or candidate.classFile == classFile)
				and HighestLevel(candidate) <= level then
				key = candidateKey
				break
			end
		end
	end
	-- The same character under a new name (a rename or a realm transfer)
	-- keeps one record: the stored GUID is exact, so move the old one rather
	-- than starting a second and counting its lifetime twice in totals.
	if guid and ns.db.chars then
		for candidateKey, candidate in pairs(ns.db.chars) do
			if candidateKey ~= key and candidate.guid == guid then
				ns.db.chars[key] = candidate
				ns.db.chars[candidateKey] = nil
				local selection = ns.db.settings and ns.db.settings.totalSelect
				if type(selection) == "table" and selection[candidateKey] ~= nil then
					selection[key] = selection[candidateKey]
					selection[candidateKey] = nil
				end
				ns.Trace("character identity: record moved from "..candidateKey.." to "..key)
				break
			end
		end
	end
	ns.charKey = key
	ns.playerName = name
	-- A login always starts on the character being played, not the one
	-- last on screen.
	ns.viewKey = nil

	local char = ns.db.chars[key]
	if not char then
		char = CreateCharData(name, realm)
		ns.db.chars[key] = char
	end
	if type(char.meta) ~= "table" then
		char.meta = {}
	end
	if type(char.meta.stamps) ~= "table" then
		char.meta.stamps = {}
	end
	EnsureCharShape(char)
	char.name = name
	char.realm = realm
	if guid then
		char.guid = guid
	end
	local surname = DetectSurname(name, realm)
	if surname then
		char.surname = surname
	end
	char.class = className or char.class
	char.classFile = classFile or char.classFile
	char.race = (UnitRace and UnitRace("player")) or char.race
	if UnitFactionGroup then
		local faction = UnitFactionGroup("player")
		if faction then
			char.faction = faction
		end
	end
	char.level = level > 0 and level or char.level
	if char.firstLevel == nil then
		char.firstLevel = char.level
	end
	if not char.highLevel or (char.level or 0) > char.highLevel then
		char.highLevel = char.level
	end
	if shared then
		ns.Print(string.format("Tally: '%s' is the first name of more than one character - this login is recorded separately from the one at level %d. /tally surname <second name> lets the two be told apart.",
			name, HighestLevel(base)))
	end
	-- XP bookkeeping. Older installs have no table. The first sample after
	-- a login sets the mark without crediting XP, so a gap in the bar is
	-- not counted as gained.
	if not char.xp then
		char.xp = { total = 0, seconds = 0, byLevel = {} }
	end
	char.xp.total = tonumber(char.xp.total) or 0
	char.xp.seconds = tonumber(char.xp.seconds) or 0
	if type(char.xp.byLevel) ~= "table" then
		char.xp.byLevel = {}
	end
	char.xp.last = nil
	-- Whether the combat-log read is on is one thing; kills themselves can
	-- still be counted from nameplates, so the UI no longer treats this as
	-- "kills unavailable".
	char.combat.logAvailable = (ns.db.settings.combatLogRead and ns.CombatLogUsable()) and true or false
	-- Fights and in-combat seconds come from the entering/leaving-combat
	-- events, available on every client even where the combat log is not.
	char.combat.fights = char.combat.fights or 0
	char.combat.combatSeconds = char.combat.combatSeconds or 0
	char.combat.deaths = char.combat.deaths or 0
	char.combat.killTypes = char.combat.killTypes or {}
	char.combat.killInfo = char.combat.killInfo or {}
	char.combat.killsByZone = char.combat.killsByZone or {}
	if type(char.combat.deathsByZone) ~= "table" then
		char.combat.deathsByZone = {}
	end
	char.combat.killSessions = char.combat.killSessions or 0
	char.combat.killingFights = char.combat.killingFights or 0
	char.combat.bestFight = char.combat.bestFight or 0
	char.combat.best10 = char.combat.best10 or 0
	char.combat.killsAvailable = ns.killSource ~= nil
	char.combat.killSource = ns.killSource
	-- The averages are measured only from the point kill counting began: the
	-- fights and tracked seconds before it carry no kill data.
	if char.combat.killBaseFights == nil then
		char.combat.killBaseFights = char.combat.fights
		char.combat.killBaseCombat = char.combat.combatSeconds
		char.combat.killBaseTracked = char.tracked or 0
	end
	local wasInFight = char.combat.inFight and true or false
	char.combat.currentFightKills = 0
	char.combat.currentFightLastAt = nil
	char.combat.currentFightZone = nil
	char.combat.inFight = false
	if UnitAffectingCombat and UnitAffectingCombat("player") and ns.Tracks("combat") then
		-- The entering-combat event does not fire for a fight already running
		-- at login or after a /reload. Count it only when the saved state did
		-- not already have this fight open, so a reload does not add a second
		-- fight for the same pull.
		if not wasInFight then
			char.combat.fights = char.combat.fights + 1
		end
		char.combat.inFight = true
	end
	return char
end

-------------------------------------------------------------------------------
-- Runtime state (never saved)
-------------------------------------------------------------------------------

local questPending, questAt = false, 0
-- The quests block. Experience is booked to a quest only when it arrives in
-- the seconds after that quest was turned in, and reward money only while its
-- own window is open; each window is set by the events, and neither reads the
-- other's state. Both windows open on a real turn-in only: QUEST_TURNED_IN
-- where the game sends it, otherwise QUEST_FINISHED after a dialog opened.
-- The boxes count, they do not list quests, so no quest name is read or kept.
local questXpUntil = 0
-- Experience lines that arrived just before a turn-in event opened the
-- window. The client can send the XP line and the turn-in event in either
-- order, so a small buffer lets the line that arrived first still be booked.
local recentXpGains = {}
local playedRequestAt = 0         -- when Tally last asked for /played itself
local forbiddenSeen = {}          -- [function name] = true, reported once
local beginPlayDone = false      -- start-of-play work, once per load
local sessionResumed = false     -- session boundary, set at world entry
local worldEntered = false       -- a world entry has happened this load
local playerGUID
local lastPlayedSync = 0
local playedRetryAt = 0           -- next repeat of an unanswered level-up request
local pendingLevelSnapshot

-- Forward declarations. ResetCharStats (below) calls into session and
-- /played bookkeeping defined later, so these names must exist here for its
-- closure to resolve.
local StartSession
local RequestPlayedSync

-- Wipes this character's statistics but keeps the addon settings. Used by
-- the Settings tab, after a confirmation popup.
function ns.ResetCharStats()
	local char = ns.GetChar()
	if not char then
		return
	end
	local fresh = CreateCharData(char.name, char.realm)
	local money = GetMoney()
	fresh.gold.balance = money
	fresh.gold.first = money
	ns.db.chars[ns.charKey] = fresh
	-- The windows for a turn-in's experience and reward money belong to the
	-- record that has just been replaced, so both are closed.
	questXpUntil = 0
	ns.moneyContext.questGoldUntil = 0
	-- The character is standing somewhere: re-note that zone as the fresh
	-- record's first entry.
	ns.ResumeZone()
	StartSession(Now())
	RequestPlayedSync()
	if ns.OnDataTick then
		ns.OnDataTick()
	end
end

-- Experience that arrives in the seconds after a turn-in. The client's only
-- word on where experience came from is the XP-gain line, and it names no
-- source, so anything inside the window after QUEST_FINISHED is booked to that
-- quest and everything else is ignored: Tally never guesses at the rest.
local function AddQuestXp(amount, why)
	local char = ns.GetChar()
	if not char then
		return
	end
	char.questXp = (char.questXp or 0) + amount
	ns.Trace("quest xp: +"..amount.." "..why)
	if ns.OnDataTick then
		ns.OnDataTick()
	end
end

-- The client can hand the XP line over a moment before the turn-in event that
-- opens the window. A line held for a couple of seconds is booked when the
-- window opens; the lookback stays short so a mob killed just before the
-- turn-in is not credited to the quest.
local function BookRecentQuestXp()
	local now = Now()
	local lookback = math.min(2, TUNING.questXpWindow)
	local kept, booked = {}, 0
	for index = 1, #recentXpGains do
		local gain = recentXpGains[index]
		if now - gain.at <= lookback then
			booked = booked + gain.amount
		else
			kept[#kept + 1] = gain
		end
	end
	recentXpGains = kept
	if booked > 0 then
		AddQuestXp(booked, "from a line that arrived just before the turn-in")
	end
end

local function OnXpMessage(text)
	if not text or not ns.Tracks("explore") then
		return
	end
	-- Any thousands separator the client uses is dropped; only the digits are
	-- wanted, so "1,234", "1.234" and "1 234" all read as 1234.
	local number = string.match(text, "%d[%d,%.%s]*")
	if not number then
		return
	end
	local digits = string.gsub(number, "%D", "")
	local amount = tonumber(digits)
	if not amount or amount <= 0 then
		return
	end
	if Now() <= questXpUntil then
		AddQuestXp(amount, "within "..TUNING.questXpWindow.."s of a turn-in")
		return
	end
	-- Outside the window: hold it briefly in case the turn-in event is the
	-- next thing to arrive.
	recentXpGains[#recentXpGains + 1] = { at = Now(), amount = amount }
	local lookback = math.min(2, TUNING.questXpWindow)
	while #recentXpGains > 0 and Now() - recentXpGains[1].at > lookback do
		table.remove(recentXpGains, 1)
	end
end

-------------------------------------------------------------------------------
-- Combat
-------------------------------------------------------------------------------

-- Kill times inside the rolling ten-minute window, newest last. Session state,
-- not saved: a reload starts a fresh window, while the best record is kept.
local killWindow = {}

local function PruneKillTypes(char)
	local types = char.combat.killTypes or {}
	char.combat.killTypes = types
	local count = 0
	for _ in pairs(types) do
		count = count + 1
	end
	if count <= TUNING.killTypeCap + 20 then
		return
	end
	local list = {}
	for name, killed in pairs(types) do
		list[#list + 1] = { name = name, count = killed }
	end
	table.sort(list, function(a, b)
		if a.count == b.count then
			return a.name < b.name
		end
		return a.count > b.count
	end)
	local fresh, infos = {}, {}
	local oldInfo = char.combat.killInfo or {}
	for index = 1, math.min(#list, TUNING.killTypeCap) do
		local name = list[index].name
		fresh[name] = list[index].count
		if oldInfo[name] then
			infos[name] = oldInfo[name]
		end
	end
	char.combat.killTypes = fresh
	char.combat.killInfo = infos
end

local function AddKill(creatureName, zone)
	local char = ns.GetChar()
	if not char or not ns.Tracks("combat") then
		return
	end
	creatureName = creatureName or "Unknown"
	zone = zone or (type(GetRealZoneText) == "function" and GetRealZoneText()) or ""
	if zone == "" then
		zone = "?"
	end
	local combat = char.combat
	local at = Now()
	combat.kills = (combat.kills or 0) + 1
	combat.killsFirstAt = combat.killsFirstAt or at
	combat.killsLastAt = at
	if ns.Touch then
		ns.Touch(char, "combat.kills", at)
	end
	if ns.NoteKillMilestone then
		ns.NoteKillMilestone(combat.kills)
	end
	local types = combat.killTypes or {}
	combat.killTypes = types
	types[creatureName] = (types[creatureName] or 0) + 1
	combat.killInfo = combat.killInfo or {}
	local info = combat.killInfo[creatureName]
	if not info then
		info = { first = at, last = at, zones = {} }
		combat.killInfo[creatureName] = info
	end
	info.last = at
	info.updatedAt = at
	info.zones = info.zones or {}
	info.zones[zone] = (info.zones[zone] or 0) + 1
	combat.killsByZone = combat.killsByZone or {}
	combat.killsByZone[zone] = (combat.killsByZone[zone] or 0) + 1
	local session = char.sessions.current
	if session then
		-- A session counts towards the per-session average only when it has a
		-- kill, so an idle login cannot pull the figure down.
		if (session.kills or 0) == 0 then
			combat.killSessions = (combat.killSessions or 0) + 1
		end
		session.kills = (session.kills or 0) + 1
	end
	if combat.inFight then
		combat.currentFightKills = (combat.currentFightKills or 0) + 1
		combat.currentFightLastAt = at
		combat.currentFightZone = zone
	end
	-- The rolling window is the best ten minutes, not a fixed clock block: a
	-- window starts at every kill and counts the kills within the next ten
	-- minutes, so no good stretch is cut in half by the clock.
	killWindow[#killWindow + 1] = GetTime()
	local cutoff = GetTime() - 600
	local first = 1
	while first <= #killWindow and killWindow[first] < cutoff do
		first = first + 1
	end
	if first > 1 then
		local kept = {}
		for index = first, #killWindow do
			kept[#kept + 1] = killWindow[index]
		end
		killWindow = kept
	end
	local recent = #killWindow
	if recent > (combat.best10 or 0) then
		combat.best10 = recent
		combat.best10At = at
		if ns.NoteRecord then
			ns.NoteRecord("combat.best10", recent, at)
		end
	end
	combat.killsHeard = true
	ns.lastKillAt = at
	if ns.NoteRecentEvent then
		ns.NoteRecentEvent("kill", {
			at = at, zone = zone, how = "kill", evidence = "unit_died_event",
			data = { name = creatureName },
		})
	end
	if ns.killSource then
		combat.killSource = ns.killSource
	end
	PruneKillTypes(char)
end

-- The nameplate module's way in. It lives above the UI so the whole kill
-- record has one writer, whichever source saw the death.
function ns.NoteKill(creatureName, zone)
	AddKill(creatureName, zone)
	if ns.OnDataTick then
		ns.OnDataTick()
	end
end

-- Fights come from entering and leaving combat: one per uninterrupted stretch,
-- with the duration accumulated by the ticker into char.combat.combatSeconds,
-- which keeps in-combat and out-of-combat time summing to tracked time exactly.
local function OnCombatStateChanged(inCombat)
	local char = ns.GetChar()
	if not char or not ns.Tracks("combat") then
		return
	end
	local combat = char.combat
	if inCombat then
		combat.fights = (combat.fights or 0) + 1
		if ns.Touch then
			ns.Touch(char, "combat.fights", Now())
		end
		combat.inFight = true
		combat.currentFightKills = 0
		combat.currentFightLastAt = nil
		combat.currentFightZone = nil
		local session = char.sessions.current
		if session then
			session.fights = (session.fights or 0) + 1
		end
	else
		combat.inFight = false
		local kills = combat.currentFightKills or 0
		if kills > 0 then
			combat.killingFights = (combat.killingFights or 0) + 1
			if kills > (combat.bestFight or 0) then
				combat.bestFight = kills
				combat.bestFightAt = combat.currentFightLastAt or Now()
				combat.bestFightZone = combat.currentFightZone
				if ns.NoteRecord then
					ns.NoteRecord("combat.bestFight", kills, combat.bestFightAt)
				end
			end
		end
		combat.currentFightKills = 0
		combat.currentFightLastAt = nil
		combat.currentFightZone = nil
	end
	if ns.OnDataTick then
		ns.OnDataTick()
	end
end

-- Which combat-log accessor this client exposes. Read-only: it checks that
-- a name exists and never calls it.
function ns.CombatLogAccessor()
	if type(CombatLogGetCurrentEventInfo) == "function" then
		return "CombatLogGetCurrentEventInfo"
	end
	if type(C_CombatLog) == "table" and type(C_CombatLog.GetCurrentEventInfo) == "function" then
		return "C_CombatLog.GetCurrentEventInfo"
	end
	if type(C_CombatLogSecure) == "table" and type(C_CombatLogSecure.GetCurrentEventInfo) == "function" then
		return "C_CombatLogSecure.GetCurrentEventInfo"
	end
	return nil
end

-- Kill tracking is offered only when the client can serve a read. Some
-- clients have no accessor and also refuse registration for
-- COMBAT_LOG_EVENT_UNFILTERED with a "blocked" popup, so the check is
-- made locally rather than by registering.
function ns.CombatLogUsable()
	return ns.CombatLogAccessor() ~= nil
end

-- Combat-log handler. On this client the event tuple is read through
-- C_CombatLogSecure; clients that pass the tuple directly to the handler
-- take the first branch. If neither works, kill tracking disables itself
-- and the UI shows a dash.
local function OnCombatLogEvent(...)
	local char = ns.GetChar()
	if not char then
		return
	end
	local timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName
	if select("#", ...) >= 2 then
		timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName = ...
	else
		-- Clients differ in how the tuple is read when it is not passed to
		-- the handler. Try each reader the accessor knows, in the same order.
		local readers = {
			C_CombatLogSecure and C_CombatLogSecure.GetCurrentEventInfo,
			C_CombatLog and C_CombatLog.GetCurrentEventInfo,
			CombatLogGetCurrentEventInfo,
		}
		local refused = false
		for index = 1, 3 do
			local reader = readers[index]
			if type(reader) == "function" then
				local ok, a, b, c, d, e, f, g, h, i = pcall(reader)
				if ok and type(b) == "string" then
					timestamp, subevent, hideCaster, sourceGUID, sourceName, sourceFlags, sourceRaidFlags, destGUID, destName = a, b, c, d, e, f, g, h, i
					break
				end
				refused = true
			end
		end
		if not subevent then
			char.combat.logAvailable = false
			if refused and ns.db.settings.combatLogRead and ns.ApplyCombatLogSetting then
				-- A reader exists but the client refused it: stop asking
				-- rather than retry on every nearby death.
				ns.db.settings.combatLogRead = false
				ns.ApplyCombatLogSetting("The client refused the combat-log read - kill tracking is off again (leave it off in this game).")
			end
			return
		end
	end
	if type(subevent) ~= "string" then
		char.combat.logAvailable = false
		return
	end
	char.combat.logHeard = true
	if subevent == "PARTY_KILL" then
		if (playerGUID and sourceGUID == playerGUID) or (sourceName and sourceName == ns.playerName) then
			AddKill(destName)
		end
	elseif subevent == "UNIT_DIED" then
		if playerGUID and destGUID == playerGUID and char.combat.lastDeath and not char.combat.lastDeath.killer then
			char.combat.lastDeath.killer = sourceName
		end
	end
end

-------------------------------------------------------------------------------
-- Playtime and levels
-------------------------------------------------------------------------------

-- Requests a /played sync from the client. Some clients answer an addon
-- attempt with the "blocked" popup; on those settings.playedSyncBlocked
-- turns further requests off, and a manual /played still feeds numbers in
-- through TIME_PLAYED_MSG.
function RequestPlayedSync()
	if ns.db.settings.playedSyncBlocked or not ns.db.settings.autoPlayedSync
		or not ns.Tracks("playtime") then
		return
	end
	if RequestTimePlayed then
		ns.Trace("asking the client for /played")
		-- Remembered so the client's own printed reply can be kept off the
		-- screen for a few seconds: the numbers are read either way, so the
		-- request costs the player nothing but chat noise otherwise.
		playedRequestAt = Now()
		pcall(RequestTimePlayed)
	end
end
ns.RequestPlayedSync = RequestPlayedSync

-- Handles TIME_PLAYED_MSG(totalTime, timePlayedThisLevel), both read from
-- the client. The values are stored as given, never computed from the
-- ticker, so they remain correct across days Tally did not observe.
local function OnTimePlayedMsg(totalTime, levelTime)
	local char = ns.GetChar()
	if not char or not totalTime or not ns.Tracks("playtime") then
		return
	end
	ns.Trace("client /played reply: total "..tostring(totalTime).."s, this level "..tostring(levelTime).."s")
	local now = Now()
	local level = UnitLevel("player") or char.level
	local played = char.played
	-- A reply without the "this level" figure keeps the last one for the
	-- display, but it cannot pin where the level began, so the reading is
	-- marked rather than corrected.
	local levelTimeKnown = (levelTime ~= nil)
	if not levelTimeKnown then
		levelTime = played.levelTime
	end
	local previousLevel = played.level
	local previousTotal = played.total

	-- Measures the level that just ended. The client's "this level" figure
	-- has already reset to about 0s for the new level at a level-up, so the
	-- finished level is computed as total played now minus total played when
	-- that level started, matching the Playtime tab's level-ups card.
	local finishedLevel, finishedSeconds, finishedGap, finishedPartial

	local pendingEntry = pendingLevelSnapshot and pendingLevelSnapshot.entry
	-- A reload between the level-up and the /played reply drops the in-memory
	-- snapshot but leaves its pending row in the history. Recover it here so
	-- the reply finalizes that row instead of appending a second one.
	if not pendingEntry then
		local last = char.levels and char.levels.history
			and char.levels.history[#char.levels.history]
		if last and last.pending and last.level == level then
			pendingEntry = last
			pendingLevelSnapshot = {
				level = last.level, at = last.at,
				zone = last.zone, zoneKind = last.zoneKind,
				entry = last,
			}
			ns.Trace("level history: recovered pending level "..tostring(level).." after a reload")
		end
	end
	local fallbackZone, fallbackKind
	if not pendingEntry and ns.MilestoneContext then
		fallbackZone, fallbackKind = ns.MilestoneContext()
	end
	if pendingEntry and pendingEntry.level == level then
		local endedAt = pendingEntry.at or now
		pendingEntry.total = totalTime
		pendingEntry.levelTime = levelTime
		pendingEntry.levelTimeUnknown = (not levelTimeKnown) or nil
		pendingEntry.partial = (not levelTimeKnown) or nil
		pendingEntry.startedAt = pendingEntry.at or now
		pendingEntry.pending = nil
		local previousEntry = char.levels.history[#char.levels.history - 1]
		if previousEntry and previousEntry ~= pendingEntry then
			previousEntry.endedAt = endedAt
			previousEntry.observed = previousEntry.observed or "live"
			local gap = (level > (previousEntry.level or 0) + 1)
			finishedLevel, finishedGap = previousEntry.level, gap
			local usableStart = previousEntry.total and not gap and totalTime > previousEntry.total
			if usableStart then
				local partial = (previousEntry.levelTimeUnknown or previousEntry.levelTime == nil) and true or false
				local startTotal = previousEntry.total
				if not partial then
					startTotal = previousEntry.total - previousEntry.levelTime
				end
				local endTotal = totalTime
				if levelTimeKnown then
					endTotal = totalTime - (levelTime or 0)
				end
				if endTotal - startTotal > 0 then
					finishedSeconds = endTotal - startTotal
					finishedPartial = partial
					previousEntry.seconds = finishedSeconds
					previousEntry.secondsPartial = partial or nil
				end
			end
		end
	elseif previousTotal == nil then
		-- First snapshot: the stretch before it was not observed, so the
		-- entry is flagged partial.
		local entry = {
			level = level, total = totalTime, levelTime = levelTime, at = now, partial = true,
			levelTimeUnknown = (not levelTimeKnown) or nil,
			startedAt = (char.firstSeen and char.firstSeen.level == level and char.firstSeen.at) or nil,
			observed = "live",
			zone = (pendingLevelSnapshot and pendingLevelSnapshot.zone) or fallbackZone,
			zoneKind = (pendingLevelSnapshot and pendingLevelSnapshot.zoneKind) or fallbackKind,
		}
		char.levels.history[#char.levels.history + 1] = entry
		if ns.NoteEvent then
			local event = ns.NoteEvent("level_up", {
				at = now, zone = entry.zone, zoneKind = entry.zoneKind,
				how = "level_up", evidence = "level_event", observed = "live",
				data = {
					level = level, total = totalTime, levelTime = levelTime, partial = true,
				},
			})
			if event then
				entry.event = event.id
			end
		end
	elseif previousLevel and level > previousLevel then
		-- One or more level-ups happened since the last reading. The jump is
		-- stored as it stands, never split into invented levels; the points
		-- reader divides it with Tally's own count where that count covers
		-- the stretch.
		local gap = (level > previousLevel + 1)
		local startedAt = char.levels.history[#char.levels.history]
		if startedAt then
			startedAt.endedAt = now
			startedAt.observed = startedAt.observed or "live"
		end
		local entry = {
			level = level, total = totalTime, levelTime = levelTime, at = now,
			gap = gap, levelTimeUnknown = (not levelTimeKnown) or nil,
			startedAt = now,
			observed = "live",
			zone = (pendingLevelSnapshot and pendingLevelSnapshot.zone) or fallbackZone,
			zoneKind = (pendingLevelSnapshot and pendingLevelSnapshot.zoneKind) or fallbackKind,
		}
		char.levels.history[#char.levels.history + 1] = entry
		if ns.NoteEvent then
			local event = ns.NoteEvent("level_up", {
				at = now, zone = entry.zone, zoneKind = entry.zoneKind,
				how = "level_up", evidence = "level_event", observed = "live",
				data = {
					level = level, total = totalTime, levelTime = levelTime, gap = gap,
				},
			})
			if event then
				entry.event = event.id
			end
		end
		finishedLevel, finishedGap = previousLevel, gap
		-- A time is claimed only when the finished level can be measured:
		-- one level gained (no gap) and a start the client can pin. Both
		-- ends are the total at a level's start, which is the reading minus
		-- the time the client says it had already spent on that level; a
		-- reply without that figure leaves a lower bound.
		local usableStart = startedAt and startedAt.total and not gap and totalTime > startedAt.total
		if usableStart then
			local partial = (startedAt.levelTimeUnknown or startedAt.levelTime == nil) and true or false
			local startTotal = startedAt.total
			if not partial then
				startTotal = startedAt.total - startedAt.levelTime
			end
			local endTotal = totalTime
			if levelTimeKnown then
				endTotal = totalTime - (levelTime or 0)
			end
			if endTotal - startTotal > 0 then
				finishedSeconds = endTotal - startTotal
				finishedPartial = partial
				startedAt.seconds = finishedSeconds
				startedAt.secondsPartial = partial or nil
			end
		end
	end

	played.total = totalTime
	played.levelTime = levelTime
	played.level = level
	played.at = now
	char.level = level
	if (char.highLevel or 0) < level then
		char.highLevel = level
	end

	if pendingLevelSnapshot then
		pendingLevelSnapshot = nil
		if ns.db.settings.announceLevelUps then
			local totalText = ns.FormatDuration(totalTime).." played in total"
			if finishedSeconds and finishedPartial then
				ns.Print(string.format("Level %d reached - at least %s on level %d, %s.", level, ns.FormatDuration(finishedSeconds), finishedLevel, totalText))
			elseif finishedSeconds then
				ns.Print(string.format("Level %d reached - %s on level %d, %s.", level, ns.FormatDuration(finishedSeconds), finishedLevel, totalText))
			elseif finishedGap then
				ns.Print(string.format("Level %d reached - %s (no /played reading at the level-up).", level, totalText))
			else
				ns.Print(string.format("Level %d reached - %s.", level, totalText))
			end
		end
	end
	if ns.OnDataTick then
		ns.OnDataTick()
	end
end

local function OnLevelUp(newLevel)
	local char = ns.GetChar()
	if not char then
		return
	end
	char.level = newLevel or UnitLevel("player") or char.level
	if (char.highLevel or 0) < (char.level or 0) then
		char.highLevel = char.level
	end
	-- The level itself is identity and always moves; the session count and
	-- the /played request belong to playtime, so they wait for it.
	if not ns.Tracks("playtime") then
		return
	end
	local session = char.sessions.current
	if session then
		session.levelCount = (session.levelCount or 0) + 1
	end
	local zone, zoneKind
	if ns.MilestoneContext then
		zone, zoneKind = ns.MilestoneContext()
	end
	local at = Now()
	if not char.levels then
		char.levels = { history = {} }
	end
	if not char.levels.history then
		char.levels.history = {}
	end
	local last = char.levels.history[#char.levels.history]
	if last and last.level == char.level then
		pendingLevelSnapshot = {
			level = char.level, at = at,
			zone = zone, zoneKind = zoneKind,
			entry = last.pending and last or nil,
		}
	else
		local entry = {
			level = char.level, at = at, zone = zone, zoneKind = zoneKind,
			observed = "live", partial = true, pending = true,
		}
		char.levels.history[#char.levels.history + 1] = entry
		if ns.NoteEvent then
			local event = ns.NoteEvent("level_up", {
				at = at, zone = zone, zoneKind = zoneKind,
				how = "level_up", evidence = "level_event", observed = "live",
				data = { level = char.level, partial = true },
			})
			if event then
				entry.event = event.id
			end
		end
		pendingLevelSnapshot = {
			level = char.level, at = at,
			zone = zone, zoneKind = zoneKind,
			entry = entry,
		}
	end
	RequestPlayedSync()
	if ns.OnDataTick then
		ns.OnDataTick()
	end
end

-- Parses a /played reply from system chat. The reply arrives as
-- TIME_PLAYED_MSG on most clients and as chat lines on some, so the text
-- is parsed too. It scans number+unit pairs ("1 day, 2 hours, 3 minutes,
-- 4 seconds") and accepts any subset, so a client printing fewer units
-- still adds up correctly.
local function ParsePlayedSeconds(text, label)
	local tail = string.match(text, label..":(.*)")
	if not tail then
		return nil
	end
	-- Only read up to the level line, in case both lines came as one message.
	if label == "total time played" then
		tail = string.match(tail, "^(.-)time played this level") or tail
	end
	local total = 0
	local matched = false
	for value, unit in string.gmatch(tail, "(%d+)%s*(%a)") do
		local count = tonumber(value)
		if unit == "d" then
			total = total + count * 86400
			matched = true
		elseif unit == "h" then
			total = total + count * 3600
			matched = true
		elseif unit == "m" then
			total = total + count * 60
			matched = true
		elseif unit == "s" then
			total = total + count
			matched = true
		end
	end
	if not matched then
		return nil
	end
	return total
end

local function OnSystemMessage(text)
	if not text then
		return
	end
	text = string.lower(ns.StripColors(text))
	local total = ParsePlayedSeconds(text, "total time played")
	if not total then
		return
	end
	OnTimePlayedMsg(total, ParsePlayedSeconds(text, "time played this level"))
end

-- How long after one of Tally's own requests the client's printed reply is
-- still considered Tally's, rather than the player's.
local PLAYED_REPLY_GRACE = 10

-- Chat filter for the client's own /played answer. The client prints what it
-- is told into chat; when the request was Tally's, that line is noise, so it
-- is not shown. The numbers arrive through the event and through the chat
-- message regardless, so nothing is lost: this only keeps the screen clear.
-- A /played the player types is never hidden - the filter only matches
-- within a few seconds of a request Tally made itself.
local function HidePlayedReply(_, _, message)
	if type(message) ~= "string" or (Now() - playedRequestAt) > PLAYED_REPLY_GRACE then
		return false
	end
	local text = string.lower(ns.StripColors(message))
	if string.find(text, "total time played", 1, true) or string.find(text, "time played this level", 1, true) then
		ns.Trace("kept the client's own /played reply off the chat frame")
		return true
	end
	return false
end

-- Installs the filter once per load. The API is old and present on every
-- client this addon has met, but a refusal is not worth an error: the reply
-- simply prints as it always did.
function ns.InstallPlayedFilter()
	if not ChatFrame_AddMessageEventFilter then
		return
	end
	local ok = pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_SYSTEM", HidePlayedReply)
	ns.Trace("played reply filter: "..(ok and "installed" or "the client refused it"))
end

-------------------------------------------------------------------------------
-- Sessions
-------------------------------------------------------------------------------

-- A session is one stretch of logged-in time. A /reload continues the
-- current session; a real login starts a new one regardless of how soon it
-- follows the last, so the session count rises when a character logs out
-- and back in. The client's world-entry flags decide which case applies;
-- TUNING.mergeGap is the fallback when none are sent.
function StartSession(now)
	local char = ns.GetChar()
	if not char then
		return
	end
	char.sessions.current = {
		start = now,
		last = now,
		lastSeenAt = now,
		seconds = 0,
		alive = 0,
		startZone = (ns.CurrentZone and ns.CurrentZone())
			or (type(GetRealZoneText) == "function" and GetRealZoneText())
			or nil,
		startLevel = UnitLevel and UnitLevel("player") or nil,
		endedObserved = false,
		durationKnown = false,
		-- Starting balance: the last known one until the settle in PollMoney
		-- adopts the real starting reading and replaces it. An unverified
		-- guess here would later be booked as session income.
		goldStart = char.gold.balance,
		kills = 0,
		deaths = 0,
		items = 0,
		itemValue = 0,
		xp = 0,
		fights = 0,
		combatSeconds = 0,
		levelCount = 0,
		firsts = {},
		distance = 0,
		flights = 0,
		flightSeconds = 0,
		mountedSeconds = 0,
	}
	-- The ten-minute window belongs to one play session; a new login must not
	-- inherit the previous character's kill times.
	killWindow = {}
end

-- Turns one area of the record on or off, from the settings page. Switching
-- off only stops new writes: nothing already stored is removed or changed.
-- Switching playtime back on clears the experience mark, so the experience
-- gained while it was off is not credited to a single second, and opens a
-- session at once rather than at the next logout.
function ns.SetTracked(area, enabled)
	if not ns.db or not ns.db.settings or not ns.db.settings.track then
		return
	end
	ns.db.settings.track[area] = enabled and true or false
	if not enabled then
		if area == "explore" then
			-- A turn-in dialog that was open when the tab was switched off
			-- must not be counted when it is switched back on.
			questPending = false
		end
		return
	end
	if area ~= "playtime" then
		return
	end
	local char = ns.GetChar()
	if not char then
		return
	end
	char.xp.last = nil
	if worldEntered and not char.sessions.current then
		StartSession(Now())
	end
end

local function FinalizeSession(stopAt, endedReason, endedObserved)
	local char = ns.GetChar()
	if not char then
		return false
	end
	local session = char.sessions.current
	if not session then
		return false
	end
	local sessions = char.sessions
	local endedAt = stopAt or session.last or Now()
	sessions.count = sessions.count + 1
	sessions.seconds = sessions.seconds + (session.seconds or 0)
	if (session.seconds or 0) > (sessions.longest or 0) then
		sessions.longest = session.seconds
		if ns.NoteRecord then
			ns.NoteRecord("sessions.longest", session.seconds, endedAt)
		end
	end
	local entry = {
		start = session.start,
		lastSeenAt = session.lastSeenAt or session.last or endedAt,
		stop = endedAt,
		endedObserved = endedObserved == true,
		endedReason = endedReason or (endedObserved == true and "logout" or "unknown"),
		durationKnown = endedObserved == true,
		startZone = session.startZone,
		endZone = ns.CurrentZone and ns.CurrentZone() or nil,
		startLevel = session.startLevel,
		endLevel = UnitLevel and UnitLevel("player") or nil,
		seconds = session.seconds,
		alive = session.alive,
		afk = session.afk,
		goldStart = session.goldStart,
		goldSettled = session.goldSettled,
		goldEnd = char.gold.balance,
		kills = session.kills,
		deaths = session.deaths,
		items = session.items,
		itemValue = session.itemValue,
		xp = session.xp,
		fights = session.fights,
		combatSeconds = session.combatSeconds,
		levels = session.levelCount or 0,
		firsts = session.firsts,
		distance = session.distance,
		flights = session.flights,
		flightSeconds = session.flightSeconds,
		mountedSeconds = session.mountedSeconds,
	}
	sessions.history[#sessions.history + 1] = entry
	if ns.NoteEvent then
		local event = ns.NoteEvent("session", {
			at = endedAt, zone = entry.endZone,
			how = entry.endedReason == "logout" and "logout" or "disconnect",
			evidence = "login_snapshot",
			observed = entry.endedObserved and "live" or "unknown",
			data = {
				start = entry.start, stop = entry.stop, seconds = entry.seconds,
				endedReason = entry.endedReason, durationKnown = entry.durationKnown,
			},
		})
		if event then
			entry.event = event.id
		end
	end
	while #sessions.history > TUNING.sessionHistoryCap do
		table.remove(sessions.history, 1)
	end
	char.sessions.current = nil
	return true
end

-- Opens the session for this world entry. `reloading` is the client's own
-- account: true for a /reload, false for a real login, nil when the client
-- said neither (then the clock decides). A reload continues an open session
-- and reopens the one the preceding logout closed. A login never reopens;
-- the previous session stays finished and counted.
local function ResumeSession(reloading)
	local char = ns.GetChar()
	if not char then
		return
	end
	local now = Now()
	local sessions = char.sessions
	if sessions.current then
		local continues = false
		if reloading == true then
			continues = true
		elseif reloading == nil and (now - (sessions.current.last or 0)) <= TUNING.mergeGap then
			continues = true
		end
		if continues then
			-- The same session, interrupted for a moment.
			sessions.current.last = now
			sessions.current.lastSeenAt = now
		else
			-- The client closed without a logout (a crash or an unannounced
			-- login): finish the session at its last tick and mark it
			-- unfinished. sessions.unfinished counts them.
			FinalizeSession(sessions.current.last, "disconnect", false)
			local ended = sessions.history[#sessions.history]
			if ended then
				ended.unfinished = true
			end
			sessions.unfinished = (sessions.unfinished or 0) + 1
		end
	end
	local last = sessions.history[#sessions.history]
	local reopen = false
	if last and last.stop and sessions.reloadable then
		if reloading == true then
			reopen = true
		elseif reloading == nil and (now - last.stop) <= TUNING.mergeGap then
			reopen = true
		end
	end
	sessions.reloadable = nil
	if reopen then
		-- A /reload: the client reports the next world entry as a reload,
		-- so the session the logout closed is still open; take it back off
		-- the finished list.
		table.remove(sessions.history)
		sessions.count = math.max(0, sessions.count - 1)
		sessions.seconds = math.max(0, sessions.seconds - (last.seconds or 0))
		sessions.current = {
			start = last.start,
			last = now,
			lastSeenAt = now,
			seconds = last.seconds or 0,
			alive = last.alive or 0,
			afk = last.afk or 0,
			startZone = last.startZone,
			startLevel = last.startLevel,
			goldStart = last.goldStart,
			goldSettled = last.goldSettled,
			kills = last.kills or 0,
			deaths = last.deaths or 0,
			items = last.items or 0,
			itemValue = last.itemValue or 0,
			xp = last.xp or 0,
			fights = last.fights or 0,
			combatSeconds = last.combatSeconds or 0,
			levelCount = last.levels or 0,
			firsts = last.firsts or {},
			distance = last.distance or 0,
			flights = last.flights or 0,
			flightSeconds = last.flightSeconds or 0,
			mountedSeconds = last.mountedSeconds or 0,
		}
		return
	end
	StartSession(now)
end

-------------------------------------------------------------------------------
-- World: zones, instances, travel
-------------------------------------------------------------------------------

-- The most recent arrivals, newest first: a place visited often keeps its
-- place in the list instead of being frozen at its first visit. The Overview's
-- activity card reads this. A record written before the list existed simply
-- starts empty and fills from the next arrival.
-- One-time start-of-play work: clean up money records left by earlier
-- client readings, start the first money reading through the settle, and
-- request the first /played snapshot. Called from PLAYER_LOGIN and
-- PLAYER_ENTERING_WORLD; whichever fires first wins, and nothing runs
-- until the character exists. The session itself starts at the world entry
-- in BeginSession, where the client says whether it is a login or a reload.
local function BeginPlay()
	if beginPlayDone then
		return
	end
	local char = ns.GetChar()
	if not char then
		return
	end
	beginPlayDone = true
	-- Removes the entries left by earlier stale client readings (0 at
	-- logout, stale at login), once per load. The session pass runs first
	-- because it matches ledger entries the ledger pass is about to remove.
	-- Each cleanup has its own accepted shapes; real transactions are never
	-- touched. Nothing here runs while the economy is paused: the stored
	-- money record is left exactly as it is.
	if ns.Tracks("economy") then
		local fixedSessions = ns.CleanSessionGold(char)
		local fixedLedger = ns.CleanGoldLedger(char.gold)
		if fixedSessions > 0 or fixedLedger > 0 then
			ns.Trace("cleanup: "..fixedSessions.." fake session gold anchors cleared, "..fixedLedger.." fake ledger entries removed")
		end
		-- A balance that only a reading recorded is booked, so the purse and
		-- the day totals agree again. The ledger pass above has finished with
		-- the change list, so the list is settled by the time this one walks
		-- it.
		local fixedDrift = ns.ReconcileGoldLedger(char.gold)
		if fixedDrift > 0 then
			ns.Trace("cleanup: "..fixedDrift.." change(s) booked that only the balance had recorded")
		end
		-- A stored balance of exactly zero may be an empty logout-time
		-- reading. It is treated as unknown for this login, so the first
		-- confirmed reading becomes the baseline and a bogus zero cannot turn
		-- the whole balance into false income. A character that really has 0c
		-- loses nothing: its confirmed reading is 0 again and books nothing.
		if char.gold.balance == 0 then
			char.gold.balance = nil
		end
		-- A stored first reading of zero is left as it stands. It is a reading
		-- Tally took, and for a character that started with nothing it is the
		-- point of the line; wiping it only let the next settle nominate a
		-- later balance as the first reading. A zero that came from a stale
		-- settle is repaired below from the session it belongs to.
		local firstReading = ns.FirstReading(char)
		if firstReading ~= nil and firstReading ~= char.gold.first then
			ns.Trace("first reading repaired: "..tostring(char.gold.first).." -> "..tostring(firstReading))
			char.gold.first = firstReading
		end
	end
	-- The settle inside PollMoney takes the first reading: it becomes the
	-- session's starting balance and is never booked, so a stale login
	-- reading cannot turn into income.
	if ns.Tracks("economy") then
		ns.PollMoney(worldEntered)
		ns.Trace("begin: money polled")
	end
	-- Ask the client for a fresh /played snapshot: it is the only way to
	-- account for playtime that happened while Tally was not watching.
	if ns.Tracks("playtime") then
		RequestPlayedSync()
	end
end

-- Decides the session boundary once per addon load, at the first world
-- entry. The two flags describe the entry: isReloadingUi a /reload,
-- isInitialLogin a real login, neither a loading screen inside the world
-- (not a boundary). Only the first world entry after load reaches here.
local function BeginSession(isInitialLogin, isReloadingUi)
	if sessionResumed then
		return
	end
	if not ns.GetChar() then
		return
	end
	local reloading = nil
	if isReloadingUi == true then
		reloading = true
	elseif isInitialLogin == true then
		reloading = false
	end
	sessionResumed = true
	ns.worldEntry = {
		initial = isInitialLogin,
		reload = isReloadingUi,
		mode = (reloading == true and "reload") or (reloading == false and "login") or "unknown",
	}
	ns.Trace("begin: session boundary read as "..ns.worldEntry.mode)
	-- A paused tab is not opened: no session is started while playtime is
	-- off. The area is always noted, since its name also labels a death and
	-- costs nothing; what explore records is gated inside NoteZone.
	if ns.Tracks("playtime") then
		ResumeSession(reloading)
		ns.Trace("begin: session resumed")
	end
	ns.explore.UpdateArea()
	ns.Trace("begin: area noted")
end

-- Handles a refused API call: ADDON_ACTION_FORBIDDEN (shows an error) or
-- ADDON_ACTION_BLOCKED (silent). Every refusal is traced; names with a
-- known shape are switched off or reported once so they cannot repeat
-- unnoticed.
local function OnBlockedAction(eventName, which, blockedFunction)
	blockedFunction = tostring(blockedFunction or "?")
	ns.Trace("blocked: "..tostring(eventName or "?")..", addon="..tostring(which or "?")..", function="..blockedFunction)
	if string.find(blockedFunction, "RequestTimePlayed", 1, true) then
		if not ns.db.settings.playedSyncBlocked then
			ns.db.settings.playedSyncBlocked = true
			ns.Print("The game blocked Tally from asking for /played - automatic sync is now off.")
			ns.Print("Type /played now and then - Tally reads the numbers from the game's own reply. Settings can try again.")
		end
		return
	end
	if string.find(blockedFunction, "GetRepairAllCost", 1, true) then
		if not ns.repairWatch.blocked then
			ns.repairWatch.blocked = true
			ns.Print("The game blocked Tally from reading repair quotes - repairs will simply count as vendor spending.")
		end
	elseif string.find(blockedFunction, "CopyToClipboard", 1, true) then
		if ns.db.settings.copyDirect then
			ns.db.settings.copyDirect = false
			ns.Print("The game blocked Tally from the system clipboard - Copy opens a selectable text window instead.")
		end
	elseif not forbiddenSeen[blockedFunction] then
		forbiddenSeen[blockedFunction] = true
		ns.Print("The game blocked Tally from using "..blockedFunction.." ("..tostring(which or "?").."). Please pass this line on.")
	end
end

-- Handles ENCOUNTER_END, which fires with success = 1 after a boss dies.
-- A dungeon has no completion signal from the client, so runs entered and
-- boss kills are counted separately rather than reported as completions.
-- The 1-second ticker
-------------------------------------------------------------------------------

-- Grabs a dialog's displayed text, if this client's popup template
-- exposes it, without ever raising an error.
local function PopupText(dialog)
	if not (dialog and dialog.GetTextFontString) then
		return nil
	end
	local ok, fontString = pcall(dialog.GetTextFontString, dialog)
	if not ok or not fontString then
		return nil
	end
	local okText, text = pcall(fontString.GetText, fontString)
	if okText then
		return text
	end
	return nil
end
ns.PopupText = PopupText

-- The per-minute XP buckets, read. The stored minutes plus the one being
-- played, in order; a minute is one entry whether anything was gained in it
-- or not, so a minute spent standing still is part of the window it sits in.
local function XpMinuteList(xp)
	local list = {}
	local entries = xp.recent or {}
	for index = 1, #entries do
		list[#list + 1] = entries[index]
	end
	if xp.minute then
		list[#list + 1] = { at = xp.minute, gained = xp.minuteGained or 0 }
	end
	return list
end

-- The best run of `minutes` contiguous minutes in the buckets, with what was
-- gained in it. Only a *full* run counts: ten minutes is the point, and a
-- shorter window would let one quest hand-in set a rate nothing could match.
-- nil when no such run exists yet.
local function XpBestWindow(xp, minutes)
	local list = XpMinuteList(xp)
	local best = nil
	for start = 1, #list do
		local gained, count, expect = 0, 0, nil
		for index = start, #list do
			local entry = list[index]
			if expect and entry.at ~= expect then
				break
			end
			expect = entry.at + 1
			gained = gained + (entry.gained or 0)
			count = count + 1
			if count >= minutes then
				break
			end
		end
		if count >= minutes and gained > 0 and (not best or gained > best.gained) then
			best = { gained = gained, minutes = count, at = list[start].at * 60 }
		end
	end
	if not best then
		return nil
	end
	best.perHour = best.gained / (best.minutes * 60) * 3600
	return best
end

-- The character's XP rate over its last few minutes of play, from the same
-- buckets: contiguous minutes only, so a logout ends the window rather than
-- being averaged across. Returns { gained, seconds, minutes, perHour } or nil.
function ns.RecentXpRate(char, minutes)
	minutes = minutes or TUNING.xpWindowMinutes
	local xp = char and char.xp
	if not xp then
		return nil
	end
	local list = XpMinuteList(xp)
	local gained, count, expect = 0, 0, nil
	for index = #list, 1, -1 do
		local entry = list[index]
		if expect and entry.at ~= expect then
			break
		end
		expect = entry.at - 1
		gained = gained + (entry.gained or 0)
		count = count + 1
		if count >= minutes then
			break
		end
	end
	if count == 0 or gained <= 0 then
		return nil
	end
	return {
		gained = gained, seconds = count * 60, minutes = count,
		perHour = gained / (count * 60) * 3600,
	}
end

-- Whether this client can say that the character is on a mount. Resolved once
-- and remembered: a client without it keeps the mounted figure blank rather
-- than guessing from auras, whose names differ between realms.
local mountedProbe
local function CanReadMounted()
	if mountedProbe == nil then
		mountedProbe = (type(IsMounted) == "function")
		if not mountedProbe then
			ns.Trace("mounted time: this client has no IsMounted, so the figure stays blank")
		end
	end
	return mountedProbe
end
ns.CanReadMounted = CanReadMounted

-- The 1-second tick: accumulates tracked time, alive time, session seconds,
-- per-zone seconds, ground distance and flight time. AFK ticks count like
-- any other logged-in second unless the player asked to leave them out.
local function OnTickStep()
	local char = ns.GetChar()
	if not char then
		return
	end
	-- The level-up event is usually the fastest path, but a reload or a
	-- missed event must not lose the level. The client's own level is the
	-- backstop; OnLevelUp is idempotent for the same level.
	local liveLevel = UnitLevel and UnitLevel("player") or nil
	if liveLevel and char.level and liveLevel > char.level and ns.Tracks("playtime") then
		OnLevelUp(liveLevel)
	end
	local afk = (UnitIsAFK and UnitIsAFK("player")) and true or false
	local session = char.sessions.current
	if afk and ns.Tracks("playtime") then
		-- AFK time is recorded even when it is left out of played time, so
		-- the breakdown can name it. It can overlap the alive and dead
		-- figures: a flagged player is still one or the other.
		char.afk = (char.afk or 0) + 1
		if ns.NoteAfkMilestone then
			ns.NoteAfkMilestone(char.afk)
		end
		if ns.Touch then
			ns.Touch(char, "afk", Now())
		end
		if session then
			session.afk = (session.afk or 0) + 1
		end
	end
	if afk and ns.db.settings.excludeAfk then
		return
	end
	local now = Now()
	local dead = UnitIsDeadOrGhost and UnitIsDeadOrGhost("player")
	-- A flight point puts the player on a mount the client reports as mounted,
	-- which is not time on their own mount. This was read as an undefined
	-- global before, so the flight exclusion never applied.
	local onTaxi = false
	if type(UnitOnTaxi) == "function" then
		local ok, taxi = pcall(UnitOnTaxi, "player")
		onTaxi = ok and taxi and true or false
	end
	-- The five switches the settings page owns. Each block below asks before
	-- it writes, so a paused tab stops moving and nothing else is touched.
	local playtime = ns.Tracks("playtime")
	local combat = ns.Tracks("combat")
	local economy = ns.Tracks("economy")
	local loot = ns.Tracks("loot")
	local explore = ns.Tracks("explore")

	if playtime then
		char.tracked = char.tracked + 1
		if ns.Touch then
			ns.Touch(char, "tracked", now)
		end
		if not dead then
			char.alive = char.alive + 1
			if ns.Touch then
				ns.Touch(char, "alive", now)
			end
		end
		-- Playtime switched back on mid-session: the clock starts a session of
		-- its own rather than resuming one that was paused.
		if not session and worldEntered then
			StartSession(now)
			session = char.sessions.current
		end
		if session then
			session.seconds = (session.seconds or 0) + 1
			session.last = now
			session.lastSeenAt = now
			if not dead then
				session.alive = (session.alive or 0) + 1
			end
		end
	end
	if combat and UnitAffectingCombat and UnitAffectingCombat("player") then
		char.combat.combatSeconds = (char.combat.combatSeconds or 0) + 1
		if ns.Touch then
			ns.Touch(char, "combat.combatSeconds", now)
		end
		if session then
			session.combatSeconds = (session.combatSeconds or 0) + 1
		end
	end

	-- XP is sampled, not derived: the client exposes only the current bar,
	-- so each tick credits the difference between two samples. A bar that
	-- went backwards means a level-up; the new sample is stored and nothing
	-- is credited for the reset.
	local xp = playtime and UnitXP and UnitXP("player")
	local xpMax = playtime and UnitXPMax and UnitXPMax("player")
	if xp and xpMax and xpMax > 0 then
		local book = char.xp
		if not book then
			book = { total = 0, seconds = 0, byLevel = {} }
			char.xp = book
		end
		if not book.byLevel then
			book.byLevel = {}
		end
		local level = (UnitLevel and UnitLevel("player")) or char.level or 1
		-- The last-known bar for a viewed character. It is only a reading
		-- Tally took while that character was played; no reading means no bar.
		book.current = xp
		book.max = xpMax
		book.currentAt = Now()
		book.currentLevel = level
		local bucket = book.byLevel[level]
		if type(bucket) ~= "table" then
			bucket = { gained = 0, seconds = 0 }
			book.byLevel[level] = bucket
		end
		bucket.gained = tonumber(bucket.gained) or 0
		bucket.seconds = tonumber(bucket.seconds) or 0
		if book.last and xp >= book.last then
			local gained = xp - book.last
			if gained > 0 then
				book.total = (tonumber(book.total) or 0) + gained
				bucket.gained = bucket.gained + gained
				book.minuteGained = (book.minuteGained or 0) + gained
				if session then
					session.xp = (session.xp or 0) + gained
				end
			end
		end
		-- One bucket per minute of play, kept for an hour: the "last ten
		-- minutes" rate is worked out from these, and the best ten-minute run
		-- is kept as the character's record. A minute with no samples (logged
		-- out) is not written at all, so it breaks the run rather than being
		-- counted as a minute of play.
		local minute = math.floor(Now() / 60)
		if book.minute ~= minute then
			if book.minute then
				book.recent = book.recent or {}
				book.recent[#book.recent + 1] = { at = book.minute, gained = book.minuteGained or 0 }
				while #book.recent > TUNING.xpMinuteCap do
					table.remove(book.recent, 1)
				end
				-- The window that has just been completed, if it is ten
				-- contiguous minutes and beats what is stored.
				local window = XpBestWindow(book, TUNING.xpWindowMinutes)
				if window and (not book.bestWindow or window.perHour > (book.bestWindow.rate or 0)) then
					book.bestWindow = {
						rate = window.perHour, at = window.at,
						gained = window.gained, minutes = window.minutes,
					}
					if ns.NoteRecord then
						ns.NoteRecord("xp.bestWindow", window.perHour, window.at)
					end
					ns.Trace("xp: best ten minutes now "..math.floor(window.perHour + 0.5).." XP/h (from "..window.gained.." XP)")
				end
			end
			book.minute = minute
			book.minuteGained = 0
		end
		book.last = xp
		book.seconds = (tonumber(book.seconds) or 0) + 1
		bucket.seconds = bucket.seconds + 1
	end

	-- Exploration state (zones, instances, travel, flights) lives with its domain.
	if explore then
		ns.explore.ExploreTick(char, explore, session, dead)
	end

	-- Time on a mount, asked once a second. A flight is not a mount, and the
	-- dead are not riding, so both are left out. Nothing is guessed from aura
	-- names: where the client cannot answer, the figure stays blank.
	if explore and not onTaxi and not dead and CanReadMounted() then
		local ok, mounted = pcall(IsMounted)
		if ok and mounted then
			char.explore.mountedSeconds = (char.explore.mountedSeconds or 0) + 1
			char.explore.mountedFirstAt = char.explore.mountedFirstAt or now
			char.explore.mountedLastAt = now
			char.explore.mountedUpdatedAt = now
			if session then
				session.mountedSeconds = (session.mountedSeconds or 0) + 1
			end
		end
	end

	-- Social time: group/solo, leader, group sizes and the members present.
	-- It is a passive record, like the playtime clock, not a tab switch.
	if ns.SocialTick then
		ns.SocialTick(char, now)
	end

	if economy then
		ns.PollMoney(worldEntered)
	end

	-- Auras are sampled every second: the buff bars' own data, read, never
	-- written. A character whose auras were never read simply has none.
	if combat and ns.auras.Scan then
		ns.auras.Scan()
	end

	if loot then
		ns.ResolvePendingLoot()
	end

	if loot then
		ns.StepLootQualityRepair()
	end

	if playtime and now - lastPlayedSync >= TUNING.playedSync then
		lastPlayedSync = now
		RequestPlayedSync()
	end
	-- The client does not answer every /played request. A level-up whose
	-- reading has not arrived is asked for again for a short while, so the
	-- level keeps its own reading instead of being folded into the next one.
	if playtime and pendingLevelSnapshot and now >= playedRetryAt then
		if char.played.at and char.played.at >= pendingLevelSnapshot.at then
			if pendingLevelSnapshot.entry then
				pendingLevelSnapshot.entry.pending = nil
				pendingLevelSnapshot.entry.timingMissing = true
			end
			pendingLevelSnapshot = nil
		elseif now - pendingLevelSnapshot.at < TUNING.levelRetryFor then
			playedRetryAt = now + TUNING.levelRetryEvery
			RequestPlayedSync()
		else
			ns.Trace("no /played reply after level "..tostring(pendingLevelSnapshot.level).."; giving up")
			if pendingLevelSnapshot.entry then
				pendingLevelSnapshot.entry.pending = nil
				pendingLevelSnapshot.entry.timingMissing = true
			end
			pendingLevelSnapshot = nil
		end
	end
	if questPending and (now - questAt) > TUNING.questWindow * 3 then
		questPending = false
	end

	if ns.OnDataTick then
		ns.OnDataTick()
	end
end

local tickerElapsed = 0
local ticker = CreateFrame("Frame")
ticker:SetScript("OnUpdate", function(_, delta)
	tickerElapsed = tickerElapsed + delta
	if tickerElapsed < 1 then
		return
	end
	-- One step per whole second: a 20-second loading screen is not counted
	-- as 20 seconds of play.
	tickerElapsed = tickerElapsed - math.floor(tickerElapsed)
	local ok, err = pcall(OnTickStep)
	if not ok and not TUNING.errorReports.ticker then
		TUNING.errorReports.ticker = true
		pcall(ns.Trace, "ERROR in ticker: "..tostring(err))
	end
end)

-- Combined figures (the Total tab)
------------------------------------------------------------------------------

-- One selection for the whole addon: the Total tab sums it, the level-times
-- chart draws it and the daily graph draws it. The characters picker is the
-- only thing that changes it, so a character ticked in one place is ticked
-- everywhere. A missing entry means included, so a character created later
-- joins the total on its own; only an explicit false excludes one. This
-- decides what is summed and drawn, and never modifies a character's record.
function ns.TotalIncludes(key)
	local selection = ns.db and ns.db.settings and ns.db.settings.totalSelect
	if not selection then
		return true
	end
	return selection[key] ~= false
end

function ns.SetTotalIncluded(key, included)
	if not key or not (ns.db and ns.db.settings) then
		return
	end
	local selection = ns.db.settings.totalSelect
	if not selection then
		selection = {}
		ns.db.settings.totalSelect = selection
	end
	selection[key] = included and true or false
end

function ns.SelectAllTotal()
	if ns.db and ns.db.settings then
		ns.db.settings.totalSelect = nil
	end
end

function ns.DeselectAllTotal()
	if not (ns.db and ns.db.settings) then
		return
	end
	local selection = {}
	local known = ns.KnownCharacters()
	for index = 1, #known do
		selection[known[index].key] = false
	end
	ns.db.settings.totalSelect = selection
end

-- Ensures the Total tab has at least one included character. When nothing
-- is ticked, the live character is included and true is returned; otherwise
-- returns false.
function ns.EnsureSomeTotalIncluded()
	local known = ns.KnownCharacters()
	local included, liveKey = 0, nil
	for index = 1, #known do
		local entry = known[index]
		if entry.live then
			liveKey = entry.key
		end
		if ns.TotalIncludes(entry.key) then
			included = included + 1
		end
	end
	if included == 0 then
		ns.SetTotalIncluded(liveKey or ns.charKey, true)
		return true
	end
	return false
end

-- The charts no longer keep a selection of their own: they ask the one
-- question above. Those two per-chart stores (chartHidden, dailyShown) are
-- gone, so a line hidden in one place is hidden in all of them.

-- Daily balances for the characters sharing the realm and faction of the
-- character being looked at; only those can pass money around. Each point
-- is reconstructed from the character's last known balance by subtracting
-- the net of each later day, which is exact within the window because money
-- moves only while logged in and every move reaches the daily ledger. A
-- walk below zero means a hole in the ledger; a character without a
-- recorded balance has no start point. Both are counted, not inferred.
function ns.GoldTracks(dayCount, endDays)
	dayCount = math.max(1, math.floor(tonumber(dayCount) or 14))
	endDays = math.max(0, math.floor(tonumber(endDays) or 0))
	local result = {
		days = {}, tracks = {}, members = {}, total = 0,
		known = 0, noBalance = 0, gaps = 0,
	}
	local now = ns.Now()
	for offset = endDays + dayCount - 1, endDays, -1 do
		local stamp = now - offset * 86400
		result.days[#result.days + 1] = { key = date("%Y-%m-%d", stamp), stamp = stamp }
	end

	-- A window that ends in the past still needs the days after it: the
	-- balance at its newest day is today's balance minus every change since.
	-- The keys are built once, and each character's ledger is walked over
	-- them; only days inside the window become points.
	local maxOffset = endDays + dayCount - 1
	local keyAt, slotOf = {}, {}
	for offset = 0, maxOffset do
		keyAt[offset] = date("%Y-%m-%d", now - offset * 86400)
	end
	for position = 1, #result.days do
		slotOf[result.days[position].key] = position
	end

	local report = ns.ReportChar()
	if not report then
		return result
	end
	local realm = report.realm or "?"
	local faction = ns.CharFaction(report)

	local known = ns.KnownCharacters()
	for index = 1, #known do
		local entry = known[index]
		local char = entry.char
		-- Every character on the same realm is listed, both factions: the
		-- picker groups them by faction, and while money cannot cross that
		-- line, the graph can still draw the two sides side by side.
		if (char.realm or "?") == realm then
			local balance = char.gold and char.gold.balance
			local member = {
				key = entry.key, name = ns.DisplayName(char), char = char,
				live = entry.live, seen = entry.seen, balance = balance,
				faction = ns.CharFaction(char),
			}
			result.members[#result.members + 1] = member

			-- What this character earned over the window, and which days it
			-- has any ledger at all. The days are kept as a set so a selection
			-- of several characters counts each real day once, rather than
			-- adding up their separate day counts.
			local income, daySet = 0, {}
			for position = 1, #result.days do
				local key = result.days[position].key
				local totals = char.gold and char.gold.daily and char.gold.daily[key]
				if totals then
					daySet[key] = true
					income = income + (totals.income or 0)
				end
			end
			member.income = income
			member.daySet = daySet

			if member.faction == faction then
				-- The pile: every character that could trade with this one,
				-- whether drawn or not.
				if balance == nil then
					result.noBalance = result.noBalance + 1
				else
					result.total = result.total + balance
					result.known = result.known + 1
				end
			end

			if balance then
				local points = {}
				local running = balance
				local firstKey = date("%Y-%m-%d", char.created or now)
				for offset = 0, maxOffset do
					local key = keyAt[offset]
					if key >= firstKey then
						local slot = slotOf[key]
						if slot then
							points[slot] = running
						end
						local totals = char.gold.daily and char.gold.daily[key]
						if totals then
							running = running - ((totals.income or 0) - (totals.expense or 0))
						end
					end
				end
				local broken = false
				for position = 1, #result.days do
					if points[position] and points[position] < 0 then
						broken = true
						break
					end
				end
				if broken then
					result.gaps = result.gaps + 1
					member.gap = true
				else
					member.points = points
					result.tracks[#result.tracks + 1] = member
				end
			end
		end
	end

	-- The viewed character first, then by descending balance, so the
	-- largest line leads the legend and the order is stable.
	table.sort(result.tracks, function(a, b)
		if a.live ~= b.live then
			return a.live
		end
		if (a.balance or 0) ~= (b.balance or 0) then
			return (a.balance or 0) > (b.balance or 0)
		end
		return tostring(a.name) < tostring(b.name)
	end)
	table.sort(result.members, function(a, b)
		if a.live ~= b.live then
			return a.live
		end
		return (a.balance or 0) > (b.balance or 0)
	end)
	return result
end

function ns.TotalSelectionLabel()
	local known = ns.KnownCharacters()
	local included, total = 0, #known
	for index = 1, total do
		if ns.TotalIncludes(known[index].key) then
			included = included + 1
		end
	end
	if included == 0 then
		return "no characters selected"
	end
	if included == total then
		return "all "..included..(included == 1 and " character" or " characters")
	end
	return included.." of "..total.." characters"
end

-- Combined figures over the selected characters. Values that sum are
-- summed; sets are unioned rather than double-counted (two characters who
-- both visited a zone count it once); unknown values are tracked as gaps.
function ns.AggregateTotal()
	local agg = {
		chars = 0, included = {}, excluded = {}, best = {},
		played = 0, playedKnown = 0, playedMissing = 0,
		tracked = 0, alive = 0, sessions = 0, sessionSeconds = 0, sessionLongest = 0,
		gold = 0, goldKnown = 0,
		fights = 0, deaths = 0, combatSeconds = 0,
		items = 0, itemValue = 0, itemValueKnown = true, quality = {},
		quests = 0, levelsGained = 0,
		zones = {}, dungeons = {}, bosses = 0, distance = 0, flights = 0, flightSeconds = 0,
		income = {}, expenses = {}, unclassified = 0, unclassifiedIn = 0, unclassifiedOut = 0, deathZones = {},
		oldest = nil, lastSeen = nil, liveIncluded = false,
	}
	local known = ns.KnownCharacters()
	for index = 1, #known do
		local entry = known[index]
		if ns.TotalIncludes(entry.key) then
			local char = entry.char
			agg.chars = agg.chars + 1
			agg.included[#agg.included + 1] = entry
			if entry.live then
				agg.liveIncluded = true
			end
			local played = char.played or {}
			if played.total then
				agg.played = agg.played + played.total
				agg.playedKnown = agg.playedKnown + 1
			else
				agg.playedMissing = agg.playedMissing + 1
			end
			agg.tracked = agg.tracked + (char.tracked or 0)
			agg.alive = agg.alive + (char.alive or 0)
			local gold = char.gold or {}
			if gold.balance then
				agg.gold = agg.gold + gold.balance
				agg.goldKnown = agg.goldKnown + 1
			end
			for category, amount in pairs(gold.income or {}) do
				agg.income[category] = (agg.income[category] or 0) + amount
			end
			for category, amount in pairs(gold.expenses or {}) do
				agg.expenses[category] = (agg.expenses[category] or 0) + amount
			end
			local unclassifiedIn, unclassifiedOut = ns.UnclassifiedTotals(gold)
			agg.unclassified = agg.unclassified + ((gold.unclassified and gold.unclassified.net) or 0)
			agg.unclassifiedIn = agg.unclassifiedIn + unclassifiedIn
			agg.unclassifiedOut = agg.unclassifiedOut + unclassifiedOut
			local sessions = char.sessions or {}
			agg.sessions = agg.sessions + (sessions.count or 0)
			agg.sessionSeconds = agg.sessionSeconds + (sessions.seconds or 0)
			agg.sessionLongest = math.max(agg.sessionLongest, sessions.longest or 0)
			local combat = char.combat or {}
			agg.fights = agg.fights + (combat.fights or 0)
			agg.deaths = agg.deaths + (combat.deaths or 0)
			agg.combatSeconds = agg.combatSeconds + (combat.combatSeconds or 0)
			for zone, count in pairs(combat.deathsByZone or {}) do
				agg.deathZones[zone] = (agg.deathZones[zone] or 0) + count
			end
			local loot = char.loot or {}
			agg.items = agg.items + (loot.items or 0)
			agg.itemValue = agg.itemValue + (loot.value or 0)
			for quality, count in pairs(loot.quality or {}) do
				agg.quality[quality] = (agg.quality[quality] or 0) + count
			end
			local best = loot.best or {}
			for findIndex = 1, #best do
				local find = best[findIndex]
				agg.best[#agg.best + 1] = {
					name = find.name, value = find.value, quality = find.quality,
					at = find.at, owner = ns.DisplayName(char), ownerClass = char.classFile,
				}
			end
			agg.quests = agg.quests + (char.quests or 0)
			agg.levelsGained = agg.levelsGained + math.max(0, (char.level or 0) - (char.firstLevel or char.level or 0))
			local explore = char.explore or {}
			for zone in pairs(explore.zones or {}) do
				agg.zones[zone] = true
			end
			for name, dungeon in pairs(explore.dungeons or {}) do
				local merged = agg.dungeons[name]
				if not merged then
					merged = { entered = 0, bosses = 0 }
					agg.dungeons[name] = merged
				end
				merged.entered = merged.entered + (dungeon.entered or 0)
				merged.bosses = merged.bosses + (dungeon.bosses or 0)
			end
			agg.bosses = agg.bosses + (explore.bosses or 0)
			agg.distance = agg.distance + (explore.distance or 0)
			agg.flights = agg.flights + (explore.flights or 0)
			agg.flightSeconds = agg.flightSeconds + (explore.flightSeconds or 0)
			if char.created and (not agg.oldest or char.created < agg.oldest) then
				agg.oldest = char.created
			end
			if entry.seen and (not agg.lastSeen or entry.seen > agg.lastSeen) then
				agg.lastSeen = entry.seen
			end
		else
			agg.excluded[#agg.excluded + 1] = entry
		end
	end

	-- Without an item API, items have no vendor value, so the total is
	-- marked unknown rather than reading as 0c.
	if ns.itemValueAvailable == false then
		agg.itemValueKnown = false
	end

	-- Biggest finds across all selected characters: highest value first,
	-- one entry per item name, so a drop looted by two characters appears
	-- once.
	table.sort(agg.best, function(a, b)
		if (a.value or 0) == (b.value or 0) then
			return tostring(a.name) < tostring(b.name)
		end
		return (a.value or 0) > (b.value or 0)
	end)
	local seen = {}
	local unique = {}
	for index = 1, #agg.best do
		local find = agg.best[index]
		local key = find.name or ("?"..index)
		if not seen[key] then
			seen[key] = true
			unique[#unique + 1] = find
		end
	end
	agg.best = unique

	return agg
end

-- The time each finished level took, one point per level, oldest first.
-- A history entry is a client /played reading: the lifetime total and how
-- long the level being stood on had run. The total at that level's start is
-- therefore total - levelTime, so a reading taken well after a level-up
-- still pins the level-up exactly; two readings give one level when they
-- sit a level apart.
--
-- The client does not answer every request, so a stretch of history can
-- cover several levels at once. That stretch is an exact total, and Tally's
-- own per-level sample count divides it: the sampler files each second
-- under the level it was played on, which is the same quantity the client's
-- stretch measures. A point divided that way is marked sampled. When the
-- two disagree the stretch stays a hole rather than being divided by
-- guesswork.
--
-- With the levelEstimate setting on, a stretch Tally did not watch in full is
-- shared equally between every level in it: a count that covers only part of
-- a stretch says nothing about how long its own level took, so it is not
-- kept as if it were the whole. The total is still the client's own figure -
-- only the split is a guess - and each point it fills is marked estimated, so
-- no reader mistakes it for a measurement. A stretch Tally's count does cover
-- keeps its measured split, and with the setting off a stretch it did not
-- watch stays a hole.
--
-- The same rule fills the head when the estimate is on: a character first read
-- above level 1 was played before Tally was installed, and its lifetime total
-- began at 0 at level 1, so the stretch up to the first reading's level start
-- is the client's exact figure for every level below it. Those points carry
-- head as well as estimated, so a reader can tell them from a stretch between
-- two readings. With the estimate off nothing below the first reading is
-- drawn, and a class that begins above level 1 is left out.
--
-- A point names the level it reaches, so its seconds are the time on the
-- level below it; the chart and the level-ups card both read it that way.
function ns.LevelPoints(char)
	local history = (char and char.levels and char.levels.history) or {}
	local buckets = (char and char.xp and char.xp.byLevel) or {}
	local estimate = ns.db and ns.db.settings and ns.db.settings.levelEstimate
	local points = {}
	-- Where the client says this reading's level began. A reply without its
	-- "this level" figure leaves the reading itself as the anchor, so a level
	-- measured from it is a lower bound; that is what loose reports.
	local function StartOf(entry)
		if not entry.total then
			return nil, false
		end
		if entry.levelTimeUnknown or entry.levelTime == nil then
			return entry.total, true
		end
		return entry.total - entry.levelTime, false
	end
	local function AddPoint(level, seconds, at, partial, sampled, estimated, head)
		points[#points + 1] = {
			level = level, seconds = seconds, at = at,
			partial = partial and true or false,
			sampled = sampled and true or false,
			estimated = estimated and true or false,
			head = head and true or false,
		}
	end
	local function AddGap(level, at)
		points[#points + 1] = { level = level, gap = true, at = at }
	end
	-- Adds the points for one stretch the client measured, from firstLevel to
	-- lastLevel: Tally's own count where it covers the stretch, an equal share
	-- otherwise. head marks the stretch before Tally's first reading.
	local function AddStretch(firstLevel, lastLevel, span, partial, at, head)
		local count = lastLevel - firstLevel + 1
		local sum = 0
		for level = firstLevel, lastLevel do
			local bucket = buckets[level]
			sum = sum + ((bucket and bucket.seconds) or 0)
		end
		-- True when Tally's own count does not account for the whole stretch,
		-- so no level in it carries a complete measurement.
		local short = (span - sum) > TUNING.levelSplitSlack
		if sum > span + TUNING.levelSplitSlack then
			-- Tally's count is larger than the stretch the client measured, so
			-- the two disagree and neither can be divided: it stays a hole.
			for level = firstLevel, lastLevel do
				AddGap(level + 1, at)
			end
		elseif estimate and short and span >= count then
			-- Tally did not watch the whole stretch, so it cannot say how long
			-- any level in it took: the client's total is shared equally
			-- between them, one second at a time, and every point is marked
			-- estimated. That is the straight line a reader expects from an
			-- estimate, and the filled points still add back up to the
			-- client's own figure.
			local each = math.floor(span / count)
			local extra = span - each * count
			for level = firstLevel, lastLevel do
				local share = each
				if extra > 0 then
					share = each + 1
					extra = extra - 1
				end
				AddPoint(level + 1, share, at, partial, false, true, head)
			end
		else
			for level = firstLevel, lastLevel do
				local bucket = buckets[level]
				local seconds = (bucket and bucket.seconds) or 0
				if seconds > 0 then
					-- Tally watched this level: its count is the split of a
					-- stretch the client measured, and a short count means
					-- time it did not see.
					AddPoint(level + 1, seconds, at, partial or short, true, false, head)
				else
					-- Neither the client nor Tally measured this level: it
					-- stays a hole rather than an invented number.
					AddGap(level + 1, at)
				end
			end
		end
	end

	-- The head: a character first read above level 1 was played before Tally
	-- was installed. Its lifetime /played began at 0 when it was created, and
	-- the first reading pins where its own level began, so the stretch
	-- between those two is the game's exact total for every level below it.
	-- One level is therefore exact on its own and is drawn without the
	-- estimate; several can only be shared out equally, which the estimate
	-- does. A class that begins above level 1 is left alone - its total does
	-- not start at level 1, so sharing it would invent levels it never played
	-- - and a head too short to give every level a second is left alone too.
	local firstReading = history[1]
	local startsHigh = char and (char.classFile == "DEATHKNIGHT"
		or char.classFile == "DEMONHUNTER" or char.classFile == "EVOKER")
	if firstReading and not startsHigh
		and firstReading.level and firstReading.level > 1 then
		local headEnd, headLoose = StartOf(firstReading)
		local headLevels = firstReading.level - 1
		if headEnd and not headLoose and headEnd >= headLevels then
			if headLevels == 1 then
				-- Playtime starts at zero when the character is made, so a
				-- first reading at level 2 measures level 1 exactly: the whole
				-- stretch before that reading is its time. No estimate needed
				-- for a single level - it is a reading, not a share.
				AddPoint(2, headEnd, firstReading.at, false, false, false, true)
			elseif estimate then
				-- Several levels before the first reading can only be shared
				-- out equally, and only when the estimate is switched on.
				AddStretch(1, headLevels, headEnd, false, firstReading.at, true)
			end
		end
	end

	for position = 2, #history do
		local previous, current = history[position - 1], history[position]
		local from, loose = StartOf(previous)
		local to = StartOf(current)
		local firstLevel = previous.level
		local lastLevel = current.level and (current.level - 1)
		if firstLevel and lastLevel and from and to and to > from and lastLevel >= firstLevel then
			local span = to - from
			local partial = loose and true or false
			if lastLevel == firstLevel then
				AddPoint(current.level, span, current.at, partial, false)
			else
				AddStretch(firstLevel, lastLevel, span, partial, current.at, false)
			end
		end
	end
	-- A level-up recorded before its /played reading arrived still gets a row,
	-- marked as a hole rather than dropped from the list entirely.
	for index = 1, #history do
		local entry = history[index]
		if entry.at and entry.level and not entry.total then
			local already = false
			for pointIndex = 1, #points do
				if points[pointIndex].level == entry.level then
					already = true
					break
				end
			end
			if not already then
				AddGap(entry.level, entry.at)
			end
		end
	end
	return points
end

-- Every known character's level-up points. With includeAll set, a character
-- that is not ticked is returned as well, so the level-times chart can keep
-- its legend entry and grey it out rather than losing the way back.
function ns.LevelSeries(includeAll)
	local series = {}
	local known = ns.KnownCharacters()
	for index = 1, #known do
		local entry = known[index]
		if includeAll or ns.TotalIncludes(entry.key) then
			local char = entry.char
			local points = ns.LevelPoints(char)
			local byLevel = {}
			for position = 1, #points do
				byLevel[points[position].level] = points[position]
			end
			series[#series + 1] = {
				key = entry.key, char = char, name = ns.DisplayName(char),
				level = char.level or 0, tracked = char.tracked or 0, live = entry.live,
				points = points, byLevel = byLevel,
			}
		end
	end
	return series
end

-- The XP rate the UI should show: the last ten minutes of play, contiguous,
-- computed from the per-minute buckets. That is the figure the owner asked
-- for - a quest hand-in inside the window is part of a ten-minute average
-- rather than a spike on its own. Records written before the buckets existed
-- fall back to the per-level samples, labelled as such.
function ns.XpRate(char)
	if not char then
		return nil
	end
	local recent = ns.RecentXpRate(char, TUNING.xpWindowMinutes)
	if recent then
		return {
			scope = "recent", minutes = recent.minutes, level = char.level or 0,
			gained = recent.gained, seconds = recent.seconds, perHour = recent.perHour,
		}
	end
	local xp = char.xp
	if not xp then
		return nil
	end
	local level = char.level or 0
	local bucket = xp.byLevel and xp.byLevel[level]
	if bucket and (bucket.gained or 0) > 0 and (bucket.seconds or 0) >= 60 then
		return {
			scope = "level", level = level, gained = bucket.gained, seconds = bucket.seconds,
			perHour = bucket.gained / bucket.seconds * 3600,
		}
	end
	if (xp.total or 0) > 0 and (xp.seconds or 0) >= 60 then
		return {
			scope = "all", level = level, gained = xp.total, seconds = xp.seconds,
			perHour = xp.total / xp.seconds * 3600,
		}
	end
	return nil
end

-- Deletes the record of the character in view, or resets the one being played.
-- The viewer is dropped first, so nothing can be drawn from a table that has
-- just been removed, and a live session is never left writing into it. The
-- Settings tab reaches this through a confirmation that names the character.
function ns.DeleteViewedRecord()
	local key = ns.viewKey
	if key and ns.db and ns.db.chars and ns.db.chars[key] then
		ns.db.chars[key] = nil
		ns.SetView(nil)
		if ns.OnDataTick then
			ns.OnDataTick()
		end
		return true
	end
	ns.ResetCharStats()
	return false
end

-- The highest level this game offers. The old views assumed 60; that hid the
-- bar for every character above it. Prefer the game's own answer, then the
-- global, then the old fallback.
function ns.MaxLevel()
	if type(GetMaxPlayerLevel) == "function" then
		local ok, level = pcall(GetMaxPlayerLevel)
		if ok and type(level) == "number" and level > 0 then
			return level
		end
	end
	if type(MAX_PLAYER_LEVEL) == "number" and MAX_PLAYER_LEVEL > 0 then
		return MAX_PLAYER_LEVEL
	end
	return 60
end

-- Progress into the current level, as a percentage, from the client's XP
-- numbers. nil when the client refuses, or at the level cap where no bar
-- remains. Only ever about the character being played; UnitXP has no other
-- unit.
function ns.LevelPercent()
	if not (UnitXP and UnitXPMax) then
		return nil
	end
	local ok, xp = pcall(UnitXP, "player")
	local okMax, xpMax = pcall(UnitXPMax, "player")
	if not ok or not okMax or not xp or not xpMax or xpMax <= 0 then
		return nil
	end
	return math.floor(xp / xpMax * 100 + 0.5)
end

-- Best observed values across the characters in the total. Records are
-- exact by construction: a level time that is only a lower bound cannot win
-- a fastest record, a single quest hand-in cannot win an XP rate (a minimum
-- sample window is required), and a metric with no data is absent rather
-- than zero. Cumulative level times compare across characters where single
-- level times cannot, since an early level is always faster. Time to a
-- milestone is the client's /played total at that level-up, exact however
-- much of the level predates install.
-- Every fifth level is a milestone; a character that has not reached one
-- simply has no time recorded for it.
local MILESTONE_LEVELS = {}
for milestone = 5, 60, 5 do
	MILESTONE_LEVELS[milestone] = true
end

-- The number of separate readings Tally holds for a character right now, and
-- the parts it is made of. Shown on the overview as "points of data
-- tracked". Every part is a value Tally wrote itself, so the figure is
-- counted rather than estimated; it grows with what the character has done,
-- not with its class.
function ns.DataPoints(char)
	local parts = {}
	local total = 0
	local function Add(label, count)
		count = math.floor(count or 0)
		if count > 0 then
			parts[#parts + 1] = { label = label, count = count }
			total = total + count
		end
	end
	if not char then
		return 0, parts
	end
	local sessions = char.sessions or {}
	Add("sessions", (sessions.count or 0) + (sessions.current and 1 or 0))
	Add("level-ups", #ns.LevelPoints(char))
	local visits = 0
	for _, zone in pairs(((char.explore or {}).zones) or {}) do
		visits = visits + (zone.visits or 0)
	end
	Add("zone visits", visits)
	Add("quests", char.quests)
	Add("deaths", (char.combat or {}).deaths)
	Add("fights", (char.combat or {}).fights)
	Add("items looted", (char.loot or {}).items)
	local crafts = 0
	for _, count in pairs(((char.professions or {}).crafts) or {}) do
		crafts = crafts + (count or 0)
	end
	Add("crafts", crafts)
	local runs = 0
	for _, dungeon in pairs(((char.explore or {}).dungeons) or {}) do
		runs = runs + (dungeon.entered or 0)
	end
	Add("dungeon runs", runs)
	Add("money changes kept", #(((char.gold or {}).tx) or {}))
	local days = 0
	for _ in pairs(((char.gold or {}).daily) or {}) do
		days = days + 1
	end
	Add("days with money moves", days)
	return total, parts
end

function ns.Records()
	local bestRate, mostLevels, firstLevelUp
	local longestSession, bestSessionGold, bestSessionXp
	local bestDayIncome, bestDayExpense, bestFind
	local mostItems, mostFights, mostDeaths, mostFirsts, mostLooted
	local mostSessionLevels, mostQuests, mostCrafted, mostCraftedItem
	local mostMounted, mostQuestGold
	local mostMailSent, mostMailReceived, mostMessagesSent
	local mostWhispersReceived, mostDuelsWon, mostDuelsLost
	local function SocialRecord(current, value)
		return value and value > 0 and (not current or value > current.count)
	end
	local mostZones, mostDungeons, mostDungeonRuns, mostBosses, mostDeathsByChar, fewestDeaths
	local bestBuyAuction, bestSellAuction, mostSoldUnits, mostBoughtUnits
	local mostFishCaught, mostValuableCatch, mostFishingCasts, mostFishKinds
	local fastestTo = {}
	local mostCraftedByProfession = {}
	local mostGatheredByProfession = {}
	local mostCraftedTotalByProfession = {}
	local favor = { earnedTotal = 0, spentTotal = 0, heldTotal = 0 }
	local cooldownUses, cooldownOff, cooldownShortest = {}, {}, {}
	local now = ns.Now()

	local series = ns.LevelSeries()
	for index = 1, #series do
		local entry = series[index]
		local char = entry.char
		local name = entry.name
		local classFile = char.classFile

		-- The first level-up Tally ever saw, once per character.
		local history = (char.levels and char.levels.history) or {}
		for historyIndex = 1, #history do
			local levelUp = history[historyIndex]
			if levelUp.at and not levelUp.partial then
				if not firstLevelUp or levelUp.at < firstLevelUp.at then
					firstLevelUp = { at = levelUp.at, level = levelUp.level, name = name, classFile = classFile, key = entry.key }
				end
				break
			end
		end

		-- Fastest to each milestone level: the client's lifetime /played
		-- figure at the moment that level was reached, which is the reading
		-- minus the time the client says it had already spent on it. That is
		-- exact even when the level was played while Tally was not watching.
		for historyIndex = 1, #history do
			local levelUp = history[historyIndex]
			local milestone = levelUp.level
			if levelUp.total and milestone and MILESTONE_LEVELS[milestone] then
				local reached = levelUp.total
				if levelUp.levelTime and not levelUp.levelTimeUnknown then
					reached = reached - levelUp.levelTime
				end
				local best = fastestTo[milestone]
				if not best or reached < best.seconds then
					fastestTo[milestone] = {
						seconds = reached, level = milestone, at = levelUp.at,
						name = name, classFile = classFile, key = entry.key,
					}
				end
			end
		end

		local gained = math.max(0, (char.level or 0) - (char.firstLevel or char.level or 0))
		if gained > 0 and (not mostLevels or gained > mostLevels.count) then
			mostLevels = { count = gained, at = char.created, name = name, classFile = classFile, key = entry.key }
		end

		-- Quests completed since install, one flat total per character:
		-- who has turned in the most, with no per-session breakdown.
		local quests = char.quests or 0
		if quests > 0 and (not mostQuests or quests > mostQuests.count) then
			mostQuests = { count = quests, name = name, classFile = classFile, key = entry.key }
		end

		-- Social counters, one lifetime total per character.
		local social = char.social or {}
		local socialMail = social.mail or {}
		local socialChat = social.chat or {}
		local socialWhispers = social.whispers or {}
		local socialDuels = social.duels or {}
		if SocialRecord(mostMailSent, socialMail.sent) then
			mostMailSent = { count = socialMail.sent, name = name, classFile = classFile, key = entry.key }
		end
		if SocialRecord(mostMailReceived, socialMail.received) then
			mostMailReceived = { count = socialMail.received, name = name, classFile = classFile, key = entry.key }
		end
		if SocialRecord(mostMessagesSent, socialChat.sent) then
			mostMessagesSent = { count = socialChat.sent, name = name, classFile = classFile, key = entry.key }
		end
		if SocialRecord(mostWhispersReceived, socialWhispers.received) then
			mostWhispersReceived = { count = socialWhispers.received, name = name, classFile = classFile, key = entry.key }
		end
		if SocialRecord(mostDuelsWon, socialDuels.won) then
			mostDuelsWon = { count = socialDuels.won, name = name, classFile = classFile, key = entry.key }
		end
		if SocialRecord(mostDuelsLost, socialDuels.lost) then
			mostDuelsLost = { count = socialDuels.lost, name = name, classFile = classFile, key = entry.key }
		end

		-- Quest reward money, one lifetime total per character: the income
		-- Tally booked to the quests category.
		local questGold = (char.gold and char.gold.income and char.gold.income.quest) or 0
		if questGold > 0 and (not mostQuestGold or questGold > mostQuestGold.value) then
			mostQuestGold = { value = questGold, name = name, classFile = classFile, key = entry.key }
		end

		-- Time on a mount, one lifetime total per character. Only characters
		-- whose client answered have a figure at all.
		local mountedSeconds = (char.explore or {}).mountedSeconds or 0
		if mountedSeconds > 0 and (not mostMounted or mountedSeconds > mostMounted.seconds) then
			mostMounted = { seconds = mountedSeconds, name = name, classFile = classFile, key = entry.key }
		end

		-- Items crafted successfully, all professions summed: one flat
		-- lifetime total per character, like the quests.
		local crafts = 0
		local professionStore = char.professions
		for _, count in pairs((type(professionStore) == "table" and professionStore.crafts) or {}) do
			crafts = crafts + (count or 0)
		end
		if crafts > 0 and (not mostCrafted or crafts > mostCrafted.count) then
			mostCrafted = { count = crafts, name = name, classFile = classFile, key = entry.key }
		end

		-- The recipe crafted most often across characters. Ties break by
		-- item name, so the row does not reshuffle between refreshes with
		-- equal counts.
		local craftedItems = (type(professionStore) == "table" and professionStore.crafted) or {}
		for _, tally in pairs(craftedItems) do
			local count = tally.count or 0
			if count > 0 and (not mostCraftedItem or count > mostCraftedItem.count
				or (count == mostCraftedItem.count and (tally.name or "") < (mostCraftedItem.item or ""))) then
				mostCraftedItem = {
					count = count, item = tally.name, itemID = tally.itemID, quality = tally.quality,
					name = name, classFile = classFile, key = entry.key,
				}
			end
		end

		-- The most crafted item in each profession, kept per profession so an
		-- Alchemy record and a Tailoring record can stand side by side.
		local byProfession = ns.MostCraftedByProfession and ns.MostCraftedByProfession(char) or {}
		for profession, tally in pairs(byProfession) do
			local count = tally.count or 0
			local best = mostCraftedByProfession[profession]
			local betterTie = best and count == best.count and (tally.name or "") < (best.item or "")
			if count > 0 and (not best or count > best.count or betterTie) then
				mostCraftedByProfession[profession] = {
					count = count, item = tally.name, itemID = tally.itemID, quality = tally.quality,
					profession = profession,
					name = name, classFile = classFile, key = entry.key,
				}
			end
		end

		-- The total number of items crafted in each profession. The row above
		-- is the single recipe crafted most often; this one is the whole
		-- profession's output, which is what "most cooked" means.
		for profession, craftsInProfession in pairs((type(professionStore) == "table" and professionStore.crafts) or {}) do
			local count = tonumber(craftsInProfession) or 0
			local best = mostCraftedTotalByProfession[profession]
			if count > 0 and (not best or count > best.count) then
				mostCraftedTotalByProfession[profession] = {
					count = count, profession = profession,
					name = name, classFile = classFile, key = entry.key,
				}
			end
		end

		-- Items gathered by each gathering profession. The count is what the
		-- Gathered view shows, so "most mined" and the Mining column agree.
		local gathering = char.gathering or {}
		for _, profession in ipairs({ "Mining", "Herbalism", "Skinning" }) do
			local entry = gathering[profession]
			local count = type(entry) == "table" and (tonumber(entry.gathered) or 0) or 0
			if count <= 0 and type(entry) == "table" and type(entry.items) == "table" then
				for _, item in pairs(entry.items) do
					count = count + (tonumber(item.count) or 0)
				end
			end
			if count > 0 then
				local best = mostGatheredByProfession[profession]
				if not best or count > best.count then
					mostGatheredByProfession[profession] = {
						count = count, attempts = tonumber(entry.attempts) or 0,
						name = name, classFile = classFile, key = entry.key,
					}
				end
			end
		end

		-- Merchant's Favor: per-character currency total, plus the best day
		-- and the largest single gain. The UI only shows these on Forever,
		-- but the figures are harmless to compute from an imported record.
		local currency = char.currency
		local favorEntry = type(currency) == "table" and currency[3402]
		if type(favorEntry) == "table" then
			local earned = tonumber(favorEntry.earned) or 0
			local spent = tonumber(favorEntry.spent) or 0
			local balance = tonumber(favorEntry.balance) or 0
			favor.earnedTotal = favor.earnedTotal + earned
			favor.spentTotal = favor.spentTotal + spent
			favor.heldTotal = favor.heldTotal + balance
			if earned > 0 and (not favor.mostEarned or earned > favor.mostEarned.count) then
				favor.mostEarned = { count = earned, name = name, classFile = classFile, key = entry.key }
			end
			if spent > 0 and (not favor.mostSpent or spent > favor.mostSpent.count) then
				favor.mostSpent = { count = spent, name = name, classFile = classFile, key = entry.key }
			end
			if balance > 0 and (not favor.mostHeld or balance > favor.mostHeld.count) then
				favor.mostHeld = { count = balance, name = name, classFile = classFile, key = entry.key }
			end
			local bestGain = tonumber(favorEntry.bestGain) or 0
			if bestGain > 0 and (not favor.bestGain or bestGain > favor.bestGain.count) then
				favor.bestGain = {
					count = bestGain, at = favorEntry.bestGainAt,
					level = tonumber(favorEntry.bestGainLevel) or 0,
					name = name, classFile = classFile, key = entry.key,
				}
			end
			for day, dayRow in pairs(type(favorEntry.daily) == "table" and favorEntry.daily or {}) do
				local dayEarned = type(dayRow) == "table" and (tonumber(dayRow.earned) or 0) or 0
				if dayEarned > 0 and (not favor.bestDay or dayEarned > favor.bestDay.count) then
					favor.bestDay = {
						count = dayEarned, day = day,
						name = name, classFile = classFile, key = entry.key,
					}
				end
			end
		end

		-- Cooldown activations: uses and the time spent off cooldown. Only
		-- characters who actually have the recipe produce entries here.
		local cooldownStats = (type(professionStore) == "table" and professionStore.cooldownStats) or {}
		for cooldownKey, stats in pairs(cooldownStats) do
			local uses = stats.uses or 0
			if uses > 0 then
				local best = cooldownUses[cooldownKey]
				if not best or uses > best.count then
					cooldownUses[cooldownKey] = {
						count = uses, cooldown = stats.name, profession = stats.profession,
						itemID = stats.itemID, quality = stats.quality,
						name = name, classFile = classFile, key = entry.key,
					}
				end
				local off = (stats.offSeconds or 0) + (stats.offSince and math.max(0, now - stats.offSince) or 0)
				if off > 0 then
					local bestOff = cooldownOff[cooldownKey]
					if not bestOff or off > bestOff.seconds then
						cooldownOff[cooldownKey] = {
							seconds = off, cooldown = stats.name, profession = stats.profession,
							itemID = stats.itemID, quality = stats.quality,
							name = name, classFile = classFile, key = entry.key,
						}
					end
				end
				local shortest = stats.shortestOff
				if shortest ~= nil then
					local bestShort = cooldownShortest[cooldownKey]
					if not bestShort or shortest < bestShort.seconds then
						cooldownShortest[cooldownKey] = {
							seconds = shortest, cooldown = stats.name, profession = stats.profession,
							itemID = stats.itemID, quality = stats.quality,
							name = name, classFile = classFile, key = entry.key,
						}
					end
				end
			end
		end

		local zoneCount = ns.CountTable((char.explore or {}).zones)
		if zoneCount > 0 and (not mostZones or zoneCount > mostZones.count) then
			mostZones = { count = zoneCount, name = name, classFile = classFile, key = entry.key }
		end
		-- Dungeons visited is the number of distinct instances; runs is how
		-- many times one was entered, which is the same count for a
		-- character who has been in each of them once.
		local dungeonCount, dungeonRuns = 0, 0
		for _, dungeon in pairs((char.explore or {}).dungeons or {}) do
			dungeonCount = dungeonCount + 1
			dungeonRuns = dungeonRuns + (dungeon.entered or 0)
		end
		if dungeonCount > 0 and (not mostDungeons or dungeonCount > mostDungeons.count) then
			mostDungeons = { count = dungeonCount, name = name, classFile = classFile, key = entry.key }
		end
		if dungeonRuns > 0 and (not mostDungeonRuns or dungeonRuns > mostDungeonRuns.count) then
			mostDungeonRuns = { count = dungeonRuns, name = name, classFile = classFile, key = entry.key }
		end
		local bosses = (char.explore or {}).bosses or 0
		if bosses > 0 and (not mostBosses or bosses > mostBosses.count) then
			mostBosses = { count = bosses, name = name, classFile = classFile, key = entry.key }
		end
		local deathTotal = (char.combat or {}).deaths or 0
		if deathTotal > 0 and (not mostDeathsByChar or deathTotal > mostDeathsByChar.count) then
			mostDeathsByChar = { count = deathTotal, name = name, classFile = classFile, key = entry.key }
		end
		if (char.tracked or 0) >= 3600 and (not fewestDeaths or deathTotal < fewestDeaths.count) then
			fewestDeaths = {
				count = deathTotal, tracked = char.tracked,
				name = name, classFile = classFile, key = entry.key,
			}
		end

		-- The character's best ten contiguous minutes, kept by the sampler as
		-- each minute closes: a full ten-minute window, so a burst inside it
		-- is averaged rather than winning on its own. Records from before the
		-- minute buckets existed have no window and simply do not compete.
		local bestWindow = (char.xp and char.xp.bestWindow) or nil
		if bestWindow and (bestWindow.rate or 0) > 0 then
			if not bestRate or bestWindow.rate > bestRate.rate then
				bestRate = {
					rate = bestWindow.rate, at = bestWindow.at,
					gained = bestWindow.gained, minutes = bestWindow.minutes or TUNING.xpWindowMinutes,
					name = name, classFile = classFile, key = entry.key,
				}
			end
		end

		local sessions = (char.sessions and char.sessions.history) or {}
		for sessionIndex = 1, #sessions do
			local session = sessions[sessionIndex]
			local seconds = session.seconds or 0
			if seconds > 0 and (not longestSession or seconds > longestSession.seconds) then
				longestSession = { seconds = seconds, start = session.start, name = name, classFile = classFile, key = entry.key }
			end
			-- Levels gained within this session's window, from the level-up
			-- timestamps. Entries without a reliable time (the first
			-- snapshot, or a gap) are excluded rather than credited to the
			-- next session.
			local start = session.start or 0
			local levelCount = 0
			for historyIndex = 1, #history do
				local levelUp = history[historyIndex]
				if levelUp.at and not levelUp.partial and not levelUp.gap
					and levelUp.at >= start and levelUp.at <= start + seconds then
					levelCount = levelCount + 1
				end
			end
			if levelCount > 0 and (not mostSessionLevels or levelCount > mostSessionLevels.count) then
				mostSessionLevels = { count = levelCount, start = session.start, name = name, classFile = classFile, key = entry.key }
			end
			local delta = session.goldStart and ((session.goldEnd or session.goldStart) - session.goldStart) or 0
			if delta > 0 and (not bestSessionGold or delta > bestSessionGold.amount) then
				bestSessionGold = { amount = delta, start = session.start, name = name, classFile = classFile, key = entry.key }
			end
			if (session.xp or 0) > 0 and (not bestSessionXp or session.xp > bestSessionXp.amount) then
				bestSessionXp = { amount = session.xp, start = session.start, name = name, classFile = classFile, key = entry.key }
			end
			if (session.items or 0) > 0 and (not mostItems or session.items > mostItems.count) then
				mostItems = { count = session.items, start = session.start, name = name, classFile = classFile, key = entry.key }
			end
			if (session.fights or 0) > 0 and (not mostFights or session.fights > mostFights.count) then
				mostFights = { count = session.fights, start = session.start, name = name, classFile = classFile, key = entry.key }
			end
			if (session.deaths or 0) > 0 and (not mostDeaths or session.deaths > mostDeaths.count) then
				mostDeaths = { count = session.deaths, start = session.start, name = name, classFile = classFile, key = entry.key }
			end
			local firsts = #(session.firsts or {})
			if firsts > 0 and (not mostFirsts or firsts > mostFirsts.count) then
				mostFirsts = { count = firsts, start = session.start, name = name, classFile = classFile, key = entry.key }
			end
		end

		local gold = char.gold or {}
		for day, totals in pairs(gold.daily or {}) do
			if (totals.income or 0) > 0 and (not bestDayIncome or totals.income > bestDayIncome.amount) then
				bestDayIncome = { amount = totals.income, day = day, name = name, classFile = classFile, key = entry.key }
			end
			if (totals.expense or 0) > 0 and (not bestDayExpense or totals.expense > bestDayExpense.amount) then
				bestDayExpense = { amount = totals.expense, day = day, name = name, classFile = classFile, key = entry.key }
			end
		end

		local finds = (char.loot and char.loot.best) or {}
		for findIndex = 1, #finds do
			local find = finds[findIndex]
			if (find.value or 0) > 0 and (not bestFind or find.value > bestFind.value) then
				bestFind = {
					value = find.value, item = find.name, quality = find.quality, at = find.at,
					name = name, classFile = classFile, key = entry.key,
				}
			end
		end

		-- The most looted item: one tally per item id, highest count wins,
		-- ties broken by name so the row does not reshuffle between
		-- refreshes.
		local tallies = (char.loot and char.loot.itemCounts) or {}
		for itemID, tally in pairs(tallies) do
			local upper = tally.count or 0
			local lower, estimated = ns.LootTallyCount(tally)
			if upper > 0 and (not mostLooted or upper > (mostLooted.upper or 0)
				or (upper == (mostLooted.upper or 0) and (tally.name or "") < (mostLooted.item or ""))) then
				mostLooted = {
					count = lower, upper = upper, estimated = estimated,
					item = tally.name, itemID = itemID,
					name = name, classFile = classFile, key = entry.key,
				}
			end
		end

		-- The auction house: the dearest single purchase and the dearest
		-- single sale Tally saw, and the characters who have moved the most
		-- items each way. Every figure comes from a recorded invoice, so a
		-- character who has never bought or sold has nothing here rather
		-- than a zero that would win by doing nothing.
		local ah = char.ah or {}
		if (ah.bestBuy and ah.bestBuy.price or 0) > 0
			and (not bestBuyAuction or ah.bestBuy.price > bestBuyAuction.value) then
			bestBuyAuction = {
				value = ah.bestBuy.price, item = ah.bestBuy.name, quality = ah.bestBuy.quality,
				at = ah.bestBuy.at, name = name, classFile = classFile, key = entry.key,
			}
		end
		if (ah.best and ah.best.price or 0) > 0
			and (not bestSellAuction or ah.best.price > bestSellAuction.value) then
			bestSellAuction = {
				value = ah.best.price, item = ah.best.name, quality = ah.best.quality,
				at = ah.best.at, name = name, classFile = classFile, key = entry.key,
			}
		end
		if (ah.units or 0) > 0 and (not mostSoldUnits or ah.units > mostSoldUnits.count) then
			mostSoldUnits = {
				count = ah.units, sales = ah.sold or 0,
				name = name, classFile = classFile, key = entry.key,
			}
		end
		if (ah.boughtUnits or 0) > 0 and (not mostBoughtUnits or ah.boughtUnits > mostBoughtUnits.count) then
			mostBoughtUnits = {
				count = ah.boughtUnits, spent = ah.spent or 0,
				name = name, classFile = classFile, key = entry.key,
			}
		end

		-- Fishing: every item looted during a cast counts, so these are
		-- collection records rather than one-catch records. A character with
		-- no cast or no catch has nothing here rather than a zero that wins.
		local fishing = char.fishing or {}
		local fishCatches = tonumber(fishing.catches) or 0
		local fishKinds, fishZones = 0, 0
		for _ in pairs(fishing.items or {}) do
			fishKinds = fishKinds + 1
		end
		for _ in pairs(fishing.zones or {}) do
			fishZones = fishZones + 1
		end
		if fishCatches > 0 and (not mostFishCaught or fishCatches > mostFishCaught.count) then
			mostFishCaught = {
				count = fishCatches, kinds = fishKinds, zones = fishZones,
				name = name, classFile = classFile, key = entry.key,
			}
		end
		if fishKinds > 0 and (not mostFishKinds or fishKinds > mostFishKinds.count) then
			mostFishKinds = {
				count = fishKinds, catches = fishCatches,
				name = name, classFile = classFile, key = entry.key,
			}
		end
		local fishCasts = tonumber(fishing.casts) or 0
		if fishCasts > 0 and (not mostFishingCasts or fishCasts > mostFishingCasts.count) then
			mostFishingCasts = {
				count = fishCasts, catches = fishCatches,
				name = name, classFile = classFile, key = entry.key,
			}
		end
		local bestCatch = fishing.best
		if type(bestCatch) == "table" and (tonumber(bestCatch.value) or 0) > 0
			and (not mostValuableCatch or bestCatch.value > mostValuableCatch.value) then
			mostValuableCatch = {
				value = bestCatch.value, item = bestCatch.name, itemID = bestCatch.id,
				quality = bestCatch.quality, at = bestCatch.at, zone = bestCatch.zone,
				name = name, classFile = classFile, key = entry.key,
			}
		end
	end

	return {
		fastestTo = fastestTo, bestRate = bestRate, mostLevels = mostLevels, mostQuests = mostQuests, mostQuestGold = mostQuestGold, mostMailSent = mostMailSent, mostMailReceived = mostMailReceived, mostMessagesSent = mostMessagesSent, mostWhispersReceived = mostWhispersReceived, mostDuelsWon = mostDuelsWon, mostDuelsLost = mostDuelsLost,
		mostCrafted = mostCrafted, mostCraftedItem = mostCraftedItem, firstLevelUp = firstLevelUp, longestSession = longestSession,
		mostCraftedByProfession = mostCraftedByProfession,
		mostGatheredByProfession = mostGatheredByProfession,
		mostCraftedTotalByProfession = mostCraftedTotalByProfession,
		favor = favor,
		cooldownUses = cooldownUses, cooldownOff = cooldownOff, cooldownShortest = cooldownShortest,
		bestSessionGold = bestSessionGold, bestSessionXp = bestSessionXp,
		bestDayIncome = bestDayIncome, bestDayExpense = bestDayExpense, bestFind = bestFind,
		mostItems = mostItems, mostFights = mostFights, mostDeaths = mostDeaths, mostFirsts = mostFirsts,
		mostSessionLevels = mostSessionLevels, mostLooted = mostLooted,
		mostMounted = mostMounted,
		mostZones = mostZones, mostDungeons = mostDungeons, mostDungeonRuns = mostDungeonRuns,
		mostBosses = mostBosses, mostDeathsByChar = mostDeathsByChar, fewestDeaths = fewestDeaths,
		bestBuyAuction = bestBuyAuction, bestSellAuction = bestSellAuction,
		mostSoldUnits = mostSoldUnits, mostBoughtUnits = mostBoughtUnits,
		mostFishCaught = mostFishCaught, mostValuableCatch = mostValuableCatch,
		mostFishingCasts = mostFishingCasts, mostFishKinds = mostFishKinds,
	}
end

-- Slash commands
-------------------------------------------------------------------------------

-- Prints the names this client gives a character, raw. The client can give
-- a character two names while UnitName returns only the first, so the whole
-- name is needed to tell same-named characters apart. Read-only: nothing is
-- stored, no function replaced, no protected frame touched.
local SURNAME_GLOBALS = {
	"UnitSurname", "GetSurname", "GetPlayerSurname",
	"UnitLastName", "GetLastName", "GetPlayerLastName",
	"GetFullName", "GetPlayerFullName", "GetCharacterFullName", "GetPlayerName",
}

local function QuotedValue(value)
	if value == nil then
		return "nil"
	end
	return "["..tostring(value).."]"
end

local function AddProbeLine(lines, label, ...)
	local parts = {}
	for index = 1, select("#", ...) do
		parts[#parts + 1] = QuotedValue(select(index, ...))
	end
	lines[#lines + 1] = label.." = "..table.concat(parts, " ")
end

local function BuildNameProbeLines()
	local lines = {}
	if UnitName then
		AddProbeLine(lines, "UnitName('player')", UnitName("player"))
		AddProbeLine(lines, "UnitName('player', true)", UnitName("player", true))
	end
	if UnitFullName then
		AddProbeLine(lines, "UnitFullName('player')", UnitFullName("player"))
	end
	if GetUnitName then
		AddProbeLine(lines, "GetUnitName('player')", GetUnitName("player"))
		AddProbeLine(lines, "GetUnitName('player', true)", GetUnitName("player", true))
	end
	if GetRealmName then
		AddProbeLine(lines, "GetRealmName()", GetRealmName())
	end
	if UnitGUID then
		AddProbeLine(lines, "UnitGUID('player')", UnitGUID("player"))
	end
	-- Tally's own idea of the name, straight from the saved record.
	local stored = ns.db and ns.db.chars and ns.db.chars[ns.charKey]
	AddProbeLine(lines, "Tally's stored name / realm", stored and stored.name, stored and stored.realm)
	AddProbeLine(lines, "Tally's surname / key used", stored and stored.surname, ns.charKey)
	AddProbeLine(lines, "Tally's stored guid", stored and stored.guid)
	AddProbeLine(lines, "logout events this client has sent", tostring(ns.db and ns.db.logoutEvents or 0))
	if ns.worldEntry then
		lines[#lines + 1] = "world entry flags this load: initialLogin="..tostring(ns.worldEntry.initial)..", reloadUi="..tostring(ns.worldEntry.reload).." - Tally read it as: "..ns.worldEntry.mode
	end
	-- Every filed character key, which is what a name collision affects.
	if ns.db and ns.db.chars then
		local keys = {}
		for key in pairs(ns.db.chars) do
			keys[#keys + 1] = key
		end
		table.sort(keys)
		lines[#lines + 1] = "stored character keys ("..#keys.."): "..table.concat(keys, ", ")
	end
	-- The frames the client's own UI draws the name into, if they exist here.
	if PlayerFrame and PlayerFrame.name and PlayerFrame.name.GetText then
		local ok, text = pcall(PlayerFrame.name.GetText, PlayerFrame.name)
		if ok then
			AddProbeLine(lines, "PlayerFrame.name", text)
		end
	end
	if PlayerFrame and PlayerFrame.Name and PlayerFrame.Name.GetText then
		local ok, text = pcall(PlayerFrame.Name.GetText, PlayerFrame.Name)
		if ok then
			AddProbeLine(lines, "PlayerFrame.Name", text)
		end
	end
	-- The player tooltip's first line carries whatever the client considers
	-- the full name.
	if GameTooltip and GameTooltipTextLeft1 and GameTooltipTextLeft1.GetText then
		GameTooltip:SetOwner(UIParent, "ANCHOR_NONE")
		local ok = pcall(function()
			GameTooltip:SetUnit("player")
		end)
		local text = ok and GameTooltipTextLeft1:GetText()
		GameTooltip:Hide()
		AddProbeLine(lines, "player tooltip line 1", text)
	end
	-- A surname accessor, if this client ships one under any of the usual
	-- names. A missing global is simply not called.
	local present = 0
	for index = 1, #SURNAME_GLOBALS do
		local globalName = SURNAME_GLOBALS[index]
		local fn = _G[globalName]
		if type(fn) == "function" then
			present = present + 1
			local ok, first, second = pcall(fn, "player")
			if not ok then
				ok, first, second = pcall(fn)
			end
			if ok then
				AddProbeLine(lines, globalName.."()", first, second)
			else
				lines[#lines + 1] = globalName.." exists but errored: "..tostring(first)
			end
		end
	end
	lines[#lines + 1] = "Surname-style globals present: "..present.." of "..#SURNAME_GLOBALS.." tried."
	return lines
end

local function HandleSlash(message)
	if not ns.db then
		return
	end
	local command = string.lower(ns.Trim(message or ""))
	local argument
	-- The command is matched in lower case, but the argument keeps its own
	-- case: a second name has to come back out exactly as it was typed.
	local raw = ns.Trim(message or "")
	local space = string.find(raw, " ", 1, true)
	if space then
		command = string.sub(string.lower(raw), 1, space - 1)
		argument = ns.Trim(string.sub(raw, space + 1))
	end
	if command == "" or command == "show" or command == "stats" then
		if ns.ToggleMainWindow then
			ns.ToggleMainWindow()
		end
	elseif command == "print" or command == "report" then
		ns.reports.Print(string.lower(argument or "overview"))
	elseif command == "copy" then
		ns.reports.Copy(string.lower(argument or "overview"))
	elseif command == "audit" then
		if ns.AuditData then
			ns.AuditData()
		end
	elseif command == "export" then
		if ns.ExportData then
			ns.ExportData()
		end
	elseif command == "combatlog" then
		if not ns.CombatLogUsable() then
			ns.Print("This game does not hand the combat log to addons, so the combat-log read is off. World kills come from the game's kill events; instance kills from experience lines and looted corpses.")
		else
			ns.db.settings.combatLogRead = not ns.db.settings.combatLogRead
			ns.ApplyCombatLogSetting()
		end
	elseif command == "debug" then
		ns.Print("Tally v"..ns.GetAddonVersion()..": autoPlayedSync="..tostring(ns.db.settings.autoPlayedSync)..", playedSyncBlocked="..tostring(ns.db.settings.playedSyncBlocked)..", copyDirect="..tostring(ns.db.settings.copyDirect)..", combatLogRead="..tostring(ns.db.settings.combatLogRead))
		local events = ns.EventOwners and ns.EventOwners() or {}
		local handlers = 0
		for index = 1, #events do
			handlers = handlers + (events[index].count or 0)
		end
		ns.Print("schema: "..tostring(ns.SchemaVersion and ns.SchemaVersion() or 0).." of "..tostring(ns.SCHEMA_VERSION or "?").."; events: "..#events..", handlers: "..handlers)
		ns.Print("social hooks: send="..tostring(ns.socialSendHooked)..", edit="..tostring(ns.socialEditHooked))
		if ns.AuctionDebugText then
			ns.Print(ns.AuctionDebugText())
		end
		if GuildControlUI then
			ns.Print("GuildControlUI tab: "..tostring(GuildControlUI.selectedTab))
		end
		local found = false
		if StaticPopup_ForEachShownDialog then
			StaticPopup_ForEachShownDialog(function(dialog)
				found = true
				ns.Print("Open popup: "..tostring(dialog.which).." | data="..tostring(dialog.data))
				local text = PopupText(dialog)
				if text then
					ns.Print("  text: "..text)
				end
			end)
		end
		if not found then
			ns.Print("No static popup is open right now.")
		end
	elseif command == "trace" then
		if ns.OpenCopyWindow and ns.OpenCopyWindow("debug + trace", ns.reports.DebugText()) then
			ns.Print("Diagnostic dump is in the copy window - press Ctrl+C there.")
		end
	elseif command == "names" or command == "name" then
		local lines = BuildNameProbeLines()
		if ns.OpenCopyWindow and ns.OpenCopyWindow("name probe", table.concat(lines, "\n")) then
			ns.Print("Name probe is in the copy window - press Ctrl+C there.")
		else
			for index = 1, #lines do
				ns.Print(lines[index])
			end
		end
	elseif command == "surname" then
		local char = ns.db.chars[ns.charKey]
		if not char then
			ns.Print("Tally has no record for this login yet - /tally surname works on the character being played.")
		elseif argument and argument ~= "" then
			char.surname = argument
			ns.Print("Second name saved for this record. It is shown when another character shares '"..(char.name or "?").."' and the class; until then the first name stays as it is.")
		elseif char.surname then
			char.surname = nil
			ns.Print("Second name cleared for this record.")
		else
			ns.Print("Usage: /tally surname <the part UnitName leaves out> - for example /tally surname Applepie")
		end
	elseif command == "auras" or command == "buffs" then
		local char = ns.db.chars[ns.charKey]
		if not char then
			ns.Print("Tally has no record for this login yet.")
		elseif string.lower(argument or "") == "reset" then
			-- The counts written before the flicker fix (a slot the client
			-- answered nothing for after combat counted as losing and
			-- regaining every buff after it) are inflated. This clears the
			-- aura record alone, so the rest of the character's statistics
			-- survive.
			char.auras = nil
			ns.Print("Buff and debuff records cleared for "..(char.name or "this character")..". Everything else is untouched.")
			if ns.OnDataTick then
				ns.OnDataTick()
			end
		else
			local auras = char.auras or {}
			local camp = auras.camp or {}
			ns.Print("Auras: "..ns.CountTable(auras.buffs).." buffs, "..ns.CountTable(auras.debuffs).." debuffs. Campfire: "..ns.FormatDuration(camp.seconds or 0)..", "..(camp.visits or 0).." visits, "..(camp.benefits or 0).." camp benefits.")
			ns.Print("Usage: /tally auras reset clears this character's buff and debuff record and leaves the rest alone.")
		end
	elseif command == "auctions" or command == "auctionhouse" then
		local char = ns.db.chars[ns.charKey]
		if not char or type(char.ah) ~= "table" then
			ns.Print("Tally has no auction record for this character yet.")
		else
			local posted, accounted, up = ns.AuctionPostingsAudit(char)
			if string.lower(argument or "") == "repair" then
				if posted <= accounted then
					ns.Print("Nothing to repair: the posting count already matches the auctions Tally saw end or still up ("..posted..").")
				else
					ns.pendingAuctionRepair = char
					StaticPopup_Show("TALLY_REPAIR_AUCTIONS", tostring(posted), tostring(accounted))
				end
			else
				ns.Print("Auction house: "..posted.." posted, "..(char.ah.sold or 0).." sold, "..(char.ah.expired or 0).." expired, "..(char.ah.cancelled or 0).." cancelled, "..up.." still up.")
				if posted > accounted then
					ns.Print((posted - accounted).." postings have no ended auction or still-up row behind them: they are readings counted more than once. /tally auctions repair lowers the count to "..accounted.." and leaves the sales alone.")
				else
					ns.Print("The posting count matches the auctions Tally saw end or still up.")
				end
			end
		end
	elseif command == "help" then
		ns.Print("Commands: /tally, /tally print [report], /tally copy [report], /tally audit, /tally export, /tally surname <name>, /tally names, /tally auras [reset], /tally auctions [repair], /tally debug, /tally trace, /tally combatlog")
		ns.Print("Reports: "..table.concat(ns.REPORT_ORDER, ", "))
	else
		ns.Print("Unknown command - type /tally help.")
	end
end

SLASH_TALLY1 = "/tally"
SlashCmdList["TALLY"] = function(message)
	local ok, err = pcall(HandleSlash, message)
	if not ok and not TUNING.errorReports.slash then
		TUNING.errorReports.slash = true
		pcall(ns.Trace, "ERROR in slash command: "..tostring(err))
	end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local function OnAddonLoad()
	ns.Trace("addon loaded")
	if type(TallyDB) ~= "table" then
		-- A damaged or foreign value must not be indexed as the database.
		TallyDB = {}
	end
	ns.db = TallyDB
	ApplyDefaults(ns.db, DEFAULTS)
	if (ns.db.version or 0) < 1 then
		ns.db.version = 1
	end
	ns.RunMigrations(ns.db)

	for _, record in pairs(ns.db.chars or {}) do
		EnsureCharShape(record)
		local combat = record.combat
		if combat and combat.killBaseFights == nil then
			combat.killBaseFights = combat.fights or 0
			combat.killBaseCombat = combat.combatSeconds or 0
			combat.killBaseTracked = record.tracked or 0
		end
	end
	ns.Trace("saved variables ready")
	ns.RegisterForEvents()
	if ns.ApplyKillSource then
		ns.ApplyKillSource()
	end
	ns.InstallPlayedFilter()
	if ns.BuildUI then
		local okBuild, buildError = pcall(ns.BuildUI)
		if not okBuild then
			ns.Print("Tally could not build its window: "..tostring(buildError))
		end
		ns.Trace("UI built")
	end
end


-------------------------------------------------------------------------------
-- Repair hook (money)
-------------------------------------------------------------------------------

-- The repair button: the call itself is the evidence, so the money change
-- that follows can be named a repair even where GetRepairAllCost is
-- refused or the vendor window is closed before the balance settles.
if type(hooksecurefunc) == "function" then
	pcall(hooksecurefunc, "RepairAllItems", function()
		ns.repairWatch.paidAt = Now()
		ns.Trace("repair: the game's repair button was used")
	end)
end

local EVENTS = {
	"PLAYER_LOGIN",
	"PLAYER_ENTERING_WORLD",
	"PLAYER_LOGOUT",
	"PLAYER_MONEY",
	"PLAYER_LEVEL_UP",
	"PLAYER_DEAD",
	"TIME_PLAYED_MSG",
	"ZONE_CHANGED_NEW_AREA",
	"MERCHANT_SHOW",
	"MERCHANT_UPDATE",
	"MERCHANT_CLOSED",
	"TRAINER_SHOW",
	"TRAINER_CLOSED",
	"TRAINER_CLOSE",
	"MAIL_SHOW",
	"MAIL_CLOSED",
	"TRADE_SHOW",
	"TRADE_CLOSED",
	"AUCTION_HOUSE_SHOW",
	"AUCTION_HOUSE_CLOSED",
	"QUEST_COMPLETE",
	"QUEST_TURNED_IN",
	"QUEST_FINISHED",
	"CHAT_MSG_COMBAT_XP_GAIN",
	"LOOT_OPENED",
	"CHAT_MSG_LOOT",
	"CHAT_MSG_MONEY",
	"ENCOUNTER_END",
	"PLAYER_REGEN_DISABLED",
	"PLAYER_REGEN_ENABLED",
	"GET_ITEM_INFO_RECEIVED",
	"COMBAT_LOG_EVENT_UNFILTERED",
	"CHAT_MSG_SYSTEM",
	"CHAT_MSG_SKILL",
	"TRADE_SKILL_SHOW",
	"TRADE_SKILL_UPDATE",
	"TRADE_SKILL_DATA_SOURCE_CHANGED",
	"TRADE_SKILL_LIST_UPDATE",
	"NEW_RECIPE_LEARNED",
	"TRADE_SKILL_CRAFT_BEGIN",
	"TRADE_SKILL_ITEM_CRAFTED_RESULT",
	"TRADE_SKILL_CLOSE",
	"CRAFT_SHOW",
	"CRAFT_UPDATE",
	"CRAFT_CLOSE",
	"UNIT_SPELLCAST_SUCCEEDED",
	"UNIT_SPELLCAST_SENT",
	"ADDON_ACTION_FORBIDDEN",
	"ADDON_ACTION_BLOCKED",
}

-- Forward declaration: the registration helpers below use the handler, and
-- the handler itself is defined after them.
local HandleTallyEvent

-- Some activities outlive the client: a flight in progress, a group still
-- around. Their "already running" state is written at logout and read once at
-- login, so resuming them is not mistaken for starting them. Clocks are
-- included because a crash leaves the previous save in place; a snapshot too
-- old to be the same activity is dropped rather than trusted.
local PRESENCE_FLIGHT_MAX = 10 * 60
local PRESENCE_GROUP_MAX = 60 * 60

local function SavePresence(char)
	if not char then
		return
	end
	local presence = { at = Now() }
	if ns.explore and ns.explore.SnapshotPresence then
		presence.explore = ns.explore.SnapshotPresence()
	end
	if ns.social and ns.social.SnapshotPresence then
		presence.social = ns.social.SnapshotPresence()
	end
	char.presence = presence
	local members = 0
	if presence.social and type(presence.social.units) == "table" then
		for _ in pairs(presence.social.units) do
			members = members + 1
		end
	end
	ns.Trace("presence: saved (on taxi="..tostring(presence.explore and presence.explore.onTaxi)
		..", group members="..members..")")
end

local function RestorePresence(char)
	if not char or type(char.presence) ~= "table" then
		return
	end
	local presence = char.presence
	-- Consumed on read: a snapshot is for the entry that follows it, never
	-- for a later one.
	char.presence = nil
	local age = Now() - (presence.at or 0)
	if age < 0 then
		age = 0
	end
	if type(presence.explore) == "table" and ns.explore and ns.explore.RestorePresence then
		if age <= PRESENCE_FLIGHT_MAX then
			ns.explore.RestorePresence(presence.explore)
		else
			ns.Trace("presence: flight state ignored ("..math.floor(age).."s old)")
		end
	end
	if type(presence.social) == "table" and ns.social and ns.social.RestorePresence then
		if age <= PRESENCE_GROUP_MAX then
			ns.social.RestorePresence(presence.social)
		else
			ns.Trace("presence: group state ignored ("..math.floor(age).."s old)")
		end
	end
end

-- Registers the event handler's events. COMBAT_LOG_EVENT_UNFILTERED is
-- registered only when kill tracking is enabled and the client exposes an
-- accessor; on clients like this one registering it alone triggers a
-- "blocked" popup, and the event is never heard.
function ns.RegisterForEvents()
	-- A saved "on" from a client that refuses the read is cleared here, so
	-- the combat-log event is never registered where it would be refused.
	if ns.db.settings.combatLogRead and not ns.CombatLogUsable() then
		ns.db.settings.combatLogRead = false
	end
	for index = 1, #EVENTS do
		local event = EVENTS[index]
		if event ~= "COMBAT_LOG_EVENT_UNFILTERED" or (ns.db.settings.combatLogRead and ns.CombatLogUsable()) then
			-- A registration failure is skipped rather than breaking the
			-- addon at load time.
			local ok = ns.On(event, HandleTallyEvent, "Core")
			if event == "QUEST_TURNED_IN" then
				-- Whether the game knows the event at all. The count still
				-- waits to see it arrive before it relies on it, so a game
				-- that accepts the registration but never raises it falls
				-- back to the guarded QUEST_FINISHED path.
				ns.questTurnedInReady = ok
			end
		end
	end
	ns.Trace("events registered (combat log read: "..(ns.db.settings.combatLogRead and "on" or "off")..", accessor: "..tostring(ns.CombatLogAccessor() or "none")..")")
end

-- Applies the combat-log setting at runtime: registers or drops the single
-- event and hands the kill source back to nameplates when the log cannot be
-- used. Kills are still counted either way; the dash is only for a client
-- that offers neither source.
function ns.ApplyCombatLogSetting(reason)
	local accessor = ns.CombatLogAccessor()
	local wanted = ns.db.settings.combatLogRead and true or false
	local enabled = (wanted and accessor ~= nil) and true or false
	if wanted and not accessor then
		-- No accessor exists and asking for the event alone is refused
		-- with a popup, so the request is refused locally and nothing is
		-- registered.
		ns.db.settings.combatLogRead = false
		for _, record in pairs(ns.db.chars) do
			if record.combat then
				record.combat.logAvailable = false
			end
		end
		if ns.ApplyKillSource then
			ns.ApplyKillSource()
		end
		if ns.OnDataTick then
			ns.OnDataTick()
		end
		ns.Print("This game does not hand the combat log to addons, so the combat-log read is off. World kills come from the game's kill events; instance kills from experience lines and looted corpses.")
		return
	end
	if enabled then
		ns.On("COMBAT_LOG_EVENT_UNFILTERED", HandleTallyEvent, "Core")
	else
		ns.Off("COMBAT_LOG_EVENT_UNFILTERED", HandleTallyEvent, "Core")
	end
	for _, record in pairs(ns.db.chars) do
		if record.combat then
			record.combat.logAvailable = enabled
		end
	end
	if ns.ApplyKillSource then
		ns.ApplyKillSource()
	end
	if ns.OnDataTick then
		ns.OnDataTick()
	end
	ns.Print(reason or ("Combat log kill tracking: "..(enabled and "on" or "off").."."))
end

ns.Trace("core file load done (build "..ns.BUILD..")")

-- One count per quest turned in. The client raises QUEST_FINISHED for more
-- than a turn-in (accepting a quest raises it too), which is how a level 10
-- character came to read 223 completed quests. QUEST_TURNED_IN is the
-- client's own word for a real turn-in, so it carries the count wherever it
-- arrives; QUEST_FINISHED only counts while that event has not been heard in
-- the session, and only when a turn-in dialog had actually opened. The two
-- stamps keep a turn-in seen twice - or by both events - from counting twice.
local questCountAt, questCountID = 0, nil

local function CountQuest(char, questID)
	if not char or not ns.Tracks("explore") then
		return
	end
	local now = Now()
	if questID and questID == questCountID and (now - questCountAt) <= 5 then
		return
	end
	if (now - questCountAt) <= 2 then
		return
	end
	questCountAt, questCountID = now, questID
	char.quests = (char.quests or 0) + 1
	ns.lastQuestTurnInAt = now
	if ns.NoteFirstQuest then
		ns.NoteFirstQuest(ns.CurrentZone())
	end
	if ns.NoteRecentEvent then
		ns.NoteRecentEvent("quest", {
			at = now, zone = ns.CurrentZone(), how = "quest", evidence = "quest_event",
			data = { count = char.quests },
		})
	end
	ns.Trace("quest completed ("..char.quests.." in total) in "..(ns.CurrentZone() or "an unknown zone"))
	if ns.NoteQuestMilestone then
		ns.NoteQuestMilestone(char.quests)
	end
	if ns.OnDataTick then
		ns.OnDataTick()
	end
end

HandleTallyEvent = function(event, ...)
	if event == "ADDON_LOADED" then
		local loadedAddon = ...
		if loadedAddon == addonName then
			ns.Off("ADDON_LOADED", HandleTallyEvent, "Core")
			OnAddonLoad()
		end
		return
	end
	-- Blocked actions can fire before the addon finishes loading, so this
	-- branch sits above the saved-variables guard; an early refusal is
	-- traced raw rather than dropped.
	if event == "ADDON_ACTION_FORBIDDEN" or event == "ADDON_ACTION_BLOCKED" then
		local which, blockedFunction = ...
		if ns.db then
			OnBlockedAction(event, which, blockedFunction)
		else
			ns.Trace("blocked before load: "..tostring(event)..", addon="..tostring(which)..", function="..tostring(blockedFunction))
		end
		return
	end

	if not ns.db then
		return
	end

	if event == "PLAYER_LOGIN" then
		ns.Trace("player login")
		-- A character switched to in the same client session is a new
		-- character: start-of-play work, the session boundary and the money
		-- context all belong to the previous one. Resetting here keeps
		-- addons from carrying that state across the character select.
		beginPlayDone = false
		sessionResumed = false
		worldEntered = false
		lastPlayedSync = 0
		playedRetryAt = 0
		pendingLevelSnapshot = nil
		questPending = false
		recentXpGains = {}
		if ns.ResetMoneyContext then
			ns.ResetMoneyContext()
		end
		if ns.ClearPendingLoot then
			ns.ClearPendingLoot()
		end
		if ns.auras and ns.auras.ResetScanGrace then
			ns.auras.ResetScanGrace()
		end
		local okInit, initError = pcall(InitializeCharacter)
		if not okInit then
			ns.Trace("ERROR in InitializeCharacter: "..tostring(initError))
		end
		local char = ns.GetChar()
		if char then
			-- Before the first tick: what was running when the client last
			-- closed must resume, not restart.
			RestorePresence(char)
		end
		playerGUID = UnitGUID("player")
		ns.playerName = UnitName("player") or ns.playerName
		ns.Trace("character ready")
		lastPlayedSync = Now()
		local okPlay, playError = pcall(BeginPlay)
		if not okPlay then
			ns.Trace("ERROR in BeginPlay: "..tostring(playError))
		end
		if ns.Tracks("loot") then
			ns.QueueLootQualityRepair()
		end
		if ns.Tracks("economy") then
			ns.SnapshotProfessions(ns.GetChar(), "login")
		end
		if ns.EnsureFirstSeen then
			ns.EnsureFirstSeen(ns.GetChar())
		end
		if ns.RepairDuplicateLevels then
			ns.RepairDuplicateLevels(ns.GetChar())
		end
		if ns.RepairMissingLevel then
			ns.RepairMissingLevel(ns.GetChar())
		end
		ns.Trace("begin play done")
		if worldEntered then
			-- The world was entered before PLAYER_LOGIN, so the entry
			-- flags were unavailable; the session boundary uses the clock.
			BeginSession(nil, nil)
		end
		if not ns.db.settings.quiet then
			ns.Print("Loaded - /tally opens your statistics, or click the minimap icon.")
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		local isInitialLogin, isReloadingUi = ...
		worldEntered = true
		ns.Trace("entering world (initial login="..tostring(isInitialLogin)..", ui reload="..tostring(isReloadingUi)..")")
		BeginPlay()
		BeginSession(isInitialLogin, isReloadingUi)
		ns.explore.UpdateArea()
		-- The minimap has its real size by now: put the icon back on its
		-- ring at the saved angle (the first apply can run before layout).
		if ns.ApplyIconPosition then
			ns.ApplyIconPosition()
		end
	elseif event == "PLAYER_LOGOUT" then
		-- Counted every time, character or not: whether the client reports
		-- logouts distinguishes a crash, and /tally names prints this
		-- number.
		ns.db.logoutEvents = (ns.db.logoutEvents or 0) + 1
		local char = ns.GetChar()
		if char then
			-- Written before the client serialises: what is still running at
			-- this moment is what the next entry should continue.
			SavePresence(char)
			if FinalizeSession(Now(), "logout", true) then
				-- If the next world entry is a /reload, it continues this
				-- session rather than starting a new one.
				char.sessions.reloadable = true
			end
			char.level = UnitLevel("player") or char.level
			if (char.highLevel or 0) < (char.level or 0) then
				char.highLevel = char.level
			end
			if ns.Tracks("economy") then
				ns.MoneyOnLogout(char)
			end
		end
	elseif event == "PLAYER_MONEY" then
		if ns.Tracks("economy") then
			ns.NoteMoneyEvent()
			ns.PollMoney(worldEntered)
		end
	elseif event == "MERCHANT_SHOW" then
		if ns.Tracks("economy") then
			ns.moneyContext.merchantShown = true
			ns.NoteRepairCost()
		end
	elseif event == "MERCHANT_UPDATE" then
		if ns.moneyContext.merchantShown and ns.Tracks("economy") then
			ns.NoteRepairCost()
		end
	elseif event == "MERCHANT_CLOSED" then
		ns.moneyContext.merchantShown = false
		ns.moneyContext.closedAt.merchant = Now()
		-- The quote is not dropped here: the money change is confirmed a
		-- second or two later, and closing the window at once must not turn
		-- a repair into an unexplained loss. It expires by time instead.
		ns.repairWatch.at = Now()
	elseif event == "TRAINER_SHOW" then
		ns.moneyContext.trainerShown = true
	elseif event == "TRAINER_CLOSED" or event == "TRAINER_CLOSE" then
		ns.moneyContext.trainerShown = false
		ns.moneyContext.closedAt.trainer = Now()
	elseif event == "MAIL_SHOW" then
		ns.moneyContext.mailShown = true
	elseif event == "MAIL_CLOSED" then
		ns.moneyContext.mailShown = false
		ns.moneyContext.closedAt.mail = Now()
	elseif event == "TRADE_SHOW" then
		ns.moneyContext.tradeShown = true
	elseif event == "TRADE_CLOSED" then
		ns.moneyContext.tradeShown = false
		ns.moneyContext.closedAt.trade = Now()
	elseif event == "AUCTION_HOUSE_SHOW" then
		ns.moneyContext.auctionShown = true
	elseif event == "AUCTION_HOUSE_CLOSED" then
		ns.moneyContext.auctionShown = false
		ns.moneyContext.closedAt.auction = Now()
	elseif event == "QUEST_COMPLETE" then
		-- The turn-in dialog has opened. QUEST_COMPLETE can fire again for the
		-- same quest, so the pending flag is only set once and the count is
		-- not touched here at all. The reward money arrives as the dialog is
		-- accepted, which is after this and usually after QUEST_FINISHED
		-- too, so its window is timed from here rather than from the dialog
		-- still being open.
		if ns.Tracks("explore") and not questPending then
			questPending = true
			questAt = Now()
		end
		if ns.Tracks("economy") then
			-- Quest reward money is a money fact: it is classified even while
			-- quests are paused, so the ledger stays honest.
			ns.moneyContext.questGoldUntil = Now() + TUNING.questGoldWindow
		end
	elseif event == "QUEST_TURNED_IN" then
		-- The client's own word for a turn-in, raised once per quest. It also
		-- opens the experience window, since the experience line follows the
		-- turn-in immediately.
		ns.questTurnedInSeen = true
		if ns.Tracks("explore") then
			questXpUntil = Now() + TUNING.questXpWindow
			BookRecentQuestXp()
			CountQuest(ns.GetChar(), ...)
		end
		questPending = false
	elseif event == "QUEST_FINISHED" then
		-- The turn-in dialog has closed. On this client QUEST_FINISHED also
		-- fires when a quest is accepted or its log entry changes, so it is
		-- not evidence of a turn-in on its own: the count moves only while
		-- QUEST_TURNED_IN has not been heard this session, and only after a
		-- dialog opened. Experience is credited on the same terms, so a kill
		-- within a few seconds of accepting a quest is not called quest XP.
		local dialogOpened = questPending
		if dialogOpened and ns.Tracks("explore") then
			questXpUntil = Now() + TUNING.questXpWindow
			BookRecentQuestXp()
			if not ns.questTurnedInSeen then
				CountQuest(ns.GetChar(), nil)
			end
		end
		questPending = false
	elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
		local text = ...
		OnXpMessage(text)
		if ns.NoteInstanceXp then
			ns.NoteInstanceXp(text)
		end
	elseif event == "LOOT_OPENED" then
		if ns.NoteInstanceLoot then
			ns.NoteInstanceLoot()
		end
		if ns.Tracks("economy") then
			ns.moneyContext.lootContextAt = Now()
		end
	elseif event == "CHAT_MSG_MONEY" then
		-- Looted coins arrive as a chat line; the amount comes from the
		-- money poll, so this only marks the loot context window.
		if ns.Tracks("economy") then
			ns.moneyContext.lootContextAt = Now()
		end
	elseif event == "CHAT_MSG_LOOT" then
		local text, looter = ...
		if ns.Tracks("loot") then
			ns.OnLootMessage(text, looter)
		end
		-- A craft is reported on the loot line on clients that do not send
		-- the crafted-item event. Core/90 pairs the two sources.
		if ns.NoteCraftMessage then
			ns.NoteCraftMessage(text)
		end
	elseif event == "CHAT_MSG_SYSTEM" then
		local text = ...
		OnSystemMessage(text)
		if ns.NoteCraftMessage then
			ns.NoteCraftMessage(text)
		end
	elseif event == "TIME_PLAYED_MSG" then
		local totalTime, levelTime = ...
		if ns.Tracks("playtime") then
			OnTimePlayedMsg(totalTime, levelTime)
		end
	elseif event == "PLAYER_LEVEL_UP" then
		local level = ...
		OnLevelUp(level)
	elseif event == "PLAYER_DEAD" then
		local char = ns.GetChar()
		if char and ns.Tracks("combat") then
			local at = Now()
			char.combat.deaths = (char.combat.deaths or 0) + 1
			char.combat.deathsFirstAt = char.combat.deathsFirstAt or at
			char.combat.deathsLastAt = at
			if ns.Touch then
				ns.Touch(char, "combat.deaths", at)
			end
			if ns.NoteDeathMilestone then
				ns.NoteDeathMilestone(char.combat.deaths)
			end
			local zone = ns.CurrentZone() or "Unknown"
			if type(char.combat.deathsByZone) ~= "table" then
				char.combat.deathsByZone = {}
			end
			char.combat.deathsByZone[zone] = (char.combat.deathsByZone[zone] or 0) + 1
			if type(char.combat.deathsByZoneMeta) ~= "table" then
				char.combat.deathsByZoneMeta = {}
			end
			local zoneMeta = char.combat.deathsByZoneMeta[zone]
			if type(zoneMeta) ~= "table" then
				zoneMeta = { firstAt = at }
				char.combat.deathsByZoneMeta[zone] = zoneMeta
			end
			zoneMeta.lastAt = at
			zoneMeta.updatedAt = at
			local death = {
				zone = zone, at = at, level = UnitLevel("player") or char.level,
				how = "death", evidence = "unit_died_event", observed = "live",
			}
			-- The last few deaths are kept, oldest first, so the card can
			-- list more than the most recent one. lastDeath is the newest
			-- entry of the same table: the combat log fills its killer in
			-- later, which updates the log with it.
			char.combat.lastDeath = death
			local log = char.combat.deathLog
			if not log then
				log = {}
				char.combat.deathLog = log
			end
			log[#log + 1] = death
			while #log > TUNING.deathLogCap do
				-- The first death is never dropped: it is the one point the
				-- character cannot regain. The oldest death after it goes
				-- instead, so the log keeps the first plus the most recent.
				table.remove(log, 2)
			end
			local session = char.sessions.current
			if session then
				session.deaths = (session.deaths or 0) + 1
			end
			if ns.OnDataTick then
				ns.OnDataTick()
			end
		end
	elseif ns.IsProfessionEvent and ns.IsProfessionEvent(event) then
		-- Skills, recipe windows and crafts live in the profession domain.
		ns.HandleProfessionEvent(event, ...)
	elseif event == "ZONE_CHANGED_NEW_AREA" then
		ns.explore.UpdateArea()
	elseif event == "ENCOUNTER_END" then
		local encounterName, difficultyID, groupSize, success = select(2, ...)
		if ns.Tracks("explore") then
			ns.OnEncounterEnd(encounterName, success)
		end
	elseif event == "GET_ITEM_INFO_RECEIVED" then
		-- While loot is switched off the entry waits: the item was looted
		-- while the tab was recording, so its value is added when the tab is
		-- switched back on, not dropped.
		ns.ResolvePendingLootFor(...)
	elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
		if ns.Tracks("combat") then
			OnCombatLogEvent(...)
		end
	elseif event == "PLAYER_REGEN_DISABLED" then
		if ns.Tracks("combat") then
			OnCombatStateChanged(true)
		end
	elseif event == "PLAYER_REGEN_ENABLED" then
		if ns.Tracks("combat") then
			OnCombatStateChanged(false)
		end
	end
end

ns.On("ADDON_LOADED", HandleTallyEvent, "Core")

