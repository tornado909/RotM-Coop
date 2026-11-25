local script_path = "mod/RotMCoop/Scripts/"
package.path = script_path .. "?.lua;" .. package.path
RegisterBeginPlayPreHook = function() end
RegisterBeginPlayPostHook = function() end
StaticFindObject = function() end
local config = dofile(script_path .. "config.lua")
config.steam_lobbies_enabled = false
config.network_motion_tuning = false
local function object(name, fields)
    local value = fields or {}
    function value:IsValid() return true end
    function value:GetFullName() return name end
    return value
end

local old_world = object("World /Game/MainMenu.MainMenu")
local hub = object("World /Game/Arenas/MageHub_New/MageHub_New.MageHub_New")
local world = old_world
local mode = "client"
local player_state = object("PlayerState")
local controller = object("PlayerController", { PlayerState = player_state, Pawn = object("DefaultPawn") })
local game_mode = object("MenuGameMode")
local state = object("GameState", { PlayerArray = { player_state } })
local commands, messages, scheduled, keys = {}, {}, {}, {}
local system = object("KismetSystemLibrary", {
    IsStandalone = function(_, context) return context == world and mode == "standalone" end,
    IsServer = function(_, context) return context == world and mode == "server" end,
    ExecuteConsoleCommand = function(_, context, command, player)
        assert(context == world and player == controller)
        commands[#commands + 1] = command
    end,
})
local statics = object("GameplayStatics", {
    GetPlayerController = function(_, context, index)
        assert(context == world and index == 0)
        return controller
    end,
    GetGameMode = function(_, context)
        assert(context == world)
        return game_mode
    end,
    GetGameState = function(_, context)
        assert(context == world)
        return state
    end,
})
package.loaded.UEHelpers = {
    GetGameViewportClient = function()
        return object("GameViewport", { GetWorld = function() return world end })
    end,
    GetGameInstance = function() error("The viewport world is available") end,
    GetKismetSystemLibrary = function() return system end,
    GetGameplayStatics = function() return statics end,
}
package.loaded.config = config
Key = { F5 = 5, F6 = 6, F7 = 7 }
ModifierKey = { CONTROL = 1 }
RegisterKeyBind = function(key, _, callback) keys[key] = callback end
LoopInGameThreadWithDelay = function() return 1 end
ExecuteInGameThread = function(callback) callback() end
ExecuteInGameThreadWithDelay = function(delay, callback)
    scheduled[#scheduled + 1] = { delay = delay, callback = callback }
end

local original_print = print
print = function(message) messages[#messages + 1] = message end
local function expect_message(message)
    assert(table.concat(messages):find(message, 1, true), "Missing log message: " .. message)
    messages = {}
end

dofile(script_path .. "main.lua")
assert(#commands == 0 and #scheduled == 0, "Startup must leave the session alone")

keys[Key.F6]()
assert(commands[1] == "open 127.0.0.1:7777")
assert(scheduled[1].delay == 2000 and scheduled[2].delay == 10000 and scheduled[3].delay == 30000)
scheduled[1].callback()
expect_message("guest readiness: waiting for server world")

world, game_mode, state = hub, nil, nil
controller.PlayerState, controller.Pawn = nil, nil
scheduled[2].callback()
expect_message("player states: unavailable")
keys[Key.F7]()
expect_message("guest readiness: waiting for local PlayerState")

controller.PlayerState = player_state
keys[Key.F7]()
expect_message("guest readiness: waiting for local pawn")

controller.Pawn = object("MagePawn")
scheduled[3].callback()
expect_message("guest readiness: local pawn possessed")

mode = "standalone"
keys[Key.F5]()
assert(commands[2] == "open /Game/Arenas/MageHub_New/MageHub_New?listen")
config.diagnostic_engine_game_mode = true
keys[Key.F5]()
assert(commands[3] == commands[2] .. "?game=/Script/Engine.GameModeBase")
messages = {}
scheduled[4].callback()
assert(#messages == 0, "Superseded travel must not log a snapshot")

original_print("Travel diagnostics passed")
