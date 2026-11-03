-- Tally - Merchant's Favor: the Forever profession currency, id 3402.
--
-- Forever is the only client with this currency table. Every entry point is
-- gated on the currency actually being readable (or on the 1.60 Forever
-- build), so the rest of the addon never shows a tab or record on a client
-- that has no Merchant's Favor.
--
-- One character subtree is owned here: char.currency[3402].
local addonName, ns = ...

local FAVOR_ID = 3402
local FAVOR_NAME = "Merchant's Favor"
local RECENT_CAP = 50
local POLL_SECONDS = 10

local available
local pendingQuestID
local pendingQuestAt = 0
local readFailureTraced = false

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

-- C_CurrencyInfo on Forever and modern clients, GetCurrencyInfo on older
-- ones. Both are probed; a client that answers for another currency but not
-- 3402 is not treated as Forever.
local function ReadFromC()
	if type(C_CurrencyInfo) ~= "table" or type(C_CurrencyInfo.GetCurrencyInfo) ~= "function" then
		return nil
	end
	local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, FAVOR_ID)
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
	return amount, name, SafeNumber(info.maxQuantity), info.isAccountWide
end

local function ReadFromOld()
	if type(GetCurrencyInfo) ~= "function" then
		return nil
	end
	local ok, name, amount, _, maxQuantity = pcall(GetCurrencyInfo, FAVOR_ID)
	name = ok and SafeString(name) or nil
	amount = ok and SafeNumber(amount) or nil
	if not name and amount == nil then
		return nil
	end
	return amount, name, SafeNumber(maxQuantity)
end

local function ReadFromList()
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
	for index = 1, size do
		local okInfo, info = pcall(infoFn, index)
		if okInfo and type(info) == "table" then
			local id = SafeNumber(info.currencyID) or SafeNumber(info.id)
			local name = SafeString(info.name)
			if id == FAVOR_ID or name == FAVOR_NAME then
				return SafeNumber(info.quantity) or SafeNumber(info.amount),
					name, SafeNumber(info.maxQuantity), info.isAccountWide
			end
		end
	end
	return nil
end

local function Read()
	local amount, name, maxQuantity, accountWide = ReadFromC()
	if amount ~= nil or name then
		return amount, name, maxQuantity, accountWide
	end
	amount, name, maxQuantity = ReadFromOld()
	if amount ~= nil or name then
		return amount, name, maxQuantity
	end
	return ReadFromList()
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
	if name == FAVOR_NAME then
		available = true
	elseif ForeverBuild() then
		-- The build check keeps the tab available on a Forever client whose
		-- currency table is still filling in at login. The tracker reads the
		-- balance before it writes anything.
		available = true
	else
		available = false
	end
	ns.Trace("favor: available "..tostring(available).." (read name "..tostring(name)..")")
	return available
end

local function Ensure(char)
	if type(char) ~= "table" then
		return nil
	end
	if type(char.currency) ~= "table" then
		char.currency = {}
	end
	local entry = char.currency[FAVOR_ID]
	if type(entry) ~= "table" then
		entry = {}
		char.currency[FAVOR_ID] = entry
	end
	entry.name = entry.name or FAVOR_NAME
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
	local amount, name = Read()
	if amount == nil then
		if not readFailureTraced then
			readFailureTraced = true
			ns.Trace("favor: currency read returned no amount")
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
	local now = ns.Now()
	if not entry.firstAt then
		-- First sight is a baseline. Existing Favor is not a gain Tally saw.
		entry.name = name or FAVOR_NAME
		entry.starting = amount
		entry.balance = amount
		entry.earned = 0
		entry.spent = 0
		entry.firstAt = now
		entry.lastAt = now
		ns.Trace("favor: baseline "..amount)
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
	local day = os.date("%Y-%m-%d", now)
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
		pcall(ns.Touch, char, "currency."..FAVOR_ID..".balance", now)
	end
	ns.Trace("favor: "..(delta > 0 and "+" or "")..delta
		.." at level "..level.." (balance "..amount..")")
	if ns.OnDataTick then
		pcall(ns.OnDataTick)
	end
end

ns.MerchantsFavor = {
	ID = FAVOR_ID,
	Name = FAVOR_NAME,
	Available = Available,
	Read = Read,
	Ensure = Ensure,
	Poll = Poll,
}
ns.MerchantsFavorAvailable = Available

ns.On("PLAYER_ENTERING_WORLD", function()
	if C_Timer and C_Timer.After then
		C_Timer.After(1, Poll)
	else
		Poll()
	end
end, "Currency")
ns.On("PLAYER_LOGIN", function()
	if C_Timer and C_Timer.After then
		C_Timer.After(2, Poll)
	else
		Poll()
	end
end, "Currency")
ns.On("CURRENCY_DISPLAY_UPDATE", function(_, currencyID)
	if not currencyID or SafeNumber(currencyID) == FAVOR_ID then
		Poll()
	end
end, "Currency")
ns.On("QUEST_TURNED_IN", function(_, questID)
	pendingQuestID = SafeNumber(questID)
	pendingQuestAt = ns.Now()
	if C_Timer and C_Timer.After then
		C_Timer.After(1, Poll)
	else
		Poll()
	end
end, "Currency")
ns.On("QUEST_FINISHED", function()
	if C_Timer and C_Timer.After then
		C_Timer.After(1, Poll)
	else
		Poll()
	end
end, "Currency")
ns.On("MERCHANT_CLOSED", function()
	if C_Timer and C_Timer.After then
		C_Timer.After(1, Poll)
	else
		Poll()
	end
end, "Currency")

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
