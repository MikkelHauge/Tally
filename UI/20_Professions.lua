-- Tally - the Character tab's Professions sub-view: the skill gained at each
-- character level, one column per profession the character has.
--
-- This used to be the by-level toggle on Economy's Secondary professions card,
-- which mixed the primary gathering professions with the secondary ones. It
-- lives with the character now, where the whole profession set belongs.
local addonName, ns = ...

local charactersProfessionsWidgets = { offset = 0 }

local function RefreshCharacterProfessions()
	local card = charactersProfessionsWidgets.card
	if not card then
		return
	end
	local char = ns.DisplayChar()
	local key = (char and char.name or "").."|"..(char and char.realm or "")
	if charactersProfessionsWidgets.charKey ~= key then
		charactersProfessionsWidgets.charKey = key
		charactersProfessionsWidgets.offset = 0
	end
	if ns.professionsUI then
		ns.professionsUI.RefreshLevelCard(card, char)
	end
end

local function BuildCharacterProfessions(page)
	local card = ns.professionsUI.BuildLevelCard(page, 0, -4, 730, 430,
		charactersProfessionsWidgets, "offset", RefreshCharacterProfessions,
		"Professions by level")
	charactersProfessionsWidgets.card = card
	RefreshCharacterProfessions()
end

ns.BuildCharacterProfessions = BuildCharacterProfessions
ns.RefreshCharacterProfessions = RefreshCharacterProfessions
