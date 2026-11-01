-- Tally - exploration: zones, instances, travel, flights and the quest
-- counts that belong to the world.
--
-- One character subtree is owned here: char.explore (and the quest counters
-- on the character). Core calls UpdateArea on an area change and ExploreTick
-- once a second; both keep their own state.
local addonName, ns = ...

local Now = ns.Now

-- Runtime state, never saved.
local currentZone
local inInstance = false
local currentInstance
local lastAreaKey
local taxiActive = false
local taxiResumeUntil = 0    -- a restored flight is trusted briefly while the client settles
local lastPosition            -- { x, y, mapID } of the previous UnitPosition

-- A zone has to hold for a few seconds before it is written to the record.
-- A loading-screen transition can name a between-area for one second; that
-- name should not become a permanent "1s" entry. The time is still counted in
-- memory, and the entry is committed if the character stays.
local PENDING_ZONE_SECONDS = 5
local pendingZones = {}       -- [zone] = { first, last, seconds, level }

-- kind is the client's instance type for an instance ("party", "raid",
-- "pvp", "arena", "scenario"), nil for a world zone. Older entries have only
-- instance = true and no kind; the UI says "instance" for those rather than
-- guessing dungeon or raid.
local function NoteVisit(explore, name, at, isInstance, kind)
	local recent = explore.recent
	if type(recent) ~= "table" then
		recent = {}
		explore.recent = recent
	end
	table.insert(recent, 1, {
		name = name, at = at,
		instance = isInstance or nil,
		kind = kind or nil,
	})
	while #recent > 40 do
		table.remove(recent)
	end
end

-- The client's instance type for the current area, or nil. Read here so a
-- saved visit can carry dungeon/raid/battleground instead of treating every
-- instance as a dungeon.
local function CurrentInstanceKind()
	if type(GetInstanceInfo) ~= "function" then
		return nil
	end
	local ok, _, instanceType = pcall(GetInstanceInfo)
	if ok and type(instanceType) == "string" and instanceType ~= "none" then
		return instanceType
	end
	return nil
end

local function NoteZone(zone, isArrival)
	if not zone or zone == "" or not ns.Tracks("explore") then
		return
	end
	local char = ns.GetChar()
	if not char then
		return
	end
	local now = Now()
	local explore = char.explore
	local instanceKind = CurrentInstanceKind()
	local isInstance = instanceKind ~= nil
	local entry = explore.zones[zone]
	for name in pairs(pendingZones) do
		if name ~= zone then
			pendingZones[name] = nil
		end
	end
	if not entry then
		local pending = pendingZones[zone]
		if not pending then
			pending = {
				first = now,
				last = now,
				seconds = 0,
				level = UnitLevel("player") or char.level,
				instance = isInstance or nil,
				kind = instanceKind,
			}
			pendingZones[zone] = pending
			-- A first arrival at a new zone is the only moment the client can
			-- award discovery XP. The very first area of a session is not an
			-- arrival, so it does not claim a discovery.
			if isArrival then
				ns.lastDiscoveryAt = now
			end
		end
		pending.last = now
		explore.lastZone = zone
		currentZone = zone
		ns.Trace("zone: "..zone.." - pending, "..PENDING_ZONE_SECONDS.."s before it is kept")
		return
	end
	-- A visit is a return: the character was somewhere else and came back, or
	-- Tally has never seen this place at all (a first visit counts 1 whatever
	-- brought the character there, so a new character's starting zone reads
	-- 1). A login or a UI reload is never an arrival, however the client
	-- names the place while it is still settling. Nothing is guessed: with no
	-- last-seen zone to compare (a record written before this was kept), an
	-- arrival that is not a first visit is not counted, and the next one can
	-- be.
	local visits = tonumber(entry.visits) or 0
	local firstVisit = visits == 0 and entry.last == entry.first
	local counted = false
	if firstVisit then
		counted = true
	elseif isArrival and explore.lastZone and explore.lastZone ~= zone then
		counted = true
	end
	if counted then
		visits = visits + 1
		entry.visits = visits
		-- An instance already notes its own entry in UpdateArea, with its
		-- kind; adding a world-zone line here would duplicate the same place.
		if not isInstance then
			NoteVisit(explore, zone, now, false)
		end
	end
	ns.Trace("zone: "..zone.." - "..(counted and (firstVisit and "first visit counted" or "return counted") or (isArrival and "no visit (same zone as the last one seen)" or "no visit (the session's first area)"))..", total "..tostring(visits))
	explore.lastZone = zone
	entry.last = now
	entry.lastSeenAt = now
	entry.updatedAt = now
	if ns.NoteRecentEvent then
		ns.NoteRecentEvent("zone", {
			at = now, zone = zone, how = "zone_entered", evidence = "zone_event",
			data = { name = zone, visits = visits },
		})
	end
	currentZone = zone
end

local function UpdateArea()
	-- Only the client's real zone name is used. The fallback (GetZoneText) can
	-- name the subzone, and while the client is still settling after a login
	-- it can answer with a subzone where it later answers with the zone - two
	-- names for one place, which invents a zone and reads as a visit. An
	-- empty answer means the client is not ready yet: nothing is written and
	-- the next area event does it.
	local zone = GetRealZoneText()
	if not zone or zone == "" then
		return
	end
	local instanceName, instanceType = GetInstanceInfo()
	local nowInInstance = instanceType and instanceType ~= "none"
	local areaKey = nowInInstance and ("instance:"..(instanceName or zone)) or ("world:"..zone)

	if areaKey ~= lastAreaKey then
		-- The first area of a session is where the character already was, so
		-- it is never an arrival: a login, and a UI reload, must not count as
		-- a visit to the zone the character is standing in. A place Tally has
		-- never seen still counts 1, since that is a first visit.
		local firstOfSession = (lastAreaKey == nil)
		if nowInInstance and ns.Tracks("explore") then
			local char = ns.GetChar()
			if char then
				local name = instanceName or zone
				-- Stage 6 may later show a first battleground or arena. The
				-- instance read already names the type, so store the first
				-- one now without drawing anything.
				if ns.NoteFutureFirst and (instanceType == "pvp" or instanceType == "arena") then
					ns.NoteFutureFirst(instanceType == "arena" and "arena" or "battleground", {
						at = Now(), zone = name, zoneKind = instanceType,
						name = name,
						observed = firstOfSession and "login" or "live",
						how = "instance_entered", evidence = "instance_info",
					})
				end
				local dungeon = char.explore.dungeons[name]
				if not dungeon then
					-- A new instance is a run however the character got there.
					dungeon = { entered = 1, bosses = 0, first = Now(), updatedAt = Now(), kind = instanceType }
					char.explore.dungeons[name] = dungeon
				elseif not firstOfSession and not dungeon.byTick then
					dungeon.entered = dungeon.entered + 1
				end
				if not dungeon.kind and instanceType then
					dungeon.kind = instanceType
				end
				dungeon.byTick = nil
				dungeon.last = Now()
				dungeon.updatedAt = Now()
				if ns.NoteDungeonMilestone then
					ns.NoteDungeonMilestone(char)
				end
				if not firstOfSession then
					NoteVisit(char.explore, name, Now(), true, instanceType)
				end
			end
		end
		lastAreaKey = areaKey
		NoteZone(zone, not firstOfSession)
		lastPosition = nil -- zone changes break the travel baseline
	end
	inInstance = nowInInstance and true or false
	currentInstance = nowInInstance and (instanceName or zone) or nil
end

local function OnEncounterEnd(encounterName, success)
	if success ~= 1 then
		return
	end
	local char = ns.GetChar()
	if not char then
		return
	end
	char.explore.bosses = (char.explore.bosses or 0) + 1
	if ns.NoteBossMilestone then
		ns.NoteBossMilestone(char.explore.bosses)
	end
	if inInstance and currentInstance then
		local dungeon = char.explore.dungeons[currentInstance]
		if not dungeon then
			dungeon = { entered = 0, bosses = 0 }
			char.explore.dungeons[currentInstance] = dungeon
		end
		dungeon.bosses = dungeon.bosses + 1
	end
	local kind
	if type(GetInstanceInfo) == "function" then
		local ok, _, instanceType = pcall(GetInstanceInfo)
		if ok then
			kind = instanceType
		end
	end
	if ns.NoteFirstBoss then
		ns.NoteFirstBoss(encounterName, currentInstance, kind)
	end
end

local function CommitPendingZone(char, zone, pending)
	local explore = char.explore
	local now = Now()
	local entry = {
		first = pending.first,
		last = now,
		lastSeenAt = now,
		updatedAt = now,
		visits = 1,
		seconds = pending.seconds,
		level = pending.level,
	}
	explore.zones[zone] = entry
	if type(explore.recentFirsts) ~= "table" then
		explore.recentFirsts = {}
	end
	explore.recentFirsts[#explore.recentFirsts + 1] = { name = zone, at = pending.first, level = entry.level }
	-- A first world-zone visit belongs in the recent list too. Instances note
	-- themselves in UpdateArea with their kind, so they are not duplicated.
	if not pending.instance then
		NoteVisit(explore, zone, pending.first, false)
	end
	if ns.NoteRecentEvent then
		ns.NoteRecentEvent("zone", {
			at = pending.first, zone = zone, how = "zone_entered", evidence = "zone_event",
			data = { name = zone, visits = 1, first = true },
		})
	end
	while #explore.recentFirsts > 20 do
		table.remove(explore.recentFirsts, 1)
	end
	local session = char.sessions.current
	if session then
		session.firsts[#session.firsts + 1] = zone
	end
	pendingZones[zone] = nil
	ns.Trace("zone: "..zone.." - kept after "..pending.seconds.."s")
end

local function ExploreTick(char, explore, session, dead)
	local now = Now()
	-- The instance state is read here, every second, rather than trusted from
	-- the last area event. A loading screen, a lag spike or a difficulty
	-- change can answer "no instance" for a moment, and the old code kept
	-- that answer until the next area event - which, in the middle of one
	-- long run, never came, so the rest of the run went uncounted. Reading it
	-- per second also picks a run up again once the client settles.
	if explore and type(GetInstanceInfo) == "function" then
		local liveName, liveType = GetInstanceInfo()
		if liveType and liveType ~= "none" then
			inInstance = true
			if liveName and liveName ~= "" then
				currentInstance = liveName
			end
		else
			inInstance = false
			currentInstance = nil
		end
	end

	if explore and currentZone then
		local zone = char.explore.zones[currentZone]
		if zone then
			zone.seconds = (zone.seconds or 0) + 1
			zone.lastSeenAt = now
			zone.updatedAt = now
		else
			local pending = pendingZones[currentZone]
			if pending then
				pending.seconds = pending.seconds + 1
				pending.last = Now()
				if pending.seconds >= PENDING_ZONE_SECONDS then
					CommitPendingZone(char, currentZone, pending)
				end
			end
		end
	end

	-- Instance time is also added to the dungeon's own record, so the
	-- dungeon list does not need to match zone names against instance names.
	if explore and inInstance and currentInstance then
		local dungeon = char.explore.dungeons[currentInstance]
		if not dungeon then
			-- A run the area event never announced. The client can change the
			-- instance's name in the middle of one (a teleport with a loading
			-- screen does), and the new name has no record yet. It is created
			-- here so the time is not silently dropped, and flagged so the
			-- next area event does not count the same run twice.
			dungeon = { entered = 1, bosses = 0, first = Now(), last = Now(), byTick = true }
			char.explore.dungeons[currentInstance] = dungeon
			if ns.NoteDungeonMilestone then
				ns.NoteDungeonMilestone(char)
			end
		end
		dungeon.seconds = (dungeon.seconds or 0) + 1
		dungeon.lastSeenAt = now
		dungeon.updatedAt = now
	end

	local onTaxi = UnitOnTaxi and UnitOnTaxi("player")
	if explore then
		if onTaxi then
			-- The client has now confirmed the flight; a restored state no
			-- longer needs its settling grace.
			taxiResumeUntil = 0
			if not taxiActive then
				taxiActive = true
				char.explore.flights = (char.explore.flights or 0) + 1
				char.explore.firstFlightAt = char.explore.firstFlightAt or now
				char.explore.lastFlightAt = now
				if session then
					session.flights = (session.flights or 0) + 1
				end
			end
			char.explore.flightSeconds = (char.explore.flightSeconds or 0) + 1
			if ns.NoteFlightTimeMilestone then
				ns.NoteFlightTimeMilestone(char.explore.flightSeconds)
			end
			if session then
				session.flightSeconds = (session.flightSeconds or 0) + 1
			end
			lastPosition = nil
		else
			-- A flight restored from the last logout stays "in progress" for a
			-- moment: the client can answer UnitOnTaxi late on the first
			-- ticks, and a false answer there must not turn the same flight
			-- into a second one.
			if taxiResumeUntil > 0 and now < taxiResumeUntil then
				-- still settling
			else
				taxiActive = false
				taxiResumeUntil = 0
			end
			if not dead then
				local x, y, z, mapID = UnitPosition("player")
				if x and y and mapID then
					if lastPosition and lastPosition.mapID == mapID then
						local dx, dy = x - lastPosition.x, y - lastPosition.y
						local distance = math.sqrt(dx * dx + dy * dy)
						-- Below 0.05 yards is float jitter; above 200 in one
						-- tick is a teleport, not a step.
						if distance > 0.05 and distance < 200 then
							local before = (tonumber(char.explore.distance) or 0)
							char.explore.distance = before + distance
							-- The same step is credited to the mounted or the
							-- on-foot bucket. A record with only the legacy
							-- total seeds both buckets from it first, so the
							-- split does not appear to start at zero.
							if char.explore.distanceMounted == nil then
								char.explore.distanceMounted = 0
							end
							if char.explore.distanceOnFoot == nil then
								char.explore.distanceOnFoot = math.max(0, before - (char.explore.distanceMounted or 0))
							end
							if type(IsMounted) == "function" and IsMounted() then
								char.explore.distanceMounted = char.explore.distanceMounted + distance
								if ns.NoteMountedDistanceMilestone then
									ns.NoteMountedDistanceMilestone(char.explore.distanceMounted)
								end
							else
								char.explore.distanceOnFoot = char.explore.distanceOnFoot + distance
								if ns.NoteFootDistanceMilestone then
									ns.NoteFootDistanceMilestone(char.explore.distanceOnFoot)
								end
							end
							char.explore.distanceAt = now
							char.explore.distanceUpdatedAt = now
							if ns.NoteDistanceMilestone then
								ns.NoteDistanceMilestone(char.explore.distance)
							end
							if session then
								session.distance = (session.distance or 0) + distance
							end
						end
					end
					lastPosition = { x = x, y = y, mapID = mapID }
				end
			end
		end
	end
end

-- The record was just replaced or the character just logged in: re-note the
-- zone the character is standing in as the first entry of the new record.
function ns.ResumeZone()
	if currentZone then
		NoteZone(currentZone, true)
	end
end

function ns.CurrentZone()
	return currentZone
end

-- State that must survive a logout because the activity itself does: a flight
-- that was running when the client closed must not count as a new one when the
-- next login resumes it. Written at PLAYER_LOGOUT, read once at login.
local TAXI_RESUME_GRACE = 10

function ns.ExploreSnapshotPresence()
	local onTaxi = false
	if type(UnitOnTaxi) == "function" then
		local ok, taxi = pcall(UnitOnTaxi, "player")
		onTaxi = ok and taxi and true or false
	end
	return { onTaxi = onTaxi }
end

function ns.ExploreRestorePresence(presence)
	if type(presence) ~= "table" or not presence.onTaxi then
		return
	end
	-- Seeded as active, so the first taxi tick continues the flight instead
	-- of counting it. If the player lands, the grace lets a late client
	-- answer settle before the state is dropped.
	taxiActive = true
	taxiResumeUntil = Now() + TAXI_RESUME_GRACE
	ns.Trace("presence: resuming a flight in progress")
end

ns.UpdateArea = UpdateArea
ns.OnEncounterEnd = OnEncounterEnd
ns.ExploreTick = ExploreTick
-- Owner namespace. Every field references the flat API above.
ns.explore = {}
ns.explore.UpdateArea = ns.UpdateArea
ns.explore.OnEncounterEnd = ns.OnEncounterEnd
ns.explore.ExploreTick = ns.ExploreTick
ns.explore.CurrentZone = ns.CurrentZone
ns.explore.ResumeZone = ns.ResumeZone
ns.explore.SnapshotPresence = ns.ExploreSnapshotPresence
ns.explore.RestorePresence = ns.ExploreRestorePresence
