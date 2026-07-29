--[[
    PlayerNotes
    Author: Eduardo
    Version: 2.10.0

    Add persistent notes to any player visible in the Social panel or Party Finder.
    Three complementary display mechanisms configured through F4 Mod Options:

    1. Roster indicator — inline note preview, or a compact icon when preview text is off.
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
local ButtonPassTemplates = require("scripts/ui/pass_templates/button_pass_templates")

-- ──────────────────────────────────────────────────────────────────────────────
-- WORLD NOTES — path used as the element filename in register_hud_element.
-- DMF resolves it to the dedicated HUD scanner module; the marker template
-- rendered by Darktide's world-marker element is defined in this file.
-- ──────────────────────────────────────────────────────────────────────────────

local _PN_HUD_ELEMENT_PATH  = "PlayerNotes/scripts/mods/PlayerNotes/hud_element_player_notes"

-- ──────────────────────────────────────────────────────────────────────────────
-- CONSTANTS
-- ──────────────────────────────────────────────────────────────────────────────

local STR_BTN_ADD    = mod:localize("btn_add_note")
local STR_NONE_SEL   = mod:localize("echo_none_selected")
local STR_USAGE_NOTE = mod:localize("echo_usage_note")

-- Notes are entered through chat, but persisted data may predate any chat-side
-- limit. Bound text by Unicode characters so malformed/imported settings cannot
-- create extremely large widgets or permanently grow the settings file.
local MAX_NOTE_CHARACTERS       = 512
local WORLD_NOTE_MAX_CHARACTERS = 160
local TOP_BAR_NOTE_MAX_CHARACTERS = 96
local MAX_LOCATION_CHARACTERS   = 160
local MAX_TOOLTIP_HEIGHT        = 360
local IDENTITY_MISS_RETRY_SECONDS = 1
local OVERLAY_INIT_RETRY_SECONDS  = 5

-- char_to_player LRU eviction cap.
-- When the table reaches CHAR_CACHE_MAX, a batch eviction trims it to CHAR_CACHE_TRIM_TO.
-- Batch eviction amortizes the sort cost: one sort every ~50 new characters instead of
-- one per character after the cap. Hub-context entries are evicted before mission-context
-- entries of the same age so hard-earned mission observations survive longer.
local CHAR_CACHE_MAX     = 250
local CHAR_CACHE_TRIM_TO = 200

-- Tooltip dimensions
-- Height is computed dynamically per note; TT_H_MIN is the floor.
local TT_W     = 340
local TT_H_MIN = 44
local TT_PAD   = 10
local TT_Z     = 997

-- Top-text bar dimensions
-- Width increased to 860 to fit "Name — Last seen in <mission> (<difficulty>) at <date>, <rel>" text.
local A2_W   = 860
local A2_H   = 34
local A2_X   = 30
local A2_Y   = 20

local function utf8_codepoint_width(text, position)
    local first_byte = string.byte(text, position)
    if not first_byte or first_byte < 128 then return 1 end

    local width
    if first_byte >= 194 and first_byte <= 223 then
        width = 2
    elseif first_byte >= 224 and first_byte <= 239 then
        width = 3
    elseif first_byte >= 240 and first_byte <= 244 then
        width = 4
    else
        return 1
    end

    if position + width - 1 > #text then return 1 end
    for offset = 1, width - 1 do
        local continuation = string.byte(text, position + offset)
        if not continuation or continuation < 128 or continuation >= 192 then
            return 1
        end
    end
    return width
end

local function text_length(text)
    if type(text) ~= "string" then return 0 end

    local utf8 = rawget(_G, "Utf8")
    if utf8 and utf8.string_length then
        local ok, length = pcall(utf8.string_length, text)
        if ok and type(length) == "number" then return length end
    end

    local count = 0
    local position = 1
    while position <= #text do
        position = position + utf8_codepoint_width(text, position)
        count = count + 1
    end
    return count
end

local function truncate_text(text, max_characters, suffix)
    if type(text) ~= "string" then return "" end
    if text_length(text) <= max_characters then return text end

    suffix = suffix or ""
    local utf8 = rawget(_G, "Utf8")
    if utf8 and utf8.sub_string then
        local ok, truncated = pcall(utf8.sub_string, text, 1, max_characters)
        if ok and truncated then return truncated .. suffix end
    end

    -- Pure-Lua fallback for test environments where Darktide's Utf8 helper is
    -- not loaded. Invalid byte sequences count as one replacement-sized unit.
    local count = 0
    local position = 1
    local last_byte = 0
    while position <= #text and count < max_characters do
        local width = utf8_codepoint_width(text, position)
        last_byte = position + width - 1
        position = position + width
        count = count + 1
    end
    return text:sub(1, last_byte) .. suffix
end

local function normalize_note_text(text)
    if type(text) ~= "string" then return nil, false end

    text = text:match("^%s*(.-)%s*$")
    if text == "" then return nil, false end

    local was_truncated = text_length(text) > MAX_NOTE_CHARACTERS
    if was_truncated then
        text = truncate_text(text, MAX_NOTE_CHARACTERS)
    end

    return text, was_truncated
end

-- ──────────────────────────────────────────────────────────────────────────────
-- TOOLTIP HEIGHT CALCULATION
-- Approximates word-wrapped line count for proxima_nova_bold at font_size 16
-- in a box of width (TT_W - 2*TT_PAD).
-- ──────────────────────────────────────────────────────────────────────────────

local function compute_tooltip_height(text)
    -- ~8px average char width for proxima_nova_bold at size 16
    local chars_per_line = math.floor((TT_W - TT_PAD * 2) / 8)
    local line_h         = 22   -- px per line including leading
    local lines          = math.max(1, math.ceil(text_length(text) / chars_per_line))
    -- TT_PAD top + line content + TT_PAD bottom + a little extra breathing room
    return math.min(MAX_TOOLTIP_HEIGHT, math.max(TT_H_MIN, lines * line_h + TT_PAD * 2 + 6))
end

-- ──────────────────────────────────────────────────────────────────────────────
-- CACHES  (must be declared before any function that references them)
-- _raw_names:  puid → raw platform display name (no note appended)
-- _puid_cache: player_info object reference → puid
--   "puid" is retained as a legacy internal name; values are canonical account
--   IDs in 2.10, with platform IDs used only as a compatibility fallback.
--   Avoids calling platform_user_id()/account_id() in the per-frame hover loop.
--   Missing identities and temporary platform-only fallbacks are retried after
--   a short cooldown because PlayerInfo can be populated in-place during loading.
--   Weak keys: allows the GC to collect stale player_info refs without waiting
--   for on_exit (handles abnormal view teardown).
-- ──────────────────────────────────────────────────────────────────────────────

local _raw_names  = {}
local _puid_cache = setmetatable({}, { __mode = "k" })
local _puid_is_fallback = setmetatable({}, { __mode = "k" })
local _puid_retry_after = setmetatable({}, { __mode = "k" })
local _roster_identity_ready = setmetatable({}, { __mode = "k" })
local _roster_identity_retry_after = setmetatable({}, { __mode = "k" })
-- Dedup guard: prevents calling mod:set for an already-persisted (char_name, puid) pair.
-- Nested keys avoid allocating char_name.."\0"..puid strings on repeated observations.
-- Cleared on game-state exit and by pn_notes_delete_all.
local _known_chars = {}
local _api = {}
local _is_enabled = true
mod._api = _api
_api.is_enabled = function() return _is_enabled end

-- ──────────────────────────────────────────────────────────────────────────────
-- PERSISTENCE CACHES
-- DMF's mod:get() calls table.clone() on every invocation for table-typed
-- settings — expensive in per-frame hooks. Load each table once at module init
-- and keep a live reference. Mutate in-place; call mod:set() only when data
-- actually changes so DMF snapshots the current state for disk persistence.
-- Scalar settings are cached separately below for hot draw/update paths.
-- ──────────────────────────────────────────────────────────────────────────────

local function load_table_setting(setting_id)
    local value = mod:get(setting_id)
    return type(value) == "table" and value or {}
end

local _notes_cache          = load_table_setting("player_notes")
local _names_cache          = load_table_setting("player_names")
local _name_to_ids_cache    = load_table_setting("name_to_ids")
local _char_to_player_cache = load_table_setting("char_to_player")
local _last_seen_cache      = load_table_setting("player_last_seen")
local _session_seen         = {}
local _stored_player_ids    = {}
local _notes_dirty          = false
local _names_dirty          = false
local _name_to_ids_dirty    = false
local _char_to_player_dirty = false
local _last_seen_dirty      = false
local flush_persistence
local get_note
local get_cached_player_key

-- Scalar settings are read by UI draw and HUD update paths. Cache them and
-- refresh only the changed entry from mod.on_setting_changed.
local _settings = {
    show_inline                  = mod:get("show_inline") == true,
    show_top_bar                 = mod:get("show_top_bar") ~= false,
    show_tooltip                 = mod:get("show_tooltip") ~= false,
    show_world_notes             = mod:get("show_world_notes") ~= false,
    show_world_notes_in_missions = mod:get("show_world_notes_in_missions") == true,
    show_session_notifications   = mod:get("show_session_notifications") ~= false,
    enable_debug_echo            = mod:get("enable_debug_echo") == true,
}
_api.settings = _settings

-- Invalidates rendered-name and hover caches when notes or inline mode change.
local _notes_revision = 0

local function valid_player_id(player_id)
    local value_type = type(player_id)
    return (value_type == "string" or value_type == "number") and player_id ~= ""
end

-- Harden persisted data from older builds or manual settings edits. Invalid
-- entries are ignored and oversized notes are normalized once, then flushed.
for player_id, note in pairs(_notes_cache) do
    local normalized_note = normalize_note_text(note)
    if not valid_player_id(player_id) or normalized_note == nil then
        _notes_cache[player_id] = nil
        _notes_dirty = true
    elseif normalized_note ~= note then
        _notes_cache[player_id] = normalized_note
        _notes_dirty = true
    end
end

for player_id, display_name in pairs(_names_cache) do
    if not valid_player_id(player_id)
        or type(display_name) ~= "string"
        or display_name == "" then
        _names_cache[player_id] = nil
        _names_dirty = true
    end
end

for display_name, id_list in pairs(_name_to_ids_cache) do
    if type(display_name) ~= "string"
        or display_name == ""
        or type(id_list) ~= "table" then
        _name_to_ids_cache[display_name] = nil
        _name_to_ids_dirty = true
    else
        local normalized_ids = {}
        local seen_ids = {}
        local stored_entry_count = 0
        for key in pairs(id_list) do
            stored_entry_count = stored_entry_count + 1
            if type(key) ~= "number"
                or key < 1
                or key % 1 ~= 0 then
                _name_to_ids_dirty = true
            end
        end
        for _, player_id in ipairs(id_list) do
            if valid_player_id(player_id) and not seen_ids[player_id] then
                seen_ids[player_id] = true
                normalized_ids[#normalized_ids + 1] = player_id
            else
                _name_to_ids_dirty = true
            end
        end
        if #normalized_ids == 0 then
            _name_to_ids_cache[display_name] = nil
            _name_to_ids_dirty = true
        elseif #normalized_ids ~= #id_list
            or #normalized_ids ~= stored_entry_count then
            _name_to_ids_cache[display_name] = normalized_ids
            _name_to_ids_dirty = true
        end
    end
end

for char_name, entry in pairs(_char_to_player_cache) do
    if type(char_name) ~= "string"
        or char_name == ""
        or type(entry) ~= "table"
        or not valid_player_id(entry.puid) then
        _char_to_player_cache[char_name] = nil
        _char_to_player_dirty = true
    else
        if type(entry.display_name) ~= "string" then
            entry.display_name = ""
            _char_to_player_dirty = true
        end
        local timestamp = tonumber(entry.last_seen)
        if timestamp == nil or timestamp < 0 then
            entry.last_seen = 0
            _char_to_player_dirty = true
        elseif timestamp ~= entry.last_seen then
            entry.last_seen = timestamp
            _char_to_player_dirty = true
        end
        if entry.context ~= "mission" and entry.context ~= "hub" then
            entry.context = "hub"
            _char_to_player_dirty = true
        end
    end
end

for player_id, entry in pairs(_last_seen_cache) do
    local timestamp = type(entry) == "table" and tonumber(entry.ts) or nil
    if not valid_player_id(player_id)
        or _notes_cache[player_id] == nil
        or type(entry) ~= "table"
        or timestamp == nil
        or timestamp < 0
        or timestamp ~= timestamp
        or math.abs(timestamp) == math.huge
        or type(entry.loc) ~= "string"
        or entry.loc == "" then
        _last_seen_cache[player_id] = nil
        _last_seen_dirty = true
    else
        if timestamp ~= entry.ts then
            entry.ts = timestamp
            _last_seen_dirty = true
        end
        local normalized_location = truncate_text(
            entry.loc,
            MAX_LOCATION_CHARACTERS,
            "..."
        )
        if normalized_location ~= entry.loc then
            entry.loc = normalized_location
            _last_seen_dirty = true
        end
    end
end

local function rebuild_stored_player_ids()
    _stored_player_ids = {}
    for player_id in pairs(_notes_cache) do _stored_player_ids[player_id] = true end
    for player_id in pairs(_names_cache) do _stored_player_ids[player_id] = true end
    for player_id in pairs(_last_seen_cache) do _stored_player_ids[player_id] = true end
    for _, id_list in pairs(_name_to_ids_cache) do
        if type(id_list) == "table" then
            for _, player_id in ipairs(id_list) do
                if valid_player_id(player_id) then
                    _stored_player_ids[player_id] = true
                end
            end
        end
    end
    for _, entry in pairs(_char_to_player_cache) do
        if type(entry) == "table" and valid_player_id(entry.puid) then
            _stored_player_ids[entry.puid] = true
        end
    end
end
rebuild_stored_player_ids()

mod._cached_top_bar_text = ""

mod._notification_done_for_session = false

mod._last_hover_time = 0

-- ──────────────────────────────────────────────────────────────────────────────
-- PERSISTENCE
-- ──────────────────────────────────────────────────────────────────────────────

local function get_notes()       return _notes_cache end
local function get_name_to_ids() return _name_to_ids_cache end

local function update_name_to_ids(display_name, puid)
    if type(display_name) ~= "string"
        or display_name == ""
        or not valid_player_id(puid) then
        return false
    end
    local id_list = _name_to_ids_cache[display_name]
    if type(id_list) ~= "table" then
        id_list = {}
    end

    -- Avoid duplicates
    for _, id in ipairs(id_list) do
        if id == puid then return false end
    end
    table.insert(id_list, puid)
    _name_to_ids_cache[display_name] = id_list
    _stored_player_ids[puid] = true
    _name_to_ids_dirty = true
    return true
end

local function save_note(puid, text, display_name)
    if not valid_player_id(puid) then
        mod:echo("[PlayerNotes] ERROR: cannot save note — player key is nil/empty.")
        return
    end

    local normalized_text, was_truncated = normalize_note_text(text)
    local changed = _notes_cache[puid] ~= normalized_text

    local mapping_changed = false
    if normalized_text then
        _notes_cache[puid] = normalized_text
        _stored_player_ids[puid] = true
        mapping_changed = update_name_to_ids(display_name, puid)
    else
        _notes_cache[puid] = nil
        if _last_seen_cache[puid] ~= nil then
            _last_seen_cache[puid] = nil
            _last_seen_dirty = true
        end
        _session_seen[puid] = nil
    end

    if changed or mapping_changed then
        _notes_revision = _notes_revision + 1
    end
    if changed then
        _notes_dirty = true
    end

    if flush_persistence then flush_persistence() end
    return changed or mapping_changed, was_truncated
end

local function safe_method(object, method_name, ...)
    local method = object and object[method_name]
    if type(method) ~= "function" then return nil end

    local ok, value, secondary = pcall(method, object, ...)
    if not ok then return nil end
    return value, secondary
end

local function get_player_display_name(player_info, use_stale, no_platform_icon)
    local name = safe_method(player_info, "user_display_name", use_stale, no_platform_icon)
    return type(name) == "string" and name ~= "" and name or nil
end

local function notify_noted_players_in_session()
    if mod._notification_done_for_session then return true end

    if not _settings.show_session_notifications then
        mod._notification_done_for_session = true
        return true
    end

    local managers = rawget(_G, "Managers")
    local player_manager = managers and managers.player
    local event_manager = managers and managers.event
    local social_service = managers and managers.data_service and managers.data_service.social
    if not player_manager or not event_manager or not social_service then return false end

    local players = safe_method(player_manager, "players")
    local local_player = safe_method(player_manager, "local_player", 1)
    if type(players) ~= "table" or not local_player then return false end
    
    local noted_list = {}
    local unresolved_player = false

    for _, player in pairs(players) do
        -- SKIP the local player
        if player ~= local_player
            and safe_method(player, "is_human_controlled") ~= false then
            local account_id = safe_method(player, "account_id")
            
            -- Only proceed if we have an account ID
            if account_id then
                local player_info = safe_method(
                    social_service,
                    "get_player_info_by_account_id",
                    account_id
                )
                
                -- Only proceed if the social service has the player's info
                if player_info then
                    local puid = get_cached_player_key(player_info)
                    local tag = get_player_display_name(player_info, true, true)
                    local note = puid and get_note(puid)
                    
                    -- If they are in our notes cache, add them to the list
                    if note then
                        local char_name = safe_method(player, "name") or "Unknown"
                        tag = tag or "Unknown"
                        table.insert(noted_list, string.format("%s(%s)", char_name, tag))
                    elseif not puid then
                        unresolved_player = true
                    end
                else
                    unresolved_player = true
                end
            else
                unresolved_player = true
            end
        end
    end

    local count = #noted_list
    if count == 0 then
        if unresolved_player then return false end
        mod._notification_done_for_session = true
        return true
    end

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
    local trigger = event_manager.trigger
    if type(trigger) ~= "function" then return false end
    local trigger_ok = pcall(trigger, event_manager, "event_add_notification_message", "custom", {
        line_1 = line_1,
        line_1_color = { 255, 255, 255, 255 },
        line_2 = line_2,
        line_2_color = { 200, 200, 200, 255 },
        line_3 = line_3,
        line_3_color = { 200, 200, 200, 255 },
    })
    if not trigger_ok then return false end

    mod._notification_done_for_session = true
    return true
end

_api.notify_players = notify_noted_players_in_session

-- Notes are identity-bound. Display names are intentionally not used as a
-- fallback because they are neither unique nor immutable.
get_note = function(puid)
    local notes = get_notes()
    if puid and puid ~= "" then
        local note = notes[puid]
        if type(note) == "string" and note ~= "" then return note end
    end
    return nil
end

_api.get_note = get_note
_api.get_player_display_name = get_player_display_name

-- ──────────────────────────────────────────────────────────────────────────────
-- PLAYER KEY
-- Darktide's account_id is the cross-platform backend identity and is preferred.
-- Existing platform-ID notes are migrated when both IDs are visible together.
-- ──────────────────────────────────────────────────────────────────────────────

local function migrate_player_id(alias_id, canonical_id)
    if not alias_id or alias_id == "" or not canonical_id or canonical_id == ""
        or alias_id == canonical_id then
        return
    end
    if not _stored_player_ids[alias_id] then return end

    local note_changed = false
    local alias_note = _notes_cache[alias_id]
    if _notes_cache[canonical_id] == nil
        and type(alias_note) == "string"
        and alias_note ~= "" then
        _notes_cache[canonical_id] = alias_note
        _notes_dirty = true
        note_changed = true
    end
    if alias_note ~= nil then
        _notes_cache[alias_id] = nil
        _notes_dirty = true
        note_changed = true
    end

    local alias_name = _names_cache[alias_id]
    if _names_cache[canonical_id] == nil and type(alias_name) == "string" then
        _names_cache[canonical_id] = alias_name
        _names_dirty = true
    end
    if alias_name ~= nil then
        _names_cache[alias_id] = nil
        _names_dirty = true
    end

    local alias_seen = _last_seen_cache[alias_id]
    local canonical_seen = _last_seen_cache[canonical_id]
    if type(alias_seen) == "table"
        and (type(canonical_seen) ~= "table"
            or (tonumber(alias_seen.ts) or 0) > (tonumber(canonical_seen.ts) or 0)) then
        _last_seen_cache[canonical_id] = alias_seen
        _last_seen_dirty = true
    end
    if alias_seen ~= nil then
        _last_seen_cache[alias_id] = nil
        _last_seen_dirty = true
    end

    for _, id_list in pairs(_name_to_ids_cache) do
        if type(id_list) == "table" then
            local found_alias = false
            local found_canonical = false
            for i = #id_list, 1, -1 do
                local id = id_list[i]
                if id == alias_id then
                    found_alias = true
                    table.remove(id_list, i)
                elseif id == canonical_id then
                    found_canonical = true
                end
            end
            if found_alias then
                if not found_canonical then id_list[#id_list + 1] = canonical_id end
                _name_to_ids_dirty = true
            end
        end
    end

    for _, entry in pairs(_char_to_player_cache) do
        if type(entry) == "table" and entry.puid == alias_id then
            entry.puid = canonical_id
            _char_to_player_dirty = true
        end
    end

    if note_changed then
        _notes_revision = _notes_revision + 1
    end
    _stored_player_ids[alias_id] = nil
    _stored_player_ids[canonical_id] = true
end

local function get_player_key(player_info)
    if not player_info then return nil end

    local account_id = safe_method(player_info, "account_id")
    local platform_id = safe_method(player_info, "platform_user_id")

    account_id = valid_player_id(account_id) and account_id or nil
    platform_id = valid_player_id(platform_id) and platform_id or nil

    if account_id and platform_id then
        migrate_player_id(platform_id, account_id)
    end

    return account_id or platform_id, account_id == nil and platform_id ~= nil
end

get_cached_player_key = function(player_info)
    if not player_info then return nil end

    local cached_puid = _puid_cache[player_info]
    if cached_puid and cached_puid ~= false and not _puid_is_fallback[player_info] then
        return cached_puid
    end

    local now = os.time()
    if now < (_puid_retry_after[player_info] or 0) then
        return cached_puid or nil
    end

    local puid, is_fallback = get_player_key(player_info)
    _puid_cache[player_info] = puid or false
    _puid_is_fallback[player_info] = is_fallback or nil
    _puid_retry_after[player_info] = (not puid or is_fallback)
        and now + IDENTITY_MISS_RETRY_SECONDS
        or nil
    return puid
end

_api.get_player_key = get_cached_player_key

-- ──────────────────────────────────────────────────────────────────────────────
-- NAME CACHE
-- Persisted so /pn_notes can show readable names even after a restart.
-- Also maintains bidirectional mapping: id→name AND name→[list of ids]
-- ──────────────────────────────────────────────────────────────────────────────

local function save_player_name(key, name)
    if not valid_player_id(key)
        or type(name) ~= "string"
        or name == "" then
        return
    end
    if _names_cache[key] == name then return end
    _names_cache[key] = name
    _stored_player_ids[key] = true
    _names_dirty = true
    _raw_names[key] = name
    if flush_persistence then flush_persistence() end
end

local function get_cached_name(key)
    if not key or key == "" then return nil end
    return _raw_names[key] or _names_cache[key]
end

-- Get all IDs associated with a display name
local function get_ids_for_name(display_name)
    if not display_name or display_name == "" then return nil end
    local ids = get_name_to_ids()[display_name]
    return type(ids) == "table" and ids or nil
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
        if type(char_name) == "string"
            and char_name ~= ""
            and type(entry) == "table"
            and entry.puid ~= nil
            and entry.puid ~= "" then
            entries[#entries + 1] = { key = char_name, entry = entry }
        else
            _char_to_player_cache[char_name] = nil
            _char_to_player_dirty = true
        end
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

    -- Make room for the pending insertion and finish at exactly TRIM_TO.
    local to_remove = count - CHAR_CACHE_TRIM_TO + 1
    for i = 1, to_remove do
        local char_name = entries[i].key
        _char_to_player_cache[char_name] = nil
        _known_chars[char_name] = nil
    end
    rebuild_stored_player_ids()
end

local function update_char_to_player(char_name, puid, display_name, context)
    if type(char_name) ~= "string" or char_name == "" then return end
    if not valid_player_id(puid) then return end
    display_name = type(display_name) == "string" and display_name or ""
    context = context == "mission" and "mission" or "hub"

    local known_ids = _known_chars[char_name]
    local known_context = known_ids and known_ids[puid]
    if known_context == "mission" or known_context == context then return end

    local existing = _char_to_player_cache[char_name]

    -- Refresh the LRU timestamp once per player/context observation. The dirty
    -- table is persisted once after the containing roster draw or HUD scan.
    if existing and existing.puid == puid
        and (existing.context == "mission" or existing.context == context) then
        existing.last_seen = os.time()
        _char_to_player_dirty = true
        if display_name and display_name ~= ""
            and existing.display_name ~= display_name then
            existing.display_name = display_name
        end
        known_ids = known_ids or {}
        known_ids[puid] = context
        _known_chars[char_name] = known_ids
        return
    end

    -- Mission beats hub: never let a hub observation overwrite a mission entry.
    if existing and existing.context == "mission" and context == "hub" then
        known_ids = known_ids or {}
        known_ids[puid] = "hub"
        _known_chars[char_name] = known_ids
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
    _stored_player_ids[puid] = true
    _char_to_player_dirty = true
    known_ids = known_ids or {}
    known_ids[puid] = context
    _known_chars[char_name] = known_ids
end

_api.update_char = update_char_to_player

-- ──────────────────────────────────────────────────────────────────────────────
-- LAST-SEEN TRACKING
--
-- _last_seen_cache: puid → { ts = <unix timestamp>, loc = <location string> }
--   Persisted across sessions via mod:set("player_last_seen").
--   Location string examples: "Mourningstar", "Vigil Station Oblivium (Havoc 40)",
--   "Smelter Complex (Auric)", "Archives (Auric Maelstrom)".
--
-- _session_seen: puid → last update timestamp (in-memory only, not persisted)
--   Throttles repeated last-seen updates for the same player and location.
--   Cleared on game-state exit so re-entering a map records a fresh timestamp.
-- ──────────────────────────────────────────────────────────────────────────────

local MONTHS = {"Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"}

local function update_last_seen(puid, location)
    if not valid_player_id(puid) then return end
    if type(location) ~= "string" or location == "" then return end
    location = truncate_text(location, MAX_LOCATION_CHARACTERS, "...")
    
    local now = os.time()
    local last_update = _session_seen[puid] or 0
    local last_entry = _last_seen_cache[puid]
    
    -- SMART THROTTLE LOGIC:
    -- 1. If the location has changed (e.g., Hub -> Mission), update IMMEDIATELY.
    -- 2. If the location is the same, only update if 300 seconds have passed.
    local location_changed = type(last_entry) ~= "table" or last_entry.loc ~= location
    local timer_expired = (now - last_update) >= 300

    if not location_changed and not timer_expired then 
        return 
    end
    
    _last_seen_cache[puid] = { ts = now, loc = location }
    _last_seen_dirty = true
    _session_seen[puid] = now 
end

-- Format a last-seen entry as a human-readable string.
-- Returns nil if no entry exists for puid.
-- Example output: "Last seen in Vigil Station Oblivium (Havoc 40) at Mar 11th, 12:37pm, 2 days ago"
local function format_last_seen_text(puid)
    if not puid then return nil end
    local entry = _last_seen_cache[puid]
    if type(entry) ~= "table" then return nil end

    local ts = tonumber(entry.ts)
    if not ts then return nil end

    local loc = type(entry.loc) == "string" and entry.loc or "Unknown"
    local delta = math.max(0, os.time() - ts)

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

    local date_ok, dt = pcall(os.date, "*t", ts)
    if not date_ok
        or type(dt) ~= "table"
        or not dt.month
        or not dt.day
        or not dt.hour
        or not dt.min then
        return nil
    end
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

_api.update_last_seen = update_last_seen

-- Batch persistence after a roster draw or HUD player scan. Both paths can
-- discover several players at once.
flush_persistence = function()
    if _notes_dirty then
        mod:set("player_notes", next(_notes_cache) and _notes_cache or nil)
        _notes_dirty = false
    end
    if _names_dirty then
        mod:set("player_names", next(_names_cache) and _names_cache or nil)
        _names_dirty = false
    end
    if _name_to_ids_dirty then
        mod:set("name_to_ids", next(_name_to_ids_cache) and _name_to_ids_cache or nil)
        _name_to_ids_dirty = false
    end
    if _char_to_player_dirty then
        mod:set("char_to_player", next(_char_to_player_cache) and _char_to_player_cache or nil)
        _char_to_player_dirty = false
    end
    if _last_seen_dirty then
        mod:set("player_last_seen", next(_last_seen_cache) and _last_seen_cache or nil)
        _last_seen_dirty = false
    end
end

_api.flush = flush_persistence

local function get_player_for_char(char_name)
    if not char_name or char_name == "" then return nil end
    return get_char_to_player()[char_name]
end

-- resolve_identifier: tries platform display name first, then character name.
-- Returns (puid, display_name, match_type). An exact display name shared by
-- multiple IDs is reported as "ambiguous" instead of choosing the first player.
local function resolve_identifier(identifier)
    if not identifier or identifier == "" then return nil, nil, nil end

    -- 1. Platform display name (name_to_ids map — populated whenever a noted player is seen)
    local ids = get_ids_for_name(identifier)
    if ids and #ids > 0 then
        local unique_ids = {}
        local resolved_id
        local count = 0
        for _, id in ipairs(ids) do
            if id ~= nil and id ~= "" and not unique_ids[id] then
                unique_ids[id] = true
                resolved_id = id
                count = count + 1
            end
        end
        if count == 1 then
            return resolved_id, identifier, "tag"
        elseif count > 1 then
            return nil, identifier, "ambiguous"
        end
    end

    -- 2. Character name (char_to_player map — populated from social roster + mission scans)
    local entry = get_player_for_char(identifier)
    if type(entry) == "table" and entry.puid and entry.puid ~= "" then
        return entry.puid, entry.display_name, "character"
    end

    return nil, nil, nil
end

-- ──────────────────────────────────────────────────────────────────────────────
-- HOVER STATE  (written by _draw_widgets hook, read by UIConstantElements hook)
-- ──────────────────────────────────────────────────────────────────────────────

mod._editing_puid            = nil
mod._editing_name            = nil
mod._hovered_note            = nil   -- full note text (used by tooltip / fallback top bar)
mod._hover_tx                = nil   -- tooltip x (UI base space)
mod._hover_ty                = nil   -- tooltip y (UI base space)
mod._hover_dyn_h             = nil   -- tooltip height for current note

local function clear_hover_state()
    mod._last_hovered_key       = nil
    mod._hover_notes_revision   = nil
    mod._hovered_note           = nil
    mod._hover_tx               = nil
    mod._hover_ty               = nil
    mod._hover_dyn_h            = nil
    mod._cached_top_bar_text    = ""
end

local function set_hover_text(puid, raw_name, note)
    local last_seen_text = puid and format_last_seen_text(puid) or nil
    local bar_text = last_seen_text
        or truncate_text(note, TOP_BAR_NOTE_MAX_CHARACTERS, "...")

    mod._hover_notes_revision   = _notes_revision
    mod._hovered_note           = note
    mod._hover_dyn_h            = compute_tooltip_height(note)
    mod._cached_top_bar_text    = raw_name .. "  —  " .. bar_text
end

-- ──────────────────────────────────────────────────────────────────────────────
-- OVERLAY WIDGET DEFINITIONS
-- ──────────────────────────────────────────────────────────────────────────────

-- Floating tooltip (height mutated dynamically at draw time)
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

-- Top-of-screen name + note bar
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
-- Injected into HudElementWorldMarkers._marker_templates via Hook 10.
--
-- Only shown within 15 world-units (~15 m) so drift from 3D→2D projection
-- at long range is never visible and nearby-only is less cluttered.
-- The widget is a semi-transparent tooltip box (border + fill + text).
-- ──────────────────────────────────────────────────────────────────────────────

local _pn_world_note_size = { 280, 30 }

local function set_world_note_geometry(style, width, height, offset_x, offset_y)
    if type(style) ~= "table" then return end

    local size = style.size
    if type(size) ~= "table" then return end
    size[1] = width
    size[2] = height

    local default_size = style.default_size
    if default_size then
        default_size[1] = width
        default_size[2] = height
    end

    local offset = style.offset
    if type(offset) ~= "table" then return end
    offset[1] = offset_x
    offset[2] = offset_y

    local default_offset = style.default_offset
    if default_offset then
        default_offset[1] = offset_x
        default_offset[2] = offset_y
    end
end

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
        local text = type(data) == "table" and data.note or ""
        text = truncate_text(text, WORLD_NOTE_MAX_CHARACTERS, "...")
        widget.content.pn_note_text = text

        -- Marker text is immutable. Compute geometry once rather than resizing
        -- and offsetting the widget every render frame.
        local W_MAX = _pn_world_note_size[1]
        local note_length = text_length(text)
        local est_w = math.max(60, math.min(W_MAX, note_length * 8 + 20))
        local chars_per_line = math.max(1, math.floor(est_w / 8))
        local num_lines = math.max(1, math.ceil(note_length / chars_per_line))
        local new_h = math.max(30, num_lines * 20 + 10)
        local offset_x = -est_w * 0.5
        local offset_y = -new_h - 30

        set_world_note_geometry(
            widget.style.pn_note_border,
            est_w + 4,
            new_h + 4,
            offset_x - 2,
            offset_y - 2
        )
        set_world_note_geometry(widget.style.pn_note_bg, est_w, new_h, offset_x, offset_y)
        set_world_note_geometry(widget.style.pn_note_text, est_w, new_h, offset_x, offset_y)
    end,
    on_exit = function(widget, marker)
        -- nothing to clean up
    end,
}

-- ──────────────────────────────────────────────────────────────────────────────
-- OVERLAY RENDERING STATE  (lazy init on first draw)
-- ──────────────────────────────────────────────────────────────────────────────

local _pn_scenegraph     = nil
local _pn_scenegraph_scale = nil
local _pn_tooltip_widget = nil
local _pn_toptext_widget = nil
local _overlay_init_retry_after = 0
local _overlay_init_error_reported = false
local _overlay_render_error_reported = false

local function _ensure_overlay_ready()
    if _pn_scenegraph then return true end
    local now = os.time()
    if now < _overlay_init_retry_after then return false end

    local ok, err = pcall(function()
        local scale = RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.scale or 1
        _pn_scenegraph = UIScenegraph.init_scenegraph(
            { screen = UIWorkspaceSettings.screen },
            scale
        )
        _pn_scenegraph_scale = scale
        _pn_tooltip_widget = UIWidget.init("pn_tooltip_overlay", _pn_tooltip_def)
        _pn_toptext_widget  = UIWidget.init("pn_toptext_overlay",  _pn_toptext_def)
        if not _pn_scenegraph or not _pn_tooltip_widget or not _pn_toptext_widget then
            error("overlay API returned an incomplete widget set")
        end
        _pn_tooltip_widget.alpha_multiplier = 1
        _pn_toptext_widget.alpha_multiplier  = 1
    end)
    if not ok then
        if not _overlay_init_error_reported then
            mod:echo("[PlayerNotes] overlay init failed: " .. tostring(err))
            _overlay_init_error_reported = true
        end
        _pn_scenegraph = nil
        _pn_scenegraph_scale = nil
        _pn_tooltip_widget = nil
        _pn_toptext_widget = nil
        _overlay_init_retry_after = now + OVERLAY_INIT_RETRY_SECONDS
        return false
    end
    _overlay_init_retry_after = 0
    _overlay_init_error_reported = false
    return true
end

local function draw_overlay_widgets(ui_renderer, note, show_top_bar, show_tooltip)
    if show_tooltip then
        local tx = mod._hover_tx or 800
        local ty = mod._hover_ty or 300
        local dyn_h = mod._hover_dyn_h or TT_H_MIN

        _pn_tooltip_widget.style.border.size[2] = dyn_h + 4
        _pn_tooltip_widget.style.background.size[2] = dyn_h
        _pn_tooltip_widget.style.note_text.size[2] = dyn_h - TT_PAD * 2

        _pn_tooltip_widget.content.note_text = note
        _pn_tooltip_widget.offset[1] = tx
        _pn_tooltip_widget.offset[2] = ty
        _pn_tooltip_widget.offset[3] = TT_Z
        _pn_tooltip_widget.visible = true
        _pn_tooltip_widget.alpha_multiplier = 1
        UIWidget.draw(_pn_tooltip_widget, ui_renderer)
    end

    if show_top_bar then
        _pn_toptext_widget.content.label_text = mod._cached_top_bar_text
        _pn_toptext_widget.offset[1] = A2_X
        _pn_toptext_widget.offset[2] = A2_Y
        _pn_toptext_widget.offset[3] = TT_Z
        _pn_toptext_widget.visible = true
        _pn_toptext_widget.alpha_multiplier = 1
        UIWidget.draw(_pn_toptext_widget, ui_renderer)
    end
end

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 1: Roster-scoped account-name decoration
--
-- Darktide calls PlayerInfo.user_display_name from many frequently rendered
-- surfaces. Decorating only the Social roster's account-name passes avoids a
-- global hot-path hook and prevents notes leaking into unrelated UI.
-- ──────────────────────────────────────────────────────────────────────────────

local function decorate_roster_account_name(content)
    local player_info = content and content.player_info
    local raw_name = content and content.pn_raw_account_name
    if not player_info or not raw_name or raw_name == "" then return end
    if not _is_enabled then
        content.account_name = raw_name
        return
    end

    if content.pn_player_info ~= player_info then
        content.pn_player_info = player_info
        content.pn_note_revision = nil
        content.pn_rendered_account_name = nil
    end

    if content.is_own_player then
        content.account_name = raw_name
        return
    end

    local puid = get_cached_player_key(player_info)
    if puid then
        _raw_names[puid] = raw_name
    end

    -- Resolve character identity once per PlayerInfo object. Loading-state
    -- misses retry on a cooldown; blocked users are terminal for this view.
    if puid
        and not _roster_identity_ready[player_info]
        and os.time() >= (_roster_identity_retry_after[player_info] or 0) then
        local is_blocked = safe_method(player_info, "is_blocked")
        if is_blocked == true then
            _roster_identity_ready[player_info] = true
        elseif is_blocked == false then
            local char_name = safe_method(player_info, "character_name")
            if type(char_name) == "string" and char_name ~= "" then
                update_char_to_player(char_name, puid, raw_name, "hub")
                _roster_identity_ready[player_info] = true
            else
                _roster_identity_retry_after[player_info] =
                    os.time() + IDENTITY_MISS_RETRY_SECONDS
            end
        else
            _roster_identity_retry_after[player_info] =
                os.time() + IDENTITY_MISS_RETRY_SECONDS
        end
    end

    if content.pn_note_revision == _notes_revision
        and content.pn_cached_raw_name == raw_name
        and content.pn_rendered_account_name then
        content.account_name = content.pn_rendered_account_name
        return
    end

    local note = puid and get_note(puid) or nil
    local rendered_name = raw_name
    if note and note ~= "" then
        if _settings.show_inline then
            local preview = truncate_text(note, 28, "...")
            rendered_name = raw_name .. " · " .. preview
        else
            -- U+E046, Darktide's favorites icon.
            rendered_name = raw_name .. " \xEE\x81\x86"
        end
    end

    content.pn_note_revision = _notes_revision
    content.pn_cached_raw_name = raw_name
    content.pn_rendered_account_name = rendered_name
    content.account_name = rendered_name
end

mod:hook_require(
    "scripts/ui/views/social_menu_roster_view/social_menu_roster_view_blueprints",
    function(blueprints)
        if type(blueprints) ~= "table" then return end

        for _, blueprint in pairs(blueprints) do
            local passes = type(blueprint) == "table" and blueprint.pass_template
            if type(passes) == "table" then
                for i = 1, #passes do
                    local pass = passes[i]
                    if type(pass) == "table" and pass.style_id == "account_name" then
                        -- Preserve the game's real function across mod reloads.
                        local original = pass.pn_player_notes_original_change_function
                            or pass.change_function
                        pass.pn_player_notes_original_change_function = original
                        pass.change_function = function(content, style)
                            if type(content) ~= "table" then
                                if original then return original(content, style) end
                                return
                            end
                            local cached_raw_name = content.pn_raw_account_name
                            if cached_raw_name then
                                content.account_name = cached_raw_name
                            end
                            if original then
                                original(content, style)
                            end
                            content.pn_raw_account_name = content.account_name
                            decorate_roster_account_name(content)
                        end
                    end
                end
            end
        end
    end
)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 2: Inject note button into the right-click popup
-- ──────────────────────────────────────────────────────────────────────────────

local _popup_error_reported = false

local function augment_social_popup(parent, player_info, menu_items, num_menu_items)
    if not _is_enabled then return num_menu_items end
    if not player_info or type(menu_items) ~= "table" then return num_menu_items end

    local puid = get_cached_player_key(player_info)
    local display_name = get_player_display_name(player_info, true, true) or "player"
    local is_own_player = safe_method(player_info, "is_own_player") == true

    if not is_own_player and puid then
        if safe_method(player_info, "is_blocked") == false then
            local char_name = safe_method(player_info, "character_name")
            if type(char_name) == "string" and char_name ~= "" then
                update_char_to_player(char_name, puid, display_name, "hub")
            end
        end

        local note = get_note(puid)
        local preview = note and truncate_text(note, 40, "...")
        local label = note and ("[Note] " .. preview) or STR_BTN_ADD
        local pressed_callback = callback(parent, "cb_pn_edit_note", player_info)

        table.insert(menu_items, 1, {
            label     = "pn_divider",
            blueprint = "group_divider",
        })
        table.insert(menu_items, 1, {
            label            = label,
            blueprint        = "button",
            is_disabled      = false,
            on_pressed_sound = UISoundEvents.social_menu_see_player_profile,
            callback         = pressed_callback,
        })
        return (tonumber(num_menu_items) or #menu_items - 2) + 2
    end

    return num_menu_items
end

mod:hook(CLASS.ViewElementPlayerSocialPopup, "_set_player_info",
    function(func, self, parent, player_info, menu_items, num_menu_items, ...)
        local ok, updated_count = pcall(
            augment_social_popup,
            parent,
            player_info,
            menu_items,
            num_menu_items
        )
        if ok then
            num_menu_items = updated_count
            _popup_error_reported = false
        elseif not _popup_error_reported then
            mod:echo("[PlayerNotes] Social popup integration failed: " .. tostring(updated_count))
            _popup_error_reported = true
        end

        flush_persistence()
        return func(self, parent, player_info, menu_items, num_menu_items, ...)
    end
)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 3: Inject callback into SocialMenuRosterView
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook_safe(CLASS.SocialMenuRosterView, "init", function(self, ...)
    function self:cb_pn_edit_note(player_info)
        mod._editing_puid = get_cached_player_key(player_info)
        mod._editing_name = get_player_display_name(player_info, true, true)
        if mod._editing_puid then
            save_player_name(mod._editing_puid, mod._editing_name)
        end
        mod:echo(mod:localize("echo_selected", mod._editing_name or "player"))
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 4: Cleanup on view close
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook_safe(CLASS.SocialMenuRosterView, "on_exit", function(self, ...)
    flush_persistence()
    mod._editing_puid           = nil
    mod._editing_name           = nil
    clear_hover_state()
    _raw_names = {}
    _puid_cache = setmetatable({}, { __mode = "k" })
    _puid_is_fallback = setmetatable({}, { __mode = "k" })
    _puid_retry_after = setmetatable({}, { __mode = "k" })
    _roster_identity_ready = setmetatable({}, { __mode = "k" })
    _roster_identity_retry_after = setmetatable({}, { __mode = "k" })
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
-- The scoped roster blueprint stores pn_raw_account_name so hover rendering
-- never has to strip inline note/icon decoration.
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook_safe(CLASS.SocialMenuRosterView, "_draw_widgets",
    function(self, dt, t, input_service, ui_renderer, render_settings)
        -- Text passes ran immediately before this post-hook and may have
        -- discovered several identities. Persist them in one batch.
        flush_persistence()

        if not next(_notes_cache) then
            clear_hover_state()
            return
        end

        if self._popup_menu then
            clear_hover_state()
            return
        end

        local grid_node      = self._ui_scenegraph and self._ui_scenegraph.roster_grid_content
        local roster_widgets = self._roster_widgets
        if not grid_node or not roster_widgets or not input_service then
            clear_hover_state()
            return
        end

        local cursor_pos = input_service:get("cursor")
        if not cursor_pos then
            clear_hover_state()
            return
        end

        local inv = RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.inverse_scale or 1
        local sw  = RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.width  * inv or 1920
        local sh  = RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.height * inv or 1080
        local mx  = Vector3.x(cursor_pos) * inv
        local my  = Vector3.y(cursor_pos) * inv
        local world_position = grid_node.world_position
        if not world_position then
            clear_hover_state()
            return
        end
        local gx = world_position[1] or 0
        local gy = world_position[2] or 0
        local grid_size = grid_node.size
        local grid_w = grid_size and grid_size[1] or 1030
        local grid_h = grid_size and grid_size[2] or 680

        -- Most frames have the cursor outside the roster; avoid walking every
        -- friend row in that common case.
        if mx < gx or mx > gx + grid_w or my < gy or my > gy + grid_h then
            clear_hover_state()
            return
        end

        local found_hover = false

        for i = 1, #roster_widgets do
            local w   = roster_widgets[i]
            local off = w and w.offset
            if off then
                local wx = gx + off[1]
                local wy = gy + off[2]
                local cs = w.content and w.content.size
                local ww = (cs and cs[1]) or 480
                local wh = (cs and cs[2]) or 80

                if mx >= wx and mx <= wx + ww and my >= wy and my <= wy + wh then
                    found_hover = true

                    -- HEARTBEAT: Tell the renderer we are still actively hovering
                    mod._last_hover_time = t 

                    local content = w.content
                    local pi = content and content.player_info
                    local is_own_player = content and content.is_own_player
                    local cached_puid = pi and _puid_cache[pi]
                    local puid = cached_puid and cached_puid or nil
                    local raw_name = get_cached_name(puid)
                        or (content and content.pn_raw_account_name)
                        or (content and content.account_name)
                        or "Player"
                    local hover_key = puid or raw_name

                    if hover_key ~= mod._last_hovered_key
                        or mod._hover_notes_revision ~= _notes_revision then
                        mod._last_hovered_key = hover_key
                        local note = nil
                        if not is_own_player then
                            note = puid and get_note(puid) or nil
                        end

                        if note then
                            set_hover_text(puid, raw_name, note)
                        else
                            clear_hover_state()
                            mod._last_hovered_key = hover_key
                            mod._hover_notes_revision = _notes_revision
                        end
                    end

                    -- Position logic MUST run every frame because the cursor is moving.
                    local note = mod._hovered_note
                    if note then
                        local dyn_h = mod._hover_dyn_h
                        local tx = wx + ww + 15
                        if tx + TT_W > sw then tx = wx - TT_W - 15 end
                        local ty = math.max(wy, 10)
                        ty = math.min(ty, sh - dyn_h - 10)

                        mod._hover_tx = tx
                        mod._hover_ty = ty
                    end
                    break
                end
            end
        end

        -- If the mouse is no longer over any player, reset ALL state.
        if not found_hover then
            clear_hover_state()
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

mod:hook_safe(CLASS.UIConstantElements, "draw", function(self, dt, t, input_service)
    -- THE WATCHDOG: If the heartbeat hasn't been updated in 0.1 seconds,
    -- it means the hover logic is gone or the mouse left. Clear everything.
    if mod._hovered_note and type(t) == "number" and t - mod._last_hover_time > 0.1 then
        clear_hover_state()
    end

    local note = mod._hovered_note
    if not note then return end

    local show_top_bar = _settings.show_top_bar
    local show_tooltip = _settings.show_tooltip
    if not show_top_bar and not show_tooltip then return end
    if not _ensure_overlay_ready() then return end

    local ui_renderer = self and self._ui_renderer
    local render_settings = self and self._render_settings
    if not ui_renderer or type(render_settings) ~= "table" then return end

    local render_error
    local scale = RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.scale or 1
    if scale ~= _pn_scenegraph_scale then
        local scale_ok, scale_error = pcall(
            UIScenegraph.update_scenegraph,
            _pn_scenegraph,
            scale
        )
        if not scale_ok then
            render_error = scale_error
        else
            _pn_scenegraph_scale = scale
        end
    end

    local saved_layer = render_settings.start_layer
    render_settings.start_layer = 900

    local begin_ok, begin_error = pcall(
        UIRenderer.begin_pass,
        ui_renderer,
        _pn_scenegraph,
        input_service,
        dt,
        render_settings
    )

    if begin_ok then
        local draw_ok, draw_error = pcall(
            draw_overlay_widgets,
            ui_renderer,
            note,
            show_top_bar,
            show_tooltip
        )
        local end_ok, end_error = pcall(UIRenderer.end_pass, ui_renderer)
        if not draw_ok then
            render_error = render_error or draw_error
        elseif not end_ok then
            render_error = render_error or end_error
        end
    else
        render_error = render_error or begin_error
    end

    -- This shared table belongs to the base UI. Restore it even when begin,
    -- widget drawing, or end_pass fails.
    render_settings.start_layer = saved_layer

    if render_error then
        if not _overlay_render_error_reported then
            mod:echo("[PlayerNotes] overlay render failed: " .. tostring(render_error))
            _overlay_render_error_reported = true
        end
    else
        _overlay_render_error_reported = false
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 7: Hover detection in GroupFinderView._draw_widgets (Party Finder)
--
-- GroupFinderView has NO offscreen renderer — widgets are drawn in screen space.
-- The game itself uses grid:hovered_grid_index() + grid:widget_by_index() for
-- hover detection in this same view (group_finder_view.lua:777), so we do the
-- same rather than using geometric bounds or hotspot.is_hover.
--
-- account_id (Fatshark backend ID) → PlayerInfo via the social data service,
-- then through the shared canonical-identity resolver. If the requesting player
-- is not in the social cache, the note cannot be resolved and is skipped.
-- ──────────────────────────────────────────────────────────────────────────────

local function clear_group_finder_hover(self, reset_identity)
    clear_hover_state()
    if reset_identity and self then
        self._pn_hover_account_id = nil
        self._pn_hover_notes_revision = nil
        self._pn_hover_note = nil
        self._pn_hover_puid = nil
        self._pn_hover_raw_name = nil
    end
end

mod:hook_safe(CLASS.GroupFinderView, "_draw_widgets",
    function(self, dt, t, input_service, ui_renderer, render_settings)
        if not next(_notes_cache) then
            clear_group_finder_hover(self, true)
            return
        end

        local grid = self._player_request_grid
        if not grid then
            clear_group_finder_hover(self, true)
            return
        end

        -- Use the same hover API the game uses in this view (no offscreen renderer)
        local hovered_idx = grid:hovered_grid_index()
        if not hovered_idx then
            clear_group_finder_hover(self, true)
            return
        end

        local widget = grid:widget_by_index(hovered_idx)
        if not widget then
            clear_group_finder_hover(self, true)
            return
        end

        local content    = widget.content
        local element    = content and content.element
        local account_id = element and element.account_id
        if not account_id then
            clear_group_finder_hover(self, true)
            return
        end

        if self._pn_hover_account_id ~= account_id
            or self._pn_hover_notes_revision ~= _notes_revision then
            self._pn_hover_account_id = account_id
            self._pn_hover_notes_revision = _notes_revision
            self._pn_hover_note = nil
            self._pn_hover_puid = nil
            self._pn_hover_raw_name = nil

            local managers = rawget(_G, "Managers")
            local social = managers and managers.data_service and managers.data_service.social
            local player_info = safe_method(social, "get_player_info_by_account_id", account_id)
            if player_info then
                local puid = get_cached_player_key(player_info)
                flush_persistence()
                local raw_name = get_cached_name(puid)
                    or get_player_display_name(player_info, true, true)
                    or "Player"
                local note = puid and get_note(puid) or nil
                if note then
                    self._pn_hover_note = note
                    self._pn_hover_puid = puid
                    self._pn_hover_raw_name = raw_name
                    set_hover_text(puid, raw_name, note)
                else
                    clear_hover_state()
                end
            else
                clear_hover_state()
            end
        end

        local note = self._pn_hover_note
        if not note then return end
        if not mod._hovered_note then
            set_hover_text(self._pn_hover_puid, self._pn_hover_raw_name or "Player", note)
        end

        mod._last_hover_time = t

        local cursor_pos = input_service and input_service:get("cursor")
        if not cursor_pos then
            clear_hover_state()
            return
        end

        local inv   = RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.inverse_scale or 1
        local sh    = RESOLUTION_LOOKUP and RESOLUTION_LOOKUP.height * inv or 1080
        local mx    = Vector3.x(cursor_pos) * inv
        local my    = Vector3.y(cursor_pos) * inv
        local dyn_h = mod._hover_dyn_h or compute_tooltip_height(note)

        -- Position tooltip to the left of cursor (player_request_grid is on the right)
        local tx = mx - TT_W - 20
        if tx < 10 then tx = mx + 20 end
        local ty = math.max(my - dyn_h / 2, 10)
        ty = math.min(ty, sh - dyn_h - 10)

        mod._hover_tx               = tx
        mod._hover_ty               = ty
    end
)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 8: Cleanup on GroupFinderView close
-- ──────────────────────────────────────────────────────────────────────────────

mod:hook_safe(CLASS.GroupFinderView, "on_exit", function(self, ...)
    clear_group_finder_hover(self, true)
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 9: "Add Note" button in Party Finder player-request entries
--
-- This feature shipped in the Nexus 2.8.0 package but was never committed to
-- the repository. Bind each button when its blueprint creates the row instead
-- of scanning every request widget from GroupFinderView.update each frame.
-- ──────────────────────────────────────────────────────────────────────────────

local function player_request_note_button_change(content, style)
    ButtonPassTemplates.terminal_button_change_function(content, style, "pn_note_hotspot")
end

local function player_request_note_button_hover_change(content, style)
    ButtonPassTemplates.terminal_button_hover_change_function(content, style, "pn_note_hotspot")
end

local function player_request_note_button_visible(content)
    local runtime_api = mod._api
    if not runtime_api
        or not runtime_api.is_enabled
        or not runtime_api.is_enabled() then
        return false
    end

    local element = content and (content.element or content.parent and content.parent.element)
    local managers = rawget(_G, "Managers")
    local ui_manager = managers and managers.ui

    return element
        and not element.is_preview
        and ui_manager
        and type(ui_manager.using_cursor_navigation) == "function"
        and ui_manager:using_cursor_navigation()
end

local function select_group_finder_player(account_id)
    if not _is_enabled then return end
    local managers = rawget(_G, "Managers")
    local social_service = managers and managers.data_service and managers.data_service.social
    local player_info = account_id
        and social_service
        and safe_method(social_service, "get_player_info_by_account_id", account_id)

    if not player_info then
        mod:echo("[PlayerNotes] Could not resolve player info for this applicant.")
        return
    end

    local puid = get_cached_player_key(player_info)
    if not puid then
        mod:echo("[PlayerNotes] Could not resolve a stable ID for this applicant.")
        return
    end

    local display_name = get_player_display_name(player_info, true, true)
        or get_cached_name(puid)
        or "player"

    mod._editing_puid = puid
    mod._editing_name = display_name
    save_player_name(puid, display_name)
    mod:echo(mod:localize("echo_selected", display_name))
end
_api.select_group_finder_player = select_group_finder_player

mod:hook_require("scripts/ui/views/group_finder_view/group_finder_view_definitions", function(definitions)
    local blueprints = definitions and definitions.grid_blueprints
    local blueprint = blueprints and blueprints.player_request_entry
    local pass_template = blueprint and blueprint.pass_template

    if not blueprint or type(pass_template) ~= "table" then
        return
    end

    if not table.find_by_key(pass_template, "style_id", "pn_note_hotspot") then
        local note_passes = {
            {
                style_id   = "pn_note_hotspot",
                pass_type  = "hotspot",
                content_id = "pn_note_hotspot",
                content    = {},
                style = {
                    vertical_alignment   = "center",
                    horizontal_alignment = "right",
                    offset = { -190, 0, 5 },
                    size   = { 40, 40 },
                },
                visibility_function = player_request_note_button_visible,
            },
            {
                pass_type  = "texture",
                style_id   = "pn_note_background",
                value      = "content/ui/materials/backgrounds/default_square",
                style = {
                    vertical_alignment   = "center",
                    horizontal_alignment = "right",
                    offset = { -190, 0, 5 },
                    size   = { 40, 40 },
                    default_color  = Color.terminal_background(nil, true),
                    selected_color = Color.terminal_background_selected(nil, true),
                },
                change_function     = player_request_note_button_change,
                visibility_function = player_request_note_button_visible,
            },
            {
                pass_type  = "texture",
                style_id   = "pn_note_background_gradient",
                value      = "content/ui/materials/gradients/gradient_vertical",
                style = {
                    vertical_alignment   = "center",
                    horizontal_alignment = "right",
                    offset = { -190, 0, 6 },
                    size   = { 40, 40 },
                    color  = Color.terminal_background_gradient(nil, true),
                },
                change_function     = player_request_note_button_hover_change,
                visibility_function = player_request_note_button_visible,
            },
            {
                style_id  = "pn_note_icon",
                pass_type = "texture",
                value     = "content/ui/materials/icons/system/escape/credits",
                style = {
                    vertical_alignment   = "center",
                    horizontal_alignment = "right",
                    offset = { -190, 0, 7 },
                    size   = { 40, 40 },
                },
                visibility_function = player_request_note_button_visible,
            },
            {
                pass_type  = "texture",
                style_id   = "pn_note_frame",
                value      = "content/ui/materials/frames/frame_tile_2px",
                style = {
                    vertical_alignment   = "center",
                    scale_to_material    = true,
                    horizontal_alignment = "right",
                    offset = { -190, 0, 7 },
                    size   = { 40, 40 },
                    default_color  = Color.terminal_frame(nil, true),
                    selected_color = Color.terminal_frame_selected(nil, true),
                },
                change_function     = player_request_note_button_change,
                visibility_function = player_request_note_button_visible,
            },
            {
                pass_type  = "texture",
                style_id   = "pn_note_corner",
                value      = "content/ui/materials/frames/frame_corner_2px",
                style = {
                    vertical_alignment   = "center",
                    scale_to_material    = true,
                    horizontal_alignment = "right",
                    offset = { -190, 0, 8 },
                    size   = { 40, 40 },
                    default_color  = Color.terminal_corner(nil, true),
                    selected_color = Color.terminal_corner_selected(nil, true),
                },
                change_function     = player_request_note_button_change,
                visibility_function = player_request_note_button_visible,
            },
            {
                style_id  = "pn_note_outer_shadow",
                pass_type = "texture",
                value     = "content/ui/materials/frames/dropshadow_medium",
                style = {
                    vertical_alignment   = "center",
                    scale_to_material    = true,
                    horizontal_alignment = "right",
                    offset        = { -180, 0, 8 },
                    size          = { 40, 40 },
                    size_addition = { 20, 20 },
                    color         = Color.black(200, true),
                },
                visibility_function = player_request_note_button_visible,
            },
        }

        table.append(pass_template, note_passes)
    else
        -- hook_require tables survive a DMF hot reload. Refresh closures on
        -- passes appended by an older PlayerNotes runtime.
        for i = 1, #pass_template do
            local pass = pass_template[i]
            local style_id = type(pass) == "table" and pass.style_id
            if type(style_id) == "string" and style_id:find("^pn_note_") then
                pass.visibility_function = player_request_note_button_visible
                if style_id == "pn_note_background_gradient" then
                    pass.change_function = player_request_note_button_hover_change
                elseif style_id == "pn_note_background"
                    or style_id == "pn_note_frame"
                    or style_id == "pn_note_corner" then
                    pass.change_function = player_request_note_button_change
                end
            end
        end
    end

    if blueprint.init then
        mod:hook(blueprint, "init",
            function(func, parent, widget, element, callback_name, secondary_callback_name, ui_renderer, ...)
                local result = func(
                    parent,
                    widget,
                    element,
                    callback_name,
                    secondary_callback_name,
                    ui_renderer,
                    ...
                )
                local hotspot = widget and widget.content and widget.content.pn_note_hotspot
                local account_id = element and element.account_id

                if hotspot and account_id then
                    hotspot.pressed_callback = function()
                        local runtime_api = mod._api
                        local select_player = runtime_api
                            and runtime_api.select_group_finder_player
                        if select_player then select_player(account_id) end
                    end
                end

                return result
            end
        )
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- COMMAND: /note <text>
-- ──────────────────────────────────────────────────────────────────────────────

mod:command("note", "Save a note for the last selected player through the 'Social' window.", function(...)
    local args = { ... }
    if #args == 0 then mod:echo(STR_USAGE_NOTE); return end
    if not mod._editing_puid then mod:echo(STR_NONE_SEL); return end
    local text = table.concat(args, " ")
    local _, was_truncated = save_note(mod._editing_puid, text, mod._editing_name)
    mod:echo(mod:localize("echo_saved", mod._editing_name or "player"))
    if was_truncated then
        mod:echo(string.format(
            "[PlayerNotes] Note was limited to %d characters.",
            MAX_NOTE_CHARACTERS
        ))
    end
    mod._editing_puid = nil
    mod._editing_name = nil
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- COMMAND: /pn_notes — list all saved notes
-- ──────────────────────────────────────────────────────────────────────────────

mod:command("pn_notes", "List all saved PlayerNotes.", function()
    local notes = get_notes()
    local entries = {}
    for puid, note in pairs(notes) do
        if type(note) == "string" and note ~= "" then
            local display_name = get_cached_name(puid) or puid
            entries[#entries + 1] = {
                display_name = tostring(display_name),
                id = tostring(puid),
                note = note,
            }
        end
    end

    table.sort(entries, function(a, b)
        if a.display_name == b.display_name then return a.id < b.id end
        return a.display_name < b.display_name
    end)

    for i = 1, #entries do
        local entry = entries[i]
        mod:echo(string.format(
            "[%d] %s [%s] → %s",
            i,
            entry.display_name,
            entry.id,
            entry.note
        ))
    end
    
    if #entries == 0 then mod:echo("No notes saved yet.") end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 10: Inject "pn_note" template into HudElementWorldMarkers
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
    local templates = self and self._marker_templates
    if type(templates) == "table" then
        templates[_pn_world_marker_template.name] = _pn_world_marker_template
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- HOOK 11: Register HudElementPlayerNotes via DMF's proper HUD element API
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
-- ADDITIONAL COMMANDS
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

local function resolve_set_note_arguments(args)
    -- DMF supplies chat-command words separately. Try the longest possible
    -- identifier prefix so mapped display names containing spaces remain usable.
    for split_at = #args - 1, 1, -1 do
        local identifier = table.concat(args, " ", 1, split_at)
        local puid, display_name, match_type = resolve_identifier(identifier)
        if puid or match_type == "ambiguous" then
            return puid,
                display_name,
                match_type,
                identifier,
                table.concat(args, " ", split_at + 1)
        end
    end

    return nil, nil, nil, args[1], table.concat(args, " ", 2)
end

mod:command("set_note", "<player_tag_or_character_name> <note> | Set a note for a player by their player tag or character name.", function(...)
    local args = { ... }
    if #args < 2 then
        mod:echo("Usage: /set_note <player_tag_or_character_name> <note text>")
        mod:echo("  e.g. /set_note Potty#1031 great psyker for havoc 40")
        mod:echo("       /set_note KimJongDois great psyker for havoc 40")
        return
    end

    local puid, display_name, match_type, identifier, text =
        resolve_set_note_arguments(args)

    if not puid then
        if match_type == "ambiguous" then
            mod:echo(string.format(
                "[PlayerNotes] '%s' matches multiple players. Select the intended player in Social or Party Finder.",
                identifier
            ))
            return
        end
        mod:echo(string.format("[PlayerNotes] Unknown: '%s'.", identifier))
        mod:echo("Tip: right-click the player in Social panel first, or use their full tag (e.g. Potty#1031).")
        return
    end

    local _, was_truncated = save_note(puid, text, display_name)

    if match_type == "character" then
        mod:echo(string.format("Note saved for %s (character of %s).", identifier, display_name or "?"))
    else
        mod:echo(string.format("Note saved for %s.", display_name or identifier))
    end
    if was_truncated then
        mod:echo(string.format(
            "[PlayerNotes] Note was limited to %d characters.",
            MAX_NOTE_CHARACTERS
        ))
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

    local identifier                    = table.concat(args, " ")
    local puid, display_name, match_type = resolve_identifier(identifier)

    if not puid then
        if match_type == "ambiguous" then
            mod:echo(string.format(
                "[PlayerNotes] '%s' matches multiple players. Select the intended player in Social or Party Finder.",
                identifier
            ))
            return
        end
        mod:echo(string.format("[PlayerNotes] Unknown: '%s'.", identifier))
        mod:echo("Tip: right-click the player in Social panel first, or use their full tag (e.g. Potty#1031).")
        return
    end

    local existing_note = get_note(puid)
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
    local entries = {}
    for char_name, entry in pairs(map) do
        if type(char_name) == "string" and type(entry) == "table" then
            entries[#entries + 1] = {
                character_name = char_name,
                display_name = tostring(entry.display_name or entry.puid or "?"),
                context = tostring(entry.context or "?"),
            }
        end
    end
    table.sort(entries, function(a, b)
        return a.character_name < b.character_name
    end)
    for i = 1, #entries do
        local entry = entries[i]
        mod:echo(string.format("[%d] %s → %s (%s)",
            i, entry.character_name, entry.display_name, entry.context))
    end
    if #entries == 0 then
        mod:echo("No character mappings recorded yet. Play a mission or open the Social panel.")
    end
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- COMMAND: /pn_notes_delete_all — wipe all notes and the name cache
-- ──────────────────────────────────────────────────────────────────────────────

mod:command("pn_notes_delete_all", "Delete ALL saved PlayerNotes and reset the name cache. Requires: /pn_notes_delete_all confirm", function(...)
    local confirmation = select(1, ...)
    if confirmation ~= "confirm" then
        mod:echo("[PlayerNotes] This deletes every note and cache entry.")
        mod:echo("Run /pn_notes_delete_all confirm to continue.")
        return
    end

    -- Use nil (not {}) to remove the key entirely — avoids passing an empty
    -- table to the native SJSON serializer, which can cause a silent crash.
    mod:set("player_notes", nil)
    mod:set("player_names", nil)
    mod:set("name_to_ids", nil)
    mod:set("char_to_player", nil)
    mod:set("player_last_seen", nil)
    -- Reset all in-memory persistence caches (closures over these upvalues
    -- automatically see the new tables, including the internal HUD API).
    _notes_cache          = {}
    _names_cache          = {}
    _name_to_ids_cache    = {}
    _char_to_player_cache = {}
    _last_seen_cache      = {}
    _notes_dirty          = false
    _names_dirty          = false
    _name_to_ids_dirty    = false
    _char_to_player_dirty = false
    _last_seen_dirty      = false
    _notes_revision       = _notes_revision + 1
    -- Reset session caches
    _raw_names   = {}
    _puid_cache  = setmetatable({}, { __mode = "k" })
    _puid_is_fallback = setmetatable({}, { __mode = "k" })
    _puid_retry_after = setmetatable({}, { __mode = "k" })
    _roster_identity_ready = setmetatable({}, { __mode = "k" })
    _roster_identity_retry_after = setmetatable({}, { __mode = "k" })
    _known_chars = {}
    _session_seen = {}
    _stored_player_ids = {}
    clear_hover_state()
    mod:echo("[PlayerNotes] All notes and name cache cleared.")
end)

-- ──────────────────────────────────────────────────────────────────────────────
-- LIFECYCLE
-- ──────────────────────────────────────────────────────────────────────────────

mod.on_setting_changed = function(setting_id)
    if _settings[setting_id] == nil then return end

    _settings[setting_id] = mod:get(setting_id) == true
    if setting_id == "show_inline" then
        _notes_revision = _notes_revision + 1
    end
end

-- Clear per-session last-seen guard when leaving a game state (mission or hub).
-- This ensures re-entering a map records a fresh timestamp.
mod.on_game_state_changed = function(status, state_name)
    if status == "exit" then
        flush_persistence()
        _session_seen = {}
        _known_chars = {}
        rebuild_stored_player_ids()
        -- Reset the flag when leaving the map
        mod._notification_done_for_session = false
    end
end

mod.on_all_mods_loaded = function()
    flush_persistence()
    if _settings.enable_debug_echo then
        mod:echo("[PlayerNotes] v2.10.0 Loaded. /note /set_note /delete_note /pn_notes /pn_chars /pn_notes_delete_all")
    end
end

local function release_transient_state()
    flush_persistence()
    clear_hover_state()
    _raw_names = {}
    _known_chars = {}
    _session_seen = {}
    _puid_cache = setmetatable({}, { __mode = "k" })
    _puid_is_fallback = setmetatable({}, { __mode = "k" })
    _puid_retry_after = setmetatable({}, { __mode = "k" })
    _roster_identity_ready = setmetatable({}, { __mode = "k" })
    _roster_identity_retry_after = setmetatable({}, { __mode = "k" })
    _pn_scenegraph = nil
    _pn_scenegraph_scale = nil
    _pn_tooltip_widget = nil
    _pn_toptext_widget = nil
    _overlay_init_retry_after = 0
    _overlay_init_error_reported = false
    _overlay_render_error_reported = false
end

mod.on_disabled = function()
    _is_enabled = false
    release_transient_state()
end

mod.on_enabled = function()
    _is_enabled = true
    _overlay_init_retry_after = 0
    _overlay_init_error_reported = false
    _overlay_render_error_reported = false
end

mod.on_unload = function()
    _is_enabled = false
    release_transient_state()
end
