-- One native montage (including instanced notify objects) per authoritative pawn.
-- Never mutate the source asset, ability CDO, or another pawn's animation.
local M = {}
local function valid(o) return o and o:IsValid() end
local function path(o)
    return valid(o) and o:GetFullName():match("^%S+ (.+)$") or nil
end
function M.new(log)
    local roster, hooks, serial = {}, {}, 0
    local errors = {}
    local function safe(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok and not errors[tostring(err)] then
            errors[tostring(err)] = true
            log("Party montage: " .. tostring(err))
        end
    end
    local function copyFor(pawn, original, entry)
        local source = path(original)
        if not source then return end
        local copy = entry.copies[source] and StaticFindObject(entry.copies[source])
        if valid(copy) then return copy end
        serial = serial + 1
        copy = StaticConstructObject(original:GetClass(), pawn, FName("RotM_PartyMontage_" .. serial),
            0, 0, false, false, original)
        if not valid(copy) or copy:GetPlayLength() ~= original:GetPlayLength()
            or #copy.Notifies ~= #original.Notifies or #copy.CompositeSections ~= #original.CompositeSections
            or #copy.SlotAnimTracks ~= #original.SlotAnimTracks then return end
        -- The RM notify subobjects must be unique, not shallow references.
        for i=1,#original.Notifies do
            local a, b = original.Notifies[i].Notify, copy.Notifies[i].Notify
            if valid(a) and a:IsA("/Script/RevengeOfTheMage.RM_AnimNotifyBase")
                and (not valid(b) or path(a)==path(b)) then return end
        end
        entry.copies[source] = path(copy)
        log("Party montage isolated " .. path(pawn) .. " " .. source)
        return copy
    end
    local function onCreated(ability)
        local pawn = ability:GetOuter()
        local entry = roster[path(pawn)]
        if not entry then return end
        local cls = path(ability:GetClass())
        local source = entry.classes[cls]
        if not source or path(ability.AnimMontage)~=source then return end
        local copy = entry.copies[source] and StaticFindObject(entry.copies[source])
        if valid(copy) then ability.AnimMontage = copy end
    end
    local function prepare(actor)
        local owner = path(actor.pawn)
        if not owner then return end
        local entry = roster[owner] or {copies={},classes={}}
        roster[owner] = entry
        local specs = actor.asc.ActivatableAbilities.Items
        local classes = {}
        for i=1,#specs do
            local spec = specs[i]
            local a = spec.Ability
            if valid(a) and a:IsA("/Script/RevengeOfTheMage.RM_GameplayAbilityAnimBase") then
                local original = a.AnimMontage
                local cls = path(a:GetClass())
                if cls and valid(original) then
                    if not hooks[cls] then
                        NotifyOnNewObject(cls, function(instance) safe(onCreated, instance) end)
                        hooks[cls] = true
                    end
                    if valid(copyFor(actor.pawn, original, entry)) then classes[cls] = path(original) end
                end
            end
        end
        entry.classes = classes
    end
    return {
        clear=function() roster={} end,
        update=function(actors)
            local live={}
            for _,actor in pairs(actors) do
                local key=path(actor.pawn)
                if key then
                    live[key]=true
                    if actor.pawn.bIsDead~=true then safe(prepare, actor) end
                end
            end
            for key in pairs(roster) do if not live[key] then roster[key]=nil end end
        end,
    }
end

-- Replicate only the timing of server-only montages. Client presentation uses
-- its own selected stock ability asset, never a server object reference.
function M.capture(player)
    local mesh=player.pawn.Mesh
    local anim=valid(mesh) and mesh:GetAnimInstance()
    if not valid(anim) then return end
    local specs=player.asc.ActivatableAbilities.Items
    for i=1,#specs do
        local spec=specs[i]
        if (spec.InputID==1 or spec.InputID==8) and spec.ActiveCount>0 and valid(spec.Ability)
            and spec.Ability.NetExecutionPolicy==3 then
            for _,list in ipairs({spec.NonReplicatedInstances,spec.ReplicatedInstances}) do
                for j=1,#list do
                    local instance=list[j]
                    local montage=valid(instance) and instance:GetCurrentMontage()
                    if valid(montage) and anim:Montage_IsPlaying(montage) then
                        local pos,rate=anim:Montage_GetPosition(montage),anim:Montage_GetPlayRate(montage)
                        if pos>=0 and pos<=600 and rate>0 and rate<=10 then
                            return {path=path(instance),slot=spec.InputID,ms=math.floor(pos*1000+0.5),rate=math.floor(rate*1000+0.5)}
                        end
                    end
                end
            end
        end
    end
end

function M.presentation(log)
    local pawnPath, playing, token, copies, serial=nil,nil,nil,{},0
    local function stop()
        local pawn=pawnPath and StaticFindObject(pawnPath)
        local montage=playing and StaticFindObject(playing)
        if valid(pawn) and valid(montage) and valid(pawn.Mesh) then
            local anim=pawn.Mesh:GetAnimInstance()
            if valid(anim) then anim:Montage_Stop(0.08,montage) end
        end
        playing,token=nil,nil
    end
    local function clear()
        stop()
        pawnPath,copies=nil,{}
    end
    local function cosmetic(pawn, original)
        local source=path(original)
        local old=copies[source] and StaticFindObject(copies[source])
        if valid(old) then return old end
        serial=serial+1
        local copy=StaticConstructObject(original:GetClass(),pawn,FName("RotM_CosmeticMontage_"..serial),0,0,false,false,original)
        if not valid(copy) or copy:GetPlayLength()~=original:GetPlayLength()
            or #copy.Notifies~=#original.Notifies then return end
        for i=1,#copy.Notifies do
            local row=copy.Notifies[i]
            local notify=row.Notify
            if valid(notify) and notify:IsA("/Script/RevengeOfTheMage.RM_AnimNotifyBase") then
                row.Notify=nil
                if valid(row.Notify) then return end
            end
            -- Gameplay notify states are not needed for local cosmetic playback.
            if valid(row.NotifyStateClass) then row.NotifyStateClass=nil;if valid(row.NotifyStateClass) then return end end
        end
        copies[source]=path(copy)
        return copy
    end
    local function update(player, state)
        local owner=path(player.pawn)
        if owner~=pawnPath then clear();pawnPath=owner end
        if not state or state.slot==0 or player.pawn.bIsDead then stop();return end
        local source
        local specs=player.asc.ActivatableAbilities.Items
        for i=1,#specs do
            local spec=specs[i]
            if spec.InputID==state.slot and valid(spec.Ability) and spec.Ability.NetExecutionPolicy==3 then source=spec.Ability.AnimMontage;break end
        end
        local mesh=player.pawn.Mesh
        local anim=valid(mesh) and mesh:GetAnimInstance()
        if not valid(source) or not valid(anim) then stop();return end
        local montage=cosmetic(player.pawn,source)
        if not valid(montage) then stop();return end
        local pos=math.min(state.ms/1000,math.max(0,montage:GetPlayLength()-0.001))
        local rate=state.rate/1000
        if playing~=path(montage) or token~=state.token or not anim:Montage_IsPlaying(montage) then
            stop()
            if anim:Montage_Play(montage,rate,0,pos,false)>0 then
                playing,token=path(montage),state.token
                log("Party native cosmetic montage slot="..state.slot.." token="..token)
            end
        else
            if math.abs(anim:Montage_GetPosition(montage)-pos)>0.25 then anim:Montage_SetPosition(montage,pos) end
            if math.abs(anim:Montage_GetPlayRate(montage)-rate)>0.01 then anim:Montage_SetPlayRate(montage,rate) end
        end
    end
    return {clear=clear,update=update}
end
return M
