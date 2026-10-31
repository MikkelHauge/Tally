-- Tally - the Combat tab: page shell, sub-view frames and selection.
--
-- Fights and deaths, kills and auras each own a file. This file only builds
-- their frames, switches between them and keeps the kill list fresh while a
-- different sub-view is shown.
local addonName, ns = ...

local ACCENT, combatWidgets, BuildCombatFights, RefreshCombatFights, BuildCombatAuras, RefreshCombatAuras, BuildCombatKills, RefreshCombatKills, pageRefresh =
	ns.ACCENT, ns.combatWidgets, ns.BuildCombatFights, ns.RefreshCombatFights, ns.BuildCombatAuras, ns.RefreshCombatAuras, ns.BuildCombatKills, ns.RefreshCombatKills, ns.pageRefresh

local function RefreshCombat()
	if not combatWidgets.first then
		return
	end
	-- The kill list is kept current even while another sub-view is shown, as
	-- it was before the split: a tick updates the records the Kills tab will
	-- draw when it is opened.
	if RefreshCombatKills then
		RefreshCombatKills()
	end
	if combatWidgets.subview == "auras" then
		RefreshCombatAuras()
		return
	end
	RefreshCombatFights()
end

-- The combat page's three sub-views: fights, kills and auras.
local function SelectCombatSubview(name)
	combatWidgets.subview = name
	if combatWidgets.fightsFrame then
		combatWidgets.fightsFrame:SetShown(name == "fights")
	end
	if combatWidgets.killsFrame then
		combatWidgets.killsFrame:SetShown(name == "kills")
	end
	if combatWidgets.aurasFrame then
		combatWidgets.aurasFrame:SetShown(name == "auras")
	end
	-- The aura and kill cards own the tooltip while the cursor is over them,
	-- so it is dropped as the sub-view is left.
	if name ~= "auras" then
		for _, card in ipairs({ combatWidgets.buffs, combatWidgets.debuffs }) do
			card.hoverKey = nil
			if GameTooltip:IsOwned(card) then
				GameTooltip:Hide()
			end
		end
	end
	if name ~= "kills" then
		for _, card in ipairs({ combatWidgets.killsCreature, combatWidgets.killsZone }) do
			if card then
				card.hoverKey = nil
				if GameTooltip:IsOwned(card) then
					GameTooltip:Hide()
				end
			end
		end
	end
	local buttons = combatWidgets.subButtons or {}
	for id, button in pairs(buttons) do
		local active = (id == name)
		button.underline:SetShown(active)
		button.text:SetTextColor(active and ACCENT[1] or 0.62, active and ACCENT[2] or 0.62, active and ACCENT[3] or 0.62)
	end
	RefreshCombat()
end

local function BuildCombatPage(page)
	-- Sub-view switch, the same widget the economy and total pages use.
	combatWidgets.subButtons = {}
	local x = 2
	local function AddSubButton(id, title)
		local button = CreateFrame("Button", nil, page)
		button:SetHeight(18)
		button.text = button:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
		button.text:SetPoint("LEFT", 0, 0)
		button.text:SetText(title)
		button:SetWidth(button.text:GetStringWidth() + 20)
		button:SetPoint("TOPLEFT", page, "TOPLEFT", x, -2)
		button.underline = button:CreateTexture(nil, "ARTWORK")
		button.underline:SetColorTexture(ACCENT[1], ACCENT[2], ACCENT[3], 0.9)
		button.underline:SetHeight(2)
		button.underline:SetPoint("TOPLEFT", button.text, "BOTTOMLEFT", -2, -2)
		button.underline:SetPoint("TOPRIGHT", button.text, "BOTTOMRIGHT", 2, -2)
		button:RegisterForClicks("LeftButtonUp")
		button:SetScript("OnClick", function()
			SelectCombatSubview(id)
		end)
		combatWidgets.subButtons[id] = button
		x = x + button:GetWidth() + 10
	end
	AddSubButton("fights", "Fights & deaths")
	AddSubButton("kills", "Kills")
	AddSubButton("auras", "Buffs & debuffs")

	local fights = CreateFrame("Frame", nil, page)
	fights:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	fights:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	combatWidgets.fightsFrame = fights
	BuildCombatFights(fights)

	-- Buffs and debuffs: the campfire figures as tiles, then one card each.
	local auras = CreateFrame("Frame", nil, page)
	auras:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	auras:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	auras:Hide()
	combatWidgets.aurasFrame = auras
	BuildCombatAuras(auras)

	-- Kills: total, records, creatures and zones.
	local kills = CreateFrame("Frame", nil, page)
	kills:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	kills:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	kills:Hide()
	combatWidgets.killsFrame = kills
	BuildCombatKills(kills)

	SelectCombatSubview("fights")
	pageRefresh.combat = RefreshCombat
end

-- Handed to the shell, which builds and refreshes every tab.
ns.BuildCombatPage, ns.RefreshCombat = BuildCombatPage, RefreshCombat
