local UEHelpers = require("UEHelpers")
local Config = require("config")
local early_controller = require("early_controller")
local travel_id = 0
local session_travel
local steam_menu

local function log(message)
    print("[RotMCoop] " .. tostring(message) .. "\n")
end

-- One dispatcher owns every periodic UE4SS callback; no concurrent Lua timers.
local jobs,clock,busy={},0,false
local function every(ms,fn)
    jobs[#jobs+1]={ms=ms,fn=fn,next=clock+ms}
end
local function valid(object)
    return object and object:IsValid()
end

local function full_name(object)
    return valid(object) and tostring(object:GetFullName()) or "unavailable"
end

local function current_world()
    local viewport = UEHelpers.GetGameViewportClient()
    local world = valid(viewport) and viewport:GetWorld()
    if valid(world) then
        return world
    end
    return nil
end

-- No gameplay polling while UE is creating the initial viewport / controllers.
-- Wait for a live controller in a real world, stable across successive frames.
local startup = require("startup_gate").new(1500)
local function start_dispatcher()
    LoopAsync(100,function()
        if busy then return false end
        busy=true
        ExecuteInGameThread(function()
            local ok,e=pcall(function()
                clock=clock+100
                if not startup.ready then
                    local w=current_world()
                    local id=valid(w) and full_name(w) or ""
                    local ready=false
                    if id:find("/Game/Arenas/",1,true) then
                        local st=UEHelpers.GetGameplayStatics()
                        local c=valid(st) and st:GetPlayerController(w,0)
                        ready=valid(c) and c.bIsLocalPlayerController==true
                    end
                    if not startup:step(id,ready,100) then return end
                    log("Startup gate: stable game world and local controller")
                end
                for _,job in ipairs(jobs)do
                    if clock>=job.next then
                        job.next=clock+job.ms
                        local safe,err=pcall(job.fn)
                        if not safe then log("Dispatcher: "..tostring(err)) end
                    end
                end
            end)
            busy=false
            if not ok then log("Startup dispatcher: "..tostring(e)) end
        end)
        return false
    end)
end

local function current_map_path(world)
    if valid(world) then
        return full_name(world):match("^World%s+(/Game/[%w_/%-]+)%.")
    end
end

local function execute_console(world, command)
    local system = UEHelpers.GetKismetSystemLibrary()
    if not valid(world) or not valid(system) then
        log("Cannot execute '" .. command .. "': world or KismetSystemLibrary unavailable")
        return
    end

    local statics = UEHelpers.GetGameplayStatics()
    if not valid(statics) then
        log("Cannot execute '" .. command .. "': GameplayStatics unavailable")
        return
    end

    local controller = statics:GetPlayerController(world, 0)
    if not valid(controller) then
        log("Cannot execute '" .. command .. "': local controller unavailable")
        return
    end

    log("Requesting console command: " .. command)
    system:ExecuteConsoleCommand(world, command, controller)
    return true
end

local function status(label)
    log("snapshot: " .. label)
    local world = current_world()
    if not valid(world) then
        log("world: unavailable")
        return
    end

    local system = UEHelpers.GetKismetSystemLibrary()
    local statics = UEHelpers.GetGameplayStatics()
    local mode = "unavailable"
    if valid(system) then
        if system:IsStandalone(world) then
            mode = "standalone"
        elseif system:IsServer(world) then
            mode = "server"
        else
            mode = "client"
        end
    end

    local controller = valid(statics) and statics:GetPlayerController(world, 0)
    local state = valid(statics) and statics:GetGameState(world)
    local game_mode = valid(statics) and statics:GetGameMode(world)
    local player_states = valid(state) and state.PlayerArray
    local local_state = valid(controller) and controller.PlayerState
    local pawn = valid(controller) and controller.Pawn
    log("world: " .. full_name(world))
    log("net mode: " .. mode)
    log("game mode: " .. full_name(game_mode))
    log("game state: " .. full_name(state))
    log("player states: " .. (player_states and tostring(#player_states) or "unavailable"))
    log("local controller: " .. full_name(controller))
    log("local player state: " .. full_name(local_state))
    log("local pawn: " .. full_name(pawn))
    if mode == "client" then
        local readiness = "waiting for local PlayerState"
        if valid(game_mode) then
            readiness = "waiting for server world"
        elseif valid(local_state) then
            readiness = valid(pawn) and "local pawn possessed" or "waiting for local pawn"
        end
        log("guest readiness: " .. readiness)
    end
end

local function travel(world, command, action)
    if not execute_console(world, command) then
        return
    end

    travel_id = travel_id + 1
    local id = travel_id
    for _, seconds in ipairs({ 2, 10, 30 }) do
        ExecuteInGameThreadWithDelay(seconds * 1000, function()
            if travel_id == id then
                status(action .. " +" .. seconds .. "s")
            end
        end)
    end
    return true
end

local function host(explicit_map)
    local world = current_world()
    local map = explicit_map or current_map_path(world)
    if type(map) ~= "string" or not map:match("^/Game/[%w_/%-]+$") then
        log("Host requires a loaded game map")
        return
    end

    local options = "?listen"
    if Config.diagnostic_engine_game_mode == true then
        log("Hosting with the Unreal GameModeBase control")
        options = options .. "?game=/Script/Engine.GameModeBase"
    end
    travel(world, "open " .. map .. options, "host")
end

local current_join_address = Config.join_address
local function join(address_override)
    if type(address_override) == "string" then
        current_join_address = address_override
    end
    local address = current_join_address
    local hostname, port
    if type(address) == "string" then
        hostname, port = address:match("^([%w][%w.%-]*):(%d+)$")
    end
    port = tonumber(port)
    if not hostname or not port or port < 1 or port > 65535 then
        log("Join requires host:port in Scripts/config.lua")
        return
    end

    local started = travel(current_world(), "open " .. hostname .. ":" .. port, "join")
    if started then
        if session_travel then session_travel.note_join() end
        if Config.steam_lobbies_enabled == true and steam_menu then
            steam_menu.mark_client_connecting()
        end
    end
end

session_travel = require("session_travel")
session_travel.install(Config, {
    every = every,
    log = log,
    current_world = current_world,
    join = join,
    can_reconnect = function()
        return not steam_menu or steam_menu.can_reconnect()
    end,
    on_host_travel = function(destination)
        if steam_menu then steam_menu.mark_host_travel(destination) end
    end,
    on_guest_ready = function()
        if steam_menu then steam_menu.mark_client_ready() end
    end,
    on_guest_disconnected = function()
        if steam_menu then steam_menu.mark_client_disconnected() end
    end,
})

require("network_motion").install(Config, {
    every = every,
    log = log,
    current_world = current_world,
})

require("hud_spells").install(Config, {
    every = every,
    log = log,
    current_world = current_world,
})

require("guest_spawn").install(Config, { every=every, log = log, current_world = current_world })

steam_menu = require("steam_menu")
steam_menu.install(Config, {
    every = every,
    log = log,
    current_world = current_world,
    host = function() host("/Game/Arenas/MageHub_New/MageHub_New") end,
    host_current = function() host() end,
    join = join,
})

require("party_loadout").install(Config, { every=every, log=log, current_world=current_world, state=steam_menu.get_state, send=steam_menu.send_party, profiles=steam_menu.profiles })
require("party_identity").install(Config, { every=every, log=log, current_world=current_world })
require("party_gate").install(Config, { every=every, log=log, current_world=current_world })
require("party_loading").install(Config, { every=every, log=log, current_world=current_world, state=steam_menu.get_state })
require("party_gameplay").install(Config, { every=every, log=log, current_world=current_world, state=steam_menu.get_state, send=steam_menu.send_party, read=steam_menu.read_party })

RegisterKeyBind(Key.F5, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function() host() end)
end)
RegisterKeyBind(Key.F6, { ModifierKey.CONTROL }, function()
    if Config.steam_lobbies_enabled == true then
        log("Use СЕТЕВАЯ ИГРА to join through Steam P2P (no direct IP)")
    else
        ExecuteInGameThread(join)
    end
end)
RegisterKeyBind(Key.F7, { ModifierKey.CONTROL }, function()
    ExecuteInGameThread(function() status("manual") end)
end)

early_controller.set_enabled(function()
    if not startup.ready then return false end
    if Config.steam_lobbies_enabled~=true then return true end
    return steam_menu.is_party_active()
end)
start_dispatcher()
log("Loaded. Ctrl+F5 host, Ctrl+F6 join, Ctrl+F7 status")

if Config.auto_action == "host" or Config.auto_action == "join" then
    local delay = Config.auto_delay_ms or 8000
    ExecuteInGameThreadWithDelay(delay, function()
        if Config.auto_action == "host" then
            host(Config.auto_map)
        else
            join()
        end
    end)
end
