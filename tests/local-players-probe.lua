local UEHelpers = require("UEHelpers")
local map = "/Game/Arenas/MageHub_New/MageHub_New"
local run_token = "@RUN_TOKEN@"
local launch_map = @LAUNCH_MAP@
local travelled = false
local attempted = false
local solo_samples = 0
local stable_samples = 0
local sampled_pawns
local last_wait

local function log(message)
    print("[RotMCoopLocalQA " .. run_token .. "] " .. message .. "\n")
end

local function valid(object)
    return object and object:IsValid()
end

local function name(object)
    return valid(object) and tostring(object:GetFullName()) or "unavailable"
end

local function wait_for(description)
    if description ~= last_wait then
        log("WAIT " .. description)
        last_wait = description
    end
    return false
end

local function mage_for(controller)
    local pawn = valid(controller) and controller.Pawn
    if name(pawn):match("^BP_MageBase_C ") and name(pawn.Controller) == name(controller) then
        return pawn
    end
end

local function quit(system, world, controller)
    if valid(system) and valid(world) and valid(controller) then
        -- EQuitPreference::Quit
        system:QuitGame(world, controller, 0, false)
    end
end

local function poll()
    local viewport = UEHelpers.GetGameViewportClient()
    local world = valid(viewport) and viewport:GetWorld()
    local statics = UEHelpers.GetGameplayStatics()
    local system = UEHelpers.GetKismetSystemLibrary()
    if not (valid(world) and valid(statics) and valid(system)) then
        return wait_for("world or gameplay helpers unavailable")
    end

    local first = statics:GetPlayerController(world, 0)
    if name(world) ~= "World " .. map .. ".MageHub_New" then
        if not launch_map and not travelled and valid(first) then
            travelled = true
            log("TRAVEL " .. map)
            system:ExecuteConsoleCommand(world, "open " .. map, first)
        end
        return wait_for("world=" .. name(world))
    end

    local game_mode = statics:GetGameMode(world)
    if not (system:IsStandalone(world) and name(game_mode):match("^GM_SinglePlayerMatch_C ")) then
        log("RESULT FAIL: Mage Hub is not running the shipped standalone game mode")
        quit(system, world, first)
        return true
    end

    local count = statics:GetNumLocalPlayerControllers(world)
    local first_pawn = mage_for(first)
    if not attempted then
        if count ~= 1 or not first_pawn then
            solo_samples = 0
            return wait_for("local_controllers=" .. count .. " host_controller=" .. name(first)
                .. " host_pawn=" .. name(valid(first) and first.Pawn))
        end
        solo_samples = solo_samples + 1
        if solo_samples < 3 then
            return false
        end
        log("READY local_controllers=1 host=" .. name(first_pawn))
        attempted = true
        log("CREATE controller_id=1")
        local new_controller = statics:CreatePlayer(world, 1, true)
        log("RETURN " .. name(new_controller))
        return false
    end

    local second = statics:GetPlayerController(world, 1)
    local second_pawn = mage_for(second)
    local pawns = "host=" .. name(first_pawn) .. " guest=" .. name(second_pawn)
    if count == 2 and first_pawn and second_pawn
        and name(first) ~= name(second) and name(first_pawn) ~= name(second_pawn) then
        if sampled_pawns ~= pawns then
            stable_samples = 0
            sampled_pawns = pawns
        end
        stable_samples = stable_samples + 1
        log("PLAYERS local_controllers=2 " .. pawns)
        if stable_samples == 3 then
            log("RESULT PASS")
            quit(system, world, first)
            return true
        end
    else
        stable_samples = 0
        return wait_for("local_controllers=" .. count .. " " .. pawns)
    end
    return false
end

local function step()
    local ok, finished = pcall(poll)
    if not ok then
        log("RESULT FAIL: " .. tostring(finished))
    elseif not finished then
        ExecuteInGameThreadWithDelay(1000, step)
    end
end

log("START")
ExecuteInGameThreadWithDelay(8000, step)
