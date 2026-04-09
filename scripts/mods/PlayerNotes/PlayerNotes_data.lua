local mod = get_mod("PlayerNotes")

return {
    name        = mod:localize("mod_title"),
    description = mod:localize("mod_description"),
    version     = "1.8.0",
    is_togglable = true,
    options = {
        widgets = {
            -- No configurable options for v1.x.
            -- Future: note font size, tooltip position offset, etc.
        },
    },
}
