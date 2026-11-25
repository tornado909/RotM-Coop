local H = require("UEHelpers")
local Loadout = require("party_loadout")
local Identity = require("party_identity")
local Montages = require("party_montage")
local M = {}
M.identity = Identity.resolve
M.roster = Identity.roster
local slots = {1, 2, 3, 4, 8}
local combatSlot = {[1]=true, [2]=true, [3]=true, [4]=true, [8]=true}

local function valid(o) return o and o:IsValid() end
local function name(o) return valid(o) and o:GetFullName() or "" end
local function same(a, b) return valid(a) and valid(b) and name(a) == name(b) end

local function bounded(value, limit)
    local n = tonumber(value)
    if n and n == n and math.abs(n) <= limit then return n end
end

local function positive(value)
    local n = value and value:match("^%d+$") and tonumber(value)
    if n and n >= 1 and n <= 4294967295 then return n end
end

local function decode(line, epoch, kind)
    local fields = {}
    for field in (line .. "|"):gmatch("([^|]*)|") do fields[#fields+1] = field end
    if fields[1] ~= kind or positive(fields[2]) ~= epoch then return end
    local seq = positive(fields[3])
    local sid = fields[#fields]
    if not seq or #sid ~= 17 or not sid:match("^%d+$") then return end
    local slot, down
    local start = 4
    if kind == "I" then
        slot = positive(fields[4])
        if not combatSlot[slot] or (fields[5] ~= "P" and fields[5] ~= "R") then return end
        down = fields[5] == "P"
        start = 6
    end
    local finish = #fields - 1
    local cameraRotation
    if fields[finish - 3] == "C" then
        local p, y, r = bounded(fields[finish - 2], 360), bounded(fields[finish - 1], 360), bounded(fields[finish], 360)
        if not p or not y or not r then return end
        cameraRotation = {Pitch = p, Yaw = y, Roll = r}
        finish = finish - 4
    end
    if finish ~= start+5 and finish ~= start+8 then return end
    local values = {}
    for i = start, finish do
        local index = i-start+1
        local v = bounded(fields[i], index >= 4 and index <= 6 and 360 or 1000000)
        if not v then return end
        values[index] = v
    end
    return {
        sid = sid, seq = seq, slot = slot, down = down,
        pos = {X = values[1], Y = values[2], Z = values[3]},
        rot = {Pitch = values[4], Yaw = values[5], Roll = values[6]},
        cameraRotation = cameraRotation,
        target = values[7] and {X = values[7], Y = values[8], Z = values[9]},
    }
end

function M.decodeAim(line, epoch) return decode(line, epoch, "M") end
function M.decodeInput(line, epoch) return decode(line, epoch, "I") end

-- Each reliable edge is scoped to a player and slot. Snapshot replay must
-- not roll a newer release back to an older press.
function M.recordInput(state, input, now)
    local previous = state[input.slot]
    if previous and input.seq <= previous.seq then return false end
    local sameEdge=previous and previous.down==input.down
    state[input.slot] = {seq=input.seq, down=input.down, at=now,
        changedAt=sameEdge and previous.changedAt or now,
        releaseApplied=sameEdge and previous.releaseApplied or nil,
        releasedAt=sameEdge and previous.releasedAt or nil}
    return true
end

function M.session(deps)
    local world = deps.current_world()
    if not valid(world) then return end
    local state = deps.state()
    local epoch = tonumber(state.game_epoch)
    if not epoch or epoch <= 0 or state.lobby == "0" or not state.lobby or state.session_stage == "loading" then return end
    if (tonumber(state.member_count) or 0) < 2 then return end
    local id = name(world)
    if not id:find("/Game/Arenas/", 1, true) or id:find("/MainMenu/", 1, true) then return end
    local system = H.GetKismetSystemLibrary()
    if not valid(system) or system:IsStandalone(world) then return end
    local host = system:IsServer(world)
    if (host and state.role ~= "host") or (not host and state.role ~= "guest") then return end
    if host and state.host_ready ~= "true" then return end
    if not host and (state.client_game_ready ~= "true" or state.remote_ready ~= "true") then return end
    return world, epoch, host, state.lobby .. ":" .. epoch .. ":" .. id
end

local function normalize(degrees)
    return (degrees + 180) % 360 - 180
end

local function localAim(world)
    local controller = H.GetGameplayStatics():GetPlayerController(world, 0)
    local actor = valid(controller) and M.identity(controller.Pawn, world)
    local camera = actor and actor.pawn.CameraComponent
    if not valid(camera) or actor.pawn.bIsDead then return end
    local pos = camera:K2_GetComponentLocation()
    local rot = controller:GetControlRotation()
    local cr = camera:K2_GetComponentRotation()
    return string.format("%.2f|%.2f|%.2f|%.3f|%.3f|%.3f|C|%.3f|%.3f|%.3f",
        pos.X, pos.Y, pos.Z, normalize(rot.Pitch), normalize(rot.Yaw), normalize(rot.Roll),
        normalize(cr.Pitch), normalize(cr.Yaw), normalize(cr.Roll)), actor
end

local function pressed(asc)
    local result = {}
    local specs = asc.ActivatableAbilities.Items
    for i = 1, #specs do
        local s = specs[i]
        if combatSlot[s.InputID] then result[s.InputID] = s.InputPressed == true end
    end
    return result
end

-- GAS InputPressed can stay true after a ServerOnly ability has consumed
-- the original mouse-up. Prefer the actual controller key state for the
-- stock primary binding; retain native input if the reflected call fails.
function M.primaryState(native, mouse, blocked)
    if blocked then return false end
    if type(mouse)=="boolean" then return mouse end
    return native==true
end

local function primaryMouse(controller)
    local ok,value=pcall(function()
        return controller:IsInputKeyDown({KeyName=FName("LeftMouseButton")})
    end)
    if ok and type(value)=="boolean" then return value end
end

-- The reflected native ReleaseInputID can leave a ServerOnly primary
-- instance active after its GAS input flag has already gone false.
-- Stop only that actor's still-running primary, after a grace period.
function M.releaseOverdue(entry,now,blocked)
    return entry and (blocked or not entry.down or now-entry.at>2)
        and entry.releasedAt and now-entry.releasedAt>=0.35
end
local function cancelReleasedPrimary(actor)
    local asc=actor.asc
    local specs=asc.ActivatableAbilities.Items
    local cancelled=0
    for i=1,#specs do
        local spec=specs[i]
        if spec.InputID==1 and spec.ActiveCount>0 and valid(spec.Ability)
            and spec.Ability.NetExecutionPolicy==3 then
            local candidates={}
            for _,list in ipairs({spec.NonReplicatedInstances,spec.ReplicatedInstances}) do
                for j=1,#list do
                    local instance=list[j]
                    if valid(instance) and same(instance:GetAvatarActorFromActorInfo(),actor.pawn) then
                        candidates[#candidates+1]=instance
                    end
                end
            end
            -- Snapshot the instance list before native cancellation mutates GAS.
            for _,instance in ipairs(candidates)do
                if valid(instance) then instance:K2_CancelAbility();cancelled=cancelled+1 end
            end
            break
        end
    end
    return cancelled
end
M.cancelReleasedPrimary=cancelReleasedPrimary

local function applyAim(actor, aim)
    local pawn, controller = actor.pawn, actor.controller
    Identity.bind(actor)
    if pawn.bIsDead or not aim then return end
    local cam = pawn.CameraComponent
    if not valid(cam) then return end
    controller:SetControlRotation(aim.rot)
    local cameraRotation = aim.cameraRotation or aim.rot
    local p = pawn:K2_GetActorLocation()
    local dx, dy, dz = aim.pos.X - p.X, aim.pos.Y - p.Y, aim.pos.Z - p.Z
    if dx*dx + dy*dy + dz*dz <= 320*320 then
        cam:K2_SetWorldLocationAndRotation(aim.pos, cameraRotation, false, {}, true)
    else
        cam:K2_SetWorldRotation(cameraRotation, false, {}, true)
    end
end

local function objectPath(o)
    return name(o):match("^%S+ (.+)$")
end

-- The game marks primary/reload LocalPredicted although the authoritative
-- remote ASC owns the real charges. Native ServerOnly eliminates execution
-- against the stale client-side magazine. Do not modify active specs.
local function isLeap(ability)
    return valid(ability) and ability:IsA("/Script/RevengeOfTheMage.RM_GA_LeapBase")
end

-- Remote leap targeting is normally updated by the locally controlled pawn.
-- On authority, run the same native targeting callback after restoring its aim.
-- The initial ascent and final descent are still original GAS tasks.
local function updateLeapTarget(actor)
    if actor.pawn.bIsDead then return end
    local specs=actor.asc.ActivatableAbilities.Items
    for i=1,#specs do
        local spec=specs[i]
        if spec.ActiveCount>0 and isLeap(spec.Ability) and spec.Ability.NetExecutionPolicy==3 then
            for _,list in ipairs({spec.NonReplicatedInstances,spec.ReplicatedInstances}) do
                for j=1,#list do
                    local instance=list[j]
                    if valid(instance) and same(instance:GetAvatarActorFromActorInfo(),actor.pawn)
                        and valid(instance.TargetsAreaNiagaraComponent) and not valid(instance.JumpForceTask) then
                        actor.pawn:CheckAim()
                        instance:OnLookedCharacter()
                    end
                end
            end
        end
    end
end

local function authorityPolicy(actor, saved, log)
    local specs = actor.asc.ActivatableAbilities.Items
    for i = 1, #specs do
        local spec = specs[i]
        if (spec.InputID == 1 or spec.InputID == 8 or isLeap(spec.Ability)) and spec.ActiveCount == 0 and valid(spec.Ability) then
            local ability = spec.Ability
            local p = objectPath(ability)
            if p and ability.NetExecutionPolicy == 0 then
                saved[p] = saved[p] or {execution=0,security=ability.NetSecurityPolicy}
                ability.NetExecutionPolicy = 3
                log("Party combat server policy " .. p)
            end
            if p and spec.InputID==8 and ability.NetExecutionPolicy==3 and ability.NetSecurityPolicy==0 then
                saved[p]=saved[p] or {execution=3,security=0}
                -- Reload must not be rejected against the client's stale magazine.
                -- Its explicit edge is consumed on the authoritative ASC only.
                ability.NetSecurityPolicy=1
            end
        end
    end
end

local function restorePolicies(saved)
    for p, policy in pairs(saved) do
        local ability = StaticFindObject(p)
        if valid(ability) then
            if ability.NetExecutionPolicy == 3 then ability.NetExecutionPolicy = policy.execution end
            if ability.NetSecurityPolicy == 1 then ability.NetSecurityPolicy = policy.security end
        end
    end
end

function M.install(config, deps)
    if config.party_identity == false then return end
    local sessionKey, sequence, lastPayload, lastSent = nil, 0, nil, -1
    local samples, aimByPlayer, inputs, sentInput = {}, {}, {}, {}
    local lastSnapshot
    local savedPolicies = {}
    local montages=Montages.new(deps.log)
    local reloadQueue, reloadEdges = {}, {}
    local function reset(key)
        sessionKey, lastPayload, lastSent = key, nil, -1
        samples, aimByPlayer, inputs, sentInput = {}, {}, {}, {}
        lastSnapshot = nil
        reloadQueue, reloadEdges = {}, {}
    end

    local mouseStateLogged=false
    local function sendInput(epoch, payload, actor, now, blocked)
        local state = pressed(actor.asc)
        local mouse
        if config.party_primary_mouse_guard~=false and not blocked then
            mouse=primaryMouse(actor.controller)
            if not mouseStateLogged then
                mouseStateLogged=true
                deps.log("Party primary mouse state: "..(type(mouse)=="boolean" and "controller" or "native fallback"))
            end
        end
        if state[1]~=nil then
            local down=M.primaryState(state[1],mouse,blocked)
            if state[1] and not down then actor.asc:ReleaseInputID(1) end
            state[1]=down
        end
        if blocked then
            for slot,down in pairs(state)do
                if down then actor.asc:ReleaseInputID(slot) end
                state[slot]=false
            end
        end
        for _, slot in ipairs(slots) do
            local down, old = state[slot], sentInput[slot]
            if down ~= nil and (not old or old.down ~= down or now-old.at >= 0.5) then
                sequence = sequence + 1
                local event = string.format("party_combat|I|%d|%d|%d|%s|%s",
                    epoch, sequence, slot, down and "P" or "R", payload)
                if deps.send(event) then sentInput[slot] = {down = down, at = now} end
            end
        end
    end

    local function ingest(epoch, now)
        local snapshot = deps.read("party-combat.txt")
        if snapshot == lastSnapshot then return end
        lastSnapshot = snapshot
        for line in snapshot:gmatch("[^\r\n]+") do
            local aim = M.decodeAim(line, epoch)
            local input = not aim and M.decodeInput(line, epoch)
            aim = aim or input
            if aim and (not samples[aim.sid] or aim.seq > samples[aim.sid].seq) then
                aim.at = now
                samples[aim.sid] = aim
            end
            if input then
                inputs[input.sid] = inputs[input.sid] or {}
                local old=inputs[input.sid][input.slot]
                local changed=not old or old.down~=input.down
                if M.recordInput(inputs[input.sid], input, now) and changed and input.slot==8 then
                    local queue=reloadEdges[input.sid] or {}
                    reloadEdges[input.sid]=queue
                    if #queue<16 then queue[#queue+1]=input.down end
                end
            end
        end
    end

    local function releaseInput(actor, sid, now, blocked)
        local state = inputs[sid]
        if not state then return end
        local native = pressed(actor.asc)
        local queue=reloadEdges[sid]
        reloadEdges[sid]=nil
        if queue then
            local specs=actor.asc.ActivatableAbilities.Items
            local ownedReload=false
            for i=1,#specs do local spec=specs[i]
                if spec.InputID==8 and valid(spec.Ability) and spec.Ability.NetExecutionPolicy==3
                    and spec.Ability.NetSecurityPolicy==1 then ownedReload=true;break end
            end
            if ownedReload and not actor.pawn.bIsDead and not blocked then
                for _,down in ipairs(queue) do
                    if down and not native[8] then actor.asc:PressInputID(8);native[8]=true
                    elseif not down and native[8] then actor.asc:ReleaseInputID(8);native[8]=false end
                end
            end
        end
        for slot, entry in pairs(state) do
            if blocked or not entry.down or now-entry.at>2 then
                -- A ServerOnly spec can report false while its native ability
                -- still waits for release. Deliver each release edge once,
                -- then reconcile any still-pressed spec on subsequent ticks.
                if not entry.releasedAt then entry.releasedAt=now end
                if native[slot] or not entry.releaseApplied then
                    actor.asc:ReleaseInputID(slot)
                    entry.releaseApplied=true
                end
                if slot==1 and M.releaseOverdue(entry,now,blocked) and not actor.pawn.bIsDead then
                    local count=cancelReleasedPrimary(actor)
                    if count>0 then
                        deps.log("Party primary release recovery player="..actor.id.." instances="..count)
                        entry.releasedAt=now
                    end
                end
            else
                entry.releasedAt=nil
            end
        end
    end

    -- The native attribute-change delegate is emitted on the authoritative
    -- pawn, including on a remote possession. Queue only a scalar identity,
    -- then invoke the original reload ability outside the GAS callback.
    local function ammoChanged(ctx, arg)
        if not ctx or not arg then return end
        local data = arg:get()
        local current, previous = tonumber(data.CurrentValue), tonumber(data.OldValue)
        if not current or not previous or not ((current == 0 and previous > 0) or (current > 0 and previous == 0)) then return end
        local world, _, host, key = M.session(deps)
        if not host or key ~= sessionKey then return end
        local player = M.identity(ctx:get(), world)
        if not player or not same(data.OwnerASC, player.asc) then return end
        local id = tostring(player.id)
        if current == 0 then
            reloadQueue[id] = {pawn=name(player.pawn), phase="empty"}
        elseif reloadQueue[id] and reloadQueue[id].pawn == name(player.pawn) then
            reloadQueue[id].phase = "refilled"
        end
    end

    local function processReload(actor, sid, now)
        local id = tostring(actor.id)
        local pending = reloadQueue[id]
        if not pending then return end
        if pending.pawn ~= name(actor.pawn) or actor.pawn.bIsDead then reloadQueue[id]=nil;return end
        local asc = actor.asc
        local primary, reload
        local specs = asc.ActivatableAbilities.Items
        for i=1,#specs do
            local spec=specs[i]
            if spec.InputID==1 then primary=spec elseif spec.InputID==8 then reload=spec end
        end
        if not primary or not reload or not valid(reload.Ability) or reload.Ability.NetExecutionPolicy~=3 then return end
        if pending.phase=="empty" then
            if primary.ActiveCount>0 or reload.ActiveCount>0 then return end
            local sets=asc.SpawnedAttributes
            local empty=false
            for i=1,#sets do
                local a=sets[i]
                if valid(a) and a:IsA("/Script/RevengeOfTheMage.RM_AttributeSetBase")
                    and same(a:GetOuter(),actor.pawn) and a.CurrentAmmo.CurrentValue==0 then empty=true;break end
            end
            if not empty then reloadQueue[id]=nil;return end
            pending.phase="requested"
            if asc:TryActivateAbilityByClass(reload.Ability:GetClass(),true) then
                deps.log("Party combat native reload " .. id)
            else
                deps.log("Party combat native reload rejected " .. id)
                reloadQueue[id]=nil
            end
        elseif pending.phase=="refilled" and reload.ActiveCount==0 then
            reloadQueue[id]=nil
            -- A held attack resumes after the original reload completes, not
            -- after a guessed timer. Never cancel a live primary ability.
            local held = primary.InputPressed==true
            if sid then
                local entry=inputs[sid] and inputs[sid][1]
                held=entry and entry.down and now-entry.at<=2
            end
            if held and primary.ActiveCount==0 and valid(primary.Ability) then
                asc:TryActivateAbilityByClass(primary.Ability:GetClass(),true)
            end
        end
    end

    local function tick()
        local world, epoch, host, key = M.session(deps)
        if key ~= sessionKey then
            restorePolicies(savedPolicies); savedPolicies = {}
            montages.clear()
            reset(key)
        end
        if not world then return end
        local stat=H.GetGameplayStatics()
        local now = stat:GetRealTimeSeconds(world)
        local paused=stat:IsGamePaused(world)
        if not host then
            local payload, actor = localAim(world)
            if actor then authorityPolicy(actor, savedPolicies, deps.log) end
            if payload and (payload ~= lastPayload or now - lastSent >= 0.25) then
                sequence = sequence + 1
                if deps.send(string.format("party_combat|M|%d|%d|%s", epoch, sequence, payload)) then
                    lastPayload, lastSent = payload, now
                end
            end
            if payload then sendInput(epoch, payload, actor, now, paused or actor.controller.bShowMouseCursor==true) end
            return
        end

        local peers = Loadout.parse(deps.profiles(), epoch)
        local counts = {}
        for _, profile in pairs(peers) do counts[profile.sid] = (counts[profile.sid] or 0) + 1 end
        local active = M.roster(world)
        montages.update(active)
        for _, actor in pairs(active) do
            authorityPolicy(actor, savedPolicies, deps.log)
            if actor.controller.bIsLocalPlayerController == false then
                local mesh = actor.pawn.Mesh
                if valid(mesh) and mesh.bOnlyAllowAutonomousTickPose then
                    mesh.bOnlyAllowAutonomousTickPose = false
                end
            end
        end
        ingest(epoch, now)
        aimByPlayer = {}
        for id in pairs(reloadQueue) do if not active[id] then reloadQueue[id]=nil end end
        for id, profile in pairs(peers) do
            local actor = active[id]
            if actor and actor.controller.bIsLocalPlayerController == false and counts[profile.sid] == 1 then
                local aim = samples[profile.sid]
                if aim and now - aim.at <= 1 then aimByPlayer[actor.id] = aim end
                local currentAim=aimByPlayer[actor.id]
                applyAim(actor, currentAim)
                if currentAim and not H.GetGameplayStatics():IsGamePaused(world) then updateLeapTarget(actor) end
                releaseInput(actor, profile.sid, now, paused)
                if not paused then processReload(actor, profile.sid, now) end
            end
        end
        for _, actor in pairs(active) do
            if not paused and actor.controller.bIsLocalPlayerController then processReload(actor,nil,now) end
        end
    end

    local function prepare(ctx)
        if not ctx then return end
        local world, _, host, key = M.session(deps)
        if not host then return end
        local asc = ctx:get()
        local pawn = valid(asc) and asc.AvatarActor
        local actor = M.identity(pawn, world)
        if actor and same(asc, actor.asc) and actor.controller.bIsLocalPlayerController == false then
            authorityPolicy(actor, savedPolicies, deps.log)
            applyAim(actor, key == sessionKey and aimByPlayer[actor.id])
        end
    end

    local logged = {}
    local function guarded(fn, ...)
        local ok, err = pcall(fn, ...)
        if not ok and not logged[tostring(err)] then
            logged[tostring(err)] = true
            deps.log("Party combat: " .. tostring(err))
        end
    end
    guarded(RegisterHook, "/Script/RevengeOfTheMage.RM_MageBase:CurrentAmmoChanged", function(ctx,arg)
        guarded(ammoChanged,ctx,arg)
    end)
    local rpc = {
        "ServerTryActivateAbility", "ServerTryActivateAbilityWithEventData", "ServerAbilityRPCBatch",
        "ServerSetInputPressed", "ServerSetInputReleased", "ServerSetReplicatedEvent", "ServerSetReplicatedTargetData",
    }
    for _, method in ipairs(rpc) do
        guarded(RegisterHook, "/Script/GameplayAbilities.AbilitySystemComponent:" .. method, function(ctx)
            guarded(prepare, ctx)
        end)
    end
    deps.every(50, function() guarded(tick) end)
end

return M
