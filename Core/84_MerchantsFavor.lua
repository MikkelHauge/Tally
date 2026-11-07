-- Tally - Merchant's Favor: the Forever profession currency, id 3402.
--
-- Forever is the only client with this currency table. Every entry point is
-- gated on the currency actually being readable (or on the 1.60 Forever
-- build), so the rest of the addon never shows a tab or record on a client
-- that has no Merchant's Favor.
--
-- One character subtree is owned here: char.currency[3402].
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

local FAVOR_ID = 3402
local FAVOR_NAME = "Merchant's Favor"
local RECENT_CAP = 50
local POLL_SECONDS = 10

local available
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
	-- A saved record can disagree with itself: an older build wrote the
	-- balance before "starting" and "earned" existed, or a save was cut
	-- short. The tab states the rule balance = starting + earned - spent, so
	-- the unexplained part is credited to earned here, once, instead of
	-- leaving a balance with nothing behind it. A fresh record is all zeroes
	-- and does not match this, so it still takes the baseline below.
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
			ns.Trace("favor: repaired a record that did not add up; earned "..repaired.." (balance "..savedBalance..")")
			if ns.Touch then
				pcall(ns.Touch, char, "currency."..FAVOR_ID..".balance", now)
			end
			if ns.OnDataTick then
				pcall(ns.OnDataTick)
			end
		end
	end
	-- A record can carry an earned total with no rows behind it: an earlier
	-- build crashed after crediting earned but before writing the level, day
	-- and recent rows (this client has no os.date). Give that total one row
	-- per view, once, so the by-level and recent lists are not empty while
	-- the Earned tile is not.
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
			pcall(ns.Touch, char, "currency."..FAVOR_ID..".balance", now)
		end
		ns.Trace("favor: wrote the missing history for "..earnedTotal.." earned")
		if ns.OnDataTick then
			pcall(ns.OnDataTick)
		end
	end

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

-- The chat line names the gain directly: "You receive currency:
-- [Merchant's Favor]x50". It is never credited from the text - the balance
-- stays the single source of truth, so nothing can be counted twice - but it
-- is used to look again a moment later, in case the currency table lags the
-- message, and both the message and the read are traced. That trace is what
-- tells a turn-in that did not move the tab apart from a first-read baseline.
ns.On("CHAT_MSG_CURRENCY", function(_, text)
	text = SafeString(text)
	if not text then
		return
	end
	lastCurrencyText = text
	local currencyID = tonumber(string.match(text, "currency:(%d+)"))
	local name = string.match(text, "%[([^%]]+)%]")
	local mentionsFavor = currencyID == FAVOR_ID
		or name == FAVOR_NAME
		or (name ~= nil and string.find(name, FAVOR_NAME, 1, true) ~= nil)
	ns.Trace("favor: chat '"..string.gsub(text, "|", "^").."' (names favor: "..tostring(mentionsFavor)..", economy tracking "..tostring(ns.Tracks and ns.Tracks("economy"))..")")
	if not mentionsFavor then
		return
	end
	local function ReadAgain()
		local amount, readName = Read()
		ns.Trace("favor: read after the message = "..tostring(amount).." ("..tostring(readName)..")")
		Poll()
	end
	if C_Timer and C_Timer.After then
		C_Timer.After(0.5, ReadAgain)
		C_Timer.After(3, ReadAgain)
	else
		ReadAgain()
	end
end, "Currency")

-- Read-only diagnostic for "/tally favor": every source the client offers,
-- side by side. It answers "what does the addon see right now" without
-- changing anything, which is the only way to tell a stale currency table
-- apart from a first-read baseline.
function ns.MerchantsFavorDiagnostics()
	local lines = {}
	local function Add(text)
		lines[#lines + 1] = text
	end
	Add("favor 3402: available="..tostring(Available())
		..", economy tracking="..tostring(ns.Tracks and ns.Tracks("economy")))
	local amount, name = ReadFromC()
	Add("favor: C_CurrencyInfo.GetCurrencyInfo = "..tostring(amount).." ("..tostring(name)..")")
	local oldAmount, oldName = ReadFromOld()
	Add("favor: GetCurrencyInfo = "..tostring(oldAmount).." ("..tostring(oldName)..")")
	local listAmount, listName = ReadFromList()
	Add("favor: currency list = "..tostring(listAmount).." ("..tostring(listName)..")")
	if type(C_CurrencyInfo) == "table" and type(C_CurrencyInfo.GetBackpackCurrencyInfo) == "function" then
		local found = false
		for index = 1, 8 do
			local ok, info = pcall(C_CurrencyInfo.GetBackpackCurrencyInfo, index)
			if not ok or type(info) ~= "table" then
				break
			end
			local id = SafeNumber(info.currencyTypesID) or SafeNumber(info.currencyID) or SafeNumber(info.id)
			local infoName = SafeString(info.name)
			if id == FAVOR_ID or infoName == FAVOR_NAME then
				Add("favor: backpack["..index.."] = "
					..tostring(SafeNumber(info.quantity) or SafeNumber(info.amount))
					.." ("..tostring(infoName)..")")
				found = true
			end
		end
		if not found then
			Add("favor: backpack currencies: favor not tracked there")
		end
	else
		Add("favor: backpack currency API unavailable")
	end
	local char = ns.GetChar and ns.GetChar() or nil
	local shown = ns.DisplayChar and ns.DisplayChar() or nil
	Add("favor: UI character = "..tostring(shown and ns.DisplayName and ns.DisplayName(shown) or "-")
		..", live character = "..tostring(char and ns.DisplayName and ns.DisplayName(char) or "-")
		..", viewer="..tostring(ns.viewKey))
	local entry = char and type(char.currency) == "table" and char.currency[FAVOR_ID] or nil
	if type(entry) == "table" then
		Add("favor: stored balance="..tostring(entry.balance)
			..", starting="..tostring(entry.starting)
			..", earned="..tostring(entry.earned)
			..", spent="..tostring(entry.spent))
		Add("favor: firstAt="..tostring(entry.firstAt)..", lastAt="..tostring(entry.lastAt))
	else
		Add("favor: no stored entry for this character")
	end
	Add("favor: last currency chat = "..tostring(lastCurrencyText))
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
