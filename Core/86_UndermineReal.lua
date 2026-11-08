-- Tally - Undermine Real: the Forever goblin currency (item 226404).
--
-- This is the second per-character currency tracker, built the same way as
-- Merchant's Favor (Core/84_MerchantsFavor.lua). It is a currency, not a bag
-- item, so every read goes through C_CurrencyInfo; the item id is only used
-- to find it when the client has not shown us its currency id yet.
--
-- One character subtree is owned here: char.currency[226404].
local addonName, ns = ...

-- This client's Lua sandbox has no "os" table at all, so os.date throws.
-- The game still provides the global date() and time(); os.date is kept as a
-- fallback for a client that has it, and an unknown day is used only if
-- neither exists (all gains then share one bucket instead of failing).
local Date
if type(date) == "function" then
	Date = date
elseif type(os) == "table" and type(os.date) == "function" then
	Date = os.date
else
	Date = function() return "unknown" end
end

local UNDERMINE_ITEM_ID = 226404
local UNDERMINE_KEY = 226404
local UNDERMINE_NAME = "Tarnished Undermine Real"
local RECENT_CAP = 50
local POLL_SECONDS = 10

local available
local currencyID
local pendingQuestID
local pendingQuestAt = 0
local readFailureTraced = false
local lastCurrencyText

local function SafeString(value)
	if type(value) ~= "string" then
		return nil
	end
	if type(issecretvalue) == "function" and issecretvalue(value) then
		return nil
	end
	return value
end

local function SafeNumber(value)
	if type(value) == "number" then
		return value
	end
	if type(value) == "string" then
		local ok, number = pcall(tonumber, value)
		return ok and number or nil
	end
	return nil
end

local function CurrentLevel()
	if type(UnitLevel) == "function" then
		local ok, value = pcall(UnitLevel, "player")
		local level = ok and SafeNumber(value) or nil
		if level and level > 0 then
			return level
		end
	end
	local char = ns.GetChar and ns.GetChar() or nil
	return SafeNumber(char and char.level) or 0
end

-- The whole currency tab, as the client reports it. Headers are kept so the
-- diagnostic can show exactly what the client calls each entry.
local function CurrencyList()
	local sizeFn = type(C_CurrencyInfo) == "table" and C_CurrencyInfo.GetCurrencyListSize
		or GetCurrencyListSize
	local infoFn = type(C_CurrencyInfo) == "table" and C_CurrencyInfo.GetCurrencyListInfo
		or GetCurrencyListInfo
	if type(sizeFn) ~= "function" or type(infoFn) ~= "function" then
		return nil
	end
	local ok, size = pcall(sizeFn)
	if not ok or type(size) ~= "number" then
		return nil
	end
	local entries = {}
	for index = 1, size do
		local okInfo, info = pcall(infoFn, index)
		if okInfo and type(info) == "table" then
			entries[#entries + 1] = {
				id = SafeNumber(info.currencyID) or SafeNumber(info.id),
				name = SafeString(info.name),
				amount = SafeNumber(info.quantity) or SafeNumber(info.amount)
					or SafeNumber(info.totalAmount),
				maxQuantity = SafeNumber(info.maxQuantity),
				isHeader = info.isHeader and true or false,
			}
		end
	end
	return entries
end

-- Reads the currency by name from the currency tab. This is also how the
-- numeric currency id is discovered: the item id is known, the currency id
-- is not documented anywhere reliable.
local function ReadFromList()
	local entries = CurrencyList()
	if not entries then
		return nil
	end
	for index = 1, #entries do
		local info = entries[index]
		local name = info.name
		if not info.isHeader and name
			and (name == UNDERMINE_NAME or string.find(name, "Undermine Real", 1, true)) then
			currencyID = info.id or currencyID
			return info.amount, name, info.maxQuantity
		end
	end
	return nil
end

local function ReadFromC()
	if not currencyID then
		return nil
	end
	if type(C_CurrencyInfo) ~= "table" or type(C_CurrencyInfo.GetCurrencyInfo) ~= "function" then
		return nil
	end
	local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
	if not ok or type(info) ~= "table" then
		return nil
	end
	local name = SafeString(info.name)
	local amount = SafeNumber(info.quantity)
		or SafeNumber(info.amount)
		or SafeNumber(info.totalAmount)
	if not name and amount == nil then
		return nil
	end
	return amount, name, SafeNumber(info.maxQuantity)
end

local function ReadFromLink()
	if type(C_CurrencyInfo) ~= "table"
		or type(C_CurrencyInfo.GetCurrencyInfoFromLink) ~= "function" then
		return nil
	end
	local getInfo = (type(C_Item) == "table" and C_Item.GetItemInfo) or GetItemInfo
	if type(getInfo) ~= "function" then
		return nil
	end
	local ok, _, link = pcall(getInfo, UNDERMINE_ITEM_ID)
	if not ok or type(link) ~= "string" then
		return nil
	end
	local okInfo, info = pcall(C_CurrencyInfo.GetCurrencyInfoFromLink, link)
	if not okInfo or type(info) ~= "table" then
		return nil
	end
	local name = SafeString(info.name)
	local amount = SafeNumber(info.quantity)
		or SafeNumber(info.amount)
		or SafeNumber(info.totalAmount)
	if not name and amount == nil then
		return nil
	end
	currencyID = SafeNumber(info.currencyID) or SafeNumber(info.id) or currencyID
	return amount, name, SafeNumber(info.maxQuantity)
end

-- Last resort only. A currency does not sit in the bags, so this normally
-- returns 0; it is kept because some clients expose currency items here.
local function ReadFromItemCount()
	if type(GetItemCount) ~= "function" then
		return nil
	end
	local ok, count = pcall(GetItemCount, UNDERMINE_ITEM_ID)
	count = ok and SafeNumber(count) or nil
	if count and count > 0 then
		return count, UNDERMINE_NAME
	end
	return nil
end

local function Read()
	local amount, name, maxQuantity = ReadFromC()
	if amount ~= nil or name then
		return amount, name, maxQuantity
	end
	amount, name, maxQuantity = ReadFromList()
	if amount ~= nil or name then
		return amount, name, maxQuantity
	end
	amount, name, maxQuantity = ReadFromLink()
	if amount ~= nil or name then
		return amount, name, maxQuantity
	end
	return ReadFromItemCount()
end

local function ForeverBuild()
	if type(GetBuildInfo) ~= "function" then
		return false
	end
	local ok, version = pcall(GetBuildInfo)
	version = ok and SafeString(version) or nil
	return version ~= nil and (version:match("^1%.60%.") ~= nil or version:match("^1%.60$") ~= nil)
end

local function Available()
	if available ~= nil then
		return available
	end
	local _, name = Read()
	if name and (name == UNDERMINE_NAME or string.find(name, "Undermine Real", 1, true)) then
		available = true
	elseif ForeverBuild() then
		-- The build check keeps the tab available on a Forever client whose
		-- currency table is still filling in at login. The tracker reads the
		-- balance before it writes anything.
		available = true
	else
		available = false
	end
	ns.Trace("undermine: available "..tostring(available).." (read name "..tostring(name)..")")
	return available
end

local function Ensure(char)
	if type(char) ~= "table" then
		return nil
	end
	if type(char.currency) ~= "table" then
		char.currency = {}
	end
	local entry = char.currency[UNDERMINE_KEY]
	if type(entry) ~= "table" then
		entry = {}
		char.currency[UNDERMINE_KEY] = entry
	end
	entry.name = entry.name or UNDERMINE_NAME
	entry.balance = SafeNumber(entry.balance) or 0
	entry.starting = SafeNumber(entry.starting) or 0
	entry.earned = SafeNumber(entry.earned) or 0
	entry.spent = SafeNumber(entry.spent) or 0
	entry.byLevel = type(entry.byLevel) == "table" and entry.byLevel or {}
	entry.daily = type(entry.daily) == "table" and entry.daily or {}
	entry.recent = type(entry.recent) == "table" and entry.recent or {}
	return entry
end

local function QuestName(questID)
	local id = SafeNumber(questID)
	if not id then
		return nil
	end
	if type(C_QuestLog) == "table" and type(C_QuestLog.GetTitleForQuestID) == "function" then
		local ok, title = pcall(C_QuestLog.GetTitleForQuestID, id)
		title = ok and SafeString(title) or nil
		if title and title ~= "" then
			return title
		end
	end
	return "Quest "..id
end

local function RecentSource(now)
	if pendingQuestID and pendingQuestAt > 0 and (now - pendingQuestAt) <= 15 then
		return QuestName(pendingQuestID)
	end
	return nil
end

local function AddRecent(entry, at, delta, level, source)
	local recent = entry.recent
	recent[#recent + 1] = {
		at = at, delta = delta, level = level, source = source,
	}
	while #recent > RECENT_CAP do
		table.remove(recent, 1)
	end
end

local function Poll()
	if not Available() then
		return
	end
	if ns.Tracks and not ns.Tracks("economy") then
		return
	end
	local amount, name, maxQuantity = Read()
	if amount == nil then
		if not readFailureTraced then
			readFailureTraced = true
			ns.Trace("undermine: currency read returned no amount")
		end
		return
	end
	local char = ns.GetChar and ns.GetChar() or nil
	if not char then
		return
	end
	local entry = Ensure(char)
	if not entry then
		return
	end
	entry.maxQuantity = SafeNumber(maxQuantity) or entry.maxQuantity
	local now = ns.Now()
	-- Same repair rule as Merchant's Favor: balance = starting + earned -
	-- spent. A saved record that disagrees is credited to earned once,
	-- instead of leaving a balance with nothing behind it.
	local savedBalance = SafeNumber(entry.balance) or 0
	local explained = (SafeNumber(entry.starting) or 0)
		+ (SafeNumber(entry.earned) or 0)
		- (SafeNumber(entry.spent) or 0)
	if savedBalance ~= explained then
		local repaired = savedBalance - (SafeNumber(entry.starting) or 0) + (SafeNumber(entry.spent) or 0)
		local repairedDelta = repaired - (SafeNumber(entry.earned) or 0)
		if repaired >= 0 and repairedDelta ~= 0 then
			entry.earned = repaired
			entry.firstAt = entry.firstAt or entry.lastAt or now
			entry.lastAt = entry.lastAt or now
			if repairedDelta > 0 then
				local level = CurrentLevel()
				local day = Date("%Y-%m-%d", entry.firstAt)
				local levelRow = entry.byLevel[level]
				if type(levelRow) ~= "table" then
					levelRow = { earned = 0, spent = 0 }
					entry.byLevel[level] = levelRow
				end
				local dayRow = entry.daily[day]
				if type(dayRow) ~= "table" then
					dayRow = { earned = 0, spent = 0 }
					entry.daily[day] = dayRow
				end
				levelRow.earned = (SafeNumber(levelRow.earned) or 0) + repairedDelta
				dayRow.earned = (SafeNumber(dayRow.earned) or 0) + repairedDelta
				AddRecent(entry, entry.firstAt, repairedDelta, level, "found in the balance")
				if repairedDelta > (SafeNumber(entry.bestGain) or 0) then
					entry.bestGain = repairedDelta
					entry.bestGainAt = entry.firstAt
					entry.bestGainLevel = level
				end
			end
			ns.Trace("undermine: repaired a record that did not add up; earned "..repaired.." (balance "..savedBalance..")")
			if ns.Touch then
				pcall(ns.Touch, char, "currency."..UNDERMINE_KEY..".balance", now)
			end
			if ns.OnDataTick then
				pcall(ns.OnDataTick)
			end
		end
	end
	-- A total with no rows behind it (the same crash shape Merchant's Favor
	-- had) gets one row per view, once.
	local earnedTotal = SafeNumber(entry.earned) or 0
	if earnedTotal > 0
		and next(entry.recent or {}) == nil
		and next(entry.byLevel or {}) == nil
		and next(entry.daily or {}) == nil then
		local spentTotal = SafeNumber(entry.spent) or 0
		local at = SafeNumber(entry.firstAt) or SafeNumber(entry.lastAt) or now
		local level = CurrentLevel()
		local day = Date("%Y-%m-%d", at)
		entry.byLevel[level] = { earned = earnedTotal, spent = spentTotal }
		entry.daily[day] = { earned = earnedTotal, spent = spentTotal }
		AddRecent(entry, at, earnedTotal, level, "found in the balance")
		if ns.Touch then
			pcall(ns.Touch, char, "currency."..UNDERMINE_KEY..".balance", now)
		end
		ns.Trace("undermine: wrote the missing history for "..earnedTotal.." earned")
		if ns.OnDataTick then
			pcall(ns.OnDataTick)
		end
	end

	if not entry.firstAt then
		-- First sight is a baseline. Reals already held are not a gain Tally
		-- saw.
		entry.name = name or UNDERMINE_NAME
		entry.starting = amount
		entry.balance = amount
		entry.earned = 0
		entry.spent = 0
		entry.firstAt = now
		entry.lastAt = now
		ns.Trace("undermine: baseline "..amount)
		return
	end

	local old = SafeNumber(entry.balance) or amount
	local delta = amount - old
	entry.balance = amount
	entry.lastAt = now
	if delta == 0 then
		return
	end

	local level = CurrentLevel()
	local day = Date("%Y-%m-%d", now)
	local levelRow = entry.byLevel[level]
	if type(levelRow) ~= "table" then
		levelRow = { earned = 0, spent = 0 }
		entry.byLevel[level] = levelRow
	end
	local dayRow = entry.daily[day]
	if type(dayRow) ~= "table" then
		dayRow = { earned = 0, spent = 0 }
		entry.daily[day] = dayRow
	end

	if delta > 0 then
		entry.earned = (SafeNumber(entry.earned) or 0) + delta
		levelRow.earned = (SafeNumber(levelRow.earned) or 0) + delta
		dayRow.earned = (SafeNumber(dayRow.earned) or 0) + delta
		if delta > (SafeNumber(entry.bestGain) or 0) then
			entry.bestGain = delta
			entry.bestGainAt = now
			entry.bestGainLevel = level
		end
	else
		local spent = -delta
		entry.spent = (SafeNumber(entry.spent) or 0) + spent
		levelRow.spent = (SafeNumber(levelRow.spent) or 0) + spent
		dayRow.spent = (SafeNumber(dayRow.spent) or 0) + spent
	end
	AddRecent(entry, now, delta, level, RecentSource(now))
	if ns.Touch then
		pcall(ns.Touch, char, "currency."..UNDERMINE_KEY..".balance", now)
	end
	ns.Trace("undermine: "..(delta > 0 and "+" or "")..delta
		.." at level "..level.." (balance "..amount..")")
	if ns.OnDataTick then
		pcall(ns.OnDataTick)
	end
end

ns.UndermineReal = {
	ID = UNDERMINE_KEY,
	ItemID = UNDERMINE_ITEM_ID,
	Name = UNDERMINE_NAME,
	Available = Available,
	Read = Read,
	Ensure = Ensure,
	Poll = Poll,
}
ns.UndermineRealAvailable = Available

ns.On("PLAYER_ENTERING_WORLD", function()
	if C_Timer and C_Timer.After then
		C_Timer.After(1, Poll)
	else
		Poll()
	end
end, "UndermineCurrency")
ns.On("PLAYER_LOGIN", function()
	if C_Timer and C_Timer.After then
		C_Timer.After(2, Poll)
	else
		Poll()
	end
end, "UndermineCurrency")
ns.On("CURRENCY_DISPLAY_UPDATE", function(_, eventCurrencyID)
	-- Until the currency id is resolved, any currency update is worth a look.
	if not currencyID or not eventCurrencyID
		or SafeNumber(eventCurrencyID) == currencyID then
		Poll()
	end
end, "UndermineCurrency")
ns.On("QUEST_TURNED_IN", function(_, questID)
	pendingQuestID = SafeNumber(questID)
	pendingQuestAt = ns.Now()
	if C_Timer and C_Timer.After then
		C_Timer.After(1, Poll)
	else
		Poll()
	end
end, "UndermineCurrency")
ns.On("QUEST_FINISHED", function()
	if C_Timer and C_Timer.After then
		C_Timer.After(1, Poll)
	else
		Poll()
	end
end, "UndermineCurrency")
ns.On("MERCHANT_CLOSED", function()
	if C_Timer and C_Timer.After then
		C_Timer.After(1, Poll)
	else
		Poll()
	end
end, "UndermineCurrency")

-- "You receive currency: [Tarnished Undermine Real]x3". The balance stays
-- the only source of truth; the message only makes the tracker look again a
-- moment later, in case the currency table lags.
ns.On("CHAT_MSG_CURRENCY", function(_, text)
	text = SafeString(text)
	if not text then
		return
	end
	lastCurrencyText = text
	local chatCurrencyID = tonumber(string.match(text, "currency:(%d+)"))
	local name = string.match(text, "%[([^%]]+)%]")
	local mentions = (chatCurrencyID ~= nil and chatCurrencyID == currencyID)
		or (name ~= nil and string.find(name, "Undermine Real", 1, true) ~= nil)
	ns.Trace("undermine: chat '"..string.gsub(text, "|", "^").."' (mentions real: "..tostring(mentions)..")")
	if not mentions then
		return
	end
	local function ReadAgain()
		local amount, readName = Read()
		ns.Trace("undermine: read after the message = "..tostring(amount).." ("..tostring(readName)..")")
		Poll()
	end
	if C_Timer and C_Timer.After then
		C_Timer.After(0.5, ReadAgain)
		C_Timer.After(3, ReadAgain)
	else
		ReadAgain()
	end
end, "UndermineCurrency")

-- Read-only diagnostic for "/tally undermine": every source, plus the whole
-- currency list, so the client's own name and id can be checked.
function ns.UndermineRealDiagnostics()
	local lines = {}
	local function Add(text)
		lines[#lines + 1] = text
	end
	Add("undermine 226404: available="..tostring(Available())
		..", economy tracking="..tostring(ns.Tracks and ns.Tracks("economy")))
	Add("undermine: currency id = "..tostring(currencyID))
	local cAmount, cName = ReadFromC()
	Add("undermine: C_CurrencyInfo.GetCurrencyInfo = "..tostring(cAmount).." ("..tostring(cName)..")")
	local list = CurrencyList()
	if list then
		Add("undermine: currency list, "..#list.." entries:")
		for index = 1, #list do
			local info = list[index]
			if not info.isHeader then
				Add("  "..tostring(info.id).." = "..tostring(info.amount)
					.." / "..tostring(info.maxQuantity).." ("..tostring(info.name)..")")
			end
		end
	else
		Add("undermine: currency list API unavailable")
	end
	local lAmount, lName = ReadFromLink()
	Add("undermine: link read = "..tostring(lAmount).." ("..tostring(lName)..")")
	Add("undermine: GetItemCount = "..tostring(ReadFromItemCount()))
	local char = ns.GetChar and ns.GetChar() or nil
	local entry = char and type(char.currency) == "table" and char.currency[UNDERMINE_KEY] or nil
	if type(entry) == "table" then
		Add("undermine: stored balance="..tostring(entry.balance)
			..", starting="..tostring(entry.starting)
			..", earned="..tostring(entry.earned)
			..", spent="..tostring(entry.spent))
		Add("undermine: firstAt="..tostring(entry.firstAt)..", lastAt="..tostring(entry.lastAt))
	else
		Add("undermine: no stored entry for this character")
	end
	Add("undermine: last currency chat = "..tostring(lastCurrencyText))
	return lines
end

-- A slow safety net for a client that does not raise a currency event for a
-- quest reward. The event paths normally answer first; a read with the same
-- balance does nothing.
local poller = CreateFrame("Frame")
local elapsed = 0
poller:SetScript("OnUpdate", function(_, delta)
	elapsed = elapsed + delta
	if elapsed < POLL_SECONDS then
		return
	end
	elapsed = 0
	Poll()
end)
