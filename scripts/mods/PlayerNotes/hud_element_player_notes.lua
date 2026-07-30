-- hud_element_player_notes.lua
-- HUD element that scans in-session player identities every SCAN_INTERVAL
-- seconds and, when enabled, adds/removes "pn_note" world marker units for
-- players who have a saved note. The actual rendering is handled by
-- HudElementWorldMarkers via the template.
--
-- Player identity chain:
--   player:account_id()
--     → optional Social PlayerInfo enrichment / legacy platform-ID migration
--       → canonical account-ID fallback
--         → cached note and character-alias lookup

local mod = get_mod("PlayerNotes")

local HudElementPlayerNotes = class("HudElementPlayerNotes")

local SCAN_INTERVAL = 2.0   -- seconds between full player scans
local NOTIFICATION_RETRY_INTERVAL = 1.0
local NOTIFICATION_MAX_ATTEMPTS = 10
local _api = mod._api or {}
local _settings = _api.settings or {
    show_world_notes = mod:get("show_world_notes") ~= false,
    show_world_notes_in_missions = mod:get("show_world_notes_in_missions") == true,
}
local _mission_templates
local _danger_utility

local function _safe_method(object, method_name, ...)
    local method = object and object[method_name]
    if type(method) ~= "function" then return nil end

    local ok, value = pcall(method, object, ...)
    return ok and value or nil
end

local function _clear_table(target)
    for key in pairs(target) do target[key] = nil end
end

-- Returns true in a mission, false in a hub, or nil while game-mode state is
-- not ready. The nil state must not be cached during loading transitions.
-- Mirrors the hub detection used in hud_visibility_groups.lua and
-- constant_element_onboarding_handler.lua: both "hub" and "prologue_hub" are hub modes.
local function _is_in_mission()
    local managers = rawget(_G, "Managers")
    local gm = managers and managers.state and managers.state.game_mode
    if not gm then return nil end
    local name = _safe_method(gm, "game_mode_name")
    if not name then return nil end
    return name ~= "hub" and name ~= "prologue_hub"
end

-- Builds the location string for the current mission.
-- Called once per scan (not per player). Returns nil if state isn't ready.
-- Examples:
--   "Vigil Station Oblivium (Havoc 40)"
--   "Smelter Complex (Auric Maelstrom)"
--   "Archives (Auric)"
--   "Hab Dreyko"
local function _get_current_location()
    local ok, result = pcall(function()
        local managers = rawget(_G, "Managers")
        local state = managers and managers.state
        local mission_key = state and _safe_method(state.mission, "mission_name")
        if not mission_key then return nil end

        -- Resolve human-readable mission name via the mission template.
        -- Template's mission_name field is a localization key (e.g. "loc_mission_name_cm_archives").
        if _mission_templates == nil then
            local ok_tmpl, result = pcall(require, "scripts/settings/mission/mission_templates")
            _mission_templates = ok_tmpl and result or false
        end
        local template    = _mission_templates and _mission_templates[mission_key]
        local loc_key     = template and template.mission_name
        local display_name
        if loc_key then
            local ok_loc, localized = pcall(Localize, loc_key)
            display_name = (ok_loc and localized and localized ~= loc_key) and localized or mission_key
        else
            display_name = mission_key
        end

        -- Difficulty suffix.
        local suffix = ""
        local diff_mgr = state.difficulty
        if not diff_mgr then return nil end

        -- Havoc: has its own rank number, takes priority.
        local ok_hav, havoc_data = pcall(diff_mgr.get_parsed_havoc_data, diff_mgr)
        if ok_hav and havoc_data and havoc_data.havoc_rank then
            suffix = " (Havoc " .. tostring(havoc_data.havoc_rank) .. ")"
        else
            -- Auric Maelstrom: flash_mission circumstance at Auric tier.
            local circ_mgr     = state.circumstance
            local circ_name    = _safe_method(circ_mgr, "circumstance_name")
            local is_maelstrom = circ_name and circ_name:find("^flash_mission") ~= nil

            -- Auric: use Danger.danger_by_difficulty(challenge, resistance) — authoritative
            -- for ALL mission types including expeditions.
            -- pacing:is_auric() only works for standard missions (expedition pacing
            -- template never sets the is_auric flag). Danger utility is what the mission
            -- board and expedition view both use.
            -- Auric = challenge 5 + resistance 5; Damnation = challenge 5 + resistance 4.
            local is_auric = false
            if _danger_utility == nil then
                local ok_d, result = pcall(require, "scripts/utilities/danger")
                _danger_utility = ok_d and result or false
            end
            if _danger_utility then
                local ch = _safe_method(diff_mgr, "get_challenge")
                local rs = _safe_method(diff_mgr, "get_resistance")
                if ch == nil or rs == nil then return nil end
                local ok_tier, tier = pcall(_danger_utility.danger_by_difficulty, ch, rs)
                is_auric = ok_tier and tier and tier.is_auric or false
            end

            if is_maelstrom then
                suffix = " (Auric Maelstrom)"
            elseif is_auric then
                suffix = " (Auric)"
            end
        end

        return display_name .. suffix
    end)
    return (ok and result) or nil
end

HudElementPlayerNotes.init = function(self, parent, draw_layer, start_scale)
    self._parent        = parent
    self._scan_timer    = 0        -- fire first scan on next update
    self._active        = {}       -- player_unit → marker_id
    self._active_notes  = {}       -- player_unit → note text (for change detection)
    self._active_appearance_revisions = {} -- player_unit → appearance revision
    self._seen_buffer   = {}       -- Persistent buffer to avoid RAM churn
    self._in_mission    = nil
    self._current_location = nil
    self._notification_timer = 3.0
    self._notification_attempts = 0
    self._notification_error_reported = false
    self._scan_error_reported = false
    self._destroyed = false
    
    -- The main module keeps a per-game-state completion guard, so HUD recreation
    -- (for example when changing operatives) cannot duplicate a notification.
end


HudElementPlayerNotes.update = function(self, dt, t)
    if self._destroyed then return end

    -- Handle the notification timer first. Loading transitions can leave
    -- Managers incomplete, so retry briefly instead of raising every frame.
    if self._notification_timer > 0 then
        self._notification_timer = self._notification_timer - dt
        if self._notification_timer <= 0 then
            local notify = _api.notify_players
            local ok, completed = notify and pcall(notify)
            if ok and completed ~= false then
                self._notification_timer = 0
                self._notification_error_reported = false
            else
                self._notification_attempts = self._notification_attempts + 1
                if self._notification_attempts < NOTIFICATION_MAX_ATTEMPTS then
                    self._notification_timer = NOTIFICATION_RETRY_INTERVAL
                else
                    self._notification_timer = 0
                    if not self._notification_error_reported then
                        mod:echo("[PlayerNotes] Session notification could not initialize.")
                        self._notification_error_reported = true
                    end
                end
            end
        end
    end

    self._scan_timer = self._scan_timer - dt
    if self._scan_timer > 0 then return end
    self._scan_timer = SCAN_INTERVAL

    local ok, scan_error = pcall(self._scan_players, self)
    if not ok then
        if not self._scan_error_reported then
            mod:echo("[PlayerNotes] HUD player scan failed: " .. tostring(scan_error))
            self._scan_error_reported = true
        end
    else
        self._scan_error_reported = false
    end
end

local function _remove_marker(self, unit, event_manager)
    local marker_id = self._active[unit]
    if marker_id and event_manager then
        _safe_method(event_manager, "trigger", "remove_world_marker", marker_id)
    end
    self._active[unit] = nil
    self._active_notes[unit] = nil
    self._active_appearance_revisions[unit] = nil
end

local function _scan_player(
    self,
    player,
    my_player,
    social,
    event_manager,
    alive,
    seen,
    current_location,
    markers_enabled
)
    if player == my_player then return end
    if _safe_method(player, "is_human_controlled") == false then return end

    local unit = player and player.player_unit
    if not unit or not alive[unit] then return end

    local account_id = _safe_method(player, "account_id")
    if not account_id then return end

    local player_info = _safe_method(social, "get_player_info_by_account_id", account_id)

    local get_player_key = _api.get_player_key
    local puid = player_info and get_player_key and get_player_key(player_info)
    if not puid
        and (type(account_id) == "string" or type(account_id) == "number")
        and account_id ~= "" then
        puid = account_id
    end
    if not puid or puid == "" then return end

    local display_name
    if player_info and _api.get_player_display_name then
        display_name = _api.get_player_display_name(player_info, true, true)
    elseif player_info then
        display_name = _safe_method(player_info, "user_display_name", true, true)
    end

    -- Character mappings support /set_note even before a note exists. They are
    -- bounded separately, while last-seen history is retained only for noted
    -- players so it cannot grow with every random teammate.
    local char_name = _safe_method(player, "name")
    if _safe_method(player_info, "is_blocked") ~= true and _api.update_char then
        if type(char_name) == "string" and char_name ~= "" then
            _api.update_char(
                char_name,
                puid,
                display_name or "",
                current_location == "Mourningstar" and "hub" or "mission"
            )
        end
    end

    local get_note = _api.get_note
    local note = get_note and get_note(puid)

    if note and current_location and _api.update_last_seen then
        _api.update_last_seen(puid, current_location)
    end

    if not markers_enabled or not note then
        _remove_marker(self, unit, event_manager)
        return
    end

    seen[unit] = true

    local get_appearance_revision = _api.get_world_note_appearance_revision
    local appearance_revision = get_appearance_revision
        and get_appearance_revision()
        or 0
    if self._active[unit] then
        if self._active_notes[unit] == note
            and self._active_appearance_revisions[unit] == appearance_revision then
            return
        end
        _remove_marker(self, unit, event_manager)
    end

    event_manager:trigger(
        "add_world_marker_unit",
        "pn_note",
        unit,
        function(marker_id)
            if self._destroyed then
                _safe_method(event_manager, "trigger", "remove_world_marker", marker_id)
                return
            end
            self._active[unit] = marker_id
            self._active_notes[unit] = note
            self._active_appearance_revisions[unit] = appearance_revision
        end,
        { puid = puid, note = note }
    )
end

HudElementPlayerNotes._scan_players = function(self)
    local in_mission = _is_in_mission()
    if in_mission == nil then return end
    if self._in_mission ~= in_mission then
        self._in_mission = in_mission
        self._current_location = nil
    end

    local markers_enabled = _settings.show_world_notes
        and (not in_mission or _settings.show_world_notes_in_missions)
    if not markers_enabled then
        self:_clear_all_markers()
    end

    local managers = rawget(_G, "Managers")
    local social = managers and managers.data_service and managers.data_service.social
    local player_manager = managers and managers.player
    local event_manager = managers and managers.event
    if not player_manager or (markers_enabled and not event_manager) then return end

    -- Resolve location only after game-mode state is available. If a mission
    -- resolver is still incomplete, leave it uncached and retry on the next scan.
    local current_location = self._current_location
    if current_location == nil then
        if in_mission then
            current_location = _get_current_location()
        else
            current_location = "Mourningstar"
        end
        self._current_location = current_location
    end

    -- ALIVE is a Stingray engine global. Guard against the brief window during
    -- HUD init where it may not yet be populated.
    if not ALIVE then return end

    local my_player = _safe_method(self._parent, "player")
    local players = _safe_method(player_manager, "players")
    if type(players) ~= "table" then return end

    local alive     = ALIVE
    local seen      = self._seen_buffer
    _clear_table(seen)

    local player_error
    for _, player in pairs(players) do
        -- Preserve an existing marker if one malformed player object fails;
        -- otherwise end-of-scan cleanup would remove a still-valid marker.
        local unit = player and player.player_unit
        if unit and self._active[unit] then seen[unit] = true end

        local ok, error_message = pcall(
            _scan_player,
            self,
            player,
            my_player,
            social,
            event_manager,
            alive,
            seen,
            current_location,
            markers_enabled
        )
        if not ok then player_error = player_error or error_message end
    end

    -- Remove markers for players who have left or whose notes were deleted
    for unit, marker_id in pairs(self._active) do
        if not seen[unit] then
            _remove_marker(self, unit, event_manager)
        end
    end

    if _api.flush then
        local flush_ok, flush_error = pcall(_api.flush)
        if not flush_ok then player_error = player_error or flush_error end
    end

    if player_error then error(player_error, 0) end
end

HudElementPlayerNotes._clear_all_markers = function(self)
    if not next(self._active) then
        _clear_table(self._active_notes)
        _clear_table(self._active_appearance_revisions)
        _clear_table(self._seen_buffer)
        return
    end

    local managers = rawget(_G, "Managers")
    local event_mgr = managers and managers.event
    for unit, marker_id in pairs(self._active) do
        if marker_id and event_mgr then
            _safe_method(event_mgr, "trigger", "remove_world_marker", marker_id)
        end
    end
    _clear_table(self._active)
    _clear_table(self._active_notes)
    _clear_table(self._active_appearance_revisions)
    _clear_table(self._seen_buffer)
end

HudElementPlayerNotes.destroy = function(self)
    self._destroyed = true
    self:_clear_all_markers()
    self._parent = nil
end

return HudElementPlayerNotes
