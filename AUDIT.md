# PlayerNotes 2.10.0 project audit

Audit date: 2026-07-29

Status: implementation complete; in-game release-candidate validation still required

## Scope and method

This review covered:

- The current repository and its history through the 2.9.0 integration branch.
- The Nexus 2.8.0 package and the locally installed 2.8.1 code that were reviewed during the 2.9.0 reconciliation.
- LucLeto's CPU-usage changes.
- All PlayerNotes Lua modules, metadata, options, localization, documentation, and release tooling.
- The locally available Darktide source for `PlayerInfo`, Social roster blueprints, Social popup behavior, Group Finder definitions, world-marker HUD behavior, mission state, and UI rendering.
- The locally available DMF source for hooks, custom HUD elements, settings, and enable/disable/unload lifecycle behavior.

The pass combined static control-flow and lifecycle review, comparison against the game/DMF implementations, Lua parsing, and executable tests with failure-injecting Darktide/DMF doubles.

## Outcome

No evidence showed that LucLeto's changes alone covered the whole risk surface. They substantially reduced CPU work, while the 2.10.0 audit found separate correctness, crash-isolation, persistence-growth, identity, lifecycle, and documentation issues.

The release-candidate changes resolve the actionable high-risk items without attempting a large module split in the same release.

## Resolved findings

| Severity | Area | Finding | 2.10.0 resolution |
|---|---|---|---|
| High | Identity/privacy | Display-name fallback could show or mutate one player's note for a different player with the same visible name. | Note rendering is strictly identity-bound. Ambiguous name commands are rejected. |
| High | Identity/migration | The mod preferred `platform_user_id`, while Darktide's own social model treats `account_id` as the backend identity. | `account_id` is canonical; legacy platform-keyed notes and metadata migrate when both IDs are known. |
| High | UI reliability | Overlay rendering temporarily changed a shared base-UI `start_layer` and could fail before restoring it or ending its pass. | Begin, widget draw, and end operations are isolated; the layer is restored on every handled failure path. |
| High | Persistence growth | Last-seen data was stored for every encountered teammate and had no bound. | Last-seen is recorded only for noted players and removed when their note is deleted. |
| High | HUD reliability | One malformed player, unavailable manager, or marker failure could abort a full scan or repeatedly raise. | Manager/method guards, per-player isolation, cleanup-after-error, and rate-limited reporting were added. |
| High | Notification reliability | Loading-state manager gaps and native notification failures could repeatedly error or silently complete too early. | Notification startup now has readiness checks, bounded retries, protected native dispatch, and one-shot reporting. |
| Medium | Persisted-data safety | Tables loaded from settings were trusted to have the expected shape and value types. | All five persisted structures are top-level validated; entries are sanitized, normalized, or pruned before use. |
| Medium | Memory retention | Session lookup tables retained stale PlayerInfo, roster, Group Finder, character, and identity-index state longer than needed. | Weak-key caches, view/game/HUD cleanup, cooldown-based miss retries, and identity-index rebuilds bound transient retention. |
| Medium | UI allocation/size | Imported or manually edited notes had no bound and could create oversized strings and widgets. | Notes are trimmed and capped at 512 Unicode characters; inline, top-bar, world, and tooltip geometry are independently bounded. |
| Medium | Character mapping | A Mourningstar observation cached in the session could prevent a later mission observation from taking priority. | Session deduplication now tracks context and permits the mission upgrade. |
| Medium | World markers | Marker bookkeeping and payload handling could retain stale note state or couple requests. | Payloads are independent; changed/deleted/departed players are removed; buffers clear on destroy. |
| Medium | Disable/unload | Blueprint mutations survive module disable, so added roster/Party Finder behavior could remain visible without an explicit state gate. | Runtime visibility and decoration honor the enabled state; transient state flushes and clears on disable/unload. |
| Medium | Destructive command | `/pn_notes_delete_all` deleted all user data immediately. | Literal `/pn_notes_delete_all confirm` is required. |
| Low | Unicode correctness | Byte-based preview truncation could split a multibyte player note. | Darktide's `Utf8` helpers are used with a safe fallback for tests. |
| Low | Command cohesion | `/pn_notes` output could group or hide same-name identities and had nondeterministic ordering. | Every identity is listed with its ID in stable name/ID order. |
| Low | Options/docs | Option tooltips were absent, the Mourningstar name was misspelled, stale localization remained, and behavior/version claims disagreed. | Tooltips and copy were corrected, unused keys removed, and all release documentation was reconciled to 2.10.0. |

## Performance and memory assessment

The retained 2.9.0 work addresses the dominant repeated CPU paths:

- Roster-local decoration instead of a global `PlayerInfo.user_display_name` hook.
- Safe post-hooks that do not wrap base draw time.
- Cached scalar settings and positive identity resolutions.
- Rendered-name and Group Finder hover caches keyed by their actual invalidation inputs.
- Two-second HUD scans rather than per-frame player scans.
- Dirty-flagged, batched persistence.
- Per-marker immutable data and one-time geometry.
- Reused HUD scan buffers.

The 2.10.0 pass adds the bounds that were missing:

- Failed identity lookups and platform-only fallbacks are cached only for a one-second cooldown, avoiding permanent loading-state results without causing uncontrolled per-frame native calls.
- Character mappings are capped at 250 and batch-trimmed to 200.
- The auxiliary identity index is rebuilt after eviction/game-state exit so it cannot retain every historical teammate indefinitely.
- Last-seen storage is proportional to current notes.
- Note strings and rendered previews are bounded.
- View, game-state, disable, unload, and HUD-destroy handlers release transient references.

Lua garbage collection does not require explicit deallocation of unreachable tables. The practical leak risks in this mod are reachable caches, native marker registrations, and persisted data growth. Those paths are now either bounded, weak-referenced, explicitly cleared, or tied to user-created notes.

## Architecture assessment

The code has a coherent runtime data flow after this pass:

```text
Social / Party Finder / HUD PlayerInfo
                  |
          canonical identity
        account_id -> platform fallback
                  |
        validated persistence store
          notes / names / mappings
                  |
      roster / hover / notification / marker
```

The principal maintainability debt is that `PlayerNotes.lua` remains a large integration module. Splitting it during a reliability release would produce a broad, difficult-to-review change across load order, hooks, and closure-owned state. The safer next phase is:

1. Extract `player_notes_store.lua`: validation, dirty flags, limits, migrations, and flush.
2. Extract `player_notes_identity.lua`: PlayerInfo resolution, legacy-ID migration, names, and character aliases.
3. Extract `player_notes_overlay.lua`: hover state, widget definitions, and protected rendering.
4. Extract `player_notes_social.lua` and `player_notes_group_finder.lua`: view-specific adapters.
5. Keep `PlayerNotes.lua` as composition root, commands, settings refresh, and lifecycle.

Each extraction should preserve the internal API currently consumed by `hud_element_player_notes.lua` and land separately with behavior tests.

## Residual risks and actionable follow-ups

| Priority | Risk/gap | Recommended action |
|---|---|---|
| P1 before release | The automated harness cannot reproduce Stingray rendering, input navigation, actual Social/Party Finder data timing, or DMF serialization. | Complete every in-game scenario in `RELEASING.md` against the packaged archive and inspect the console log. |
| P1 after Darktide updates | PlayerNotes hooks private game view blueprints and methods that Fatshark may rename or reshape. | Re-run syntax/behavior checks, then the full Social, Party Finder, HUD, and lifecycle smoke matrix after each major patch. |
| P2 | The main module is large and mixes persistence, identity, UI, commands, and lifecycle. | Apply the staged module extraction above in 2.11.x; do not combine it with feature work. |
| P2 | Character names are not unique; the single best mapping remains heuristic even with mission priority and recency. | Consider storing multiple candidate identities per character name and requiring disambiguation when candidates conflict. |
| P2 | All user-facing localization is English-only. | Add locale contributions after stable English keys are finalized. |
| P2 | Tests currently run locally but are not enforced by continuous integration. | Add a minimal CI job for `tools/test_player_notes.py`, version consistency, and `git diff --check`. |
| P3 | Hover placement uses manual geometry because the offscreen Social roster does not expose reliable hotspot hover state. | Re-evaluate if Fatshark exposes a stable roster selection/hover event in a future update. |
| P3 | World notes during missions can add combat-screen clutter even with the 15 m limit. | Keep the option off by default and collect player feedback before promoting it from experimental. |

## Verification performed

- Parsed every tracked Lua file with `luaparser`.
- Executed nine behavior tests through Lupa:
  - Platform-key to account-key migration across all persisted structures.
  - Loading-state platform fallback upgrading to account identity after its cooldown.
  - Malformed persisted entry normalization and pruning.
  - No display-name note fallback.
  - Note size bound and last-seen deletion.
  - Destructive-command confirmation.
  - Session-notification local-player exclusion and bot handling.
  - Overlay layer/pass cleanup after an injected widget-draw failure.
  - Continued HUD player processing and persistence after one marker request fails.
- Validated every localization key referenced by code and option metadata.
- Compared identity order, hook behavior, marker callback behavior, and lifecycle assumptions against the local Darktide and DMF sources.

Run the checks with:

```powershell
python .\tools\test_player_notes.py
.\tools\check_release.ps1 -ExpectedVersion 2.10.0
git diff --check
```
