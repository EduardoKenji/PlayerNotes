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
   .\tools\check_release.ps1 -ExpectedVersion 2.9.0
   ```

3. Review `git diff --check` and the complete branch diff.
4. If a Lua compiler is available, run `luac -p` for every tracked `.lua` file.

## In-game smoke test

- Open the Social panel and verify add/edit, inline note/icon, top bar, and tooltip behavior.
- Verify player names outside the Social roster remain undecorated.
- Close a selected-player profile and the Social panel; verify no tooltip remains.
- Open Party Finder and verify an applicant can be selected with the note button.
- Verify the PlayerNotes and Inspect From Party Finder buttons do not overlap.
- Enter the Mourningstar and a mission; verify last-seen location, session notification, and world-note cleanup.
- Toggle each mod option, including the debug load message, and reload the mod once.
- If ModPerformanceMonitor is available, compare Social, Party Finder, and mission costs against 2.8.1.
- Check the Darktide console log for PlayerNotes errors.

## Package and publish

1. Package a single top-level `PlayerNotes` folder containing:
   - `PlayerNotes.mod`
   - `README.md`
   - `CHANGELOG.md`
   - `LICENSE`
   - `scripts/`
2. Install that exact archive into a clean mod directory and repeat the smoke test.
3. Merge the reviewed release branch.
4. Create the signed or annotated tag `v2.9.0` from the merge commit.
5. Publish the same archive and release notes to GitHub Releases and Nexus Mods.
