# PlayerNotes v2.8.0

**Persistent notes for your Darktide friends/acquaintances** — add/edit free-text notes on any Steam, Xbox, or PSN friend and see them instantly in the Social panel, Party Finder, and in-world above player nameplates.

---

## Features

- **Right-click to annotate** — right-click any friend → **Add Note** / **Edit Note**.
- **Three display modes** (all independently togglable via F4 Mod Options):
  - **Inline notes** — append note preview directly to friend name (e.g. `Arthuralo64 · good psyker for havoc 40`).
  - **Top-bar** — shows "Name — note" in a small bar at top-left when hovering. **Now includes "Last Seen" data (Location, Difficulty, and Timestamp).**
  - **Tooltip** — floating box near the hovered player row, dynamically sized to fit the text.
- **Last-Seen Tracking** — Automatically records where and when you last encountered a player, including mission name and difficulty (e.g., *Havoc 40, Auric, or Auric Maelstrom*).
- **Session Notifications** — Get a native game notification upon entering a map if players with saved notes are present in your current session.
- **World notes** — Stylized note boxes appear above player nameplates in-game (within ~15m range).
- **Party Finder support** — Hover tooltips work for join requesters in Group Finder.
- **Persistent** — Notes and location history survive game restarts.
- **Platform-stable keys** — Keyed by `platform_user_id` (Steam/Xbox/PSN ID) with fallback to `account_id` for cross-platform offline friends.
- **Performance Optimized** — Implements LRU (Least Recently Used) caching for character mappings and table reuse to minimize RAM churn and Garbage Collection (GC) spikes.

---

## Requirements

- [Darktide Mod Loader (DML)](https://www.nexusmods.com/warhammer40kdarktide/mods/19)
- [Darktide Mod Framework (DMF)](https://www.nexusmods.com/warhammer40kdarktide/mods/8)

---

## Installation

1. Install **DML** and **DMF** (see links above) if you haven't already.
2. Download the [latest release](https://github.com/EduardoKenji/PlayerNotes/releases/latest).
3. Extract the `PlayerNotes` folder into your Darktide mods directory:
   ```
   Steam\steamapps\common\Warhammer 40,000 DARKTIDE\mods\PlayerNotes\
   ```
4. Run `toggle_darktide_mods.bat` in the game root if prompted after a game update.
5. Launch Darktide — enable **PlayerNotes** in the DMF mod list.

---

## Usage

### Adding or editing a note

1. Open the **Social** panel.
2. Right-click a friend → click **Add Note** (or shows `[Note] preview...` if one exists).
3. Type `/note <your note here>` in chat and press Enter.

```
/note good psyker for havoc 40 runs
```

### Setting a note by player tag or character name

You can also set a note directly without going through the Social panel:

```
/set_note <player_tag_or_character_name> <note text>
/set_note Potty#1031 great psyker for havoc 40
/set_note KimJongDois great psyker for havoc 40
```

The identifier can be a platform player tag (e.g. `Potty#1031`) or a character name seen in a mission or the Social panel.

### Deleting a note

```
/delete_note <player_tag_or_character_name>
/delete_note Potty#1031
/delete_note KimJongDois
```

### Listing all notes

```
/pn_notes
```

Shows all saved notes with player names (if cached) or their platform IDs.

### Listing character-name mappings

```
/pn_chars
```

Shows all known character name → player tag mappings. These are recorded automatically when you see a player in a mission or the Social panel.

### Deleting all notes

```
/pn_notes_delete_all
```

Wipes ALL saved notes and the name cache. Use with caution!

### Mod Options (F4 in-game)

Navigate to **PlayerNotes** in the mod options menu to toggle:

- **Show inline notes** — append note preview to friend names.
- **Show top bar** — shows "Name — Last seen in [Location] at [Date], [Time ago]" when hovering.
- **Show tooltip** — floating tooltip box near hovered player.
- **Show world notes** — notes above player nameplates in hub/lobby.

**Experimental options:**

- **Show 2D world notes in missions** — also show notes above nameplates during missions (disabled by default to reduce clutter).
- **Show session notifications** — display a notification in the top-right when entering a map if noted players are present.

---

## Commands

| Command | Description |
|---|---|
| `/note <text>` | Save a note for the last selected player (via Social panel) |
| `/set_note <tag_or_char> <text>` | Save a note by player tag or character name |
| `/delete_note <tag_or_char>` | Delete a note by player tag or character name |
| `/pn_notes` | List all saved notes with player names/IDs |
| `/pn_chars` | List known character name → player tag mappings |
| `/pn_notes_delete_all` | Wipe ALL notes and name cache (use with caution) |

---

## Compatibility

Tested on the current live version of Darktide. Should be compatible with most mods.

**Hooks used:**
- `PlayerInfo.user_display_name` — for inline note display
- `ViewElementPlayerSocialPopup._set_player_info` — for right-click menu injection
- `SocialMenuRosterView._draw_widgets` — for hover detection in Social panel
- `GroupFinderView._draw_widgets` — for Party Finder hover tooltips
- `UIConstantElements.draw` — for overlay rendering (tooltip + top-bar)
- `HudElementWorldMarkers.init` — for world note template injection

---

## License

MIT — see [LICENSE](LICENSE).