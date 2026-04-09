return {
    en = {
        mod_title       = "PlayerNotes",
        mod_description = "Add persistent notes to any player in the Social panel or Party Finder. Hover a player to see their note.",

        -- Social popup buttons
        btn_add_note    = "Add Note",
        btn_edit_note   = "Edit Note",

        -- Echo messages
        echo_selected           = "Selected %s - click Add/Edit Note, then type /note [your text]",
        echo_saved              = "Note saved for %s.",
        echo_cleared            = "Note cleared for %s.",
        echo_none_selected      = "Click Add Note or Edit Note on a player first.",
        echo_usage_note         = "Usage: /note [your note text]",
        echo_usage_note_clear   = "Usage: /note_clear",

        -- Command descriptions
        cmd_note_desc       = "Save a note for the last selected player.",
        cmd_note_clear_desc = "Clear the note for the last selected player.",

        -- Mod options
        opt_show_inline_title   = "Display note within player's rectangle",
        opt_show_inline_tooltip = "Appends a short note preview next to the player name in the friend list row.",

        opt_show_top_bar_title   = "Display note in the top left",
        opt_show_top_bar_tooltip = "Shows 'Name — note' in a bar at the top-left of the screen when hovering a player with a note.",

        opt_show_tooltip_title   = "Display note in tooltips",
        opt_show_tooltip_tooltip = "Shows the full note in a floating tooltip next to the hovered player row.",
    },
}
