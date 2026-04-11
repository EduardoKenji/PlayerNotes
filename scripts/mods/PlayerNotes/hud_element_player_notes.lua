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

HudElementPlayerNotes.init = function(self, parent, draw_layer, start_scale)
    self._parent     = parent
    self._scan_timer = 0        -- fire first scan on next update
    self._active     = {}       -- player_unit → marker_id
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

    local my_player = self._parent:player()
    local players   = Managers.player:players()
    local notes     = mod:get("player_notes") or {}
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
            -- Mission context has the highest priority (see update_char_to_player in PlayerNotes.lua).
            -- mod._fn_update_char is set at PlayerNotes.lua load time.
            local char_name = player:name()
            if char_name and char_name ~= "" and mod._fn_update_char then
                local display_name = player_info:user_display_name()
                mod._fn_update_char(char_name, puid, display_name, "mission")
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

            if self._active[unit] then break end   -- marker already present

            local data = { puid = puid, note = note }
            local captured_unit = unit
            event_mgr:trigger("add_world_marker_unit", "pn_note", unit,
                function(marker_id)
                    self._active[captured_unit] = marker_id
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
end

return HudElementPlayerNotes
