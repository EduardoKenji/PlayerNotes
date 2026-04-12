-- hud_element_player_notes.lua
-- HUD element that scans in-session players every SCAN_INTERVAL seconds and
-- adds/removes "pn_note" world marker units for players who have a saved note.
-- The actual rendering is handled by HudElementWorldMarkers via the template.
--
-- Player identity chain:
--   player:account_id()
--     → Managers.data_service.social:get_player_info_by_account_id(account_id)
--       → player_info:platform_user_id()  (Steam ID / Xbox XUID / PSN)
--         → mod:get("player_notes")[puid]

local mod = get_mod("PlayerNotes")

local HudElementPlayerNotes = class("HudElementPlayerNotes")

local SCAN_INTERVAL = 2.0   -- seconds between full player scans

-- Returns true when the player is in a mission (not in the Morningstar/prologue hub).
-- Mirrors the hub detection used in hud_visibility_groups.lua and
-- constant_element_onboarding_handler.lua: both "hub" and "prologue_hub" are hub modes.
local function _is_in_mission()
    local gm = Managers.state and Managers.state.game_mode
    if not gm then return false end
    local name = gm:game_mode_name()
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
        local mission_key = Managers.state.mission and Managers.state.mission:mission_name()
        if not mission_key then return nil end

        -- Resolve human-readable mission name via the mission template.
        -- Template's mission_name field is a localization key (e.g. "loc_mission_name_cm_archives").
        local ok_tmpl, MissionTemplates = pcall(require, "scripts/settings/mission/mission_templates")
        local template    = ok_tmpl and MissionTemplates and MissionTemplates[mission_key]
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
        local diff_mgr = Managers.state.difficulty
        if diff_mgr then
            -- Havoc: has its own rank number, takes priority.
            local ok_hav, havoc_data = pcall(function() return diff_mgr:get_parsed_havoc_data() end)
            if ok_hav and havoc_data and havoc_data.havoc_rank then
                suffix = " (Havoc " .. tostring(havoc_data.havoc_rank) .. ")"
            else
                -- Auric Maelstrom: flash_mission circumstance at Auric tier.
                local circ_mgr     = Managers.state.circumstance
                local circ_name    = circ_mgr and circ_mgr:circumstance_name()
                local is_maelstrom = circ_name and circ_name:find("^flash_mission") ~= nil

                -- Auric: use Danger.danger_by_difficulty(challenge, resistance) — authoritative
                -- for ALL mission types including expeditions.
                -- pacing:is_auric() only works for standard missions (expedition pacing
                -- template never sets the is_auric flag). Danger utility is what the mission
                -- board and expedition view both use.
                -- Auric = challenge 5 + resistance 5; Damnation = challenge 5 + resistance 4.
                local is_auric = false
                local ok_d, Danger = pcall(require, "scripts/utilities/danger")
                if ok_d and Danger then
                    local ch = diff_mgr:get_challenge()
                    local rs = diff_mgr:get_resistance()
                    local ok_tier, tier = pcall(function() return Danger.danger_by_difficulty(ch, rs) end)
                    is_auric = ok_tier and tier and tier.is_auric or false
                end

                if is_maelstrom then
                    suffix = " (Auric Maelstrom)"
                elseif is_auric then
                    suffix = " (Auric)"
                end
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
end

HudElementPlayerNotes.update = function(self, dt, t)
    self._scan_timer = self._scan_timer - dt
    if self._scan_timer > 0 then return end
    self._scan_timer = SCAN_INTERVAL

    self:_scan_players()
end

HudElementPlayerNotes._scan_players = function(self)
    if not mod:get("show_world_notes") then
        self:_clear_all_markers()
        return
    end

    if _is_in_mission() and not mod:get("show_world_notes_in_missions") then
        self:_clear_all_markers()
        return
    end

    local social = Managers.data_service and Managers.data_service.social
    if not social then return end

    -- Capture current location once per scan for last-seen tracking.
    -- Only meaningful in missions; nil in hub (hub tracking handled by Social panel hooks).
    local current_location = _is_in_mission() and _get_current_location() or "Mourningstar"

    -- ALIVE is a Stingray engine global. Guard against the brief window during
    -- HUD init where it may not yet be populated.
    if not ALIVE then return end

    local my_player = self._parent:player()
    local players   = Managers.player:players()
    local notes     = mod._fn_get_notes and mod._fn_get_notes() or {}
    local event_mgr = Managers.event
    local alive     = ALIVE
    local seen      = {}   -- units that should have an active marker

    for _, player in pairs(players) do
        repeat
            if player == my_player then break end

            local unit = player.player_unit
            if not unit or not alive[unit] then break end

            local account_id = player.account_id and player:account_id()
            if not account_id then break end

            local player_info = social:get_player_info_by_account_id(account_id)
            if not player_info then break end

            local puid = player_info:platform_user_id()
            if not puid or puid == "" then break end

            -- Track character name → player mapping with "mission" context.
            -- Skip blocked players — character_name() returns a localized "Blocked Player"
            -- string for them, which would pollute the char_to_player map.
            -- use_stale=true, no_platform_icon=true matches the call form used everywhere else.
            if not player_info:is_blocked() and mod._fn_update_char then
                local char_name = player:name()
                if char_name and char_name ~= "" then
                    local display_name = player_info:user_display_name(true, true)
                    mod._fn_update_char(char_name, puid, display_name, "mission")
                end
            end

            -- Record last-seen location for this player (once per session via _session_seen guard).
            if current_location and mod._fn_update_last_seen then
                mod._fn_update_last_seen(puid, current_location)
            end

            local note = notes[puid]
            if not note then
                -- Player has no note: remove existing marker if any
                if self._active[unit] then
                    event_mgr:trigger("remove_world_marker", self._active[unit])
                    self._active[unit] = nil
                end
                break
            end

            seen[unit] = true

            -- If marker exists but note text changed, remove it to re-add with updated text.
            if self._active[unit] then
                if self._active_notes[unit] == note then break end  -- unchanged, keep it
                event_mgr:trigger("remove_world_marker", self._active[unit])
                self._active[unit]       = nil
                self._active_notes[unit] = nil
            end

            local data = { puid = puid, note = note }
            local captured_unit = unit
            event_mgr:trigger("add_world_marker_unit", "pn_note", unit,
                function(marker_id)
                    self._active[captured_unit]       = marker_id
                    self._active_notes[captured_unit] = note
                end,
                data)
        until true
    end

    -- Remove markers for players who have left or whose notes were deleted
    for unit, marker_id in pairs(self._active) do
        if not seen[unit] then
            if marker_id then
                event_mgr:trigger("remove_world_marker", marker_id)
            end
            self._active[unit] = nil
        end
    end
end

HudElementPlayerNotes._clear_all_markers = function(self)
    local event_mgr = Managers.event
    for unit, marker_id in pairs(self._active) do
        if marker_id then
            event_mgr:trigger("remove_world_marker", marker_id)
        end
    end
    table.clear(self._active)
    table.clear(self._active_notes)
end

return HudElementPlayerNotes
