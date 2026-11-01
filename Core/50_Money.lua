-- Tally - money: the balance reading, the ledger, the day buckets, repairs
-- and the moneyContext flags that classify a change.
--
-- One character subtree is owned here: char.gold. The moneyContext flags are
-- written by the event chain and read by the classifier, so they live in one
-- table; the ledger functions stay private to this file.
local addonName, ns = ...

local Now, TUNING = ns.Now, ns.TUNING

local moneyContext = {
	merchantShown = false,
	mailShown = false,
	tradeShown = false,
	auctionShown = false,
	trainerShown = false,
	closedAt = { merchant = 0, trainer = 0, mail = 0, trade = 0, auction = 0 },
	lootContextAt = 0,
	questGoldUntil = 0,
	repair = { cost = 0, at = 0, paidAt = 0, blocked = false },
	pendingMoney = nil,          -- { key, value, at }: pending reading
	lastMoneyReading = nil,      -- last balance given while in the world
	moneySettled = false,        -- the session's start balance is adopted
	sawUnsettledChange = false,  -- PLAYER_MONEY fired before the settle
}
ns.moneyContext = moneyContext
ns.repairWatch = moneyContext.repair

-- Gold is written through one path. Context flags record what was open or
-- what just happened when money changed; a change the flags cannot explain
-- is stored as unclassified rather than assigned to a category.
local function PruneDaily(gold)
	local count = 0
	for _ in pairs(gold.daily) do
		count = count + 1
	end
	if count <= TUNING.dailyCap then
		return
	end
	local keys = {}
	for key in pairs(gold.daily) do
		keys[#keys + 1] = key
	end
	table.sort(keys)
	for index = 1, count - TUNING.dailyCap do
		gold.daily[keys[index]] = nil
	end
end

-- Reverses one booked change: the category bucket, the day total and the
-- unclassified counters are restored to their pre-change values.
local function UndoMoneyChange(gold, entry)
	local delta = entry.d or 0
	if delta == 0 then
		return
	end
	if entry.c == "unclassified" then
		gold.unclassified.count = math.max(0, (gold.unclassified.count or 0) - 1)
		gold.unclassified.net = (gold.unclassified.net or 0) - delta
		if delta > 0 then
			gold.unclassified.cashIn = math.max(0, (gold.unclassified.cashIn or 0) - delta)
		else
			gold.unclassified.cashOut = math.max(0, (gold.unclassified.cashOut or 0) + delta)
		end
	elseif delta > 0 then
		gold.income[entry.c] = math.max(0, (gold.income[entry.c] or 0) - delta)
	else
		gold.expenses[entry.c] = math.max(0, (gold.expenses[entry.c] or 0) + delta)
	end
	local day = gold.daily[date("%Y-%m-%d", entry.t or Now())]
	if day then
		if delta > 0 then
			day.income = math.max(0, (day.income or 0) - delta)
		else
			day.expense = math.max(0, (day.expense or 0) + delta)
		end
	end
end

-- The balance Tally first saw for a character: the opening balance of the
-- earliest session it recorded, which is the reading the first settle adopted
-- and is never a change. Falls back to the stored reading for a record whose
-- sessions were cleared or predate session anchors. The ledger, the overview
-- and the printed report all read this, so the three cannot disagree.
function ns.FirstReading(char)
	if not char then
		return nil
	end
	local sessions = char.sessions
	local history = sessions and sessions.history
	if history and #history > 0 then
		-- Only the earliest session's own anchor can speak for the first
		-- reading: a later session's start is simply a later balance.
		local start = history[1].goldStart
		if start then
			return start
		end
	elseif sessions and sessions.current and sessions.current.goldStart then
		-- No session has ended yet, so the open one is the first: its start
		-- is the first balance Tally took.
		return sessions.current.goldStart
	end
	local gold = char.gold
	return gold and gold.first or nil
end

-- Books one change into the buckets and the day ledger. The callers own the
-- balance and the change list, since only they know the reading that
-- produced the change.
local function BookChange(gold, delta, category, at)
	if type(gold) ~= "table" then
		return
	end
	if type(gold.income) ~= "table" then gold.income = {} end
	if type(gold.expenses) ~= "table" then gold.expenses = {} end
	if type(gold.daily) ~= "table" then gold.daily = {} end
	if type(gold.unclassified) ~= "table" then gold.unclassified = {} end
	local char = ns.GetChar()
	at = at or Now()
	if category == "unclassified" then
		gold.unclassified.count = gold.unclassified.count + 1
		gold.unclassified.net = gold.unclassified.net + delta
		gold.unclassified.lastAt = at
		gold.unclassified.firstAt = gold.unclassified.firstAt or at
		gold.unclassified.countAt = at
		-- Money the flags could not explain, split by direction. Before the
		-- split was kept, only the net exists, and the readers fall back to
		-- it: a net is exact whenever the unexplained money went one way.
		if delta > 0 then
			gold.unclassified.cashIn = (gold.unclassified.cashIn or 0) + delta
		else
			gold.unclassified.cashOut = (gold.unclassified.cashOut or 0) - delta
		end
	else
		local bank = delta > 0 and "income" or "expenses"
		local metaBank = delta > 0 and "incomeMeta" or "expenseMeta"
		gold[bank][category] = (gold[bank][category] or 0) + (delta > 0 and delta or -delta)
		if type(gold[metaBank]) ~= "table" then
			gold[metaBank] = {}
		end
		local meta = gold[metaBank][category]
		if type(meta) ~= "table" then
			meta = { firstAt = at }
			gold[metaBank][category] = meta
		end
		meta.lastAt = at
		meta.updatedAt = at
		meta.evidence = "money_window"
		if char then
			ns.Touch(char, "gold."..bank.."."..tostring(category), at)
		end
	end
	local dayKey = date("%Y-%m-%d", at)
	local day = gold.daily[dayKey]
	if not day then
		day = { income = 0, expense = 0 }
		gold.daily[dayKey] = day
	end
	if delta > 0 then
		day.income = day.income + delta
	else
		day.expense = day.expense - delta
	end
	PruneDaily(gold)
end

-- Whether the cursor is in the vendor's repair mode. In that mode the player
-- clicks their own items to repair them one at a time, and the cost of each
-- is not the quoted total, so the mode itself is the evidence.
local function RepairModeLive()
	if type(InRepairMode) ~= "function" then
		return false
	end
	local ok, repairing = pcall(InRepairMode)
	return ok and repairing and true or false
end
ns.RepairModeLive = RepairModeLive

local WINDOW_CATEGORY = {
	merchant = "vendor",
	trainer = "training",
	mail = "mail",
	trade = "trade",
	auction = "auction",
}
local WINDOW_ORDER = { "merchant", "trainer", "mail", "trade", "auction" }

-- With no window open, the most recently closed window within the grace is
-- the one that explains the change. A fixed priority made a trade completed
-- just after closing mail read as mail.
local function RecentWindow(now)
	local best, bestAt
	for index = 1, #WINDOW_ORDER do
		local name = WINDOW_ORDER[index]
		local at = moneyContext.closedAt[name] or 0
		if at > 0 and (now - at) <= TUNING.windowGrace and (not bestAt or at > bestAt) then
			best, bestAt = name, at
		end
	end
	return best
end

local function Age(at, now)
	if not at or at <= 0 then
		return "-"
	end
	return tostring(math.floor(now - at)).."s"
end

-- The balance is a reading, not an event. Keep the moment it was read and the
-- first reading's own anchor, so the UI never has to pretend the figure is
-- live when it is a snapshot.
local function SetBalance(char, gold, money, at, source)
	if not char or not gold then
		return
	end
	at = at or Now()
	gold.balance = money
	gold.balanceAt = at
	gold.balanceEvidence = "money_poll"
	if gold.firstAt == nil then
		local session = char.sessions and char.sessions.current
		gold.firstAt = (session and session.start) or at
		gold.firstEvidence = "money_poll"
	end
	if gold.firstSource == nil then
		gold.firstSource = source or "poll"
	end
	if ns.Touch then
		ns.Touch(char, "gold.balance", at)
	end
end

-- Books one money change end to end: the category it falls in, the day it
-- falls on, the balance it leaves, and the change list. `at` defaults to now
-- and is only given by the login repair, which books movement an earlier
-- reading recorded.
local function ApplyMoneyDelta(delta, newBalance, at)
	local char = ns.GetChar()
	if not char or not delta or delta == 0 or not ns.Tracks("economy") then
		return
	end
	local gold = char.gold
	if type(gold) ~= "table" then
		return
	end
	if type(gold.tx) ~= "table" then gold.tx = {} end
	if type(gold.unclassified) ~= "table" then gold.unclassified = {} end
	local now = at or Now()

	-- A session open before the first balance reading was confirmed starts
	-- its gold count from the balance just before this change, so the
	-- change counts as part of the session.
	local session = char.sessions.current
	if session and session.goldStart == nil then
		session.goldStart = (newBalance or 0) - delta
	end

	local category
	-- A repair is recognised by the quote the vendor gave, not only by the
	-- vendor window: the balance is confirmed a couple of seconds after the
	-- money moves, so a player who repairs and closes the window at once
	-- would otherwise be booked as something else. The quote outlives the
	-- window by TUNING.repairGrace for exactly that case.
	local repairFresh = moneyContext.repair.cost > 0 and (now - moneyContext.repair.at) <= TUNING.repairGrace
	local repairButton = moneyContext.repair.paidAt > 0 and (now - moneyContext.repair.paidAt) <= TUNING.repairButton
	if delta < 0 and repairButton then
		-- The player pressed the game's repair button a moment ago; the change
		-- that follows is what it cost.
		category = "repair"
		moneyContext.repair.paidAt = 0
		moneyContext.repair.cost = 0
	elseif (moneyContext.merchantShown or repairFresh) and delta < 0 and moneyContext.repair.cost > 0 and -delta == moneyContext.repair.cost then
		category = "repair"
		moneyContext.repair.cost = 0
		moneyContext.repair.paidAt = 0
	elseif delta < 0 and moneyContext.merchantShown and RepairModeLive() then
		-- One item repaired at a time with the cursor in repair mode: the cost
		-- is that item's own, not the quoted total, so the mode stands in.
		category = "repair"
		moneyContext.repair.cost = 0
		moneyContext.repair.paidAt = 0
	-- Reward money is income arriving inside the window a turn-in opened. That
	-- window is timed from QUEST_COMPLETE rather than from the dialog still
	-- being open: the balance reading is confirmed a second or two later, and
	-- by then QUEST_FINISHED has already fired.
	elseif delta > 0 and now <= moneyContext.questGoldUntil then
		category = "quest"
	elseif delta > 0 and (now - moneyContext.lootContextAt) <= TUNING.lootWindow then
		category = "loot"
	-- A collected auction sale is auction money, not mail. Auction.lua sets
	-- the amount and a short window when it reads the seller invoice, and only
	-- an exact match is claimed, so other mail in the same moment keeps its
	-- own name.
	elseif delta > 0 and ns.ahSaleAmount and delta == ns.ahSaleAmount and now <= (ns.ahSaleUntil or 0) then
		category = "auction"
		ns.ahSaleAmount = nil
	elseif moneyContext.merchantShown then
		category = "vendor"
	elseif moneyContext.trainerShown then
		category = "training"
	-- An active trade beats a mail window that is still open or was just
	-- closed. The change happens in the trade, whatever else is on screen.
	elseif moneyContext.tradeShown then
		category = "trade"
	elseif moneyContext.mailShown then
		category = "mail"
	elseif moneyContext.auctionShown then
		category = "auction"
	else
		local recent = RecentWindow(now)
		category = recent and WINDOW_CATEGORY[recent] or "unclassified"
	end

	-- An exact opposite change within TUNING.moneyReversal seconds cancels the
	-- earlier one instead of being booked as a second change; a flickering
	-- balance produces this shape. Both sides must be unclassified for that
	-- reading: a category is evidence of its own, so a real sale and a real
	-- purchase of the same size, or a repair, are never cancelled by the
	-- flicker guard.
	local tx = gold.tx
	local last = tx[#tx]
	if last and last.c == "unclassified" and category == "unclassified"
		and last.d == -delta and (now - (last.t or 0)) <= TUNING.moneyReversal then
		UndoMoneyChange(gold, last)
		tx[#tx] = nil
		SetBalance(char, gold, newBalance, now, "reversal")
		if ns.NoteGoldMilestone then
			ns.NoteGoldMilestone(gold.balance, now)
		end
		return
	end

	-- A completed trade reports both sides of its money exactly. Booking the
	-- pair keeps trade income and trade expense from hiding one direction
	-- behind the net change the purse reports.
	local bookedGross = false
	if ns.lastTradeGold then
		local trade = ns.lastTradeGold
		local given = trade.given or 0
		local received = trade.received or 0
		if trade.at and (now - trade.at) <= (TUNING.windowGrace + 5)
			and received - given == delta then
			-- The trade's own figures are better evidence than whichever
			-- window happened to be open, so they also settle the category.
			category = "trade"
			ns.lastTradeGold = nil
			bookedGross = true
			if received > 0 then
				BookChange(gold, received, "trade", now)
			end
			if given > 0 then
				BookChange(gold, -given, "trade", now)
			end
		end
	end
	if not bookedGross then
		BookChange(gold, delta, category, now)
	end
	if ns.NoteGoldSpentMilestone then
		ns.NoteGoldSpentMilestone(char)
	end
	-- The categories that depend on a window being open are breadcrumbed,
	-- since a change booked here instead is the only sign the client did not
	-- report that window.
	if category == "mail" or category == "trade" or category == "auction" or category == "unclassified" then
		ns.Trace("money: "..ns.FormatMoneyDelta(delta).." booked as "..category
			.." [mail="..tostring(moneyContext.mailShown).."/"..Age(moneyContext.closedAt.mail, now)
			..", trade="..tostring(moneyContext.tradeShown).."/"..Age(moneyContext.closedAt.trade, now)
			..", merchant="..tostring(moneyContext.merchantShown).."/"..Age(moneyContext.closedAt.merchant, now)
			..", trainer="..tostring(moneyContext.trainerShown).."/"..Age(moneyContext.closedAt.trainer, now)
			..", auction="..tostring(moneyContext.auctionShown).."/"..Age(moneyContext.closedAt.auction, now).."]")
	end

	SetBalance(char, gold, newBalance, now, "change")
	if gold.first == nil then
		gold.first = newBalance - delta
		gold.firstAt = gold.firstAt or (char.sessions and char.sessions.current and char.sessions.current.start) or now
		gold.firstEvidence = "money_poll"
	end
	if ns.NoteGoldMilestone then
		ns.NoteGoldMilestone(gold.balance, now)
	end

	tx[#tx + 1] = { t = now, d = delta, c = category, b = newBalance }
	if #tx > TUNING.transactionCap then
		table.remove(tx, 1)
	end
	if ns.NoteRecentEvent then
		ns.NoteRecentEvent("money", {
			at = now, zone = ns.CurrentZone and ns.CurrentZone() or nil,
			how = category, evidence = "money_poll",
			data = { delta = delta, category = category, balance = newBalance },
		})
	end
end

-- What the unclassified bucket holds, split by direction. Money that moved
-- while nothing explained it is kept out of the named categories, but it is
-- still money, so the totals add it back in. A record written before the
-- directions were kept has only the net; a net is exact whenever the
-- unexplained money went one way, so it is used as it stands.
function ns.UnclassifiedTotals(gold)
	local bucket = type(gold) == "table" and gold.unclassified or nil
	if type(bucket) ~= "table" then
		return 0, 0
	end
	local net = bucket.net or 0
	local cashIn = bucket.cashIn
	local cashOut = bucket.cashOut
	if cashIn == nil then
		cashIn = net > 0 and net or 0
	end
	if cashOut == nil then
		cashOut = net < 0 and -net or 0
	end
	return math.max(0, cashIn), math.max(0, cashOut)
end

-- Money in and money out as the tiles and totals state them: the named
-- categories plus whatever the flags could not classify.
function ns.MoneyTotals(gold)
	if type(gold) ~= "table" then
		return 0, 0
	end
	local unclassifiedIn, unclassifiedOut = ns.UnclassifiedTotals(gold)
	local earned, spent = 0, 0
	for _, value in pairs(gold.income or {}) do
		earned = earned + (value or 0)
	end
	for _, value in pairs(gold.expenses or {}) do
		spent = spent + (value or 0)
	end
	return earned + unclassifiedIn, spent + unclassifiedOut
end

-- Stores the repair quote for the open merchant window. The next negative
-- money change equal to it is booked as "repair" rather than "vendor".
local function NoteRepairCost()
	if moneyContext.repair.blocked or not GetRepairAllCost then
		return
	end
	local ok, cost = pcall(GetRepairAllCost)
	if ok and type(cost) == "number" and cost > 0 then
		moneyContext.repair.cost = cost
		moneyContext.repair.at = Now()
	end
end

-- Called from PLAYER_MONEY and once per tick as a safety net. The first
-- reading of a session becomes the starting balance only after it holds
-- for TUNING.moneySettle seconds; later readings are accepted after TUNING.moneyConfirm
-- seconds, since this client can report a briefly wrong balance (a
-- flickering money display) that would otherwise book a false loss and
-- gain. Both call paths share state through gold.balance, so no change is
-- counted twice.
local function PollMoney(enteredWorld)
	local char = ns.GetChar()
	if not char then
		return
	end
	if not enteredWorld then
		-- Money is only read once the character is in the world. This
		-- client can answer with an empty or stale balance for a moment
		-- at login; adopting such a reading as the baseline would turn
		-- the real balance into a large false change.
		return
	end
	if moneyContext.pendingMoney and moneyContext.pendingMoney.key ~= ns.charKey then
		moneyContext.pendingMoney = nil
	end
	local money = GetMoney()
	moneyContext.lastMoneyReading = money
	if not moneyContext.moneySettled then
		-- The start of a play session settles first. This client can
		-- serve a stale balance (sometimes 0) just after world entry; the
		-- real balance then arrives as false income or a fake whole-purse
		-- loss. A session's first steady reading is its starting point,
		-- not a transaction: it replaces the stored balance and is never
		-- booked. The settle timer restarts only on a different value,
		-- otherwise a steady reading would never age past the threshold.
		-- Readings after the settle are measured normally.
		local now = Now()
		if moneyContext.pendingMoney and moneyContext.pendingMoney.value == money then
			if (now - moneyContext.pendingMoney.at) >= TUNING.moneySettle then
				moneyContext.pendingMoney = nil
				moneyContext.moneySettled = true
				local session = char.sessions.current
				-- A session that was already anchored (an interface reload or
				-- a loading screen, rather than a fresh login) cannot have
				-- changed character, so the balance Tally stored seconds ago
				-- belongs to this same purse. A different reading is money
				-- that moved while Tally was not looking: it is booked, so the
				-- ledger and the balance stay in step instead of drifting apart
				-- by the amount that moved.
				if session and session.goldSettled and char.gold.balance ~= nil
					and char.gold.balance ~= money then
					ns.Trace("reload settle: balance "..tostring(char.gold.balance).." -> "..tostring(money).." (booked as a change Tally did not see)")
					ApplyMoneyDelta(money - char.gold.balance, money)
					moneyContext.sawUnsettledChange = false
					return
				end
				if char.gold.balance ~= nil and char.gold.balance ~= money then
					if moneyContext.sawUnsettledChange then
						-- The purse really moved while the settle was waiting:
						-- the client fired PLAYER_MONEY, so this is not a stale
						-- login reading but money that arrived in the session.
						-- Book it (unclassified when no window explains it) so
						-- the balance and the income total agree from the start,
						-- instead of drifting apart until the next reload.
						ns.Trace("settle: balance "..tostring(char.gold.balance).." -> "..tostring(money).." (booked, seen during the settle)")
						ApplyMoneyDelta(money - char.gold.balance, money, now)
					else
						ns.Trace("session settled: balance "..tostring(char.gold.balance).." -> "..tostring(money).." (adopted, nothing booked)")
					end
				end
				moneyContext.sawUnsettledChange = false
				SetBalance(char, char.gold, money, now, "settle")
				if char.gold.first == nil then
					char.gold.first = money
					char.gold.firstAt = now
					char.gold.firstEvidence = "money_poll"
				end
				if ns.NoteGoldMilestone then
					ns.NoteGoldMilestone(money, now)
				end
				-- The session is already open (at the world entry); its
				-- gold anchor becomes this settled reading, replacing the
				-- stored balance it was opened with. A session anchored in
				-- an earlier load (/reload) keeps its anchor.
				if session and not session.goldSettled then
					session.goldStart = money
					session.goldSettled = true
				end
			end
			return
		end
		moneyContext.pendingMoney = { key = ns.charKey, value = money, at = now }
		return
	end
	if money == char.gold.balance then
		-- Back at the known balance: whatever was pending was a flicker.
		moneyContext.pendingMoney = nil
		return
	end
	local now = Now()
	if moneyContext.pendingMoney and moneyContext.pendingMoney.value == money then
		if (now - moneyContext.pendingMoney.at) >= TUNING.moneyConfirm then
			moneyContext.pendingMoney = nil
			if char.gold.balance == nil then
				-- No stored balance to measure against (a brand-new record or
				-- a character switched to in this same client session): adopt
				-- the reading instead of subtracting from nil.
				SetBalance(char, char.gold, money, now, "adopt")
			else
				ApplyMoneyDelta(money - char.gold.balance, money)
			end
		end
		return
	end
	moneyContext.pendingMoney = { key = ns.charKey, value = money, at = now }
end

-- Called from the PLAYER_MONEY event, just before the poll: the client is
-- reporting a move in the purse. During the settle window that is what
-- separates a genuine change from a stale login reading - but only when the
-- last steady-ish reading was the stored balance. If the client was still
-- serving 0 (or another stale value), the event is the correction arriving,
-- not money the session earned, and the settle keeps adopting it.
function ns.NoteMoneyEvent()
	if moneyContext.moneySettled then
		return
	end
	local char = ns.GetChar()
	local stored = char and char.gold and char.gold.balance
	local pending = moneyContext.pendingMoney
	if stored ~= nil and pending and pending.value == stored then
		moneyContext.sawUnsettledChange = true
	end
end

-- Clears the gold anchor of sessions recorded while the client reported a
-- stale zero balance. Such a session starts at 0 and its gain equals the
-- unclassified income entry booked when the real balance arrived; that
-- matching entry identifies it. Only goldStart and goldEnd are cleared -
-- playtime, kills and everything else stay. Runs at login; idempotent.
-- Returns the number of sessions cleared.
local function CleanSessionGold(char)
	local history = char.sessions and char.sessions.history
	local tx = char.gold and char.gold.tx
	if not history or not tx then
		return 0
	end
	local fixed = 0
	for index = 1, #history do
		local session = history[index]
		local gain = session.goldEnd or 0
		if session.goldStart == 0 and gain > 0 then
			for entry = 1, #tx do
				local change = tx[entry]
				if change.c == "unclassified" and change.d == gain and (change.b or 0) == gain then
					session.goldStart = nil
					session.goldEnd = nil
					fixed = fixed + 1
					break
				end
			end
		end
	end
	return fixed
end

-- Removes cancelled-out entries from ledgers written before the flicker
-- guard. Three shapes are dropped, with their bucket effects undone:
--   * an adjacent pair of unclassified changes that negate each other
--     within TUNING.moneyReversal seconds;
--   * a whole-purse pair - a loss ending at a balance of 0 followed by an
--     income of the same amount starting from 0, a session apart;
--   * a lone whole-purse loss (negative change, balance 0) with no other
--     side.
-- Only cancelling moves are touched, so a ledger of real transactions is
-- unchanged. Runs at login; idempotent. Returns the count of entries
-- removed.
local function CleanGoldLedger(gold)
	if not (gold and gold.tx) then
		return 0
	end
	local tx = gold.tx
	local removed = 0
	local index = 2
	while index <= #tx do
		local previous, current = tx[index - 1], tx[index]
		if previous.c == "unclassified" and current.c == "unclassified"
			and (current.d or 0) ~= 0 and current.d == -previous.d
			and math.abs((current.t or 0) - (previous.t or 0)) <= TUNING.moneyReversal then
			UndoMoneyChange(gold, previous)
			UndoMoneyChange(gold, current)
			table.remove(tx, index)
			table.remove(tx, index - 1)
			removed = removed + 2
			if index > 2 then
				index = index - 1
			end
		else
			index = index + 1
		end
	end
	-- Whole-purse pair: a loss ending at balance 0 followed by an income of
	-- the same amount starting from 0. The two cancel exactly, but they sit
	-- a session apart, outside the window of the first pass.
	index = 2
	while index <= #tx do
		local previous, current = tx[index - 1], tx[index]
		if previous.c == "unclassified" and (previous.d or 0) < 0 and (previous.b or 1) == 0
			and current.c == "unclassified" and (current.d or 0) > 0
			and current.d == -previous.d and (current.b or 0) == current.d then
			UndoMoneyChange(gold, previous)
			UndoMoneyChange(gold, current)
			table.remove(tx, index)
			table.remove(tx, index - 1)
			removed = removed + 2
			if index > 2 then
				index = index - 1
			end
		else
			index = index + 1
		end
	end
	-- Lone whole-purse loss whose matching income never arrived.
	index = 1
	while index <= #tx do
		local entry = tx[index]
		if entry.c == "unclassified" and (entry.d or 0) < 0 and (entry.b or 1) == 0 then
			UndoMoneyChange(gold, entry)
			table.remove(tx, index)
			removed = removed + 1
		else
			index = index + 1
		end
	end
	return removed
end

-- Books movement that only a balance reading recorded. A reading adopted
-- without a change - the settle after a reload or a loading screen, or a
-- balance the client reported later than the change that caused it - leaves
-- the purse and the day totals apart by exactly that amount, and every
-- stored change carries the balance it left behind. The amount is therefore
-- measurable between two changes, and its time is that of the later one, so
-- it is booked there as unclassified: the bucket for money nothing
-- explained. A ledger that already adds up is not touched, which makes this
-- idempotent. Runs at login. Returns the number of changes booked.
local function ReconcileGoldLedger(gold)
	local tx = gold and gold.tx
	if not tx or #tx < 2 then
		return 0
	end
	local booked = 0
	-- The rebuilt list is the old one with a correction in front of every
	-- change whose starting balance its predecessor cannot explain.
	local rebuilt = { tx[1] }
	for index = 2, #tx do
		local current = tx[index]
		local previous = rebuilt[#rebuilt]
		-- An entry stored without its balance or its amount cannot be checked
		-- against the one before it, and is left as it stands.
		local unbooked = 0
		if type(previous.b) == "number" and type(current.b) == "number"
			and type(current.d) == "number" then
			unbooked = current.b - (previous.b + current.d)
		end
		if unbooked ~= 0 then
			BookChange(gold, unbooked, "unclassified", current.t)
			rebuilt[#rebuilt + 1] = {
				t = current.t,
				d = unbooked,
				c = "unclassified",
				b = (current.b or 0) - (current.d or 0),
			}
			booked = booked + 1
		end
		rebuilt[#rebuilt + 1] = current
	end
	if booked > 0 then
		gold.tx = rebuilt
	end
	return booked
end

-- The logout reading is the last chance to book movement that happened while
-- the character was being torn down. It lives here so the pending-reading
-- state never has to be touched from Core.
function ns.MoneyOnLogout(char)
	local money = GetMoney()
	-- The game can answer 0 while tearing the character down at logout;
	-- adopting that reading would book a false whole-purse loss and turn the
	-- balance into fake income at the next login. A zero contradicting every
	-- reading of this session is the teardown, so the last balance stands and
	-- the next login settles any real difference.
	if money ~= nil and (money > 0 or (char.gold.balance or moneyContext.lastMoneyReading or 0) == 0) then
		-- Only a settled session has a measured starting point; before that
		-- nothing is booked and the reading is adopted as the settle would
		-- have adopted it.
		if moneyContext.moneySettled and char.gold.balance ~= money then
			ApplyMoneyDelta(money - (char.gold.balance or money), money)
		end
		SetBalance(char, char.gold, money, Now(), "logout")
	else
		local known = char.gold.balance or moneyContext.lastMoneyReading
		ns.Trace("logout: money reading ignored (client said "..tostring(money)..", last known "..tostring(known)..")")
	end
	moneyContext.pendingMoney = nil    -- the final reading is taken at face value
end

-- A character switched to in the same client session starts from an empty
-- money context: no window belongs to it, nothing has been confirmed for it,
-- and the settle has to run again. Without this the previous character's
-- flags leak into the new one and its nil balance is subtracted from.
function ns.ResetMoneyContext()
	moneyContext.merchantShown = false
	moneyContext.mailShown = false
	moneyContext.tradeShown = false
	moneyContext.auctionShown = false
	moneyContext.trainerShown = false
	moneyContext.closedAt.merchant = 0
	moneyContext.closedAt.trainer = 0
	moneyContext.closedAt.mail = 0
	moneyContext.closedAt.trade = 0
	moneyContext.closedAt.auction = 0
	moneyContext.lootContextAt = 0
	moneyContext.questGoldUntil = 0
	moneyContext.pendingMoney = nil
	moneyContext.lastMoneyReading = nil
	moneyContext.moneySettled = false
	moneyContext.sawUnsettledChange = false
	moneyContext.repair.cost = 0
	moneyContext.repair.at = 0
	moneyContext.repair.paidAt = 0
	moneyContext.repair.blocked = false
	ns.lastTradeGold = nil
end

-- A completed trade can report both sides of its money exactly. When the two
-- sides cancel out the purse reports no change at all, so the gross pair has
-- to be booked here rather than waiting for a change event.
function ns.BookTradeGold(given, received, at)
	local char = ns.GetChar()
	if not char or not char.gold or not ns.Tracks("economy") then
		return
	end
	at = at or Now()
	if (received or 0) > 0 then
		BookChange(char.gold, received, "trade", at)
	end
	if (given or 0) > 0 then
		BookChange(char.gold, -(given or 0), "trade", at)
	end
end

ns.PollMoney = PollMoney
ns.NoteRepairCost = NoteRepairCost
ns.CleanSessionGold = CleanSessionGold
ns.CleanGoldLedger = CleanGoldLedger
ns.ReconcileGoldLedger = ReconcileGoldLedger
-- Owner namespace. Every field is a reference to the flat API above; no
-- wrapper and no second implementation.
ns.money = {}
ns.money.FirstReading = ns.FirstReading
ns.money.UnclassifiedTotals = ns.UnclassifiedTotals
ns.money.Totals = ns.MoneyTotals
ns.money.Poll = ns.PollMoney
ns.money.NoteRepair = ns.NoteRepairCost
ns.money.CleanSession = ns.CleanSessionGold
ns.money.CleanLedger = ns.CleanGoldLedger
ns.money.Reconcile = ns.ReconcileGoldLedger
ns.money.OnLogout = ns.MoneyOnLogout
ns.money.RepairMode = ns.RepairModeLive
ns.money.Context = ns.moneyContext
ns.money.RepairWatch = ns.repairWatch
