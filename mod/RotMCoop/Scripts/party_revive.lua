local L=require("localization")
-- Server-authoritative downed state. The verified native guard preserves GAS
-- and the pawn when its HP reaches zero; only the whole-party wipe ends a run.
local H=require("UEHelpers")
local M={}
local function valid(o)local ok,v=pcall(function()return o and o:IsValid()end);return ok and v==true end
local function name(o)return valid(o) and o:GetFullName() or "" end
local function distance(a,b)return math.sqrt((a.X-b.X)^2+(a.Y-b.Y)^2+(a.Z-b.Z)^2)end
local RADIUS=280
local SECONDS=5
function M.advance(entry,rescuer,dt,paused)
    if paused then return false end
    if not rescuer then entry.rescuer=nil;entry.progress=0;return false end
    if entry.rescuer~=rescuer then entry.rescuer=rescuer;entry.progress=0;return false end
    entry.progress=math.min(SECONDS,(entry.progress or 0)+math.max(0,math.min(dt,0.5)))
    return entry.progress>=SECONDS
end
function M.parse(raw,epoch)
    local e,body=raw:match("^(%d+)|(.*)$")
    if tonumber(e)~=epoch then return nil end
    local result={}
    if body=="-" then return result end
    if body=="wipe" then return nil,"wipe" end
    for line in body:gmatch("[^;]+") do
        local id,x,y,z,p=line:match("^(%d+):([%d%-%.]+):([%d%-%.]+):([%d%-%.]+):([%d%.]+)$")
        x,y,z,p=tonumber(x),tonumber(y),tonumber(z),tonumber(p)
        if not id or result[id] or not x or not y or not z or not p or p<0 or p>5
            or math.abs(x)>1e7 or math.abs(y)>1e7 or math.abs(z)>1e7 then return nil end
        result[id]={loc={X=x,Y=y,Z=z},progress=p}
    end
    return result
end
local function attributes(p)
    local a=p.AbilitySystemComponent
    if not valid(a) then return nil end
    local list=a.SpawnedAttributes
    for i=1,#list do
        local v=list[i]
        if valid(v) and v:IsA("/Script/RevengeOfTheMage.RM_AttributeSetBase") then return v,a end
    end
end
local function heal(p,fraction)
    local a,asc=attributes(p)
    if not a then return false end
    local max=a.MaxHealth.CurrentValue
    if type(max)~="number" or max<=0 then return false end
    p.bIsDead=false
    p:HealthChanged({OwnerASC=asc,CurrentValue=max*fraction,OldValue=-1234567.0,MaxValue=max})
    if fraction==0 then p.bIsDead=true;return a.HealthPower.CurrentValue<=0 end
    if a.HealthPower.CurrentValue<=0 then p.bIsDead=true;return false end
    return true
end
function M.new(config,deps,ui)
    local downed={}
    local visuals,visualPositions={},{}
    local localFrozen=nil
    local serverFrozen={}
    local worldId,epochId="",0
    local lastTime=nil
    local lastPayload=nil
    local guardRequested=nil
    local lastGuardRequest=0
    local wipeAt=nil
    local wiping=false
    local wipeComplete=false
    local function freeze(p,c)
        if not valid(p) then return end
        if valid(p.CharacterMovement) then p.CharacterMovement:DisableMovement() end
        if valid(p.AbilitySystemComponent) then pcall(function()p.AbilitySystemComponent:SetUserAbilityActivationInhibited(true)end)end
        if valid(c) and c.bIsLocalPlayerController==true then c:SetIgnoreMoveInput(true) end
    end
    -- Network corrections can restore Walking after the first disable.
    -- Never stack SetIgnoreMoveInput calls in a periodic tick.
    local function maintainFreeze(p)
        if not valid(p) then return end
        local movement=p.CharacterMovement
        if valid(movement) and movement.MovementMode~=0 then
            movement:StopMovementImmediately()
            movement:DisableMovement()
        end
    end
    local function thaw(p,c)
        if not valid(p) then return end
        if valid(p.CharacterMovement) then p.CharacterMovement:SetMovementMode(1,0) end
        if valid(p.AbilitySystemComponent) then pcall(function()p.AbilitySystemComponent:SetUserAbilityActivationInhibited(false)end)end
        if valid(c) and c.bIsLocalPlayerController==true then c:SetIgnoreMoveInput(false) end
    end
    local function clearEffects()
        for _,v in pairs(visuals)do if valid(v)then pcall(function()v:Deactivate();v:K2_DestroyComponent(v)end)end end
        visuals={};visualPositions={}
    end
    local function effect(w,e)
        local system=StaticFindObject("/Game/VFX/MSTF/Zone_Fx/NS_HealthZoneVer2_Small.NS_HealthZoneVer2_Small")
        local lib=StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
        if not valid(system) or not valid(lib) then return nil end
        local loc={X=e.loc.X,Y=e.loc.Y,Z=e.loc.Z-80}
        local ok,v=pcall(function()
            return lib:SpawnSystemAtLocation(w,system,loc,{Pitch=0,Yaw=0,Roll=0},
                {X=1.5,Y=1.5,Z=1},false,true,0,false)
        end)
        if ok and valid(v)then return v end
    end
    local function showEffects(w,snapshot)
        for id,v in pairs(visuals)do
            if not snapshot[id] then if valid(v)then pcall(function()v:Deactivate();v:K2_DestroyComponent(v)end)end;visuals[id]=nil;visualPositions[id]=nil end
        end
        for id,e in pairs(snapshot)do
            if valid(visuals[id]) and visualPositions[id] and distance(visualPositions[id],e.loc)>20 then
                pcall(function()visuals[id]:K2_SetWorldLocation({X=e.loc.X,Y=e.loc.Y,Z=e.loc.Z-80},false,{},true)end)
                visualPositions[id]=e.loc
            end
            if not valid(visuals[id]) then visuals[id]=effect(w,e);visualPositions[id]=e.loc end
        end
    end
    local function setGuard(w,st,state,want)
        local actual=state.party_guard=="true"
        local now=st:GetRealTimeSeconds(w)
        if actual~=want and (guardRequested~=want or now-lastGuardRequest>=1)then
            if deps.send("party_guard|"..(want and "1" or "0"))then guardRequested=want;lastGuardRequest=now end
        end
        return actual==want
    end
    local function publish(epoch)
        local lines={}
        for id,e in pairs(downed)do
            lines[#lines+1]=string.format("%s:%.1f:%.1f:%.1f:%.2f",id,e.loc.X,e.loc.Y,e.loc.Z,e.progress or 0)
        end
        table.sort(lines)
        local payload=epoch.."|"..(#lines>0 and table.concat(lines,";") or "-")
        if payload~=lastPayload and deps.send("party_downed|"..payload)then lastPayload=payload end
    end
    local function display(w,st,c,snapshot,client)
        if not valid(c) or not valid(c.PlayerState) or not valid(c.Pawn)then return end
        local p=c.Pawn
        local id=tostring(c.PlayerState.PlayerId)
        local e=snapshot[id]
        if e then
            if client and localFrozen~=name(p)then
                heal(p,0);p.bIsDead=true;freeze(p,c);localFrozen=name(p)
                deps.log("Party local downed HP synchronized")
            end
            if client then maintainFreeze(p) end
            ui.status("revive",string.format(L.t("Downed  |  Ally revive %.1f / 5 s"),e.progress or 0),w,c)
            return
        elseif client and localFrozen==name(p)then
            p.bIsDead=false
            local a=attributes(p)
            if a then heal(p,0.5) end
            deps.log("Party local revived HP synchronized")
            thaw(p,c);localFrozen=nil
        end
        local pos=p:K2_GetActorLocation()
        local closest,dist=nil,nil
        for _,entry in pairs(snapshot)do local d=distance(pos,entry.loc);if not dist or d<dist then closest=entry;dist=d end end
        if closest and dist<=RADIUS then
            ui.status("revive",string.format(L.t("Reviving ally  |  %.1f / 5 s"),closest.progress or 0),w,c)
        elseif closest then
            ui.status("revive",string.format(L.t("Ally down  |  %.0f m"),dist/100),w,c)
        else ui.clear("revive")end
    end
    local function host(w,st,state,players,epoch,dt,paused)
        if wipeComplete then return end
        local n=0;for _ in pairs(players)do n=n+1 end
        if not wiping and n>=2 then setGuard(w,st,state,true) end
        if state.party_guard~="true" and not wiping then return end
        for id,v in pairs(players)do
            if v.p.bIsDead==true and not downed[id] then
                local p=v.p:K2_GetActorLocation()
                downed[id]={loc={X=p.X,Y=p.Y,Z=p.Z},progress=0,controller=name(v.c),pawn=name(v.p)}
                freeze(v.p,v.c);serverFrozen[id]=true
                deps.log("Party downed player "..id)
            end
        end
        for id,e in pairs(downed)do
            local v=players[id]
            if not v or name(v.p)~=e.pawn then downed[id]=nil;serverFrozen[id]=nil
            else
                maintainFreeze(v.p)
                local pos=v.p:K2_GetActorLocation()
                e.loc={X=pos.X,Y=pos.Y,Z=pos.Z}
            end
        end
        local alive={}
        for id,v in pairs(players)do if not downed[id] and not v.p.bIsDead then alive[id]=v end end
        local hasAlive=next(alive)~=nil
        if not hasAlive and next(downed)~=nil then
            wipeAt=wipeAt or st:GetRealTimeSeconds(w)
            if st:GetRealTimeSeconds(w)-wipeAt>=1 then
                wiping=true
                if setGuard(w,st,state,false) then
                    local c=st:GetPlayerController(w,0)
                    local p=valid(c) and c.Pawn
                    if valid(p) and p.bIsDead==true then
                        local a,asc=attributes(p)
                        if a then
                            p.bIsDead=false
                            p:HealthChanged({OwnerASC=asc,CurrentValue=0,OldValue=1,MaxValue=a.MaxHealth.CurrentValue})
                            deps.log("Party wiped; original end-of-run invoked")
                        end
                    end
                    wipeComplete=true
                    deps.send("party_downed|"..epoch.."|wipe")
                    clearEffects();ui.clear("revive")
                end
            end
            return
        end
        wipeAt=nil
        for id,e in pairs(downed)do
            local rescuer=nil
            local v=alive[e.rescuer]
            if v and distance(v.p:K2_GetActorLocation(),e.loc)<=RADIUS then rescuer=e.rescuer end
            if not rescuer then
                for aid,a in pairs(alive)do
                    if distance(a.p:K2_GetActorLocation(),e.loc)<=RADIUS then rescuer=aid;break end
                end
            end
            if M.advance(e,rescuer,dt,paused)then
                local v=players[id]
                if v and heal(v.p,0.5)then
                    thaw(v.p,v.c);downed[id]=nil;serverFrozen[id]=nil
                    deps.log("Party revived player "..id.." after 5s; HP=50%")
                end
            end
        end
        if n<2 and next(downed)==nil then setGuard(w,st,state,false)end
        publish(epoch)
        showEffects(w,downed)
        display(w,st,st:GetPlayerController(w,0),downed,false)
    end
    local function reset()
        clearEffects();ui.clear("revive");downed={};serverFrozen={};localFrozen=nil;lastTime=nil;lastPayload=nil
        guardRequested=nil;lastGuardRequest=0;wipeAt=nil;wiping=false;wipeComplete=false
    end
    return {
        tick=function(w,st,sys,state,players,paused)
            if config.party_revive==false then return end
            local epoch=tonumber(state.game_epoch) or 0
            if name(w)~=worldId or epoch~=epochId then reset();worldId=name(w);epochId=epoch end
            if epoch==0 or state.party_supported~="true" or state.lobby=="0" or state.session_stage~="run" then
                if state.party_guard=="true" then setGuard(w,st,state,false) end
                if next(downed) or next(visuals) or localFrozen then reset()end
                return
            end
            local now=st:GetRealTimeSeconds(w)
            local dt=lastTime and now-lastTime or 0
            lastTime=now
            if state.role=="host" and sys:IsServer(w)then host(w,st,state,players,epoch,dt,paused)
            elseif state.role=="guest" and not sys:IsServer(w)then
                setGuard(w,st,state,(tonumber(state.member_count) or 0)>=2)
                local snapshot,phase=M.parse(deps.read("party-downed.txt"),epoch)
                if phase=="wipe" then
                    clearEffects()
                    ui.status("revive",L.t("Party defeated"),w,st:GetPlayerController(w,0))
                elseif snapshot and state.party_guard=="true" then
                    showEffects(w,snapshot);display(w,st,st:GetPlayerController(w,0),snapshot,true)
                end
            end
        end,
        reset=reset
    }
end
return M
