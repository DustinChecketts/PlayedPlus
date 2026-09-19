# Played Plus — Architecture

Played Plus is maintained as one addon codebase across supported Classic clients and WoW Forever. The architecture keeps the existing tracking model intact while isolating Blizzard client differences.

## Design goals

- Preserve current Played Plus behavior and SavedVariables.
- Keep one addon version across supported clients.
- Prefer capability detection over client/version checks.
- Keep Blizzard API/client compatibility in `Compat.lua`.
- Keep gameplay tracking, XP classification, account aggregation, and UI behavior in `PlayedPlus.lua`.
- Keep settings controls in `Options.lua`.
- Avoid intentional behavior changes during compatibility-only refactors.

WoW Forever must not be treated as Retail solely because it currently reports `WOW_PROJECT_MAINLINE`. When explicit identification is required, the current Forever beta uses the 16xxx interface generation (currently 16001).

## Core data rules

### XP collection

`UnitXP("player")` deltas remain the authoritative source of XP gained.

Quest, combat, dungeon, and exploration events are classification signals. They annotate an XP transaction that has already been captured and must not create an independent XP total.

A level-up can require two internal ledger fragments so XP can be assigned to the correct levels. Both fragments share a `transactionID` and `transactionAmount`, so reporting still represents one logical XP transaction.

### Played time

`PlayedPlusDB.days[date].seconds` is authoritative for each character.

`PlayedPlusAccountDB` is an account-wide reporting index grouped by realm. It stores snapshots of each character's daily total. Snapshot assignment is intentional; do not maintain a second incrementing account timer.

## File responsibilities

- `Compat.lua` — Blizzard client/API detection and compatibility helpers.
- `PlayedPlus.lua` — tracking, SavedVariables migrations, XP ledger/classification, account aggregation, tracker UI, commands, and game events.
- `Options.lua` — Blizzard AddOns settings controls only.
- `PlayedPlus.toc` — supported interfaces, metadata, SavedVariables, and load order.
- `.pkgmeta` — release package contents.
- `.github/workflows/release.yml` — tag/browser release packaging and CurseForge publishing.

## SavedVariables

### Per-character: `PlayedPlusDB`

Important areas:

- `days[YYYY-MM-DD]`: seconds, quests, mobs, dungeons
- `levels[level]`: seconds, quests, mobs, dungeons, ledger
- display/debug preferences

### Account-wide: `PlayedPlusAccountDB`

- `realms[realmName].characters[Name-Realm]`
- `realms[realmName].days[YYYY-MM-DD].characters[Name-Realm]`

The legacy `PlayedTrackerPlusDB` and `PlayedTrackerPlusAccountDB` names remain loaded for rename migration.

## Compatibility strategy

Feature code should use capability checks where Blizzard exposes equivalent functionality through different APIs. Event registration that may vary by client should be guarded instead of assuming every event exists.

ForeverTest established the main compatibility rules used by this refactor:

- modern `Settings` APIs are available on Forever;
- legacy `InterfaceOptions*` APIs cannot be assumed;
- use individually confirmed/needed events rather than broad event sweeps;
- do not infer Forever from `WOW_PROJECT_ID` alone.

The existing XP and `/played` behavior is intentionally preserved for the first Forever test branch. Any Forever-only gameplay divergence discovered in live testing should be handled behind `Compat.lua` rather than forked into a second addon.

## Release workflow

`main` is the known-good/release branch. Compatibility work is developed on branches and merged only after testing.

Releases use the same workflow established for VendorPricePlus:

1. Merge tested code to `main`.
2. Run **Package and release** from GitHub Actions and enter a semantic version, or push a `v*` tag.
3. The workflow creates/checks out the version tag.
4. BigWigs Packager builds the addon and publishes the GitHub release and CurseForge file using the repository `CF_API_KEY` secret.

The packager action is pinned to the reviewed v2.6.1 commit with explicit WoW Forever 16xxx support.

## Versioning and migrations

Addon versions and SavedVariables schema versions are separate. Increment `DB_VERSION`, `ACCOUNT_DB_VERSION`, or `LEDGER_VERSION` only when persisted data requires migration. Compatibility refactors and UI-only changes should not force a data migration.
