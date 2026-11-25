-- Host-authoritative enemy health, keyed by Unreal connection/channel lifetime.
-- Experimental until native death presentation, respawn and large waves pass QA.
local H=require("UEHelpers")
local Combat=require("party_combat")
local M={}
local function valid(o)return o and o:IsValid()end
local function name(o)return valid(o) and o:GetFullName() or "" end
local function integer(s,max)
    local n=tonumber(s)
    if n and n>=0 and n<=max and n%1==0 then return n end
end
local function key(i,f,l)return i..":"..f..":"..l end
function M.parse(line,epoch,pid)
    if #line>1000 then return end
    local e,s,p,b,body=line:match("^N|(%d+)|(%d+)|(%d+)|(%d+)|(.+)$")
    if tonumber(e)~=epoch or tonumber(p)~=pid then return end
    local seq=integer(s,4294967295)
    if not seq or seq==0 or not integer(b,255) then return end
    local rows,count={},0
    for r in body:gmatch("[^;]+")do
        local i,f,l,c,h,m,d=r:match("^(%d+):(%d+):(%d+):([%w_/%.%-]+):([%d%.]+):([%d%.]+):([01])$")
        i,f,l=integer(i,65535),integer(f,2147483647),integer(l,2147483647)
        h,m=tonumber(h),tonumber(m)
        if not i or not f or not l or l<f or not h or not m or m<0.001 or m>1000000000 or h<0 or h>m or #c>180 then return end
        local k=key(i,f,l)
        if rows[k]then return end
        count=count+1
        if count>16 then return end
        rows[k]={class=c,hp=h,max=m,dead=d=="1",seq=seq}
    end
    if count>0 then return rows end
end
local function attributes(a)
    local asc=a.AbilitySystemComponent
    if not valid(asc)then return end
    for i=1,#asc.SpawnedAttributes do
        local t=asc.SpawnedAttributes[i]
        if valid(t)and t:IsA("/Script/RevengeOfTheMage.RM_EnemyAttributeSet")and name(t:GetOuter())==name(a)then return t end
    end
end
local function enemy(a,w)
    return valid(a)and a:IsA("/Script/RevengeOfTheMage.RM_EnemyCharacterBase")and name(a:GetWorld())==name(w)
end
local function class(a)return name(a:GetClass()):match("^%S+ (.+)$")end
local function identity(ch)
    local i,f,l=ch.RotMEnemyChIndex,ch.RotMEnemyOpenFirst,ch.RotMEnemyOpenLast
    if integer(i,65535)and integer(f,2147483647)and integer(l,2147483647)and l>=f then return key(i,f,l)end
end
local function register()
    -- Verified against this game's UE 5.5 Channel layout and a native LAN trace.
    for _,p in ipairs({{"RotMEnemyChIndex",0x34},{"RotMEnemyOpenFirst",0x38},{"RotMEnemyOpenLast",0x3c}})do
        RegisterCustomProperty({Name=p[1],Type=PropertyTypes.IntProperty,BelongsToClass="/Script/Engine.Channel",OffsetInternal=p[2]})
    end
end
function M.install(config,deps)
    -- Do not enable on public builds until native presentation/reuse is verified.
    if config.experimental_enemy_sync~=true then return end
    local ok,err=pcall(register)
    if not ok then deps.log("Enemy sync registration failed: "..tostring(err));return end
    local session,seq,known,lastSent,errors=nil,0,{},-1,{}
    local function tick()
        local w,epoch,host,s=Combat.session(deps)
        if s~=session then session,seq,known,lastSent=s,0,{},-1 end
        if not w then return end
        local stat=H.GetGameplayStatics()
        local now=stat:GetRealTimeSeconds(w)
        local pc=stat:GetPlayerController(w,0)
        local pid=valid(pc)and valid(pc.PlayerState)and pc.PlayerState.PlayerId
        if not pid then return end
        -- Cache the identity while the channel exists: enemy death tears it off.
        local openPaths={}
        for _,ch in ipairs(FindAllOf("ActorChannel")or{})do
            if valid(ch)and enemy(ch.Actor,w)then
                local a,c=ch.Actor,ch.Connection
                local owner=valid(c)and c.OwningActor
                local recipient=valid(owner)and valid(owner.PlayerState)and owner.PlayerState.PlayerId
                local k=identity(ch)
                local path=name(a):match("^%S+ (.+)$")
                local cls=class(a)
                if k and path and cls and recipient and recipient>0 and (host and recipient~=pid or not host and recipient==pid) then
                    local id=recipient..":"..k
                    openPaths[recipient..":"..path]=id
                    local old=known[id]
                    if not old or old.path~=path then known[id]={path=path,class=cls,pid=recipient,key=k,last=now,received=0} else old.last=now end
                end
            end
        end
        local groups={}
        local incoming={}
        if not host then
            for line in deps.read("party-combat.txt"):gmatch("[^\r\n]+")do
                local rows=M.parse(line,epoch,pid)
                if rows then for k,r in pairs(rows)do if not incoming[k]or incoming[k].seq<r.seq then incoming[k]=r end end end
            end
        end
        local function queue(v,row)
            local rows=groups[v.pid]or{}
            groups[v.pid]=rows
            rows[#rows+1]=row
        end
        for id,v in pairs(known)do
            local a=StaticFindObject(v.path)
            local reused=openPaths[v.pid..":"..v.path] and openPaths[v.pid..":"..v.path]~=id
            -- A dormant actor may outlive its channel. Keep the mapping until the actor disappears or is reused.
            local stale=host and v.terminalAt and now-v.terminalAt>30
            if stale then
                known[id]=nil
            elseif host and v.terminal then
                -- Keep the old lifetime's terminal snapshot even if its channel
                -- number or actor has already been reused by a new enemy.
                queue(v,v.terminal)
            elseif reused or not enemy(a,w)or class(a)~=v.class then
                known[id]=nil
            else
                local t=attributes(a)
                if t and host then
                    local hp,m=t.HealthPower.CurrentValue,t.MaxHealth.CurrentValue
                    if type(hp)=="number"and type(m)=="number"and m>=0.001 and m<=1000000000 and hp==hp then
                        local dead=a.bIsDead==true
                        local row=string.format("%s:%s:%.3f:%.3f:%d",v.key,v.class,dead and 0 or math.max(0,math.min(hp,m)),m,dead and 1 or 0)
                        if dead then v.terminal=row;v.terminalAt=now end
                        queue(v,row)
                    end
                elseif t and not host then
                    local r=incoming[v.key]
                    if r and r.class==v.class and r.seq>v.received and not v.dead then
                        t.MaxHealth.CurrentValue=r.max;t.MaxHealth.BaseValue=r.max
                        t.HealthPower.CurrentValue=r.hp;t.HealthPower.BaseValue=r.hp
                        if r.dead then
                            if not a.bIsDead then
                                a.bIsDead=true
                                a:Die_BP()
                            end
                            a:SetActorEnableCollision(false)
                            v.dead=true
                            -- A local target must not keep a corpse locked after
                            -- the authoritative actor channel has torn off.
                            local detector=valid(pc.Pawn) and pc.Pawn.EnemyDetectionComponent
                            if valid(detector) and name(detector.CurrentTarget)==name(a) then
                                detector:NullifyCurrentTarget()
                            end
                        end
                        v.received=r.seq
                    end
                end
            end
        end
        if host and now-lastSent>=0.25 then
            lastSent=now
            for recipient,rows in pairs(groups)do
                table.sort(rows)
                local batch,body,count=0,"",0
                local function flush()
                    if count==0 or batch>255 then return end
                    seq=seq+1
                    deps.send(string.format("party_combat|N|%d|%d|%d|%d|%s",epoch,seq,recipient,batch,body))
                    batch,body,count=batch+1,"",0
                end
                for _,row in ipairs(rows)do
                    if count==16 or #body+#row>900 then flush()end
                    if batch>255 then break end
                    body=body..(count>0 and ";"or "")..row
                    count=count+1
                end
                flush()
            end
        end
    end
    deps.every(200,function()
        local pass,e=pcall(tick)
        if not pass and not errors[tostring(e)]then errors[tostring(e)]=true;deps.log("Enemy sync: "..tostring(e))end
    end)
end
return M
