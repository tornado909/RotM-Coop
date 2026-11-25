-- Isolated level-transition and Steam readiness gating regression.
local scripts = "mod/RotMCoop/Scripts/"
package.path = scripts .. "?.lua;" .. package.path

local world = { name = "World /Game/Arenas/MageHub_New/MageHub_New.MageHub_New" }
function world:IsValid() return true end
function world:GetFullName() return self.name end
local mode = "server"
local clock = 1000
local real_time = os.time
os.time = function() return clock end
local enabled = false
local calls = {}
local joins = 0
local guest_ready_count = 0
local travel_dest
local hooks = {}
local watchdog

local system = {}
function system:IsValid() return true end
function system:IsServer() return mode == "server" end
function system:IsStandalone() return mode == "standalone" end
local controller = {}
function controller:IsValid() return true end
local statics = {}
function statics:IsValid() return true end
function statics:GetPlayerController() return controller end
local ue = {}
function ue.GetKismetSystemLibrary() return system end
function ue.GetGameplayStatics() return statics end
package.loaded.UEHelpers = ue

RegisterHook = function(path, pre)
    hooks[path] = pre
    return #calls + 1
end
LoopAsync = function(_, fn) watchdog = fn end
ExecuteInGameThread = function(fn) fn() end

local cfg = { auto_reconnect = true, max_reconnect_attempts = 5,
              reconnect_interval_seconds = 25 }
local module = dofile(scripts .. "session_travel.lua")
module.install(cfg, {
    log = function(x) calls[#calls+1] = x end,
    current_world = function() return world end,
    can_reconnect = function() return enabled end,
    on_host_travel = function(dest) travel_dest = dest end,
    join = function() joins = joins + 1; module.note_join() end,
    on_guest_ready = function() guest_ready_count = guest_ready_count + 1 end,
})
assert(watchdog and hooks["/Script/Engine.GameplayStatics:OpenLevel"])

local function arg(value)
    return {
        get = function() return value end,
        set = function(_, new) value = new end,
        result = function() return value end,
    }
end
local level = arg("/Game/Arenas/Arena_2/Arena_2")
local options = arg("")
hooks["/Script/Engine.GameplayStatics:OpenLevel"](nil, arg(world),
    level, arg(false), options)
assert(options.result() == "listen", "Server must retain listen across OpenLevel")
assert(travel_dest == "/Game/Arenas/Arena_2/Arena_2",
    "Host must announce the new map before travel")

travel_dest = nil
local menu = arg("/Game/Arenas/MainMenu/MainMenu")
local options2 = arg("")
hooks["/Script/Engine.GameplayStatics:OpenLevel"](nil, arg(world),
    menu, arg(false), options2)
assert(travel_dest == "/Game/Arenas/MainMenu/MainMenu" and options2.result() == "",
    "Main menu must pause the previous session without becoming a listen server")
travel_dest = nil
local options3 = arg("listen")
hooks["/Script/Engine.GameplayStatics:OpenLevel"](nil, arg(world),
    level, arg(false), options3)
assert(options3.result() == "listen" and travel_dest == "/Game/Arenas/Arena_2/Arena_2",
    "Existing listen option must still announce a new map")

module.note_join()
world.name = "World /Game/Arenas/MainMenu/MainMenu.MainMenu"
mode = "standalone"
clock = clock + 28
watchdog()
clock = clock + 28
watchdog()
assert(joins == 0, "Reconnect must wait while host transitions maps")
enabled = true
watchdog()
assert(joins == 1, "Reconnect must resume after host is ready")
watchdog()
assert(joins == 1, "No duplicate reconnect within cooldown")
-- A new Unreal login in the SAME Steam room has to emit an independent
-- game_ready event, even if the old PlayerState was already possessed.
mode = "client"
world.name = "World /Game/Arenas/MageHub_New/MageHub_New.MageHub_New"
controller.Pawn = {
    IsValid = function() return true end,
    IsA = function(_, path) return path == "/Script/RevengeOfTheMage.RM_MageBase" end,
}
controller.PlayerState = { IsValid = function() return true end }
module.note_join()
watchdog()
assert(guest_ready_count == 1, "First possession must report game_ready")
watchdog()
assert(guest_ready_count == 1, "Ready may not repeat on the same login")
module.note_join()
watchdog()
assert(guest_ready_count == 2,
    "Second possession after Steam epoch change must report game_ready")
-- Guest -> host -> menu must not reconnect to a previous guest endpoint.
mode="server"
watchdog()
mode="standalone"
world.name="World /Game/Arenas/MainMenu/MainMenu.MainMenu"
clock=clock+60
watchdog()
clock=clock+60
watchdog()
assert(joins==1,"Host transition must discard previous guest retry state")
module.note_join()
module.note_host()
clock=clock+60
watchdog()
assert(joins==1,"Explicit host action must cancel old guest retry state")
os.time = real_time
print("Session travel gate and role-reset tests passed")
