-- Tally - social: group time, race and class combinations, guild, chat,
-- trades, mail and duels. Everything is counted locally in TallyDB.
--
-- The group half is fed by the one-second ticker (see ns.SocialTick), because
-- "how long was I grouped" and "how long with this class" only exist as time.
-- Chat, mail, trades, duels and friend-list changes are events: each one is
-- registered through the shared registrar, so a failure here disables only
-- this owner and never the recorder.
local addonName, ns = ...

local function Now()
	return (ns.Now and ns.Now()) or time()
end

-- The one subtree this file owns. Created on first use so a character
-- recorded before the Social view existed needs no migration.
local function Ensure(char)
	if not char then
		return nil
	end
	local social = char.social
	if type(social) ~= "table" then
		social = {}
		char.social = social
	end
	if type(social.time) ~= "table" then
		social.time = { solo = 0, party = 0, raid = 0, leader = 0 }
	end
	if type(social.sizes) ~= "table" then
		social.sizes = {}
	end
	if type(social.combos) ~= "table" then
		social.combos = {}
	end
	if type(social.guild) ~= "table" then
		social.guild = { name = nil, seconds = 0, guildless = 0, joins = {}, leaves = {}, history = {} }
	end
	if type(social.guild.joins) ~= "table" then
		social.guild.joins = {}
	end
	if type(social.guild.leaves) ~= "table" then
		social.guild.leaves = {}
	end
	if type(social.guild.history) ~= "table" then
		social.guild.history = {}
	end
	if type(social.guildGroup) ~= "table" then
		social.guildGroup = { mates = 0, strangers = 0 }
	end
	if type(social.chat) ~= "table" then
		social.chat = { sent = 0, say = 0, yell = 0, party = 0, raid = 0,
			guild = 0, whisper = 0, channels = 0, emote = 0, other = 0 }
	end
	if type(social.chat.byGuild) ~= "table" then
		-- Guild and officer chat sent while in each guild, keyed by guild
		-- name. The lifetime guild total stays in social.chat.guild; this is
		-- the per-guild breakdown shown on the Social card.
		social.chat.byGuild = {}
	end
	if type(social.whispers) ~= "table" then
		social.whispers = { sent = 0, received = 0, sentCombos = {}, receivedCombos = {} }
	end
	social.whispers.sentCombos = social.whispers.sentCombos or {}
	social.whispers.receivedCombos = social.whispers.receivedCombos or {}
	-- Whispers used to be added to the chat total as well as their own
	-- counter. Take them back out once, so Messages sent means what it says
	-- on characters recorded by an earlier build.
	if not social.chat.whispersSeparated then
		social.chat.sent = math.max(0, (social.chat.sent or 0) - (social.chat.whisper or 0))
		social.chat.whispersSeparated = true
	end
	-- The friend and ignore lists are account-wide, not character history, so
	-- they are not stored here. Any copy from an earlier build is dropped.
	social.friends = nil
	social.ignores = nil
	if type(social.trades) ~= "table" then
		social.trades = { count = 0, completed = 0, itemsGiven = 0, itemsReceived = 0,
			goldGiven = 0, goldReceived = 0, combos = {} }
	end
	if type(social.trades.combos) ~= "table" then
		social.trades.combos = {}
	end
	social.trades.completed = social.trades.completed or 0
	social.trades.itemsGiven = social.trades.itemsGiven or 0
	social.trades.itemsReceived = social.trades.itemsReceived or 0
	social.trades.goldGiven = social.trades.goldGiven or 0
	social.trades.goldReceived = social.trades.goldReceived or 0
	if type(social.mail) ~= "table" then
		social.mail = { sent = 0, received = 0, packages = 0, cod = 0, visits = 0, seen = {} }
	end
	if type(social.mail.seen) ~= "table" then
		social.mail.seen = {}
	end
	if type(social.duels) ~= "table" then
		social.duels = { challenged = 0, accepted = 0, won = 0, lost = 0, wonCombos = {}, lostCombos = {}, challengedCombos = {} }
	end
	social.duels.wonCombos = social.duels.wonCombos or {}
	social.duels.lostCombos = social.duels.lostCombos or {}
	social.duels.challengedCombos = social.duels.challengedCombos or {}
	-- Outcomes recorded before the win/loss split cannot be named; the owner
	-- asked for them deleted rather than guessed at.
	social.duels.combos = nil
	return social
end

-- "Orc Warrior" - the client's own words, so a custom or localised race needs
-- no list here.
local function UnitCombo(unit)
	if not unit or type(UnitExists) ~= "function" or not UnitExists(unit) then
		return nil
	end
	local race = type(UnitRace) == "function" and UnitRace(unit) or nil
	local class = type(UnitClass) == "function" and UnitClass(unit) or nil
	if not race or not class then
		return nil
	end
	return race.." "..class
end

-- A string from the client can be a secret value on newer clients, where any
-- pattern or comparison throws. Such a value is treated as "unknown" rather
-- than read.
local function SafeString(value)
	if type(value) ~= "string" then
		return nil
	end
	if type(issecretvalue) == "function" and issecretvalue(value) then
		return nil
	end
	return value
end

-- A player name as the client writes it: a chat link, or "Name-Realm". The
-- realm is dropped because the unit tokens below only carry the name.
local function PlayerName(text)
	local value = SafeString(text)
	if not value or value == "" then
		return nil
	end
	local name = string.match(value, "|Hplayer:([^|:]+)") or value
	name = string.match(name, "^%s*([^%-]+)") or name
	if name == "" then
		return nil
	end
	return name
end

-- The client can only answer for units it can see: the player, the current
-- target and anyone in the group. A player met in the open world therefore
-- stays unknown rather than being guessed at, which is why the caller treats
-- a nil combo as "no entry" instead of inventing one.
local function UnitByName(name)
	local wanted = PlayerName(name)
	if not wanted then
		return nil
	end
	local wantedLower = string.lower(wanted)
	local units = { "player", "target", "focus", "mouseover" }
	for index = 1, (MAX_PARTY_MEMBERS or 4) do
		units[#units + 1] = "party"..index
	end
	for index = 1, (MAX_RAID_MEMBERS or 40) do
		units[#units + 1] = "raid"..index
	end
	for index = 1, #units do
		local unit = units[index]
		if UnitExists and UnitExists(unit) then
			local unitName = UnitName(unit)
			local short = PlayerName(unitName)
			if short and string.lower(short) == wantedLower then
				return unit
			end
		end
	end
	return nil
end

-- A name-to-"Race Class" memo for this character, filled whenever the client
-- does answer for a player (target, group, trade, duel). A whisper or trade
-- afterwards can then still be attributed after the player is out of sight.
-- It is a lookup table for the interaction counters, capped and with no
-- per-player figures, not a player history.
local KNOWN_PLAYERS_CAP = 250

local function RememberName(name, combo)
	local player = PlayerName(name)
	if not player or not combo then
		return
	end
	local key = string.lower(player)
	local social = Ensure(ns.GetChar())
	if not social then
		return
	end
	local known = social.known
	if type(known) ~= "table" then
		known = {}
		social.known = known
		social.knownOrder = {}
	end
	if not known[key] then
		local order = social.knownOrder
		if type(order) ~= "table" then
			order = {}
			social.knownOrder = order
		end
		order[#order + 1] = key
		while #order > KNOWN_PLAYERS_CAP do
			local old = table.remove(order, 1)
			known[old] = nil
		end
	end
	known[key] = combo
end

local function KnownCombo(name)
	local social = Ensure(ns.GetChar())
	local player = PlayerName(name)
	if not social or not player or type(social.known) ~= "table" then
		return nil
	end
	return social.known[string.lower(player)]
end

-- A chat line carries the speaker's GUID on this client, and the client can
-- answer race and class from a GUID even for players the unit API does not
-- expose. That is what makes a whisper from a stranger classifiable.
local function ComboForGUID(guid)
	local value = SafeString(guid)
	if not value or type(GetPlayerInfoByGUID) ~= "function" then
		return nil
	end
	if not string.match(value, "^Player%-%d+%-%x+$") then
		return nil
	end
	local ok, class, _, race = pcall(GetPlayerInfoByGUID, value)
	if not ok or not race or not class then
		return nil
	end
	return race.." "..class
end

local function GUIDIn(...)
	for index = 1, select("#", ...) do
		local value = SafeString(select(index, ...))
		if value and string.match(value, "^Player%-%d+%-%x+$") then
			return value
		end
	end
	return nil
end

local function RememberUnit(unit)
	if type(UnitExists) ~= "function" or not UnitExists(unit) then
		return
	end
	local combo = UnitCombo(unit)
	if combo then
		RememberName(UnitName(unit), combo)
	end
end

-- "Human Mage" for a name the client can still resolve, then for one it was
-- seen before, or nil.
local function ComboForName(name)
	local key = PlayerName(name)
	if not key then
		return nil
	end
	local unit = UnitByName(key)
	if unit then
		local combo = UnitCombo(unit)
		if combo then
			RememberName(key, combo)
			return combo
		end
	end
	return KnownCombo(key)
end

-- The trade frame names the partner in its own font string; the target is
-- only a fallback, since a trade can be opened with /trade name without
-- targeting anyone.
local function TradePartnerName()
	local field = _G.TradeFrameRecipientNameText
	if field and type(field.GetText) == "function" then
		local ok, text = pcall(field.GetText, field)
		if ok and type(text) == "string" and text ~= "" then
			return text
		end
	end
	if UnitExists and UnitExists("target") then
		return UnitName("target")
	end
	return nil
end

-- The counters are stored in two shapes: a plain number for interactions
-- that only need a count (trades, whispers, duels), and { seconds,
-- encounters } for the group combos that also carry time. This one entry
-- point keeps both working, and repairs a number left by an older build.
local function AddCombo(bucket, combo)
	if not combo then
		return
	end
	local value = bucket[combo]
	if type(value) == "table" then
		value.encounters = (value.encounters or 0) + 1
	else
		bucket[combo] = (tonumber(value) or 0) + 1
	end
end

local function AddComboSeconds(bucket, combo)
	if not combo then
		return
	end
	local entry = bucket[combo]
	if type(entry) ~= "table" then
		-- A number from an older build (or a damaged record) becomes the
		-- seconds bucket it is now, instead of being indexed as a table.
		entry = { seconds = tonumber(entry) or 0, encounters = 0 }
		bucket[combo] = entry
	end
	entry.seconds = (entry.seconds or 0) + 1
end

-- ---------------------------------------------------------------------------
-- Group time and the members in it
-- ---------------------------------------------------------------------------

-- The combo each party/raid unit held on the previous tick, so a member
-- arriving (or a unit slot changing hands) counts as one encounter. The
-- fingerprint lives across a logout in char.presence, because the group does:
-- logging back in must not make every member a new encounter.
local lastUnits = {}
local unitsRestoreUntil = 0

local function GuildName(unit)
	if type(GetGuildInfo) ~= "function" then
		return nil
	end
	local ok, name = pcall(GetGuildInfo, unit)
	if ok then
		return name
	end
	return nil
end

local function IsLeader()
	if type(UnitIsGroupLeader) == "function" then
		local ok, leader = pcall(UnitIsGroupLeader, "player")
		if ok then
			return leader and true or false
		end
	end
	if type(IsRaidLeader) == "function" and IsRaidLeader() then
		return true
	end
	if type(IsPartyLeader) == "function" and IsPartyLeader() then
		return true
	end
	return false
end

local MAX_GUILD_HISTORY = 20

local function UpdateGuild(char, social, now)
	local name = GuildName("player")
	local guild = social.guild
	local history = guild.history or {}
	guild.history = history

	local function CloseHistory(oldName)
		for index = #history, 1, -1 do
			local entry = history[index]
			if entry.name == oldName and entry.leftAt == nil then
				entry.leftAt = now
				return
			end
		end
	end

	-- The first observation only sets the baseline: a character who was
	-- already guilded when Tally met it did not join today. The history entry
	-- is marked so the UI can say the join date is unknown rather than invent
	-- one.
	if not guild.initialized then
		guild.name = name
		guild.initialized = true
		if name then
			history[#history + 1] = { name = name, joinedAt = now, baseline = true }
		end
		return
	end
	if name == guild.name then
		return
	end
	if guild.name then
		guild.leaves[#guild.leaves + 1] = { at = now, name = guild.name }
		if #guild.leaves > MAX_GUILD_HISTORY then
			table.remove(guild.leaves, 1)
		end
		CloseHistory(guild.name)
	end
	if name then
		guild.joins[#guild.joins + 1] = { at = now, name = name }
		if #guild.joins > MAX_GUILD_HISTORY then
			table.remove(guild.joins, 1)
		end
		history[#history + 1] = { name = name, joinedAt = now }
		while #history > MAX_GUILD_HISTORY do
			table.remove(history, 1)
		end
	end
	guild.name = name
end

function ns.SocialTick(char, now)
	if not char then
		return
	end
	local social = Ensure(char)
	if not social then
		return
	end
	now = now or Now()
	local inRaid = type(IsInRaid) == "function" and IsInRaid() and true or false
	local inGroup = inRaid or (type(IsInGroup) == "function" and IsInGroup() and true or false)
	local size = 1
	if inGroup and type(GetNumGroupMembers) == "function" then
		size = GetNumGroupMembers() or 1
	end

	if inRaid then
		social.time.raid = social.time.raid + 1
	elseif inGroup then
		social.time.party = social.time.party + 1
	else
		social.time.solo = social.time.solo + 1
	end

	if inGroup then
		if IsLeader() then
			social.time.leader = social.time.leader + 1
		end
		local sizeKey = tostring(size)
		social.sizes[sizeKey] = (social.sizes[sizeKey] or 0) + 1

		-- One second for every member present, and one encounter when a unit
		-- slot first shows that combo.
		local playerGuild = GuildName("player")
		local sawMate, sawStranger = false, false
		local fingerprint = {}
		local function Consider(unit)
			if type(UnitExists) ~= "function" or not UnitExists(unit) then
				return
			end
			local combo = UnitCombo(unit)
			if not combo then
				return
			end
			RememberName(UnitName(unit), combo)
			AddComboSeconds(social.combos, combo)
			if lastUnits[unit] ~= combo then
				-- A restored roster is trusted while the client settles: a
				-- slot that answers late must not count as a new encounter.
				if now >= unitsRestoreUntil then
					AddCombo(social.combos, combo)
				end
			end
			fingerprint[unit] = combo

			local memberGuild = GuildName(unit)
			if playerGuild and memberGuild == playerGuild then
				sawMate = true
			else
				sawStranger = true
			end
		end
		if inRaid then
			for index = 1, size do
				Consider("raid"..index)
			end
		else
			for index = 1, 4 do
				Consider("party"..index)
			end
		end
		lastUnits = fingerprint
		if sawMate then
			social.guildGroup.mates = social.guildGroup.mates + 1
		end
		if sawStranger then
			social.guildGroup.strangers = social.guildGroup.strangers + 1
		end
	else
		-- A restored roster is kept for a moment: the group can load a tick
		-- or two after the character does.
		if now >= unitsRestoreUntil then
			lastUnits = {}
		end
	end

	UpdateGuild(char, social, now)
	if social.guild.name then
		social.guild.seconds = social.guild.seconds + 1
	else
		social.guild.guildless = social.guild.guildless + 1
	end
end

-- ---------------------------------------------------------------------------
-- Chat and whispers
-- ---------------------------------------------------------------------------

-- The client does not echo the player's own chat back as events, so the send
-- path is the only place to count it. One count per call, and the channel it
-- was aimed at decides the bucket.
local CHAT_BUCKET = {
	SAY = "say", YELL = "yell", PARTY = "party", RAID = "raid",
	GUILD = "guild", OFFICER = "guild", INSTANCE_CHAT = "party",
	WHISPER = "whisper", BN_WHISPER = "whisper",
	CHANNEL = "channels", EMOTE = "emote",
}

local function CountSentChat(chatType, targetName)
	local char = ns.GetChar()
	local social = Ensure(char)
	if not social then
		return
	end
	local bucket = CHAT_BUCKET[chatType or "SAY"] or "other"
	social.chat[bucket] = (social.chat[bucket] or 0) + 1
	if bucket == "guild" then
		-- Guild chat and officer chat both count for the guild the character
		-- is in when the message is sent.
		local guildName = GuildName("player")
		if guildName then
			social.chat.byGuild[guildName] = (tonumber(social.chat.byGuild[guildName]) or 0) + 1
		end
	end
	if bucket == "whisper" then
		-- Whispers have their own counters; counting them in the chat total
		-- too would show the same message twice, once in Messages sent and
		-- once in Whispers sent.
		social.whispers.sent = social.whispers.sent + 1
		local combo = ComboForName(targetName)
		if combo then
			RememberName(targetName, combo)
		end
		ns.Trace("whisper sent to "..tostring(SafeString(targetName) or "?").."; combo="..tostring(combo))
		AddCombo(social.whispers.sentCombos, combo)
		return
	end
	social.chat.sent = social.chat.sent + 1
end

local lastSendAt = 0
local hookedSend

local function ChatNow()
	return (GetTime and GetTime()) or 0
end

-- The send hook can go quiet if the client's chat frame took a local
-- reference to SendChatMessage before addons loaded, or something replaced
-- the global after us. Re-hooking compares the function object; HookEditText
-- below is the fallback for the local-reference case.
local function HookSend()
	if type(SendChatMessage) ~= "function" or SendChatMessage == hookedSend then
		return
	end
	if type(hooksecurefunc) ~= "function" then
		return
	end
	local ok = pcall(hooksecurefunc, "SendChatMessage", function(_, chatType, _, target)
		local now = ChatNow()
		if now - lastSendAt < 0.5 then
			return
		end
		lastSendAt = now
		CountSentChat(chatType, target)
	end)
	if ok then
		hookedSend = SendChatMessage
		ns.socialSendHooked = true
	end
end

local CHAT_COMMAND_TYPES = {
	s = "SAY", say = "SAY", y = "YELL", yell = "YELL",
	p = "PARTY", party = "PARTY", i = "INSTANCE_CHAT", instance = "INSTANCE_CHAT",
	ra = "RAID", raid = "RAID", g = "GUILD", guild = "GUILD",
	o = "OFFICER", officer = "OFFICER", w = "WHISPER", whisper = "WHISPER",
	r = "WHISPER", reply = "WHISPER", c = "CHANNEL", csay = "CHANNEL",
}

-- The chat type lives in the edit box's "chatType" attribute on this client,
-- not in a plain field; reading only the field made every message look like
-- Say. The attribute is the client's own answer for yell, party, whisper and
-- the rest.
local function EditBoxChatType(box)
	if not box then
		return "SAY"
	end
	if type(box.GetAttribute) == "function" then
		local ok, value = pcall(box.GetAttribute, box, "chatType")
		if ok and type(value) == "string" and value ~= "" then
			return value
		end
	end
	return box.chatType or "SAY"
end

local function ChatCommandType(text)
	local command = string.match(text or "", "^/(%S+)")
	if not command then
		return nil
	end
	local lower = string.lower(command)
	if CHAT_COMMAND_TYPES[lower] then
		return CHAT_COMMAND_TYPES[lower]
	end
	if string.match(lower, "^%d+$") then
		return "CHANNEL"
	end
	return false
end

-- The whisper target lives in the edit box's "tellTarget" attribute on this
-- client. It is what /r and the reply arrow fill in.
local function EditBoxChatTarget(box)
	if not box then
		return nil
	end
	if type(box.GetAttribute) == "function" then
		local ok, value = pcall(box.GetAttribute, box, "tellTarget")
		if ok and type(value) == "string" and value ~= "" then
			return value
		end
	end
	return box.tellTarget
end

-- /r and /reply do not write the name into the edit box, so the client's own
-- "last person who whispered me" answer is the fallback.
local function LastTellTarget()
	if type(ChatEdit_GetLastTellTarget) ~= "function" then
		return nil
	end
	local ok, value = pcall(ChatEdit_GetLastTellTarget)
	if ok and type(value) == "string" and value ~= "" then
		return value
	end
	return nil
end

local function WhisperTarget(box, name)
	return name or EditBoxChatTarget(box) or LastTellTarget()
end

-- "/w Name text" and "/whisper Name text" name the target themselves; /r and
-- /reply take it from the edit box, which the caller falls back to.
local function ChatCommandTarget(text)
	local command, rest = string.match(text or "", "^/(%S+)%s*(.*)$")
	if not command then
		return nil
	end
	local lower = string.lower(command)
	if lower == "w" or lower == "whisper" or lower == "t" or lower == "tell" then
		return string.match(rest or "", "^(%S+)")
	end
	return nil
end

-- The chat edit box's OnEnterPressed script is deliberately left alone.
-- Replacing it taints the edit box, and a tainted chat box blocks protected
-- guild actions such as /invite. Hooking SendChatMessage and ChatEdit_SendText
-- is secure and covers the send path without touching the frame.
-- Last resort for clients where SendChatMessage itself is unreachable.
local function HookEditText()
	if type(ChatEdit_SendText) ~= "function" or type(hooksecurefunc) ~= "function" then
		return
	end
	local ok = pcall(hooksecurefunc, "ChatEdit_SendText", function(editBox)
		local now = ChatNow()
		if now - lastSendAt < 0.5 then
			return
		end
		local text = editBox and editBox:GetText() or ""
		if text == "" then
			return
		end
		if string.sub(text, 1, 1) == "/" then
			local chatType = ChatCommandType(text)
			if not chatType then
				return
			end
			lastSendAt = now
			CountSentChat(chatType, WhisperTarget(editBox, ChatCommandTarget(text)))
			return
		end
		lastSendAt = now
		local chatType = EditBoxChatType(editBox)
		CountSentChat(chatType, chatType == "WHISPER" and WhisperTarget(editBox) or nil)
	end)
	if ok then
		ns.socialEditHooked = true
	end
end

HookSend()
HookEditText()
-- Emotes typed with a slash go through DoEmote, not SendChatMessage.
if type(DoEmote) == "function" and type(hooksecurefunc) == "function" then
	pcall(hooksecurefunc, "DoEmote", function()
		local char = ns.GetChar()
		local social = Ensure(char)
		if social then
			social.chat.sent = social.chat.sent + 1
			social.chat.emote = social.chat.emote + 1
		end
	end)
end

local function OnWhisperReceived(event, text, author, ...)
	local social = Ensure(ns.GetChar())
	if not social then
		return
	end
	social.whispers.received = social.whispers.received + 1
	local combo = ComboForGUID(GUIDIn(...)) or ComboForName(author)
	if combo then
		RememberName(author, combo)
	end
	ns.Trace("whisper received from "..tostring(SafeString(author) or "?").."; combo="..tostring(combo))
	AddCombo(social.whispers.receivedCombos, combo)
end

-- ---------------------------------------------------------------------------
-- Trades
-- ---------------------------------------------------------------------------

local tradeCounted = false
local tradeOpen = false
local tradePlayerAccepted = false
local tradeTargetAccepted = false
local tradeMoneyGiven = 0
local tradeMoneyReceived = 0
local tradePending
local lastTradeCombo
-- A client with the completion string sends it on every successful trade, so
-- the close is not needed to confirm one. A client without it falls back to
-- the close, where the inventory-refusal case cannot be told apart.
local tradeCompleteWorks = _G.ERR_TRADE_COMPLETE ~= nil

-- The client exposes both sides of the trade window's money directly, so the
-- gross amounts do not have to be inferred from a balance change. Classic Era
-- has the same two globals the default trade frame uses.
local function ReadTradeMoney()
	local given, received = 0, 0
	if type(GetPlayerTradeMoney) == "function" then
		local ok, amount = pcall(GetPlayerTradeMoney)
		if ok and type(amount) == "number" then
			given = amount
		end
	end
	if type(GetTargetTradeMoney) == "function" then
		local ok, amount = pcall(GetTargetTradeMoney)
		if ok and type(amount) == "number" then
			received = amount
		end
	end
	return given, received
end

local function OnTradeMoney()
	tradeMoneyGiven, tradeMoneyReceived = ReadTradeMoney()
end

local function OnTradeShow()
	tradeCounted = false
	tradeOpen = true
	tradePending = nil
	tradePlayerAccepted = false
	tradeTargetAccepted = false
	tradeMoneyGiven, tradeMoneyReceived = ReadTradeMoney()
	local partner = TradePartnerName()
	local combo
	if partner then
		-- A named partner is not attributed to whatever the player happens to
		-- have targeted; only an unnamed trade falls back to the target.
		combo = ComboForName(partner)
	else
		combo = UnitCombo("target")
	end
	lastTradeCombo = combo
	local social = Ensure(ns.GetChar())
	if not social then
		return
	end
	social.trades.count = social.trades.count + 1
	ns.Trace("trade opened; partner="..tostring(partner)..", combo="..tostring(lastTradeCombo))
end

-- Units on one side of the open trade. The slot info returns the stack size
-- as its third value, so a stack of twenty counts as twenty items. Slot 7 is
-- the "will not be traded" enchant slot and is not an item exchanged.
local TRADE_ITEM_SLOTS = 6

local function TradeSideItems(getter)
	local total = 0
	if type(getter) ~= "function" then
		return total
	end
	for slot = 1, TRADE_ITEM_SLOTS do
		local ok, name, _, count = pcall(getter, slot)
		if ok and name then
			total = total + (tonumber(count) or 1)
		end
	end
	return total
end

-- Everything a completed trade needs, read while the window still holds the
-- offers. The server can refuse the exchange (either side's bags full), in
-- which case no completion line is sent and nothing must be counted.
local function TradeSnapshot()
	local getPlayer = GetTradePlayerItemInfo or (C_TradeInfo and C_TradeInfo.GetTradePlayerItemInfo)
	local getTarget = GetTradeTargetItemInfo or (C_TradeInfo and C_TradeInfo.GetTradeTargetItemInfo)
	local freshGiven, freshReceived = ReadTradeMoney()
	local combo = lastTradeCombo
	if not combo then
		local partner = TradePartnerName()
		if partner then
			combo = ComboForName(partner)
		else
			combo = UnitCombo("target")
		end
	end
	return {
		itemsGiven = TradeSideItems(getPlayer),
		itemsReceived = TradeSideItems(getTarget),
		goldGiven = freshGiven > 0 and freshGiven or tradeMoneyGiven,
		goldReceived = freshReceived > 0 and freshReceived or tradeMoneyReceived,
		combo = combo,
		at = Now(),
	}
end

local function CountCompletedTrade(snapshot)
	if tradeCounted then
		return
	end
	local social = Ensure(ns.GetChar())
	if not social then
		return
	end
	snapshot = snapshot or TradeSnapshot()
	tradeCounted = true
	social.trades.completed = social.trades.completed + 1
	local given = snapshot.itemsGiven or 0
	local received = snapshot.itemsReceived or 0
	social.trades.itemsGiven = social.trades.itemsGiven + given
	social.trades.itemsReceived = social.trades.itemsReceived + received
	local goldGiven = snapshot.goldGiven or 0
	local goldReceived = snapshot.goldReceived or 0
	social.trades.goldGiven = (social.trades.goldGiven or 0) + goldGiven
	social.trades.goldReceived = (social.trades.goldReceived or 0) + goldReceived
	-- The money system books the net change when the purse updates a moment
	-- later, and it is handed the two gross sides so trade income and trade
	-- expense stay separate. Equal sides cancel out and produce no purse
	-- change at all, so that pair is booked here instead.
	if goldGiven > 0 and goldReceived > 0 and goldGiven == goldReceived then
		if ns.BookTradeGold then
			ns.BookTradeGold(goldGiven, goldReceived)
		end
	else
		ns.lastTradeGold = { given = goldGiven, received = goldReceived, at = Now() }
	end
	AddCombo(social.trades.combos, snapshot.combo)
	ns.Trace("trade completed; items given="..given..", received="..received
		..", gold given="..tostring(goldGiven)..", received="..tostring(goldReceived)
		..", combo="..tostring(snapshot.combo))
end

local function OnTradeAccept(event, playerAccepted, targetAccepted)
	-- The payload is the current state of both sides, not a latch: a side
	-- that withdraws its acceptance reports 0 and must clear the flag.
	tradePlayerAccepted = tonumber(playerAccepted) == 1
	tradeTargetAccepted = tonumber(targetAccepted) == 1
	ns.Trace("trade accept: player="..tostring(playerAccepted)..", target="..tostring(targetAccepted))
	-- Snapshot while the slots still hold the offers. The trade is counted
	-- only once the server confirms it; both sides accepting is not proof,
	-- because the server refuses a trade that neither inventory can hold.
	if tradePlayerAccepted and tradeTargetAccepted then
		if not tradePending then
			tradePending = TradeSnapshot()
		end
	else
		-- A changed offer withdraws acceptance; the next acceptance takes a
		-- fresh snapshot of what is actually on the table.
		tradePending = nil
	end
end

local function OnTradeClosed()
	if not tradeCounted and tradePending and not tradeCompleteWorks then
		-- The client has no completion line: closing is the only signal.
		CountCompletedTrade(tradePending)
		tradePending = nil
	end
	-- When the line is expected, a pending snapshot is kept until the next
	-- trade opens: the line can arrive just after the close. A refused trade
	-- simply never gets one, so it stays uncounted. tradeCounted stays set
	-- until the next trade so a repeated line cannot double count.
	tradeOpen = false
	tradePlayerAccepted = false
	tradeTargetAccepted = false
	tradeMoneyGiven = 0
	tradeMoneyReceived = 0
	lastTradeCombo = nil
end

-- The client prints "Trade complete." only when the exchange actually
-- happened. That is the authoritative signal, and it covers both directions:
-- a full inventory on either side means no line and no count.
local function OnTradeMessage(event, text)
	if tradeCounted then
		return
	end
	local secret = SafeString(text)
	if not secret then
		return
	end
	local complete = _G.ERR_TRADE_COMPLETE
	if complete and secret == complete then
		tradeCompleteWorks = true
		if tradePending or tradeOpen then
			CountCompletedTrade(tradePending)
			tradePending = nil
		end
	end
end

-- ---------------------------------------------------------------------------
-- Mail
-- ---------------------------------------------------------------------------

local MAIL_SEEN_CAP = 250

local function InboxCount()
	local getter = (C_Mail and C_Mail.GetInboxNumItems) or GetInboxNumItems
	if type(getter) ~= "function" then
		return nil
	end
	local ok, count = pcall(getter)
	if ok and type(count) == "number" then
		return count
	end
	return nil
end

local function InboxHeader(index)
	local getter = (C_Mail and C_Mail.GetInboxHeaderInfo) or GetInboxHeaderInfo
	if type(getter) ~= "function" then
		return nil
	end
	local ok, a, b, sender, subject, money, cod, daysLeft, hasItem = pcall(getter, index)
	if not ok then
		return nil
	end
	return sender, subject, money, cod, hasItem, daysLeft
end

-- The first inbox a character ever shows is seeded: those letters arrived
-- before Tally could see them, so counting them would invent activity. From
-- then on, a letter kind is identified by sender and subject, with a count,
-- because money, COD and attachments change when a letter is emptied - a
-- signature that included them counted the same letter twice.
local function ScanInbox()
	local social = Ensure(ns.GetChar())
	if not social then
		return
	end
	local mail = social.mail
	local count = InboxCount()
	if not count or count <= 0 then
		-- An empty or not-yet-loaded inbox is not a seed: seeding here made
		-- every letter appear new when the headers arrived a moment later.
		-- Two zero scans in a row (the mailbox really is empty) do clear the
		-- remembered letters, so a later one of the same kind counts again.
		if mail.seeded then
			mail.zeroScans = (mail.zeroScans or 0) + 1
			if mail.zeroScans >= 2 then
				mail.seen = {}
				mail.seenOrder = {}
			end
		end
		return
	end
	mail.zeroScans = 0
	local seen = mail.seen
	if type(seen) ~= "table" then
		seen = {}
		mail.seen = seen
	end
	local seenOrder = mail.seenOrder
	if type(seenOrder) ~= "table" then
		seenOrder = {}
		mail.seenOrder = seenOrder
	end

	local counts, order, samples = {}, {}, {}
	for index = 1, count do
		local sender, subject, money, cod, hasItem = InboxHeader(index)
		if sender then
			local key = tostring(sender).."|"..tostring(subject or "")
			if not counts[key] then
				counts[key] = 0
				order[#order + 1] = key
				samples[key] = { hasItem = hasItem and true or false, cod = tonumber(cod) or 0 }
			end
			counts[key] = counts[key] + 1
		end
	end

	-- A record from an earlier signature scheme (or a character seen for the
	-- first time) is seeded silently, so the upgrade cannot invent mail.
	if not mail.seeded or mail.seenFormat ~= 2 then
		mail.seen = counts
		mail.seenOrder = order
		mail.seeded = true
		mail.seenFormat = 2
		return
	end

	for index = 1, #order do
		local key = order[index]
		local previous = seen[key]
		if previous == true then
			previous = 1
		else
			previous = tonumber(previous) or 0
		end
		local fresh = (counts[key] or 0) - previous
		if fresh > 0 then
			mail.received = mail.received + fresh
			local sample = samples[key]
			if sample and sample.hasItem then
				mail.packages = mail.packages + fresh
			end
			if sample and sample.cod > 0 then
				mail.cod = mail.cod + fresh
			end
		end
	end

	-- Keys still in the box keep their place; keys that left go first when
	-- the cap is trimmed. A live key is never dropped, or its letters would
	-- be counted again on the next scan.
	local kept, inKept = {}, {}
	for index = 1, #seenOrder do
		local key = seenOrder[index]
		if counts[key] and not inKept[key] then
			kept[#kept + 1] = key
			inKept[key] = true
		end
	end
	for index = 1, #order do
		local key = order[index]
		if not inKept[key] then
			kept[#kept + 1] = key
			inKept[key] = true
		end
	end
	while #kept > MAIL_SEEN_CAP do
		local removed = false
		for index = 1, #kept do
			if not counts[kept[index]] then
				table.remove(kept, index)
				removed = true
				break
			end
		end
		if not removed then
			break
		end
	end
	mail.seen = counts
	mail.seenOrder = kept
end

local function OnMailShow()
	local social = Ensure(ns.GetChar())
	if social then
		social.mail.visits = social.mail.visits + 1
	end
	ScanInbox()
end

local function OnMailSent()
	local social = Ensure(ns.GetChar())
	if social then
		social.mail.sent = social.mail.sent + 1
	end
end

-- ---------------------------------------------------------------------------
-- Duels
-- ---------------------------------------------------------------------------

local lastDuelCombo
local lastDuelName
local lastDuelAt
local lastDuelText
local lastDuelTextAt
local duelFinishedAt
-- A duel only has an outcome once it actually started. Some clients raise
-- DUEL_FINISHED for a request that was declined, with no result to read; that
-- is not a loss and must not reach the counters.
local duelStarted = false

local function SameName(a, b)
	if not a or not b then
		return false
	end
	local left = PlayerName(a)
	local right = PlayerName(b)
	return left ~= nil and right ~= nil and string.lower(left) == string.lower(right)
end

local function EscapePattern(text)
	return (string.gsub(text, "([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- The client's own winner strings, turned into Lua patterns. Both the plain
-- "%s" and the positional "%1$s" forms appear across clients, and each name
-- becomes one capture. The literal between the two names is returned as
-- well: it survives punctuation or colour the format does not carry, which
-- is what the fallback below matches on.
local function DuelPattern(format)
	if type(format) ~= "string" or format == "" then
		return nil
	end
	local parts, index, middle = {}, 1, nil
	local seenPlaceholder = false
	while true do
		local startPos, endPos = string.find(format, "%%%d?%$?s", index)
		if not startPos then
			break
		end
		local literal = string.sub(format, index, startPos - 1)
		parts[#parts + 1] = EscapePattern(literal)
		parts[#parts + 1] = "(.+)"
		if seenPlaceholder then
			middle = literal
		end
		seenPlaceholder = true
		index = endPos + 1
	end
	local suffix = string.sub(format, index)
	parts[#parts + 1] = EscapePattern(suffix)
	return "^"..table.concat(parts).."$", middle, suffix
end

-- Knockout names the winner first; retreat names the player who fled first,
-- which makes that player the loser.
local DUEL_MESSAGES = {}
for _, spec in ipairs({
	{ format = _G.DUEL_WINNER_KNOCKOUT, firstWins = true },
	{ format = _G.DUEL_WINNER_RETREAT, firstWins = false },
}) do
	local pattern, middle, suffix = DuelPattern(spec.format)
	if pattern then
		DUEL_MESSAGES[#DUEL_MESSAGES + 1] = {
			pattern = pattern, middle = middle, suffix = suffix, firstWins = spec.firstWins,
		}
	end
end

-- System text with colour codes removed and player links flattened to the
-- name they display. The duel announcement is plain on some clients and a
-- link or a coloured line on others.
local function PlainText(text)
	local value = SafeString(text)
	if not value then
		return ""
	end
	local plain = string.gsub(value, "|c%x%x%x%x%x%x%x%x", "")
	plain = string.gsub(plain, "|r", "")
	plain = string.gsub(plain, "|Hplayer:[^|]-|h%[([^%]]*)%]|h", "%1")
	return plain
end

local function FindNamePos(text, name)
	local short = PlayerName(name)
	if not short or short == "" then
		return nil
	end
	return string.find(string.lower(text), string.lower(short), 1, true)
end

-- The client's own middle wording, plus which side of it the opponent's name
-- sits on. The local player may be written as a name or as "you", but the
-- opponent is always named, so their side is enough to read the result.
local function DuelFromPositions(plain, opponent)
	if not opponent then
		return nil
	end
	local opponentAt = FindNamePos(plain, opponent)
	if not opponentAt then
		return nil
	end
	for index = 1, #DUEL_MESSAGES do
		local spec = DUEL_MESSAGES[index]
		if spec.middle and spec.middle ~= "" then
			local middleAt = string.find(plain, spec.middle, 1, true)
			-- The tail of the client's sentence ("in a duel") keeps this from
			-- catching an unrelated "... has defeated ..." notice.
			local suffixOk = not spec.suffix or spec.suffix == ""
				or string.find(plain, spec.suffix, 1, true) ~= nil
			if middleAt and suffixOk then
				local opponentFirst = opponentAt < middleAt
				local won
				if spec.firstWins then
					-- Knockout: the first name won, so the opponent first
					-- means this character lost.
					won = not opponentFirst
				else
					-- Retreat: the first name fled, so the opponent first
					-- means this character won.
					won = opponentFirst
				end
				return won and true or false, opponent
			end
		end
	end
	return nil
end

-- One place for an outcome, whichever channel reported it: the finish event
-- and the chat announcement can both arrive for the same duel, so the first
-- one wins and the other is dropped.
local function RecordDuelOutcome(won, opponent)
	local social = Ensure(ns.GetChar())
	if not social then
		return
	end
	local now = Now()
	if lastDuelAt and now - lastDuelAt < 10 then
		return
	end
	lastDuelAt = now
	if not duelStarted then
		-- This client raises no countdown event; an outcome proves the duel
		-- was accepted and fought.
		social.duels.accepted = social.duels.accepted + 1
	end
	duelStarted = false
	local combo = ComboForName(opponent) or lastDuelCombo
	if not combo and not opponent then
		combo = UnitCombo("target")
	end
	if combo and opponent then
		RememberName(opponent, combo)
	end
	if won then
		social.duels.won = social.duels.won + 1
		AddCombo(social.duels.wonCombos, combo)
	else
		social.duels.lost = social.duels.lost + 1
		AddCombo(social.duels.lostCombos, combo)
	end
	ns.Trace("duel result: "..(won and "won" or "lost").." vs "..tostring(opponent).."; combo="..tostring(combo))
	lastDuelCombo = nil
	lastDuelName = nil
	lastDuelText = nil
	duelFinishedAt = nil
end

local function OnDuelRequested(event, challenger)
	-- The challenger's name comes with the event; the target is only a
	-- fallback for the combo.
	duelStarted = false
	lastDuelName = PlayerName(challenger) or UnitName("target")
	lastDuelCombo = ComboForName(lastDuelName) or UnitCombo("target")
	RememberName(lastDuelName, lastDuelCombo)
	ns.Trace("duel requested by "..tostring(lastDuelName).."; combo="..tostring(lastDuelCombo))
end

local function OnDuelCountdown()
	duelStarted = true
	lastDuelCombo = lastDuelCombo or UnitCombo("target")
	ns.Trace("duel countdown; combo="..tostring(lastDuelCombo))
	local social = Ensure(ns.GetChar())
	if social then
		social.duels.accepted = social.duels.accepted + 1
	end
end

local function OnDuelFinished()
	duelFinishedAt = Now()
	local result = type(GetDuelResult) == "function" and GetDuelResult() or nil
	ns.Trace("duel finished: result="..tostring(result)..", started="..tostring(duelStarted)
		..", combo="..tostring(lastDuelCombo or UnitCombo("target")))
	if result ~= nil then
		RecordDuelOutcome(result == 1 or result == true, lastDuelName)
		return
	end
	-- Some clients cannot report the result here at all. If the chat
	-- announcement arrived before the event, read it now that a finish is
	-- known to have happened.
	if lastDuelText and lastDuelTextAt and Now() - lastDuelTextAt <= 10 then
		local won, opponent = DuelFromPositions(lastDuelText, lastDuelName)
		if won ~= nil then
			RecordDuelOutcome(won, opponent)
		end
	end
end

-- "X has defeated Y in a duel." / "X has fled from Y in a duel." Both are
-- system chat messages, and the local player has to be one of the two names:
-- anything else is somebody else's duel and is ignored.
local function OnDuelMessage(event, text)
	if #DUEL_MESSAGES == 0 then
		return
	end
	local safe = SafeString(text)
	if not safe then
		return
	end
	local plain = PlainText(safe)
	local player = UnitName("player")
	if player then
		for index = 1, #DUEL_MESSAGES do
			local spec = DUEL_MESSAGES[index]
			local first, second = string.match(plain, spec.pattern)
			if first then
				local localFirst = SameName(first, player)
				local localSecond = SameName(second, player)
				if localFirst or localSecond then
					local won = spec.firstWins and localFirst or (localSecond and not localFirst)
					local opponent = localFirst and second or first
					RecordDuelOutcome(won and true or false, opponent)
				end
				return
			end
		end
	end
	-- Keep an unmatched line: the finish event may arrive after it, and the
	-- wording may be readable by position rather than by the exact sentence.
	local recentFinish = duelFinishedAt and Now() - duelFinishedAt <= 10
	if lastDuelName or lastDuelCombo or recentFinish then
		lastDuelText = plain
		lastDuelTextAt = Now()
		if recentFinish then
			local won, opponent = DuelFromPositions(plain, lastDuelName)
			if won ~= nil then
				RecordDuelOutcome(won, opponent)
				return
			end
		end
		ns.Trace("system message during a duel: "..tostring(safe))
	end
end

if type(StartDuel) == "function" and type(hooksecurefunc) == "function" then
	pcall(hooksecurefunc, "StartDuel", function(unit)
		lastDuelName = UnitName(unit or "target")
		lastDuelText = nil
		duelFinishedAt = nil
		duelStarted = false
		local social = Ensure(ns.GetChar())
		if social then
			social.duels.challenged = social.duels.challenged + 1
			lastDuelCombo = ComboForName(lastDuelName) or UnitCombo(unit or "target")
			RememberName(lastDuelName, lastDuelCombo)
			AddCombo(social.duels.challengedCombos, lastDuelCombo)
		end
	end)
end

-- ---------------------------------------------------------------------------
-- Wire-up through the shared registrar
-- ---------------------------------------------------------------------------

ns.On("CHAT_MSG_WHISPER", OnWhisperReceived, "Social")
ns.On("CHAT_MSG_BN_WHISPER", OnWhisperReceived, "Social")
ns.On("TRADE_SHOW", OnTradeShow, "Social")
ns.On("TRADE_ACCEPT_UPDATE", OnTradeAccept, "Social")
ns.On("TRADE_CLOSED", OnTradeClosed, "Social")
ns.On("TRADE_MONEY_CHANGED", OnTradeMoney, "Social")
ns.On("PLAYER_TRADE_MONEY", OnTradeMoney, "Social")
ns.On("CHAT_MSG_SYSTEM", OnTradeMessage, "Social")
ns.On("MAIL_SHOW", OnMailShow, "Social")
ns.On("MAIL_INBOX_UPDATE", ScanInbox, "Social")
ns.On("MAIL_SEND_SUCCESS", OnMailSent, "Social")
ns.On("SEND_MAIL_SUCCESS", OnMailSent, "Social")
ns.On("DUEL_REQUESTED", OnDuelRequested, "Social")
ns.On("DUEL_COUNTDOWN", OnDuelCountdown, "Social")
ns.On("DUEL_FINISHED", OnDuelFinished, "Social")
ns.On("CHAT_MSG_SYSTEM", OnDuelMessage, "Social")
ns.On("PLAYER_LOGIN", function()
	HookSend()
	HookEditText()
end, "Social")
ns.On("PLAYER_TARGET_CHANGED", function()
	RememberUnit("target")
end, "Social")
ns.On("UPDATE_MOUSEOVER_UNIT", function()
	RememberUnit("mouseover")
end, "Social")


-- The group roster at logout, for the same reason a flight is kept: a group
-- that survives a relog is not a group met for the first time.
local GROUP_RESUME_GRACE = 3

function ns.SocialSnapshotPresence()
	local units = {}
	for unit, combo in pairs(lastUnits) do
		units[unit] = combo
	end
	return { units = units }
end

function ns.SocialRestorePresence(presence)
	if type(presence) ~= "table" or type(presence.units) ~= "table" then
		return
	end
	local count = 0
	for _ in pairs(presence.units) do
		count = count + 1
	end
	if count == 0 then
		return
	end
	lastUnits = presence.units
	unitsRestoreUntil = Now() + GROUP_RESUME_GRACE
	ns.Trace("presence: resuming with "..count.." group member(s) already counted")
end

ns.social = {
	Ensure = Ensure,
	UnitCombo = UnitCombo,
	ScanInbox = ScanInbox,
	SnapshotPresence = ns.SocialSnapshotPresence,
	RestorePresence = ns.SocialRestorePresence,
}
