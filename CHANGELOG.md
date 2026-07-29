# Changelog

All notable PlayerNotes changes are documented here.

## [2.9.0] - Unreleased

### Added

- Restored the Party Finder applicant note button that shipped in the Nexus 2.8.0 package but was missing from the repository.
- Added a debug-echo option for confirming the loaded PlayerNotes version.
- Added release metadata validation and a repeatable release checklist.

### Changed

- Integrated LucLeto's CPU-usage improvements from commit `3041da7`, including post-only draw hooks, cached player-ID lookups, reduced hover work, and batched persistence writes.
- Integrated the reviewed local 2.8.1 optimizations: roster-scoped name decoration, cached scalar settings and rendered state, bounded no-op persistence, cached Group Finder identities, and one-time world-marker geometry.
- Bound Party Finder note buttons when request rows are created instead of scanning every request widget every frame.
- Removed the unused duplicate world-marker template; the registered inline template remains the single implementation.
- Made 2.9.0 the consistent version in the mod metadata, source header, load message, README, and changelog.

### Fixed

- Preserved the Social-panel tooltip lifecycle fix merged after 2.7.4.
- Prevented inline note/icon decoration from leaking into unrelated UI that calls `PlayerInfo.user_display_name`.
- Gave each world marker an independent payload instead of sharing one mutable table between asynchronous marker events.
- Cleared stale world-marker note bookkeeping when players or notes disappear and when the HUD is destroyed.
- Avoided recording the Mourningstar as a player's location while game-mode state is still loading.

## [2.8.0] - 2026-04-15

- Added the note action for applicants in Party Finder.
- Added safeguards around Party Finder note rendering.

## [2.7.4] - 2026-04-14

- Last GitHub-documented release before the Nexus-only 2.8.0 changes.
