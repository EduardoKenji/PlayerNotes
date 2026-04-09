--[[
    PlayerNotes
    Author: Eduardo
    Version: 1.8.0

    Add persistent notes to any player visible in the Social panel or Party Finder.
    Three simultaneous display mechanisms:

    1. Inline note (Alternative 1) — hook PlayerInfo.user_display_name to append
       " · <note>" to the account_name line. Confirmed working.

    2. Top-of-screen text (Alternative 2) — when hovering a player with a note,
       show "<name> — <note>" in a small bar at the top of the screen. Uses the
       UIConstantElements overlay renderer (drawn above ALL views after view_handler).

    3. Hover tooltip (Alternative 3) — floating box near the hovered player row.
       Same renderer as Alternative 2.

    Why UIConstantElements renderer works:
      UIManager.render() call order:
        1. view_handler:draw()           — SocialMenuRosterView and all UI views
        2. ui_constant_elements:draw()   — overlay viewport (type="overlay"), drawn
                                          on top of ALL views (chat box, popups, etc.)
        3. hud:draw()
      We hook UIConstantElements.draw (CLASS.UIConstantElements) and inject our own
      begin_pass/UIWidget.draw/end_pass after func() runs. The overlay viewport
      composites on top of the social panel.

    Hover detection:
      SocialMenuRosterView._draw_widgets is used ONLY to detect which player is
      hovered (geometric bounds check — hotspot.is_hover never works for offscreen-
      rendered roster widgets). Detected state stored in mod._hovered_note etc.
      UIConstantElements.draw hook reads that state and draws.

    Usage:
      1. Open Social panel, right-click a player → click "Add Note".
      2. Type  /note good psyker for havoc 40  in chat → Enter.
      3. Note appears inline, at top of screen on hover, and as tooltip on hover.
--]]

local mod = get_mod("PlayerNotes")

-- ──────────────────────────────────────────────────────────────────────────────
-- DEPENDENCIES
-- ──────────────────────────────────────────────────────────────────────────────

local UISoundEvents       = require("scripts/settings/ui/ui_sound_events")
local UIWidget            = require("scripts/managers/ui/ui_widget")
local UIRenderer          = require("scripts/managers/ui/ui_renderer")
local UIScenegraph        = require("scripts/managers/ui/ui_scenegraph")
local UIWorkspaceSettings = require("scripts/settings/ui/ui_workspace_settings")

-- ──────────────────────────────────────────────────────────────────────────────
-- CONSTANTS
-- ──────────────────────────────────────────────────────────────────────────────

local STR_BTN_ADD    = "Add Note"
local STR_SELECTED   = "Selected %s — type /note [text] to save, /note_clear to remove."
local STR_SAVED      = "Note saved for %s."
local STR_CLEARED    = "Note cleared for %s."
local STR_NONE_SEL   = "Click 'Add Note' on a player first."
local STR_USAGE_NOTE = "Usage: /note [your note text]"

-- Tooltip dimensions (Alternative 3)
local TT_W   = 340
local TT_H   = 130
local TT_PAD = 10
local TT_Z   = 997

-- Top-text bar dimensions (Alternative 2)
local A2_W   = 600
local A2_H   = 34
local A2_X   = 30    -- left edge
local A2_Y   = 20    -- top of screen

-- ──────────────────────────────────────────────────────────────────────────────
-- PERSISTENCE
-- ──────────────────────────────────────────────────────────────────────────────

local function get_notes()
    return mod:get("player_notes") or {}
end

local function save_note(puid, text)
    local notes = get_notes()
    notes[puid] = (text and text ~= "") and text or nil
    mod:set("player_notes", notes)
end

local function get_note(puid)
    if not puid or puid == "" then return nil end
    return get_notes()[puid]
end

-- ──────────────────────────────────────────────────────────────────────────────
-- HOVER STATE  (written by _draw_widgets hook, read by UIConstantElements hook)
-- ──────────────────────────────────────────────────────────────────────────────

mod._popup_puid           = nil
mod._editing_puid         = nil
mod._editing_name         = nil
-- Hover state (nil when not hovering a player with a note)
mod._hovered_note         = nil   -- note text
mod._hovered_display_name = nil   -- player display name for Alternative 2
mod._hover_tx             = nil   -- tooltip x (UI base space)
mod._hover_ty             = nil   -- tooltip y (UI base space)

-- ──────────────────────────────────────────────────────────────────────────────
-- OVERLAY WIDGET DEFINITIONS
--
-- Widgets are anchored to "screen" in our own minimal scenegraph.
-- screen.world_position = {0, 0, 2}  (scale="fit", position={0,0,2})
-- widget.offset = {tx, ty, z} → final position = {tx, ty, z+2}
-- ──────────────────────────────────────────────────────────────────────────────

-- Alternative 3: floating tooltip
local _pn_tooltip_def = UIWidget.create_definition({
    {
        pass_type = "rect",
        style_id  = "border",
        style     = {
            color  = { 220, 160, 130, 60 },
            offset = { -2, -2, 0 },
            size   = { TT_W + 4, TT_H + 4 },
        },
    },
    {
        pass_type = "rect",
        style_id  = "background",
        style     = {
            color  = { 230, 10, 10, 10 },
            offset = { 0, 0, 1 },
            size   = { TT_W, TT_H },
        },
    },
    {
        pass_type = "text",
        value_id  = "note_text",
        value     = "",
        style     = {
            font_type                 = "proxima_nova_bold",
            font_size                 = 16,
            text_color                = { 255, 255, 255, 255 },
            offset                    = { TT_PAD, TT_PAD, 2 },
            size                      = { TT_W - TT_PAD * 2, TT_H - TT_PAD * 2 },
            text_horizontal_alignment = "left",
            text_vertical_alignment   = "top",
            word_wrap                 = true,
        },
    },
}, "screen")

-- Alternative 2: top-of-screen name + note bar
local _pn_toptext_def = UIWidget.create_definition({
    {
        pass_type = "rect",
        style_id  = "background",
        style     = {
            color  = { 200, 0, 0, 0 },
            offset = { 0, 0, 0 },
            size   = { A2_W, A2_H },
        },
    },
    {
        pass_type = "text",
        value_id  = "label_text",
        value     = "",
        style     = {
            font_type                 = "proxima_nova_bold",
            font_size                 = 16,
            text_color                = { 255, 230, 210, 140 },
            offset                    = { 8, 8, 1 },
            size                      = { A2_W - 16, A2_H - 16 },
            text_horizontal_alignment = "left",
            text_vertical_alignment   = "center",
        },
    },
}, "screen")

-- ──────────────────────────────────────────────────────────────────────────────
-- OVERLAY RENDERING STATE  (lazy init on first draw)
-- ──────────────────────────────────────────────────────────────────────────────

local _pn_scenegraph     = nil
local _pn_tooltip_widget = nil
local _pn_toptext_widget = nil

local function _ensure_overlay_ready()
    if _pn_scenegraph then return true end
    local ok, err = pcall(function()
        _pn_scenegraph = UIScenegraph.init_scenegraph(
            { screen = UIWorkspaceSettings.screen },
            RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.scale or 1
        )
        _pn_tooltip_widget = UIWidget.init("pn_tooltip_overlay", _pn_tooltip_def)
        _pn_toptext_widget  = UIWidget.init("pn_toptext_overlay",  _pn_toptext_def)
        _pn_tooltip_widget.alpha_multiplier = 1
        _pn_toptext_widget.alpha_multiplier  = 1
    end)
    if not ok then
        mod:echo("[PlayerNotes] overlay init failed: " .. tostring(err))
        _pn_scenegraph = nil
        return false
    end
    return true
end

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 1: Inline note in account_name row (CONFIRMED WORKING)
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook(CLASS.PlayerInfo, "user_display_name",
    function(func, self, ...)
        local name, color_override = func(self, ...)
        if self:is_own_player() then return name, color_override end

        local puid = self:platform_user_id()
        if not puid or puid == "" then return name, color_override end

        local note = get_note(puid)
        if not note or note == "" then return name, color_override end

        local preview = #note > 28 and note:sub(1, 28) .. "..." or note
        return (name or "") .. " · " .. preview, color_override
    end
)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 2: Inject note button into the right-click popup (CONFIRMED WORKING)
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook(CLASS.ViewElementPlayerSocialPopup, "_set_player_info",
    function(func, self, parent, player_info, menu_items, num_menu_items, ...)
        local puid = player_info:platform_user_id()

        if not player_info:is_own_player() and puid and puid ~= "" then
            mod._popup_puid = puid

            local note    = get_note(puid)
            local preview = note and (#note > 40 and note:sub(1, 40) .. "..." or note)
            local label   = note and ("[Note] " .. preview) or STR_BTN_ADD

            table.insert(menu_items, 1, {
                label     = "pn_divider",
                blueprint = "group_divider",
            })
            table.insert(menu_items, 1, {
                label            = label,
                blueprint        = "button",
                is_disabled      = false,
                on_pressed_sound = UISoundEvents.social_menu_see_player_profile,
                callback         = callback(parent, "cb_pn_edit_note", player_info),
            })
            num_menu_items = num_menu_items + 2
        else
            mod._popup_puid = nil
        end

        func(self, parent, player_info, menu_items, num_menu_items, ...)
    end
)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 3: Inject callback into SocialMenuRosterView
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook_safe(CLASS.SocialMenuRosterView, "init", function(self, ...)
    function self:cb_pn_edit_note(player_info)
        mod._editing_puid = player_info:platform_user_id()
        mod._editing_name = player_info:user_display_name(true, true)
        mod:echo(string.format(STR_SELECTED, mod._editing_name or "player"))
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 4: Cleanup on view close
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook_safe(CLASS.SocialMenuRosterView, "on_exit", function(self, ...)
    mod._popup_puid           = nil
    mod._editing_puid         = nil
    mod._editing_name         = nil
    mod._hovered_note         = nil
    mod._hovered_display_name = nil
    mod._hover_tx             = nil
    mod._hover_ty             = nil
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 5: Hover detection in SocialMenuRosterView._draw_widgets
--
-- This hook ONLY detects which player is hovered and stores state in mod._.
-- Actual rendering moved to UIConstantElements.draw (Hook 6) which uses the
-- overlay renderer that draws on top of all game views.
--
-- hotspot.is_hover NEVER works here — roster widgets are drawn in an offscreen
-- render target. Use geometric bounds check with world_position + widget.offset.
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook(CLASS.SocialMenuRosterView, "_draw_widgets",
    function(func, self, dt, t, input_service, ui_renderer, render_settings)
        func(self, dt, t, input_service, ui_renderer, render_settings)

        -- Reset hover state each frame; set below if hover detected
        mod._hovered_note         = nil
        mod._hovered_display_name = nil
        mod._hover_tx             = nil
        mod._hover_ty             = nil

        if self._popup_menu then return end

        local grid_node      = self._ui_scenegraph and self._ui_scenegraph.roster_grid_content
        local roster_widgets = self._roster_widgets
        if not grid_node or not roster_widgets then return end

        local cursor_pos = input_service:get("cursor")
        if not cursor_pos then return end

        local inv = RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.inverse_scale or 1
        local sw  = RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.width  * inv or 1920
        local sh  = RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.height * inv or 1080
        local mx  = Vector3.x(cursor_pos) * inv
        local my  = Vector3.y(cursor_pos) * inv
        local gx  = grid_node.world_position[1]
        local gy  = grid_node.world_position[2]

        for i = 1, #roster_widgets do
            local w   = roster_widgets[i]
            local off = w.offset
            if off then
                local wx = gx + off[1]
                local wy = gy + off[2]
                -- w.content.size is authoritative — w.size is always nil (UIWidget.init)
                local cs = w.content and w.content.size
                local ww = (cs and cs[1]) or 480
                local wh = (cs and cs[2]) or 80

                if mx >= wx and mx <= wx + ww and my >= wy and my <= wy + wh then
                    local pi = w.content and w.content.player_info
                    if pi and not pi:is_own_player() then
                        local puid = pi:platform_user_id()
                        local note = get_note(puid)
                        if note then
                            -- Compute tooltip position (right of widget, or left if off-screen)
                            local tx = wx + ww + 15
                            if tx + TT_W > sw then tx = wx - TT_W - 15 end
                            local ty = math.max(wy, 10)
                            ty = math.min(ty, sh - TT_H - 10)

                            mod._hovered_note         = note
                            mod._hovered_display_name = pi:user_display_name()
                            mod._hover_tx             = tx
                            mod._hover_ty             = ty
                        end
                    end
                    break  -- stop at first widget under cursor
                end
            end
        end
    end
)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 6: UIConstantElements.draw — overlay renderer, drawn above ALL views
--
-- UIManager.render() order:
--   1. view_handler:draw()          ← SocialMenuRosterView here
--   2. ui_constant_elements:draw()  ← WE HOOK HERE (overlay viewport on top)
--   3. hud:draw()
--
-- self._ui_renderer is UIConstantElements' own renderer (viewport_type="overlay").
-- We create one fresh begin_pass/end_pass block using our own minimal scenegraph.
-- UIWidget.draw reads ui_renderer.ui_scenegraph (set by begin_pass) to resolve
-- the "screen" anchor node world_position = {0,0,2}. Widget.offset adds to that.
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook(CLASS.UIConstantElements, "draw", function(func, self, dt, t, input_service)
    func(self, dt, t, input_service)

    local note = mod._hovered_note
    if not note then return end
    if not _ensure_overlay_ready() then return end

    -- Keep scenegraph scale in sync with resolution changes
    UIScenegraph.update_scenegraph(_pn_scenegraph, RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.scale or 1)

    local ui_renderer     = self._ui_renderer
    local render_settings = self._render_settings
    local saved_layer     = render_settings.start_layer

    render_settings.start_layer = 900  -- above social panel, below nothing

    UIRenderer.begin_pass(ui_renderer, _pn_scenegraph, input_service, dt, render_settings)

    -- ── Alternative 3: floating tooltip near hovered widget ───────────────────
    local tx = mod._hover_tx or 800
    local ty = mod._hover_ty or 300
    _pn_tooltip_widget.content.note_text = note
    _pn_tooltip_widget.offset[1]          = tx
    _pn_tooltip_widget.offset[2]          = ty
    _pn_tooltip_widget.offset[3]          = TT_Z
    _pn_tooltip_widget.visible            = true
    _pn_tooltip_widget.alpha_multiplier   = 1
    pcall(UIWidget.draw, _pn_tooltip_widget, ui_renderer)

    -- ── Alternative 2: name + note bar at top of screen ──────────────────────
    local display_name = mod._hovered_display_name or "Player"
    _pn_toptext_widget.content.label_text = display_name .. "  —  " .. note
    _pn_toptext_widget.offset[1]           = A2_X
    _pn_toptext_widget.offset[2]           = A2_Y
    _pn_toptext_widget.offset[3]           = TT_Z
    _pn_toptext_widget.visible             = true
    _pn_toptext_widget.alpha_multiplier    = 1
    pcall(UIWidget.draw, _pn_toptext_widget, ui_renderer)

    UIRenderer.end_pass(ui_renderer)
    render_settings.start_layer = saved_layer
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- COMMAND: /note <text>
-- ──────────────────────────────────────────────────────────────────────────────

mod:command("note", "Save a note for the last selected player.", function(...)
    local args = { ... }
    if #args == 0 then mod:echo(STR_USAGE_NOTE); return end
    if not mod._editing_puid then mod:echo(STR_NONE_SEL); return end
    local text = table.concat(args, " ")
    save_note(mod._editing_puid, text)
    mod:echo(string.format(STR_SAVED, mod._editing_name or "player"))
    mod._editing_puid = nil
    mod._editing_name = nil
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- COMMAND: /note_clear
-- ──────────────────────────────────────────────────────────────────────────────

mod:command("note_clear", "Clear the note for the last selected player.", function()
    if not mod._editing_puid then mod:echo(STR_NONE_SEL); return end
    save_note(mod._editing_puid, nil)
    mod:echo(string.format(STR_CLEARED, mod._editing_name or "player"))
    mod._editing_puid = nil
    mod._editing_name = nil
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- COMMAND: /pn_notes — list all saved notes
-- ──────────────────────────────────────────────────────────────────────────────

mod:command("pn_notes", "List all saved PlayerNotes.", function()
    local notes = get_notes()
    local count = 0
    for k, v in pairs(notes) do
        count = count + 1
        mod:echo(string.format("[%d] %s → %s", count, tostring(k), tostring(v)))
    end
    if count == 0 then mod:echo("No notes saved yet.") end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- LIFECYCLE
-- ──────────────────────────────────────────────────────────────────────────────

mod.on_all_mods_loaded = function()
    mod:echo("[PlayerNotes] v1.8.0 Loaded. /note /note_clear /pn_notes")
end
