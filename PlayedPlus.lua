--[[
Played Plus
===================

Architecture
------------
1. PlayedPlusDB
   Per-character SavedVariables. Owns:
   - daily and per-level played time
   - quest/dungeon activity counts
   - the authoritative XP ledger for this character
   - display/debug preferences

2. PlayedPlusAccountDB
   Account-wide SavedVariables grouped by realm. Owns:
   - per-character daily played-time snapshots used by the Days view

3. XP ledger
   UnitXP("player") deltas are authoritative. Quest/combat/system events
   classify an already-captured XP transaction; they do not create separate
   XP totals. UI totals and source percentages are derived from the ledger.

Maintenance rules
-----------------
Capture XP first and classify second. Do not add a parallel XP counter that
can drift from the canonical ledger.

Each character's daily played total is authoritative. The account-wide realm
database stores snapshots of that total; it does not run a second timer.

See ARCHITECTURE.md for persisted-data layout and extension guidance.
--]]

local ADDON_NAME = ...

local eventFrame = CreateFrame("Frame")

-- ============================================================================
-- Configuration and runtime constants
-- ============================================================================
-- Schema versions change only when persisted data requires migration.
local DB_VERSION = 27
local ACCOUNT_DB_VERSION = 3
local LEDGER_VERSION = 1
local TICK_INTERVAL = 1
-- XP collection is event-driven first, with UnitXP polling as a reliability
-- backstop. Classification queues are runtime-only and never persisted.
local XP_POLL_INTERVAL = 0.25
local XP_SIGNAL_WINDOW = 3.0
local XP_DEBUG_SETTLE_DELAY = 1.50
local MAX_ROWS = 10

local sessionStarted = false
local lastTick = nil
local tickAccumulator = 0
local xpPollAccumulator = 0
local pendingPlayedRequest = false

local historyFrame = nil
local currentView = "levels"

local xpObserved = false
local observedLevel = nil
local observedXP = nil
local observedXPMax = nil

local recentTransactions = {}
local pendingSignals = {}
local nextRuntimeTransactionID = 0

local XP_COLORS = {
    mob = { 0.25, 0.70, 0.20, 0.95 },
    quest = { 0.15, 0.45, 0.85, 0.95 },
    dungeon = { 0.55, 0.20, 0.75, 0.95 },
    exploration = { 0.95, 0.72, 0.08, 0.95 },
    other = { 0.50, 0.50, 0.50, 0.95 },
}

local FALLBACK_CLASS_COLOR = { 0.65, 0.65, 0.65, 0.95 }

local function GetClassColor(classFile)
    local color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]

    if color then
        return { color.r or 0.65, color.g or 0.65, color.b or 0.65, 0.95 }
    end

    return FALLBACK_CLASS_COLOR
end

-- Higher-confidence signals may replace lower-confidence classifications
-- for the same canonical XP transaction.
local CLASSIFICATION_PRIORITY = {
    unclassified = 0,
    mob = 40,
    dungeon = 50,
    exploration = 90,
    quest = 100,
}

local TBC_FINAL_DUNGEON_BOSSES = {
    ["Nazan"] = true,
    ["Keli'dan the Breaker"] = true,
    ["Warchief Kargath Bladefist"] = true,
    ["Quagmirran"] = true,
    ["The Black Stalker"] = true,
    ["Warlord Kalithresh"] = true,
    ["Nexus-Prince Shaffar"] = true,
    ["Exarch Maladaar"] = true,
    ["Talon King Ikiss"] = true,
    ["Murmur"] = true,
    ["Epoch Hunter"] = true,
    ["Aeonus"] = true,
    ["Pathaleon the Calculator"] = true,
    ["Warp Splinter"] = true,
    ["Harbinger Skyriss"] = true,
    ["Kael'thas Sunstrider"] = true,
}

local lastAutomaticDungeonCompletion = 0
local lastAutomaticDungeonName = nil

-- ============================================================================
-- General utilities and formatting
-- ============================================================================
local function Print(message)
    DEFAULT_CHAT_FRAME:AddMessage(
        "|cff66c0ff/Played Plus:|r " .. tostring(message)
    )
end

local function DebugXPEnabled()
    local db = PlayedPlusDB
    return type(db) == "table" and db.debugXPLog == true
end

local function Clamp(value, low, high)
    value = tonumber(value) or 0

    if value < low then
        return low
    elseif value > high then
        return high
    end

    return value
end

local function FormatDuration(seconds)
    seconds = math.max(0, math.floor(tonumber(seconds) or 0))

    local days = math.floor(seconds / 86400)
    seconds = seconds % 86400

    local hours = math.floor(seconds / 3600)
    seconds = seconds % 3600

    local minutes = math.floor(seconds / 60)
    local secs = seconds % 60

    if days > 0 then
        return string.format("%dd %dh %dm", days, hours, minutes)
    elseif hours > 0 then
        return string.format("%dh %dm", hours, minutes)
    elseif minutes > 0 then
        return string.format("%dm %ds", minutes, secs)
    end

    return string.format("%ds", secs)
end

local function GetDateKey(timestamp)
    return date("%Y-%m-%d", timestamp or time())
end

-- ============================================================================
-- SavedVariables: per-character database
-- ============================================================================
local function EnsureDatabase()
    -- One-time rename migration from Played Tracker Plus.
    if type(PlayedPlusDB) ~= "table"
        and type(PlayedTrackerPlusDB) == "table" then
        PlayedPlusDB = PlayedTrackerPlusDB
    end

    if type(PlayedPlusDB) ~= "table" then
        PlayedPlusDB = {}
    end

    local db = PlayedPlusDB

    db.version = DB_VERSION
    db.createdAt = db.createdAt or time()
    db.lastSeenAt = time()
    db.totalTracked = tonumber(db.totalTracked) or 0
    db.lastKnownTotalPlayed = tonumber(db.lastKnownTotalPlayed) or 0
    db.currentLevel = tonumber(db.currentLevel) or UnitLevel("player") or 1
    db.days = db.days or {}
    db.levels = db.levels or {}
    db.nextXPEventID = tonumber(db.nextXPEventID) or 1

    db.windowOpacity = tonumber(db.windowOpacity) or 0.70
    db.windowOpacity = Clamp(db.windowOpacity, 0.20, 1.00)

    if db.showLabels == nil then db.showLabels = true end
    if db.showTooltips == nil then db.showTooltips = true end
    if db.showDetails == nil then db.showDetails = true end
    if db.showStatus == nil then db.showStatus = true end
    if db.debugXPLog == nil then db.debugXPLog = false end

    return db
end

-- ============================================================================
-- SavedVariables: account / realm database
-- ============================================================================
local function GetRealmKey()
    local realm = GetRealmName and GetRealmName() or "Unknown Realm"
    if realm == "" then realm = "Unknown Realm" end
    return realm
end

local function GetCharacterKey()
    local name = UnitName("player") or "Unknown"
    return name .. "-" .. GetRealmKey()
end

local function EnsureAccountDatabase()
    -- One-time account-wide rename migration from Played Tracker Plus.
    if type(PlayedPlusAccountDB) ~= "table"
        and type(PlayedTrackerPlusAccountDB) == "table" then
        PlayedPlusAccountDB = PlayedTrackerPlusAccountDB
    end

    if type(PlayedPlusAccountDB) ~= "table" then
        PlayedPlusAccountDB = {}
    end

    local db = PlayedPlusAccountDB
    db.version = ACCOUNT_DB_VERSION
    db.realms = db.realms or {}

    local realmKey = GetRealmKey()
    if type(db.realms[realmKey]) ~= "table" then
        db.realms[realmKey] = { characters = {}, days = {} }
    end

    local realm = db.realms[realmKey]
    realm.characters = realm.characters or {}
    realm.days = realm.days or {}

    local characterKey = GetCharacterKey()
    local name = UnitName("player") or "Unknown"
    local _, classFile = UnitClass("player")

    if type(realm.characters[characterKey]) ~= "table" then
        realm.characters[characterKey] = {}
    end

    local character = realm.characters[characterKey]
    character.name = name
    character.realm = realmKey
    character.classFile = classFile or character.classFile or "UNKNOWN"
    character.guid = (UnitGUID and UnitGUID("player")) or character.guid
    character.level = UnitLevel("player") or character.level

    local characterDB = PlayedPlusDB
    if type(characterDB) == "table"
        and tonumber(characterDB.lastKnownTotalPlayed) then
        character.totalPlayed = math.max(
            tonumber(character.totalPlayed) or 0,
            tonumber(characterDB.lastKnownTotalPlayed) or 0
        )
    else
        character.totalPlayed = tonumber(character.totalPlayed) or 0
    end

    character.lastSeenAt = time()

    return db, realm, characterKey, character
end

local function EnsureAccountDay(dateKey)
    local _, realm = EnsureAccountDatabase()
    dateKey = dateKey or GetDateKey()

    if type(realm.days[dateKey]) ~= "table" then
        realm.days[dateKey] = { characters = {} }
    end

    local day = realm.days[dateKey]
    day.characters = day.characters or {}
    return day
end

-- Snapshot the current character's authoritative daily total into the
-- shared realm DB. Assignment rather than incrementing prevents double-counts
-- across reloads and character switches.
local function SyncCharacterDayToAccount(dateKey)
    local db = EnsureDatabase()
    local _, _, characterKey, character = EnsureAccountDatabase()

    dateKey = dateKey or GetDateKey()

    local characterDay = db.days and db.days[dateKey]
    local seconds = 0

    if type(characterDay) == "table" then
        seconds = tonumber(characterDay.seconds) or 0
    end

    local accountDay = EnsureAccountDay(dateKey)
    local entry = accountDay.characters[characterKey]

    if type(entry) ~= "table" then
        entry = {}
        accountDay.characters[characterKey] = entry
    end

    entry.name = character.name
    entry.classFile = character.classFile
    entry.seconds = seconds
    entry.syncedAt = time()
end

local function SyncAllCharacterDaysToAccount()
    local db = EnsureDatabase()

    for dateKey in pairs(db.days or {}) do
        SyncCharacterDayToAccount(dateKey)
    end
end

local function ImportLegacyCharacterDays()
    local db = EnsureDatabase()

    db.accountDayImportVersion =
        tonumber(db.accountDayImportVersion) or 0

    if db.accountDayImportVersion < 2 then
        SyncAllCharacterDaysToAccount()
        db.accountDayImportVersion = 2
    end
end

-- ============================================================================
-- Character day / level records
-- ============================================================================
local function EnsureDay(dateKey)
    local db = EnsureDatabase()
    dateKey = dateKey or GetDateKey()

    if type(db.days[dateKey]) ~= "table" then
        db.days[dateKey] = {
            seconds = 0,
            quests = 0,
            mobs = 0,
            dungeons = 0,
        }
    end

    local day = db.days[dateKey]

    day.seconds = tonumber(day.seconds) or 0
    day.quests = tonumber(day.quests) or 0
    day.mobs = tonumber(day.mobs) or 0
    day.dungeons = tonumber(day.dungeons) or 0

    return day
end

local function EnsureLevel(level)
    local db = EnsureDatabase()
    level = tonumber(level) or UnitLevel("player") or db.currentLevel or 1

    if type(db.levels[level]) ~= "table" then
        db.levels[level] = {
            level = level,
            startedAt = time(),
            seconds = 0,
            quests = 0,
            mobs = 0,
            dungeons = 0,
            ledger = {},
        }
    end

    local levelData = db.levels[level]

    levelData.level = level
    levelData.startedAt = levelData.startedAt or time()
    levelData.seconds = tonumber(levelData.seconds) or 0
    levelData.quests = tonumber(levelData.quests) or 0
    levelData.mobs = tonumber(levelData.mobs) or 0
    levelData.dungeons = tonumber(levelData.dungeons) or 0
    levelData.ledger = levelData.ledger or {}

    return levelData
end

local function NextXPEventID()
    local db = EnsureDatabase()
    local id = db.nextXPEventID
    db.nextXPEventID = id + 1
    return id
end

-- ============================================================================
-- XP ledger migration and normalization
-- ============================================================================
local function NormalizeSource(source)
    if source == "mob" or source == "quest"
        or source == "dungeon" or source == "other" then
        return source
    end

    return "other"
end

local function SourceSubtype(source, reason)
    if reason == "exploration" then
        return "exploration"
    elseif source == "quest" then
        return "quest"
    elseif source == "mob" or source == "dungeon" then
        return "kill"
    end

    return "unclassified"
end

local function CopyEventContext(target, source)
    local fields = {
        "rawMessage",
        "questID",
        "zone",
        "instanceName",
        "instanceType",
        "inInstance",
        "reason",
        "subtype",
        "classificationPriority",
    }

    for _, key in ipairs(fields) do
        if source[key] ~= nil then
            target[key] = source[key]
        end
    end
end

local function BuildLegacyLedger(levelData)
    if type(levelData.ledger) == "table" and #levelData.ledger > 0 then
        return
    end

    levelData.ledger = {}

    local oldEvents = levelData.xpEvents or {}
    local earliestCanonicalAt = nil

    for _, event in ipairs(oldEvents) do
        if event.canonical and event.at then
            if not earliestCanonicalAt or event.at < earliestCanonicalAt then
                earliestCanonicalAt = event.at
            end
        end
    end

    local skip = {}

    -- Remove the known pre-ledger quest/combat duplicate pattern.
    for qi, q in ipairs(oldEvents) do
        if q.source == "quest" and tonumber(q.amount) and q.at then
            for mi, m in ipairs(oldEvents) do
                if not skip[mi]
                    and m.source == "mob"
                    and tonumber(m.amount) == tonumber(q.amount)
                    and m.at
                    and math.abs(m.at - q.at) <= 1 then
                    skip[mi] = true
                    break
                end
            end
        end
    end

    for index, event in ipairs(oldEvents) do
        local include = not skip[index]

        if include and earliestCanonicalAt and not event.canonical then
            if not event.at or event.at >= earliestCanonicalAt then
                include = false
            end
        end

        if include then
            local source = NormalizeSource(event.source)
            local reason = event.reason
            local subtype = SourceSubtype(source, reason)

            local imported = {
                id = NextXPEventID(),
                at = tonumber(event.at) or time(),
                level = levelData.level,
                amount = math.max(0, math.floor(tonumber(event.amount) or 0)),
                source = source,
                subtype = subtype,
                reason = reason or "legacy_import",
                captureReason = event.canonical and "canonical_import" or "legacy_import",
                classificationPriority =
                    tonumber(event.classificationPriority)
                    or CLASSIFICATION_PRIORITY[subtype]
                    or CLASSIFICATION_PRIORITY[source]
                    or 0,
                legacy = true,
                transactionID = event.transactionID,
                transactionAmount = event.transactionAmount,
                primary = event.primary,
                synthetic = event.synthetic,
            }

            CopyEventContext(imported, event)

            if imported.amount > 0 then
                table.insert(levelData.ledger, imported)
            end
        end
    end

    levelData.legacyKillCount = tonumber(levelData.mobs) or 0
end

local function GetLedgerTotal(levelData)
    local total = 0

    for _, event in ipairs(levelData.ledger or {}) do
        total = total + (tonumber(event.amount) or 0)
    end

    return total
end

local function AddSyntheticBaseline(levelData, amount, reason)
    amount = math.floor(tonumber(amount) or 0)

    if amount <= 0 then
        return
    end

    local event = {
        id = NextXPEventID(),
        at = time(),
        level = levelData.level,
        amount = amount,
        source = "other",
        subtype = "unclassified",
        reason = reason or "legacy_baseline",
        captureReason = reason or "legacy_baseline",
        classificationPriority = 0,
        legacy = true,
        synthetic = true,
    }

    table.insert(levelData.ledger, event)
end

local function MigrateLedger()
    local db = EnsureDatabase()

    if tonumber(db.ledgerVersion) == LEDGER_VERSION then
        return
    end

    for level, levelData in pairs(db.levels) do
        if type(levelData) == "table" then
            levelData.level = tonumber(levelData.level) or tonumber(level)
            BuildLegacyLedger(levelData)

            local ledgerTotal = GetLedgerTotal(levelData)
            local target = 0

            if levelData.completedAt then
                target = tonumber(levelData.xpRequired) or 0

                if target <= 0 then
                    target =
                        (tonumber(levelData.xpMob) or 0)
                        + (tonumber(levelData.xpQuest) or 0)
                        + (tonumber(levelData.xpDungeon) or 0)
                        + (tonumber(levelData.xpOther) or 0)
                end
            end

            if target > ledgerTotal then
                AddSyntheticBaseline(
                    levelData,
                    target - ledgerTotal,
                    "legacy_unclassified"
                )
            end
        end
    end

    db.ledgerVersion = LEDGER_VERSION
end

local function EnsureCurrentLevelBaseline()
    if not IsLoggedIn or not IsLoggedIn() then
        return
    end

    local db = EnsureDatabase()
    local level = UnitLevel("player") or db.currentLevel or 1
    local levelData = EnsureLevel(level)
    local currentXP = UnitXP("player") or 0
    local requiredXP = UnitXPMax("player") or 0
    local ledgerTotal = GetLedgerTotal(levelData)

    if requiredXP > 0 then
        levelData.xpRequired = requiredXP
    end

    if currentXP > ledgerTotal then
        AddSyntheticBaseline(
            levelData,
            currentXP - ledgerTotal,
            "startup_unclassified"
        )
    end
end

-- ============================================================================
-- Played-time and activity tracking
-- ============================================================================
local function AddTrackedSeconds(seconds)
    seconds = tonumber(seconds) or 0

    if seconds <= 0 then
        return
    end

    local db = EnsureDatabase()
    local level = UnitLevel("player") or db.currentLevel or 1

    db.currentLevel = level
    db.totalTracked = db.totalTracked + seconds
    db.lastSeenAt = time()

    local day = EnsureDay()
    day.seconds = day.seconds + seconds

    SyncCharacterDayToAccount(GetDateKey())

    local levelData = EnsureLevel(level)
    levelData.seconds = levelData.seconds + seconds
end

local function IncrementActivity(field, amount)
    amount = tonumber(amount) or 1

    local db = EnsureDatabase()
    local level = UnitLevel("player") or db.currentLevel or 1

    db.currentLevel = level

    local day = EnsureDay()
    day[field] = (tonumber(day[field]) or 0) + amount

    local levelData = EnsureLevel(level)
    levelData[field] = (tonumber(levelData[field]) or 0) + amount
end

local function FinalizeCurrentTick()
    if not sessionStarted or not lastTick then
        return
    end

    local now = GetTime()
    local elapsed = now - lastTick
    lastTick = now

    if elapsed > 0 and elapsed < 120 then
        AddTrackedSeconds(elapsed)
    end
end

-- ============================================================================
-- XP observation and source classification
-- ============================================================================
local function ParseXPFromCombatMessage(message)
    if type(message) ~= "string" then
        return nil
    end

    local amount = string.match(
        message,
        "[Yy]ou gain%s+([%d,]+)%s+experience"
    )

    if not amount then
        amount = string.match(message, "([%d,]+)%s+experience")
    end

    if not amount then
        amount = string.match(message, "([%d,]+)%s+[Xx][Pp]")
    end

    if not amount then
        return nil
    end

    amount = string.gsub(amount, ",", "")
    return tonumber(amount)
end

local function ParseExplorationXP(message)
    if type(message) ~= "string" then
        return nil
    end

    local lower = string.lower(message)

    if not string.find(lower, "discovered", 1, true)
        and not string.find(lower, "exploration experience", 1, true)
        and not string.find(lower, "exploration xp", 1, true) then
        return nil
    end

    local amount =
        string.match(message, "([%d,]+)%s+[Ee]xperience")
        or string.match(message, "([%d,]+)%s+[Xx][Pp]")

    if not amount then
        return nil
    end

    amount = string.gsub(amount, ",", "")
    return tonumber(amount)
end

local function IsInFivePlayerDungeon()
    if not IsInInstance then
        return false
    end

    local inInstance, instanceType = IsInInstance()
    return inInstance and instanceType == "party"
end

local function BuildEventContext()
    local context = {
        zone = GetRealZoneText and GetRealZoneText() or nil,
    }

    if IsInInstance then
        local inInstance, instanceType = IsInInstance()
        context.inInstance = inInstance and true or false
        context.instanceType = instanceType
    end

    if GetInstanceInfo then
        context.instanceName = select(1, GetInstanceInfo())
    end

    return context
end

local function CreateLedgerEvent(
    level,
    amount,
    transactionID,
    transactionAmount,
    primary,
    captureReason
)
    amount = math.floor(tonumber(amount) or 0)

    if amount <= 0 then
        return nil
    end

    local levelData = EnsureLevel(level)
    local context = BuildEventContext()

    local event = {
        id = NextXPEventID(),
        at = time(),
        level = level,
        amount = amount,
        source = "other",
        subtype = "unclassified",
        reason = "unclassified",
        captureReason = captureReason or "xp_bar_delta",
        classificationPriority = 0,
        transactionID = transactionID,
        transactionAmount = transactionAmount or amount,
        primary = primary and true or false,
        legacy = false,
        synthetic = false,
    }

    CopyEventContext(event, context)
    table.insert(levelData.ledger, event)

    return event
end

local function RegisterRecentTransaction(
    transactionID,
    totalAmount,
    eventIDs
)
    table.insert(recentTransactions, {
        id = transactionID,
        amount = totalAmount,
        eventIDs = eventIDs,
        capturedAt = GetTime(),
        debugPrinted = false,
    })
end

local function PruneRuntimeQueues()
    local now = GetTime()

    for i = #recentTransactions, 1, -1 do
        if (now - recentTransactions[i].capturedAt) > XP_SIGNAL_WINDOW then
            table.remove(recentTransactions, i)
        end
    end

    for i = #pendingSignals, 1, -1 do
        if (now - pendingSignals[i].queuedAt) > XP_SIGNAL_WINDOW then
            table.remove(pendingSignals, i)
        end
    end
end

local function FindLedgerEventByID(eventID)
    local db = EnsureDatabase()

    for _, levelData in pairs(db.levels) do
        for _, event in ipairs(levelData.ledger or {}) do
            if event.id == eventID then
                return event
            end
        end
    end

    return nil
end

local function BuildTransactionSummary(transaction)
    if not transaction then
        return nil
    end

    local summary = {
        transactionID = transaction.id,
        amount = tonumber(transaction.amount) or 0,
        at = nil,
        source = "other",
        subtype = "unclassified",
        reason = "unclassified",
        captureReason = nil,
        zone = nil,
        instanceName = nil,
        classificationPriority = -1,
        levels = {},
    }

    local seenLevels = {}

    for _, eventID in ipairs(transaction.eventIDs or {}) do
        local event = FindLedgerEventByID(eventID)

        if event then
            if event.at and (not summary.at or event.at < summary.at) then
                summary.at = event.at
            end

            if event.level and not seenLevels[event.level] then
                seenLevels[event.level] = true
                table.insert(summary.levels, event.level)
            end

            local priority = tonumber(event.classificationPriority) or 0

            if priority >= summary.classificationPriority then
                summary.source = NormalizeSource(event.source)
                summary.subtype = event.subtype or "unclassified"
                summary.reason = event.reason or event.captureReason or "unclassified"
                summary.captureReason = event.captureReason
                summary.zone = event.zone or summary.zone
                summary.instanceName = event.instanceName or summary.instanceName
                summary.classificationPriority = priority
            end
        end
    end

    table.sort(summary.levels)

    return summary
end

local function BuildPersistedTransactionSummaries(levelFilter)
    local db = EnsureDatabase()
    local grouped = {}
    local ordered = {}

    for level, levelData in pairs(db.levels) do
        for _, event in ipairs(levelData.ledger or {}) do
            local eventLevel = tonumber(event.level) or tonumber(level)

            if not levelFilter or eventLevel == tonumber(levelFilter) then
                local transactionKey =
                    event.transactionID
                    or ("event:" .. tostring(event.id))

                local summary = grouped[transactionKey]

                if not summary then
                    summary = {
                        transactionID = transactionKey,
                        amount = tonumber(event.transactionAmount)
                            or tonumber(event.amount)
                            or 0,
                        at = event.at,
                        source = NormalizeSource(event.source),
                        subtype = event.subtype or "unclassified",
                        reason = event.reason or event.captureReason or "unclassified",
                        captureReason = event.captureReason,
                        zone = event.zone,
                        instanceName = event.instanceName,
                        classificationPriority =
                            tonumber(event.classificationPriority) or 0,
                        levels = {},
                        seenLevels = {},
                    }

                    grouped[transactionKey] = summary
                    table.insert(ordered, summary)
                else
                    local priority =
                        tonumber(event.classificationPriority) or 0

                    if priority >= summary.classificationPriority then
                        summary.source = NormalizeSource(event.source)
                        summary.subtype = event.subtype or "unclassified"
                        summary.reason =
                            event.reason
                            or event.captureReason
                            or "unclassified"
                        summary.captureReason = event.captureReason
                        summary.zone = event.zone or summary.zone
                        summary.instanceName =
                            event.instanceName or summary.instanceName
                        summary.classificationPriority = priority
                    end

                    if event.at and (not summary.at or event.at < summary.at) then
                        summary.at = event.at
                    end
                end

                if eventLevel and not summary.seenLevels[eventLevel] then
                    summary.seenLevels[eventLevel] = true
                    table.insert(summary.levels, eventLevel)
                end
            end
        end
    end

    for _, summary in ipairs(ordered) do
        summary.seenLevels = nil
        table.sort(summary.levels)
    end

    table.sort(ordered, function(a, b)
        local atA = tonumber(a.at) or 0
        local atB = tonumber(b.at) or 0

        if atA == atB then
            return tostring(a.transactionID) < tostring(b.transactionID)
        end

        return atA < atB
    end)

    return ordered
end

local function FormatSummarySource(summary)
    if not summary then
        return "other"
    end

    if summary.source == "other"
        and summary.subtype == "exploration" then
        return "other (exploration)"
    elseif summary.source == "other" then
        return "other (unclassified)"
    end

    return tostring(summary.source or "other")
end

local function FormatSummaryLevels(summary)
    if not summary or not summary.levels or #summary.levels == 0 then
        return ""
    end

    if #summary.levels == 1 then
        return "L" .. tostring(summary.levels[1])
    end

    return "L"
        .. tostring(summary.levels[1])
        .. "->"
        .. tostring(summary.levels[#summary.levels])
end

local function FlushSettledXPDebug()
    if not DebugXPEnabled() then
        return
    end

    local now = GetTime()

    for _, transaction in ipairs(recentTransactions) do
        if not transaction.debugPrinted
            and (now - transaction.capturedAt) >= XP_DEBUG_SETTLE_DELAY then

            local summary = BuildTransactionSummary(transaction)

            if summary then
                local when =
                    summary.at and date("%H:%M:%S", summary.at) or "?"
                local sourceLabel = FormatSummarySource(summary)
                local context =
                    summary.instanceName
                    or summary.zone
                    or ""
                local levels = FormatSummaryLevels(summary)

                Print(string.format(
                    "|cffaaaaaaXP DEBUG|r %s | %s | %d XP | %s | %s | %s",
                    when,
                    sourceLabel,
                    tonumber(summary.amount) or 0,
                    context,
                    summary.reason or summary.captureReason or "",
                    levels
                ))
            end

            transaction.debugPrinted = true
        end
    end
end

local function ApplySignalToTransaction(transaction, signal)
    if not transaction or not signal then
        return false
    end

    local changed = false

    for _, eventID in ipairs(transaction.eventIDs or {}) do
        local event = FindLedgerEventByID(eventID)

        if event then
            local oldPriority = tonumber(event.classificationPriority) or 0
            local newPriority = tonumber(signal.priority) or 0

            if newPriority >= oldPriority then
                event.source = NormalizeSource(signal.source)
                event.subtype = signal.subtype or SourceSubtype(
                    event.source,
                    signal.reason
                )
                event.reason = signal.reason or event.reason
                event.classificationPriority = newPriority

                if signal.details then
                    CopyEventContext(event, signal.details)
                end

                changed = true
            end
        end
    end

    return changed
end

local function FindBestRecentTransaction(reportedAmount, signalQueuedAt)
    local best = nil
    local exact = nil

    for i = #recentTransactions, 1, -1 do
        local transaction = recentTransactions[i]

        -- If this classifier was queued before the XP-bar delta existed,
        -- never consume it on an older transaction with the same XP amount.
        -- It must wait for a transaction captured at or after the signal.
        local eligible = true

        if signalQueuedAt
            and transaction.capturedAt
            and transaction.capturedAt < signalQueuedAt then
            eligible = false
        end

        if eligible then
            if tonumber(reportedAmount)
                and tonumber(reportedAmount) > 0
                and tonumber(transaction.amount) == tonumber(reportedAmount) then
                exact = transaction
                break
            end

            if not best then
                best = transaction
            end
        end
    end

    if exact then
        return exact
    end

    if not reportedAmount then
        return best
    end

    return nil
end

-- Classification never adds XP. A signal only annotates a canonical
-- transaction, with timing guards protecting repeated equal-value gains.
local function QueueClassificationSignal(
    source,
    subtype,
    reportedAmount,
    priority,
    reason,
    details
)
    local now = GetTime()

    local signal = {
        source = source,
        subtype = subtype,
        reportedAmount = tonumber(reportedAmount),
        priority = priority or 0,
        reason = reason,
        details = details or {},
        queuedAt = now,
    }

    -- Normal event order is XP delta first, source message second.
    -- In that case, only bind immediately to a transaction captured very
    -- recently. This avoids stealing an older same-value transaction.
    local immediate = nil

    for i = #recentTransactions, 1, -1 do
        local transaction = recentTransactions[i]
        local age = now - (transaction.capturedAt or 0)

        if age >= 0 and age <= 0.75 then
            if signal.reportedAmount
                and signal.reportedAmount > 0
                and tonumber(transaction.amount) == signal.reportedAmount then
                immediate = transaction
                break
            elseif not signal.reportedAmount and not immediate then
                immediate = transaction
            end
        end
    end

    if immediate then
        ApplySignalToTransaction(immediate, signal)
        return true
    end

    table.insert(pendingSignals, signal)
    return false
end

local function ApplyPendingSignals()
    if #pendingSignals == 0 or #recentTransactions == 0 then
        return false
    end

    local changed = false

    for i = #pendingSignals, 1, -1 do
        local signal = pendingSignals[i]
        local transaction = FindBestRecentTransaction(
            signal.reportedAmount,
            signal.queuedAt
        )

        if transaction then
            if ApplySignalToTransaction(transaction, signal) then
                changed = true
            end

            table.remove(pendingSignals, i)
        end
    end

    return changed
end

local function InitializeXPObservation()
    if not IsLoggedIn or not IsLoggedIn() then
        return
    end

    observedLevel = UnitLevel("player") or 1
    observedXP = UnitXP("player") or 0
    observedXPMax = UnitXPMax("player") or 0
    xpObserved = true
end

-- Capture one positive UnitXP delta as one logical transaction. Level-up
-- overflow can create two internal fragments, but transactionID keeps every
-- reporting interface de-duplicated.
local function CaptureXPBarDelta(captureReason)
    if not IsLoggedIn or not IsLoggedIn() then
        return false
    end

    local level = UnitLevel("player") or 1
    local currentXP = UnitXP("player") or 0
    local currentXPMax = UnitXPMax("player") or 0

    if not xpObserved then
        InitializeXPObservation()
        return false
    end

    local oldLevel = observedLevel or level
    local oldXP = observedXP or 0
    local oldXPMax = observedXPMax or 0

    local oldLevelGain = 0
    local newLevelGain = 0

    if level == oldLevel then
        if currentXP > oldXP then
            newLevelGain = currentXP - oldXP
        end
    elseif level > oldLevel then
        if oldXPMax > oldXP then
            oldLevelGain = oldXPMax - oldXP
        end

        newLevelGain = currentXP
    end

    local totalGain = oldLevelGain + newLevelGain

    if totalGain > 0 then
        nextRuntimeTransactionID = nextRuntimeTransactionID + 1

        local transactionID =
            tostring(time()) .. ":" .. tostring(nextRuntimeTransactionID)

        local eventIDs = {}
        local primaryAssigned = false

        if oldLevelGain > 0 then
            local event = CreateLedgerEvent(
                oldLevel,
                oldLevelGain,
                transactionID,
                totalGain,
                true,
                captureReason
            )

            if event then
                table.insert(eventIDs, event.id)
                primaryAssigned = true
            end
        end

        if newLevelGain > 0 then
            local event = CreateLedgerEvent(
                level,
                newLevelGain,
                transactionID,
                totalGain,
                not primaryAssigned,
                captureReason
            )

            if event then
                table.insert(eventIDs, event.id)
            end
        end

        RegisterRecentTransaction(
            transactionID,
            totalGain,
            eventIDs
        )

        ApplyPendingSignals()
    end

    observedLevel = level
    observedXP = currentXP
    observedXPMax = currentXPMax

    return totalGain > 0
end

-- ============================================================================
-- Derived XP statistics
-- ============================================================================
local function AggregateLevelXP(levelData)
    local totals = {
        mob = 0,
        quest = 0,
        dungeon = 0,
        exploration = 0,
        other = 0,
        total = 0,
    }

    for _, event in ipairs(levelData.ledger or {}) do
        local amount = tonumber(event.amount) or 0
        local source = NormalizeSource(event.source)
        local bucket = event.subtype == "exploration" and "exploration" or source

        totals[bucket] = totals[bucket] + amount
        totals.total = totals.total + amount
    end

    return totals
end

-- ============================================================================
-- Derived realm-wide daily played-time statistics
-- ============================================================================
local function GetAccountDayRows()
    local _, realm = EnsureAccountDatabase()
    local keys = {}

    for dateKey in pairs(realm.days or {}) do
        table.insert(keys, dateKey)
    end

    table.sort(keys, function(a, b) return a > b end)
    return keys
end


local function GetLocalizedClassName(classFile)
    return
        (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[classFile])
        or classFile
        or "Unknown"
end

local function GetAccountLifetimeData()
    local accountDB = EnsureAccountDatabase()
    local classes = {}
    local accountTotal = 0
    local characterCount = 0
    local realmCount = 0

    for realmName, realm in pairs(accountDB.realms or {}) do
        local realmHasCharacter = false

        for characterKey, character in pairs(realm.characters or {}) do
            local seconds = tonumber(character.totalPlayed) or 0

            if seconds > 0 then
                realmHasCharacter = true
                characterCount = characterCount + 1
                accountTotal = accountTotal + seconds

                local classFile = character.classFile or "UNKNOWN"
                local classData = classes[classFile]

                if not classData then
                    classData = {
                        classFile = classFile,
                        className = GetLocalizedClassName(classFile),
                        seconds = 0,
                        characters = {},
                        realms = {},
                    }
                    classes[classFile] = classData
                end

                classData.seconds = classData.seconds + seconds
                classData.realms[realmName] = true

                table.insert(classData.characters, {
                    key = characterKey,
                    name = character.name or characterKey,
                    realm = character.realm or realmName,
                    classFile = classFile,
                    level = tonumber(character.level) or 0,
                    seconds = seconds,
                    lastSeenAt = tonumber(character.lastSeenAt) or 0,
                })
            end
        end

        if realmHasCharacter then
            realmCount = realmCount + 1
        end
    end

    local rows = {}

    for _, classData in pairs(classes) do
        local realms = 0
        for _ in pairs(classData.realms) do
            realms = realms + 1
        end

        classData.realmCount = realms
        classData.percent =
            accountTotal > 0
            and (classData.seconds / accountTotal * 100)
            or 0

        table.sort(classData.characters, function(a, b)
            if a.seconds == b.seconds then
                if a.realm == b.realm then
                    return a.name < b.name
                end
                return a.realm < b.realm
            end
            return a.seconds > b.seconds
        end)

        table.insert(rows, classData)
    end

    table.sort(rows, function(a, b)
        if a.seconds == b.seconds then
            return a.className < b.className
        end
        return a.seconds > b.seconds
    end)

    return rows, accountTotal, characterCount, realmCount
end

local function FormatHistoryDate(dateKey)
    local year, month, day =
        string.match(tostring(dateKey or ""), "^(%d%d%d%d)%-(%d%d)%-(%d%d)$")

    year = tonumber(year)
    month = tonumber(month)
    day = tonumber(day)

    if not year or not month or not day then
        return tostring(dateKey or "")
    end

    local monthNames = {
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    }

    local label = string.format("%s %d", monthNames[month] or "?", day)
    local currentYear = tonumber(date("%Y"))

    if year ~= currentYear then
        label = label .. ", " .. tostring(year)
    end

    return label
end

local function GetAccountDayBreakdown(dateKey)
    local _, realm = EnsureAccountDatabase()
    local day = realm.days[dateKey]
    local segments = {}
    local totalSeconds = 0

    if not day or not day.characters then
        return segments, totalSeconds
    end

    for characterKey, entry in pairs(day.characters) do
        local seconds = tonumber(entry.seconds) or 0
        if seconds > 0 then
            totalSeconds = totalSeconds + seconds
            table.insert(segments, {
                characterKey = characterKey,
                name = entry.name or characterKey,
                classFile = entry.classFile or "UNKNOWN",
                seconds = seconds,
            })
        end
    end

    table.sort(segments, function(a, b)
        if a.seconds == b.seconds then return a.name < b.name end
        return a.seconds > b.seconds
    end)

    return segments, totalSeconds
end

local function CountNewLedgerKills(levelData)
    local seenTransactions = {}
    local count = 0

    for _, event in ipairs(levelData.ledger or {}) do
        if not event.legacy
            and event.subtype == "kill"
            and event.primary ~= false then

            local key = event.transactionID or event.id

            if not seenTransactions[key] then
                seenTransactions[key] = true
                count = count + 1
            end
        end
    end

    return count
end

local function GetLevelKillCount(levelData)
    return (tonumber(levelData.legacyKillCount) or 0)
        + CountNewLedgerKills(levelData)
end

local function GetLevelExplorationCount(levelData)
    local seenTransactions = {}
    local count = 0

    for _, event in ipairs(levelData.ledger or {}) do
        if event.subtype == "exploration" and event.primary ~= false then
            local key = event.transactionID or event.id
            if not seenTransactions[key] then
                seenTransactions[key] = true
                count = count + 1
            end
        end
    end

    return count
end

local function GetLevelBreakdown(levelData, isCurrent)
    local totals = AggregateLevelXP(levelData)
    local mix = {
        mob = 0,
        quest = 0,
        dungeon = 0,
        exploration = 0,
        other = 0,
    }

    if totals.total > 0 then
        mix.mob = totals.mob / totals.total * 100
        mix.quest = totals.quest / totals.total * 100
        mix.dungeon = totals.dungeon / totals.total * 100
        mix.exploration = totals.exploration / totals.total * 100
        mix.other = totals.other / totals.total * 100
    end

    local progressPct = 0

    if levelData.completedAt then
        progressPct = 100
    elseif isCurrent then
        local required = UnitXPMax("player") or 0
        local currentXP = UnitXP("player") or 0

        if required > 0 then
            progressPct = Clamp(currentXP / required * 100, 0, 100)
            levelData.xpRequired = required
        end
    else
        local required = tonumber(levelData.xpRequired) or 0

        if required > 0 then
            progressPct = Clamp(totals.total / required * 100, 0, 100)
        end
    end

    return {
        totals = totals,
        mix = mix,
        progressPct = progressPct,
    }
end

-- ============================================================================
-- Blizzard /played and dungeon-completion helpers
-- ============================================================================
local function RequestPlayedSync()
    if pendingPlayedRequest then
        return
    end

    if RequestTimePlayed then
        pendingPlayedRequest = true
        RequestTimePlayed()
    end
end

local function RecordDungeonCompletion(sourceName)
    local now = GetTime()
    local instanceName =
        GetInstanceInfo and select(1, GetInstanceInfo()) or "Dungeon"

    if (now - lastAutomaticDungeonCompletion) < 30
        and lastAutomaticDungeonName == instanceName then
        return false
    end

    lastAutomaticDungeonCompletion = now
    lastAutomaticDungeonName = instanceName

    IncrementActivity("dungeons", 1)

    Print(string.format(
        "Recorded dungeon completion: %s%s",
        tostring(instanceName or "Dungeon"),
        sourceName and (" (" .. sourceName .. ")") or ""
    ))

    return true
end

-- ============================================================================
-- Slash-command summaries
-- ============================================================================
local function ShowToday()
    FinalizeCurrentTick()
    local dateKey = GetDateKey()
    local segments, totalSeconds = GetAccountDayBreakdown(dateKey)

    Print(string.format(
        "Today on %s: %s played across %d character%s.",
        GetRealmKey(),
        FormatDuration(totalSeconds),
        #segments,
        #segments == 1 and "" or "s"
    ))
end

local function ShowCurrentLevel()
    FinalizeCurrentTick()

    local db = EnsureDatabase()
    local level = UnitLevel("player") or db.currentLevel or 1
    local levelData = EnsureLevel(level)
    local breakdown = GetLevelBreakdown(levelData, true)

    Print(string.format(
        "Level %d: %s | Q:%d K:%d D:%d | XP K:%d%% Q:%d%% D:%d%% E:%d%% O:%d%%",
        level,
        FormatDuration(levelData.seconds),
        levelData.quests,
        GetLevelKillCount(levelData),
        levelData.dungeons,
        math.floor(breakdown.mix.mob + 0.5),
        math.floor(breakdown.mix.quest + 0.5),
        math.floor(breakdown.mix.dungeon + 0.5),
        math.floor(breakdown.mix.exploration + 0.5),
        math.floor(breakdown.mix.other + 0.5)
    ))
end

local function ShowRecentLevels()
    FinalizeCurrentTick()

    local db = EnsureDatabase()
    local currentLevel = UnitLevel("player") or db.currentLevel or 1
    local firstLevel = math.max(1, currentLevel - 5)

    Print("Recent level history:")

    for level = firstLevel, currentLevel do
        local levelData = db.levels[level]

        if levelData then
            Print(string.format(
                "Level %d (%s): %s | Q:%d K:%d D:%d",
                level,
                levelData.completedAt and "complete" or "current",
                FormatDuration(levelData.seconds),
                levelData.quests,
                GetLevelKillCount(levelData),
                levelData.dungeons
            ))
        end
    end
end

-- ============================================================================
-- Tracker UI
-- ============================================================================
local function CreateText(
    parent,
    font,
    anchor,
    relativeTo,
    relativePoint,
    x,
    y,
    justify
)
    local text = parent:CreateFontString(
        nil,
        "OVERLAY",
        font or "GameFontNormal"
    )

    text:SetPoint(
        anchor,
        relativeTo or parent,
        relativePoint or anchor,
        x or 0,
        y or 0
    )

    if justify then
        text:SetJustifyH(justify)
    end

    return text
end

local function CreateFlatButton(parent, label, width, height)
    -- Use Blizzard's own panel button art so the tracker feels like a native
    -- game window on every client that exposes the standard template.
    local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    button:SetSize(width, height)
    button:SetText(label)
    button.label = button:GetFontString()

    return button
end

local function SetButtonSelected(button, selected)
    button.selected = selected

    if selected then
        button:LockHighlight()
        if button.label then
            button.label:SetTextColor(1, 1, 1)
        end
    else
        button:UnlockHighlight()
        if button.label then
            button.label:SetTextColor(1, 0.82, 0)
        end
    end
end

local function RefreshCharacterHeader()
    if not historyFrame then
        return
    end

    local name = UnitName("player") or "Unknown"
    local realm = GetRealmKey()
    local level = UnitLevel("player") or 1
    local localizedClass = UnitClass("player") or "Unknown"

    if historyFrame.characterName then
        historyFrame.characterName:SetText(name)
    end

    if historyFrame.characterMeta then
        historyFrame.characterMeta:SetText(
            string.format("Level %d %s  •  %s", level, localizedClass, realm)
        )
    end

    if historyFrame.portrait then
        if SetPortraitTexture then
            SetPortraitTexture(historyFrame.portrait, "player")
        else
            SetPortraitTextureFromCreatureDisplayID(historyFrame.portrait, 0)
        end
    end
end

local function ApplyWindowOpacity()
    if not historyFrame or not historyFrame.background then
        return
    end

    local db = EnsureDatabase()
    local opacity = Clamp(db.windowOpacity or 0.70, 0.20, 1.00)

    historyFrame.background:SetVertexColor(
        0.055,
        0.038,
        0.018,
        opacity
    )

    historyFrame.titleBar:SetVertexColor(
        0.07,
        0.07,
        0.07,
        math.min(1, opacity + 0.03)
    )

    -- BasicFrameTemplateWithInset brings its own opaque background/chrome.
    -- Fade those artwork regions with the user's setting without fading text,
    -- bars, buttons, or other child controls.
    if historyFrame.Bg then
        historyFrame.Bg:SetAlpha(opacity)
    end
    if historyFrame.Inset then
        historyFrame.Inset:SetAlpha(opacity)
    end
    if historyFrame.NineSlice then
        historyFrame.NineSlice:SetAlpha(math.max(0.55, opacity))
    end
end

local function CreateSegment(parent, color)
    local segment = CreateFrame("Frame", nil, parent)
    segment:SetHeight(18)
    segment:EnableMouse(true)

    segment.texture = segment:CreateTexture(nil, "ARTWORK")
    segment.texture:SetAllPoints()
    segment.texture:SetTexture("Interface\\Buttons\\WHITE8X8")
    segment.texture:SetVertexColor(
        color[1],
        color[2],
        color[3],
        color[4]
    )

    segment.label = segment:CreateFontString(
        nil,
        "OVERLAY",
        "GameFontHighlight"
    )
    segment.label:SetPoint("CENTER")
    segment.label:SetTextColor(1, 1, 1, 1)
    segment.label:SetShadowColor(0, 0, 0, 1)
    segment.label:SetShadowOffset(1, -1)

    segment:SetScript("OnEnter", function(self)
        local db = EnsureDatabase()

        if not db.showTooltips or not self.tooltipTitle then
            return
        end

        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(self.tooltipTitle, 1, 0.82, 0)

        GameTooltip:AddDoubleLine(
            "Total XP",
            tostring(math.floor(self.tooltipXP or 0)),
            1, 1, 1,
            1, 1, 1
        )

        GameTooltip:AddDoubleLine(
            "Share of XP earned",
            tostring(math.floor((self.tooltipPercent or 0) + 0.5)) .. "%",
            0.8, 0.8, 0.8,
            1, 1, 1
        )

        GameTooltip:Show()
    end)

    segment:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return segment
end

local function CreateCharacterSegment(parent)
    local segment = CreateFrame("Frame", nil, parent)
    segment:SetHeight(18)
    segment:EnableMouse(true)

    segment.texture = segment:CreateTexture(nil, "ARTWORK")
    segment.texture:SetAllPoints()
    segment.texture:SetTexture("Interface\\Buttons\\WHITE8X8")

    segment:SetScript("OnEnter", function(self)
        local db = EnsureDatabase()
        if not db.showTooltips or not self.characterName then return end

        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:ClearLines()

        local localizedClass =
            (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[self.classFile])
            or self.classFile
            or "Unknown"

        GameTooltip:AddLine(self.characterName, 1, 0.82, 0)
        GameTooltip:AddLine(tostring(localizedClass), 0.8, 0.8, 0.8)
        GameTooltip:AddDoubleLine("Time played", FormatDuration(self.seconds or 0), 1,1,1, 1,1,1)
        GameTooltip:AddDoubleLine(
            "Share of day",
            string.format("%d%%", math.floor((self.percent or 0) + 0.5)),
            0.8,0.8,0.8, 1,1,1
        )
        GameTooltip:Show()
    end)

    segment:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return segment
end


local function CreateAccountSegment(parent)
    local segment = CreateFrame("Frame", nil, parent)
    segment:SetHeight(18)
    segment:EnableMouse(true)

    segment.texture = segment:CreateTexture(nil, "ARTWORK")
    segment.texture:SetAllPoints()
    segment.texture:SetTexture("Interface\\Buttons\\WHITE8X8")

    segment.label = segment:CreateFontString(
        nil,
        "OVERLAY",
        "GameFontHighlightSmall"
    )
    segment.label:SetPoint("CENTER")
    segment.label:SetTextColor(1, 1, 1, 1)
    segment.label:SetShadowColor(0, 0, 0, 1)
    segment.label:SetShadowOffset(1, -1)

    segment:SetScript("OnEnter", function(self)
        local db = EnsureDatabase()

        if not db.showTooltips or not self.className then
            return
        end

        GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
        GameTooltip:ClearLines()
        GameTooltip:AddLine(self.className, 1, 0.82, 0)

        GameTooltip:AddDoubleLine(
            "Total /played",
            FormatDuration(self.seconds or 0),
            1, 1, 1,
            1, 1, 1
        )

        GameTooltip:AddDoubleLine(
            "Share of account",
            string.format("%d%%", math.floor((self.percent or 0) + 0.5)),
            0.8, 0.8, 0.8,
            1, 1, 1
        )

        if self.characters and #self.characters > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine("Characters", 0.75, 0.75, 0.75)

            for _, character in ipairs(self.characters) do
                local levelText =
                    character.level and character.level > 0
                    and ("L" .. tostring(character.level) .. "  ")
                    or ""

                GameTooltip:AddDoubleLine(
                    levelText
                        .. tostring(character.name)
                        .. " — "
                        .. tostring(character.realm),
                    FormatDuration(character.seconds or 0),
                    0.9, 0.9, 0.9,
                    1, 1, 1
                )
            end
        end

        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(
            "Characters update when logged into with Played Plus enabled.",
            0.55, 0.55, 0.55,
            true
        )

        GameTooltip:Show()
    end)

    segment:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return segment
end

local function ClearCharacterSegments(row)
    row.characterSegments = row.characterSegments or {}
    for _, segment in ipairs(row.characterSegments) do
        segment:Hide()
        segment:ClearAllPoints()
    end
end

local function RenderCharacterSegments(row, segments, totalSeconds, barWidth)
    ClearCharacterSegments(row)
    if totalSeconds <= 0 then return end

    local offset = 0
    for index, data in ipairs(segments) do
        local segment = row.characterSegments[index]
        if not segment then
            segment = CreateCharacterSegment(row.barContent)
            row.characterSegments[index] = segment
        end

        local percent = data.seconds / totalSeconds * 100
        local width = barWidth * percent / 100
        local color = GetClassColor(data.classFile)

        segment:ClearAllPoints()
        segment:SetPoint("LEFT", row.barContent, "LEFT", offset, 0)
        segment:SetWidth(math.max(1, width))
        segment:SetHeight(18)
        segment.texture:SetVertexColor(color[1], color[2], color[3], color[4])
        segment.characterName = data.name
        segment.classFile = data.classFile
        segment.seconds = data.seconds
        segment.percent = percent
        segment:Show()
        offset = offset + width
    end
end

local function SetSegment(
    segment,
    leftOffset,
    width,
    labelPercent
)
    segment:ClearAllPoints()

    if width <= 0.5 then
        segment:Hide()
        return
    end

    segment:SetPoint(
        "LEFT",
        segment:GetParent(),
        "LEFT",
        leftOffset,
        0
    )
    segment:SetWidth(width)
    segment:Show()

    local db = EnsureDatabase()

    if db.showLabels and width >= 30 and labelPercent > 0 then
        segment.label:SetText(
            string.format(
                "%d%%",
                math.floor(labelPercent + 0.5)
            )
        )
        segment.label:Show()
    else
        segment.label:Hide()
    end
end

local function SetSegmentTooltip(
    segment,
    title,
    xp,
    percentage
)
    segment.tooltipTitle = title
    segment.tooltipXP = xp or 0
    segment.tooltipPercent = percentage or 0
end

local function CreateHistoryRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(860, 28)
    row:SetPoint(
        "TOPLEFT",
        parent,
        "TOPLEFT",
        18,
        -166 - ((index - 1) * 30)
    )

    if index % 2 == 0 then
        row.background = row:CreateTexture(nil, "BACKGROUND")
        row.background:SetAllPoints()
        row.background:SetTexture("Interface\\Buttons\\WHITE8X8")
        row.background:SetVertexColor(0.42, 0.31, 0.16, 0.10)
    end

    row.level = CreateText(
        row,
        "GameFontHighlightLarge",
        "LEFT",
        row,
        "LEFT",
        6,
        0,
        "LEFT"
    )
    row.level:SetWidth(82)

    row.time = CreateText(
        row,
        "GameFontHighlight",
        "LEFT",
        row,
        "LEFT",
        88,
        0,
        "LEFT"
    )
    row.time:SetWidth(96)

    row.barFrame = CreateFrame("Frame", nil, row)
    row.barFrame:SetHeight(18)
    row.barFrame:SetPoint("LEFT", row, "LEFT", 190, 0)

    -- A borderless, uniform track renders consistently at fractional UI scales.
    -- The colored segments themselves provide the visual edge.
    row.barBackground = row.barFrame:CreateTexture(nil, "BACKGROUND")
    row.barBackground:SetAllPoints()
    row.barBackground:SetTexture("Interface\\Buttons\\WHITE8X8")
    row.barBackground:SetVertexColor(0.045, 0.038, 0.028, 0.98)

    row.barContent = CreateFrame("Frame", nil, row.barFrame)
    row.barContent:SetAllPoints()

    row.mobSegment = CreateSegment(row.barContent, XP_COLORS.mob)
    row.questSegment = CreateSegment(row.barContent, XP_COLORS.quest)
    row.dungeonSegment = CreateSegment(row.barContent, XP_COLORS.dungeon)
    row.explorationSegment = CreateSegment(row.barContent, XP_COLORS.exploration)
    row.otherSegment = CreateSegment(row.barContent, XP_COLORS.other)

    row.progress = row.barFrame:CreateFontString(
        nil,
        "OVERLAY",
        "GameFontHighlightSmall"
    )
    row.progress:SetTextColor(1, 0.82, 0, 1)
    row.progress:SetShadowColor(0, 0, 0, 1)
    row.progress:SetShadowOffset(1, -1)
    row.progress:Hide()
    row.characterSegments = {}
    row.accountSegment = CreateAccountSegment(row.barContent)
    row.accountSegment:Hide()

    row.details = CreateText(
        row,
        "GameFontHighlightSmall",
        "LEFT",
        row,
        "LEFT",
        700,
        0,
        "LEFT"
    )
    row.details:SetWidth(155)

    row.status = CreateText(
        row,
        "GameFontHighlightSmall",
        "LEFT",
        row,
        "LEFT",
        900,
        0,
        "CENTER"
    )
    row.status:SetWidth(65)

    return row
end

local function GetRowLayout(view)
    local rowWidth = 860
    local barX = 190

    if view == "levels" then
        local activityX = 700
        return activityX - barX - 12, activityX, nil
    end

    -- Days and Account devote the rest of the row to the visualization.
    return rowWidth - barX - 8, nil, nil
end

local function ApplyRowLayout(row, view)
    local barWidth, detailsX = GetRowLayout(view)

    row.barFrame:ClearAllPoints()
    row.barFrame:SetPoint("LEFT", row, "LEFT", 190, 0)
    row.barFrame:SetWidth(barWidth)

    if view == "levels" and detailsX then
        row.details:Show()
        row.details:ClearAllPoints()
        row.details:SetPoint("LEFT", row, "LEFT", detailsX, 0)
    else
        row.details:Hide()
    end

    row.status:Hide()
    return barWidth
end

local function CollectLevelRows()
    local db = EnsureDatabase()
    local currentLevel = UnitLevel("player") or db.currentLevel or 1
    local rows = {}

    for level = currentLevel, math.max(1, currentLevel - MAX_ROWS + 1), -1 do
        local levelData = db.levels[level]

        if levelData then
            local breakdown = GetLevelBreakdown(
                levelData,
                level == currentLevel
            )

            table.insert(rows, {
                label = tostring(level),
                seconds = levelData.seconds,
                quests = levelData.quests,
                kills = GetLevelKillCount(levelData),
                explorations = GetLevelExplorationCount(levelData),
                dungeons = levelData.dungeons,
                status =
                    level == currentLevel
                    and "Current"
                    or (levelData.completedAt and "Complete" or ""),
                breakdown = breakdown,
            })
        end
    end

    return rows
end

local function CollectDayRows()
    local keys = GetAccountDayRows()
    local rows = {}

    for i = 1, math.min(MAX_ROWS, #keys) do
        local dateKey = keys[i]
        local segments, totalSeconds = GetAccountDayBreakdown(dateKey)

        table.insert(rows, {
            label = FormatHistoryDate(dateKey)
                .. (dateKey == GetDateKey() and "  |cffffd100Today|r" or ""),
            seconds = totalSeconds,
            status = "",
            characterSegments = segments,
        })
    end

    return rows
end

local function CollectAccountRows()
    local classRows, accountTotal = GetAccountLifetimeData()
    local rows = {}

    for i = 1, math.min(MAX_ROWS, #classRows) do
        local classData = classRows[i]

        table.insert(rows, {
            label = classData.className,
            seconds = classData.seconds,
            status = string.format(
                "%d%%",
                math.floor((classData.percent or 0) + 0.5)
            ),
            classFile = classData.classFile,
            accountPercent = classData.percent,
            accountTotal = accountTotal,
            accountCharacters = classData.characters,
            characterCount = #classData.characters,
            realmCount = classData.realmCount or 0,
        })
    end

    return rows
end

local function RenderRow(row, data, view)
    row:Show()
    row.level:SetText(data.label)
    row.time:SetText(FormatDuration(data.seconds))

    if view == "levels" then
        row.level:SetFontObject("GameFontHighlightLarge")
    else
        row.level:SetFontObject("GameFontHighlight")
    end

    local barWidth = ApplyRowLayout(row, view)

    if view == "days" then
        row.accountSegment:Hide()
        row.mobSegment:Hide()
        row.questSegment:Hide()
        row.dungeonSegment:Hide()
        row.explorationSegment:Hide()
        row.otherSegment:Hide()
        row.progress:Hide()

        RenderCharacterSegments(row, data.characterSegments or {}, data.seconds or 0, barWidth)

        return
    end

    if view == "account" then
        ClearCharacterSegments(row)

        row.mobSegment:Hide()
        row.questSegment:Hide()
        row.dungeonSegment:Hide()
        row.explorationSegment:Hide()
        row.otherSegment:Hide()
        row.progress:Hide()

        local percent = tonumber(data.accountPercent) or 0
        local width = barWidth * percent / 100
        local color = GetClassColor(data.classFile)

        row.accountSegment:ClearAllPoints()
        row.accountSegment:SetPoint("LEFT", row.barContent, "LEFT", 0, 0)
        row.accountSegment:SetWidth(math.max(1, width))
        row.accountSegment:SetHeight(18)
        row.accountSegment.texture:SetVertexColor(
            color[1], color[2], color[3], color[4]
        )

        row.accountSegment.className = data.label
        row.accountSegment.classFile = data.classFile
        row.accountSegment.seconds = data.seconds
        row.accountSegment.percent = percent
        row.accountSegment.characters = data.accountCharacters or {}

        local db = EnsureDatabase()
        if db.showLabels and width >= 42 then
            row.accountSegment.label:SetText(
                string.format("%d%%", math.floor(percent + 0.5))
            )
            row.accountSegment.label:Show()
        else
            row.accountSegment.label:Hide()
        end

        row.accountSegment:Show()

        return
    end

    row.accountSegment:Hide()
    ClearCharacterSegments(row)

    local breakdown = data.breakdown
    local mix = breakdown.mix
    local totals = breakdown.totals
    local progressPct = breakdown.progressPct

    local progressWidth = barWidth * progressPct / 100
    local mobWidth = progressWidth * mix.mob / 100
    local questWidth = progressWidth * mix.quest / 100
    local dungeonWidth = progressWidth * mix.dungeon / 100
    local explorationWidth = progressWidth * mix.exploration / 100
    local otherWidth = progressWidth * mix.other / 100

    local offset = 0
    SetSegment(row.mobSegment, offset, mobWidth, mix.mob)
    offset = offset + mobWidth
    SetSegment(row.questSegment, offset, questWidth, mix.quest)
    offset = offset + questWidth
    SetSegment(row.dungeonSegment, offset, dungeonWidth, mix.dungeon)
    offset = offset + dungeonWidth
    SetSegment(row.explorationSegment, offset, explorationWidth, mix.exploration)
    offset = offset + explorationWidth
    SetSegment(row.otherSegment, offset, otherWidth, mix.other)

    row.progress:ClearAllPoints()
    if data.status == "Current" then
        local roundedProgress = math.floor(progressPct + 0.5)
        row.progress:SetText(string.format("%d%%", roundedProgress))
        if progressWidth <= (barWidth - 48) then
            row.progress:SetPoint("LEFT", row.barContent, "LEFT", math.max(6, progressWidth + 6), 0)
        else
            row.progress:SetPoint("RIGHT", row.barContent, "RIGHT", -5, 0)
        end
        row.progress:Show()
    else
        row.progress:Hide()
    end

    SetSegmentTooltip(row.mobSegment, "Kills XP", totals.mob, mix.mob)
    SetSegmentTooltip(row.questSegment, "Quest XP", totals.quest, mix.quest)
    SetSegmentTooltip(row.dungeonSegment, "Dungeon XP", totals.dungeon, mix.dungeon)
    SetSegmentTooltip(row.explorationSegment, "Exploration XP", totals.exploration, mix.exploration)
    SetSegmentTooltip(row.otherSegment, "Other / Unclassified XP", totals.other, mix.other)

    local activity = {}
    if (data.quests or 0) > 0 then
        table.insert(activity, "|cff2673d9" .. data.quests .. " Quests|r")
    end
    if (data.kills or 0) > 0 then
        table.insert(activity, "|cff40b333" .. data.kills .. " Kills|r")
    end
    if (data.explorations or 0) > 0 then
        table.insert(activity, "|cfff2b814" .. data.explorations .. " Explored|r")
    end
    if (data.dungeons or 0) > 0 then
        table.insert(activity, "|cff8c33bf" .. data.dungeons .. " Dungeons|r")
    end
    row.details:SetText(table.concat(activity, "  •  "))

    if data.status == "Current" then
        row.level:SetText("|cffffd100" .. tostring(data.label) .. "|r")
    end
end

local function ApplyHeaderLayout()
    if not historyFrame then return end

    local barWidth, detailsX = GetRowLayout(currentView)

    historyFrame.barHeader:ClearAllPoints()
    historyFrame.barHeader:SetPoint("TOPLEFT", historyFrame, "TOPLEFT", 208, -145)
    historyFrame.barHeader:SetWidth(barWidth)

    if currentView == "levels" and detailsX then
        historyFrame.detailsHeader:Show()
        historyFrame.detailsHeader:ClearAllPoints()
        historyFrame.detailsHeader:SetPoint(
            "TOPLEFT", historyFrame, "TOPLEFT", 18 + detailsX, -145
        )
        historyFrame.detailsHeader:SetText("Activity")
    else
        historyFrame.detailsHeader:Hide()
    end

    historyFrame.statusHeader:Hide()
end

local function RefreshHistoryUI()
    if not historyFrame then
        return
    end

    FinalizeCurrentTick()

    local db = EnsureDatabase()
    local level = UnitLevel("player") or db.currentLevel or 1

    if historyFrame.characterLine then
        historyFrame.characterLine:SetText(
            tostring(UnitName("player") or "Unknown")
            .. "  •  "
            .. tostring(GetRealmKey())
        )
    end
    local levelData = EnsureLevel(level)
    local today = EnsureDay()

    historyFrame.summaryLevel:SetText(
        "|cffffd100This level|r  |cffffffff"
        .. FormatDuration(levelData.seconds)
        .. "|r"
    )

    local _, realmTodaySeconds = GetAccountDayBreakdown(GetDateKey())

    historyFrame.summaryToday:SetText(
        "|cffffd100Today|r  |cffffffff" .. FormatDuration(realmTodaySeconds) .. "|r"
    )

    local _, accountPlayed, accountCharacters, accountRealms =
        GetAccountLifetimeData()

    historyFrame.summaryTotal:SetText(
        "|cffffd100Account|r  |cffffffff"
        .. FormatDuration(accountPlayed)
        .. "|r"
    )

    SetButtonSelected(
        historyFrame.levelsButton,
        currentView == "levels"
    )

    SetButtonSelected(
        historyFrame.daysButton,
        currentView == "days"
    )

    SetButtonSelected(
        historyFrame.accountButton,
        currentView == "account"
    )

    if historyFrame.xpLegendRegions then
        for _, region in ipairs(historyFrame.xpLegendRegions) do
            if currentView == "levels" then
                region:Show()
            else
                region:Hide()
            end
        end
    end

    if historyFrame.dayLegendHint then
        if currentView == "days" then
            historyFrame.dayLegendHint:SetText(
                "Class-colored by character • hover for details"
            )
            historyFrame.dayLegendHint:Show()
        elseif currentView == "account" then
            historyFrame.dayLegendHint:SetText(
                string.format(
                    "%d character%s • %d realm%s • hover a class for details",
                    accountCharacters,
                    accountCharacters == 1 and "" or "s",
                    accountRealms,
                    accountRealms == 1 and "" or "s"
                )
            )
            historyFrame.dayLegendHint:Show()
        else
            historyFrame.dayLegendHint:Hide()
        end
    end

    ApplyHeaderLayout()

    local dataRows

    if currentView == "levels" then
        historyFrame.windowTitle:SetText("Played Plus")
        historyFrame.sectionTitle:SetText("")
        historyFrame.leftHeader:SetText("Level")
        historyFrame.barHeader:SetText("XP progress by source")
        dataRows = CollectLevelRows()
    elseif currentView == "days" then
        historyFrame.windowTitle:SetText("Played Plus")
        historyFrame.sectionTitle:SetText("")
        historyFrame.leftHeader:SetText("Date")
        historyFrame.barHeader:SetText("Played time by character")
        dataRows = CollectDayRows()
    else
        historyFrame.windowTitle:SetText("Played Plus")
        historyFrame.sectionTitle:SetText("")
        historyFrame.leftHeader:SetText("Class")
        historyFrame.barHeader:SetText("Share of account")
        dataRows = CollectAccountRows()
    end

    for i = 1, MAX_ROWS do
        local row = historyFrame.rows[i]
        local data = dataRows[i]

        if data then
            RenderRow(row, data, currentView)
        else
            row:Hide()
        end
    end
end

local function CreateHistoryUI()
    if historyFrame then
        return historyFrame
    end

    -- BasicFrameTemplateWithInset supplies Blizzard's standard portrait-less
    -- panel chrome, NineSlice border, title background, and close button.
    local frame = CreateFrame(
        "Frame",
        "PlayedPlusHistoryFrame",
        UIParent,
        "BasicFrameTemplateWithInset"
    )

    if UISpecialFrames then
        local found = false

        for _, frameName in ipairs(UISpecialFrames) do
            if frameName == "PlayedPlusHistoryFrame" then
                found = true
                break
            end
        end

        if not found then
            table.insert(
                UISpecialFrames,
                "PlayedPlusHistoryFrame"
            )
        end
    end

    frame:SetSize(900, 500)
    frame:SetPoint("CENTER")
    frame:SetFrameStrata("DIALOG")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:Hide()

    frame:SetScript("OnDragStart", function(self)
        self:StartMoving()
    end)

    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
    end)

    -- A translucent parchment-dark content wash sits inside Blizzard's native
    -- frame chrome. Opacity remains user-configurable without fading text.
    frame.background = frame:CreateTexture(nil, "BACKGROUND", nil, 1)
    frame.background:SetPoint("TOPLEFT", frame, "TOPLEFT", 12, -32)
    frame.background:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 12)
    frame.background:SetTexture("Interface\\Buttons\\WHITE8X8")

    -- Keep this alias for the existing opacity routine. The native template
    -- owns the visible title bar, so this texture itself stays invisible.
    frame.titleBar = frame:CreateTexture(nil, "BACKGROUND")
    frame.titleBar:SetSize(1, 1)
    frame.titleBar:SetAlpha(0)

    frame.windowTitle = frame.TitleText or CreateText(
        frame,
        "GameFontNormalLarge",
        "TOP",
        frame,
        "TOP",
        0,
        -8,
        "CENTER"
    )

    -- BasicFrameTemplateWithInset already supplies the Blizzard close button.
    local closeButton = frame.CloseButton
    if closeButton then
        closeButton:SetScript("OnClick", function()
            frame:Hide()
        end)
    end

    -- Character-sheet style identity block. The live unit portrait keeps this
    -- native and automatically matches the character being documented.
    frame.portraitFrame = CreateFrame("Frame", nil, frame)
    frame.portraitFrame:SetSize(68, 68)
    frame.portraitFrame:SetPoint("TOPLEFT", frame, "TOPLEFT", 24, -40)

    -- Keep the live portrait at the existing readable size. Avoid scaling the
    -- low-resolution Minimap tracking artwork; it becomes visibly pixelated.
    frame.portrait = frame.portraitFrame:CreateTexture(nil, "ARTWORK")
    frame.portrait:SetSize(56, 56)
    frame.portrait:SetPoint("CENTER")
    frame.portrait:SetTexCoord(0.09, 0.91, 0.09, 0.91)

    -- Prefer Blizzard's circular portrait mask when available. The ring stays
    -- close to its native resolution so it remains crisp instead of pixelating.
    if frame.portrait.CreateMaskTexture and frame.portrait.AddMaskTexture then
        frame.portraitMask = frame.portraitFrame:CreateMaskTexture()
        frame.portraitMask:SetTexture(
            "Interface\\CharacterFrame\\TempPortraitAlphaMask",
            "CLAMPTOBLACKADDITIVE",
            "CLAMPTOBLACKADDITIVE"
        )
        frame.portraitMask:SetAllPoints(frame.portrait)
        frame.portrait:AddMaskTexture(frame.portraitMask)
    end

    -- Draw our own restrained circular presentation: the portrait is masked to
    -- a circle, with two thin circular rings layered around it. These use the
    -- same alpha mask as geometry rather than scaling the chunky Minimap frame.
    frame.portraitRingOuter = frame.portraitFrame:CreateTexture(nil, "OVERLAY")
    frame.portraitRingOuter:SetSize(64, 64)
    frame.portraitRingOuter:SetPoint("CENTER")
    frame.portraitRingOuter:SetTexture("Interface\\Buttons\\WHITE8X8")
    frame.portraitRingOuter:SetVertexColor(0.50, 0.34, 0.14, 1)

    frame.portraitRingInner = frame.portraitFrame:CreateTexture(nil, "OVERLAY")
    frame.portraitRingInner:SetSize(60, 60)
    frame.portraitRingInner:SetPoint("CENTER")
    frame.portraitRingInner:SetTexture("Interface\\Buttons\\WHITE8X8")
    frame.portraitRingInner:SetVertexColor(0.08, 0.06, 0.035, 1)

    if frame.portrait.CreateMaskTexture and frame.portrait.AddMaskTexture then
        frame.ringMaskOuter = frame.portraitFrame:CreateMaskTexture()
        frame.ringMaskOuter:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        frame.ringMaskOuter:SetAllPoints(frame.portraitRingOuter)
        frame.portraitRingOuter:AddMaskTexture(frame.ringMaskOuter)

        frame.ringMaskInner = frame.portraitFrame:CreateMaskTexture()
        frame.ringMaskInner:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        frame.ringMaskInner:SetAllPoints(frame.portraitRingInner)
        frame.portraitRingInner:AddMaskTexture(frame.ringMaskInner)
    end

    -- Portrait sits above the inner disc, leaving a narrow bronze ring visible.
    frame.portrait:SetDrawLayer("OVERLAY", 2)

    frame.characterName = CreateText(
        frame,
        "GameFontNormalLarge",
        "TOPLEFT",
        frame,
        "TOPLEFT",
        100,
        -48,
        "LEFT"
    )

    frame.characterMeta = CreateText(
        frame,
        "GameFontHighlightSmall",
        "TOPLEFT",
        frame,
        "TOPLEFT",
        101,
        -70,
        "LEFT"
    )
    frame.characterMeta:SetTextColor(0.82, 0.72, 0.52, 1)

    frame.sectionTitle = CreateText(
        frame,
        "GameFontNormal",
        "TOP",
        frame,
        "TOP",
        0,
        -54,
        "CENTER"
    )

    frame.summaryLevel = CreateText(
        frame,
        "GameFontHighlight",
        "TOPLEFT",
        frame,
        "TOPLEFT",
        30,
        -111,
        "LEFT"
    )

    frame.summaryToday = CreateText(
        frame,
        "GameFontHighlight",
        "TOPLEFT",
        frame,
        "TOPLEFT",
        190,
        -111,
        "LEFT"
    )

    frame.summaryTotal = CreateText(
        frame,
        "GameFontHighlight",
        "TOPLEFT",
        frame,
        "TOPLEFT",
        325,
        -111,
        "LEFT"
    )

    frame.levelsButton = CreateFlatButton(
        frame,
        "Levels",
        95,
        28
    )
    frame.levelsButton:SetPoint(
        "TOPRIGHT",
        frame,
        "TOPRIGHT",
        -325,
        -101
    )
    frame.levelsButton:SetScript("OnClick", function()
        currentView = "levels"
        RefreshHistoryUI()
    end)

    frame.daysButton = CreateFlatButton(
        frame,
        "Days",
        95,
        28
    )
    frame.daysButton:SetPoint(
        "LEFT",
        frame.levelsButton,
        "RIGHT",
        8,
        0
    )
    frame.daysButton:SetScript("OnClick", function()
        currentView = "days"
        RefreshHistoryUI()
    end)

    frame.accountButton = CreateFlatButton(
        frame,
        "Account",
        95,
        28
    )
    frame.accountButton:SetPoint(
        "LEFT",
        frame.daysButton,
        "RIGHT",
        8,
        0
    )
    frame.accountButton:SetScript("OnClick", function()
        currentView = "account"
        RefreshHistoryUI()
    end)

    local syncButton = CreateFlatButton(
        frame,
        "Sync",
        78,
        28
    )
    syncButton:SetPoint(
        "TOPRIGHT",
        frame,
        "TOPRIGHT",
        -24,
        -44
    )
    syncButton:SetScript("OnClick", function()
        RequestPlayedSync()
        Print("Requested played-time sync.")
    end)

    local separator = frame:CreateTexture(nil, "ARTWORK")
    separator:SetPoint(
        "TOPLEFT",
        frame,
        "TOPLEFT",
        24,
        -151
    )
    separator:SetPoint(
        "TOPRIGHT",
        frame,
        "TOPRIGHT",
        -24,
        -151
    )
    separator:SetHeight(1)
    separator:SetTexture("Interface\\Buttons\\WHITE8X8")
    separator:SetVertexColor(0.35, 0.35, 0.35, 1)

    frame.leftHeader = CreateText(
        frame,
        "GameFontNormalSmall",
        "TOPLEFT",
        frame,
        "TOPLEFT",
        28,
        -145,
        "LEFT"
    )

    local timeHeader = CreateText(
        frame,
        "GameFontNormalSmall",
        "TOPLEFT",
        frame,
        "TOPLEFT",
        106,
        -145,
        "LEFT"
    )
    timeHeader:SetText("Time played")

    frame.barHeader = CreateText(
        frame,
        "GameFontNormalSmall",
        "TOPLEFT",
        frame,
        "TOPLEFT",
        208,
        -145,
        "CENTER"
    )

    frame.detailsHeader = CreateText(
        frame,
        "GameFontNormalSmall",
        "TOPLEFT",
        frame,
        "TOPLEFT",
        718,
        -145,
        "CENTER"
    )
    frame.detailsHeader:SetWidth(160)
    frame.detailsHeader:SetText("Details")

    frame.statusHeader = CreateText(
        frame,
        "GameFontNormalSmall",
        "TOPLEFT",
        frame,
        "TOPLEFT",
        820,
        -145,
        "CENTER"
    )
    frame.statusHeader:SetWidth(65)
    frame.statusHeader:SetText("Status")

    frame.rows = {}

    for i = 1, MAX_ROWS do
        frame.rows[i] = CreateHistoryRow(frame, i)
    end

    local legendSeparator = frame:CreateTexture(nil, "ARTWORK")
    legendSeparator:SetPoint(
        "BOTTOMLEFT",
        frame,
        "BOTTOMLEFT",
        24,
        44
    )
    legendSeparator:SetPoint(
        "BOTTOMRIGHT",
        frame,
        "BOTTOMRIGHT",
        -24,
        44
    )
    legendSeparator:SetHeight(1)
    legendSeparator:SetTexture("Interface\\Buttons\\WHITE8X8")
    legendSeparator:SetVertexColor(0.22, 0.22, 0.22, 0.65)

    frame.xpLegendRegions = {}

    local function CompactLegend(x, color, label)
        local swatch = frame:CreateTexture(nil, "ARTWORK")
        swatch:SetSize(12, 12)
        swatch:SetPoint(
            "BOTTOMLEFT",
            frame,
            "BOTTOMLEFT",
            x,
            17
        )
        swatch:SetTexture("Interface\\Buttons\\WHITE8X8")
        swatch:SetVertexColor(
            color[1],
            color[2],
            color[3],
            1
        )

        local text = frame:CreateFontString(
            nil,
            "OVERLAY",
            "GameFontHighlightSmall"
        )
        text:SetPoint("LEFT", swatch, "RIGHT", 5, 0)
        text:SetText(label)

        table.insert(frame.xpLegendRegions, swatch)
        table.insert(frame.xpLegendRegions, text)
    end

    CompactLegend(28, XP_COLORS.mob, "Kills · mob XP")
    CompactLegend(180, XP_COLORS.quest, "Quests · turn-ins")
    CompactLegend(345, XP_COLORS.dungeon, "Dungeon · kill XP")
    CompactLegend(520, XP_COLORS.exploration, "Exploration XP")
    CompactLegend(680, XP_COLORS.other, "Other · unclassified")

    frame.dayLegendHint = frame:CreateFontString(
        nil,
        "OVERLAY",
        "GameFontHighlightSmall"
    )
    frame.dayLegendHint:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -28, 17)
    frame.dayLegendHint:SetText("Days: class-colored segments • hover for character")
    frame.dayLegendHint:Hide()

    historyFrame = frame

    ApplyWindowOpacity()

    frame:SetScript("OnShow", function()
        ApplyWindowOpacity()
        RefreshCharacterHeader()
        RefreshHistoryUI()
    end)

    return frame
end

local function ToggleHistoryUI()
    local frame = CreateHistoryUI()

    if frame:IsShown() then
        frame:Hide()
    else
        RefreshHistoryUI()
        frame:Show()
    end
end

function PlayedPlus_ApplyWindowOpacity()
    ApplyWindowOpacity()
end

function PlayedPlus_RefreshTracker()
    if historyFrame and historyFrame:IsShown() then
        RefreshHistoryUI()
    end
end

function PlayedPlus_OpenTracker()
    local frame = CreateHistoryUI()
    RefreshHistoryUI()
    frame:Show()
    frame:Raise()
end

function PlayedPlus_ResetDisplayDefaults()
    local db = EnsureDatabase()

    db.showLabels = true
    db.showTooltips = true
    db.showDetails = true
    db.showStatus = true
    db.debugXPLog = false

    ApplyWindowOpacity()
    PlayedPlus_RefreshTracker()
end

-- ============================================================================
-- XP ledger inspection and options navigation
-- ============================================================================
local function ShowXPLog(requested)
    CaptureXPBarDelta("xplog_check")
    ApplyPendingSignals()

    local db = EnsureDatabase()
    local level = UnitLevel("player") or db.currentLevel or 1
    local transactions = BuildPersistedTransactionSummaries(level)

    if #transactions == 0 then
        Print(
            string.format(
                "No XP transactions logged yet for level %d.",
                level
            )
        )
        return
    end

    local count

    if requested == "all" then
        count = #transactions
    else
        count = math.floor(tonumber(requested) or 10)
        count = Clamp(count, 1, 250)
    end

    count = math.min(count, #transactions)

    Print(string.format(
        "Showing %d of %d XP transactions touching level %d:",
        count,
        #transactions,
        level
    ))

    local first = math.max(1, #transactions - count + 1)

    for i = first, #transactions do
        local summary = transactions[i]
        local when =
            summary.at and date("%H:%M:%S", summary.at) or "?"
        local context =
            summary.instanceName
            or summary.zone
            or ""
        local sourceLabel = FormatSummarySource(summary)
        local levels = FormatSummaryLevels(summary)

        Print(string.format(
            "%s | %s | %d XP | %s | %s | %s",
            when,
            sourceLabel,
            tonumber(summary.amount) or 0,
            context,
            summary.reason or summary.captureReason or "",
            levels
        ))
    end
end

local function OpenOptions()
    local panelName = "Played Plus"

    if Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(panelName)
    elseif InterfaceOptionsFrame_OpenToCategory
        and PlayedPlusOptionsPanel then
        InterfaceOptionsFrame_OpenToCategory(
            PlayedPlusOptionsPanel
        )
        InterfaceOptionsFrame_OpenToCategory(
            PlayedPlusOptionsPanel
        )
    else
        Print("Unable to open the options panel on this client.")
    end
end

local function ShowHelp()
    Print("Commands:")
    Print("/pp - open Played Plus")
    Print("/pp options - open addon settings")
    Print("/pp today - show today's stats")
    Print("/pp level - show current level stats")
    Print("/pp levels - show recent level history")
    Print("/pp account - show account-wide lifetime /played")
    Print("/pp dungeon - manually record one dungeon completion")
    Print("/pp sync - request a fresh /played total")
    Print("/pp xplog [number|all] - show current-level XP ledger")
    Print("/pp debugxp - toggle live XP debug logging")
    Print("/ptp remains available as a compatibility alias")
end

-- ============================================================================
-- Slash commands
-- ============================================================================
SLASH_PLAYEDPLUS1 = "/pp"
SLASH_PLAYEDPLUS2 = "/playedplus"
SLASH_PLAYEDPLUS3 = "/ptp"
SLASH_PLAYEDPLUS4 = "/playedtrackerplus"

SlashCmdList["PLAYEDPLUS"] = function(msg)
    msg = string.lower((msg or ""):match("^%s*(.-)%s*$"))

    if msg == "" or msg == "ui" then
        ToggleHistoryUI()
    elseif msg == "options" or msg == "settings" then
        OpenOptions()
    elseif msg == "today" then
        ShowToday()
    elseif msg == "level" then
        ShowCurrentLevel()
    elseif msg == "levels" then
        ShowRecentLevels()
    elseif msg == "dungeon" then
        IncrementActivity("dungeons", 1)
        Print("Recorded one dungeon completion.")
        PlayedPlus_RefreshTracker()
    elseif msg == "sync" then
        RequestPlayedSync()
        Print("Requested played-time sync.")
    elseif msg == "xplog" then
        ShowXPLog()
    elseif string.sub(msg, 1, 6) == "xplog " then
        ShowXPLog(string.match(msg, "^xplog%s+(.+)$"))
    elseif msg == "debugxp" then
        local db = EnsureDatabase()
        db.debugXPLog = not db.debugXPLog

        Print(
            "Live XP debug logging "
            .. (db.debugXPLog and "|cff33ff33enabled|r." or "|cffff5555disabled|r.")
        )
    elseif msg == "account" then
        RequestPlayedSync()

        local classRows, accountTotal, characterCount, realmCount =
            GetAccountLifetimeData()

        Print(string.format(
            "Account /played: %s across %d character%s on %d realm%s.",
            FormatDuration(accountTotal),
            characterCount,
            characterCount == 1 and "" or "s",
            realmCount,
            realmCount == 1 and "" or "s"
        ))

        for _, classData in ipairs(classRows) do
            Print(string.format(
                "%s: %s (%d%%)",
                classData.className,
                FormatDuration(classData.seconds),
                math.floor((classData.percent or 0) + 0.5)
            ))
        end

        local frame = CreateHistoryUI()
        currentView = "account"
        RefreshHistoryUI()
        frame:Show()
        frame:Raise()
    else
        ShowHelp()
    end
end

-- ============================================================================
-- Event registration and game-event handlers
-- ============================================================================
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:RegisterEvent("PLAYER_LEVEL_UP")
eventFrame:RegisterEvent("TIME_PLAYED_MSG")
eventFrame:RegisterEvent("QUEST_TURNED_IN")
eventFrame:RegisterEvent("CHAT_MSG_COMBAT_XP_GAIN")
eventFrame:RegisterEvent("CHAT_MSG_SYSTEM")
eventFrame:RegisterEvent("PLAYER_XP_UPDATE")

pcall(function()
    eventFrame:RegisterEvent("LFG_COMPLETION_REWARD")
end)

pcall(function()
    eventFrame:RegisterEvent("ENCOUNTER_END")
end)

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loadedAddon = ...

        if loadedAddon ~= ADDON_NAME then
            return
        end

        local db = EnsureDatabase()

        MigrateLedger()
        EnsureAccountDatabase()
        ImportLegacyCharacterDays()
        SyncAllCharacterDaysToAccount()

        db.currentLevel =
            UnitLevel("player")
            or db.currentLevel
            or 1

        EnsureDay()
        EnsureLevel(db.currentLevel)
        CreateHistoryUI()

        Print(
            "v1.0.2 loaded. Type /pp to open Played Plus."
        )

    elseif event == "PLAYER_ENTERING_WORLD" then
        local db = EnsureDatabase()

        db.currentLevel =
            UnitLevel("player")
            or db.currentLevel
            or 1

        EnsureDay()
        EnsureLevel(db.currentLevel)
        EnsureAccountDatabase()
        ImportLegacyCharacterDays()
        SyncAllCharacterDaysToAccount()
        EnsureCurrentLevelBaseline()
        InitializeXPObservation()

        sessionStarted = true
        lastTick = GetTime()

        RequestPlayedSync()

    elseif event == "PLAYER_LOGOUT" then
        FinalizeCurrentTick()
        SyncAllCharacterDaysToAccount()

        local db = EnsureDatabase()
        db.lastSeenAt = time()

    elseif event == "TIME_PLAYED_MSG" then
        local totalPlayed, levelPlayed = ...

        pendingPlayedRequest = false

        local db = EnsureDatabase()
        local level = UnitLevel("player") or db.currentLevel or 1
        local levelData = EnsureLevel(level)

        if tonumber(totalPlayed) then
            db.lastKnownTotalPlayed = totalPlayed

            local _, _, _, character = EnsureAccountDatabase()
            character.totalPlayed = totalPlayed
            character.level = level
            character.lastPlayedSyncAt = time()
        end

        if tonumber(levelPlayed)
            and levelPlayed > levelData.seconds then
            levelData.seconds = levelPlayed
        end

        PlayedPlus_RefreshTracker()

    elseif event == "PLAYER_LEVEL_UP" then
        FinalizeCurrentTick()
        CaptureXPBarDelta("PLAYER_LEVEL_UP")
        ApplyPendingSignals()

        local newLevel = tonumber((...)) or UnitLevel("player")

        if not newLevel then
            return
        end

        local db = EnsureDatabase()
        local oldLevel = newLevel - 1
        local oldLevelData = EnsureLevel(oldLevel)

        oldLevelData.completedAt = oldLevelData.completedAt or time()

        if not oldLevelData.xpRequired
            or oldLevelData.xpRequired <= 0 then
            oldLevelData.xpRequired = observedXPMax or 0
        end

        db.currentLevel = newLevel

        local newLevelData = EnsureLevel(newLevel)
        newLevelData.startedAt = newLevelData.startedAt or time()
        newLevelData.xpRequired =
            UnitXPMax("player")
            or newLevelData.xpRequired
            or 0

        Print(string.format(
            "Level %d complete in %s. Quests: %d, kills: %d, dungeons: %d.",
            oldLevel,
            FormatDuration(oldLevelData.seconds),
            oldLevelData.quests,
            GetLevelKillCount(oldLevelData),
            oldLevelData.dungeons
        ))

        local _, _, _, character = EnsureAccountDatabase()
        character.level = newLevel
        character.lastSeenAt = time()

        RequestPlayedSync()
        PlayedPlus_RefreshTracker()

    elseif event == "PLAYER_XP_UPDATE" then
        local captured = CaptureXPBarDelta("PLAYER_XP_UPDATE")
        local classified = ApplyPendingSignals()

        if captured or classified then
            PlayedPlus_RefreshTracker()
        end

    elseif event == "QUEST_TURNED_IN" then
        local questID, xpReward = ...

        IncrementActivity("quests", 1)
        CaptureXPBarDelta("quest_signal")

        if tonumber(xpReward) and xpReward > 0 then
            QueueClassificationSignal(
                "quest",
                "quest",
                xpReward,
                CLASSIFICATION_PRIORITY.quest,
                "quest_turn_in",
                {
                    questID = questID,
                }
            )
        end

        ApplyPendingSignals()
        PlayedPlus_RefreshTracker()

    elseif event == "CHAT_MSG_COMBAT_XP_GAIN" then
        local message = ...
        local xpAmount = ParseXPFromCombatMessage(message)

        CaptureXPBarDelta("combat_signal")

        if xpAmount and xpAmount > 0 then
            local inDungeon = IsInFivePlayerDungeon()

            QueueClassificationSignal(
                inDungeon and "dungeon" or "mob",
                "kill",
                xpAmount,
                inDungeon
                    and CLASSIFICATION_PRIORITY.dungeon
                    or CLASSIFICATION_PRIORITY.mob,
                "combat_xp",
                {
                    rawMessage = message,
                }
            )
        end

        ApplyPendingSignals()
        PlayedPlus_RefreshTracker()

    elseif event == "CHAT_MSG_SYSTEM" then
        local message = ...
        local amount = ParseExplorationXP(message)

        if amount and amount > 0 then
            CaptureXPBarDelta("exploration_signal")

            QueueClassificationSignal(
                "other",
                "exploration",
                amount,
                CLASSIFICATION_PRIORITY.exploration,
                "exploration",
                {
                    rawMessage = message,
                }
            )

            ApplyPendingSignals()
            PlayedPlus_RefreshTracker()
        end

    elseif event == "ENCOUNTER_END" then
        local encounterID, encounterName, difficultyID, groupSize, success = ...

        if success == 1
            and IsInFivePlayerDungeon()
            and encounterName
            and TBC_FINAL_DUNGEON_BOSSES[encounterName] then

            RecordDungeonCompletion(encounterName)
            PlayedPlus_RefreshTracker()
        end

    elseif event == "LFG_COMPLETION_REWARD" then
        RecordDungeonCompletion("LFG")
        PlayedPlus_RefreshTracker()
    end
end)

-- ============================================================================
-- Runtime polling / timers
-- ============================================================================
eventFrame:SetScript("OnUpdate", function(self, elapsed)
    if not sessionStarted then
        return
    end

    xpPollAccumulator = xpPollAccumulator + elapsed

    if xpPollAccumulator >= XP_POLL_INTERVAL then
        xpPollAccumulator = 0

        local captured = CaptureXPBarDelta("xp_poll")
        local classified = ApplyPendingSignals()

        FlushSettledXPDebug()
        PruneRuntimeQueues()

        if captured or classified then
            PlayedPlus_RefreshTracker()
        end
    end

    tickAccumulator = tickAccumulator + elapsed

    if tickAccumulator < TICK_INTERVAL then
        return
    end

    local now = GetTime()
    local delta = now - (lastTick or now)

    lastTick = now
    tickAccumulator = 0

    if delta > 0 and delta < 120 then
        AddTrackedSeconds(delta)
    end

    if historyFrame and historyFrame:IsShown() then
        historyFrame.refreshAccumulator =
            (historyFrame.refreshAccumulator or 0)
            + delta

        if historyFrame.refreshAccumulator >= 2 then
            historyFrame.refreshAccumulator = 0
            RefreshHistoryUI()
        end
    end
end)
