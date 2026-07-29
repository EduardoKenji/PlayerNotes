# PlayerNotes v3.0.0

PlayerNotes adds private, persistent notes to players you encounter in Warhammer 40,000: Darktide. Notes can be created from the Social panel or Party Finder and shown in the roster, Party Finder group details, on hover, or above nearby players.

Version 3.0.0 adds at-a-glance notes for every saved player in a Party Finder group while Show Details is held. It retains the reliability, identity, and performance work completed for 2.10.0.

## Features

- Add or edit a note from a player's Social-panel menu.
- Select a Party Finder applicant from the note button on their request card.
- Hold Party Finder's **Show Details** action (**Shift** by default) to display saved notes on all visible member cards without hovering each player.
- Show a short note preview beside a Social-roster name. When inline text is disabled, a compact note icon is shown instead.
- Show the full note in a floating hover tooltip.
- Show a top-left hover bar. It displays last-seen information when available and otherwise displays a bounded note preview.
- Show note boxes above nearby players in the Mourningstar, with optional mission support.
- Notify once after entering a map when a player with a saved note is present.
- Record where and when a noted player was last encountered.
- Resolve `/set_note` and `/delete_note` by a uniquely mapped player tag or a recently observed character name.

Notes are stored only in the local DMF settings. PlayerNotes does not upload or share them.

## Requirements

- [Darktide Mod Loader (DML)](https://www.nexusmods.com/warhammer40kdarktide/mods/19)
- [Darktide Mod Framework (DMF)](https://www.nexusmods.com/warhammer40kdarktide/mods/8)

## Installation

1. Install DML and DMF.
2. Download a PlayerNotes release.
3. Extract the single top-level `PlayerNotes` folder into the Darktide `mods` directory. A typical Steam path is:

   ```text
   Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods\PlayerNotes\
   ```

4. Add `PlayerNotes` to `mod_load_order.txt` if your mod manager does not do so.
5. Run `toggle_darktide_mods.bat` again after a game update when DML requests it.

## Upgrading from 2.8.x, 2.9.x, or 2.10.x

Existing notes and caches are reused. Since 2.10.0, PlayerNotes treats Darktide's `account_id` as the canonical player identity. When an older `platform_user_id` and its corresponding account ID are both available, the stored note and related metadata are migrated automatically. Cross-network offline friends may temporarily hide the older platform ID; when their full `name#1234` tag has exactly one stored identity, PlayerNotes uses that unique tag once to migrate the legacy data to the visible account ID. Plain or ambiguous names are never migrated this way.

Display names are never used as note identities. If two people have the same visible name, their notes remain separate.

As with any mod update, keeping a backup of your DMF settings before replacing the folder is sensible.

## Usage

### Social panel

1. Open the Social panel.
2. Open another player's context menu and choose **Add Note**, or choose the existing `[Note]` entry.
3. Enter the note in chat:

   ```text
   /note good psyker for havoc 40
   ```

### Party Finder

To review a group before joining:

1. Open Party Finder and point at a group.
2. Hold **Show Details** (**Shift** by default).
3. Saved notes appear together on the right side of the corresponding member cards. Notes wrap across a few lines and long notes use a bounded preview.

To create or edit a note for someone requesting to join your group:

1. View incoming player requests.
2. Select the note button on an applicant's request card.
3. Enter `/note <text>` in chat.

The applicant note button is positioned to coexist with the button added by Inspect From Party Finder. The group-note display follows Darktide's configurable Show Details action, so remapped keyboard and controller bindings continue to work.

### Direct commands

```text
/set_note <player_tag_or_character_name> <note text>
/delete_note <player_tag_or_character_name>
/pn_notes
/pn_chars
/pn_notes_delete_all confirm
```

Examples:

```text
/set_note Potty#1031 dependable veteran
/set_note KimJongDois good team player
/delete_note Potty#1031
```

Mapped player tags may contain spaces, but they must resolve to one stored identity. Darktide's visual platform and favorite glyphs are removed before a tag is stored or compared, so chat commands use the plain form such as `Shark#7571`. If the same display name maps to multiple player identities, PlayerNotes refuses the command and asks you to select the intended player in Social or Party Finder. Character-name mappings are observational heuristics: mission observations take priority over Mourningstar observations, but character names are not globally unique.

When `/set_note` or `/delete_note` cannot resolve a cached name, it refreshes character and account-tag mappings from the currently visible player list and retries immediately. This works even if world-note rendering is disabled or the Social service has not finished loading that player's profile.

Notes are trimmed and limited to 512 Unicode characters. The inline, top-bar, and world displays use shorter previews; the hover tooltip retains the full saved note.

`/pn_notes_delete_all` is intentionally non-destructive without the literal `confirm` argument. The confirmed command deletes all notes, names, character mappings, and last-seen history.

## Mod options

Open **F4 → Mod Options → PlayerNotes**.

- **Show inline note text in Social roster**: show a short text preview. When off, noted players still receive a compact icon.
- **Show note in top-left bar**: show last-seen information or a note preview while hovering.
- **Show floating tooltip on hover**: show the full note beside the hovered row.
- **Show group notes in Party Finder details**: while Show Details is held, show every saved note directly on the matching group-member card.
- **Show note above player head**: show nearby note boxes in the Mourningstar.
- **Show 2D world notes in missions**: extend world notes into missions; off by default.
- **Notify when noted players are present**: show one native notification after entering a map.
- **Enable debug mod:echo**: print the loaded version and command summary after all mods load.

## Identity and persistence

- Canonical key: Darktide `account_id`.
- Compatibility key: `platform_user_id`, used only when no account ID is available and migrated when both become known or when a unique discriminated cross-network tag safely links the legacy key to the canonical account ID.
- Display names: labels and unique command aliases only, never authoritative note keys.
- Last-seen history: stored only for players who currently have notes.
- Character mappings: bounded to 250 entries and batch-trimmed to 200 using recency and mission-context preference.
- Empty persisted tables are removed instead of serialized.

Deleting one note also removes that player's last-seen entry. Name and character mappings remain available for future direct commands until evicted or cleared.

## Performance and reliability

The 3.0.0 code retains the 2.10.0 defensive bounds and 2.9.0 hot-path optimizations:

- Social names are decorated only in the Social-roster blueprint; `PlayerInfo.user_display_name` is not globally hooked.
- Social hover uses each rendered widget's real bounds rather than imposing a fixed nominal bottom on scrolled rows.
- Scalar settings, resolved identities, rendered names, hover text, Group Finder identities, and overlay scale are cached.
- Party Finder group-note identities and previews are resolved when preview rows are created or saved notes change; their render passes reuse cached text.
- Identity misses and platform-only fallbacks retry after a cooldown so loading-state results do not become permanent.
- Persisted table reads are cached; writes are dirty-flagged and batched.
- HUD identity and last-seen scans run every two seconds and reuse marker/seen tables; marker creation remains independently controlled by the world-note options.
- Each player scan is isolated so one malformed player or marker request does not prevent cleanup or processing of the others.
- Last-seen data grows with saved notes, not with every teammate ever encountered.
- Character mappings and transient identity sets are bounded or rebuilt.
- Note and widget sizes are capped.
- Overlay rendering restores the base UI's shared layer setting even when begin, draw, or end operations fail.
- Notification initialization has bounded retries instead of retrying forever.
- Disable, unload, view-exit, and HUD-destroy paths release transient references and marker bookkeeping.

No classic unreachable-reference leak was found in the audited paths. The main memory risks were retained lookup tables and unconstrained persisted data; both are now bounded or tied to user-owned notes.

## Compatibility

PlayerNotes integrates with these Darktide/DMF surfaces:

- `social_menu_roster_view_blueprints`
- `ViewElementPlayerSocialPopup._set_player_info`
- `SocialMenuRosterView.init`, `_draw_widgets`, and `on_exit`
- `GroupFinderView._draw_widgets` and `on_exit`
- `group_finder_view_definitions.player_request_entry`
- `UIConstantElements.draw`
- `HudElementWorldMarkers.init`
- DMF custom HUD-element registration and lifecycle callbacks

These are game implementation details and may change after a Darktide update. See [AUDIT.md](AUDIT.md) for the completed review, residual risks, and the proposed architectural follow-up.

## Development and release validation

Run the repository checks from its root:

```powershell
python .\tools\test_player_notes.py
.\tools\check_release.ps1 -ExpectedVersion 3.0.0
git diff --check
```

The Python suite uses `lupa` for Lua behavior tests and `luaparser` for syntax validation:

```powershell
python -m pip install lupa luaparser
```

Automated tests complement, but cannot replace, the in-game matrix in [RELEASING.md](RELEASING.md).

### Synchronizing the active mod

The repository and Darktide's active `mods\PlayerNotes` directory are separate working trees; Git commits do not synchronize them automatically. From the canonical repository root, deploy and verify every tracked file with:

```powershell
.\tools\sync_active_mod.ps1
.\tools\sync_active_mod.ps1 -Check
```

The default destination matches this repository's development layout. Pass `-Destination <path-to-mods\PlayerNotes>` when using another layout. The command never modifies `.git`, ignores Python bytecode caches, and fails if tracked files differ or unexpected payload files require review.

## Credits

- EduardoKenji: original mod and maintenance.
- LucLeto: CPU-usage reduction work integrated in 2.9.0 and retained in 3.0.0.

## License

MIT — see [LICENSE](LICENSE).
