-- Tally - the auction house: postings, sales and the house's own cut.
--
-- The client states an auction in three different places, each at a different
-- moment, and this file keeps them apart:
--
--   * A posting is counted from the player's own list of owned auctions: a
--     row that was not in the previous list is new. The classic list has no
--     ids, so there a row that occurs more often than before is new. The
--     created event carries only an id and is not counted, so one auction is
--     never recorded twice.
--   * A sale is stated only by the seller invoice in the mail: the price, the
--     deposit returned and the house's cut. It is read when the mail is taken,
--     which is also when the money arrives.
--   * The live list is the client's own list of owned auctions, read while the
--     auction house is open. It is a snapshot and is labelled as one.
--
-- Nothing here books money. The gold ledger books the sale when the money
-- arrives; ns.ahSaleAmount only names that arrival as auction money.
local addonName, ns = ...

local CAPS = {
	itemDays = 30,          -- days an item row is kept without activity
	recentDays = 30,        -- days of events kept, ending at the newest
	buyDays = 30,           -- days of purchases kept for the buys view
	live = 40,              -- live auctions kept in the snapshot
	liveHold = 10,          -- seconds an empty answer keeps the last list
	baseline = 43200,       -- seconds the saved list is a posting baseline
	days = 120,             -- daily buckets kept
	saleWindow = 15,        -- seconds the sale money may arrive after the mail
}

local DAY_FIELDS = { "posted", "sold", "expired", "cancelled", "units", "soldFor", "cut", "received", "spent", "boughtUnits" }

-- What the client has answered this session, for "/tally debug". The counts
-- show whether the owned list and the created event arrive at all; postings
-- come from the list alone, since that is the one path every client has.
local auctionAnswers = {
	show = 0, owned = 0, created = 0,
	snapshotRows = 0, seeded = false, lastError = nil,
}

-- Set once the one-time sale-payment repair has run; the function itself is
-- defined with the reports and called from here, at login and when a page is
-- first drawn.
local repairedSales = false
local RepairSaleCategories

local function Now()
	return ns.Now and ns.Now() or time()
end

-- The day key the ledger's own daily buckets use.
local function DayKey(at)
	return date("%Y-%m-%d", at or time())
end

-- A message matched against a client format string, returning the captured
-- item name. Used for the expired and cancelled mail, which carry no invoice.
local function MatchFormat(message, format)
	if type(message) ~= "string" or type(format) ~= "string" then
		return nil
	end
	local pattern = format:gsub("([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
	pattern = pattern:gsub("%%%d%$s", "(.+)"):gsub("%%%d%$d", "(%d+)")
	pattern = pattern:gsub("%%s", "(.+)"):gsub("%%d", "(%d+)")
	local found, _, capture = message:find("^"..pattern.."$")
	return found and capture or nil
end

-- A returned-auction subject appends the stack size: "Yellow Housing Dye
-- (2)". The name is the part before it, and the number is the quantity, so a
-- returned stack keeps its true count and its item colour.
local function ReturnedName(value, units)
	if type(value) ~= "string" then
		return value, units or 1
	end
	local base, count = value:match("^(.-)%s+%((%d+)%)$")
	if base then
		return base, math.max(units or 1, tonumber(count) or 1)
	end
	return value, units or 1
end

-------------------------------------------------------------------------------
-- Storage
-------------------------------------------------------------------------------

-- The character's auction record, created on first use: characters saved
-- before this existed simply gain it the first time they post or sell.
local function EnsureAuction(char)
	if type(char) ~= "table" then
		return nil
	end
	local ah = char.ah
	if type(ah) ~= "table" then
		ah = {}
		char.ah = ah
	end
	if type(ah.days) ~= "table" then
		ah.days = {}
	end
	if type(ah.items) ~= "table" then
		ah.items = {}
	end
	if type(ah.recent) ~= "table" then
		ah.recent = {}
	end
	if type(ah.buys) ~= "table" then
		ah.buys = {}
	end
	if type(ah.live) ~= "table" then
		ah.live = {}
	end
	if type(ah.live.rows) ~= "table" then
		ah.live.rows = {}
	end
	return ah
end

local function DayBucket(ah, at)
	local key = DayKey(at)
	local day = ah.days[key]
	if not day then
		day = {}
		ah.days[key] = day
		-- The oldest day goes once the cap is passed; the key is a date, so
		-- a plain string sort is a date sort.
		local keys = {}
		for dayKey in pairs(ah.days) do
			keys[#keys + 1] = dayKey
		end
		if #keys > CAPS.days then
			table.sort(keys)
			for index = 1, #keys - CAPS.days do
				ah.days[keys[index]] = nil
			end
		end
	end
	for index = 1, #DAY_FIELDS do
		local field = DAY_FIELDS[index]
		if day[field] == nil then
			day[field] = 0
		end
	end
	return day
end

local function ItemRow(ah, name, itemID, quality, at)
	if type(name) ~= "string" or name == "" then
		name = "?"
	end
	local row = ah.items[name]
	if not row then
		row = {
			name = name, id = itemID, quality = quality,
			units = 0, sales = 0, income = 0, cut = 0, deposit = 0, received = 0,
			cost = 0, bought = 0,
		}
		ah.items[name] = row
	end
	if itemID and not row.id then
		row.id = itemID
	end
	if quality and row.quality == nil then
		row.quality = quality
	end
	if at then
		row.last = at
	end
	return row
end

-- Date-based, not count-based: a row is kept while its last sale, purchase or
-- posting falls inside the activity window. The window ends at the event being
-- written, so a break in play does not shorten it, and no number of distinct
-- items can push another out.
local function PruneItems(ah, at)
	local cutoff = (at or Now()) - CAPS.itemDays * 86400
	for name, row in pairs(ah.items or {}) do
		local last = row.last or row.bestAt
		if last and last < cutoff then
			ah.items[name] = nil
		end
	end
end

-- Newest first, so the recent list reads like the other logs. The list is
-- kept by date, not by count: everything within the activity window stays,
-- however many events there were, and nothing newer is ever pushed out by
-- old rows.
local function PushRecent(ah, entry)
	table.insert(ah.recent, 1, entry)
	local newest = entry.at or Now()
	local cutoff = newest - CAPS.recentDays * 86400
	while #ah.recent > 0 and (ah.recent[#ah.recent].at or 0) < cutoff do
		table.remove(ah.recent)
	end
end

-------------------------------------------------------------------------------
-- Recording
-------------------------------------------------------------------------------

local function Touch()
	if ns.OnDataTick then
		ns.OnDataTick()
	end
end

local function RecordPosted(ah, at, name, quality, units, bid, buyout, itemID)
	ah.posted = (ah.posted or 0) + 1
	local day = DayBucket(ah, at)
	day.posted = day.posted + 1
	-- The posting is often the only moment the item's own id and quality are
	-- stated: the sale invoice that follows may name the item but carry
	-- neither. Keeping them on the item's row now is what lets the sold row,
	-- the top list and the best-sale box keep the item's colour later.
	if name and name ~= "?" then
		ItemRow(ah, name, itemID, quality, at)
		PruneItems(ah, at)
	end
	PushRecent(ah, {
		kind = "posted", at = at, name = name, quality = quality,
		units = units or 1, price = bid, buyout = buyout, id = itemID,
	})
end

local function RecordSale(ah, at, name, quality, units, price, cut, deposit, net)
	units = math.max(1, units or 1)
	price = price or 0
	cut = cut or 0
	deposit = deposit or 0
	net = net or (price + deposit - cut)
	ah.sold = (ah.sold or 0) + 1
	if ns.NoteMilestoneFirst then
		ns.NoteMilestoneFirst("auctionSale", { name = name, at = at })
	end
	ah.units = (ah.units or 0) + units
	ah.soldFor = (ah.soldFor or 0) + price
	ah.cut = (ah.cut or 0) + cut
	ah.received = (ah.received or 0) + net
	local day = DayBucket(ah, at)
	day.sold = day.sold + 1
	day.units = day.units + units
	day.soldFor = day.soldFor + price
	day.cut = day.cut + cut
	day.received = day.received + net
	local row = ItemRow(ah, name, nil, quality, at)
	row.units = row.units + units
	row.sales = row.sales + 1
	row.income = row.income + price
	row.cut = row.cut + cut
	row.deposit = row.deposit + deposit
	row.received = row.received + net
	-- The price of one item in this sale, so the hover can state the range
	-- of what the item actually fetched rather than only a total.
	local unitPrice = units > 0 and (price / units) or 0
	if row.unitMin == nil or unitPrice < row.unitMin then
		row.unitMin = unitPrice
	end
	if row.unitMax == nil or unitPrice > row.unitMax then
		row.unitMax = unitPrice
	end
	row.unitCount = (row.unitCount or 0) + 1
	if not row.best or price > row.best then
		row.best = price
		row.bestAt = at
	end
	PushRecent(ah, {
		kind = "sold", at = at, name = name, quality = quality,
		units = units, price = price, cut = cut, deposit = deposit, net = net,
	})
	if not ah.best or price > (ah.best.price or 0) then
		ah.best = {
			name = row.name, quality = row.quality, price = price, at = at, id = row.id,
			units = units, cut = cut, deposit = deposit, net = net,
		}
		if ns.NoteRecord then
			ns.NoteRecord("auction.bestSale", price, at)
		end
	end
	if ns.NoteRecentEvent then
		ns.NoteRecentEvent("auction", {
			at = at, how = "auction_sale", evidence = "auction_invoice",
			data = { action = "sold", name = name, units = units, price = price, net = net },
		})
	end
	PruneItems(ah, at)
end

local function RecordUnsold(ah, at, kind, name, quality, units, buyout)
	ah[kind] = (ah[kind] or 0) + 1
	local day = DayBucket(ah, at)
	day[kind] = day[kind] + 1
	if buyout and buyout > 0 then
		day.unsoldValue = (day.unsoldValue or 0) + buyout
	end
	PushRecent(ah, {
		kind = kind, at = at, name = name, quality = quality,
		units = units or 1, buyout = buyout,
	})
end

-- What the character paid for an item at the auction house. Read from the
-- buyer invoice when that mail is taken; the average unit cost is what the
-- profit column divides with, since a stack bought together can be sold in
-- parts. The purchase itself is kept too, so the page can list what was
-- bought as well as what it cost.
local function RecordPurchase(ah, at, name, quality, units, price, itemID)
	units = math.max(1, units or 1)
	price = price or 0
	if not quality and itemID then
		local _, _, found = ns.ItemInfo(itemID)
		quality = found
	end
	ah.spent = (ah.spent or 0) + price
	ah.boughtUnits = (ah.boughtUnits or 0) + units
	local day = DayBucket(ah, at)
	day.spent = day.spent + price
	day.boughtUnits = day.boughtUnits + units
	if not ah.bestBuy or price > (ah.bestBuy.price or 0) then
		ah.bestBuy = { name = name, quality = quality, price = price, at = at, units = units, id = itemID }
		if ns.NoteRecord then
			ns.NoteRecord("auction.bestBuy", price, at)
		end
	end
	if ns.NoteRecentEvent then
		ns.NoteRecentEvent("auction", {
			at = at, how = "auction_purchase", evidence = "auction_invoice",
			data = { action = "bought", name = name, units = units, price = price },
		})
	end
	if ns.NoteMilestoneFirst then
		ns.NoteMilestoneFirst("auctionBuy", { name = name, at = at })
	end
	local row = ItemRow(ah, name, itemID, quality, at)
	row.cost = (row.cost or 0) + price
	row.bought = (row.bought or 0) + units
	local buys = ah.buys
	if type(buys) ~= "table" then
		buys = {}
		ah.buys = buys
	end
	table.insert(buys, 1, {
		at = at, name = name, quality = quality,
		units = units, price = price, id = itemID,
	})
	while #buys > 0 and (buys[#buys].at or 0) < at - CAPS.buyDays * 86400 do
		table.remove(buys)
	end
	PruneItems(ah, at)
end

-------------------------------------------------------------------------------
-- Postings
-------------------------------------------------------------------------------

-- A posting is counted from the owned list, not from the PostItem call: the
-- list is the one source every client provides, it states the quantity and the
-- prices as the auction house accepted them, and counting the PostItem call as
-- well recorded every auction twice.

-------------------------------------------------------------------------------
-- Mail
-------------------------------------------------------------------------------

-- The invoices found in the mailScan at the last scan, by mail index. A take is
-- read against this before the client moves the mail, so the sale is named
-- even when the mail itself is gone a moment later.
local mailScan = {}

-- The attachment's item id, read while the mail is still in the mailScan. A
-- buyer invoice names its item but carries no id, and the id is what makes a
-- tooltip reliable: the client's own spelling of the name may differ in a
-- capital or an apostrophe. The second and fifth returns are where the
-- clients seen so far put the id; the one the client can name is the item.
local function AttachmentID(index, wantName)
	if type(GetInboxItem) ~= "function" or type(ns.ItemInfo) ~= "function" then
		return nil
	end
	local ok, _, second, _, _, fifth = pcall(GetInboxItem, index, 1)
	if not ok then
		return nil
	end
	for _, candidate in ipairs({ second, fifth }) do
		if type(candidate) == "number" and candidate > 0 then
			local itemName = ns.ItemInfo(candidate)
			if type(itemName) == "string"
				and (not wantName or itemName:lower() == wantName:lower()) then
				return candidate
			end
		end
	end
	return nil
end

local function ScanInbox()
	mailScan = {}
	if type(GetInboxNumItems) ~= "function" or type(GetInboxInvoiceInfo) ~= "function" then
		return
	end
	local okCount, count = pcall(GetInboxNumItems)
	if not okCount or type(count) ~= "number" then
		return
	end
	for index = 1, count do
		local okInvoice, kind, itemName, _, bid, buyout, deposit, consignment, _, _, _, units =
			pcall(GetInboxInvoiceInfo, index)
		if okInvoice and kind == "seller" then
			-- The money actually in the mail, which is not always the same as
			-- the invoice's arithmetic: the deposit refund can arrive as its
			-- own payment, separately from the sale. The ledger books what
			-- arrives, so that is what the tag must name.
			local okHeader, _, _, _, _, money = pcall(GetInboxHeaderInfo, index)
			mailScan[index] = {
				kind = "sold", name = itemName, price = bid, buyout = buyout,
				deposit = deposit, cut = consignment, units = units,
				money = (okHeader and type(money) == "number" and money > 0) and money or nil,
			}
		elseif okInvoice and kind == "buyer" then
			mailScan[index] = {
				kind = "bought", name = itemName, price = bid, units = units,
				id = AttachmentID(index, itemName),
			}
		else
			-- No invoice: a returned auction names its item in the subject.
			local okHeader, _, _, _, subject = pcall(GetInboxHeaderInfo, index)
			if okHeader and type(subject) == "string" then
				local returned, count = ReturnedName(MatchFormat(subject, AUCTION_EXPIRED_MAIL_SUBJECT))
				if returned then
					mailScan[index] = { kind = "expired", name = returned, units = count }
				else
					returned, count = ReturnedName(MatchFormat(subject, AUCTION_REMOVED_MAIL_SUBJECT))
					if returned then
						mailScan[index] = { kind = "cancelled", name = returned, units = count }
					end
				end
			end
		end
	end
end

-- Reads one taken mail. The mailScan entry is consumed so a second take of the
-- same index cannot count the same auction twice.
local function TakeMail(index)
	local entry = mailScan[index]
	if not entry then
		return
	end
	mailScan[index] = nil
	local char = ns.GetChar()
	if not char or not ns.Tracks("economy") then
		return
	end
	local ah = EnsureAuction(char)
	if not ah then
		return
	end
	local at = Now()
	if entry.kind == "sold" then
		local net = (entry.price or 0) + (entry.deposit or 0) - (entry.cut or 0)
		RecordSale(ah, at, entry.name, nil, entry.units, entry.price, entry.cut, entry.deposit, net)
		-- Names the money the ledger is about to book: it arrives at the
		-- mailbox, so it would otherwise be filed as mail. The mail's own
		-- figure is used when it has one, because the deposit refund can
		-- arrive separately and the invoice's arithmetic would not match what
		-- the ledger sees.
		ns.ahSaleAmount = entry.money or net
		ns.ahSaleUntil = at + CAPS.saleWindow
	elseif entry.kind == "bought" then
		RecordPurchase(ah, at, entry.name, nil, entry.units, entry.price, entry.id)
	elseif entry.kind == "expired" or entry.kind == "cancelled" then
		RecordUnsold(ah, at, entry.kind, entry.name, nil, entry.units or 1, nil)
	end
	Touch()
end

-------------------------------------------------------------------------------
-- Live auctions
-------------------------------------------------------------------------------

local liveByID = {}
-- Every auction id already counted as a posting this session, so a list read
-- again cannot count the same auction twice.
local countedIDs = {}
-- Ids the game said it created this session, even if the owned list had not
-- answered yet. Such an auction must be counted when the first list arrives.
local createdIDs = {}

-- The classic owner list, for a client that never exposed C_AuctionHouse. It
-- has no auction ids, so a posting is a row whose signature (name, quantity
-- and prices) occurs more often than it did in the previous list.
local previousSignatures = {}

-- The live snapshot. An empty answer is not an empty auction house: the game
-- clears its own owner list while it asks for a fresh one, so an empty answer
-- that closely follows a real one is treated as a blink and the real list is
-- kept. A longer gap means the player really has nothing up.
local function StoreLive(ah, at, rows)
	local live = ah.live
	if #rows == 0 and type(live) == "table" and live.at and at - live.at < CAPS.liveHold then
		return
	end
	ah.live = { at = at, count = #rows, rows = rows }
	while #ah.live.rows > CAPS.live do
		table.remove(ah.live.rows)
	end
end

-- The one-time repair for posting counts written before the owner-list fix.
-- It waits until a live list has been read, because the auctions still up are
-- half of the accounting; /tally auctions repair does the same on demand.
local function RepairOldPostings()
	if not ns.db or (ns.db.auctionPostingNote or 0) >= 1 then
		return
	end
	ns.db.auctionPostingNote = 1
	local removed = 0
	for _, record in pairs(ns.db.chars or {}) do
		if ns.RepairAuctionPostings then
			removed = removed + ns.RepairAuctionPostings(record)
		end
	end
	if removed > 0 then
		ns.Trace("auction postings: "..removed.." duplicate readings removed")
		if ns.OnDataTick then
			ns.OnDataTick()
		end
	end
end

local function SnapshotClassicOwned()
	if type(GetNumAuctionItems) ~= "function" or type(GetAuctionItemInfo) ~= "function" then
		return
	end
	local okTotal, total = pcall(GetNumAuctionItems, "owner")
	if not okTotal or type(total) ~= "number" then
		return
	end
	local char = ns.GetChar()
	if not char or not ns.Tracks("economy") then
		return
	end
	local ah = EnsureAuction(char)
	if not ah then
		return
	end
	-- The list saved at logout is the baseline for the first list of the
	-- session, so an auction posted since then is counted rather than
	-- mistaken for one that was up long ago.
	if not auctionAnswers.seeded and type(ah.live) == "table"
		and #(ah.live.rows or {}) > 0
		and Now() - (ah.live.at or 0) <= CAPS.baseline then
		for index = 1, #ah.live.rows do
			local row = ah.live.rows[index]
			local sig = row.sig
			if not sig and row.name then
				sig = row.name.."|"..tostring(row.units).."|"..tostring(row.buyout).."|"..tostring(row.bid)
			end
			if sig then
				previousSignatures[sig] = (previousSignatures[sig] or 0) + 1
			end
		end
		auctionAnswers.seeded = true
	end
	local rows, counts = {}, {}
	for index = 1, total do
		local okRow, name, _, units, quality, _, _, _, _, _, buyout, bid, _, _, _, _, saleStatus =
			pcall(GetAuctionItemInfo, "owner", index)
		if okRow and type(name) == "string" then
			local band
			if type(GetAuctionItemTimeLeft) == "function" then
				local okLeft, value = pcall(GetAuctionItemTimeLeft, "owner", index)
				if okLeft and type(value) == "number" then
					band = value
				end
			end
			local signature = name.."|"..tostring(units).."|"..tostring(buyout).."|"..tostring(bid)
			rows[#rows + 1] = {
				name = name, quality = quality, units = units,
				bid = bid, buyout = buyout, band = band,
				sold = (saleStatus == 1) or nil, sig = signature,
			}
			counts[signature] = (counts[signature] or 0) + 1
		end
	end
	local at = Now()
	if not auctionAnswers.seeded then
		-- No saved list means nothing was up at logout. If the game said it
		-- created an auction this session, the rows are new and are counted;
		-- otherwise they only seed, since they may predate Tally. An empty
		-- list seeds nothing, because the game answers with nothing until its
		-- own Auctions tab has been opened once.
		if #rows > 0 then
			auctionAnswers.seeded = true
			if (ah.live.count or 0) == 0 and auctionAnswers.created > 0 then
				for index = 1, #rows do
					local row = rows[index]
					RecordPosted(ah, at, row.name, row.quality, row.units, row.bid, row.buyout)
				end
			end
		end
	else
		for index = 1, #rows do
			local row = rows[index]
			local before = previousSignatures[row.sig] or 0
			if before > 0 then
				previousSignatures[row.sig] = before - 1
			else
				RecordPosted(ah, at, row.name, row.quality, row.units, row.bid, row.buyout)
			end
		end
	end
	-- An empty answer is not an empty auction house: the client clears its
	-- owner list while it asks for a fresh one, and treating that as "all
	-- gone" made the next answer look like a list of new postings. The
	-- baseline is only replaced by a list that actually holds something.
	if #rows > 0 then
		previousSignatures = counts
	end
	StoreLive(ah, at, rows)
	if #rows > 0 then
		RepairOldPostings()
	end
	Touch()
end

local function SnapshotLive()
	local char = ns.GetChar()
	if not char or not ns.Tracks("economy") then
		return
	end
	if type(C_AuctionHouse) ~= "table" or type(C_AuctionHouse.GetOwnedAuctions) ~= "function" then
		SnapshotClassicOwned()
		return
	end
	local ok, list = pcall(C_AuctionHouse.GetOwnedAuctions)
	if not ok or type(list) ~= "table" then
		if not ok then
			auctionAnswers.lastError = "GetOwnedAuctions: "..tostring(list)
		end
		return
	end
	local ah = EnsureAuction(char)
	if not ah then
		return
	end
	-- The list saved at logout is the baseline for the first list of the
	-- session, so an auction posted since then counts instead of being
	-- mistaken for one that was up long ago.
	if not auctionAnswers.seeded and type(ah.live) == "table"
		and #(ah.live.rows or {}) > 0
		and Now() - (ah.live.at or 0) <= CAPS.baseline then
		for index = 1, #ah.live.rows do
			local row = ah.live.rows[index]
			if row.id then
				countedIDs[row.id] = true
			end
		end
		auctionAnswers.seeded = true
	end
	local previous = liveByID
	local rows = {}
	local byID = {}
	for index = 1, #list do
		local info = list[index]
		if type(info) == "table" then
			local itemID = info.itemKey and info.itemKey.itemID
			local name, _, quality
			if itemID then
				name, _, quality = ns.ItemInfo(itemID)
			end
			if not name and type(info.itemLink) == "string" then
				name = info.itemLink:match("%[(.-)%]")
			end
			local row = {
				-- The auction id identifies the posting; the item id identifies
				-- the thing being sold. They are not interchangeable: saving
				-- the auction id as the item id made every hover and every
				-- record point at a non-existent item.
				id = info.auctionID,
				itemID = itemID,
				name = name, quality = quality,
				units = info.quantity,
				bid = info.bidAmount, buyout = info.buyoutAmount,
				left = info.timeLeftSeconds,
				sold = (Enum and Enum.AuctionStatus and info.status == Enum.AuctionStatus.Sold) or info.status == 1 or nil,
			}
			rows[#rows + 1] = row
			if row.id then
				byID[row.id] = row
			end
		end
	end
	auctionAnswers.snapshotRows = #rows

	-- A posting shows up here as an auction id that was not in the previous
	-- list, and it is the only source: the created event gives an id and
	-- nothing else, and counting both recorded every auction twice. An id the
	-- game created this session counts even on the first list, which is what
	-- happens when an auction is posted before the list first answers.
	local at = Now()
	if not auctionAnswers.seeded then
		if #rows > 0 then
			auctionAnswers.seeded = true
			for index = 1, #rows do
				local row = rows[index]
				if row.id then
					countedIDs[row.id] = true
					if createdIDs[row.id] then
						createdIDs[row.id] = nil
						RecordPosted(ah, at, row.name, row.quality, row.units, row.bid, row.buyout, row.itemID)
					end
				end
			end
		end
	else
		for index = 1, #rows do
			local row = rows[index]
			if row.id and not previous[row.id] and not countedIDs[row.id] then
				countedIDs[row.id] = true
				RecordPosted(ah, at, row.name, row.quality, row.units, row.bid, row.buyout, row.itemID)
			end
		end
	end

	StoreLive(ah, at, rows)
	-- The same rule as the classic path: an empty answer does not mean the
	-- player's auctions are gone, so the id map is kept until a real list
	-- replaces it.
	if #rows > 0 then
		liveByID = byID
		RepairOldPostings()
	end
	Touch()
end

local function ClearLive(id)
	local char = ns.GetChar()
	local ah = char and char.ah
	local rows = ah and ah.live and ah.live.rows or {}
	for index = #rows, 1, -1 do
		if rows[index].id == id then
			table.remove(rows, index)
			break
		end
	end
	liveByID[id] = nil
	if ah and ah.live and ah.live.count and ah.live.count > 0 then
		ah.live.count = ah.live.count - 1
	end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local function OnAuctionCreated(auctionID)
	auctionAnswers.created = auctionAnswers.created + 1
	if auctionID then
		createdIDs[auctionID] = true
	end
	-- Counted from the owned list: this event carries only an id, and counting
	-- it alone recorded every posting twice. The id is kept so the first list
	-- of the session can tell a just-posted auction from an old one.
	ns.Trace("auction created "..tostring(auctionID).." (counted from the owned list)")
end

local function OnAuctionEnded(auctionID)
	-- Only the live list is adjusted here. The expired or cancelled mail is
	-- the record of the event itself, and it is counted when it is collected,
	-- so counting the event as well would count the auction twice.
	ClearLive(auctionID)
	Touch()
end

local function QueryOwned()
	if type(C_AuctionHouse) ~= "table" or type(C_AuctionHouse.QueryOwnedAuctions) ~= "function" then
		return
	end
	local sortOrder = (Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Buyout) or 4
	local ok, err = pcall(C_AuctionHouse.QueryOwnedAuctions, { { sortOrder = sortOrder, reverseSort = false } })
	if not ok then
		auctionAnswers.lastError = "QueryOwnedAuctions: "..tostring(err)
	end
end

-- The owned list can answer a moment after the auction house opens, and on
-- some clients it answers only once its own Auctions tab has been shown. A
-- few retries cover both without a timer library this client lacks.
local retryFrame = CreateFrame("Frame")
local retryLeft, retryIn = 0, 0
local function StartRetries()
	retryLeft, retryIn = 5, 0.5
end

-- A second way in, for the case where the show event was missed: while the
-- client's auction house window is open, ask for the owned list again every
-- few seconds. It costs one call and keeps the snapshot from going stale on a
-- client that does not raise the event.
local lastPoll = 0

-- The client's own window is another way in, for a client that never raises
-- the show event: hooking its OnShow is the same signal. It does not exist
-- until the client loads its auction house addon, so this is tried whenever
-- that addon appears and again from the poll below.
local frameHooked = false
local function HookAuctionFrame()
	if frameHooked or type(AuctionHouseFrame) ~= "table" then
		return
	end
	if type(AuctionHouseFrame.HookScript) ~= "function" then
		return
	end
	frameHooked = true
	pcall(AuctionHouseFrame.HookScript, AuctionHouseFrame, "OnShow", function()
		auctionAnswers.show = auctionAnswers.show + 1
		QueryOwned()
		SnapshotLive()
		StartRetries()
	end)
end

function ns.AuctionPollLive()
	HookAuctionFrame()
	local shown = type(AuctionHouseFrame) == "table" and AuctionHouseFrame.IsShown
		and AuctionHouseFrame:IsShown()
	if not shown then
		return
	end
	if Now() - lastPoll < 5 then
		return
	end
	lastPoll = Now()
	QueryOwned()
	SnapshotLive()
end
retryFrame:SetScript("OnUpdate", function(_, elapsed)
	if retryLeft <= 0 then
		return
	end
	retryIn = retryIn - (elapsed or 0)
	if retryIn > 0 then
		return
	end
	retryLeft = retryLeft - 1
	retryIn = 1.5
	QueryOwned()
	SnapshotLive()
end)

local function HandleEvent(event, ...)
	if event == "ADDON_LOADED" then
		if (...) == "Blizzard_AuctionHouseUI" then
			HookAuctionFrame()
		end
	elseif event == "PLAYER_ENTERING_WORLD" then
		if not repairedSales and RepairSaleCategories then
			local ok, done = pcall(RepairSaleCategories)
			if ok and done then
				repairedSales = true
			end
		end
	elseif event == "AUCTION_HOUSE_SHOW" then
		auctionAnswers.show = auctionAnswers.show + 1
		QueryOwned()
		SnapshotLive()
		StartRetries()
	elseif event == "AUCTION_HOUSE_CLOSED" then
		retryLeft = 0
	elseif event == "OWNED_AUCTIONS_UPDATED" then
		auctionAnswers.owned = auctionAnswers.owned + 1
		SnapshotLive()
	elseif event == "AUCTION_OWNED_LIST_UPDATE" or event == "AUCTION_ITEM_LIST_UPDATE" then
		auctionAnswers.owned = auctionAnswers.owned + 1
		SnapshotLive()
	elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
		OnAuctionCreated(...)
	elseif event == "AUCTION_HOUSE_AUCTIONS_EXPIRED" then
		OnAuctionEnded(...)
	elseif event == "AUCTION_CANCELED" then
		OnAuctionEnded(...)
	elseif event == "MAIL_SHOW" or event == "MAIL_INBOX_UPDATE" then
		ScanInbox()
	elseif event == "MAIL_CLOSED" then
		mailScan = {}
	end
end

-- Keep the auction file's own error field: the registrar isolates a failed
-- handler too, but this is where /tally debug reads the last auction error.
local function AuctionHandler(event, ...)
	local ok, err = pcall(HandleEvent, event, ...)
	if not ok then
		auctionAnswers.lastError = tostring(event)..": "..tostring(err)
		ns.Trace("auction event "..tostring(event).." failed: "..tostring(err))
	end
end

local EVENTS = {
	"ADDON_LOADED",
	"PLAYER_ENTERING_WORLD",
	"AUCTION_HOUSE_SHOW",
	"AUCTION_HOUSE_CLOSED",
	"OWNED_AUCTIONS_UPDATED",
	"AUCTION_HOUSE_AUCTION_CREATED",
	"AUCTION_HOUSE_AUCTIONS_EXPIRED",
	"AUCTION_CANCELED",
	"AUCTION_OWNED_LIST_UPDATE",
	"AUCTION_ITEM_LIST_UPDATE",
	"MAIL_SHOW",
	"MAIL_INBOX_UPDATE",
	"MAIL_CLOSED",
}

function ns.RegisterAuctionEvents()
	for index = 1, #EVENTS do
		ns.On(EVENTS[index], AuctionHandler, "Auction")
	end
end

-------------------------------------------------------------------------------
-- Hooks
-------------------------------------------------------------------------------

local function InstallHooks()
	for _, name in ipairs({ "TakeInboxItem", "TakeInboxMoney", "AutoLootMailItem" }) do
		if type(_G[name]) == "function" then
			pcall(hooksecurefunc, name, function(index)
				local ok, err = pcall(TakeMail, index)
				if not ok then
					auctionAnswers.lastError = name..": "..tostring(err)
				end
			end)
		end
	end
end

-------------------------------------------------------------------------------
-- Reports
-------------------------------------------------------------------------------

local EMPTY = {
	posted = 0, sold = 0, expired = 0, cancelled = 0,
	units = 0, soldFor = 0, cut = 0, received = 0,
	spent = 0, boughtUnits = 0,
}

-- Sales collected before the mail's own figure was used were filed by the
-- ledger as mail. Several of them often arrive in one payment, because the
-- balance is sampled and a run of mail clicks merges into a single change, so
-- they cannot be matched one sale at a time. This compares the money Tally
-- recorded as received for sales with the money already labelled auction, and
-- moves the difference out of mail - but only by finding a mail payment of
-- that size (within a small tolerance), so the amount moved is one the ledger
-- really booked and nothing is invented. It changes only the label and the two
-- category sums; the total is untouched.
RepairSaleCategories = function()
	local char = ns.GetChar()
	local ah = char and char.ah
	local gold = char and char.gold
	if not ah or not gold or type(gold.tx) ~= "table" or type(gold.income) ~= "table" then
		-- The character is not ready yet (the login event can arrive before
		-- the saved record is bound); the caller must try again later.
		return false
	end
	for _ = 1, 3 do
		local expected = (ah.received or 0) - (gold.income.auction or 0)
		if expected <= 0 then
			return true
		end
		local tolerance = math.max(100, math.min(20000, math.floor(expected / 200)))
		local best, bestDiff
		for index = #gold.tx, 1, -1 do
			local tx = gold.tx[index]
			if tx.c == "mail" and (tx.d or 0) > 0 then
				local diff = math.abs(tx.d - expected)
				if diff <= tolerance and (not bestDiff or diff < bestDiff) then
					best, bestDiff = tx, diff
				end
			end
		end
		if not best or (gold.income.mail or 0) < best.d then
			ns.Trace("auction: no mail payment near "..ns.FormatMoneyPlain(expected).." to relabel")
			return true
		end
		best.c = "auction"
		gold.income.mail = gold.income.mail - best.d
		gold.income.auction = (gold.income.auction or 0) + best.d
		ns.Trace("auction: moved "..ns.FormatMoneyPlain(best.d).." of sale money from mail to auction")
	end
	return true
end

-- The character's totals over a period: 0 or nil means everything stored;
-- any other number means that many calendar days, ending at `anchor` (the
-- latest auction event) rather than at the clock, so a break in play does not
-- shorten the window. "Today" is passed the clock by the caller.
local function PeriodTotals(ah, days, anchor)
	local totals = {}
	for field, value in pairs(EMPTY) do
		totals[field] = ah[field] or value
	end
	if not days or days <= 0 or not ah.days then
		return totals
	end
	for field in pairs(EMPTY) do
		totals[field] = 0
	end
	local cutoff = DayKey((anchor or Now()) - (days - 1) * 86400)
	for key, day in pairs(ah.days) do
		if key >= cutoff then
			for field in pairs(EMPTY) do
				totals[field] = totals[field] + (day[field] or 0)
			end
		end
	end
	return totals
end

-- The figures for one or more characters. `list` comes from the page: one
-- entry for the character being shown, or every ticked character for the
-- combined view. Rows that belong to a character carry its name and class so
-- the combined list can say whose auction it was.
function ns.AuctionReport(list, days)
	if not repairedSales then
		local ok, done = pcall(RepairSaleCategories)
		if ok and done then
			repairedSales = true
		elseif not ok then
			ns.Trace("auction: sale repair failed: "..tostring(done))
		end
	end
	local report = {
		totals = { posted = 0, sold = 0, expired = 0, cancelled = 0, units = 0, soldFor = 0, cut = 0, received = 0, spent = 0, boughtUnits = 0 },
		items = {}, recent = {}, buys = {}, live = {},
		liveAt = 0, liveCount = 0, liveUnlisted = 0, chars = 0,
	}
	local now = Now()
	local seen = {}
	list = list or {}
	-- The day ranges end at the latest auction event across the characters
	-- being read, not at the clock: a player back after three days still sees
	-- the last seven days of activity. "Today" alone stays the calendar day.
	local anchor = 0
	for index = 1, #list do
		local record = list[index].char
		local ah = record and record.ah
		local recent = ah and ah.recent
		local newest = recent and recent[1] and recent[1].at
		local buy = ah and ah.buys and ah.buys[1]
		if buy and (not newest or (buy.at or 0) > newest) then
			newest = buy.at
		end
		if newest and newest > anchor then
			anchor = newest
		end
	end
	if anchor <= 0 then
		anchor = now
	end
	-- One quality map for the whole report: a name seen on any ticked
	-- character's posting or item row colours it everywhere, so a combined
	-- view cannot show the same item blue in one row and white in another.
	local hints = {}
	-- What the player is carrying is the one place an item the mail only
	-- named can still be resolved, even when the cache will not answer by
	-- name. Bags are read once per report.
	local bagItems = ns.BagItemIndex and ns.BagItemIndex() or nil
	if bagItems then
		for itemName, info in pairs(bagItems) do
			hints[itemName] = { quality = info.quality, id = info.id }
		end
	end
	for index = 1, #list do
		local ah = list[index].char and list[index].char.ah
		if ah then
			for itemName, row in pairs(ah.items or {}) do
				if row.quality ~= nil or row.id then
					local hint = hints[itemName]
					if not hint then
						hint = {}
						hints[itemName] = hint
					end
					if hint.quality == nil then
						hint.quality = row.quality
					end
					if hint.id == nil then
						hint.id = row.id
					end
				end
			end
			for eventIndex = 1, #(ah.recent or {}) do
				local event = ah.recent[eventIndex]
				if event.kind == "posted" and event.name and event.name ~= "?" then
					local hint = hints[event.name]
					if not hint then
						hint = {}
						hints[event.name] = hint
					end
					if hint.quality == nil and event.quality ~= nil then
						hint.quality = event.quality
					end
					if hint.id == nil and event.id then
						hint.id = event.id
					end
				end
			end
		end
	end
	for index = 1, #list do
		local entry = list[index]
		local char = entry.char
		local ah = char and char.ah
		if ah then
			report.chars = report.chars + 1
			local totals = PeriodTotals(ah, days, days > 1 and anchor or now)
			for field in pairs(report.totals) do
				report.totals[field] = report.totals[field] + (totals[field] or 0)
			end
			local who = entry.name or ns.DisplayName(char)
			-- A profession book knows the item id behind a recipe's name, and
			-- an id is enough to ask the game for the quality. This reaches
			-- older sales whose postings have left the recent list.
			local professionIDs = {}
			local recipeBooks = char.professions and char.professions.recipes
			if type(recipeBooks) == "table" then
				for _, book in pairs(recipeBooks) do
					if type(book) == "table" and type(book.items) == "table" then
						for itemName, itemID in pairs(book.items) do
							if type(itemID) == "number" then
								professionIDs[itemName] = itemID
							end
						end
					end
				end
			end
			for name, row in pairs(ah.items or {}) do
				-- A posting also makes a row now, so its id and quality can
				-- survive to the sale. Rows that have never sold or been
				-- bought are not auctions the top list should show, and rows
				-- whose last activity falls outside the window are past it.
				local last = row.last or row.bestAt
				local inWindow = not last or last >= anchor - CAPS.itemDays * 86400
				if inWindow and ((row.sales or 0) > 0 or (row.bought or 0) > 0) then
					local hint = hints[name]
					local quality = row.quality
					local itemID = row.id
					if quality == nil and hint then
						quality = hint.quality
					end
					if itemID == nil and hint then
						itemID = hint.id
					end
					if itemID == nil then
						itemID = professionIDs[name]
					end
					if quality == nil and itemID then
						local _, _, found = ns.ItemInfo(itemID)
						quality = found
					end
					local merged = seen[name]
					if not merged then
						merged = { name = row.name, quality = quality, id = itemID,
							units = 0, sales = 0, income = 0, cut = 0, deposit = 0,
							received = 0, cost = 0, bought = 0, best = 0, bestAt = row.bestAt,
							unitMin = nil, unitMax = nil, unitKnown = 0 }
						seen[name] = merged
						report.items[#report.items + 1] = merged
					end
					merged.units = merged.units + (row.units or 0)
					merged.sales = merged.sales + (row.sales or 0)
					merged.income = merged.income + (row.income or 0)
					merged.cut = merged.cut + (row.cut or 0)
					merged.deposit = merged.deposit + (row.deposit or 0)
					merged.received = merged.received + (row.received or 0)
					merged.cost = merged.cost + (row.cost or 0)
					merged.bought = merged.bought + (row.bought or 0)
					-- The range of one item's price. A row with a single sale
					-- can state it exactly even when it predates the tracking;
					-- a row with several sales cannot be split, so its range is
					-- only what was recorded.
					local unitMin, unitMax = row.unitMin, row.unitMax
					local unitKnown = row.unitCount or 0
					if unitMin == nil and (row.sales or 0) == 1 and (row.units or 0) > 0 then
						unitMin = (row.income or 0) / row.units
						unitMax = unitMin
						unitKnown = 1
					end
					if unitMin and (merged.unitMin == nil or unitMin < merged.unitMin) then
						merged.unitMin = unitMin
					end
					if unitMax and (merged.unitMax == nil or unitMax > merged.unitMax) then
						merged.unitMax = unitMax
					end
					merged.unitKnown = merged.unitKnown + unitKnown
					if (row.best or 0) > (merged.best or 0) then
						merged.best = row.best
						merged.bestAt = row.bestAt
					end
					if merged.quality == nil then
						merged.quality = quality
					end
					if merged.id == nil then
						merged.id = itemID
					end
				end
			end
			if ah.best and (not report.best or (ah.best.price or 0) > (report.best.price or 0)) then
				local item = ah.items and ah.items[ah.best.name]
				local hint = hints[ah.best.name]
				local bestID = ah.best.id or (hint and hint.id) or professionIDs[ah.best.name]
				local bestQuality = ah.best.quality or (hint and hint.quality)
				if bestQuality == nil and bestID then
					local _, _, found = ns.ItemInfo(bestID)
					bestQuality = found
				end
				local units = ah.best.units
				local cut = ah.best.cut
				local deposit = ah.best.deposit
				local net = ah.best.net
				-- A best sale recorded before it kept these can borrow them
				-- from the item's row, but only when that row is one sale.
				if units == nil and item and (item.sales or 0) == 1 then
					units, cut, deposit, net = item.units, item.cut, item.deposit, item.received
				end
				report.best = {
					name = ah.best.name,
					quality = bestQuality,
					id = bestID,
					price = ah.best.price, at = ah.best.at, who = who,
					units = units, cut = cut, deposit = deposit, net = net,
				}
			end
			if ah.bestBuy and (not report.bestBuy or (ah.bestBuy.price or 0) > (report.bestBuy.price or 0)) then
				local hint = hints[ah.bestBuy.name]
				local buyID = ah.bestBuy.id or (hint and hint.id) or professionIDs[ah.bestBuy.name]
				local buyQuality = ah.bestBuy.quality or (hint and hint.quality)
				if buyQuality == nil and buyID then
					local _, _, found = ns.ItemInfo(buyID)
					buyQuality = found
				end
				report.bestBuy = {
					name = ah.bestBuy.name,
					quality = buyQuality,
					id = buyID,
					price = ah.bestBuy.price, at = ah.bestBuy.at, who = who,
					units = ah.bestBuy.units,
				}
			end
			for buyIndex = 1, #(ah.buys or {}) do
				local buy = ah.buys[buyIndex]
				if (buy.at or 0) >= anchor - CAPS.buyDays * 86400 then
					-- A purchase recorded before the id was read can still
					-- borrow one from the item's own row, when the same item
					-- was also sold and so carried an id.
					local sameItem = ah.items and ah.items[buy.name]
					local hint = buy.name and hints[buy.name]
					local buyID = buy.id or (sameItem and sameItem.id) or (hint and hint.id)
					local buyQuality = buy.quality or (sameItem and sameItem.quality) or (hint and hint.quality)
					if buyQuality == nil and buyID then
						local _, _, found = ns.ItemInfo(buyID)
						buyQuality = found
					end
					report.buys[#report.buys + 1] = {
						at = buy.at, name = buy.name,
						quality = buyQuality,
						units = buy.units, price = buy.price,
						id = buyID,
						who = who, classFile = char.classFile, key = entry.key,
					}
				end
			end
			local cutoff
			if days and days > 0 then
				cutoff = DayKey((days > 1 and anchor or now) - (days - 1) * 86400)
			end
			local soldSeen = {}
			for recentIndex = 1, #(ah.recent or {}) do
				local item = ah.recent[recentIndex]
				if not cutoff or DayKey(item.at) >= cutoff then
					-- An old posting could be written without a name when the
					-- owned list answered before the item reached the cache.
					-- Its id, when one was kept, can still name it now.
					local name = item.name
					local units = item.units
					if item.kind == "expired" or item.kind == "cancelled" then
						name, units = ReturnedName(name, units)
					end
					local quality = item.quality
					local itemID = item.id
					if itemID then
						if not name or name == "?" then
							name = ns.ItemInfo(itemID)
						end
						if quality == nil then
							local _, _, found = ns.ItemInfo(itemID)
							quality = found
						end
					end
					local hint = name and hints[name]
					if itemID == nil and hint and hint.id then
						itemID = hint.id
						if quality == nil then
							local _, _, found = ns.ItemInfo(itemID)
							quality = found
						end
					end
					if quality == nil and hint then
						quality = hint.quality
					end
					if quality == nil and name then
						local foundID = itemID or professionIDs[name]
						if foundID then
							local _, _, found = ns.ItemInfo(foundID)
							quality = found
						end
					end
					report.recent[#report.recent + 1] = {
						kind = item.kind, at = item.at, name = name, quality = quality,
						units = units, price = item.price, buyout = item.buyout,
						cut = item.cut, deposit = item.deposit, net = item.net, id = itemID,
						who = who, classFile = char.classFile, key = entry.key,
					}
					if item.kind == "sold" and name then
						soldSeen[name] = true
					end
				end
			end
			-- A sale older than the event list Tally used to keep is still in
			-- the item's own row when that row stands for exactly one sale, and
			-- the row states every field the event needs. Restore it, so the
			-- sold view and Top auctions describe the same sales.
			for itemName, row in pairs(ah.items or {}) do
				if (row.sales or 0) == 1 and row.bestAt and not soldSeen[itemName]
					and (not cutoff or DayKey(row.bestAt) >= cutoff) then
					local hint = hints[itemName]
					local quality = row.quality or (hint and hint.quality)
					local itemID = row.id or (hint and hint.id)
					if quality == nil and itemID then
						local _, _, found = ns.ItemInfo(itemID)
						quality = found
					end
					if quality == nil then
						local foundID = professionIDs[itemName]
						if foundID then
							local _, _, found = ns.ItemInfo(foundID)
							quality = found
						end
					end
					report.recent[#report.recent + 1] = {
						kind = "sold", at = row.bestAt, name = itemName, quality = quality,
						units = row.units, price = row.income, cut = row.cut,
						deposit = row.deposit, net = row.received, id = itemID,
						who = who, classFile = char.classFile, key = entry.key,
						restored = true,
					}
				end
			end
			local live = ah.live or {}
			local liveAt = live.at or 0
			report.liveAt = math.max(report.liveAt, liveAt)
			local liveRows = live.rows or {}
			local kept = 0
			for liveIndex = 1, #liveRows do
				local row = liveRows[liveIndex]
				-- A remaining time the game stated runs down from the moment
				-- the list was read; one that has run out is no longer up.
				-- The classic list states only a band, so those rows stay.
				local expiresAt = row.left and liveAt > 0 and (liveAt + row.left) or nil
				if not expiresAt or expiresAt > now then
					kept = kept + 1
					local hint = row.name and hints[row.name]
					report.live[#report.live + 1] = {
						name = row.name,
						quality = row.quality or (hint and hint.quality),
						id = row.id or (hint and hint.id),
						units = row.units,
						bid = row.bid, buyout = row.buyout, band = row.band,
						expiresAt = expiresAt, at = liveAt, sold = row.sold,
						who = who, classFile = char.classFile, key = entry.key,
					}
				end
			end
			-- Rows the snapshot had to drop at its cap are still up; they
			-- simply have no row to count down in.
			report.liveUnlisted = report.liveUnlisted + (live.count or #liveRows) - #liveRows
			report.liveCount = report.liveCount + kept
		end
	end
	table.sort(report.live, function(a, b)
		-- The auction nearest its end comes first, so the hover reads as a
		-- countdown; rows with only a band follow by name.
		if a.expiresAt and b.expiresAt then
			if a.expiresAt ~= b.expiresAt then
				return a.expiresAt < b.expiresAt
			end
		elseif a.expiresAt ~= b.expiresAt then
			return a.expiresAt ~= nil
		end
		return (a.name or "") < (b.name or "")
	end)
	table.sort(report.recent, function(a, b)
		return (a.at or 0) > (b.at or 0)
	end)
	table.sort(report.buys, function(a, b)
		return (a.at or 0) > (b.at or 0)
	end)
	return report
end

-------------------------------------------------------------------------------
-- Posting repair
-------------------------------------------------------------------------------

-- How many auctions a character can account for: every sale, expiry and
-- cancellation Tally read, plus the auctions its last owned list showed as
-- still up. Every auction that went up is one of those, so a posting count
-- above this one holds readings that were counted more than once - which is
-- what the owner list did before an empty answer stopped wiping the baseline.
-- Returns posted, accounted, stillUp.
function ns.AuctionPostingsAudit(char)
	local ah = char and char.ah
	if type(ah) ~= "table" then
		return 0, 0, 0
	end
	local live = ah.live or {}
	local liveAt = live.at or 0
	local now = Now()
	local up = 0
	local rows = live.rows or {}
	for index = 1, #rows do
		local row = rows[index]
		local expiresAt = row.left and liveAt > 0 and (liveAt + row.left) or nil
		if not expiresAt or expiresAt > now then
			up = up + 1
		end
	end
	-- Rows the snapshot dropped at its cap are still up, just not listed.
	up = up + math.max(0, (live.count or 0) - #rows)
	local accounted = (ah.sold or 0) + (ah.expired or 0) + (ah.cancelled or 0) + up
	return ah.posted or 0, accounted, up
end

-- Lowers the posting counts to what the character can account for, oldest day
-- first: the duplicate readings are the oldest. Nothing else is touched, so
-- sales, purchases and finds stay exactly as they are. Returns how many
-- postings were removed.
function ns.RepairAuctionPostings(char)
	local posted, accounted = ns.AuctionPostingsAudit(char)
	if type(char) ~= "table" or posted <= accounted then
		return 0
	end
	local ah = char.ah
	local excess = posted - accounted
	ah.posted = accounted
	local days = {}
	for key, day in pairs(ah.days or {}) do
		if (day.posted or 0) > 0 then
			days[#days + 1] = key
		end
	end
	table.sort(days)
	for index = 1, #days do
		if excess <= 0 then
			break
		end
		local day = ah.days[days[index]]
		local cut = math.min(day.posted, excess)
		day.posted = day.posted - cut
		excess = excess - cut
	end
	return posted - accounted
end

-------------------------------------------------------------------------------
-- Diagnostics
-------------------------------------------------------------------------------

-- Appends the auction block to "/tally debug". Kept to a handful of lines: the
-- figures this file keeps, and whether the client raised the events it needs.
-- Appends the auction block to the full diagnostic dump ("/tally trace").
-- `/tally debug` prints the one-line form below, since the chat line is what
-- the reader actually has to hand.
function ns.AuctionDebugText()
	local char = ns.GetChar()
	local ah = char and char.ah
	local text = string.format(
		"auctions: posted=%d, live=%d, buys=%d, show=%d, owned=%d, created=%d, rows=%d",
		(ah and ah.posted) or 0, (ah and ah.live and ah.live.count) or 0,
		(ah and ah.buys and #ah.buys) or 0,
		auctionAnswers.show, auctionAnswers.owned, auctionAnswers.created,
		auctionAnswers.snapshotRows)
	if auctionAnswers.lastError then
		text = text.." | error: "..tostring(auctionAnswers.lastError)
	end
	text = text.." | api: C_AuctionHouse="..type(C_AuctionHouse)
		..", GetNumAuctionItems="..type(GetNumAuctionItems)
		..", GetAuctionItemInfo="..type(GetAuctionItemInfo)
		..", GetAuctionItemTimeLeft="..type(GetAuctionItemTimeLeft)
		..", AuctionFrame="..type(AuctionFrame)
		..", AuctionHouseFrame="..type(AuctionHouseFrame)
	-- What the one-time sale-payment repair is looking at, so a card that
	-- still disagrees with the ledger can be traced in one line.
	local gold = char and char.gold
	local income = gold and gold.income or {}
	text = text.." | saleTag: need="..ns.FormatNumber((ah and ah.received or 0) - (income.auction or 0))
		..", mail="..ns.FormatNumber(income.mail or 0)..", auction="..ns.FormatNumber(income.auction or 0)
	return text
end

function ns.AuctionDebugLines(lines)
	local char = ns.GetChar()
	if not char then
		return
	end
	local ah = char.ah
	if not ah then
		lines[#lines + 1] = "auctions: nothing recorded yet"
		return
	end
	lines[#lines + 1] = string.format(
		"auctions: posted=%d, sold=%d, units=%d, received=%s, cut=%s, expired=%d, cancelled=%d, live=%d",
		ah.posted or 0, ah.sold or 0, ah.units or 0,
		ns.FormatMoneyDelta(ah.received or 0), ns.FormatMoneyDelta(ah.cut or 0),
		ah.expired or 0, ah.cancelled or 0, (ah.live and ah.live.count) or 0)
	local items, recent = 0, #(ah.recent or {})
	for _ in pairs(ah.items or {}) do
		items = items + 1
	end
	lines[#lines + 1] = string.format("auction rows: items=%d, recent=%d", items, recent)
	-- What the client answered this session. A zero here says which part of
	-- the chain the client is not giving us, which is otherwise invisible.
	lines[#lines + 1] = string.format(
		"auction events: show=%d, owned=%d, created=%d, snapshotRows=%d",
		auctionAnswers.show, auctionAnswers.owned, auctionAnswers.created, auctionAnswers.snapshotRows)
	local auctionApi = type(C_AuctionHouse) == "table"
	lines[#lines + 1] = string.format(
		"auction api: C_AuctionHouse=%s, GetOwnedAuctions=%s, QueryOwnedAuctions=%s, PostItem=%s, GetInboxInvoiceInfo=%s, TakeInboxMoney=%s",
		tostring(auctionApi),
		tostring(auctionApi and type(C_AuctionHouse.GetOwnedAuctions) == "function"),
		tostring(auctionApi and type(C_AuctionHouse.QueryOwnedAuctions) == "function"),
		tostring(auctionApi and type(C_AuctionHouse.PostItem) == "function"),
		tostring(type(GetInboxInvoiceInfo) == "function"),
		tostring(type(TakeInboxMoney) == "function"))
	if auctionAnswers.lastError then
		lines[#lines + 1] = "auction error: "..tostring(auctionAnswers.lastError)
	end
end

-- The record is bound a moment after login fires, and the reader may never
-- open a page that calls the report. This retries the repair every few
-- seconds until it has run, then stops asking.
local repairIn = 3
local repairFrame = CreateFrame("Frame")
repairFrame:SetScript("OnUpdate", function(_, elapsed)
	if repairedSales then
		return
	end
	repairIn = repairIn - (elapsed or 0)
	if repairIn > 0 then
		return
	end
	repairIn = 3
	local ok, done = pcall(RepairSaleCategories)
	if ok and done then
		repairedSales = true
	end
end)

ns.RegisterAuctionEvents()
InstallHooks()

-- Owner namespace. Every field references the flat auction API above;
-- ahSaleAmount and ahSaleUntil stay flat mutable flags for the money reader.
ns.auction = {}
ns.auction.RegisterEvents = ns.RegisterAuctionEvents
ns.auction.DebugLines = ns.AuctionDebugLines
ns.auction.DebugText = ns.AuctionDebugText
ns.auction.PollLive = ns.AuctionPollLive
ns.auction.PostingsAudit = ns.AuctionPostingsAudit
ns.auction.Report = ns.AuctionReport
ns.auction.RepairPostings = ns.RepairAuctionPostings
