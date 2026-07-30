# Releasing PlayerNotes

Use a `release/<version>` branch and keep `main` protected until the candidate has passed the checks below.

## Prepare

1. Update the version in:
   - `scripts/mods/PlayerNotes/PlayerNotes_data.lua`
   - `scripts/mods/PlayerNotes/PlayerNotes.lua` (header and debug load message)
   - `README.md`
   - `CHANGELOG.md`
2. Run:

   ```powershell
   python .\tools\test_player_notes.py
   .\tools\check_release.ps1 -ExpectedVersion 3.1.0
   git diff --check
   ```

3. Review the complete branch diff and `AUDIT.md`.
4. Confirm all behavior tests run rather than skip. Install development dependencies with `python -m pip install lupa luaparser` when needed.
5. If a Lua compiler is available, also run `luac -p` for every tracked `.lua` file.
6. Synchronize and verify the active development installation:

   ```powershell
   .\tools\sync_active_mod.ps1
   .\tools\sync_active_mod.ps1 -Check
   ```

## In-game smoke test

- Open the Social panel and verify add/edit, inline note/icon, top bar, and tooltip behavior.
- Scroll the Friends list to its bottom and verify both halves of the boundary row and every lower visible row can trigger hover output.
- Verify a 513+ character and a multibyte note are bounded without corrupting text.
- Verify player names outside the Social roster remain undecorated.
- Close a selected-player profile and the Social panel; verify no tooltip remains.
- Open Party Finder and verify an applicant can be selected with the note button.
- Verify the PlayerNotes and Inspect From Party Finder buttons do not overlap.
- In Party Finder browsing, point at a group and hold Show Details (Shift by default); verify all noted members display their wrapped note previews at once without individual hovering.
- Repeat the Show Details check with no-note, one-note, and multi-note groups. Confirm member names remain readable, previews stay inside their cards, release clears the details view, and the option disables/re-enables only this display.
- Remap Show Details or use a controller and verify the group-note display follows the configured action rather than a hard-coded Shift key.
- Enter the Mourningstar and a mission; verify last-seen location, session notification, and world-note cleanup.
- In **2D World Note Appearance**, move Opacity through 0%, 50%, and 100%; verify an existing world note refreshes within one HUD scan and that distance fading still composes with the selected opacity.
- Select Red, Blue, Green, and Yellow; verify the RGB sliders immediately become `(255,0,0)`, `(0,0,255)`, `(0,255,0)`, and `(255,255,0)` respectively and visible notes update.
- Move one RGB slider away from a preset and verify the Color dropdown changes to Custom. Restore an exact preset combination and verify the corresponding named color is selected.
- Reload PlayerNotes and re-open Mod Options; verify the chosen opacity, dropdown value, and RGB channels persist and remain coherent.
- Load 2.8.x/2.9.x settings and verify a platform-keyed note migrates to the same player's account ID without loss.
- Hover a noted cross-network friend while offline and verify their full `name#1234` tag still resolves the tooltip and migrates the legacy key only when unique.
- Disable world-note rendering, target a visible Mourningstar character with `/set_note <character> <text>`, and verify the command resolves without first opening Social.
- For a visible account rendered with a platform glyph, verify plain `/set_note name#1234 <text>` and `/delete_note name#1234` both resolve without copying the glyph.
- If possible, use two test identities with the same visible name and verify neither can see or modify the other's note.
- Run `/pn_notes_delete_all` without an argument and verify no data changes; use `confirm` only with disposable test data.
- Disable and re-enable PlayerNotes while Social/Party Finder is open; verify injected UI becomes inactive and recovers cleanly.
- Toggle each mod option, including the debug load message, and reload the mod once.
- If ModPerformanceMonitor is available, compare Social, Party Finder, and mission costs against 2.8.1.
- Check the Darktide console log for PlayerNotes errors.

## Package and publish

1. Package a single top-level `PlayerNotes` folder containing:
   - `PlayerNotes.mod`
   - `README.md`
   - `AUDIT.md`
   - `CHANGELOG.md`
   - `RELEASING.md`
   - `LICENSE`
   - `scripts/`
2. Install that exact archive into a clean mod directory and repeat the smoke test.
3. Merge the reviewed release branch.
4. Create the signed or annotated tag `v3.1.0` from the merge commit.
5. Publish the same archive and release notes to GitHub Releases and Nexus Mods.
