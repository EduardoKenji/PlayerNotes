--[[
    PlayerNotes
    Author: Eduardo
    Version: 1.9.6

    Add persistent notes to any player visible in the Social panel or Party Finder.
    Three simultaneous display mechanisms (each individually togglable via F4 Mod Options):

    1. Inline note — hook PlayerInfo.user_display_name to append " · <note>" to the name.
    2. Top-bar   — when hovering, show "Name — note" in a small bar at top-left.
    3. Tooltip   — floating box near the hovered player row, sized to fit the text.

    Why UIConstantElements renderer works:
      UIManager.render() call order:
        1. view_handler:draw()           — SocialMenuRosterView and all UI views
        2. ui_constant_elements:draw()   — overlay viewport, drawn on top of ALL views
        3. hud:draw()
      We hook UIConstantElements.draw and inject our own begin_pass/UIWidget.draw/end_pass
      after func() runs. The overlay viewport composites on top of the social panel.

    Hover detection:
      SocialMenuRosterView._draw_widgets is used ONLY to detect which player is hovered
      (geometric bounds check — hotspot.is_hover never works for offscreen-rendered roster
      widgets). Detected state stored in mod._ vars. UIConstantElements.draw reads that state.
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
-- Height is computed dynamically per note; TT_H_MIN is the floor.
local TT_W     = 340
local TT_H_MIN = 44
local TT_PAD   = 10
local TT_Z     = 997

-- Top-text bar dimensions (Alternative 2)
local A2_W   = 600
local A2_H   = 34
local A2_X   = 30
local A2_Y   = 20

-- ──────────────────────────────────────────────────────────────────────────────
-- TOOLTIP HEIGHT CALCULATION
-- Approximates word-wrapped line count for proxima_nova_bold at font_size 16
-- in a box of width (TT_W - 2*TT_PAD).
-- ──────────────────────────────────────────────────────────────────────────────

local function compute_tooltip_height(text)
    -- ~8px average char width for proxima_nova_bold at size 16
    local chars_per_line = math.floor((TT_W - TT_PAD * 2) / 8)
    local line_h         = 22   -- px per line including leading
    local lines          = math.max(1, math.ceil(#text / chars_per_line))
    -- TT_PAD top + line content + TT_PAD bottom + a little extra breathing room
    return math.max(TT_H_MIN, lines * line_h + TT_PAD * 2 + 6)
end

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
-- PLAYER KEY
-- platform_user_id() returns "" for cross-platform offline friends (globe icon).
-- Fall back to account_id() so those players still get a stable, usable key.
-- ──────────────────────────────────────────────────────────────────────────────

local function get_player_key(player_info)
    local puid = player_info:platform_user_id()
    if puid and puid ~= "" then return puid end
    local ok, aid = pcall(function() return player_info:account_id() end)
    if ok and aid and aid ~= "" then return aid end
    return nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- NAME CACHE
-- Persisted so /pn_notes can show readable names even after a restart.
-- ──────────────────────────────────────────────────────────────────────────────

local function save_player_name(key, name)
    if not key or key == "" or not name or name == "" then return end
    local names = mod:get("player_names") or {}
    if names[key] == name then return end
    names[key] = name
    mod:set("player_names", names)
end

local function get_cached_name(key)
    if not key or key == "" then return nil end
    return _raw_names[key] or (mod:get("player_names") or {})[key]
end

-- ──────────────────────────────────────────────────────────────────────────────
-- HOVER STATE  (written by _draw_widgets hook, read by UIConstantElements hook)
-- ──────────────────────────────────────────────────────────────────────────────

mod._popup_puid           = nil
mod._editing_puid         = nil
mod._editing_name         = nil
mod._hovered_note         = nil   -- full note text
mod._hovered_raw_name     = nil   -- raw account name (no note appended)
mod._hover_tx             = nil   -- tooltip x (UI base space)
mod._hover_ty             = nil   -- tooltip y (UI base space)
mod._hover_dyn_h          = nil   -- tooltip height for current note

-- ──────────────────────────────────────────────────────────────────────────────
-- OVERLAY WIDGET DEFINITIONS
-- ──────────────────────────────────────────────────────────────────────────────

-- Alternative 3: floating tooltip (height mutated dynamically at draw time)
local _pn_tooltip_def = UIWidget.create_definition({
    {
        pass_type = "rect",
        style_id  = "border",
        style     = {
            color  = { 220, 160, 130, 60 },
            offset = { -2, -2, 0 },
            size   = { TT_W + 4, TT_H_MIN + 4 },
        },
    },
    {
        pass_type = "rect",
        style_id  = "background",
        style     = {
            color  = { 230, 10, 10, 10 },
            offset = { 0, 0, 1 },
            size   = { TT_W, TT_H_MIN },
        },
    },
    {
        pass_type = "text",
        style_id  = "note_text",
        value_id  = "note_text",
        value     = "",
        style     = {
            font_type                 = "proxima_nova_bold",
            font_size                 = 16,
            text_color                = { 255, 255, 255, 255 },
            offset                    = { TT_PAD, TT_PAD, 2 },
            size                      = { TT_W - TT_PAD * 2, TT_H_MIN - TT_PAD * 2 },
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
-- HOOK 1: Inline note in account_name row
-- Guarded by "show_inline" mod option.
--
-- Also caches the raw (unmodified) platform display name per puid so the
-- top-bar (Alt 2) can show "Name — note" even when inline mode is on.
-- Without this cache, w.content.account_name already contains " · note"
-- because the roster blueprint calls user_display_name() through this hook.
-- ──────────────────────────────────────────────────────────────────────────────

local _raw_names = {}  -- puid → raw platform display name (no note appended)

mod:hook(CLASS.PlayerInfo, "user_display_name",
    function(func, self, ...)
        local name, color_override = func(self, ...)

        -- Cache raw name before any modification (keyed by the same stable key used for notes)
        local puid = get_player_key(self)
        if puid then
            _raw_names[puid] = name
            save_player_name(puid, name)
        end

        if self:is_own_player() then return name, color_override end
        if not puid then return name, color_override end

        local note = get_note(puid)
        if not note or note == "" then return name, color_override end

        if not mod:get("show_inline") then
            -- Icon-only: show a small star glyph (U+E046, Darktide favorites icon) to
            -- indicate this player has a note, without revealing the text.
            return (name or "") .. " \xEE\x81\x86", color_override
        end

        local preview = #note > 28 and note:sub(1, 28) .. "..." or note
        return (name or "") .. " · " .. preview, color_override
    end
)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 2: Inject note button into the right-click popup
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook(CLASS.ViewElementPlayerSocialPopup, "_set_player_info",
    function(func, self, parent, player_info, menu_items, num_menu_items, ...)
        local puid = get_player_key(player_info)

        if not player_info:is_own_player() and puid then
            mod._popup_puid = puid
            -- Keep name cache warm (display name may not be in _raw_names yet for offline players)
            save_player_name(puid, player_info:user_display_name())

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
        mod._editing_puid = get_player_key(player_info)
        mod._editing_name = player_info:user_display_name(true, true)
        if mod._editing_puid then
            save_player_name(mod._editing_puid, mod._editing_name)
        end
        mod:echo(string.format(STR_SELECTED, mod._editing_name or "player"))
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 4: Cleanup on view close
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook_safe(CLASS.SocialMenuRosterView, "on_exit", function(self, ...)
    mod._popup_puid       = nil
    mod._editing_puid     = nil
    mod._editing_name     = nil
    mod._hovered_note     = nil
    mod._hovered_raw_name = nil
    mod._hover_tx         = nil
    mod._hover_ty         = nil
    mod._hover_dyn_h      = nil
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 5: Hover detection in SocialMenuRosterView._draw_widgets
--
-- Detects which player is hovered and stores state in mod._ vars.
-- Rendering happens in UIConstantElements.draw (Hook 6) via the overlay renderer.
--
-- hotspot.is_hover NEVER works here — roster widgets are drawn in an offscreen
-- render target. Geometric bounds check with world_position + widget.offset is used.
--
-- Raw account name (w.content.account_name) is stored instead of calling
-- pi:user_display_name() to avoid getting the note-appended version from Hook 1.
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook(CLASS.SocialMenuRosterView, "_draw_widgets",
    function(func, self, dt, t, input_service, ui_renderer, render_settings)
        func(self, dt, t, input_service, ui_renderer, render_settings)

        -- Reset hover state each frame
        mod._hovered_note     = nil
        mod._hovered_raw_name = nil
        mod._hover_tx         = nil
        mod._hover_ty         = nil
        mod._hover_dyn_h      = nil

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
                -- w.content.size is authoritative; w.size is always nil (UIWidget.init)
                local cs = w.content and w.content.size
                local ww = (cs and cs[1]) or 480
                local wh = (cs and cs[2]) or 80

                if mx >= wx and mx <= wx + ww and my >= wy and my <= wy + wh then
                    local pi = w.content and w.content.player_info
                    if pi and not pi:is_own_player() then
                        local puid = get_player_key(pi)
                        local note = get_note(puid)
                        if note then
                            local dyn_h = compute_tooltip_height(note)

                            -- Position tooltip to the right; flip left if off-screen
                            local tx = wx + ww + 15
                            if tx + TT_W > sw then tx = wx - TT_W - 15 end
                            local ty = math.max(wy, 10)
                            ty = math.min(ty, sh - dyn_h - 10)

                            -- Use _raw_names cache (populated by Hook 1) to get the
                            -- unmodified platform name. w.content.account_name is set
                            -- by the roster blueprint calling user_display_name() through
                            -- Hook 1, so it already contains " · note" when inline is on.
                            mod._hovered_note     = note
                            mod._hovered_raw_name = get_cached_name(puid)
                                                 or (w.content and w.content.account_name)
                                                 or "Player"
                            mod._hover_tx         = tx
                            mod._hover_ty         = ty
                            mod._hover_dyn_h      = dyn_h
                        end
                    end
                    break
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
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook(CLASS.UIConstantElements, "draw", function(func, self, dt, t, input_service)
    func(self, dt, t, input_service)

    local note = mod._hovered_note
    if not note then return end
    if not _ensure_overlay_ready() then return end

    local show_top_bar = mod:get("show_top_bar")
    local show_tooltip = mod:get("show_tooltip")
    if not show_top_bar and not show_tooltip then return end

    UIScenegraph.update_scenegraph(_pn_scenegraph, RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.scale or 1)

    local ui_renderer     = self._ui_renderer
    local render_settings = self._render_settings
    local saved_layer     = render_settings.start_layer

    render_settings.start_layer = 900

    UIRenderer.begin_pass(ui_renderer, _pn_scenegraph, input_service, dt, render_settings)

    -- ── Alternative 3: floating tooltip (dynamic height) ─────────────────────
    if show_tooltip then
        local tx    = mod._hover_tx or 800
        local ty    = mod._hover_ty or 300
        local dyn_h = mod._hover_dyn_h or TT_H_MIN

        -- Resize widget styles to fit the actual note text
        _pn_tooltip_widget.style.border.size[2]     = dyn_h + 4
        _pn_tooltip_widget.style.background.size[2] = dyn_h
        _pn_tooltip_widget.style.note_text.size[2]  = dyn_h - TT_PAD * 2

        _pn_tooltip_widget.content.note_text  = note
        _pn_tooltip_widget.offset[1]          = tx
        _pn_tooltip_widget.offset[2]          = ty
        _pn_tooltip_widget.offset[3]          = TT_Z
        _pn_tooltip_widget.visible            = true
        _pn_tooltip_widget.alpha_multiplier   = 1
        pcall(UIWidget.draw, _pn_tooltip_widget, ui_renderer)
    end

    -- ── Alternative 2: top-left name + note bar ───────────────────────────────
    if show_top_bar then
        local raw_name = mod._hovered_raw_name or "Player"
        _pn_toptext_widget.content.label_text = raw_name .. "  —  " .. note
        _pn_toptext_widget.offset[1]          = A2_X
        _pn_toptext_widget.offset[2]          = A2_Y
        _pn_toptext_widget.offset[3]          = TT_Z
        _pn_toptext_widget.visible            = true
        _pn_toptext_widget.alpha_multiplier   = 1
        pcall(UIWidget.draw, _pn_toptext_widget, ui_renderer)
    end

    UIRenderer.end_pass(ui_renderer)
    render_settings.start_layer = saved_layer
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 7: Hover detection in GroupFinderView._draw_widgets (Party Finder)
--
-- GroupFinderView has NO offscreen renderer — widgets are drawn in screen space.
-- The game itself uses grid:hovered_grid_index() + grid:widget_by_index() for
-- hover detection in this same view (group_finder_view.lua:777), so we do the
-- same rather than using geometric bounds or hotspot.is_hover.
--
-- account_id (Fatshark backend ID) → platform_user_id via social data service.
-- If the requesting player is not in the social cache (non-friend), puid will
-- be nil and we silently skip (no note to show).
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook(CLASS.GroupFinderView, "_draw_widgets",
    function(func, self, dt, t, input_service, ui_renderer, render_settings)
        func(self, dt, t, input_service, ui_renderer, render_settings)

        -- Reset hover state each frame
        mod._hovered_note     = nil
        mod._hovered_raw_name = nil
        mod._hover_tx         = nil
        mod._hover_ty         = nil
        mod._hover_dyn_h      = nil

        local grid = self._player_request_grid
        if not grid then return end

        -- Use the same hover API the game uses in this view (no offscreen renderer)
        local hovered_idx = grid:hovered_grid_index()
        if not hovered_idx then return end

        local widget = grid:widget_by_index(hovered_idx)
        if not widget then return end

        local content    = widget.content
        local element    = content and content.element
        local account_id = element and element.account_id
        if not account_id then return end

        local social = Managers.data_service and Managers.data_service.social
        if not social then return end

        local player_info = social:get_player_info_by_account_id(account_id)
        if not player_info then return end

        local puid = get_player_key(player_info)
        local note = get_note(puid)
        if not note then return end

        local cursor_pos = input_service and input_service:get("cursor")
        if not cursor_pos then return end

        local inv   = RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.inverse_scale or 1
        local sw    = RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.width  * inv or 1920
        local sh    = RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.height * inv or 1080
        local mx    = Vector3.x(cursor_pos) * inv
        local my    = Vector3.y(cursor_pos) * inv
        local dyn_h = compute_tooltip_height(note)

        -- Position tooltip to the left of cursor (player_request_grid is on the right)
        local tx = mx - TT_W - 20
        if tx < 10 then tx = mx + 20 end
        local ty = math.max(my - dyn_h / 2, 10)
        ty = math.min(ty, sh - dyn_h - 10)

        mod._hovered_note     = note
        mod._hovered_raw_name = get_cached_name(puid)
                             or player_info:user_display_name()
                             or "Player"
        mod._hover_tx         = tx
        mod._hover_ty         = ty
        mod._hover_dyn_h      = dyn_h
    end
)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 8: Cleanup on GroupFinderView close
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook_safe(CLASS.GroupFinderView, "on_exit", function(self, ...)
    mod._hovered_note     = nil
    mod._hovered_raw_name = nil
    mod._hover_tx         = nil
    mod._hover_ty         = nil
    mod._hover_dyn_h      = nil
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
        local display_name = get_cached_name(k) or k
        mod:echo(string.format("[%d] %s → %s", count, display_name, tostring(v)))
    end
    if count == 0 then mod:echo("No notes saved yet.") end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- LIFECYCLE
-- ──────────────────────────────────────────────────────────────────────────────

mod.on_all_mods_loaded = function()
    mod:echo("[PlayerNotes] v1.9.6 Loaded. /note /note_clear /pn_notes")
end
