# Played Plus — Architecture

Version 1.0.0 is a maintenance release. It establishes the public Played Plus name and adds account-wide lifetime `/played` aggregation across every realm observed by the addon.

## Core rules

### XP collection

`UnitXP("player")` deltas are the authoritative source of XP gained.

Quest, combat, dungeon, and exploration events are classification signals.
They annotate an XP transaction that has already been captured. They must not
create an independent XP total.

A level-up can require two internal ledger fragments so XP can be assigned to
the correct levels. Both fragments share a `transactionID` and
`transactionAmount`, so `/ptp xplog` and live debug logging still report one
logical XP transaction.

### Played time

`PlayedPlusDB.days[date].seconds` is authoritative for each character.

`PlayedPlusAccountDB` is an account-wide reporting index grouped by
realm. It stores a snapshot of each character's daily total. Snapshot
assignment is intentional: do not maintain a second incrementing account timer.

## SavedVariables

### Per-character: `PlayedPlusDB`

Important areas:

- `days[YYYY-MM-DD]`
  - `seconds`
  - `quests`
  - `mobs`
  - `dungeons`
- `levels[level]`
  - `seconds`
  - `quests`
  - `mobs`
  - `dungeons`
  - `ledger[]`
- preferences
  - `windowOpacity`
  - `showLabels`
  - `showTooltips`
  - `showDetails`
  - `showStatus`
  - `debugXPLog`

### Account-wide: `PlayedPlusAccountDB`

- `realms[realmName]`
  - `characters[Name-Realm]`
    - `name`
    - `realm`
    - `classFile`
    - `guid`
    - `lastSeenAt`
  - `days[YYYY-MM-DD].characters[Name-Realm]`
    - `name`
    - `classFile`
    - `seconds`
    - `syncedAt`

## Canonical XP ledger

A modern ledger entry contains fields such as:

- `id`
- `at`
- `level`
- `amount`
- `source`
- `subtype`
- `reason`
- `captureReason`
- `classificationPriority`
- `transactionID`
- `transactionAmount`
- `primary`
- `zone`
- `instanceName`
- `instanceType`

Current source values:

- `mob`
- `quest`
- `dungeon`
- `other`

Useful subtypes:

- `kill`
- `quest`
- `exploration`
- `unclassified`

## Runtime-only state

Do not persist these:

- recent XP transactions
- pending classification signals
- the UnitXP observation baseline
- timer/poll accumulators
- UI frame references
- dungeon-completion debounce state

They exist only to join asynchronous Blizzard events to the correct persisted
transaction.

## UI semantics

### Levels view

- bar width = overall progress through the level
- colored bar portions = source mix of XP earned
- percentages inside segments/tooltips = share of earned XP
- gold percentage beside the current fill = overall level progress

### Days view

- row time = total played time across tracked characters on the current realm
- each segment = one character
- segment color = WoW class color
- tooltip = character identity, class, time, and share of the day

## Extension points

### Add an XP source/classifier

1. Register/handle the relevant Blizzard event.
2. Call `CaptureXPBarDelta()` first.
3. Parse the reported XP amount when available.
4. Call `QueueClassificationSignal()`.
5. Assign a priority matching the confidence of that source.
6. Never add another XP aggregate.

### Add a derived level statistic

Prefer deriving it from the ledger. Persist only information that cannot be
reconstructed from authoritative data.

### Add account/realm reporting

Keep character-owned totals authoritative and sync snapshots to the shared
realm database. Do not create a second independent timer.

### Add options

`Options.lua` should only change preferences and refresh the tracker. Keep
game/event logic in `PlayedPlus.lua`.

## Debug commands

- `/ptp xplog [number|all]` — canonical XP transactions
- `/ptp debugxp` — finalized live XP transaction logging
- `/ptp account` — synchronized characters and today's realm time
- `/ptp sync` — request Blizzard `/played`

## Versioning and migrations

The addon version and SavedVariables schema versions are intentionally
separate.

Increment `DB_VERSION`, `ACCOUNT_DB_VERSION`, or `LEDGER_VERSION` only when a
data migration is required. Refactors and UI-only changes should not force a
migration.


## Account-wide lifetime `/played`

Each time a character is logged into, Played Plus requests Blizzard's
`RequestTimePlayed()` value and stores the returned lifetime total in the
account-wide character index.

This works across realms because `PlayedPlusAccountDB` is account-wide
SavedVariables data. WoW cannot query offline characters, so a character must
be logged into with Played Plus enabled at least once before it can appear in
the Account tab.

The Account tab derives class totals from all stored realm/character records.
No separate account timer is maintained.

## Rename migration

Played Plus 1.0.0 loads the legacy `PlayedTrackerPlusDB` and
`PlayedTrackerPlusAccountDB` SavedVariables names so existing users retain
their data. If the new variables do not yet exist, the old tables are adopted
as the new Played Plus databases automatically.
