-- Network level transition compatibility for Revenge of the Mage.
-- OpenLevel is a hard travel and does not bring connected guests along.
-- Keep the next map in listen mode, then let disconnected guests reconnect.
local UEHelpers = require("UEHelpers")
local Module = {}

local function valid(object)
    return object and object:IsValid()
end

local function converted(value)
    if type(value) == "string" then return value end
    if value == nil then return "" end
    local ok, text = pcall(function() return value:ToString() end)
    if ok and type(text) == "string" then return text end
    return nil
end

function Module.install(config, callbacks)
    local log = callbacks.log
    local current_world = callbacks.current_world
    local reconnect = callbacks.join
    local system = UEHelpers.GetKismetSystemLibrary()
    local statics = UEHelpers.GetGameplayStatics()

    local session = {
        requested = false,
        connected = false,
        last_join = 0,
        attempts = 0,
        disconnected_at = 0,
        last_world_name = "",
        last_role = "",
    }
    local max_attempts = tonumber(config.max_reconnect_attempts) or 5
    local retry_seconds = tonumber(config.reconnect_interval_seconds) or 30

    function Module.note_join()
        -- Each Steam lobby map epoch triggers a new actual Unreal login.
        -- Clear the old pawn-ready edge; otherwise a new possession on the
        -- next map never invokes on_guest_ready and the bridge stays stuck in
        -- connecting_game despite a valid pawn and PlayerState.
        session.requested = true
        session.connected = false
        session.disconnected_at = 0
        session.last_join = os.time()
    end

    local function hook_openlevel(path)
        local ok, pre_id, post_id = pcall(RegisterHook, path,
            function(context, world_arg, level_arg, absolute_arg, options_arg)
                local safe, error_message = pcall(function()
                    local world = world_arg:get()
                    if not valid(world) or not valid(system) or not system:IsServer(world) then
                        return
                    end
                    local destination = converted(level_arg:get())
                    local options = converted(options_arg:get())
                    if not destination or options == nil then
                        log("Travel hook skipped: unrecognized parameters")
                        return
                    end
                    local is_arena = destination:find("Arena", 1, true)
                        or destination:find("MageHub", 1, true)
                    if destination:find("MainMenu", 1, true) then
                        -- Returning to the menu must not advertise a live server.
                        if type(callbacks.on_host_travel) == "function" then
                            callbacks.on_host_travel(destination)
                        end
                        return
                    end
                    if not is_arena then return end
                    -- Pause the Steam session even when this OpenLevel call
                    -- already contains ?listen: clients must wait for the
                    -- next UWorld to become authoritative.
                    if type(callbacks.on_host_travel) == "function" then
                        callbacks.on_host_travel(destination)
                    end
                    local has_listen = ("?" .. options .. "?"):match("%?listen%?")
                    if has_listen then return end
                    local replacement = options == "" and "listen" or options .. "?listen"
                    options_arg:set(replacement)
                    log("Preserved listen on level transition: "
                        .. destination .. " options=" .. replacement)
                end)
                if not safe then log("Travel hook error: " .. tostring(error_message)) end
            end)
        if ok then
            log("Level transition hook ready: " .. path)
        else
            log("Level transition hook unavailable: " .. path .. ": " .. tostring(pre_id))
        end
    end

    hook_openlevel("/Script/Engine.GameplayStatics:OpenLevel")
    hook_openlevel("/Script/Engine.GameplayStatics:OpenLevelBySoftObjectPtr")

    -- The native portal button calls C++ travel directly, bypassing the
    -- Blueprint OpenLevel wrappers. Advertise loading BEFORE world teardown.
    local ok,err=pcall(RegisterHook,"/Script/RevengeOfTheMage.W_PortalTeleportingScreen:ClickContinue",function(context)
        local safe,e=pcall(function()
            local w=current_world()
            if not valid(w) or not valid(system) or not system:IsServer(w) or system:IsStandalone(w) then return end
            local widget=context:get()
            if not valid(widget) then return end
            local dest=converted(widget.LevelName)
            if dest and dest~="" and type(callbacks.on_host_travel)=="function" then
                callbacks.on_host_travel(dest)
            end
        end)
        if not safe then log("Native portal transition hook: "..tostring(e)) end
    end)
    if not ok then log("Native portal transition hook unavailable: "..tostring(err)) end

    local monitor_ticks = 0
    local function monitor()
        monitor_ticks = monitor_ticks + 1
        local ok, error_message = pcall(function()
            if not session.requested or config.auto_reconnect ~= true then return end

            local world = current_world()
            if not valid(world) or not valid(system) then return end
            local now = os.time()
            if monitor_ticks % 10 == 0 then
                log("Reconnect monitor: mode="
                    .. (system:IsStandalone(world) and "standalone" or "client")
                    .. " connected=" .. tostring(session.connected)
                    .. " attempts=" .. session.attempts
                    .. " elapsed=" .. tostring(now-session.last_join)
                    .. " world=" .. world:GetFullName())
            end
            if system:IsServer(world) and not system:IsStandalone(world) then
                return
            end
            if not system:IsStandalone(world) then
                if valid(statics) then
                    local controller = statics:GetPlayerController(world, 0)
                    local pawn = valid(controller) and controller.Pawn
                    local player_state = valid(controller) and controller.PlayerState
                    local map_name = world:GetFullName()
                    if valid(pawn) and valid(player_state)
                        and pawn:IsA("/Script/RevengeOfTheMage.RM_MageBase")
                        and map_name:find("/Game/Arenas/", 1, true)
                        and not map_name:find("/MainMenu/", 1, true) then
                        if not session.connected then
                            log("Client is connected to an arena")
                            if type(callbacks.on_guest_ready) == "function" then
                                callbacks.on_guest_ready()
                            end
                        end
                        session.connected = true
                        session.attempts = 0
                        session.disconnected_at = 0
                    end
                end
                return
            end

            -- Unreal can briefly report standalone while changing worlds.
            -- Only start retrying once the user has returned to the main menu.
            if not world:GetFullName():find("/Game/Arenas/MainMenu/", 1, true) then
                return
            end
            if session.disconnected_at == 0 then
                session.disconnected_at = now
                if session.connected and type(callbacks.on_guest_disconnected) == "function" then
                    callbacks.on_guest_disconnected()
                end
            end

            local wait = session.connected and 6 or retry_seconds
            if now - session.disconnected_at < wait then return end
            if now - session.last_join < retry_seconds then return end
            if session.attempts >= max_attempts then return end

            -- Avoid connecting while the previous server level is tearing down.
            if type(callbacks.can_reconnect) == "function"
                and not callbacks.can_reconnect() then return end

            session.attempts = session.attempts + 1
            log("Reconnecting after level transition (attempt "
                .. session.attempts .. "/" .. max_attempts .. ")")
            session.connected = false
            -- note_join is called by reconnect() once a travel command is issued.
            reconnect()
        end)
        if not ok then log("Reconnect watchdog error: " .. tostring(error_message)) end
    end
    -- Keep the watchdog outside UWorld timers so it survives a hard map travel.
    local LoopAsync=callbacks.every or LoopAsync
    local ExecuteInGameThread=callbacks.every and function(fn) fn() end or ExecuteInGameThread
    LoopAsync(2000, function()
        ExecuteInGameThread(monitor)
        return false
    end)
    return Module
end

return Module
