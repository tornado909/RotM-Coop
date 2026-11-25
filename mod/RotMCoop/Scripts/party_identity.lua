-- Keep the game's cached controller and per-instance ability owner aligned
-- with actual replicated possession. Never mutate ability class defaults.
local H=require("UEHelpers")
local M={}
local function valid(o) return o and o:IsValid() end
local function name(o) return valid(o) and o:GetFullName() or "" end
local function same(a,b) return valid(a) and valid(b) and name(a)==name(b) end
local function owned(p,c) return valid(p) and valid(c) and same(c.Pawn,p) and same(p.Controller,c) end
function M.install(config,deps)
    if config.party_identity==false then return M end
    local seen={}
    local function repair(p)
        if not valid(p) or not p:IsA("/Script/RevengeOfTheMage.RM_MageBase") then return end
        local c=p.Controller
        if not owned(p,c) then return end
        local world=p:GetWorld()
        local sys=H.GetKismetSystemLibrary()
        if not valid(world) or not valid(sys) or sys:IsStandalone(world) then return end
        if not same(p.PC,c) then
            p.PC=c
            deps.log("Corrected cached mage PC: "..name(p).." -> "..name(c))
        end
        -- A remote player's camera is not the server's local view target.
        -- Use replicated controller rotation, not the listen host camera.
        if sys:IsServer(world) and c.bIsLocalPlayerController==false and valid(p.CameraComponent) then
            local rot=c:GetControlRotation()
            p.CameraComponent:K2_SetWorldRotation(rot,false,{},true)
        end
        local asc=p.AbilitySystemComponent
        if not valid(asc) then return end
        local items=asc.ActivatableAbilities.Items; for j=1,#items do local spec=items[j]
            for _,instances in ipairs({spec.NonReplicatedInstances,spec.ReplicatedInstances}) do
                for i=1,#instances do
                    local ability=instances[i]
                    if valid(ability) and ability:IsA("/Script/RevengeOfTheMage.RM_GameplayAbilityBase")
                        and same(ability:GetAvatarActorFromActorInfo(),p) and not same(ability.OwnerCharacter,p) then
                        ability.OwnerCharacter=p
                        deps.log("Corrected instance owner: "..name(ability).." -> "..name(p))
                    end
                end
            end
        end
    end
    local function guarded(p)
        local ok,e=pcall(repair,p)
        if not ok and not seen[tostring(e)] then seen[tostring(e)]=true;deps.log("Party identity: "..tostring(e)) end
    end
    for _,path in ipairs({"/Script/RevengeOfTheMage.RM_MageBase:InjectAbilityInput",
        "/Script/GameplayAbilities.AbilitySystemComponent:ServerTryActivateAbility",
        "/Script/GameplayAbilities.AbilitySystemComponent:ServerTryActivateAbilityWithEventData",
        "/Script/GameplayAbilities.AbilitySystemComponent:ServerAbilityRPCBatch"}) do
        local ok,err=pcall(RegisterHook,path,function(ctx)
            local obj=ctx:get()
            if valid(obj) then
                local p=obj
                if obj:IsA("/Script/GameplayAbilities.AbilitySystemComponent") then p=obj.AvatarActor end
                guarded(p)
            end
        end)
        if not ok then deps.log("Party input hook unavailable: "..path.." "..tostring(err)) end
    end
    local pending=false
    local LoopAsync=deps.every or LoopAsync
    local ExecuteInGameThread=deps.every and function(fn) fn() end or ExecuteInGameThread
    LoopAsync(250,function()
        if not pending then pending=true; ExecuteInGameThread(function()
            local ok,e=pcall(function()
                local w=deps.current_world()
                if not valid(w) then return end
                for _,p in ipairs(FindAllOf("RM_MageBase") or {}) do
                    if valid(p) and same(p:GetWorld(),w) then guarded(p) end
                end
            end)
            pending=false
            if not ok and not seen[tostring(e)] then seen[tostring(e)]=true;deps.log("Party identity: "..tostring(e)) end
        end) end
        return false
    end)
    return M
end
return M
