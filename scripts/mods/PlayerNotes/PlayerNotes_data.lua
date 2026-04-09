return {
    name         = "PlayerNotes",
    description  = "Add persistent notes to any player in the Social panel or Party Finder. Hover a player to see their note.",
    version      = "1.9.0",
    is_togglable = true,
    options = {
        widgets = {
            {
                setting_id    = "show_inline",
                type          = "checkbox",
                default_value = true,
                title         = "Display note within player's rectangle",
                tooltip       = "Appends a short note preview next to the player name in the friend list row.",
            },
            {
                setting_id    = "show_top_bar",
                type          = "checkbox",
                default_value = true,
                title         = "Display note in the top left",
                tooltip       = "Shows 'Name - note' in a bar at the top-left of the screen when hovering a player with a note.",
            },
            {
                setting_id    = "show_tooltip",
                type          = "checkbox",
                default_value = true,
                title         = "Display note in tooltip",
                tooltip       = "Shows the full note in a floating tooltip next to the hovered player row.",
            },
        },
    },
}
