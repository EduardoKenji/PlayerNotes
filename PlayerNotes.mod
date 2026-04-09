return {
    run = function()
        fassert(rawget(_G, "new_mod"), "`PlayerNotes` encountered an error loading the Darktide Mod Framework.")
        new_mod("PlayerNotes", {
            mod_script       = "PlayerNotes/scripts/mods/PlayerNotes/PlayerNotes",
            mod_data         = "PlayerNotes/scripts/mods/PlayerNotes/PlayerNotes_data",
            mod_localization = "PlayerNotes/scripts/mods/PlayerNotes/PlayerNotes_localization",
        })
    end,
    packages = {},
}
