-- Tally - the Character tab: the old overview plus the new one-time
-- milestones. The overview keeps its own file and is left exactly as it was;
-- this file only owns the sub-view switch.
local addonName, ns = ...

local ACCENT, pageRefresh, BuildOverviewPage, RefreshOverview,
	BuildMilestonesPage, RefreshMilestones, BuildTimelinePage, RefreshTimeline,
	BuildSocialPage, RefreshSocial,
	BuildCharacterProfessions, RefreshCharacterProfessions =
	ns.ACCENT, ns.pageRefresh, ns.BuildOverviewPage, ns.RefreshOverview,
	ns.BuildMilestonesPage, ns.RefreshMilestones, ns.BuildTimelinePage, ns.RefreshTimeline,
	ns.BuildSocialPage, ns.RefreshSocial,
	ns.BuildCharacterProfessions, ns.RefreshCharacterProfessions

local characterWidgets = { subview = "overview" }

local function RefreshCharacter()
	if not characterWidgets.overviewFrame then
		return
	end
	if characterWidgets.subview == "milestones" then
		RefreshMilestones()
	elseif characterWidgets.subview == "professions" then
		RefreshCharacterProfessions()
	elseif characterWidgets.subview == "timeline" then
		RefreshTimeline()
	elseif characterWidgets.subview == "social" then
		RefreshSocial()
	else
		RefreshOverview()
	end
end

local function SelectCharacterSubview(name)
	characterWidgets.subview = name
	if characterWidgets.overviewFrame then
		characterWidgets.overviewFrame:SetShown(name == "overview")
	end
	if characterWidgets.milestonesFrame then
		characterWidgets.milestonesFrame:SetShown(name == "milestones")
	end
	if characterWidgets.professionsFrame then
		characterWidgets.professionsFrame:SetShown(name == "professions")
	end
	if characterWidgets.timelineFrame then
		characterWidgets.timelineFrame:SetShown(name == "timeline")
	end
	if characterWidgets.socialFrame then
		characterWidgets.socialFrame:SetShown(name == "social")
	end
	local buttons = characterWidgets.subButtons or {}
	for id, button in pairs(buttons) do
		local active = (id == name)
		button.underline:SetShown(active)
		button.text:SetTextColor(active and ACCENT[1] or 0.62, active and ACCENT[2] or 0.62, active and ACCENT[3] or 0.62)
	end
	RefreshCharacter()
end

local function BuildCharacterPage(page)
	characterWidgets.subButtons = {}
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
			SelectCharacterSubview(id)
		end)
		characterWidgets.subButtons[id] = button
		x = x + button:GetWidth() + 10
	end
	AddSubButton("overview", "Overview")
	AddSubButton("professions", "Professions")
	AddSubButton("milestones", "Milestones")
	AddSubButton("timeline", "Timeline")
	AddSubButton("social", "Social")

	local overview = CreateFrame("Frame", nil, page)
	overview:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	overview:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	characterWidgets.overviewFrame = overview
	BuildOverviewPage(overview)

	local professions = CreateFrame("Frame", nil, page)
	professions:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	professions:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	professions:Hide()
	characterWidgets.professionsFrame = professions
	BuildCharacterProfessions(professions)

	local milestones = CreateFrame("Frame", nil, page)
	milestones:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	milestones:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	milestones:Hide()
	characterWidgets.milestonesFrame = milestones
	BuildMilestonesPage(milestones)

	local timelineFrame = CreateFrame("Frame", nil, page)
	timelineFrame:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	timelineFrame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	timelineFrame:Hide()
	characterWidgets.timelineFrame = timelineFrame
	BuildTimelinePage(timelineFrame)

	local socialFrame = CreateFrame("Frame", nil, page)
	socialFrame:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -26)
	socialFrame:SetPoint("BOTTOMRIGHT", page, "BOTTOMRIGHT", 0, 0)
	socialFrame:Hide()
	characterWidgets.socialFrame = socialFrame
	BuildSocialPage(socialFrame)

	SelectCharacterSubview("overview")
	pageRefresh.overview = RefreshCharacter
end

ns.BuildCharacterPage = BuildCharacterPage
ns.RefreshCharacter = RefreshCharacter
