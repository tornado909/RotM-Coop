local H = require("UEHelpers")
local Combat = require("party_combat")
local M = {}

local function valid(o) return o and type(o.IsValid) == "function" and o:IsValid() end
local function name(o) return valid(o) and o:GetFullName() or "" end
local function path(o) return name(o):match("^%S+ (.+)$") end
local function find(p) return p and StaticFindObject(p) end

local function number(value, limit)
    local n = tonumber(value)
    if n and n == n and math.abs(n) <= limit then return n end
end

local function positive(value)
    local n = value and value:match("^%d+$") and tonumber(value)
    if n and n >= 1 and n <= 4294967295 then return n end
end

local function assetPath(asset)
    return asset and #asset <= 220 and asset:match("^/Game/[%w_./%-]+$")
        and asset:find(".", 1, true) and not asset:find("..", 1, true)
end

local function xyz(v) return {X = v.X, Y = v.Y, Z = v.Z} end
local function degrees(n) return (n + 180) % 360 - 180 end

local function transform(fields, i)
    local x, y, z = number(fields[i], 1e6), number(fields[i+1], 1e6), number(fields[i+2], 1e6)
    local p, r, w = number(fields[i+3], 360), number(fields[i+4], 360), number(fields[i+5], 360)
    local sx, sy, sz = number(fields[i+6], 100), number(fields[i+7], 100), number(fields[i+8], 100)
    if x and y and z and p and r and w and sx and sy and sz then
        return {pos = {X = x, Y = y, Z = z}, rot = {Pitch = p, Yaw = r, Roll = w},
            scale = {X = sx, Y = sy, Z = sz}}
    end
end

function M.decode(line, epoch)
    local p = {}
    for field in (line .. "|"):gmatch("([^|]*)|") do p[#p+1] = field end
    if p[1] ~= "X" or positive(p[2]) ~= epoch then return end
    local player, cast, effect, seq = positive(p[3]), positive(p[4]), positive(p[5]), positive(p[6])
    if not player or player > 2147483647 or not cast or not effect or not seq then return end
    local state, phase = nil, p[7]
    if phase == "B" and (#p == 18 or #p == 19) and assetPath(p[8]) then
        state = transform(p, 9)
        local ms = p[18]:match("^%d+$") and tonumber(p[18])
        if not state or not ms or ms > 600000 then return end
        state.asset, state.duration, state.parameters = p[8], ms / 1000, p[19]
    elseif phase == "U" and (#p == 16 or #p == 17) then
        state = transform(p, 8)
        if state then state.parameters = p[17] end
    elseif phase == "E" and #p == 7 then
        state = {}
    end
    if not state then return end
    state.player, state.phase, state.seq = player, phase, seq
    state.key = string.format("%d:%d:%d", player, cast, effect)
    return state
end

function M.advance(old, event)
    if old and (old.ended or event.seq <= old.seq) then return old end
    if event.phase == "E" then return {seq = event.seq, ended = true} end
    if event.phase == "B" then return old or event end
    if not old then return end
    event.asset, event.duration = old.asset, old.duration
    if not event.parameters then event.parameters = old.parameters end
    return event
end

-- A world-owned landing effect has no Instigator. Match the native
-- configured explosion asset and the exact final target, only when unique.
function M.matchLanding(candidates, asset, pos, now)
    local match
    for _,v in pairs(candidates) do
        if not v.claimed and v.asset==asset and now-v.at<=1.2 then
            local dx,dy,dz=pos.X-v.pos.X,pos.Y-v.pos.Y,pos.Z-v.pos.Z
            if dx*dx+dy*dy+dz*dz<=100*100 then
                if match then return end
                match=v
            end
        end
    end
    return match
end

local function packTransform(c)
    local p, r, s = c:K2_GetComponentLocation(), c:K2_GetComponentRotation(), c:K2_GetComponentScale()
    return string.format("%.2f|%.2f|%.2f|%.2f|%.2f|%.2f|%.3f|%.3f|%.3f",
        p.X, p.Y, p.Z, degrees(r.Pitch), degrees(r.Yaw), degrees(r.Roll), s.X, s.Y, s.Z)
end

local function ownerOf(actor, world)
    local current = actor
    for _ = 1, 6 do
        local owner = Combat.identity(current, world)
        if owner then return owner end
        if not valid(current) then return end
        local instigator = Combat.identity(current.Instigator, world)
        if instigator then return instigator end
        current = current:GetOwner()
    end
end

local function spellActor(actor)
    local p = path(actor:GetClass())
    return p and (p:find("/Gameplay/Actors/AbilityActors/", 1, true)
        or p:find("/Gameplay/Actors/Explosives/", 1, true))
end

local componentFields = {
    {class = "/Script/RevengeOfTheMage.RM_GA_Base", fields = {"HeldPropComponent", "HeldPropAuraComponent"}},
    {class = "/Script/RevengeOfTheMage.RM_GA_LeapBase", fields = {"TargetsAreaNiagaraComponent"}},
    {class = "/Script/RevengeOfTheMage.RM_GameplayAbilityDash", fields = {"TrailNiagaraComponent"}},
}

local effectCallbacks = {
    "/Script/RevengeOfTheMage.RM_GameplayAbilityAnimBase:AnimNotifyReceived",
    "/Script/RevengeOfTheMage.RM_GameplayAbilityAnimBase:AbilityEventReceived",
    "/Script/RevengeOfTheMage.RM_GA_LeapBase:OnTargetLocationReached",
}

local parameterSetters = {
    SetVariableBool = "b", SetVariableInt = "i", SetVariableFloat = "f", SetVariableVec3 = "v",
}

local function setParameters(component, encoded)
    if not encoded then return end
    for parameter in encoded:gmatch("[^;]+") do
        local param, kind, val = parameter:match("^([%w_.]+):([bifv]):(.+)$")
        if param and param:match("^User%.") and #param <= 80 then
            if kind == "v" then
                local x, y, z = val:match("^([^,]+),([^,]+),([^,]+)$")
                x, y, z = number(x, 1e6), number(y, 1e6), number(z, 1e6)
                if x and y and z then component:SetVariableVec3(FName(param), {X=x, Y=y, Z=z}) end
            else
                local n = number(val, 1e6)
                if n and kind == "f" then component:SetVariableFloat(FName(param), n) end
                if n and kind == "i" and n % 1 == 0 then component:SetVariableInt(FName(param), n) end
                if n and kind == "b" and (n == 0 or n == 1) then
                    component:SetVariableBool(FName(param), n == 1)
                end
            end
        end
    end
end

function M.predict(pos,encoded,age)
    if not encoded then return pos end
    local x,y,z=encoded:match("RotMVel:v:([^,;]+),([^,;]+),([^,;]+)")
    x,y,z=number(x,30000),number(y,30000),number(z,30000)
    if not x or not y or not z then return pos end
    local t=math.max(0,math.min(age,0.10))
    return {X=pos.X+x*t,Y=pos.Y+y*t,Z=pos.Z+z*t}
end
local function lerp(a, b, t) return a + (b-a)*t end
local function vector(a, b, t)
    return {X=lerp(a.X,b.X,t), Y=lerp(a.Y,b.Y,t), Z=lerp(a.Z,b.Z,t)}
end
local function rotation(a, b, t)
    return {Pitch=a.Pitch+degrees(b.Pitch-a.Pitch)*t, Yaw=a.Yaw+degrees(b.Yaw-a.Yaw)*t,
        Roll=a.Roll+degrees(b.Roll-a.Roll)*t}
end

function M.install(config, deps)
    if config.party_visuals == false then return end
    local session, onServer, epoch, nextCast, nextEffect = nil, false, 0, 0, 0
    local actors, casts, components, scopes, authored, remote, copies, parameters = {}, {}, {}, {}, {}, {}, {}, {}
    local landings, newComponents = {}, {}
    local now, lastTick, lastRead = 0, 0, -1
    local logged = {}

    local function guarded(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok and not logged[tostring(err)] then
            logged[tostring(err)] = true
            deps.log("Party FX: " .. tostring(err))
        end
    end

    local function retire(copy)
        local c = find(copy.path)
        if valid(c) and c:IsA("/Script/Niagara.NiagaraComponent") then
            c:SetVisibility(false, true)
            c:Deactivate()
        end
    end

    local function reset(key, host, newEpoch)
        for _, copy in pairs(copies) do guarded(retire, copy) end
        session, onServer, epoch = key, host, newEpoch
        actors, casts, components, scopes, authored, remote, copies, parameters = {}, {}, {}, {}, {}, {}, {}, {}
        landings, newComponents = {}, {}
        lastTick, lastRead = 0, -1
    end

    local function newCast(owner, serverOnly)
        nextCast = nextCast + 1
        return {id = nextCast, player = owner.id, serverOnly = serverOnly == true}
    end

    -- Nonreplicated projectiles created by a server-only ability do not exist
    -- in the owning guest's simulation. Match the actual configured class,
    -- not a guessed spell name or a second local gameplay activation.
    local function serverOnlyAbility(owner, instance)
        local cls=path(instance:GetClass())
        local specs=owner.asc.ActivatableAbilities.Items
        for i=1,#specs do
            local spec=specs[i]
            if valid(spec.Ability) and path(spec.Ability:GetClass())==cls then
                return spec.Ability.NetExecutionPolicy==3
            end
        end
        return instance.NetExecutionPolicy==3
    end

    local function projectileSpec(actor, owner)
        local specs=owner.asc.ActivatableAbilities.Items
        local cls=path(actor:GetClass())
        for i=1,#specs do
            local spec=specs[i]
            if valid(spec.Ability) then
                local projectile=spec.Ability.ProjectileClass
                if valid(projectile) and path(projectile)==cls then return spec end
            end
        end
        return false
    end

    local function send(effect, phase, suffix)
        effect.seq = effect.seq + 1
        local payload = string.format("party_combat|X|%d|%d|%d|%d|%d|%s%s",
            epoch, effect.cast.player, effect.cast.id, effect.id, effect.seq, phase, suffix or "")
        return deps.send(payload)
    end

    local function packedParameters(p, cast, velocity)
        local encoded, size = {}, 0
        if cast.serverOnly then encoded[1]="RotMOwn:b:1";size=11 end
        if velocity then
            local value=string.format("RotMVel:v:%.1f,%.1f,%.1f",velocity.X,velocity.Y,velocity.Z)
            encoded[#encoded+1]=value;size=size+#value+1
        end
        for name, value in pairs(parameters[p] or {}) do
            local item = name .. ":" .. value
            size = size + #item + 1
            if size > 480 then break end
            encoded[#encoded+1] = item
        end
        table.sort(encoded)
        return #encoded > 0 and "|" .. table.concat(encoded, ";") or ""
    end

    local function component(c, cast, live, lifetime, velocity)
        if not valid(c) or not c:IsA("/Script/Niagara.NiagaraComponent") or not c:IsActive() then return end
        local asset = path(c.Asset)
        local p = path(c)
        if not p or live[p] or not assetPath(asset) then return end
        local fx = authored[p]
        if fx and (fx.cast ~= cast or fx.asset ~= asset) then
            if not send(fx, "E") then return end
            authored[p] = nil
            fx = nil
        end
        if not fx then
            nextEffect = nextEffect + 1
            fx = {id = nextEffect, cast = cast, asset = asset, seq = 0}
            authored[p] = fx
        end
        live[p] = true
        local tx = packTransform(c)
        local params = packedParameters(p, cast, velocity)
        local update = tx .. params
        if not fx.state then
            local ms = math.floor(math.min(600, math.max(0, lifetime or 0)) * 1000)
            if send(fx, "B", "|" .. asset .. "|" .. tx .. "|" .. ms .. params) then fx.state = update end
        elseif update ~= fx.state and send(fx, "U", "|" .. update) then
            fx.state = update
        end
    end

    local function observeActors(world, live)
        local niagara = StaticFindObject("/Script/Niagara.NiagaraComponent")
        if not valid(niagara) then return end
        for p, cast in pairs(actors) do
            local actor = find(p)
            if not valid(actor) or name(actor:GetWorld()) ~= name(world) then
                actors[p] = nil
            else
                local children = actor:K2_GetComponentsByClass(niagara)
                local lifetime = actor:GetLifeSpan()
                local velocity
                if cast.projectile then
                    local v=actor:GetVelocity()
                    if number(v.X,30000)and number(v.Y,30000)and number(v.Z,30000)then velocity=xyz(v)end
                end
                for _, value in ipairs(children) do
                    component(value:get(), cast, live, lifetime,velocity)
                end
            end
        end
    end

    local function observeAbility(instance, owner, all, live)
        if not valid(instance) or name(instance:GetAvatarActorFromActorInfo()) ~= name(owner.pawn) then return end
        local key = path(instance)
        if not key then return end
        local cast = casts[key] or newCast(owner, serverOnlyAbility(owner, instance))
        cast.serverOnly = serverOnlyAbility(owner, instance)
        all[key] = cast
        if instance:IsA("/Script/RevengeOfTheMage.RM_GA_LeapBase") then
            local marker=instance.TargetsAreaNiagaraComponent
            local task=instance.JumpForceTask
            local asset=path(instance.ExplosionNiagaraSystem)
            if assetPath(asset) and valid(marker) and valid(task) then
                local existing=landings[key]
                if not existing or not existing.claimed then
                    landings[key]={cast=cast,asset=asset,pos=xyz(marker:K2_GetComponentLocation()),at=now}
                end
            end
        end
        for _, item in ipairs(componentFields) do
            if instance:IsA(item.class) then
                for _, field in ipairs(item.fields) do
                    local c=instance[field]
                    local p=path(c)
                    -- The explicit ability field, not the generic creation hook,
                    -- owns this component's lifetime.
                    if p then components[p]=nil end
                    component(c, cast, live)
                end
            end
        end
    end

    local function observeAbilities(world, live)
        local all = {}
        for _, owner in pairs(Combat.roster(world)) do
            local specs = owner.asc.ActivatableAbilities.Items
            for i = 1, #specs do
                local spec = specs[i]
                if spec.ActiveCount > 0 and (spec.InputID >= 1 and spec.InputID <= 4 or spec.InputID == 7) then
                    for _, instances in ipairs({spec.NonReplicatedInstances, spec.ReplicatedInstances}) do
                        for j = 1, #instances do observeAbility(instances[j], owner, all, live) end
                    end
                end
            end
        end
        casts = all
    end

    local function observeNewComponents(world)
        for key,v in pairs(landings) do
            if now-v.at>1.2 then landings[key]=nil end
        end
        for p,at in pairs(newComponents) do
            local c=find(p)
            if now-at>0.5 or not valid(c) then newComponents[p]=nil
            elseif valid(c.Asset) and c:IsActive() then
                local owner=c:GetOwner()
                if valid(owner) and owner:IsA("/Script/Engine.WorldSettings") and name(owner:GetWorld())==name(world) then
                    local v=M.matchLanding(landings,path(c.Asset),c:K2_GetComponentLocation(),now)
                    if v then
                        components[p]=v.cast
                        v.claimed=true
                        newComponents[p]=nil
                    end
                else newComponents[p]=nil end
            end
        end
    end

    local function captureActor(param)
        local actor = param:get()
        if not valid(actor) or not spellActor(actor) or actor.bReplicates then return end
        local world, activeEpoch, host, key = Combat.session(deps)
        if not host or key ~= session or activeEpoch ~= epoch then return end
        if name(actor:GetWorld()) ~= name(world) then return end
        local owner = ownerOf(actor, world)
        local p = owner and path(actor)
        if p and not actors[p] then
            local scope = scopes[#scopes]
            local spec=projectileSpec(actor,owner)
            local cast=scope and scope.cast and scope.cast.player==owner.id and scope.cast
                or newCast(owner,spec and spec.Ability.NetExecutionPolicy==3)
            -- Actor ownership can share an ability cast, but projectile motion
            -- is an actor-specific property.
            actors[p]={id=cast.id,player=cast.player,serverOnly=cast.serverOnly,projectile=spec~=nil}
        end
    end

    local function abilityScope(ctx)
        if not onServer or not ctx then return end
        local frame = {}
        scopes[#scopes+1] = frame
        local instance = ctx:get()
        local world, _, host, key = Combat.session(deps)
        if not host or key ~= session or not valid(instance) then return end
        local owner = Combat.identity(instance:GetAvatarActorFromActorInfo(), world)
        local p = owner and path(instance)
        if p then
            casts[p] = casts[p] or newCast(owner, serverOnlyAbility(owner, instance))
            casts[p].serverOnly = serverOnlyAbility(owner, instance)
            frame.cast = casts[p]
        end
    end

    local function observeParameter(kind, ctx, nameArg, valueArg)
        if not onServer or not ctx or not nameArg or not valueArg then return end
        local c = ctx:get()
        local p = path(c)
        if not p or not authored[p] and not components[p] then return end
        local param = nameArg:get():ToString()
        if #param > 80 or not param:match("^User%.[%w_.]+$") then return end
        local value = valueArg:get()
        local encoded
        if kind == "v" and number(value.X, 1e6) and number(value.Y, 1e6) and number(value.Z, 1e6) then
            encoded = string.format("%.4f,%.4f,%.4f", value.X, value.Y, value.Z)
        elseif kind == "b" and type(value) == "boolean" then
            encoded = value and "1" or "0"
        elseif (kind == "i" or kind == "f") and number(value, 1e6) then
            encoded = kind == "i" and tostring(value) or string.format("%.4f", value)
        end
        if encoded then
            parameters[p] = parameters[p] or {}
            parameters[p][param] = kind .. ":" .. encoded
        end
    end

    local function spawn(world, effect)
        local asset = StaticFindObject(effect.asset)
        if not valid(asset) then asset = LoadAsset(effect.asset) end
        local library = StaticFindObject("/Script/Niagara.Default__NiagaraFunctionLibrary")
        if not valid(asset) or not asset:IsA("/Script/Niagara.NiagaraSystem") or not valid(library) then return end
        local c = library:SpawnSystemAtLocation(world, asset, effect.pos, effect.rot, effect.scale, true, false, 0, false)
        if not valid(c) then return end
        setParameters(c, effect.parameters)
        c:Activate(true)
        return {path = path(c), pos = xyz(effect.pos), rot = effect.rot, scale = xyz(effect.scale),
            started = now, parameters = effect.parameters}
    end

    local function render(world, localId, delta)
        if now-lastRead>=0.032 then
        lastRead=now
        for line in deps.read("party-combat.txt"):gmatch("[^\r\n]+") do
            local event = M.decode(line, epoch)
            local old=event and remote[event.key]
            if event and (event.player ~= localId or old or
                (event.phase=="B" and event.parameters and (";"..event.parameters..";"):find(";RotMOwn:b:1;",1,true))) then
                local current = M.advance(old, event)
                if current ~= old then
                    current.at = now
                    remote[event.key] = current
                    if current.ended and copies[event.key] then
                        retire(copies[event.key])
                        copies[event.key] = nil
                    end
                end
            end
        end
        end
        local blend = 1 - math.exp(-delta*28)
        for key, effect in pairs(remote) do
            if not effect.ended then
                local copy = copies[key]
                if not copy then
                    copy = spawn(world, effect) or {unavailable = true, started = now}
                    copies[key] = copy
                end
                local c = find(copy.path)
                if valid(c) and c:IsA("/Script/Niagara.NiagaraComponent") then
                    if effect.duration > 0 and now - copy.started >= effect.duration then
                        retire(copy)
                        copy.path = nil
                    else
                        copy.pos = vector(copy.pos, M.predict(effect.pos,effect.parameters,now-effect.at), blend)
                        copy.rot = rotation(copy.rot, effect.rot, blend)
                        copy.scale = vector(copy.scale, effect.scale, blend)
                        if copy.parameters ~= effect.parameters then
                            setParameters(c, effect.parameters)
                            copy.parameters = effect.parameters
                        end
                        c:K2_SetWorldLocationAndRotation(copy.pos, copy.rot, false, {}, true)
                        c:SetWorldScale3D(copy.scale)
                    end
                end
            elseif now - effect.at > 7 then
                remote[key] = nil
            end
        end
    end

    local function tick()
        local world, e, host, key = Combat.session(deps)
        if key ~= session then reset(key, host, e) end
        if not world then return end
        local stat = H.GetGameplayStatics()
        now = stat:GetRealTimeSeconds(world)
        if host and now-lastTick<0.032 then return end
        local delta = math.min(0.25, math.max(0, now - lastTick))
        lastTick = now
        if host then
            local live = {}
            observeActors(world, live)
            observeAbilities(world, live)
            observeNewComponents(world)
            for p, cast in pairs(components) do
                local c = find(p)
                if valid(c) and c:IsA("/Script/Niagara.NiagaraComponent") and c:IsActive() then
                    component(c, cast, live)
                else
                    components[p] = nil
                    if not authored[p] then parameters[p] = nil end
                end
            end
            for p, fx in pairs(authored) do
                if not live[p] and (not fx.state or send(fx, "E")) then
                    authored[p], parameters[p] = nil, nil
                end
            end
        else
            local pc = stat:GetPlayerController(world, 0)
            local ownership = valid(pc) and Combat.identity(pc.Pawn, world)
            if ownership then render(world, ownership.id, delta) end
        end
    end

    RegisterBeginPlayPostHook(function(param)
        if onServer and param then guarded(captureActor, param) end
    end)
    if type(NotifyOnNewObject) == "function" then
        NotifyOnNewObject("/Script/Niagara.NiagaraComponent", function(c)
            if not onServer then return end
            local scope = scopes[#scopes]
            if (not scope or not scope.cast) and next(landings)==nil then return end
            guarded(function()
                local p = path(c)
                if p then
                    if scope and scope.cast then components[p] = scope.cast
                    elseif next(landings) then
                        local count=0;for _ in pairs(newComponents)do count=count+1 end
                        if count<128 then newComponents[p]=now end
                    end
                end
            end)
        end)
        for _, callback in ipairs(effectCallbacks) do
            guarded(RegisterHook, callback, function(ctx)
                guarded(abilityScope, ctx)
            end, function()
                scopes[#scopes] = nil
            end)
        end
    end
    for method, kind in pairs(parameterSetters) do
        local functionPath = "/Script/Niagara.NiagaraComponent:" .. method
        if valid(StaticFindObject(functionPath)) then
            guarded(RegisterHook, functionPath, function(ctx, param, value)
                guarded(observeParameter, kind, ctx, param, value)
            end)
        end
    end
    deps.every(16, function() guarded(tick) end)
end

return M
