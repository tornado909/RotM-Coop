-- Bind an unpossessed RM_PlayerController before RM_MageBase::BeginPlay.
-- The shipped BeginPlay dereferences the controller before vanilla possession.
-- Only touch a mage with no controller and exactly one unpossessed
-- controller in the same world; leave ambiguous cases unchanged.
local mage_class = "/Script/RevengeOfTheMage.RM_MageBase"
local controller_class = "/Script/RevengeOfTheMage.RM_PlayerController"

local function valid(object)
    return object and object:IsValid()
end

local function full_name(object)
    return valid(object) and tostring(object:GetFullName()) or "unavailable"
end

local function log(message)
    print("[RotMCoop] " .. tostring(message) .. "\n")
end

local function assign_unpossessed_controller(actor_param)
    local actor = actor_param:get()
    if not valid(actor) or not actor:IsA(mage_class) or valid(actor.Controller) then
        return
    end
    -- A simulated replica must never claim the client's unpossessed local controller.
    if actor:GetLocalRole() ~= 3 then return end
    local world = actor:GetWorld()
    if not valid(world) then return end

    local all_controllers = FindAllOf("PlayerController") or {}
    local matching = {}
    -- UE4SS can return different Lua wrappers for the same UObject.
    -- Comparing the world wrapper with == was proven false in this game.
    local world_name = full_name(world)
    for _, controller in ipairs(all_controllers) do
        if valid(controller) and controller:IsA(controller_class) and not valid(controller.Pawn)
            and full_name(controller:GetWorld()) == world_name then
            matching[#matching + 1] = controller
        end
    end

    if #matching == 1 then
        actor.Controller = matching[1]
        log("Early mage controller assigned: " .. full_name(actor) .. " -> " .. full_name(matching[1]))
    elseif #matching > 1 then
        log("Ambiguous unpossessed controllers (" .. #matching .. "); not assigning")
    end
end

local enabled=function()return false end
local M={set_enabled=function(fn)enabled=fn end}
RegisterBeginPlayPreHook(function(actor_param)
    if not actor_param or not enabled() then return end
    local ok, err = pcall(assign_unpossessed_controller, actor_param)
    if not ok then log("Early controller hook error: " .. tostring(err)) end
end)

return M
