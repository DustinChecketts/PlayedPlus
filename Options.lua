--[[
Played Plus - Options
=============================
This file owns only Blizzard Settings/AddOns controls.

Gameplay tracking, SavedVariables migration, and XP classification belong in
PlayedPlus.lua. Options should mutate preferences and request a refresh.
--]]

PlayedPlus = PlayedPlus or {}
local PP = PlayedPlus
local Compat = PP.Compat

local PANEL_NAME = "Played Plus"

local DEFAULTS = {
    showLabels = true,
    showTooltips = true,
    showDetails = true,
    showStatus = true,
    debugXPLog = false,
}

local panel = CreateFrame("Frame", "PlayedPlusOptionsPanel")
panel.name = PANEL_NAME

local controls = {}

local function EnsureDB()
    if type(PlayedPlusDB) ~= "table"
        and type(PlayedTrackerPlusDB) == "table" then
        PlayedPlusDB = PlayedTrackerPlusDB
    end

    if type(PlayedPlusDB) ~= "table" then
        PlayedPlusDB = {}
    end

    for key, value in pairs(DEFAULTS) do
        if PlayedPlusDB[key] == nil then
            PlayedPlusDB[key] = value
        end
    end

    return PlayedPlusDB
end

local function RefreshTracker()
    if PlayedPlus_RefreshTracker then
        PlayedPlus_RefreshTracker()
    end
end

local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
title:SetPoint("TOPLEFT", 16, -16)
title:SetText("Played Plus")

local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
subtitle:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8)
subtitle:SetText("Display options for level, daily, and account playtime history.")

local displayHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
displayHeader:SetPoint("TOPLEFT", 20, -82)
displayHeader:SetText("Tracker Window")

local function CreateOptionCheckbox(name, label, key, x, y)
    -- UICheckButtonTemplate is available on WoW Forever and avoids relying on
    -- the removed legacy Interface Options checkbox template.
    local check = CreateFrame("CheckButton", name, panel, "UICheckButtonTemplate")

    check:SetPoint("TOPLEFT", x, y)

    local labelText = check:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    labelText:SetPoint("LEFT", check, "RIGHT", 2, 0)
    labelText:SetText(label)

    check:SetScript("OnClick", function(self)
        EnsureDB()[key] = self:GetChecked() and true or false
        RefreshTracker()
    end)

    check.Refresh = function()
        check:SetChecked(EnsureDB()[key] and true or false)
    end

    table.insert(controls, check)
    return check
end

CreateOptionCheckbox("PlayedPlusShowLabels", "Show Labels", "showLabels", 24, -120)
CreateOptionCheckbox("PlayedPlusShowTooltips", "Show Tooltips", "showTooltips", 220, -120)
CreateOptionCheckbox("PlayedPlusShowDetails", "Show Details Column", "showDetails", 24, -155)
CreateOptionCheckbox("PlayedPlusShowStatus", "Show Status Column", "showStatus", 220, -155)
CreateOptionCheckbox("PlayedPlusDebugXPLog", "Debug XP Logging to Chat", "debugXPLog", 24, -190)

local debugHelp = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
debugHelp:SetPoint("TOPLEFT", 48, -216)
debugHelp:SetWidth(430)
debugHelp:SetJustifyH("LEFT")
debugHelp:SetText("Prints one finalized chat line per XP transaction after classification settles.")

local openButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
openButton:SetSize(130, 24)
openButton:SetPoint("TOPLEFT", 24, -260)
openButton:SetText("Open Tracker")
openButton:SetScript("OnClick", function()
    if PlayedPlus_OpenTracker then
        PlayedPlus_OpenTracker()
    end
end)

local resetButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
resetButton:SetSize(130, 24)
resetButton:SetPoint("LEFT", openButton, "RIGHT", 12, 0)
resetButton:SetText("Reset Defaults")
resetButton:SetScript("OnClick", function()
    if PlayedPlus_ResetDisplayDefaults then
        PlayedPlus_ResetDisplayDefaults()
    end

    for _, control in ipairs(controls) do
        if control.Refresh then
            control.Refresh()
        end
    end
end)

panel:SetScript("OnShow", function()
    for _, control in ipairs(controls) do
        if control.Refresh then
            control.Refresh()
        end
    end
end)

if Settings
    and Settings.RegisterCanvasLayoutCategory
    and Settings.RegisterAddOnCategory then

    PP.OptionsCategory = Settings.RegisterCanvasLayoutCategory(panel, PANEL_NAME)
    Settings.RegisterAddOnCategory(PP.OptionsCategory)
elseif InterfaceOptions_AddCategory then
    InterfaceOptions_AddCategory(panel)
end

function PlayedPlus_OpenOptions()
    if Compat and Compat.OpenSettings then
        if Compat.OpenSettings(PP.OptionsCategory, panel) then
            return
        end
    elseif Settings and Settings.OpenToCategory and PP.OptionsCategory then
        Settings.OpenToCategory(PP.OptionsCategory:GetID())
        return
    elseif InterfaceOptionsFrame_OpenToCategory then
        InterfaceOptionsFrame_OpenToCategory(panel)
        InterfaceOptionsFrame_OpenToCategory(panel)
        return
    end

    if DEFAULT_CHAT_FRAME then
        DEFAULT_CHAT_FRAME:AddMessage("|cff66c0ff/Played Plus:|r Unable to open the options panel on this client.")
    end
end
