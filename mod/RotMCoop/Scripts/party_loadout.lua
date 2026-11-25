-- Per-player spell loadouts. The local robe UI and authoritative ASC are
-- separate in the single-player game. Exchange only validated slot names;
-- never overwrite the listen host's saved robe or use arbitrary asset paths.
local H=require("UEHelpers")
local M={}
local fields={"PrimaryAbilities","SecondaryAbilities","UltimateAbilities","UtilityAbilities"}
local function valid(o) return o and o:IsValid() end
local function name(o) return valid(o) and o:GetFullName() or "" end
local function className(o) return valid(o) and o:GetFName():ToString() or "" end
function M.validate(robe,slots,data)
    if not data or #slots~=4 then return nil end
    for ri=1,#data do local r=data[ri]
        if r.RobeType==robe then
            local result={}
            for i=1,4 do
                local list=r[fields[i]]; for ai=1,#list do local a=list[ai]
                    if a.InputID==i and className(a.AbilityClass)==slots[i] then result[i]=a;break end
                end
                if not result[i] then return nil end
            end
            return result
        end
    end
end
function M.profile(p)
    local r=p.CharacterRobeComponent
    if not valid(r) or not valid(r.RobeSelectionData) then return end
    local slots={}
    r.OwnedAbilityMap:ForEach(function(key,val)
        local i=tonumber(key:get())
        if i and i>=1 and i<=4 then slots[i]=className(val:get().AbilityClass) end
    end)
    for i=1,4 do if not slots[i] or slots[i]=="" then return end end
    local robe=r:GetCurrentRobeType()
    if M.validate(robe,slots,r.RobeSelectionData.RobeSelectionData) then return robe,slots end
    -- Resolve the actual four selected classes, rather than trusting a
    -- shared single-player save getter if it returns the listen host's robe.
    local data=r.RobeSelectionData.RobeSelectionData; for ri=1,#data do local entry=data[ri]
        if M.validate(entry.RobeType,slots,r.RobeSelectionData.RobeSelectionData) then return entry.RobeType,slots end
    end
end
function M.apply(p,robe,slots,log)
    local r,asc=p.CharacterRobeComponent,p.AbilitySystemComponent
    if not valid(r) or not valid(asc) or not valid(r.RobeSelectionData) then return false,"not ready" end
    local desired=M.validate(robe,slots,r.RobeSelectionData.RobeSelectionData)
    if not desired then return false,"invalid robe/slot combination" end
    local existing,change={},{}
    local items=asc.ActivatableAbilities.Items; for j=1,#items do local spec=items[j]
        local id=tonumber(spec.InputID)
        if id and id>=1 and id<=4 and valid(spec.Ability) then
            if spec.ActiveCount>0 then return false,"active ability" end
            existing[id]=existing[id] or {}
            existing[id][#existing[id]+1]={class=spec.Ability:GetClass(),level=spec.Level}
        end
    end
    for i=1,4 do
        local a=existing[i] or {}
        if #a~=1 or className(a[1].class)~=slots[i] then change[#change+1]=i end
    end
    local applied={}
    for _,i in ipairs(change) do
        applied[#applied+1]=i
        local ok,e=pcall(function()
            asc:ClearAllAbilitiesWithInputID(i)
            asc:K2_GiveAbility(desired[i].AbilityClass,1,i)
        end)
        if not ok then
            for _,j in ipairs(applied) do
                pcall(function()
                    asc:ClearAllAbilitiesWithInputID(j)
                    for _,old in ipairs(existing[j] or {}) do asc:K2_GiveAbility(old.class,old.level,j) end
                end)
            end
            return false,"grant failed: "..tostring(e)
        end
    end
    local actual={}
    local items=asc.ActivatableAbilities.Items; for j=1,#items do local spec=items[j]
        local i=tonumber(spec.InputID)
        if i and i>=1 and i<=4 and valid(spec.Ability) then
            if actual[i] then actual[i]="duplicate" else actual[i]=className(spec.Ability:GetClass()) end
        end
    end
    for i=1,4 do if actual[i]~=slots[i] then
        for _,j in ipairs(applied) do pcall(function()
            asc:ClearAllAbilitiesWithInputID(j)
            for _,old in ipairs(existing[j] or {}) do asc:K2_GiveAbility(old.class,old.level,j) end
        end) end
        return false,"grant verification failed"
    end end
    -- Update the per-pawn map (not the account-level save subsystem).
    r.OwnedAbilityMap:ForEach(function(key,val)
        local i=tonumber(key:get())
        if i and desired[i] then
            local d=val:get()
            for _,field in ipairs({"AbilityClass","Icon","IconBorder","Cost","bIsLocked"}) do
                pcall(function()d[field]=desired[i][field] end)
            end
        end
    end)
    if #change>0 then log("Authoritative loadout "..name(p).." robe="..robe.." slots="..table.concat(slots,",")) end
    return true
end
function M.parse(lines,epoch)
    local byId,dupe={},{}
    for _,line in ipairs(lines) do
        local sid,e,id,robe,a,b,c,d=line:match("^(%d+)\t(%d+)|(%d+)|(%d+)|([%w_]+)|([%w_]+)|([%w_]+)|([%w_]+)$")
        if sid and e==tostring(epoch) then
            if byId[id] then dupe[id]=true end
            byId[id]={sid=sid,robe=tonumber(robe),slots={a,b,c,d}}
        end
    end
    for id in pairs(dupe) do byId[id]=nil end
    return byId
end
function M.install(config,deps)
    if config.party_loadout==false then return M end
    local last,applied,worldId="",{},""
    local errors={}
    local function tick()
        local state=deps.state()
        local epoch=tonumber(state.game_epoch)
        if not epoch or epoch<=0 or state.lobby=="0" then last="";applied={};return end
        local w=deps.current_world()
        local sys=H.GetKismetSystemLibrary()
        local st=H.GetGameplayStatics()
        if not valid(w) or not valid(sys) or not valid(st) or sys:IsStandalone(w) then return end
        local id=name(w)
        if id~=worldId then applied={};last="";worldId=id end
        if state.role=="guest" and not sys:IsServer(w) then
            local c=st:GetPlayerController(w,0)
            if not valid(c) or not valid(c.Pawn) or not valid(c.PlayerState) or not c.Pawn:IsA("/Script/RevengeOfTheMage.RM_MageBase") then return end
            local robe,slots=M.profile(c.Pawn)
            local pid=tonumber(c.PlayerState.PlayerId)
            if not robe or not pid or pid<=0 then return end
            local key=table.concat({epoch,pid,robe,slots[1],slots[2],slots[3],slots[4]},"|")
            if key~=last and deps.send("profile|"..key) then last=key;deps.log("Published local spell loadout: "..key) end
        elseif state.role=="host" and sys:IsServer(w) then
            local profiles=M.parse(deps.profiles(),epoch)
            for _,c in ipairs(FindAllOf("PlayerController") or {}) do
                if valid(c) and c.bIsLocalPlayerController==false and name(c:GetWorld())==id and valid(c.PlayerState) and valid(c.Pawn) and c.Pawn:IsA("/Script/RevengeOfTheMage.RM_MageBase") then
                    local profile=profiles[tostring(c.PlayerState.PlayerId)]
                    if profile then
                        local pawn=name(c.Pawn)
                        local key=profile.sid.."|"..profile.robe.."|"..table.concat(profile.slots,"|")
                        if not applied[pawn] or (id:find("MageHub_New",1,true) and applied[pawn]~=key) then
                            local ok,why=M.apply(c.Pawn,profile.robe,profile.slots,deps.log)
                            if ok then applied[pawn]=key
                            elseif why~="not ready" and why~="active ability" and not errors[key..why] then
                                errors[key..why]=true;deps.log("Loadout rejected: "..why)
                            end
                        end
                    end
                end
            end
        end
    end
    local pending=false
    local LoopAsync=deps.every or LoopAsync
    local ExecuteInGameThread=deps.every and function(fn) fn() end or ExecuteInGameThread
    LoopAsync(500,function()
        if not pending then pending=true;ExecuteInGameThread(function()
            local ok,e=pcall(tick);pending=false
            if not ok and not errors[tostring(e)] then errors[tostring(e)]=true;deps.log("Party loadout: "..tostring(e)) end
        end) end
        return false
    end)
    return M
end
return M
