# Changelog

All notable PlayerNotes changes are documented here.

## [3.1.0] - Unreleased

### Added

- Added a dedicated **2D World Note Appearance** options section.
- Added a 0–100% overall opacity slider for world-note boxes.
- Added Custom, Red, Blue, Green, and Yellow color choices, with Yellow as the default.
- Added independent 0–255 red, green, and blue sliders.
- Added behavior coverage for default appearance, bidirectional preset/RGB synchronization, rendered widget colors, opacity, and live marker refresh.

### Changed

- Selecting a named color now updates all RGB sliders immediately.
- Moving an RGB slider now selects an exact matching named color or switches the dropdown to Custom.
- Active world-note markers are recreated once on the next bounded HUD scan after an appearance change, avoiding per-frame settings reads.

## [3.0.0] - 2026-07-29

### Added

- Added an at-a-glance Party Finder display for saved notes: hold Show Details (Shift by default) to show wrapped note previews on every matching group-member card without individual mouse hovering.
- Added a default-on option to disable the Party Finder group-note display independently.
- Added behavior coverage for preview-pass hot reload safety, identity-bound note resolution, note truncation, details-only visibility, and the new option.
- Added a tracked-file synchronization command that deploys and hash-verifies the canonical repository against the active Darktide mod directory.

### Changed

- Reused Darktide's configurable Show Details action and preview-row lifecycle, preserving remapped keyboard and controller input.
- Cached each Party Finder preview note by account identity and notes revision so normal frame rendering does not repeat social-service identity work.

## [2.10.0] - 2026-07-29

### Added

- Added a documented project audit covering bugs, crash isolation, CPU/memory behavior, persistence growth, feature cohesion, maintainability, and residual risks.
- Added executable Lua behavior tests for identity migration/isolation, persistence bounds, destructive confirmation, overlay cleanup, and HUD failure isolation.
- Added explanatory tooltips for every mod option.

### Changed

- Made Darktide `account_id` the canonical player key, with automatic migration of legacy platform-keyed notes, names, aliases, character mappings, and last-seen history.
- Made note lookup strictly identity-bound; display names are now labels and uniquely resolved command aliases, never note keys.
- Limited notes to 512 Unicode characters and bounded inline, top-bar, tooltip, and world-note rendering.
- Retained last-seen history only for currently noted players.
- Added a one-second retry cooldown for loading-state identity misses and platform-only fallbacks instead of caching an incomplete result for the whole view.
- Rebuilt transient identity indexes after bounded character-cache eviction and game-state exits.
- Updated commands to support mapped names containing spaces, produce deterministic identity-explicit output, and show actionable ambiguity messages.
- Reconciled the README, options, localization, release checklist, feature behavior, identity semantics, and version references.

### Fixed

- Fixed Social hover detection for scrolled rows below the roster scenegraph's nominal height, including partially clipped boundary rows.
- Normalized Darktide platform/favorite glyphs out of stored player tags so plain tags such as `Shark#7571` resolve for `/set_note` and `/delete_note`.
- Added bounded live-tag resolution and command-time refresh for both direct note commands while preserving ambiguity rejection.
- Restored notes for offline cross-network friends by safely migrating a single stored `name#1234` platform alias to the canonical account ID; plain and ambiguous names remain excluded.
- Made `/set_note` refresh currently visible players on a cache miss, even when world markers are disabled or Social player information is still loading.
- Decoupled live identity and last-seen scans from world-marker visibility settings.
- Fixed startup localization errors by passing `%s` replacements through DMF's localization API instead of caching incomplete format templates.
- Restored the base UI's shared render layer and closed the PlayerNotes pass after protected overlay failures.
- Isolated HUD scans per player so one malformed player or marker request cannot prevent other players from being processed or stale markers from being cleaned.
- Guarded loading-sensitive player, social-service, event-manager, popup, marker, mission, and lifecycle paths.
- Added bounded notification initialization retries and prevented a missing social record from being treated as a completed empty scan.
- Prevented same-name players from inheriting, displaying, editing, or deleting each other's notes.
- Allowed a mission character observation to supersede an earlier same-session Mourningstar observation.
- Cleared transient caches and world-marker bookkeeping on the appropriate view, game-state, disable, unload, and HUD-destroy paths.
- Validated and sanitized malformed persisted notes, names, aliases, character mappings, and last-seen entries.
- Removed a noted player's last-seen history when their note is deleted.
- Required `/pn_notes_delete_all confirm` before deleting all local PlayerNotes data.
- Corrected Unicode preview truncation, the Mourningstar spelling, inaccurate option copy, and stale localization entries.

## [2.9.0] - 2026-07-29

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
- Gave each world marker an independent payload instead of sharing one mutable table between marker requests.
- Cleared stale world-marker note bookkeeping when players or notes disappear and when the HUD is destroyed.
- Avoided recording the Mourningstar as a player's location while game-mode state is still loading.

## [2.8.0] - 2026-04-15

- Added the note action for applicants in Party Finder.
- Added safeguards around Party Finder note rendering.

## [2.7.4] - 2026-04-14

- Last GitHub-documented release before the Nexus-only 2.8.0 changes.
