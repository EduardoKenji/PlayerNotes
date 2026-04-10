-- world_marker_template_pn_note.lua
-- World marker template that displays a player's note to the RIGHT of their
-- nameplate. Registered into HudElementWorldMarkers._marker_templates via
-- hook_safe on init. Triggered by HudElementPlayerNotes for players with notes.
--
-- Positioning:
--   The world marker system sets widget.offset = projected_screen_position each
--   frame, then calls update_function. We shift offset[1] right by:
--     200 * marker.scale  →  past the nameplate right edge (nameplate = 400 UI
--                             units wide, centered → half = 200)
--     + 15                →  small visual gap
--   This keeps the note aligned to the nameplate regardless of distance-based scale.

local UIWidget = require("scripts/managers/ui/ui_widget")

local template = {}

template.name              = "pn_note"
template.unit_node         = "j_head"
template.position_offset   = { 0, 0, 0.4 }   -- same anchor as standard nameplate
template.check_line_of_sight = false           -- skip raycast for performance
template.max_distance      = 100              -- visible at hub range (100m)
template.screen_clamp      = false
template.start_layer       = 302              -- above nameplate layer (300)

template.scale_settings = {
    distance_max = 20,
    distance_min = 10,
    scale_from   = 0.8,
    scale_to     = 1,
}

template.fade_settings = {
    default_fade    = 1,
    fade_from       = 0,
    fade_to         = 1,
    distance_max    = 100,
    distance_min    = 50,
    easing_function = math.ease_exp,
}

local _size = { 500, 24 }
template.size = _size

-- Note: the game source spells this "defintion" (typo) — match exactly.
template.create_widget_defintion = function(tmpl, scenegraph_id)
    return UIWidget.create_definition({
        {
            pass_type = "text",
            style_id  = "pn_note_text",
            value_id  = "pn_note_text",
            value     = "",
            style     = {
                horizontal_alignment      = "left",
                text_horizontal_alignment = "left",
                text_vertical_alignment   = "center",
                vertical_alignment        = "center",
                offset                    = { 0, 0, 2 },
                font_type                 = "proxima_nova_bold",
                font_size                 = 18,
                default_font_size         = 18,
                text_color                = { 255, 220, 200, 150 },
                size                      = _size,
            },
        },
    }, scenegraph_id)
end

template.on_enter = function(widget, marker)
    local data = marker.data
    widget.content.pn_note_text = (data and data.note) or ""
end

template.on_exit = function(widget, marker)
    -- nothing to clean up
end

-- Called each frame after widget.offset is set from the 3D projection.
-- Shifts the widget right so it appears beside the nameplate, not on top of it.
template.update_function = function(parent, ui_renderer, widget, marker, tmpl, dt, t)
    widget.offset[1] = widget.offset[1] + (200 * marker.scale + 15)
end

return template
