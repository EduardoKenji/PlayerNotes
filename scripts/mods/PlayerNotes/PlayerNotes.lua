--[[
    PlayerNotes
    Author: Eduardo
    Version: 2.7.0

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
-- WORLD NOTES — path used as the element filename in register_hud_element.
-- The class itself is defined inline below; a require hook intercepts this
-- path so no file ever needs to be loaded from disk via io_dofile.
-- ──────────────────────────────────────────────────────────────────────────────

local _PN_HUD_ELEMENT_PATH  = "PlayerNotes/scripts/mods/PlayerNotes/hud_element_player_notes"

-- ──────────────────────────────────────────────────────────────────────────────
-- CONSTANTS
-- ──────────────────────────────────────────────────────────────────────────────

local STR_BTN_ADD    = "Add Note"
local STR_SELECTED   = "Selected %s — type /note [text] to save."
local STR_SAVED      = "Note saved for %s."
local STR_NONE_SEL   = "Click 'Add Note' on a player first."
local STR_USAGE_NOTE = "Usage: /note [your note text]"

-- char_to_player LRU eviction cap.
-- When the table reaches CHAR_CACHE_MAX, a batch eviction trims it to CHAR_CACHE_TRIM_TO.
-- Batch eviction amortizes the sort cost: one sort every ~50 new characters instead of
-- one per character after the cap. Hub-context entries are evicted before mission-context
-- entries of the same age so hard-earned mission observations survive longer.
local CHAR_CACHE_MAX     = 250
local CHAR_CACHE_TRIM_TO = 200

-- Tooltip dimensions (Alternative 3)
-- Height is computed dynamically per note; TT_H_MIN is the floor.
local TT_W     = 340
local TT_H_MIN = 44
local TT_PAD   = 10
local TT_Z     = 997

-- Top-text bar dimensions (Alternative 2)
-- Width increased to 860 to fit "Name — Last seen in <mission> (<difficulty>) at <date>, <rel>" text.
local A2_W   = 860
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
-- CACHES  (must be declared before any function that references them)
-- _raw_names:  puid → raw platform display name (no note appended)
-- _puid_cache: player_info object reference → puid
--   Avoids calling platform_user_id()/account_id() in the per-frame hover loop.
--   Populated once in Hook 1 (roster blueprint calls, safe context).
--   Weak keys: allows the GC to collect stale player_info refs without waiting
--   for on_exit (handles abnormal view teardown).
-- ──────────────────────────────────────────────────────────────────────────────

local _raw_names  = {}
local _puid_cache = setmetatable({}, { __mode = "k" })
-- Dedup guard: prevents calling mod:set for an already-persisted (char_name, puid) pair.
-- Keyed by char_name.."\0"..puid. Cleared only by pn_notes_delete_all.
local _known_chars = {}

-- ──────────────────────────────────────────────────────────────────────────────
-- PERSISTENCE CACHES
-- DMF's mod:get() calls table.clone() on every invocation for table-typed
-- settings — expensive in per-frame hooks. Load each table once at module init
-- and keep a live reference. Mutate in-place; call mod:set() only when data
-- actually changes so DMF snapshots the current state for disk persistence.
-- mod:get() / mod:set() for booleans and strings are NOT cloned — fine as-is.
-- ──────────────────────────────────────────────────────────────────────────────

local _notes_cache          = mod:get("player_notes")   or {}
local _names_cache          = mod:get("player_names")   or {}
local _name_to_ids_cache    = mod:get("name_to_ids")    or {}
local _char_to_player_cache = mod:get("char_to_player") or {}
local _notification_timer = 0

-- Exposed so hud_element_player_notes.lua can read notes without mod:get().
mod._fn_get_notes = function() return _notes_cache end

mod._cached_top_bar_text = ""

mod._notification_done_for_session = false

-- ──────────────────────────────────────────────────────────────────────────────
-- PERSISTENCE
-- ──────────────────────────────────────────────────────────────────────────────

local function get_notes()       return _notes_cache end
local function get_name_to_ids() return _name_to_ids_cache end

local function update_name_to_ids(display_name, puid)
    if not display_name or display_name == "" or not puid or puid == "" then return end
    local id_list = _name_to_ids_cache[display_name] or {}
    -- Avoid duplicates
    for _, id in ipairs(id_list) do
        if id == puid then return end
    end
    table.insert(id_list, puid)
    _name_to_ids_cache[display_name] = id_list
    mod:set("name_to_ids", _name_to_ids_cache)
end

-- Look up note by display name, checking all associated IDs
local function get_note_by_name(display_name)
    if not display_name or display_name == "" then return nil, nil end
    local name_to_ids = get_name_to_ids()
    local id_list = name_to_ids[display_name]
    if not id_list or #id_list == 0 then return nil, nil end
    local notes = get_notes()
    for _, id in ipairs(id_list) do
        local note = notes[id]
        if note and note ~= "" then return note, id end
    end
    return nil, nil
end

local function save_note(puid, text, display_name)
    if not puid or puid == "" then
        mod:echo("[PlayerNotes] ERROR: cannot save note — player key is nil/empty.")
        return
    end

    -- Sync to all known IDs for this name so online/offline IDs never diverge.
    -- (Xbox friends get a Fatshark UUID when offline and their Xbox XUID when online.)
    -- Uses _name_to_ids_cache directly — no mod:get() clone needed.
    local function sync_all_ids(value)
        _notes_cache[puid] = value
        if display_name and display_name ~= "" then
            local id_list = _name_to_ids_cache[display_name] or {}
            for _, id in ipairs(id_list) do
                _notes_cache[id] = value
            end
        end
    end

    if text and text ~= "" then
        sync_all_ids(text)
        update_name_to_ids(display_name, puid)
    else
        sync_all_ids(nil)
    end

    mod:set("player_notes", _notes_cache)
end

local function notify_noted_players_in_session()
    if mod._notification_done_for_session then return end

    if not mod:get("show_session_notifications") then return end

    local players = Managers.player:players()
    local notes = mod._fn_get_notes and mod._fn_get_notes() or {}
    
    local noted_list = {}

    for _, player in pairs(players) do
        -- SKIP the local player
        if player ~= Managers.player:local_player() then
            local account_id = player.account_id and player:account_id()
            
            -- Only proceed if we have an account ID
            if account_id then
                local player_info = Managers.data_service.social:get_player_info_by_account_id(account_id)
                
                -- Only proceed if the social service has the player's info
                if player_info then
                    local puid = player_info:platform_user_id()
                    
                    -- If they are in our notes cache, add them to the list
                    if puid and notes[puid] then
                        local char_name = player:name() or "Unknown"
                        local tag = player_info:user_display_name(true, true) or "Unknown"
                        table.insert(noted_list, string.format("%s(%s)", char_name, tag))
                    end
                end
            end
        end
    end

    local count = #noted_list
    if count == 0 then return end -- Don't show if no one is noted

    -- Formatting the lines
    local line_1 = string.format("[PlayerNotes] Noted players here (%d):", count)
    local line_2 = ""
    local line_3 = ""

    if count == 1 then
        line_2 = noted_list[1]
    elseif count == 2 then
        line_2 = noted_list[1]
        line_3 = noted_list[2]
    else
        -- Split the list: half on line 2, half on line 3
        local mid = math.ceil(count / 2)
        local l2_players = {}
        local l3_players = {}
        for i = 1, count do
            if i <= mid then 
                table.insert(l2_players, noted_list[i]) 
            else 
                table.insert(l3_players, noted_list[i]) 
            end
        end
        line_2 = table.concat(l2_players, ", ")
        line_3 = table.concat(l3_players, ", ")
    end

    -- Trigger the native Game Notification
    Managers.event:trigger("event_add_notification_message", "custom", {
        line_1 = line_1,
        line_1_color = { 255, 255, 255, 255 },
        line_2 = line_2,
        line_2_color = { 200, 200, 200, 255 },
        line_3 = line_3,
        line_3_color = { 200, 200, 200, 255 },
    })

    mod._notification_done_for_session = true 
end

mod._fn_notify_players = notify_noted_players_in_session

-- Try to get note by ID first, then fall back to name-based lookup
local function get_note(puid, display_name)
    local notes = get_notes()
    
    -- Try direct ID lookup first
    if puid and puid ~= "" then
        local note = notes[puid]
        if note and note ~= "" then return note end
    end
    
    -- Fall back to name-based lookup (handles ID switching)
    if display_name and display_name ~= "" then
        return get_note_by_name(display_name)
    end
    
    return nil
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
-- Also maintains bidirectional mapping: id→name AND name→[list of ids]
-- ──────────────────────────────────────────────────────────────────────────────

local function save_player_name(key, name)
    if not key or key == "" or not name or name == "" then return end
    if _names_cache[key] == name then return end
    _names_cache[key] = name
    mod:set("player_names", _names_cache)
    _raw_names[key] = name
end

local function get_cached_name(key)
    if not key or key == "" then return nil end
    return _raw_names[key] or _names_cache[key]
end

-- Get all IDs associated with a display name
local function get_ids_for_name(display_name)
    if not display_name or display_name == "" then return nil end
    return get_name_to_ids()[display_name]
end

-- ──────────────────────────────────────────────────────────────────────────────
-- CHARACTER NAME → PLAYER MAPPING
-- char_to_player[char_name] = { puid, display_name, last_seen, context }
--
-- context = "mission" | "hub"
-- Priority rule: "mission" always beats "hub" — a mission entry is never
-- overwritten by a hub observation. This prevents a hub-lobby player with the
-- same character name as your recent mission teammate from hijacking the mapping.
--
-- _known_chars guards against calling mod:set on every frame for the same pair.
-- ──────────────────────────────────────────────────────────────────────────────

local function get_char_to_player() return _char_to_player_cache end

-- Evict oldest entries from _char_to_player_cache when it exceeds CHAR_CACHE_MAX.
-- Sort key: last_seen ASC (oldest first); hub entries are evicted before mission
-- entries of equal age so hard-earned mission observations survive longer.
-- Only called when a new char_name key is about to be inserted.
local function evict_oldest_char_entries()
    local entries = {}
    for char_name, entry in pairs(_char_to_player_cache) do
        entries[#entries + 1] = { key = char_name, entry = entry }
    end
    local count = #entries
    if count < CHAR_CACHE_MAX then return end

    table.sort(entries, function(a, b)
        local at = a.entry.last_seen or 0
        local bt = b.entry.last_seen or 0
        if at == bt then
            -- hub before mission: hub=true when context=="hub"
            local a_hub = (a.entry.context == "hub")
            local b_hub = (b.entry.context == "hub")
            if a_hub ~= b_hub then return a_hub end
        end
        return at < bt
    end)

    local to_remove = count - CHAR_CACHE_TRIM_TO  -- batch trim: drop to TRIM_TO, not just -1
    for i = 1, to_remove do
        local char_name = entries[i].key
        local puid      = entries[i].entry.puid or ""
        _char_to_player_cache[char_name] = nil
        _known_chars[char_name .. "\0" .. puid] = nil
    end
end

local function update_char_to_player(char_name, puid, display_name, context)
    if not char_name or char_name == "" then return end
    if not puid or puid == "" then return end

    local cache_key = char_name .. "\0" .. puid
    if _known_chars[cache_key] then return end  -- already persisted this pair this session

    local existing = _char_to_player_cache[char_name]

    -- Mission beats hub: never let a hub observation overwrite a mission entry.
    if existing and existing.context == "mission" and context == "hub" then
        _known_chars[cache_key] = true  -- mark so we don't keep retrying
        return
    end

    -- Evict oldest entries if this is a new key and the table is at capacity.
    if not existing then
        evict_oldest_char_entries()
    end

    _char_to_player_cache[char_name] = {
        puid         = puid,
        display_name = display_name or "",
        last_seen    = os.time(),
        context      = context,
    }
    mod:set("char_to_player", _char_to_player_cache)
    _known_chars[cache_key] = true
end

-- Expose so hud_element_player_notes.lua can record mission-context entries.
mod._fn_update_char = update_char_to_player

-- ──────────────────────────────────────────────────────────────────────────────
-- LAST-SEEN TRACKING
--
-- _last_seen_cache: puid → { ts = <unix timestamp>, loc = <location string> }
--   Persisted across sessions via mod:set("player_last_seen").
--   Location string examples: "Mourningstar", "Vigil Station Oblivium (Havoc 40)",
--   "Smelter Complex (Auric)", "Archives (Auric Maelstrom)".
--
-- _session_seen: puid → true (in-memory only, not persisted)
--   Guards against repeated mod:set() calls for the same player in the same session.
--   Cleared on game-state exit so re-entering a map records a fresh timestamp.
-- ──────────────────────────────────────────────────────────────────────────────

local MONTHS = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}

local _last_seen_cache = mod:get("player_last_seen") or {}
local _session_seen    = {}

local function update_last_seen(puid, location)
    if not puid or puid == "" then return end
    
    local now = os.time()
    local last_update = _session_seen[puid] or 0
    local last_entry = _last_seen_cache[puid]
    
    -- SMART THROTTLE LOGIC:
    -- 1. If the location has changed (e.g., Hub -> Mission), update IMMEDIATELY.
    -- 2. If the location is the same, only update if 300 seconds have passed.
    local location_changed = not last_entry or last_entry.loc ~= location
    local timer_expired = (now - last_update) >= 300

    if not location_changed and not timer_expired then 
        return 
    end
    
    _last_seen_cache[puid] = { ts = now, loc = location }
    mod:set("player_last_seen", _last_seen_cache)
    _session_seen[puid] = now 
end

-- Format a last-seen entry as a human-readable string.
-- Returns nil if no entry exists for puid.
-- Example output: "Last seen in Vigil Station Oblivium (Havoc 40) at Mar 11th, 12:37pm, 2 days ago"
local function format_last_seen_text(puid)
    if not puid then return nil end
    local entry = _last_seen_cache[puid]
    if not entry or not entry.ts then return nil end

    local ts    = entry.ts
    local loc   = entry.loc or "Unknown"
    local delta = os.time() - ts

    if delta < 60 then
        return "Last seen in " .. loc .. " just now"
    end

    local rel
    if delta < 3600 then
        local m = math.floor(delta / 60)
        rel = m .. (m == 1 and " min ago" or " mins ago")
    elseif delta < 86400 then
        local h = math.floor(delta / 3600)
        rel = h .. (h == 1 and " hr ago" or " hrs ago")
    else
        local d = math.floor(delta / 86400)
        rel = d .. (d == 1 and " day ago" or " days ago")
    end

    local dt  = os.date("*t", ts)
    local day = dt.day
    local suf = "th"
    if day % 10 == 1 and day ~= 11 then suf = "st"
    elseif day % 10 == 2 and day ~= 12 then suf = "nd"
    elseif day % 10 == 3 and day ~= 13 then suf = "rd" end
    local hr = dt.hour
    local ap = hr >= 12 and "pm" or "am"
    hr = hr % 12; if hr == 0 then hr = 12 end
    local date_str = string.format("%s %d%s, %d:%02d%s",
        MONTHS[dt.month], day, suf, hr, dt.min, ap)

    return string.format("Last seen in %s at %s, %s", loc, date_str, rel)
end

-- Expose so hud_element_player_notes.lua can record mission-context entries.
mod._fn_update_last_seen = update_last_seen

local function get_player_for_char(char_name)
    if not char_name or char_name == "" then return nil end
    return get_char_to_player()[char_name]
end

-- resolve_identifier: tries platform display name first, then character name.
-- Returns (puid, display_name, match_type) where match_type is "tag" or "character".
local function resolve_identifier(identifier)
    if not identifier or identifier == "" then return nil, nil, nil end

    -- 1. Platform display name (name_to_ids map — populated whenever a noted player is seen)
    local ids = get_ids_for_name(identifier)
    if ids and #ids > 0 then
        return ids[1], identifier, "tag"
    end

    -- 2. Character name (char_to_player map — populated from social roster + mission scans)
    local entry = get_player_for_char(identifier)
    if entry then
        return entry.puid, entry.display_name, "character"
    end

    return nil, nil, nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- HOVER STATE  (written by _draw_widgets hook, read by UIConstantElements hook)
-- ──────────────────────────────────────────────────────────────────────────────

mod._popup_puid              = nil
mod._editing_puid            = nil
mod._editing_name            = nil
mod._hovered_note            = nil   -- full note text (used by tooltip / fallback top bar)
mod._hovered_raw_name        = nil   -- raw account name (no note appended)
mod._hovered_last_seen_text  = nil   -- formatted "Last seen in X at Y, Z ago" for top bar
mod._hover_tx                = nil   -- tooltip x (UI base space)
mod._hover_ty                = nil   -- tooltip y (UI base space)
mod._hover_dyn_h             = nil   -- tooltip height for current note

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
-- WORLD MARKER TEMPLATE (inline — no require path needed)
-- Injected into HudElementWorldMarkers._marker_templates via Hook 9.
--
-- Only shown within 15 world-units (~15 m) so drift from 3D→2D projection
-- at long range is never visible and nearby-only is less cluttered.
-- The widget is a semi-transparent tooltip box (border + fill + text).
-- ──────────────────────────────────────────────────────────────────────────────

local _pn_world_note_size = { 280, 30 }

local _pn_world_marker_template = {
    name              = "pn_note",
    unit_node         = "j_head",
    position_offset   = { 0, 0, 0.4 },
    check_line_of_sight = false,
    max_distance      = 15,
    screen_clamp      = false,
    start_layer       = 302,
    size              = _pn_world_note_size,
    scale_settings = {
        distance_max = 15,
        distance_min = 5,
        scale_from   = 0.7,
        scale_to     = 1,
    },
    fade_settings = {
        default_fade    = 1,
        fade_from       = 0,
        fade_to         = 1,
        distance_max    = 15,
        distance_min    = 8,
        easing_function = math.ease_exp,
    },
    create_widget_defintion = function(tmpl, scenegraph_id)
        local W   = _pn_world_note_size[1]
        local H   = _pn_world_note_size[2]
        local PAD = 6
        return UIWidget.create_definition({
            -- Outer border (semi-transparent warm accent)
            {
                pass_type = "rect",
                style_id  = "pn_note_border",
                style     = {
                    color  = { 70, 200, 160, 80 },
                    offset = { -2, -2, 0 },
                    size   = { W + 4, H + 4 },
                },
            },
            -- Dark fill (semi-transparent)
            {
                pass_type = "rect",
                style_id  = "pn_note_bg",
                style     = {
                    color  = { 80, 8, 8, 8 },
                    offset = { 0, 0, 1 },
                    size   = { W, H },
                },
            },
            -- Note text: NO vertical_alignment/horizontal_alignment so all passes
            -- share the same origin (0,0) and the text renders inside the box.
            {
                pass_type = "text",
                style_id  = "pn_note_text",
                value_id  = "pn_note_text",
                value     = "",
                style     = {
                    text_horizontal_alignment = "center",
                    text_vertical_alignment   = "center",
                    word_wrap                 = true,
                    offset                    = { 0, 0, 2 },
                    font_type                 = "proxima_nova_bold",
                    font_size                 = 16,
                    default_font_size         = 16,
                    text_color                = { 130, 230, 210, 160 },
                    size                      = { W, H },
                },
            },
        }, scenegraph_id)
    end,
    on_enter = function(widget, marker)
        local data = marker.data
        widget.content.pn_note_text = (data and data.note) or ""
    end,
    on_exit = function(widget, marker)
        -- nothing to clean up
    end,
    update_function = function(parent, ui_renderer, widget, marker, tmpl, dt, t)
        local text  = widget.content.pn_note_text or ""
        local W_MAX = _pn_world_note_size[1]   -- 280

        -- Estimate rendered width (~8px per char for proxima_nova_bold @16)
        local est_w = math.max(60, math.min(W_MAX, #text * 8 + 20))

        -- Estimate height from line count (word_wrap active, ~8px per char)
        local chars_per_line = math.max(1, math.floor(est_w / 8))
        local num_lines      = math.max(1, math.ceil(#text / chars_per_line))
        local new_h          = math.max(30, num_lines * 20 + 10)

        -- Resize all box passes to match note content
        widget.style.pn_note_border.size[1] = est_w + 4
        widget.style.pn_note_border.size[2] = new_h + 4
        widget.style.pn_note_bg.size[1]     = est_w
        widget.style.pn_note_bg.size[2]     = new_h
        widget.style.pn_note_text.size[1]   = est_w
        widget.style.pn_note_text.size[2]   = new_h

        -- Center box horizontally on the projected anchor (matches nameplate center)
        widget.offset[1] = widget.offset[1] - est_w * 0.5

        -- Place box above the nameplate: push up by box height + fixed gap.
        -- Tune the 50 constant if the box clips the nameplate or floats too high.
        widget.offset[2] = widget.offset[2] - new_h - 30
    end,
}

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

mod:hook(CLASS.PlayerInfo, "user_display_name",
    function(func, self, ...)
        local name, color_override = func(self, ...)

        -- Populate puid and name caches. Never call mod:set here (per-frame cost).
        -- _puid_cache[self] = puid lets the hover loop look up the key without
        -- calling any native methods on player_info (which can crash natively
        -- for offline/cross-platform players when called every render frame).
        local puid = get_player_key(self)
        if puid then
            _puid_cache[self]  = puid
            _raw_names[puid]   = name
        end

        if self:is_own_player() then return name, color_override end

        -- Track character name → player mapping (hub context).
        -- Skip blocked players — character_name() returns a localized string for them.
        -- _known_chars ensures mod:set is only called once per unique (char, puid) pair.
        if puid and not self:is_blocked() then
            local char_name = self:character_name()
            if char_name and char_name ~= "" then
                update_char_to_player(char_name, puid, name, "hub")
            end
        end

        -- Try to get note using both puid and display name for ID mapping support
        local note = nil
        if puid then
            note = get_note(puid, name)
        else
            note = get_note_by_name(name)
        end
        
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
        local display_name = player_info:user_display_name(true, true)

        if not player_info:is_own_player() and puid then
            mod._popup_puid = puid

            -- Track character name → player mapping (hub context, exact same priority as roster).
            -- Skip blocked players — character_name() returns a localized string for them.
            if not player_info:is_blocked() then
                local char_name = player_info:character_name()
                if char_name and char_name ~= "" then
                    update_char_to_player(char_name, puid, display_name, "hub")
                end
            end

            -- Get note using both ID and name for mapping support
            local note    = get_note(puid, display_name)
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
    mod._popup_puid             = nil
    mod._editing_puid           = nil
    mod._editing_name           = nil
    mod._hovered_note           = nil
    mod._hovered_raw_name       = nil
    mod._hovered_last_seen_text = nil
    mod._hover_tx               = nil
    mod._hover_ty               = nil
    mod._hover_dyn_h            = nil
    _puid_cache = {}
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
        mod._hovered_note           = nil
        mod._hovered_raw_name       = nil
        mod._hovered_last_seen_text = nil
        mod._hover_tx               = nil
        mod._hover_ty               = nil
        mod._hover_dyn_h            = nil

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
                    -- Use _puid_cache to avoid any native method calls on player_info
                    -- during the render loop. is_own_player is a plain bool in content.
                    local pi   = w.content and w.content.player_info
                    local puid = pi and not w.content.is_own_player and _puid_cache[pi]
                    
                    -- Get raw name from cache or widget content
                    local raw_name = get_cached_name(puid)
                        or (w.content and w.content.account_name)
                        or "Player"
                    
                    -- Try to get note using both puid and display name for ID mapping support
                    local note = nil
                    if puid then
                        note = get_note(puid, raw_name)
                    else
                        note = get_note_by_name(raw_name)
                    end
                    
                    if note then
                        local dyn_h = compute_tooltip_height(note)

                        -- Position tooltip to the right; flip left if off-screen
                        local tx = wx + ww + 15
                        if tx + TT_W > sw then tx = wx - TT_W - 15 end
                        local ty = math.max(wy, 10)
                        ty = math.min(ty, sh - dyn_h - 10)

                        local bar_text = puid and format_last_seen_text(puid) or note
                        mod._cached_top_bar_text = raw_name .. "  —  " .. bar_text

                        mod._hovered_note           = note
                        mod._hovered_raw_name       = raw_name
                        mod._hovered_last_seen_text = puid and format_last_seen_text(puid) or nil
                        mod._hover_tx               = tx
                        mod._hover_ty               = ty
                        mod._hover_dyn_h            = dyn_h
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

    -- ── Alternative 2: top-left name + last-seen bar ────────────────────────────
    -- Shows "Name — Last seen in <location> at <date>, <rel>" when last-seen data
    -- is available; falls back to "Name — <note>" for players seen before this
    -- feature was added.
    if show_top_bar then
        local raw_name  = mod._hovered_raw_name or "Player"
        local bar_text  = mod._hovered_last_seen_text or note
        _pn_toptext_widget.content.label_text = mod._cached_top_bar_text
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
        mod._hovered_note           = nil
        mod._hovered_raw_name       = nil
        mod._hovered_last_seen_text = nil
        mod._hover_tx               = nil
        mod._hover_ty               = nil
        mod._hover_dyn_h            = nil

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

        local bar_text = puid and format_last_seen_text(puid) or note
        mod._cached_top_bar_text = mod._hovered_raw_name .. "  —  " .. bar_text

        mod._hovered_note           = note
        mod._hovered_raw_name       = get_cached_name(puid)
                                   or player_info:user_display_name()
                                   or "Player"
        mod._hovered_last_seen_text = puid and format_last_seen_text(puid) or nil
        mod._hover_tx               = tx
        mod._hover_ty               = ty
        mod._hover_dyn_h            = dyn_h
    end
)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 8: Cleanup on GroupFinderView close
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook_safe(CLASS.GroupFinderView, "on_exit", function(self, ...)
    mod._hovered_note           = nil
    mod._hovered_raw_name       = nil
    mod._hovered_last_seen_text = nil
    mod._hover_tx               = nil
    mod._hover_ty               = nil
    mod._hover_dyn_h            = nil
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- COMMAND: /note <text>
-- ──────────────────────────────────────────────────────────────────────────────

mod:command("note", "Save a note for the last selected player through the 'Social' window.", function(...)
    local args = { ... }
    if #args == 0 then mod:echo(STR_USAGE_NOTE); return end
    if not mod._editing_puid then mod:echo(STR_NONE_SEL); return end
    local text = table.concat(args, " ")
    -- Pass display_name to save_note for ID mapping support
    save_note(mod._editing_puid, text, mod._editing_name)
    mod:echo(string.format(STR_SAVED, mod._editing_name or "player"))
    mod._editing_puid = nil
    mod._editing_name = nil
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- COMMAND: /pn_notes — list all saved notes
-- ──────────────────────────────────────────────────────────────────────────────

mod:command("pn_notes", "List all saved PlayerNotes.", function()
    local notes = get_notes()
    local name_to_ids = get_name_to_ids()
    
    -- Group notes by player name (handles multiple IDs per player)
    local grouped_notes = {}
    for puid, note in pairs(notes) do
        if note and note ~= "" then
            local display_name = get_cached_name(puid) or puid
            if not grouped_notes[display_name] then
                grouped_notes[display_name] = {note = note, ids = {puid}}
            else
                -- Check if this is a different note for the same name
                if note ~= grouped_notes[display_name].note then
                    table.insert(grouped_notes[display_name].ids, puid)
                end
            end
        end
    end
    
    -- Display grouped notes
    local count = 0
    for display_name, data in pairs(grouped_notes) do
        count = count + 1
        local id_str = table.concat(data.ids, ", ")
        mod:echo(string.format("[%d] %s → %s", count, display_name, data.note))
        if #data.ids > 1 then
            mod:echo(string.format("    IDs: %s", id_str))
        end
    end
    
    if count == 0 then mod:echo("No notes saved yet.") end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 9: Inject "pn_note" template into HudElementWorldMarkers
--
-- HudElementWorldMarkers.init populates self._marker_templates from a static
-- settings list. We inject our template after that loop runs so that
-- "add_world_marker_unit" events with type "pn_note" are handled correctly.
--
-- Fires each time a hub/mission is entered (HUD is recreated per session).
-- String form used (not CLASS.) because HUD element classes may not be
-- registered in the CLASS global.
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook_safe("HudElementWorldMarkers", "init", function(self)
    self._marker_templates[_pn_world_marker_template.name] = _pn_world_marker_template
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 10: Register HudElementPlayerNotes via DMF's proper HUD element API
--
-- mod:register_hud_element() wraps injection in safe_call_nrc, so a missing
-- or broken element file logs a DMF error instead of crashing the game.
-- It also calls add_require_path internally at injection time, and handles
-- lifecycle events (mod disable, HUD recreation) automatically.
--
-- visibility_groups = { "alive" }: active when the player character is alive,
-- which covers both missions and the hub (health extension is present in hub).
-- ──────────────────────────────────────────────────────────────────────────────

mod:register_hud_element({
    class_name        = "HudElementPlayerNotes",
    filename          = _PN_HUD_ELEMENT_PATH,
    use_hud_scale     = true,
    visibility_groups = { "alive" },
})

-- ──────────────────────────────────────────────────────────────────────────────
-- LIFECYCLE
-- ──────────────────────────────────────────────────────────────────────────────

-- ──────────────────────────────────────────────────────────────────────────────
-- COMMAND: /set_note <identifier> <text...>
--
-- Sets a note without needing to right-click first. The identifier can be:
--   • A platform player tag  — e.g. Potty#1031  or  Ayas1260
--   • A character name       — e.g. KimJongDois  or  OldWitch
--
-- Lookup order:
--   1. name_to_ids map   (populated whenever a noted player is visible in Social)
--   2. char_to_player map (populated from Social roster and mission scans)
--
-- If unrecognised, the player must first be seen in the Social panel or in a
-- mission so the mod can build the mapping.
-- ──────────────────────────────────────────────────────────────────────────────

mod:command("set_note", "<player_tag_or_character_name> <note> | Set a note for a player by their player tag or character name.", function(...)
    local args = { ... }
    if #args < 2 then
        mod:echo("Usage: /set_note <player_tag_or_character_name> <note text>")
        mod:echo("  e.g. /set_note Potty#1031 great psyker for havoc 40")
        mod:echo("       /set_note KimJongDois great psyker for havoc 40")
        return
    end

    local identifier             = args[1]
    local text                   = table.concat(args, " ", 2)
    local puid, display_name, match_type = resolve_identifier(identifier)

    if not puid then
        mod:echo(string.format("[PlayerNotes] Unknown: '%s'.", identifier))
        mod:echo("Tip: right-click the player in Social panel first, or use their full tag (e.g. Potty#1031).")
        return
    end

    save_note(puid, text, display_name)

    if match_type == "character" then
        mod:echo(string.format("Note saved for %s (character of %s).", identifier, display_name or "?"))
    else
        mod:echo(string.format("Note saved for %s.", display_name or identifier))
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- COMMAND: /delete_note <identifier>
--
-- Removes the note for a player. The identifier can be:
--   • A platform player tag  — e.g. Potty#1031  or  Ayas1260
--   • A character name       — e.g. KimJongDois  or  OldWitch
--
-- Lookup order:
--   1. name_to_ids map   (player tag exact match)
--   2. char_to_player map (character name), where mission context beats hub
--      and more recently seen characters beat older ones within the same context.
-- ──────────────────────────────────────────────────────────────────────────────

mod:command("delete_note", "<player_tag_or_character_name> | Delete the note for a player by their player tag or character name.", function(...)
    local args = { ... }
    if #args == 0 then
        mod:echo("Usage: /delete_note <player_tag_or_character_name>")
        mod:echo("  e.g. /delete_note Potty#1031")
        mod:echo("       /delete_note KimJongDois")
        return
    end

    local identifier                    = args[1]
    local puid, display_name, match_type = resolve_identifier(identifier)

    if not puid then
        mod:echo(string.format("[PlayerNotes] Unknown: '%s'.", identifier))
        mod:echo("Tip: right-click the player in Social panel first, or use their full tag (e.g. Potty#1031).")
        return
    end

    local existing_note = get_note(puid, display_name)
    if not existing_note or existing_note == "" then
        if match_type == "character" then
            mod:echo(string.format("[PlayerNotes] No note found for %s (character of %s).", identifier, display_name or "?"))
        else
            mod:echo(string.format("[PlayerNotes] No note found for %s.", display_name or identifier))
        end
        return
    end

    save_note(puid, nil, display_name)

    if match_type == "character" then
        mod:echo(string.format("Note deleted for %s (character of %s).", identifier, display_name or "?"))
    else
        mod:echo(string.format("Note deleted for %s.", display_name or identifier))
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- COMMAND: /pn_chars — list the character-name → player-tag map
-- ──────────────────────────────────────────────────────────────────────────────

mod:command("pn_chars", "List known character-name to player-tag mappings.", function()
    local map = get_char_to_player()
    local count = 0
    for char_name, entry in pairs(map) do
        count = count + 1
        mod:echo(string.format("[%d] %s → %s (%s)",
            count, char_name,
            entry.display_name or entry.puid or "?",
            entry.context or "?"))
    end
    if count == 0 then
        mod:echo("No character mappings recorded yet. Play a mission or open the Social panel.")
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- COMMAND: /pn_notes_delete_all — wipe all notes and the name cache
-- ──────────────────────────────────────────────────────────────────────────────

mod:command("pn_notes_delete_all", "Delete ALL saved PlayerNotes and reset the name cache.", function()
    -- Use nil (not {}) to remove the key entirely — avoids passing an empty
    -- table to the native SJSON serializer, which can cause a silent crash.
    mod:set("player_notes", nil)
    mod:set("player_names", nil)
    mod:set("name_to_ids", nil)
    mod:set("char_to_player", nil)
    mod:set("player_last_seen", nil)
    -- Reset all in-memory persistence caches (closures over these upvalues
    -- automatically see the new tables — mod._fn_get_notes() included).
    _notes_cache          = {}
    _names_cache          = {}
    _name_to_ids_cache    = {}
    _char_to_player_cache = {}
    _last_seen_cache      = {}
    -- Reset session caches
    _raw_names   = {}
    _puid_cache  = setmetatable({}, { __mode = "k" })
    _known_chars = {}
    _session_seen = {}
    mod:echo("[PlayerNotes] All notes and name cache cleared.")
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- LIFECYCLE
-- ──────────────────────────────────────────────────────────────────────────────

-- Clear per-session last-seen guard when leaving a game state (mission or hub).
-- This ensures re-entering a map records a fresh timestamp.
mod.on_game_state_changed = function(status, state_name)
    if status == "exit" then
        _session_seen = {}
        -- Reset the flag when leaving the map
        mod._notification_done_for_session = false
    elseif status == "enter" then
        -- We use mod._notification_timer so the HUD file can see it
        mod._notification_timer = 3.0
    end
end

mod.on_all_mods_loaded = function()
    mod:echo("[PlayerNotes] v2.7.0 Loaded. /note /set_note /delete_note /pn_notes /pn_chars /pn_notes_delete_all")
end
