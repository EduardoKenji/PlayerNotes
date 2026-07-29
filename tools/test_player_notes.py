"""Behavioral smoke tests for PlayerNotes outside Darktide.

The harness supplies small DMF/Darktide test doubles and executes the real Lua
modules through Lupa. Install development dependencies with:

    python -m pip install lupa luaparser
"""

from __future__ import annotations

import unittest
from pathlib import Path

try:
    from lupa import LuaRuntime
except ImportError:  # pragma: no cover - handled by the explicit skip below
    LuaRuntime = None


ROOT = Path(__file__).resolve().parents[1]
MAIN_MODULE = ROOT / "scripts/mods/PlayerNotes/PlayerNotes.lua"
HUD_MODULE = ROOT / "scripts/mods/PlayerNotes/hud_element_player_notes.lua"


LUA_PRELUDE = r"""
local unpack_values = table.unpack or unpack

mod = {
    _settings = {},
    _commands = {},
    _hooks = {},
    _safe_hooks = {},
    _echoes = {},
    _set_counts = {},
}

function mod:get(key)
    return self._settings[key]
end

function mod:set(key, value)
    self._settings[key] = value
    self._set_counts[key] = (self._set_counts[key] or 0) + 1
end

function mod:echo(message)
    self._echoes[#self._echoes + 1] = tostring(message)
end

function mod:localize(key, ...)
    local values = {
        btn_add_note = "Add Note",
        echo_selected = "Selected %s — type /note [text] to save.",
        echo_saved = "Note saved for %s.",
        echo_none_selected = "Click Add Note or Edit Note on a player first.",
        echo_usage_note = "Usage: /note [your note text]",
    }
    return string.format(values[key] or key, ...)
end

function mod:command(name, description, command)
    self._commands[name] = command
end

local function hook_key(target, method_name)
    local target_name = type(target) == "table" and target.__name or tostring(target)
    return tostring(target_name) .. "." .. method_name
end

function mod:hook(target, method_name, callback_function)
    self._hooks[hook_key(target, method_name)] = callback_function
end

function mod:hook_safe(target, method_name, callback_function)
    self._safe_hooks[hook_key(target, method_name)] = callback_function
end

function mod:hook_require(path, callback_function)
    -- Module mutations are integration-tested in Darktide. Avoid fabricating
    -- entire view definitions in this focused behavioral harness.
end

function mod:register_hud_element(definition)
    self._registered_hud_element = definition
end

function get_mod(name)
    assert(name == "PlayerNotes")
    return mod
end

function callback(parent, method_name, ...)
    local fixed = { ... }
    return function()
        return parent[method_name](parent, unpack_values(fixed))
    end
end

function class(name)
    return { __name = name }
end

CLASS = {
    ViewElementPlayerSocialPopup = { __name = "ViewElementPlayerSocialPopup" },
    SocialMenuRosterView = { __name = "SocialMenuRosterView" },
    UIConstantElements = { __name = "UIConstantElements" },
    GroupFinderView = { __name = "GroupFinderView" },
}

function table.find_by_key(values, key, expected)
    for i = 1, #values do
        if values[i][key] == expected then return values[i] end
    end
end

function table.append(target, values)
    for i = 1, #values do target[#target + 1] = values[i] end
end

Color = setmetatable({}, {
    __index = function()
        return function() return { 255, 255, 255, 255 } end
    end,
})

Vector3 = {
    x = function(value) return value[1] end,
    y = function(value) return value[2] end,
}

RESOLUTION_LOOKUP = {
    scale = 1,
    inverse_scale = 1,
    width = 1920,
    height = 1080,
}

ALIVE = {}
Localize = function(key) return key end
math.ease_exp = function(value) return value end
__test_time = 100
os.time = function() return __test_time end

local UIWidget = {}
function UIWidget.create_definition(passes, scenegraph_id)
    return { passes = passes, scenegraph_id = scenegraph_id }
end
function UIWidget.init(name, definition)
    local widget = {
        name = name,
        content = {},
        style = {},
        offset = { 0, 0, 0 },
        visible = false,
    }
    for i = 1, #definition.passes do
        local pass = definition.passes[i]
        if pass.style_id then widget.style[pass.style_id] = pass.style end
        if pass.value_id then widget.content[pass.value_id] = pass.value end
    end
    return widget
end
function UIWidget.draw(widget, renderer)
    if __fail_widget_draw then error("injected widget failure") end
    renderer.draw_count = (renderer.draw_count or 0) + 1
end

local UIRenderer = {}
function UIRenderer.begin_pass(renderer)
    renderer.pass_open = true
end
function UIRenderer.end_pass(renderer)
    renderer.pass_open = false
end

local UIScenegraph = {}
function UIScenegraph.init_scenegraph(definition, scale)
    return { definition = definition, scale = scale }
end
function UIScenegraph.update_scenegraph(scenegraph, scale)
    scenegraph.scale = scale
end

local ButtonPassTemplates = {
    terminal_button_change_function = function() end,
    terminal_button_hover_change_function = function() end,
}

local modules = {
    ["scripts/settings/ui/ui_sound_events"] = {
        social_menu_see_player_profile = "profile",
    },
    ["scripts/managers/ui/ui_widget"] = UIWidget,
    ["scripts/managers/ui/ui_renderer"] = UIRenderer,
    ["scripts/managers/ui/ui_scenegraph"] = UIScenegraph,
    ["scripts/settings/ui/ui_workspace_settings"] = {
        screen = { size = { 1920, 1080 } },
    },
    ["scripts/ui/pass_templates/button_pass_templates"] = ButtonPassTemplates,
    ["scripts/settings/mission/mission_templates"] = {},
    ["scripts/utilities/danger"] = {
        danger_by_difficulty = function() return { is_auric = false } end,
    },
}

function require(path)
    return modules[path] or {}
end
"""


def _to_lua(lua: LuaRuntime, value):
    if isinstance(value, dict):
        table = lua.table()
        for key, item in value.items():
            table[key] = _to_lua(lua, item)
        return table
    if isinstance(value, (list, tuple)):
        table = lua.table()
        for index, item in enumerate(value, 1):
            table[index] = _to_lua(lua, item)
        return table
    return value


@unittest.skipIf(LuaRuntime is None, "Install the 'lupa' package to run Lua behavior tests")
class PlayerNotesBehaviorTests(unittest.TestCase):
    def make_runtime(self, settings=None):
        lua = LuaRuntime(unpack_returned_tuples=True)
        lua.execute(LUA_PRELUDE)
        mod = lua.globals().mod
        for key, value in (settings or {}).items():
            mod._settings[key] = _to_lua(lua, value)
        lua.execute(MAIN_MODULE.read_text(encoding="utf-8-sig"))
        return lua, mod

    def test_platform_identity_is_migrated_to_account_identity(self):
        lua, mod = self.make_runtime(
            {
                "player_notes": {"platform-old": "legacy note"},
                "player_names": {"platform-old": "Veteran"},
                "name_to_ids": {"Veteran": ["platform-old"]},
                "char_to_player": {
                    "Varlet": {
                        "puid": "platform-old",
                        "display_name": "Veteran",
                        "last_seen": 10,
                        "context": "mission",
                    }
                },
                "player_last_seen": {
                    "platform-old": {"ts": 20, "loc": "Mourningstar"}
                },
            }
        )
        player_info = lua.execute(
            """
            return {
                account_id = function() return "account-new" end,
                platform_user_id = function() return "platform-old" end,
            }
            """
        )

        self.assertEqual(mod._api.get_player_key(player_info), "account-new")
        mod._api.flush()

        self.assertEqual(mod._settings.player_notes["account-new"], "legacy note")
        self.assertIsNone(mod._settings.player_notes["platform-old"])
        self.assertEqual(mod._settings.player_names["account-new"], "Veteran")
        self.assertEqual(
            mod._settings.char_to_player["Varlet"]["puid"], "account-new"
        )
        self.assertEqual(
            mod._settings.player_last_seen["account-new"]["loc"], "Mourningstar"
        )

    def test_note_lookup_never_falls_back_to_a_shared_display_name(self):
        _, mod = self.make_runtime(
            {
                "player_notes": {"old-account": "private old note"},
                "name_to_ids": {"SharedName": ["old-account"]},
            }
        )

        self.assertIsNone(mod._api.get_note("different-account", "SharedName"))
        self.assertEqual(mod._api.get_note("old-account"), "private old note")

    def test_malformed_persisted_entries_are_sanitized(self):
        _, mod = self.make_runtime(
            {
                "player_notes": {
                    "good": "  valid note  ",
                    "bad": 42,
                },
                "player_names": {
                    "good": "Good",
                    "bad": 42,
                },
                "name_to_ids": {
                    "Good": {
                        1: "good",
                        2: "good",
                        "extra": "bad",
                    }
                },
                "char_to_player": {
                    "Invalid": {"display_name": "Nobody"},
                },
                "player_last_seen": {
                    "good": {"ts": "20", "loc": "x" * 300},
                    "orphan": {"ts": 20, "loc": "Mourningstar"},
                },
            }
        )

        mod._api.flush()
        self.assertEqual(mod._settings.player_notes["good"], "valid note")
        self.assertIsNone(mod._settings.player_notes["bad"])
        self.assertIsNone(mod._settings.player_names["bad"])
        self.assertEqual(mod._settings.name_to_ids["Good"][1], "good")
        self.assertIsNone(mod._settings.name_to_ids["Good"][2])
        self.assertIsNone(mod._settings.name_to_ids["Good"]["extra"])
        self.assertIsNone(mod._settings.char_to_player)
        self.assertEqual(mod._settings.player_last_seen["good"]["ts"], 20)
        self.assertLessEqual(
            len(mod._settings.player_last_seen["good"]["loc"]), 163
        )
        self.assertIsNone(mod._settings.player_last_seen["orphan"])

        for index in range(1, 252):
            mod._api.update_char(
                f"Character{index}",
                f"account-{index}",
                f"Player{index}",
                "mission",
            )
        mod._api.flush()
        self.assertEqual(
            sum(1 for _ in mod._settings.char_to_player.items()),
            200,
        )

    def test_temporary_platform_fallback_upgrades_after_cooldown(self):
        lua, mod = self.make_runtime(
            {"player_notes": {"platform-only": "migrate me"}}
        )
        player_info = lua.execute(
            """
            __account_value = nil
            return {
                account_id = function() return __account_value end,
                platform_user_id = function() return "platform-only" end,
            }
            """
        )

        self.assertEqual(mod._api.get_player_key(player_info), "platform-only")
        lua.globals()["__account_value"] = "account-ready"
        self.assertEqual(mod._api.get_player_key(player_info), "platform-only")
        lua.globals()["__test_time"] = 102
        self.assertEqual(mod._api.get_player_key(player_info), "account-ready")
        mod._api.flush()
        self.assertEqual(mod._settings.player_notes["account-ready"], "migrate me")
        self.assertIsNone(mod._settings.player_notes["platform-only"])

    def test_session_notification_skips_local_player_and_bots(self):
        lua, mod = self.make_runtime(
            {"player_notes": {"remote-account": "noted"}}
        )
        result = lua.execute(
            """
            local local_player = {
                is_human_controlled = function() return true end,
                account_id = function() return "local-account" end,
            }
            local bot = {
                is_human_controlled = function() return false end,
            }
            local remote = {
                is_human_controlled = function() return true end,
                account_id = function() return "remote-account" end,
                name = function() return "RemoteCharacter" end,
            }
            local trigger_count = 0
            Managers = {
                player = {
                    players = function()
                        return {
                            [1] = local_player,
                            [2] = bot,
                            [3] = remote,
                        }
                    end,
                    local_player = function(self, local_player_id)
                        assert(local_player_id == 1)
                        return local_player
                    end,
                },
                data_service = {
                    social = {
                        get_player_info_by_account_id = function(self, account_id)
                            return {
                                account_id = function() return account_id end,
                                platform_user_id = function() return nil end,
                                user_display_name = function() return "RemoteTag" end,
                            }
                        end,
                    },
                },
                event = {
                    trigger = function()
                        trigger_count = trigger_count + 1
                    end,
                },
            }

            local first_completed = mod._api.notify_players()
            mod._notification_done_for_session = false
            Managers.player.players = function()
                return {
                    [1] = local_player,
                    [2] = bot,
                }
            end
            local bot_only_completed = mod._api.notify_players()
            return {
                first_completed = first_completed,
                bot_only_completed = bot_only_completed,
                trigger_count = trigger_count,
            }
            """
        )

        self.assertTrue(result["first_completed"])
        self.assertTrue(result["bot_only_completed"])
        self.assertEqual(result["trigger_count"], 1)

    def test_note_length_delete_cleanup_and_delete_all_confirmation(self):
        _, mod = self.make_runtime(
            {
                "player_notes": {"account": "old"},
                "player_names": {"account": "Space Marine"},
                "name_to_ids": {"Space Marine": ["account"]},
                "player_last_seen": {
                    "account": {"ts": 20, "loc": "Mourningstar"}
                },
            }
        )

        mod._editing_puid = "account"
        mod._editing_name = "Space Marine"
        mod._commands["note"]("x" * 600)
        self.assertEqual(len(mod._settings.player_notes["account"]), 512)
        self.assertEqual(mod._echoes[1], "Note saved for Space Marine.")

        mod._editing_puid = "account"
        mod._editing_name = "Space Marine"
        mod._commands["note"]("é" * 600)
        self.assertEqual(len(mod._settings.player_notes["account"]), 512)

        mod._commands["set_note"]("Space", "Marine", "short", "note")
        self.assertEqual(mod._settings.player_notes["account"], "short note")

        mod._commands["delete_note"]("Space", "Marine")
        self.assertIsNone(mod._settings.player_notes)
        self.assertIsNone(mod._settings.player_last_seen)

        _, confirm_mod = self.make_runtime(
            {"player_notes": {"other": "keep"}}
        )
        confirm_mod._commands["pn_notes_delete_all"]()
        self.assertEqual(confirm_mod._settings.player_notes["other"], "keep")
        confirm_mod._commands["pn_notes_delete_all"]("confirm")
        self.assertIsNone(confirm_mod._settings.player_notes)

    def test_overlay_restores_shared_render_layer_after_draw_failure(self):
        lua, mod = self.make_runtime()
        draw_hook = mod._safe_hooks["UIConstantElements.draw"]
        renderer = lua.table()
        render_settings = _to_lua(lua, {"start_layer": 42})
        constant_elements = _to_lua(
            lua,
            {
                "_ui_renderer": renderer,
                "_render_settings": render_settings,
            },
        )
        input_service = lua.table()
        mod._hovered_note = "note"
        mod._cached_top_bar_text = "Player — note"
        mod._last_hover_time = 10
        lua.globals().__fail_widget_draw = True

        draw_hook(constant_elements, 0.016, 10, input_service)

        self.assertEqual(render_settings["start_layer"], 42)
        self.assertFalse(renderer["pass_open"])

    def test_hud_continues_after_one_player_marker_failure(self):
        lua, mod = self.make_runtime(
            {
                "player_notes": {
                    "bad-account": "bad marker",
                    "good-account": "good marker",
                }
            }
        )
        hud_class = lua.execute(HUD_MODULE.read_text(encoding="utf-8-sig"))
        scenario = lua.execute(
            """
            local Hud = ...
            local local_player = { player_unit = {} }
            local bad_unit = {}
            local good_unit = {}
            local unnoted_unit = {}
            ALIVE[bad_unit] = true
            ALIVE[good_unit] = true
            ALIVE[unnoted_unit] = true

            local function player(unit, account_id, character_name)
                return {
                    player_unit = unit,
                    account_id = function() return account_id end,
                    name = function() return character_name end,
                }
            end

            local bad = player(bad_unit, "bad-account", "Bad")
            local good = player(good_unit, "good-account", "Good")
            local unnoted = player(unnoted_unit, "unnoted-account", "Unnoted")

            local function player_info(account_id)
                return {
                    account_id = function() return account_id end,
                    platform_user_id = function() return nil end,
                    user_display_name = function() return account_id end,
                    is_blocked = function() return false end,
                }
            end

            local social = {
                get_player_info_by_account_id = function(self, account_id)
                    return player_info(account_id)
                end,
            }
            local event = {
                trigger = function(self, event_name, marker_type, unit, cb)
                    if event_name == "add_world_marker_unit" then
                        if unit == bad_unit then error("injected marker failure") end
                        cb("marker-good")
                    end
                end,
            }
            Managers = {
                data_service = { social = social },
                event = event,
                player = {
                    players = function()
                        return {
                            [1] = bad,
                            [2] = good,
                            [3] = unnoted,
                            [4] = local_player,
                        }
                    end,
                },
                state = {
                    game_mode = {
                        game_mode_name = function() return "hub" end,
                    },
                },
            }

            local parent = {
                player = function() return local_player end,
            }
            local instance = setmetatable({}, { __index = Hud })
            instance:init(parent, 0, 1)
            local ok, err = pcall(instance._scan_players, instance)
            return {
                ok = ok,
                error = err,
                instance = instance,
                bad_unit = bad_unit,
                good_unit = good_unit,
                unnoted_unit = unnoted_unit,
            }
            """,
            hud_class,
        )

        self.assertFalse(scenario["ok"])
        self.assertIsNone(scenario["instance"]._active[scenario["bad_unit"]])
        self.assertEqual(
            scenario["instance"]._active[scenario["good_unit"]], "marker-good"
        )
        self.assertIsNotNone(mod._settings.player_last_seen["good-account"])
        self.assertIsNone(mod._settings.player_last_seen["unnoted-account"])


class LuaSyntaxTests(unittest.TestCase):
    def test_all_lua_files_parse(self):
        try:
            from luaparser import ast
        except ImportError:
            self.skipTest("Install the 'luaparser' package to run syntax tests")

        for path in ROOT.rglob("*.lua"):
            with self.subTest(path=path.relative_to(ROOT)):
                ast.parse(path.read_text(encoding="utf-8-sig"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
