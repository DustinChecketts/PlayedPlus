-- Played Plus client/API compatibility layer
--
-- Keep differences between WoW client API surfaces here so the tracker and
-- SavedVariables logic can remain client-agnostic. Prefer capability detection
-- over project IDs; WoW Forever currently reports the Mainline project ID.

PlayedPlus = PlayedPlus or {}
local PP = PlayedPlus

PP.Compat = PP.Compat or {}
local Compat = PP.Compat

function Compat.GetInterfaceVersion()
    if not GetBuildInfo then
        return nil
    end

    return select(4, GetBuildInfo())
end

-- WoW Forever currently reports WOW_PROJECT_MAINLINE. Its 16xxx interface
-- generation is the reliable discriminator from Retail for the current beta.
function Compat.IsForever()
    local interfaceVersion = Compat.GetInterfaceVersion()

    return WOW_PROJECT_ID == WOW_PROJECT_MAINLINE
        and type(interfaceVersion) == "number"
        and interfaceVersion >= 16000
        and interfaceVersion < 17000
end

function Compat.RegisterEvent(frame, eventName)
    if not frame or not eventName then
        return false
    end

    local ok = pcall(frame.RegisterEvent, frame, eventName)
    return ok
end

function Compat.OpenSettings(category, legacyPanel)
    if Settings and Settings.OpenToCategory and category then
        local categoryID = category.GetID and category:GetID() or category
        Settings.OpenToCategory(categoryID)
        return true
    end

    if InterfaceOptionsFrame_OpenToCategory and legacyPanel then
        InterfaceOptionsFrame_OpenToCategory(legacyPanel)
        InterfaceOptionsFrame_OpenToCategory(legacyPanel)
        return true
    end

    return false
end
