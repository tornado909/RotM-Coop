-- Local-only third-person presentation. Gameplay remains on the original mage.
local H=require("UEHelpers")
local Loadout=require("party_loadout")
local Hud=require("party_hud")
local StockHUD=require("hud_spells")
local M={parse=Hud.parseVisuals,health=Hud.health}
local function valid(o)local ok,v=pcall(function()return o and o:IsValid()end);return ok and v==true end
local function name(o)return valid(o) and o:GetFullName() or "" end
local function same(a,b)return valid(a) and valid(b) and name(a)==name(b) end
local function path(o)return name(o):match("^%S+ (.+)$")end
local function find(key)
    if key then
        local o=StaticFindObject(key)
        if valid(o)then return o end
    end
end
-- Streamed lighting levels keep their own UWorld in the shipped game.
-- Restrict presentation to the current arena directory as well as its root.
local function inArena(o,w)
    if not valid(o)or not valid(w)then return false end
    if same(o:GetWorld(),w)then return true end
    local prefix=name(w):match("World (/Game/Arenas/[^/]+/)")
    return prefix~=nil and name(o):find(prefix,1,true)~=nil
end
local GREEN={R=0.13,G=0.95,B=0.30,A=1}
local SCHOOL={"Fire","Ice","Lightning","Arcane","Blood","Umbral"}
function M.smooth(current,target,dt)
    local dx,dy,dz=target.X-current.X,target.Y-current.Y,target.Z-current.Z
    local dist=math.sqrt(dx*dx+dy*dy+dz*dz)
    local alpha=dist>1800 and 1 or 1-math.exp(-math.max(0,math.min(dt,0.1))/0.065)
    if dist<1 then alpha=1 end
    return {X=current.X+dx*alpha,Y=current.Y+dy*alpha,Z=current.Z+dz*alpha},alpha
end
function M.install(config,deps)
    if config.party_visuals==false then return M end
    local bodies={}
    local outline=nil
    local allyHud=Hud.new(config,deps)
    local lastSnapshot,lastSnapshotTime,previousSnapshot
    local nativeOutlines={}
    local localOutlineVolume=nil
    local castPawns,castActive,castRoles={}, {}, {}
    local castSeq,lastRemoteSeq,castEpoch,castLocalId=0,0,0,""
    local castHost=false
    local castReadAt=nil
    local worldId,lastPayload="",nil
    local worldReadyAt=0
    local seen={}
    local lastPublish,lastScan=0,0
    local depthConflict=false
    local errors={}
    local serial=0
    local function safe(key,fn)
        local ok,v=pcall(fn)
        if not ok and not errors[key..tostring(v)]then errors[key..tostring(v)]=true;deps.log("Party visuals "..key..": "..tostring(v))end
        return ok,v
    end
    local function asset(key)
        local existing=find(key)
        if existing then return existing end
        local ok,loaded=pcall(LoadAsset,key)
        if ok and valid(loaded)then return loaded end
    end
    local function role(p)
        local ok,r=pcall(Loadout.profile,p)
        if ok and r and r>=1 and r<=6 then return r end
    end
    local function data(p,r)
        local v=p.CharacterRobeComponent
        if not valid(v)or not valid(v.RobeSelectionData)then return end
        local a=v.RobeSelectionData.RobeSelectionData
        for i=1,#a do if a[i].RobeType==r then return a[i]end end
    end
    local function hands(p,r)
        local d=data(p,r)
        if not d then return end
        local m=p.Mesh
        if not valid(m)then return end
        local a=d.GloveMaterials
        for i=1,math.min(#a,m:GetNumMaterials())do
            local mat=a[i]
            if valid(mat) and not same(m:GetMaterial(i-1),mat)then m:SetMaterial(i-1,mat)end
        end
    end
    local modelPath="/Game/StylizedCharacter_Sentinel/Meshes/Enemy_Levels/SK_Mage_F_lvl_01.SK_Mage_F_lvl_01"
    local animBase="/Game/StylizedCharacter/Animations/Human/Hu_F_SMage/AS_Hu_F_SMage_"
    local function animation(which)
        local n=animBase..which
        return asset(n..".AS_Hu_F_SMage_"..which)
    end
    local function paint(b,c,r)
        local suffix=({ "Rd","Gn","Gn","Pe","Rd","Pe" })[r]
        -- The shipped full-body model has red, green and purple texture sets.
        -- Ice uses the native blue helmet and cyan clothing set where available.
        for i,original in pairs(b.materials)do
            if original:find("BMage_Rd",1,true)then
                local replacement=original:gsub("BMage_Rd","BMage_"..suffix)
                local mat=asset(replacement)
                if valid(mat)then c:SetMaterial(i,mat)end
            elseif original:find("SMage_Rd",1,true)then
                local key=({ "Rd","Bl","green","Cn","Rd","Bl" })[r]
                local mat=asset(original:gsub("SMage_Rd","SMage_"..key)) or asset(original)
                if valid(mat)then c:SetMaterial(i,mat)end
            end
        end
        -- Use cyan variants of the compatible set/belt/shoulders for ice.
        if r==2 then
            local base="/Game/StylizedCharacter/Materials/Instances/Item/Equipment/"
            for i,k in pairs({[5]="Belt",[6]="Shoulder",[8]="Set"})do
                local n="MI_"..k.."_SMage_Cn";local v=asset(base..k.."/"..n.."."..n)
                if valid(v)then c:SetMaterial(i,v)end
            end
        end
        b.robe=r
    end
    local function removeBody(b)
        if not b then return end
        local actor=find(b.actor)
        if actor then pcall(function()actor:K2_DestroyActor()end)end
        for _,v in ipairs(b.originals)do
            local component=find(v.path)
            if component and path(component:GetOwner())==b.pawn then
                pcall(function()component:SetVisibility(v.visible,false)end)
            end
        end
    end
    local function outlineAllowed(w)
        return config.party_ally_outline~=false
    end
    local function createBody(p,r,w)
        local sk=asset(modelPath)
        local cls=StaticFindObject("/Script/Engine.SkeletalMeshActor")
        if not valid(sk) or not valid(cls)then return end
        local originals={}
        for _,c in ipairs(FindAllOf("SkeletalMeshComponent")or{})do
            if valid(c)and same(c:GetOwner(),p)then originals[#originals+1]={path=path(c),visible=c.bVisible==true}end
        end
        local l=p:K2_GetActorLocation()
        local rot=p:K2_GetActorRotation()
        local actor=w:SpawnActor(cls,{X=l.X,Y=l.Y,Z=l.Z-90},{Pitch=0,Yaw=rot.Yaw-90,Roll=0})
        if not valid(actor)then return end
        actor:SetReplicates(false)
        actor:SetActorEnableCollision(false)
        local mesh=actor.SkeletalMeshComponent
        if not valid(mesh)then actor:K2_DestroyActor();return end
        local b={actor=path(actor),mesh=path(mesh),pawn=path(p),originals=originals,materials={},robe=0}
        local ok,e=pcall(function()
            mesh:SetIsReplicated(false);mesh:SetCollisionEnabled(0);mesh:SetGenerateOverlapEvents(false)
            mesh:SetSkeletalMeshAsset(sk)
            mesh:SetComponentTickEnabled(true)
            mesh:SetCustomDepthStencilValue(247);mesh:SetRenderCustomDepth(false)
            mesh:SetVisibility(true,false)
            for i=0,mesh:GetNumMaterials()-1 do b.materials[i]=path(mesh:GetMaterial(i))end
            local a=animation("Idle")
            if valid(a)then mesh:PlayAnimation(a,true);b.anim="Idle"end
            paint(b,mesh,r)
            -- Hide only the remote pawn's first-person arms after the body exists.
            for _,v in ipairs(originals)do
                local component=find(v.path)
                if component then component:SetVisibility(false,false)end
            end
        end)
        if not ok then removeBody(b);error(e)end
        deps.log("Ally body created "..name(p).." school="..SCHOOL[r])
        return b
    end
    local function copyColor(c)return {R=c.R,G=c.G,B=c.B,A=c.A}end
    local function restoreNative()
        for _,e in pairs(nativeOutlines)do
            local volume=find(e.volume)
            local original=volume and asset(e.original)
            if volume and original then
                pcall(function()
                    local a=volume.Settings.WeightedBlendables.Array
                    for i=1,#a do
                        if path(a[i].Object)==e.mid then a[i].Object=original;break end
                    end
                end)
            end
        end
        nativeOutlines={}
    end
    local function clearOutline()
        local volume=find(localOutlineVolume)
        if volume then pcall(function()volume:K2_DestroyActor()end)end
        localOutlineVolume=nil
        restoreNative()
        local ch=outline and find(outline.ch)
        if ch then
            local o=outline;local k="Custom Depth Highlighter"
            pcall(function()
                ch[k]=o.enabled;ch[k.." Outline Color"]=o.color;ch[k.." Highlight Color"]=o.fill
                ch[k.." Outline Opacity"]=o.opacity;ch[k.." Highlight Opacity"]=o.fillOpacity
                ch[k.." Func"](ch,o.enabled)
            end)
        end
        outline=nil
    end
    local function applyNative(w)
        -- The shipped M_Outline postprocess sees the entire CustomDepth buffer.
        -- Use a local MID, never change the shared MI or an enemy component.
        local lib=StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
        if not valid(lib)then return false end
        local found=false
        for _,v in ipairs(FindAllOf("PostProcessVolume")or{})do
            if valid(v)and inArena(v,w)then
                local a=v.Settings.WeightedBlendables.Array
                for i=1,#a do
                    local obj=a[i].Object
                    local key=name(v)..":"..i
                    local e=nativeOutlines[key]
                    if e and path(obj)==e.mid then found=true
                    elseif valid(obj) and name(obj):find("/Game/Art/Material/Overlay_Materials/MI_Outline_Red.MI_Outline_Red",1,true)then
                        serial=serial+1
                        local mid=lib:CreateDynamicMaterialInstance(w,obj,FName("RotMAllyOutline_"..serial),0)
                        if valid(mid)then
                            mid:SetVectorParameterValue(FName("Color"),GREEN)
                            a[i].Object=mid
                            nativeOutlines[key]={volume=path(v),original=path(obj),mid=path(mid)}
                            found=true
                            deps.log("Ally native postprocess outline enabled")
                        end
                    end
                end
            end
        end
        return found
    end
    local function depthEnabled(enabled)
        for _,b in pairs(bodies)do
            local mesh=find(b.mesh)
            if mesh and mesh.bRenderCustomDepth~=enabled then mesh:SetRenderCustomDepth(enabled)end
        end
    end
    local function updateOutline(w,now)
        if not outlineAllowed(w) or next(bodies)==nil then depthEnabled(false);clearOutline();return end
        if now-lastScan<0.5 and lastScan~=0 then return end
        lastScan=now;depthConflict=false
        local own={}
        for _,b in pairs(bodies)do if b.mesh then own[b.mesh]=true end end
        for _,c in ipairs(FindAllOf("PrimitiveComponent")or{})do
            if valid(c) and c.bRenderCustomDepth==true and not own[path(c)]then
                local p=c:GetOwner()
                if valid(p) and inArena(p,w)then depthConflict=true;break end
            end
        end
        if depthConflict then
            -- Preserve all stock enemy/object highlights. The ally silhouette
            -- is temporarily disabled during a shared-buffer conflict.
            depthEnabled(false);clearOutline();return
        end
        if applyNative(w)then depthEnabled(true);return end
        -- Use the arena's through-wall outline shader in the hub as well.
        -- A local unbound volume avoids mutating the map's lighting effects.
        if not find(localOutlineVolume) then
            local pp=StaticFindObject("/Script/Engine.PostProcessVolume")
            local mat=asset("/Game/Art/Material/Overlay_Materials/MI_Outline_Red.MI_Outline_Red")
            local lib=StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
            if valid(pp) and valid(mat) and valid(lib) then
                serial=serial+1
                local mid=lib:CreateDynamicMaterialInstance(w,mat,FName("RotMAllyHubOutline_"..serial),0)
                if valid(mid) then
                    mid:SetVectorParameterValue(FName("Color"),GREEN)
                    local v=w:SpawnActor(pp,{X=0,Y=0,Z=0},{Pitch=0,Yaw=0,Roll=0})
                    if valid(v) then
                        local ok,e=pcall(function()
                            v:SetReplicates(false);v:SetActorEnableCollision(false)
                            v.bUnbound=true;v.bEnabled=true;v.BlendWeight=1;v.Priority=90
                            v:AddOrUpdateBlendable(mid,1)
                        end)
                        if ok then localOutlineVolume=path(v);deps.log("Ally through-wall outline volume enabled")
                        else v:K2_DestroyActor();deps.log("Ally outline volume unavailable: "..tostring(e)) end
                    end
                end
            end
        end
        if find(localOutlineVolume)then depthEnabled(true);return end

        if outline and find(outline.ch)then depthEnabled(true);return end
        local k="Custom Depth Highlighter"
        for _,ch in ipairs(FindAllOf("Chameleon_C")or{})do
            if valid(ch)and inArena(ch,w)and ch[k]~=true then
                outline={ch=path(ch),enabled=false,color=copyColor(ch[k.." Outline Color"]),fill=copyColor(ch[k.." Highlight Color"]),
                    opacity=ch[k.." Outline Opacity"],fillOpacity=ch[k.." Highlight Opacity"]}
                ch[k.." Outline Color"]=GREEN;ch[k.." Highlight Color"]=GREEN
                ch[k.." Outline Opacity"]=1.5;ch[k.." Highlight Opacity"]=0.08
                ch[k]=true;ch[k.." Func"](ch,true)
                depthEnabled(true)
                deps.log("Ally native outline enabled")
                return
            end
        end
        depthEnabled(false)
    end
    local function clear()
        depthEnabled(false);clearOutline()
        for _,b in pairs(bodies)do removeBody(b)end
        bodies={};seen={};allyHud.clear();lastPayload=nil;lastPublish=0;lastScan=0
        lastSnapshot,lastSnapshotTime,previousSnapshot=nil,nil,nil
        castPawns={};castActive={};castRoles={};castEpoch=0;lastRemoteSeq=0;castHost=false;castReadAt=nil
    end
    local function syncVitals(pc,hud)
        local p=pc.Pawn
        if not valid(p) or not valid(p.AbilitySystemComponent)then return end
        local list=p.AbilitySystemComponent.SpawnedAttributes
        local hp,maxhp,armor,maxarmor
        for i=1,#list do local a=list[i]
            if valid(a) and a:IsA("/Script/RevengeOfTheMage.RM_AttributeSetBase") then
                hp=a.HealthPower.CurrentValue;maxhp=a.MaxHealth.CurrentValue
                armor=a.Armor.CurrentValue;maxarmor=a.MaxArmor.CurrentValue;break
            end
        end
        if not hp or not maxhp or maxhp<=0 then return end
        local function text(t,v)if valid(t)then t:SetText(FText(v))end end
        local function bar(b,v,m)
            if not valid(b)or type(v)~="number"or type(m)~="number" then return end
            local pct=m>0 and math.max(0,math.min(1,v/m))or 0
            local tree=b.WidgetTree
            if not valid(tree)then return end
            local function visit(o)
                if not valid(o)then return end
                local n=o:GetFName():ToString()
                if n=="ProgressBar" or n=="DelayedProgressBar"then o:SetPercent(pct)
                elseif n=="TextBlockPercentage"then text(o,math.floor(pct*100+0.5).."%")
                elseif n=="TextBlockValue"then text(o,string.format("%.0f / %.0f",v,m))
                elseif n=="TextBlockValueMin"then text(o,string.format("%.0f",v))
                elseif n=="TextBlockValueMax"then text(o,string.format("%.0f",m))end
                local ok,count=pcall(function()return o:GetChildrenCount()end)
                if ok then for i=0,count-1 do visit(o:GetChildAt(i))end end
            end
            visit(tree.RootWidget)
        end
        local function walk(o)
            if not valid(o)then return end
            local n=o:GetFName():ToString()
            if n=="HealthBar" then bar(o,hp,maxhp);return
            elseif n=="ArmorBar" then bar(o,armor,maxarmor);return end
            local ok,count=pcall(function()return o:GetChildrenCount()end)
            if ok then for i=0,count-1 do walk(o:GetChildAt(i))end end
        end
        if valid(hud)and valid(hud.WidgetTree)then walk(hud.WidgetTree.RootWidget)end
    end
    local function tick()
        local w=deps.current_world()
        if not valid(w)then allyHud.clear();return end
        local s=deps.state()
        local epoch=tonumber(s.game_epoch)or 0
        local st=H.GetGameplayStatics();local sys=H.GetKismetSystemLibrary()
        if not valid(st)or not valid(sys)then return end
        local key=name(w)..":"..epoch
        if key~=worldId then clear();worldId=key;worldReadyAt=0 end
        if sys:IsStandalone(w) or epoch<=0 or s.lobby=="0" or s.session_stage=="loading"
            or (s.role~="host" and s.role~="guest")then
            clear();return
        end
        local pc=st:GetPlayerController(w,0)
        if not valid(pc) or not valid(pc.Pawn)then allyHud.clear();return end
        local stockHud=StockHUD.local_hud(st,w,pc)
        safe("local HUD",function()syncVitals(pc,stockHud)end)
        local now=st:GetRealTimeSeconds(w)
        local gameTime=st:GetTimeSeconds(w)
        if worldReadyAt==0 then worldReadyAt=now end
        if now-worldReadyAt<4 then return end
        local packet=deps.read("party-visuals.txt")
        if packet~=lastSnapshot then
            local parsed=M.parse(packet,epoch)
            if parsed then lastSnapshot,lastSnapshotTime,previousSnapshot=packet,gameTime,parsed end
        end
        local snapshot=previousSnapshot or {}
        local elapsed=lastSnapshotTime and math.max(0,gameTime-lastSnapshotTime) or 0
        local others,all={},{}
        for _,p in ipairs(FindAllOf("RM_MageBase")or{})do
            if valid(p)and same(p:GetWorld(),w)and valid(p.PlayerState)then
                local id=tostring(p.PlayerState.PlayerId)
                if tonumber(id)and tonumber(id)>0 then
                    all[id]=p;if not same(p,pc.Pawn)then others[id]=p end
                end
            end
        end
        if sys:IsServer(w) and s.role=="host"then
            local list={}
            local authoritative={}
            for id,p in pairs(all)do
                local r=role(p)
                local row
                if r then
                    local ok,value=safe("HUD snapshot",function()return Hud.capture(p,r,gameTime)end)
                    if ok then row=value end
                    if not row then
                        local hp,max=Hud.health(p)
                        if hp then
                            local dead=p.bIsDead==true
                            row={robe=r,hp=dead and 0 or hp,max=max,dead=dead}
                        end
                    end
                end
                if row then
                    authoritative[id]=row
                    list[#list+1]=row.spells and Hud.encodeRow(id,row)
                        or table.concat({id,r,row.hp,row.max,row.dead and 1 or 0},":")
                end
            end
            snapshot=authoritative;elapsed=0;table.sort(list)
            local payload=epoch.."|"..(#list>0 and table.concat(list,";")or"-")
            if #payload<=2048 and payload~=lastPayload and (now-lastPublish>=0.5 or lastPublish==0)then
                if deps.send("party_visuals|"..payload)then lastPayload=payload;lastPublish=now end
            end
        end
        castPawns={}
        for id,p in pairs(all)do castPawns[id]=path(p)end
        castHost=sys:IsServer(w) and s.role=="host";castEpoch=epoch
        castLocalId=valid(pc.Pawn.PlayerState) and tostring(pc.Pawn.PlayerState.PlayerId) or ""
        castRoles=snapshot
        for id,b in pairs(bodies)do
            if not others[id]or b.pawn~=path(others[id])then removeBody(b);bodies[id]=nil end
        end
        for id,p in pairs(others)do
            local d=snapshot[id]
            if d then
                if not seen[id] then seen[id]=now end
                safe("gloves",function()hands(p,d.robe)end)
                if config.party_full_body~=false and now-seen[id]>=2 then safe("body",function()
                    local b=bodies[id]
                    local mesh=b and find(b.mesh)
                    if not mesh then
                        b=createBody(p,d.robe,w)
                        if not b then return end
                        bodies[id]=b
                    elseif b.robe~=d.robe then paint(b,mesh,d.robe)end
                    b.dead=d.dead
                end)end
            end
        end
        if next(others)then safe("outline",function()updateOutline(w,now)end)
        else clearOutline()end
        if tonumber(s.member_count or 0)>1 then
            safe("HUD",function()allyHud.update(w,pc,stockHud,snapshot,epoch,elapsed)end)
        else allyHud.clear()end
    end
    local function showCast(w,id,slot,robe,ability,yaw,pitch,now)
        if id==castLocalId then return end
        local b=bodies[id]
        local mesh=b and not b.dead and find(b.pawn) and find(b.mesh)
        if not mesh then return end
        local a=animation("Attack")
        if valid(a)then mesh:PlayAnimation(a,false);b.anim="Attack";b.attackUntil=now+0.55 end
        -- Original effects are replicated by party_fx; this path animates only.
        deps.log("Ally cast visual "..id.." "..ability)
    end
    local function updateCasts(w,now)
        if castEpoch<=0 then return end
        if castHost then
            for id,key in pairs(castPawns)do
                local p=find(key)
                if p and valid(p.AbilitySystemComponent)then
                    local active=castActive[id] or {};local nextActive={}
                    local specs=p.AbilitySystemComponent.ActivatableAbilities.Items
                    for i=1,#specs do
                        local spec=specs[i];local slot=tonumber(spec.InputID)
                        if slot and slot>=1 and slot<=4 and valid(spec.Ability) and spec.ActiveCount>0 then
                            local ability=spec.Ability:GetClass():GetFName():ToString()
                            nextActive[slot]=ability
                            local role=castRoles[id]
                            if active[slot]~=ability and role and ability:match("^GA_[%w_]+_C$") then
                                local rot=p:K2_GetActorRotation()
                                if valid(p.Controller)then rot=p.Controller:GetControlRotation()end
                                local yaw=math.floor(((rot.Yaw+180)%360)-180+0.5)
                                local pitch=math.floor(math.max(-90,math.min(90,((rot.Pitch+180)%360)-180))+0.5)
                                castSeq=castSeq+1
                                deps.send("party_cast|"..castEpoch.."|"..id.."|"..castSeq.."|"..slot.."|"..role.robe.."|"..ability.."|"..yaw.."|"..pitch)
                                safe("cast",function()showCast(w,id,slot,role.robe,ability,yaw,pitch,now)end)
                            end
                        end
                    end
                    castActive[id]=nextActive
                end
            end
        elseif not castReadAt or now-castReadAt>=0.033 then
            castReadAt=now
            for line in deps.read("party-casts.txt"):gmatch("[^\r\n]+")do
                local e,id,seq,slot,robe,ability,yaw,pitch=line:match("^(%d+)|(%d+)|(%d+)|([1-4])|([1-6])|(GA_[%w_]+_C)|([%-]?%d+)|([%-]?%d+)$")
                if tonumber(e)==castEpoch and tonumber(seq)>lastRemoteSeq then
                    lastRemoteSeq=tonumber(seq)
                    safe("cast",function()showCast(w,id,tonumber(slot),tonumber(robe),ability,tonumber(yaw),tonumber(pitch),now)end)
                end
            end
        end
    end
    local function render()
        if next(bodies)==nil then return end
        local w=deps.current_world()
        if not valid(w) or not worldId:find(name(w)..":",1,true)then return end
        local st=H.GetGameplayStatics()
        local now=st:GetRealTimeSeconds(w)
        safe("cast events",function()updateCasts(w,now)end)
        for _,b in pairs(bodies)do
            local pawn,actor,mesh=find(b.pawn),find(b.actor),find(b.mesh)
            if pawn and actor and mesh then
                local l=pawn:K2_GetActorLocation();local r=pawn:K2_GetActorRotation()
                local target={X=l.X,Y=l.Y,Z=l.Z-90}
                local current=b.pos or target
                local dt=math.max(0,math.min(now-(b.renderAt or now),0.1))
                local nextpos,alpha=M.smooth(current,target,dt)
                local yaw=b.yaw or r.Yaw
                yaw=yaw+((r.Yaw-yaw+180)%360-180)*alpha
                local speed=dt>0 and math.sqrt((nextpos.X-current.X)^2+(nextpos.Y-current.Y)^2)/dt or 0
                if speed>45 then b.movingUntil=now+0.12 end
                local anim=(b.movingUntil and now<b.movingUntil and not b.dead) and "Run" or "Idle"
                if b.attackUntil and now<b.attackUntil and not b.dead then anim="Attack" end
                if b.anim~=anim then local a=animation(anim);if valid(a)then mesh:PlayAnimation(a,true);b.anim=anim end end
                actor:K2_SetActorLocationAndRotation(nextpos,{Pitch=b.dead and 80 or 0,Yaw=yaw-90,Roll=0},false,{},true)
                b.pos=nextpos;b.yaw=yaw;b.renderAt=now
            end
        end
    end
    local LoopAsync=deps.every or LoopAsync
    local ExecuteInGameThread=deps.every and function(fn)fn()end or ExecuteInGameThread
    LoopAsync(16,function()ExecuteInGameThread(function()safe("render",render)end);return false end)
    local pending=false
    LoopAsync(250,function()
        if not pending then pending=true;ExecuteInGameThread(function()safe("tick",tick);pending=false end)end
        return false
    end)
    return {tick=tick,clear=clear,inspect=function()return bodies,allyHud.inspect(),outline end}
end
return M
