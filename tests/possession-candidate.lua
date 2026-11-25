local controller_class = "/Script/RevengeOfTheMage.RM_PlayerController"
local mage_class = "/Script/RevengeOfTheMage.RM_MageBase"
local frames = {}

local function log(message)
    print("[RotMPossessionTrial] " .. message .. "\n")
end

local function valid(object)
    return object and object:IsValid()
end

local function enter_spawn(context, controller_param)
    local mode = context:get()
    local controller = controller_param:get()
    local frame = {}
    frames[#frames + 1] = frame
    if valid(mode) and valid(controller) and controller:IsA(controller_class) then
        frame.world = mode:GetWorld()
        frame.controller = controller
        log("Spawn context for " .. controller:GetFullName())
    end
end

local function leave_spawn()
    local frame = table.remove(frames)
    if not frame or not valid(frame.pawn) then
        return
    end
    local pawn = frame.pawn
    local controller = frame.controller
    if pawn.Controller == controller and controller.Pawn ~= pawn then
        pawn.Controller = frame.previous
        log("Restored pre-possession controller")
    end
end

RegisterBeginPlayPreHook(function(actor_param)
    local frame = frames[#frames]
    if not frame or not valid(frame.controller) or frame.pawn then
        return
    end
    local actor = actor_param:get()
    if not valid(actor) or not actor:IsA(mage_class) or actor:GetWorld() ~= frame.world then
        return
    end
    local previous = actor.Controller
    if valid(previous) then
        log("Mage already has controller " .. previous:GetFullName())
        return
    end
    frame.pawn = actor
    frame.previous = CreateInvalidObject()
    actor.Controller = frame.controller
    log("Supplied spawn controller to " .. actor:GetFullName() .. " readback=" .. tostring(actor.Controller == frame.controller))
end)

for _, name in ipairs({ "HandleStartingNewPlayer", "SpawnDefaultPawnAtTransform" }) do
    local path = "/Script/Engine.GameModeBase:" .. name
    local ok, err = pcall(RegisterHook, path, enter_spawn, leave_spawn)
    log(ok and "Watching " .. path or "Hook unavailable for " .. path .. ": " .. tostring(err))
end
