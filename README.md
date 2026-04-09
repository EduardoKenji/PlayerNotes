# PlayerNotes

**Persistent notes for your Darktide friends/acquaintances** — add/edit free-text notes on any Steam, Xbox, or PSN friend and see them instantly in the Social panel.

![In-game screenshot](https://github.com/EduardoKenji/PlayerNotes/blob/main/screenshot.png?raw=true)

---

## Features

- **Right-click to annotate** — right-click any friend → **Add Note** / **Edit Note**
- **Inline display** — notes appear directly in every friend row (e.g. `Arthuralo64 · good psyker for havoc 40`)
- **Hover tooltip** — hovering a friend shows the full note in a clean dark overlay
- **Persistent** — notes survive game restarts (saved via DMF `mod:get/set`)
- **Platform-stable keys** — keyed by `platform_user_id` (Steam/Xbox/PSN ID), not display name — survives name changes
- **Offline-friend support** — notes work even when the friend is offline
- **Chat commands** — `/note <text>` to save, `/note_clear` to delete

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
2. Right-click a friend → click **Add Note** (or **Edit Note** if one already exists).
3. Type `/note <your note here>` in chat and press Enter.

```
/note good psyker for havoc 40 runs
```

The button label will update to **Edit Note** and the note appears inline in the friend list row.

### Clearing a note

```
/note_clear
```

Click **Edit Note** on the friend first, then run `/note_clear`.

---

## Commands

| Command | Description |
|---|---|
| `/note <text>` | Save a note for the last right-clicked friend |
| `/note_clear` | Delete the note for the last right-clicked friend |

---

## Compatibility

Tested on the current live version of Darktide. Should be compatible with any mod that does not also hook `ViewElementPlayerSocialPopup._set_player_info` or `SocialMenuRosterView.formatted_character_name`.

---

## License

MIT — see [LICENSE](LICENSE).
