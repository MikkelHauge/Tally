-- Tally - kills from the game's kill events, with the nameplate cache and the
-- instance messages where the game hides the identity.
--
-- Midnight and WoW Forever no longer hand the combat log to addons. They do
-- fire PARTY_KILL for a player or group killing blow and UNIT_DIED for a death
-- the client sees; nameplates only cache what a mob was while it was alive.
-- Inside instances identity is secret, so the only readable signals there are
-- the experience line and the corpses a loot window names.
--
-- This file turns each of those into one call to Core's AddKill, so the totals,
-- the per-creature rows, the session figures and the records stay in one place.
local addonName, ns = ...

do
	
	local MAX_CACHE = 500
	local CACHE_TTL = 300
	local PET_TTL = 60
	local MAX_OBSERVED = 200
	
	-- [guid] = { name, tapDenied, friendly, removedAt }
	local cache = {}
	local cacheCount = 0
	
	-- [nameplate token] = { guid, counted } for the health fallback.
	local tokens = {}
	local tokenCount = 0
	
	-- [guid] = GetTime when the death was recorded, so the same death arriving as
	-- both PARTY_KILL and UNIT_DIED is only counted once.
	local counted = {}
	
	local petTarget, petLeft = nil, {}

	-- [guid] = GetTime when the player was last on the mob's threat list. A
	-- death the player fought but PARTY_KILL missed can still be claimed.
	local engaged = {}

	-- Counts for "/tally debug": where a kill was seen and where it was lost.
	local stats = { party = 0, ours = 0, denied = 0, noName = 0,
		recorded = 0, health = 0, pet = 0, threat = 0, rejected = 0 }
	
	-- Instance state: an experience kill is counted at once and the matching
	-- looted corpse uses a credit instead of counting again. The reverse order
	-- is handled by lootCredits, for a corpse looted before its line arrives.
	local xpCredits, lootCredits, looted = {}, {}, {}
	local instanceNames = {}
	local instanceClassifications = {}
	
	local killActive = false
	local modernKills = false
	local partyKillEvent = false
	local unitDiedFallback = false
	
	local function Secret(value)
		if type(issecretvalue) == "function" then
			local ok, result = pcall(issecretvalue, value)
			return ok and result and true or false
		end
		return false
	end
	
	local function ReadGUID(token)
		local ok, guid = pcall(UnitGUID, token)
		if not ok or Secret(guid) or type(guid) ~= "string" then
			return nil
		end
		return guid
	end
	
	local function ReadName(token)
		local ok, name = pcall(UnitName, token)
		if not ok or Secret(name) or type(name) ~= "string" or name == "" then
			return nil
		end
		return name
	end
	
	local function ReadTap(token)
		if type(UnitIsTapDenied) ~= "function" then
			return nil
		end
		local ok, denied = pcall(UnitIsTapDenied, token)
		if not ok or Secret(denied) then
			return nil
		end
		return denied and true or false
	end

	local function ReadClassification(token)
		if type(UnitClassification) ~= "function" then
			return nil
		end
		local ok, classification = pcall(UnitClassification, token)
		if not ok or Secret(classification) or type(classification) ~= "string" then
			return nil
		end
		return classification
	end
	
	local function InAnyInstance()
		if type(IsInInstance) ~= "function" then
			return false
		end
		local ok, inside = pcall(IsInInstance)
		return ok and inside and true or false
	end
	
	local function InstanceActive()
		if type(IsInInstance) ~= "function" then
			return false
		end
		local ok, inside, kind = pcall(IsInInstance)
		if not ok or not inside then
			return false
		end
		return kind == "party" or kind == "raid" or kind == "scenario"
	end
	
	local function CreatureGUID(guid)
		if type(guid) ~= "string" then
			return false
		end
		return string.sub(guid, 1, 9) == "Creature-"
			or string.sub(guid, 1, 8) == "Vehicle-"
	end
	
	local function Prune(now)
		for guid, entry in pairs(cache) do
			if entry.removedAt and now - entry.removedAt > CACHE_TTL then
				cache[guid] = nil
				cacheCount = cacheCount - 1
			end
		end
		for guid, at in pairs(counted) do
			if now - at > CACHE_TTL then
				counted[guid] = nil
			end
		end
		for guid, at in pairs(petLeft) do
			if now - at > PET_TTL then
				petLeft[guid] = nil
			end
		end
		for guid, at in pairs(engaged) do
			if now - at > PET_TTL then
				engaged[guid] = nil
			end
		end
	end
	
	local function FindToken(guid)
		if type(UnitTokenFromGUID) == "function" then
			local ok, token = pcall(UnitTokenFromGUID, guid)
			if ok and not Secret(token) and type(token) == "string"
				and ReadGUID(token) == guid then
				return token
			end
		end
		local list = { "target", "focus", "mouseover", "pet", "pettarget" }
		for index = 1, 5 do
			list[#list + 1] = "boss"..index
		end
		for index = 1, 40 do
			list[#list + 1] = "nameplate"..index
		end
		for index = 1, #list do
			if ReadGUID(list[index]) == guid then
				return list[index]
			end
		end
		return nil
	end
	
	local function NameFor(guid)
		local entry = cache[guid]
		if entry and entry.name then
			return entry.name
		end
		local token = FindToken(guid)
		return token and ReadName(token) or nil
	end
	
	local function FriendlyFor(guid)
		local entry = cache[guid]
		if entry and entry.friendly ~= nil then
			return entry.friendly
		end
		local token = FindToken(guid)
		if token and type(UnitReaction) == "function" then
			local ok, reaction = pcall(UnitReaction, "player", token)
			if ok and type(reaction) == "number" then
				return reaction >= 5
			end
		end
		return nil
	end

	local function ClassificationFor(guid)
		local entry = cache[guid]
		if entry and entry.classification then
			return entry.classification
		end
		local token = FindToken(guid)
		return token and ReadClassification(token) or nil
	end
	
	local function TapDeniedFor(guid)
		local token = FindToken(guid)
		if token then
			local denied = ReadTap(token)
			if denied ~= nil then
				return denied
			end
		end
		local entry = cache[guid]
		return entry and entry.tapDenied or nil
	end
	
	local function PetWasOn(guid)
		if petTarget == guid then
			return true
		end
		if ReadGUID("pettarget") == guid then
			return true
		end
		local at = petLeft[guid]
		return at ~= nil and GetTime() - at <= PET_TTL
	end
	
	local function NotePetTarget()
		local guid = ReadGUID("pettarget")
		if guid ~= petTarget then
			if petTarget then
				petLeft[petTarget] = GetTime()
			end
			petTarget = guid
		end
	end

	-- The player is on this mob's threat list: remember it, so a death the
	-- killing-blow event missed can still be claimed. A stranger's mob never
	-- enters the player's threat list.
	local function NoteThreat(unit)
		if InAnyInstance() or Secret(unit) or type(unit) ~= "string" then
			return
		end
		local guid = ReadGUID(unit)
		if not guid or not CreatureGUID(guid) then
			return
		end
		if type(UnitThreatSituation) ~= "function" then
			return
		end
		local ok, status = pcall(UnitThreatSituation, "player", unit)
		if not ok or Secret(status) or status == nil then
			return
		end
		engaged[guid] = GetTime()
		stats.threat = stats.threat + 1
		local denied = ReadTap(unit)
		local entry = cache[guid]
		if entry and denied ~= nil then
			entry.tapDenied = denied
		end
	end
	
	local function SameGUID(one, two)
		if not one or not two or Secret(one) or Secret(two) then
			return false
		end
		return one == two
	end
	
	-- The player, their pet, and every party or raid member and pet: group kills
	-- count, as the page's older kill source counted them.
	local function IsOurKiller(attacker)
		if not attacker or Secret(attacker) then
			return false
		end
		if SameGUID(attacker, UnitGUID("player")) or SameGUID(attacker, UnitGUID("pet")) then
			return true
		end
		if type(IsInRaid) == "function" and IsInRaid() then
			for index = 1, 40 do
				if SameGUID(attacker, UnitGUID("raid"..index))
					or SameGUID(attacker, UnitGUID("raidpet"..index)) then
					return true
				end
			end
		elseif type(IsInGroup) == "function" and IsInGroup() then
			for index = 1, 4 do
				if SameGUID(attacker, UnitGUID("party"..index))
					or SameGUID(attacker, UnitGUID("partypet"..index)) then
					return true
				end
			end
		end
		return false
	end
	
	local function RecordKill(guid, name, zone)
		if not guid or counted[guid] then
			return
		end
		name = name or NameFor(guid)
		if not name then
			stats.noName = stats.noName + 1
			return
		end
		if FriendlyFor(guid) == true or TapDeniedFor(guid) == true then
			stats.denied = stats.denied + 1
			return
		end
		counted[guid] = GetTime()
		stats.recorded = stats.recorded + 1
		local zoneName = zone or (type(GetRealZoneText) == "function" and GetRealZoneText()) or ""
		ns.NoteKill(name, zoneName)
		local classification = ClassificationFor(guid)
		if ns.NoteEliteKill then
			ns.NoteEliteKill(name, classification, zoneName)
		end
	end
	
	local function RecordModernDeath(guid, needPet)
		if InAnyInstance() or not CreatureGUID(guid) or counted[guid] then
			return
		end
		if needPet and not PetWasOn(guid) then
			return
		end
		RecordKill(guid, NameFor(guid))
	end
	
	local function Observe(token)
		if InAnyInstance() then
			return
		end
		local guid = ReadGUID(token)
		if not guid or not CreatureGUID(guid) then
			return
		end
		local name = ReadName(token)
		if not name then
			return
		end
		local friendly
		if type(UnitReaction) == "function" then
			local ok, reaction = pcall(UnitReaction, "player", token)
			if ok and type(reaction) == "number" then
				friendly = reaction >= 5
			end
		end
		local tap = ReadTap(token)
		local classification = ReadClassification(token)
		local entry = cache[guid]
		if not entry then
			if cacheCount >= MAX_CACHE then
				Prune(GetTime())
				if cacheCount >= MAX_CACHE then
					return
				end
			end
			cache[guid] = { name = name, tapDenied = tap, friendly = friendly, classification = classification }
			cacheCount = cacheCount + 1
		else
			entry.name = name
			entry.tapDenied = tap
			entry.friendly = friendly
			entry.classification = classification or entry.classification
			entry.removedAt = nil
		end
		if tokens[token] == nil then
			if tokenCount >= MAX_OBSERVED then
				return
			end
			tokens[token] = { guid = guid, counted = false }
			tokenCount = tokenCount + 1
		else
			tokens[token].guid = guid
			tokens[token].counted = false
		end
	end
	
	local function Forget(token)
		local known = tokens[token]
		if not known then
			return
		end
		tokens[token] = nil
		tokenCount = tokenCount - 1
		local entry = known.guid and cache[known.guid]
		if entry then
			entry.removedAt = GetTime()
			local denied = ReadTap(token)
			if denied ~= nil then
				entry.tapDenied = denied
			end
		end
	end
	
	local function CheckHealth(token)
		if InAnyInstance() then
			return
		end
		local known = tokens[token]
		if not known or known.counted then
			return
		end
		-- A visible death is only ours when the player or pet was actually
		-- fighting it. NPC guards in a spawn area produce nameplates too, and
		-- their kills must not be booked as the player's.
		local guid = known.guid
		if not engaged[guid] and not PetWasOn(guid) then
			stats.rejected = stats.rejected + 1
			return
		end
		local ok, dead = pcall(UnitIsDead, token)
		if not ok or Secret(dead) or dead ~= true then
			return
		end
		if ReadTap(token) == true then
			return
		end
		known.counted = true
		stats.health = stats.health + 1
		RecordKill(guid, ReadName(token))
	end
	
	local function PartyKill(attacker, target)
		if InAnyInstance() or Secret(attacker) or Secret(target) then
			return
		end
		stats.party = stats.party + 1
		if not IsOurKiller(attacker) then
			return
		end
		stats.ours = stats.ours + 1
		if TapDeniedFor(target) == true then
			return
		end
		RecordModernDeath(target, false)
	end

	local function UnitDied(guid)
		if InAnyInstance() or Secret(guid) or not CreatureGUID(guid) then
			return
		end
		if counted[guid] then
			return
		end
		-- UNIT_DIED carries no attacker. Without the player's threat on the
		-- mob or the pet's target, this death is not ours: an NPC can kill a
		-- nearby creature and still raise the event.
		local pet = PetWasOn(guid)
		if not engaged[guid] and not pet then
			stats.rejected = stats.rejected + 1
			return
		end
		if unitDiedFallback then
			if TapDeniedFor(guid) == true then
				return
			end
			RecordModernDeath(guid, false)
		elseif pet then
			stats.pet = stats.pet + 1
			RecordModernDeath(guid, true)
		elseif engaged[guid] then
			-- The player was fighting it: a killing-blow event went missing,
			-- but the death is still theirs to claim.
			RecordModernDeath(guid, false)
		end
	end
	
	local function ResetState()
		for guid in pairs(cache) do
			cache[guid] = nil
		end
		cacheCount = 0
		for token in pairs(tokens) do
			tokens[token] = nil
		end
		tokenCount = 0
		for guid in pairs(counted) do
			counted[guid] = nil
		end
		for guid in pairs(engaged) do
			engaged[guid] = nil
		end
		petTarget, petLeft = nil, {}
		xpCredits, lootCredits, looted = {}, {}, {}
	end

	local function ResetInstance()
		xpCredits, lootCredits, looted = {}, {}, {}
	end
	
	local OnEvent

	local function SafeRegister(event)
		return ns.On(event, OnEvent, "Kills")
	end

	local function SafeUnregister(event)
		ns.Off(event, OnEvent, "Kills")
		ns.Off(event, OnEvent, "Kills", "pet")
	end

	OnEvent = function(event, ...)
		if event == "NAME_PLATE_UNIT_ADDED" then
			Observe(...)
		elseif event == "NAME_PLATE_UNIT_REMOVED" then
			Forget(...)
		elseif event == "PARTY_KILL" then
			PartyKill(...)
		elseif event == "UNIT_DIED" then
			UnitDied(...)
		elseif event == "UNIT_TARGET" then
			if (...) == "pet" then
				NotePetTarget()
			end
		elseif event == "UNIT_THREAT_LIST_UPDATE" then
			NoteThreat(...)
		elseif event == "UNIT_HEALTH" then
			CheckHealth(...)
		elseif event == "PLAYER_ENTERING_WORLD" then
			ResetState()
		elseif event == "ZONE_CHANGED_NEW_AREA" then
			ResetInstance()
		end
	end
	
	-- Nameplates are still needed to learn what a mob was, but they are no longer
	-- the kill trigger: PARTY_KILL and UNIT_DIED are. The health check is only for
	-- a client that refuses both of those.
	function ns.SetNameplateKills(on)
		on = on and ns.NameplateKillsAvailable() and true or false
		if on == killActive then
			return
		end
		killActive = on
		local base = {
			"NAME_PLATE_UNIT_ADDED", "NAME_PLATE_UNIT_REMOVED",
			"PLAYER_ENTERING_WORLD", "ZONE_CHANGED_NEW_AREA",
		}
		for index = 1, #base do
			if on then
				SafeRegister(base[index])
			else
				SafeUnregister(base[index])
			end
		end
		SafeUnregister("PARTY_KILL")
		SafeUnregister("UNIT_DIED")
		SafeUnregister("UNIT_HEALTH")
		SafeUnregister("UNIT_TARGET")
		SafeUnregister("UNIT_THREAT_LIST_UPDATE")
		modernKills, partyKillEvent, unitDiedFallback = false, false, false
		ResetState()
		if not on then
			return
		end
		partyKillEvent = SafeRegister("PARTY_KILL")
		local unitDied = SafeRegister("UNIT_DIED")
		modernKills = partyKillEvent or unitDied
		unitDiedFallback = unitDied and not partyKillEvent
		-- The nameplate health is always watched as a second witness: a
		-- visible death is counted even if the event that should have named
		-- the killer did not arrive. counted[guid] stops a double count.
		SafeRegister("UNIT_HEALTH")
		SafeRegister("UNIT_THREAT_LIST_UPDATE")
		if modernKills then
			ns.On("UNIT_TARGET", OnEvent, "Kills", { unit = "pet" })
		end
	end
	
	function ns.NameplateKillsAvailable()
		return type(UnitIsTapDenied) == "function"
			and type(UnitIsDead) == "function"
			and type(C_NamePlate) == "table"
	end
	
	function ns.NameplateKillsActive()
		return killActive
	end

	-- One line for "/tally debug": which source is live and where kills were
	-- seen or lost. Counts are for the session.
	function ns.KillDebugText()
		return string.format(
			"kills: mode=%s, party=%d, ours=%d, denied=%d, noName=%d, health=%d, pet=%d, threat=%d, rejected=%d, recorded=%d",
			modernKills and "events+health" or "health",
			stats.party, stats.ours, stats.denied, stats.noName,
			stats.health, stats.pet, stats.threat, stats.rejected, stats.recorded)
	end
	
	-- Picks the one source that may count. Where the player has switched on the
	-- combat log and the client exposes it, that is used: it is more precise. The
	-- otherwise nameplate/event reader counts the open world and the instance
	-- messages. The two never run together.
	function ns.ApplyKillSource()
		local logOn = ns.db and ns.db.settings and ns.db.settings.combatLogRead
			and ns.CombatLogUsable()
		local plates = (not logOn) and ns.NameplateKillsAvailable()
		ns.SetNameplateKills(plates)
		ns.killSource = logOn and "log" or (plates and "nameplate" or nil)
		for _, record in pairs((ns.db and ns.db.chars) or {}) do
			if record.combat then
				record.combat.killsAvailable = ns.killSource ~= nil
				record.combat.killSource = ns.killSource
			end
		end
		if ns.OnDataTick then
			ns.OnDataTick()
		end
	end
	
	-- ---------------------------------------------------------------------------
	-- Instance kills: the experience line and the loot window
	-- ---------------------------------------------------------------------------
	
	local function EscapePattern(text)
		return (text:gsub("([%(%)%.%+%-%*%?%[%]%^%$%%])", "%%%1"))
	end
	
	local function BuildXpPattern(format)
		if type(format) ~= "string" then
			return nil
		end
		local first, firstEnd = format:find("%%%d*%$?s")
		local number = format:find("%%%d*%$?d")
		if not (first and number and number > firstEnd) then
			return nil
		end
		return "^"..EscapePattern(format:sub(1, first - 1))
			.."(.-)"..EscapePattern(format:sub(firstEnd + 1, number - 1)).."%d"
	end
	
	local xpPattern
	
	local function XpName(text)
		if type(text) ~= "string" then
			return nil
		end
		if not xpPattern then
			xpPattern = BuildXpPattern(COMBATLOG_XPGAIN_FIRSTPERSON)
				or BuildXpPattern("%s dies, you gain %d experience.")
		end
		local name = xpPattern and text:match(xpPattern)
		if type(name) ~= "string" then
			return nil
		end
		name = name:gsub("%s*<[^>]*>%s*$", "")
		if name == "" then
			return nil
		end
		return name
	end
	
	local function CanInstance()
		return killActive and ns.killSource == "nameplate"
			and ns.Tracks and ns.Tracks("combat") and InstanceActive()
	end
	
	function ns.NoteInstanceXp(text)
		if not CanInstance() then
			return
		end
		local name = XpName(text)
		if not name then
			return
		end
		local paid = lootCredits[name]
		if paid and paid > 0 then
			lootCredits[name] = paid - 1
		else
			xpCredits[name] = (xpCredits[name] or 0) + 1
			ns.NoteKill(name, type(GetRealZoneText) == "function" and GetRealZoneText() or "")
		end
	end
	
	local function CreatureNameForID(id)
		local known = instanceNames[id]
		if known then
			return known
		end
		if type(C_TooltipInfo) ~= "table" or type(C_TooltipInfo.GetHyperlink) ~= "function" then
			return nil
		end
		local link = "unit:Creature-0-0-0-0-"..tostring(id).."-0000000000"
		local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
		if not ok or type(data) ~= "table" or Secret(data) or type(data.lines) ~= "table" then
			return nil
		end
		local first = data.lines[1]
		if type(first) ~= "table" or Secret(first) then
			return nil
		end
		local name = first.leftText
		if Secret(name) or type(name) ~= "string" or name == "" or name:find("^Retrieving") then
			return nil
		end
		local classification
		for index = 1, #data.lines do
			local line = data.lines[index]
			local text = type(line) == "table" and not Secret(line) and line.leftText or nil
			if type(text) == "string" then
				if text:find("Rare Elite", 1, true) then
					classification = "rareelite"
					break
				elseif text:find("Elite", 1, true) then
					classification = "elite"
				elseif text:find("Rare", 1, true) and not classification then
					classification = "rare"
				end
			end
		end
		instanceNames[id] = name
		instanceClassifications[id] = classification
		return name
	end
	
	local function MobIDFromGUID(guid)
		if type(guid) ~= "string" or Secret(guid) then
			return nil
		end
		local kind, id = guid:match("^([%a]+)%-%d+%-%d+%-%d+%-%d+%-(%d+)%-")
		if kind ~= "Creature" and kind ~= "Vehicle" then
			return nil
		end
		return tonumber(id)
	end
	
	-- A looted corpse: if its kill already arrived as an experience line, use that
	-- credit; otherwise the corpse is the only signal the client gives.
	function ns.NoteInstanceLoot()
		if not CanInstance() then
			return
		end
		if type(GetNumLootItems) ~= "function" or type(GetLootSourceInfo) ~= "function" then
			return
		end
		local ok, count = pcall(GetNumLootItems)
		if not ok or type(count) ~= "number" then
			return
		end
		for slot = 1, count do
			local results = { pcall(GetLootSourceInfo, slot) }
			if results[1] then
				for index = 2, #results, 2 do
					local guid = results[index]
					if type(guid) == "string" and not Secret(guid) and not looted[guid] then
						looted[guid] = true
						local id = MobIDFromGUID(guid)
						local name = id and CreatureNameForID(id) or nil
						if name then
							local credit = xpCredits[name]
							if credit and credit > 0 then
								xpCredits[name] = credit - 1
							else
								lootCredits[name] = (lootCredits[name] or 0) + 1
								local zone = type(GetRealZoneText) == "function" and GetRealZoneText() or ""
								ns.NoteKill(name, zone)
								if ns.NoteEliteKill then
									ns.NoteEliteKill(name, instanceClassifications[id], zone)
								end
							end
						end
					end
				end
			end
		end
	end
	
end

-- Owner namespace for the kill source. NoteKill belongs to Core's combat
-- record, but the kill API reads through this one table. killSource stays a
-- flat mutable flag.
ns.kills = {}
ns.kills.Note = ns.NoteKill
ns.kills.ApplySource = ns.ApplyKillSource
ns.kills.SetNameplates = ns.SetNameplateKills
ns.kills.NameplatesActive = ns.NameplateKillsActive
ns.kills.NameplatesAvailable = ns.NameplateKillsAvailable
ns.kills.DebugText = ns.KillDebugText
ns.kills.NoteInstanceXp = ns.NoteInstanceXp
ns.kills.NoteInstanceLoot = ns.NoteInstanceLoot
