-- Tally - buffs and debuffs: the once-a-second aura scan, the campfire
-- figures and the text the game gives for each aura.
--
-- One character subtree is owned here: char.auras. The ticker calls
-- ns.ScanAurasTick once a second; nothing else in Core reads the scan.
local addonName, ns = ...

local Now = ns.Now

-------------------------------------------------------------------------------
-- Buffs and debuffs
--
-- The section is wrapped in a do-block on purpose: this client refuses to load
-- a file whose main chunk declares more than 200 locals, and every name in
-- here is private to it, so the block hands them all back at its end.
-------------------------------------------------------------------------------

do
	-- Every buff and debuff the character has is sampled once a second while it is
	-- up, so the figures are watched time, never inferred: how many times an aura
	-- was gained, and how long it has run in total. Every aura name is retained.
	local AURA_SLOTS = 60
	-- Slots are read in order, but an empty one is not the end: this client
	-- answers nothing for a slot now and then while later slots still hold
	-- auras. Only this many empty slots in a row end the scan.
	local AURA_GAP = 6
	-- How many scans in a row an aura may be missing before it counts as gone.
	-- Without this, one hiccup in the client's list reads as losing the buff
	-- and gaining it again, which is how Find Herbs reached x18. Five seconds
	-- is well past a list being rebuilt (leaving combat, an instance change)
	-- and still quick enough that a real loss is noticed.
	local AURA_MISS = 5
	-- For buffs, a return counts as a new gain only when the aura was away
	-- for at least this long. The window is the aura's own duration - a buff
	-- cannot have really lapsed and been re-gained inside the time it was
	-- going to last - floored at five seconds and capped at five minutes, so
	-- a client that drops and re-applies a long buff is read as refreshing
	-- it rather than granting it afresh. This is what turned two Camp
	-- Benefits into fifty. Debuffs are different: each landing is an
	-- application, so a return or a refreshed expiration counts.
	local AURA_REFRESH_MIN = 5
	local AURA_REFRESH_MAX = 300
	-- A permanent aura (no duration and no expiration) cannot really lapse
	-- and come back in five seconds. Its reappearance counts as a new gain
	-- only after this long, or when a death happened since it was last seen
	-- and the player applied it again. This is what stops Find Minerals from
	-- being counted on every short gap in the client's aura list.
	local AURA_PERMANENT_AWAY = 300
	local aurasAnnounced = false
	local aurasScanFailed = false
	local scanStartedAt = 0

	-- The campfire figures come from the two auras the campfire system uses: the
	-- welcoming fire itself (whose time is the sitting time Tally can honestly
	-- claim) and Camp Benefits, the reward that lands when it settles. The name
	-- of the first one is read from the CampfireHangout addon when it is loaded,
	-- since that addon owns the name; this is the fallback.
	local CAMPFIRE_BUFF_FALLBACK = "welcoming campfire"
	local CAMP_BENEFITS = "camp benefits"

	-- Whether an aura API is available at all. C_UnitAuras is the documented one;
	-- UnitAura/UnitBuff/UnitDebuff are deprecated wrappers that this client may
	-- not install. Whichever answers first is used from then on.
	local auraReader
	local auraReaderTested = false
	local auraUnusable = false

	-- True for a value that can be used: a string the client has not sealed.
	-- This client can mark aura names as secret, and a secret value used as a
	-- table key errors rather than returning nil.
	local issecretvalue = rawget(_G, "issecretvalue")
	local function ReadableName(value)
		if type(issecretvalue) == "function" then
			local okSealed, sealed = pcall(issecretvalue, value)
			if not okSealed or sealed == true then
				return nil
			end
		end
		if type(value) ~= "string" or value == "" then
			return nil
		end
		return value
	end

	-- A readable spell name for an aura whose own name the client sealed.
	-- The spell id often stays readable, and C_Spell/GetSpellInfo can still
	-- name it. Returns nil when that answer is sealed too.
	local sealedAuraTried = {}
	local function SpellName(spellID)
		local id = tonumber(spellID)
		if not id then
			return nil
		end
		if type(C_Spell) == "table" and type(C_Spell.GetSpellInfo) == "function" then
			local ok, info = pcall(C_Spell.GetSpellInfo, id)
			if ok and type(info) == "table" then
				local name = ReadableName(info.name)
				if name then
					return name
				end
			end
		end
		if type(GetSpellInfo) == "function" then
			local ok, name = pcall(GetSpellInfo, id)
			if ok then
				name = ReadableName(name)
				if name then
					return name
				end
			end
		end
		return nil
	end

	-- Reads one aura slot on the player. Returns its name, spell id and aura
	-- instance id, or nil when the slot is empty, sealed, or the client will
	-- not answer. The instance id is what the client's own buff buttons hand
	-- their tooltip, so it is worth carrying.
	local function ReadAuraSlot(index, filter)
		if C_UnitAuras and C_UnitAuras.GetAuraDataByIndex then
			local ok, aura = pcall(C_UnitAuras.GetAuraDataByIndex, "player", index, filter)
			if not ok or type(aura) ~= "table" then
				return nil
			end
			local spellId = type(aura.spellId) == "number" and aura.spellId or nil
			local instanceID = type(aura.auraInstanceID) == "number" and aura.auraInstanceID or nil
			local duration = type(aura.duration) == "number" and aura.duration or nil
			local expiration = type(aura.expirationTime) == "number" and aura.expirationTime or nil
			local name = ReadableName(aura.name)
			if not name and spellId then
				name = SpellName(spellId)
			end
			if not name then
				local key = tostring(filter)..":"..tostring(spellId or index)
				if not sealedAuraTried[key] then
					sealedAuraTried[key] = true
					ns.Trace("auras: "..tostring(filter).." slot "..index
						.." has no readable name (spell "..tostring(spellId)..")")
				end
				return nil
			end
			return name, spellId, instanceID, duration, expiration
		end
		local reader = (filter == "HARMFUL") and UnitDebuff or UnitAura
		if type(reader) ~= "function" then
			return nil
		end
		-- The deprecated tuple: name first, spell id tenth, duration fifth
		-- and expiration time sixth.
		local ok, name, _, _, _, duration, expiration, _, _, _, spellId = pcall(reader, "player", index, filter)
		if not ok then
			return nil
		end
		name = ReadableName(name)
		if not name then
			local id = type(spellId) == "number" and spellId or nil
			if id then
				name = SpellName(id)
			end
		end
		if not name then
			local key = tostring(filter)..":"..tostring(spellId or index)
			if not sealedAuraTried[key] then
				sealedAuraTried[key] = true
				ns.Trace("auras: "..tostring(filter).." slot "..index
					.." has no readable name (spell "..tostring(spellId)..")")
			end
			return nil
		end
		return name, type(spellId) == "number" and spellId or nil, nil,
			type(duration) == "number" and duration or nil,
			type(expiration) == "number" and expiration or nil
	end

	local function AurasUsable()
		if auraUnusable then
			return false
		end
		if auraReaderTested then
			return true
		end
		auraReaderTested = true
		local hasModern = (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) ~= nil
		local hasOld = type(UnitAura) == "function"
		if not hasModern and not hasOld then
			auraUnusable = true
			ns.Trace("auras: the client offers no aura API Tally can use")
		end
		return not auraUnusable
	end

	-- The campfire buff's name, lowercased: the CampfireHangout addon publishes
	-- the name it looks for, and this client's own name is the fallback.
	local function CampfireBuffName()
		local addon = rawget(_G, "CampfireHangout")
		local name = type(addon) == "table" and addon.BUFF_NAME or nil
		name = ReadableName(name)
		if name then
			return string.lower(name)
		end
		return CAMPFIRE_BUFF_FALLBACK
	end

	-- The character's own class buff names, lowercased. A buff on this list is
	-- counted in the class bucket; everything else is counted as other. The list
	-- is a built-in one (the client gives no way to ask which class an aura
	-- belongs to), so a name it misses lands under other until it is added here.
	local CLASS_BUFFS = {
		WARRIOR = {
			"battle shout", "bloodrage", "last stand", "shield wall", "recklessness", "retaliation",
		},
		PALADIN = {
			"blessing of might", "blessing of wisdom", "blessing of kings", "blessing of salvation",
			"blessing of sanctuary", "blessing of protection", "blessing of freedom", "blessing of sacrifice",
			"blessing of light", "divine shield", "divine protection", "holy shield", "seal of righteousness",
			"seal of wisdom", "seal of light", "seal of justice", "seal of command", "seal of fury",
			"seal of might", "devotion aura", "retribution aura", "concentration aura", "sanctity aura",
			"shadow resistance aura", "frost resistance aura", "fire resistance aura",
		},
		HUNTER = {
			"aspect of the hawk", "aspect of the monkey", "aspect of the cheetah", "aspect of the pack",
			"aspect of the wild", "aspect of the beast", "trueshot aura", "rapid fire", "bestial wrath",
			"deterrence",
		},
		ROGUE = {
			"stealth", "vanish", "evasion", "sprint", "slice and dice", "blade flurry", "adrenaline rush",
			"cold blood", "prowl",
		},
		PRIEST = {
			"power word: fortitude", "prayer of fortitude", "power word: shield", "inner fire",
			"shadow protection", "prayer of shadow protection", "fear ward", "divine spirit",
			"prayer of spirit", "renew", "shadowform", "feedback",
		},
		SHAMAN = {
			"lightning shield", "water walking", "water breathing", "ghost wolf", "rockbiter weapon",
			"flametongue weapon", "frostbrand weapon", "windfury weapon", "windfury totem", "grace of air totem",
			"strength of earth totem", "stoneskin totem", "mana spring totem", "healing stream totem",
			"searing totem", "earthbind totem", "tremor totem", "grounding totem", "elemental mastery",
		},
		MAGE = {
			"arcane intellect", "arcane brilliance", "frost armor", "ice armor", "mage armor", "ice barrier",
			"mana shield", "arcane power", "presence of mind", "invisibility", "ice block", "dampen magic",
			"amplify magic", "combustion",
		},
		WARLOCK = {
			"demon skin", "demon armor", "fel armor", "soul link", "detect invisibility", "unending breath",
			"blood pact", "fire shield", "sacrifice", "shadow ward",
		},
		DRUID = {
			"mark of the wild", "gift of the wild", "thorns", "rejuvenation", "regrowth", "barkskin",
			"nature's grasp", "omen of clarity", "innervate", "cat form", "bear form", "dire bear form",
			"travel form", "aquatic form", "moonkin form", "tiger's fury", "frenzied regeneration", "enrage",
			"dash", "prowl",
		},
	}

	-- Racial abilities, counted with the class ones: they are the character's
	-- own, not something picked up in the world.
	local RACIAL_AURAS = {
		["find treasure"] = true, stoneform = true, ["escape artist"] = true,
		["will of the forsaken"] = true, cannibalize = true, berserking = true,
		["blood fury"] = true, ["war stomp"] = true, perception = true,
	}

	-- Gathering and tracking abilities: a profession's own, not a class's.
	local PROFESSION_AURAS = {
		["find herbs"] = true,
		["find minerals"] = true,
	}

	-- Which group an aura belongs to: "class" for the character's own class or
	-- racial ability, "prof" for a gathering or tracking ability, nil for
	-- everything else - food, potions, scrolls, other players, the campfire.
	-- The client attaches no class to an aura, so this is a built-in list and
	-- a name it misses lands under Other.
	local function AuraKind(char, name)
		local lower = string.lower(name)
		local list = CLASS_BUFFS[char and char.classFile or ""]
		if list then
			for index = 1, #list do
				if list[index] == lower then
					return "class"
				end
			end
		end
		if RACIAL_AURAS[lower] then
			return "class"
		end
		if PROFESSION_AURAS[lower] then
			return "prof"
		end
		return nil
	end

	-- The aura record for a character, created on first use.
	local function AuraStore(char)
		local auras = char.auras
		if not auras then
			auras = { buffs = {}, debuffs = {}, seenBuffs = {}, seenDebuffs = {}, camp = { seconds = 0, visits = 0, benefits = 0 } }
			char.auras = auras
		end
		return auras
	end

	-- Only the aura API is unavailable after the first failure, so the text of
	-- an aura is attempted once per session each, not once a second.
	local auraTextTried = {}

	-- A hidden tooltip, used only to read what the game itself says about an
	-- aura while it is on the character. That text is the aura tooltip - the
	-- one the buff bar shows - which is not the same as the spell's own entry:
	-- the spell entry carries its cast time, cost and rank wording, while the
	-- aura says what it is doing to the character. It is read once per aura and
	-- stored beside the name, because a tooltip cannot be asked for an aura
	-- that is no longer there.
	local AURA_DESC_LINES = 4
	local AURA_DESC_MAX = 240
	local auraScanTip
	local auraScanTipBroken = false

	local function AuraScanTip()
		if auraScanTip then
			return auraScanTip
		end
		if auraScanTipBroken then
			return nil
		end
		local ok, tip = pcall(CreateFrame, "GameTooltip", "TallyAuraScanTooltip", UIParent, "GameTooltipTemplate")
		if not ok or not tip then
			auraScanTipBroken = true
			ns.Trace("auras: this client would not make the hidden tooltip, so aura text is not read")
			return nil
		end
		auraScanTip = tip
		tip:SetOwner(UIParent, "ANCHOR_NONE")
		return tip
	end

	-- The text of a tooltip line, whichever shape this client's data uses: the
	-- documented one is a table with leftText/rightText, but a plain string is
	-- taken as it comes rather than dropped.
	local function TooltipLineText(line)
		if type(line) == "string" then
			return ReadableName(line)
		end
		if type(line) ~= "table" then
			return nil
		end
		return ReadableName(line.leftText) or ReadableName(line.rightText)
	end

	-- The aura's own wording, from the tooltip *data* the client draws its
	-- aura tooltip from (C_TooltipInfo.GetUnitAura, the source behind
	-- GameTooltip:SetUnitAura). Reading the data avoids the rendering step
	-- entirely, which is why this is tried first: reading the drawn lines of a
	-- hidden tooltip produced nothing here. The aura's own name is skipped,
	-- since the window already prints it.
	local function AuraDataText(name, index, filter, instanceID)
		if not (C_TooltipInfo and C_TooltipInfo.GetUnitAura) then
			return nil, nil
		end
		local data, used
		if instanceID and C_TooltipInfo.GetUnitAuraByAuraInstanceID then
			local ok, got = pcall(C_TooltipInfo.GetUnitAuraByAuraInstanceID, "player", instanceID, filter)
			if ok and type(got) == "table" then
				data, used = got, "aura data by id"
			end
		end
		if not data then
			local ok, got = pcall(C_TooltipInfo.GetUnitAura, "player", index, filter)
			if ok and type(got) == "table" then
				data, used = got, "aura data by slot"
			end
		end
		if not data or type(data.lines) ~= "table" then
			return nil, nil
		end
		local parts = {}
		for lineIndex = 1, #data.lines do
			local text = TooltipLineText(data.lines[lineIndex])
			if text then
				local lower = string.lower(text)
				-- The aura's own name is the window's title, and the removal
				-- hint belongs to the tooltip rather than to the aura.
				if text ~= name and not string.find(lower, "to remove", 1, true) then
					parts[#parts + 1] = text
				end
			end
		end
		if #parts == 0 then
			return nil, nil
		end
		return table.concat(parts, "  "), used
	end

	-- The aura's own wording from the drawn tooltip, for a client without
	-- C_TooltipInfo. Same text, one rendering step more.
	local function ReadAuraDescription(name, index, filter, instanceID)
		local text, used = AuraDataText(name, index, filter, instanceID)
		if text then
			return text, used
		end
		local tip = AuraScanTip()
		if not tip then
			return nil, used
		end
		-- The same calls this client's own buff buttons make, in the same
		-- order: the aura by instance id, then by slot. SetUnitBuff is
		-- deliberately not used first - it renders the *spell's* entry, which
		-- is the long spellbook wording ("Following herbs...") rather than
		-- what the buff itself says ("Finding herbs").
		local renderedUsed
		if instanceID and type(tip.SetUnitAuraByAuraInstanceID) == "function"
			and pcall(tip.SetUnitAuraByAuraInstanceID, tip, "player", instanceID, filter) then
			renderedUsed = "aura by id"
		elseif type(tip.SetUnitAura) == "function" and pcall(tip.SetUnitAura, tip, "player", index, filter) then
			renderedUsed = "aura by slot"
		elseif filter == "HARMFUL" and type(tip.SetUnitDebuff) == "function" and pcall(tip.SetUnitDebuff, tip, "player", index) then
			renderedUsed = "debuff slot"
		elseif filter ~= "HARMFUL" and type(tip.SetUnitBuff) == "function" and pcall(tip.SetUnitBuff, tip, "player", index) then
			renderedUsed = "buff slot"
		end
		if not renderedUsed then
			return nil, used
		end
		local parts = {}
		for line = 2, 1 + AURA_DESC_LINES do
			local region = _G["TallyAuraScanTooltipTextLeft"..line]
			if region and region.GetText then
				local okText, text = pcall(region.GetText, region)
				if okText then
					text = ReadableName(text)
					if text then
						local lower = string.lower(text)
						-- The removal hint is the tooltip's own note, not
						-- anything about the aura.
						if not string.find(lower, "to remove", 1, true) and not string.find(lower, "right%-click") then
							parts[#parts + 1] = text
						end
					end
				end
			end
		end
		tip:Hide()
		if #parts == 0 then
			return nil, renderedUsed
		end
		local text = table.concat(parts, "  ")
		if #text > AURA_DESC_MAX then
			text = string.sub(text, 1, AURA_DESC_MAX - 3).."..."
		end
		return text, renderedUsed
	end

	-- Samples one kind of aura: the HELPFUL filter for buffs, HARMFUL for
	-- debuffs. Each aura that is up adds a second to its total, and one to its
	-- count the first second it is seen - which is why the seen set is stored,
	-- so a reload in the middle of a buff does not count it twice, and why the
	-- miss sets are: a slot the client answers nothing for is not a loss.
	local function ScanAuras(char, auras, filter, bucketField, seenField)
		local bucket, seen = auras[bucketField], auras[seenField]
		if not bucket or not seen then
			return
		end
		local missField = (bucketField == "buffs") and "missBuffs" or "missDebuffs"
		local misses = auras[missField]
		if not misses then
			misses = {}
			auras[missField] = misses
		end
		local present = {}
		local now = ns.Now()
		local isBuffs = (bucketField == "buffs")
		local campBuff = isBuffs and CampfireBuffName() or nil
		local camp = auras.camp
		if type(camp) ~= "table" then
			camp = { seconds = 0, visits = 0, benefits = 0 }
			auras.camp = camp
		end
		camp.seconds = tonumber(camp.seconds) or 0
		camp.visits = tonumber(camp.visits) or 0
		camp.benefits = tonumber(camp.benefits) or 0
		-- Old records may already carry the one-time migration flag from an
		-- earlier pass that ran before the visit count was corrected. Recheck
		-- on each scan so a stale benefits total cannot survive that flag.
		if isBuffs then
			local visits = camp.visits or 0
			if (camp.benefits or 0) > visits then
				ns.Trace("campfire: benefits "..camp.benefits.." capped to the "..visits.." visits recorded")
				camp.benefits = visits
				for name, entry in pairs(bucket) do
					if string.lower(name) == CAMP_BENEFITS and (entry.count or 0) > visits then
						entry.count = visits
					end
				end
			end
		end
		local empty = 0
		for index = 1, AURA_SLOTS do
			local name, spellID, instanceID, duration, expiration = ReadAuraSlot(index, filter)
			if not name then
				empty = empty + 1
				if empty >= AURA_GAP then
					break
				end
			else
				empty = 0
				present[name] = true
				misses[name] = nil
				local lower = string.lower(name)
				local entry = bucket[name]
				if type(entry) ~= "table" then
					entry = {
						count = 0, seconds = 0,
						firstAt = now, lastAt = now, updatedAt = now,
						how = "aura", evidence = "aura_scan", observed = "live",
					}
					local kind = AuraKind(char, name)
					if kind then
						entry.class = kind
					end
					bucket[name] = entry
				end
				entry.count = tonumber(entry.count) or 0
				entry.seconds = tonumber(entry.seconds) or 0
				-- The spell id is kept beside the name so a hover can ask the
				-- client what the aura does, long after it has worn off: the
				-- window describes buffs that are not up any more.
				if spellID and entry.spellID ~= spellID then
					entry.spellID = spellID
				end
				-- The aura's own wording, read while it is up. Records written
				-- before this read the spell's entry instead, and a read that
				-- came back empty is worth another try, so the condition covers
				-- both. Each aura is tried once a session, so a client that will
				-- not answer is not asked every second for the rest of the night.
				if (entry.descFrom ~= "aura" or not entry.desc) and not auraTextTried[name] then
					auraTextTried[name] = true
					local desc, used = ReadAuraDescription(name, index, filter, instanceID)
					-- What is stored from before an "aura" read with text is not
					-- the aura's own wording (it is the spell's entry, which is
					-- exactly what the user saw), so it is replaced - with nil
					-- when this read failed, rather than kept as if it were.
					entry.desc = desc
					entry.descFrom = used and (string.find(used, "aura", 1, true) and "aura" or used) or nil
					if used then
						ns.Trace("auras: "..name.." text read ("..used.."): "..(desc and string.sub(desc, 1, 60) or "none"))
					end
				end
				-- The aura's own duration, remembered for the refresh window
				-- below (a permanent aura reports none).
				if duration and duration > 0 then
					entry.duration = duration
				end
				-- A debuff that is refreshed is another application even when
				-- the old one never left the bar. A forward jump in the
				-- client's expiration time is that refresh; buffs keep the
				-- "same buff" handling below.
				local refreshed = false
				if not isBuffs and expiration and entry.expirationTime
					and expiration > entry.expirationTime + 1 then
					refreshed = true
				end
				if expiration then
					entry.expirationTime = expiration
				end
				-- When this aura was last actually seen, which is how long it
				-- has been away when it comes back.
				local lastSeen = auras.lastSeen and auras.lastSeen[name] or 0
				if not auras.lastSeen then
					auras.lastSeen = {}
				end
				auras.lastSeen[name] = now
				-- A permanent buff has no duration; it is not treated as a
				-- five-second refresh. Its own long window applies, or a death
				-- since it was last seen if the player applied it again.
				local permanent = isBuffs and (not entry.duration or entry.duration <= 0)
				local window
				if permanent then
					window = AURA_PERMANENT_AWAY
				else
					window = math.max(AURA_REFRESH_MIN, math.min(AURA_REFRESH_MAX, entry.duration or 0))
				end
				local away = now - lastSeen
				local deathAt = 0
				local deathCountedAt = 0
				if permanent then
					deathAt = tonumber(char and char.combat and char.combat.deathsLastAt) or 0
					deathCountedAt = tonumber(auras.deathCountedAt) or 0
				end
				-- A death at or just after the last sighting means the buff
				-- really went away and was applied again. The two-second grace
				-- covers a scan that still saw the buff as the player died.
				-- deathCountedAt is the last death this rule already used, so
				-- one death cannot count the same buff several times.
				local diedSinceSeen = permanent and deathAt > (lastSeen - 2) and deathAt > deathCountedAt
				-- Gone means the miss rule has already let it drop; a buff is
				-- a gain again only when it was away at least its own window.
				-- A debuff that is gone and comes back is a new landing.
				local wasGone = not seen[name]
				local appeared
				if isBuffs then
					appeared = wasGone and (diedSinceSeen or away >= window)
				else
					appeared = wasGone
				end
				if wasGone then
					seen[name] = true
					if lower == campBuff or lower == CAMP_BENEFITS then
						ns.Trace(string.format("auras: %s %s (away %ds, window %ds)", name,
							appeared and "gained" or "came back - a refresh, not a new gain",
							math.floor(away), math.floor(window)))
					elseif permanent and appeared then
						ns.Trace(string.format("auras: permanent %s counted (away %ds, death %s)",
							name, math.floor(away), diedSinceSeen and "yes" or "no"))
					end
				end
				if appeared or refreshed then
					entry.count = entry.count + 1
					if diedSinceSeen then
						auras.deathCountedAt = deathAt
					end
				end
				entry.seconds = entry.seconds + 1
				entry.lastAt = now
				entry.updatedAt = now
				if isBuffs then
					if lower == campBuff then
						-- Time at the fire is the time its own buff is on; a visit
						-- is one appearance of it.
						camp.seconds = camp.seconds + 1
						camp.firstAt = camp.firstAt or now
						camp.lastAt = now
						camp.updatedAt = now
						if appeared then
							camp.visits = camp.visits + 1
						end
					elseif lower == CAMP_BENEFITS and appeared then
						-- One per appearance of the benefits buff itself, not per
						-- bonus it carries: the client shows it as a single aura,
						-- whatever it happens to be granting at the time.
						camp.benefits = camp.benefits + 1
					end
				end
			end
		end
		-- An aura that is not in this scan has not necessarily gone: it counts
		-- as gone after AURA_MISS scans in a row without it, and a return
		-- before then is the same gain, not a new one.
		for name in pairs(seen) do
			if not present[name] then
				local missed = (misses[name] or 0) + 1
				if missed >= AURA_MISS and (ns.Now() - scanStartedAt) > 10 then
					seen[name] = nil
					misses[name] = nil
				else
					-- The client can answer "no aura" while it settles after a
					-- login; in the first seconds a miss does not forget an
					-- aura that was already known, so its return is not a new
					-- gain.
					misses[name] = missed
				end
			end
		end
	end

	-- Called from the ticker, once a second. Read-only on the client: nothing is
	-- asked of it beyond what the buff bars themselves read.
	local function ScanAurasTick()
		if not AurasUsable() then
			return
		end
		if scanStartedAt == 0 then
			scanStartedAt = ns.Now()
		end
		local char = ns.GetChar()
		if not char then
			return
		end
		local auras = AuraStore(char)
		-- The scan is called from the ticker, so a mistake in it must not stop
		-- the ticker: it is run under pcall and a failure is reported once. A
		-- nil arithmetic here once killed the whole second, every second.
		local okScan, scanError = pcall(function()
			ScanAuras(char, auras, "HELPFUL", "buffs", "seenBuffs")
			ScanAuras(char, auras, "HARMFUL", "debuffs", "seenDebuffs")
		end)
		if not okScan then
			if not aurasScanFailed then
				aurasScanFailed = true
				ns.Trace("auras: the scan raised an error and was skipped: "..tostring(scanError))
			end
			return
		end
		if not aurasAnnounced then
			aurasAnnounced = true
			local fromAddon = type(rawget(_G, "CampfireHangout")) == "table" and " (name from CampfireHangout)" or ""
			ns.Trace("auras: reading buffs and debuffs; watching for '"..CampfireBuffName().."'"..fromAddon.." and '"..CAMP_BENEFITS.."'")
		end
	end
	ns.ScanAurasTick = ScanAurasTick
end

-- Owner namespace. The ticker calls the scan; this is the same function.
ns.auras = {}
ns.auras.Scan = ns.ScanAurasTick

-- A character switch starts the settling grace again, so a late answer from
-- the new character's client cannot forget its active auras.
function ns.auras.ResetScanGrace()
	scanStartedAt = 0
end
