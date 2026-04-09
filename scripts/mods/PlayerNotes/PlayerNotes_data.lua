local mod = get_mod("PlayerNotes")

return {
    name         = mod:localize("mod_title"),
    description  = mod:localize("mod_description"),
    version      = "1.9.0",
    is_togglable = true,
    options = {
        widgets = {
            {
                setting_id    = "show_inline",
                type          = "checkbox",
                default_value = true,
                title         = mod:localize("opt_show_inline_title"),
                tooltip       = mod:localize("opt_show_inline_tooltip"),
            },
            {
                setting_id    = "show_top_bar",
                type          = "checkbox",
                default_value = true,
                title         = mod:localize("opt_show_top_bar_title"),
                tooltip       = mod:localize("opt_show_top_bar_tooltip"),
            },
            {
                setting_id    = "show_tooltip",
                type          = "checkbox",
                default_value = true,
                title         = mod:localize("opt_show_tooltip_title"),
                tooltip       = mod:localize("opt_show_tooltip_tooltip"),
            },
        },
    },
}
