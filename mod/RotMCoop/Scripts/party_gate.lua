-- Gate recovery is directional and uses an observed crossing of the entrance.
-- Never infer inside from a PlayerStart (later entrances can face either way).
local H=require("UEHelpers")
local M={}
local function valid(o)return o and o:IsValid() end
local function name(o)return valid(o) and o:GetFullName() or "" end
local function same(a,b)return valid(a) and valid(b) and name(a)==name(b) end
local function xyz(p)return {X=p.X,Y=p.Y,Z=p.Z}end
function M.side(pos,origin,normal)
    return (pos.X-origin.X)*normal.X+(pos.Y-origin.Y)*normal.Y
end
function M.crossing(before,after,extent)
    if not before or math.abs(before)<extent or before*after>=0 or math.abs(after)<40 then return end
    return before>0 and -1 or 1
end
function M.plan(state,players,origin,normal,extent,now)
    if not state.active or state.done or now-state.started>12 or state.conflict then return {}end
    local direction=state.direction
    if not direction then return {}end
    local anchor,depth
    for _,p in ipairs(players)do
        local d=M.side(p.pos,origin,normal)*direction
        if state.crossed[p.id] and d>extent+100 and (not depth or d<depth) then anchor=p;depth=d end
    end
    if not anchor then return {}end
    local moves={}
    for _,p in ipairs(players)do
        -- A player who already crossed is never a teleport candidate.
        if not state.crossed[p.id] and not state.moved[p.id] and state.before[p.id]
            and state.before[p.id]*direction<0 and M.side(p.pos,origin,normal)*direction< -40 then
            moves[#moves+1]={id=p.id,target={X=anchor.pos.X+normal.X*direction*160,
                Y=anchor.pos.Y+normal.Y*direction*160,Z=anchor.pos.Z+10}}
        end
    end
    return moves
end
function M.observe(state,players,origin,normal,extent,enabled,now)
    if not state then state={before={},crossed={},moved={},recent={},seenClosed=false}end
    if not enabled then
        if state.active or not state.seenClosed then state={before={},crossed={},moved={},recent={},seenClosed=true}end
        for _,p in ipairs(players)do
            local s=M.side(p.pos,origin,normal)
            local previous=state.before[p.id]
            local direction=M.crossing(previous,s,extent)
            if direction then state.recent[p.id]={direction=direction,at=now}end
            if math.abs(s)>=extent and math.abs(s)<2500 then state.before[p.id]=s end
        end
        return state
    end
    -- Never act on a gate first discovered already enabled.
    if not state.seenClosed then return state end
    if not state.active then state.active=true;state.started=now end
    if now-state.started>12 then state.done=true;return state end
    for _,p in ipairs(players)do
        local d=M.crossing(state.before[p.id],M.side(p.pos,origin,normal),extent)
        local recent=state.recent[p.id]
        if not d and recent and now-recent.at<1.5
            and M.side(p.pos,origin,normal)*recent.direction>40 then d=recent.direction end
        if d then
            if state.direction and state.direction~=d then state.conflict=true end
            state.direction=state.direction or d
            state.crossed[p.id]=true
        end
    end
    return state
end
function M.install(config,deps)
    if config.party_gate==false then return M end
    local worldId,gates="",{}
    local errors={}
    local function tick()
        local w=deps.current_world()
        local sys=H.GetKismetSystemLibrary()
        if not valid(w) or not valid(sys) or sys:IsStandalone(w) or not sys:IsServer(w) then return end
        local id=name(w)
        if id~=worldId then gates={};worldId=id end
        if not id:find("/Game/Arenas/Arena_",1,true) then return end
        local players,actors={},{}
        for _,c in ipairs(FindAllOf("PlayerController") or {})do
            if valid(c) and same(c:GetWorld(),w) and valid(c.Pawn) and same(c.Pawn.Controller,c)
                and c.Pawn:IsA("/Script/RevengeOfTheMage.RM_MageBase") and c.Pawn.bIsDead==false then
                local k=name(c.Pawn)
                players[#players+1]={id=k,pos=xyz(c.Pawn:K2_GetActorLocation())};actors[k]=c.Pawn
            end
        end
        if #players==0 then return end
        local now=H.GetGameplayStatics():GetRealTimeSeconds(w)
        for _,g in ipairs(FindAllOf("BP_LevelEntranceTrigger_C") or {})do
            if valid(g) and same(g:GetWorld(),w) and g.BlockPlayerAfterTrigger==true
                and valid(g.Spawner) and valid(g.TriggerBox) and valid(g.Arrow) then
                local k=name(g)
                local o=xyz(g.TriggerBox:K2_GetComponentLocation())
                local n=xyz(g.Arrow:GetForwardVector())
                local magnitude=math.sqrt(n.X*n.X+n.Y*n.Y)
                if magnitude>0.8 then
                    n.X=n.X/magnitude;n.Y=n.Y/magnitude
                    local extent=g.TriggerBox:GetScaledBoxExtent()
                    local lateralLimit=math.max(extent.X,extent.Y)+160
                    local near={}
                    for _,p in ipairs(players)do
                        local lateral=math.abs((p.pos.X-o.X)*n.Y-(p.pos.Y-o.Y)*n.X)
                        if lateral<=lateralLimit and math.abs(p.pos.Z-o.Z)<extent.Z+300 then near[#near+1]=p end
                    end
                    local state=M.observe(gates[k],near,o,n,80,g.Spawner.bEnabled==true,now)
                    gates[k]=state
                    if #players>=2 then
                        for _,move in ipairs(M.plan(state,near,o,n,80,now))do
                            local p=actors[move.id]
                            if p:K2_TeleportTo(move.target,p:K2_GetActorRotation())then
                                state.moved[move.id]=true
                                p:ForceNetUpdate()
                                deps.log("Party gate: moved lagging "..move.id.." inside "..k)
                            end
                        end
                    end
                end
            end
        end
    end
    deps.every(64,function()
        local ok,e=pcall(tick)
        if not ok and not errors[tostring(e)]then errors[tostring(e)]=true;deps.log("Party gate: "..tostring(e))end
    end)
    return M
end
return M
