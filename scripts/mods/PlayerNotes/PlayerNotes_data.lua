return {
    name         = "PlayerNotes",
    description  = "Add persistent notes to players and see them in Social, Party Finder, and the game world.",
    version      = "3.0.0",
    is_togglable = true,
    options = {
        widgets = {
            {
                setting_id    = "show_inline",
                type          = "checkbox",
                default_value = false,
                title         = "opt_show_inline_title",
                tooltip       = "opt_show_inline_title_description",
            },
            {
                setting_id    = "show_top_bar",
                type          = "checkbox",
                default_value = true,
                title         = "opt_show_top_bar_title",
                tooltip       = "opt_show_top_bar_title_description",
            },
            {
                setting_id    = "show_tooltip",
                type          = "checkbox",
                default_value = true,
                title         = "opt_show_tooltip_title",
                tooltip       = "opt_show_tooltip_title_description",
            },
            {
                setting_id    = "show_party_finder_notes",
                type          = "checkbox",
                default_value = true,
                title         = "opt_show_party_finder_notes_title",
                tooltip       = "opt_show_party_finder_notes_title_description",
            },
            {
                setting_id    = "show_world_notes",
                type          = "checkbox",
                default_value = true,
                title         = "opt_show_world_notes_title",
                tooltip       = "opt_show_world_notes_title_description",
            },
            {
                setting_id  = "experimental_group",
                type        = "group",
                title       = "opt_experimental_group_title",
                tooltip     = "opt_experimental_group_title_description",
                sub_widgets = {
                    {
                        setting_id    = "show_world_notes_in_missions",
                        type          = "checkbox",
                        default_value = false,
                        title         = "opt_show_world_notes_in_missions_title",
                        tooltip       = "opt_show_world_notes_in_missions_title_description",
                    },
                    {
                        setting_id    = "show_session_notifications",
                        type          = "checkbox",
                        default_value = true,
                        title         = "opt_show_session_notifications_title",
                        tooltip       = "opt_show_session_notifications_title_description",
                    },
                    {
                        setting_id    = "enable_debug_echo",
                        type          = "checkbox",
                        default_value = false,
                        title         = "opt_debug_echo_title",
                        tooltip       = "opt_debug_echo_title_description",
                    },
                },
            },
        },
    },
}

