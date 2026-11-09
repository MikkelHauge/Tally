-- Tally - the Character tab's Social sub-view: time grouped, guild time,
-- chat, trades, mail and duels, and a second card that lists every race and
-- class met and the guilds the character has been in.
--
-- Everything here is read from char.social, which Core/85_Social.lua records.
-- This file only draws it.
local addonName, ns = ...

local ACCENT, CreateTileRow, SetTile, DisplayChar, CreateListCard,
	FillScrollingLines, ShowCardText, AddCardTitleNote, AddCardScrollbar,
	MakeCardScrollable, ClassColorCode =
	ns.ACCENT, ns.CreateTileRow, ns.SetTile, ns.DisplayChar, ns.CreateListCard,
	ns.FillScrollingLines, ns.ShowCardText, ns.AddCardTitleNote, ns.AddCardScrollbar,
	ns.MakeCardScrollable, ns.ClassColorCode

local socialWidgets = { tiles = {} }

local CHAT_ORDER = {
	{ key = "say", label = "Say" },
	{ key = "yell", label = "Yell" },
	{ key = "party", label = "Party" },
	{ key = "raid", label = "Raid" },
	{ key = "guild", label = "Guild" },
	{ key = "channels", label = "Public channels" },
	{ key = "emote", label = "Emotes" },
	{ key = "other", label = "Other" },
}

local function Duration(seconds)
	return ns.FormatDuration(seconds or 0, true)
end

local function AddLine(lines, label, right, color)
	lines[#lines + 1] = { left = label, right = right, leftColor = color }
end

-- A section heading: a hairline with a blank row on either side, so each
-- block of figures reads as its own group instead of running into the one
-- above it.
local function AddHeader(lines, title)
	if #lines > 0 then
		lines[#lines + 1] = { divider = true }
		lines[#lines + 1] = {}
	end
	lines[#lines + 1] = { left = title, leftColor = ACCENT }
end

-- "Human Mage" with the class in its own colour: the class name is the tail
-- of the stored combo, so the race stays plain and the class reads like a
-- class anywhere else in the addon.
local function ClassColoredCombo(combo)
	local names = LOCALIZED_CLASS_NAMES_MALE
	if names then
		for classFile, name in pairs(names) do
			local suffix = " "..name
			if #combo > #suffix and string.sub(combo, -#suffix) == suffix then
				local race = string.sub(combo, 1, #combo - #suffix)
				local code = ClassColorCode(classFile) or ""
				if code == "" then
					return race.." "..name
				end
				return race.." "..code..name.."|r"
			end
		end
	end
	return combo
end

local function AddTotals(lines, char, social)
	local time = social.time or {}
	local guild = social.guild or {}
	local socialChat = social.chat or {}
	local whispers = social.whispers or {}

	local trades = social.trades or {}
	local mail = social.mail or {}
	local duels = social.duels or {}

	AddHeader(lines, "Group")
	local grouped = (time.party or 0) + (time.raid or 0)
	AddLine(lines, "Time grouped", Duration(grouped))
	AddLine(lines, "Time solo", Duration(time.solo))
	AddLine(lines, "Time as leader", Duration(time.leader))
	local sizes = {}
	for key, seconds in pairs(social.sizes or {}) do
		local size = tonumber(key)
		if size and seconds > 0 then
			sizes[#sizes + 1] = { size = size, seconds = seconds }
		end
	end
	table.sort(sizes, function(a, b)
		if a.size ~= b.size then
			return a.size < b.size
		end
		return a.seconds > b.seconds
	end)
	for index = 1, #sizes do
		local entry = sizes[index]
		AddLine(lines, "Group of "..entry.size, Duration(entry.seconds))
	end
	if social.guildGroup and ((social.guildGroup.mates or 0) + (social.guildGroup.strangers or 0)) > 0 then
		AddLine(lines, "Grouped with guildmates", Duration(social.guildGroup.mates))
		AddLine(lines, "Grouped with strangers", Duration(social.guildGroup.strangers))
	end

	AddHeader(lines, "Guild")
	AddLine(lines, "Current guild", guild.name or "none")
	if guild.name then
		local sent = tonumber((socialChat.byGuild or {})[guild.name]) or 0
		AddLine(lines, "Messages sent in this guild", ns.FormatNumber(sent))
	end
	AddLine(lines, "Time in any guild", Duration(guild.seconds))
	AddLine(lines, "Time without a guild", Duration(guild.guildless))

	AddHeader(lines, "Public chat")
	AddLine(lines, "Messages sent", ns.FormatNumber(socialChat.sent or 0))
	for index = 1, #CHAT_ORDER do
		local bucket = CHAT_ORDER[index]
		local count = socialChat[bucket.key] or 0
		if count > 0 then
			AddLine(lines, "   "..bucket.label, ns.FormatNumber(count))
		end
	end
	AddHeader(lines, "Whispers")
	AddLine(lines, "Whispers sent", ns.FormatNumber(whispers.sent or 0))
	AddLine(lines, "Whispers received", ns.FormatNumber(whispers.received or 0))

	AddHeader(lines, "Trades")
	AddLine(lines, "Trade windows opened", ns.FormatNumber(trades.count or 0))
	AddLine(lines, "Trades completed", ns.FormatNumber(trades.completed or 0))
	-- Both directions are always shown, zero included, so the pair reads as
	-- a balance rather than one figure that might mean either side.
	AddLine(lines, "Items given", ns.FormatNumber(trades.itemsGiven or 0))
	AddLine(lines, "Items received", ns.FormatNumber(trades.itemsReceived or 0))
	local gold = char.gold or {}
	local tradeIn = (gold.income and gold.income.trade) or 0
	local tradeOut = (gold.expenses and gold.expenses.trade) or 0
	-- The ledger is the lifetime figure. The trade record's own totals are the
	-- fallback for a window the ledger did not book.
	if tradeIn <= 0 then
		tradeIn = trades.goldReceived or 0
	end
	if tradeOut <= 0 then
		tradeOut = trades.goldGiven or 0
	end
	AddLine(lines, "Gold given", ns.MoneyColored(tradeOut))
	AddLine(lines, "Gold received", ns.MoneyColored(tradeIn))

	AddHeader(lines, "Mail")
	AddLine(lines, "Mail sent", ns.FormatNumber(mail.sent or 0))
	AddLine(lines, "Mail received", ns.FormatNumber(mail.received or 0))
	AddLine(lines, "With packages", ns.FormatNumber(mail.packages or 0))
	AddLine(lines, "Cash on delivery", ns.FormatNumber(mail.cod or 0))
	AddLine(lines, "Mailbox visits", ns.FormatNumber(mail.visits or 0))

	AddHeader(lines, "Duels")
	AddLine(lines, "Challenged", ns.FormatNumber(duels.challenged or 0))
	AddLine(lines, "Accepted", ns.FormatNumber(duels.accepted or 0))
	AddLine(lines, "Won", ns.FormatNumber(duels.won or 0))
	AddLine(lines, "Lost", ns.FormatNumber(duels.lost or 0))
end

-- Every race and class met, with the figures recorded against it, then the
-- guild history. This fills the second card.
local function AddInteractions(lines, social)
	local group = social.combos or {}
	local trades = (social.trades and social.trades.combos) or {}
	local whispersSent = (social.whispers and social.whispers.sentCombos) or {}
	local whispersReceived = (social.whispers and social.whispers.receivedCombos) or {}
	local won = (social.duels and social.duels.wonCombos) or {}
	local lost = (social.duels and social.duels.lostCombos) or {}
	local challenged = (social.duels and social.duels.challengedCombos) or {}

	local keys, seen = {}, {}
	local function AddKey(key)
		if key and not seen[key] then
			seen[key] = true
			keys[#keys + 1] = key
		end
	end
	for key in pairs(group) do
		AddKey(key)
	end
	for key in pairs(trades) do
		AddKey(key)
	end
	for key in pairs(whispersSent) do
		AddKey(key)
	end
	for key in pairs(whispersReceived) do
		AddKey(key)
	end
	for key in pairs(won) do
		AddKey(key)
	end
	for key in pairs(lost) do
		AddKey(key)
	end
	for key in pairs(challenged) do
		AddKey(key)
	end

	table.sort(keys, function(a, b)
		local ae = type(group[a]) == "table" and group[a] or {}
		local be = type(group[b]) == "table" and group[b] or {}
		if (ae.seconds or 0) ~= (be.seconds or 0) then
			return (ae.seconds or 0) > (be.seconds or 0)
		end
		local function Total(key)
			return (trades[key] or 0) + (whispersSent[key] or 0) + (whispersReceived[key] or 0)
				+ (won[key] or 0) + (lost[key] or 0) + (challenged[key] or 0)
		end
		local at, bt = Total(a), Total(b)
		if at ~= bt then
			return at > bt
		end
		return a < b
	end)

	AddHeader(lines, "Races and classes")
	for index = 1, #keys do
		-- A blank row between combos: the name and its figures below it stay
		-- together and the next race/class reads as a new entry.
		if index > 1 then
			lines[#lines + 1] = {}
		end
		local key = keys[index]
		local entry = type(group[key]) == "table" and group[key] or nil
		lines[#lines + 1] = { left = ClassColoredCombo(key) }
		if entry and (entry.seconds or 0) > 0 then
			AddLine(lines, "   Grouped", Duration(entry.seconds).."  ·  x"..ns.FormatNumber(entry.encounters or 0))
		end
		if (trades[key] or 0) > 0 then
			AddLine(lines, "   Trades completed", "x"..ns.FormatNumber(trades[key]))
		end
		if (whispersSent[key] or 0) > 0 then
			AddLine(lines, "   Whispers sent", "x"..ns.FormatNumber(whispersSent[key]))
		end
		if (whispersReceived[key] or 0) > 0 then
			AddLine(lines, "   Whispers received", "x"..ns.FormatNumber(whispersReceived[key]))
		end
		if (challenged[key] or 0) > 0 then
			AddLine(lines, "   Duels challenged", "x"..ns.FormatNumber(challenged[key]))
		end
		if (won[key] or 0) > 0 then
			AddLine(lines, "   Duels won", "x"..ns.FormatNumber(won[key]))
		end
		if (lost[key] or 0) > 0 then
			AddLine(lines, "   Duels lost", "x"..ns.FormatNumber(lost[key]))
		end
	end

	-- Whatever the client could not name a race and class for. The totals are
	-- kept even when a stranger's whisper or trade cannot be classified, so
	-- the remainder is shown rather than quietly disappearing from the card.
	local function SumBucket(bucket)
		local total = 0
		for _, value in pairs(bucket or {}) do
			if type(value) == "table" then
				total = total + (tonumber(value.encounters) or 0)
			else
				total = total + (tonumber(value) or 0)
			end
		end
		return total
	end
	local whispers = social.whispers or {}
	local tradesTotal = social.trades or {}
	local duels = social.duels or {}
	local unknown = {
		whispersSent = math.max(0, (tonumber(whispers.sent) or 0) - SumBucket(whispersSent)),
		whispersReceived = math.max(0, (tonumber(whispers.received) or 0) - SumBucket(whispersReceived)),
		trades = math.max(0, (tonumber(tradesTotal.completed) or 0) - SumBucket(trades)),
		challenged = math.max(0, (tonumber(duels.challenged) or 0) - SumBucket(challenged)),
		won = math.max(0, (tonumber(duels.won) or 0) - SumBucket(won)),
		lost = math.max(0, (tonumber(duels.lost) or 0) - SumBucket(lost)),
	}
	local anyUnknown = unknown.whispersSent > 0 or unknown.whispersReceived > 0
		or unknown.trades > 0 or unknown.challenged > 0
		or unknown.won > 0 or unknown.lost > 0
	if anyUnknown then
		if #keys > 0 then
			lines[#lines + 1] = {}
		end
		lines[#lines + 1] = { left = "Unknown", leftColor = { 0.62, 0.62, 0.62 } }
		if unknown.whispersSent > 0 then
			AddLine(lines, "   Whispers sent", "x"..ns.FormatNumber(unknown.whispersSent))
		end
		if unknown.whispersReceived > 0 then
			AddLine(lines, "   Whispers received", "x"..ns.FormatNumber(unknown.whispersReceived))
		end
		if unknown.trades > 0 then
			AddLine(lines, "   Trades completed", "x"..ns.FormatNumber(unknown.trades))
		end
		if unknown.challenged > 0 then
			AddLine(lines, "   Duels challenged", "x"..ns.FormatNumber(unknown.challenged))
		end
		if unknown.won > 0 then
			AddLine(lines, "   Duels won", "x"..ns.FormatNumber(unknown.won))
		end
		if unknown.lost > 0 then
			AddLine(lines, "   Duels lost", "x"..ns.FormatNumber(unknown.lost))
		end
	end

	AddHeader(lines, "Guilds")
	local guild = social.guild or {}
	local history = guild.history or {}
	local byGuild = (social.chat and social.chat.byGuild) or {}
	local now = (ns.Now and ns.Now()) or time()
	-- One heading per guild, with every membership of it underneath. A real
	-- rejoin therefore reads as a second membership of the same guild rather
	-- than as a second guild, and the lifetime message count stays in one
	-- place. Groups keep the order of their newest membership.
	local order, groups = {}, {}
	for index = #history, 1, -1 do
		local entry = history[index]
		if entry.name then
			local group = groups[entry.name]
			if not group then
				group = { name = entry.name, memberships = {} }
				groups[entry.name] = group
				order[#order + 1] = group
			end
			group.memberships[#group.memberships + 1] = entry
			if entry.leftAt == nil then
				group.current = true
			end
		end
	end
	for index = 1, #order do
		local group = order[index]
		-- Same blank row between guilds as between races and classes.
		if index > 1 then
			lines[#lines + 1] = {}
		end
		lines[#lines + 1] = {
			left = group.name..(group.current and "   (current)" or ""),
			leftColor = ACCENT,
		}
		for position = 1, #group.memberships do
			local entry = group.memberships[position]
			-- A blank row between memberships of one guild, the same way the
			-- entries above are separated.
			if position > 1 then
				lines[#lines + 1] = {}
			end
			local since = entry.joinedAt
			local untilAt = entry.leftAt or now
			if since then
				local label = entry.baseline and "   Member for at least" or "   Member for"
				AddLine(lines, label, Duration(untilAt - since))
			end
			if entry.baseline then
				AddLine(lines, "   Joined", "before Tally met this character")
			elseif entry.joinedAt then
				AddLine(lines, "   Joined", ns.FormatDate(entry.joinedAt))
			end
			if entry.leftAt then
				AddLine(lines, "   Left", ns.FormatDate(entry.leftAt))
			end
		end
		local sent = tonumber(byGuild[group.name]) or 0
		AddLine(lines, "   Messages sent", ns.FormatNumber(sent))
	end
	if #order == 0 then
		AddLine(lines, "No guild history yet", "none")
	end
end

local function RefreshSocial()
	local totalsCard = socialWidgets.card
	local interactionsCard = socialWidgets.interactions
	if not totalsCard or not interactionsCard then
		return
	end
	local char = DisplayChar()
	if not char then
		for index = 1, #socialWidgets.tiles do
			SetTile(socialWidgets.tiles[index], "-", "")
		end
		ShowCardText(totalsCard, "No character selected.")
		ShowCardText(interactionsCard, "No character selected.")
		return
	end
	local social = char.social or {}
	local time = social.time or {}
	SetTile(socialWidgets.tiles[1], Duration(time.solo), "")
	SetTile(socialWidgets.tiles[2], Duration(time.party), "")
	SetTile(socialWidgets.tiles[3], Duration(time.raid), "")
	SetTile(socialWidgets.tiles[4], Duration(time.leader), "")

	local totals = {}
	AddTotals(totals, char, social)
	if FillScrollingLines(totalsCard, totals, socialWidgets, "socialOffset", "Social", 30) == 0 then
		ShowCardText(totalsCard, "Nothing social has been recorded for this character yet. The counters fill as you group, talk, trade and duel.")
	end

	local interactions = {}
	AddInteractions(interactions, social)
	if FillScrollingLines(interactionsCard, interactions, socialWidgets, "interactionsOffset", "Interactions", 30) == 0 then
		ShowCardText(interactionsCard, "Nothing recorded for any race, class or guild yet.")
	end
end

local function BuildSocialPage(page)
	CreateTileRow(page, -4, { "Time solo", "Time in party", "Time in raid", "As leader" }, socialWidgets.tiles, false)

	local card = CreateListCard(page, 0, -88, 359, 326, "Social")
	socialWidgets.card = card
	AddCardTitleNote(card, "Social",
		"Time grouped, time in any guild and time without a guild are counted once a second while Tally is running, so only time you were online counts. Mail is seeded the first time a mailbox is opened, so old letters are not counted as new. Everything is stored locally in TallyDB.")
	AddCardScrollbar(card, socialWidgets, "socialOffset", RefreshSocial)
	MakeCardScrollable(card, socialWidgets, "socialOffset", RefreshSocial)

	local interactions = CreateListCard(page, 371, -88, 359, 326, "Interactions")
	socialWidgets.interactions = interactions
	AddCardTitleNote(interactions, "Interactions",
		"Every race and class this character has grouped with, traded with, whispered or duelled, with the group time and the counts recorded for each, followed by the guilds the character has been in, one heading per guild with each membership below it. A guild's Member for is calendar time since the join date, so it includes days offline; the Social card's time in any guild is the time Tally watched. A player's race and class is read from the client when possible and remembered by name for this character, so a later whisper or trade can still be counted even after they are out of sight. A final Unknown row collects interactions whose race and class the client could not name.")
	AddCardScrollbar(interactions, socialWidgets, "interactionsOffset", RefreshSocial)
	MakeCardScrollable(interactions, socialWidgets, "interactionsOffset", RefreshSocial)

	RefreshSocial()
end

ns.BuildSocialPage = BuildSocialPage
ns.RefreshSocial = RefreshSocial