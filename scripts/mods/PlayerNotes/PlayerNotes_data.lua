return {
    name         = "PlayerNotes",
    description  = "Add persistent notes to any player in the Social panel or Party Finder. Hover a player to see their note.",
    version      = "2.7.4",
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
            {
                setting_id    = "show_world_notes",
                type          = "checkbox",
                default_value = true,
                title         = "opt_show_world_notes_title",
            },
            {
                setting_id  = "experimental_group",
                type        = "group",
                title       = "opt_experimental_group_title",
                sub_widgets = {
                    {
                        setting_id    = "show_world_notes_in_missions",
                        type          = "checkbox",
                        default_value = false,
                        title         = "opt_show_world_notes_in_missions_title",
                    },
                    {
                        setting_id    = "show_session_notifications",
                        type          = "checkbox",
                        default_value = true,
                        title         = "opt_show_session_notifications_title",
                    },
                    {
                        setting_id    = "enable_debug_echo",
                        type          = "checkbox",
                        default_value = false,
                        title         = "opt_debug_echo_title",
                    },
                },
            },
        },
    },
}

