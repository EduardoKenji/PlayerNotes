return {
    mod_title = {
        en = "PlayerNotes",
    },
    mod_description = {
        en = "Add persistent notes to players and see them in Social, Party Finder, and the game world.",
    },

    -- Social popup buttons
    btn_add_note = {
        en = "Add Note",
    },
    -- Echo messages
    echo_selected = {
        en = "Selected %s — type /note [text] to save.",
    },
    echo_saved = {
        en = "Note saved for %s.",
    },
    echo_none_selected = {
        en = "Click Add Note or Edit Note on a player first.",
    },
    echo_usage_note = {
        en = "Usage: /note [your note text]",
    },
    -- Mod options titles
    opt_show_inline_title = {
        en = "Show inline note text in Social roster",
    },
    opt_show_inline_title_description = {
        en = "Appends a short note preview next to the player name. When disabled, a small note indicator icon is shown instead.",
    },

    opt_show_top_bar_title = {
        en = "Show note in top-left bar",
    },
    opt_show_top_bar_title_description = {
        en = "Shows the player's last-seen information, or a note preview when no history exists, in a top-left bar while hovering.",
    },

    opt_show_tooltip_title = {
        en = "Show floating tooltip on hover",
    },
    opt_show_tooltip_title_description = {
        en = "Shows the full note in a floating tooltip next to the hovered player row.",
    },

    opt_show_party_finder_notes_title = {
        en = "Show group notes in Party Finder details",
    },
    opt_show_party_finder_notes_title_description = {
        en = "While holding Show Details (Shift by default), shows every saved player note directly on that group's member cards.",
    },

    opt_show_world_notes_title = {
        en = "Show note above player head",
    },
    opt_show_world_notes_title_description = {
        en = "Shows the player's note above their nameplate in the game world. Active in the Mourningstar hub; use the option below to also enable it in missions.",
    },

    opt_world_note_appearance_group_title = {
        en = "2D World Note Appearance",
    },
    opt_world_note_appearance_group_title_description = {
        en = "Controls the opacity and text/accent color of notes rendered above player heads.",
    },
    opt_world_note_opacity_title = {
        en = "Opacity",
    },
    opt_world_note_opacity_title_description = {
        en = "Sets the overall opacity of the 2D world-note box, border, and text from 0 to 100 percent.",
    },
    opt_world_note_color_preset_title = {
        en = "Color",
    },
    opt_world_note_color_preset_title_description = {
        en = "Selects a color preset and updates all three RGB sliders. Moving an RGB slider selects the matching preset or Custom.",
    },
    opt_world_note_color_custom = {
        en = "Custom",
    },
    opt_world_note_color_red = {
        en = "Red",
    },
    opt_world_note_color_blue = {
        en = "Blue",
    },
    opt_world_note_color_green = {
        en = "Green",
    },
    opt_world_note_color_yellow = {
        en = "Yellow",
    },
    opt_world_note_color_red_title = {
        en = "Red (RGB)",
    },
    opt_world_note_color_red_title_description = {
        en = "Sets the red channel from 0 to 255.",
    },
    opt_world_note_color_green_title = {
        en = "Green (RGB)",
    },
    opt_world_note_color_green_title_description = {
        en = "Sets the green channel from 0 to 255.",
    },
    opt_world_note_color_blue_title = {
        en = "Blue (RGB)",
    },
    opt_world_note_color_blue_title_description = {
        en = "Sets the blue channel from 0 to 255.",
    },

    opt_experimental_group_title = {
        en = "Experimental",
    },
    opt_experimental_group_title_description = {
        en = "Optional features whose visibility or usefulness depends on the current game mode.",
    },

    opt_show_world_notes_in_missions_title = {
        en = "Show 2D world notes in missions",
    },
    opt_show_world_notes_in_missions_title_description = {
        en = "Also shows notes above player heads during missions. Disabled by default to avoid cluttering the screen during combat. Requires 'Show note above player head' to be enabled.",
    },
    opt_show_session_notifications_title = {
        en = "Notify when noted players are present",
    },
    opt_show_session_notifications_title_description = {
        en = "Displays a notification in the top-right when entering a map if noted players are present.",
    },
    opt_debug_echo_title = {
        en = "Enable debug mod:echo",
    },
    opt_debug_echo_title_description = {
        en = "Displays the PlayerNotes version and command summary after all mods load.",
    },
}
