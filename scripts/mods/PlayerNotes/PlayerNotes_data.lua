return {
    name         = "PlayerNotes",
    description  = "Add persistent notes to any player in the Social panel or Party Finder. Hover a player to see their note.",
    version      = "1.9.3",
    is_togglable = true,
    options = {
        widgets = {
            {
                setting_id    = "show_inline",
                type          = "checkbox",
                default_value = false,
                title         = "opt_show_inline_title",
            },
            {
                setting_id    = "show_top_bar",
                type          = "checkbox",
                default_value = true,
                title         = "opt_show_top_bar_title",
            },
            {
                setting_id    = "show_tooltip",
                type          = "checkbox",
                default_value = true,
                title         = "opt_show_tooltip_title",
            },
        },
    },
}
