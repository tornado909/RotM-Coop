-- The vanilla entrance closes for the first player. Once its actual
-- spawner is enabled, bring lagging party members to a safe inside teammate.
local H=require("UEHelpers")
local M={}
local function valid(o)return o and o:IsValid() end
local function name(o)return valid(o) and o:GetFullName() or "" end
local function same(a,b)return valid(a) and valid(b) and name(a)==name(b) end
function M.side(pos,origin,normal)
    return (pos.X-origin.X)*normal.X+(pos.Y-origin.Y)*normal.Y
end
function M.outside(pos,origin,normal,outsideSign)
    return M.side(pos,origin,normal)*outsideSign >= -100
end
function M.install(config,deps)
    if config.party_gate==false then return M end
    local worldId, gates="",{}
    local pending=false
    local function tick()
        local w=deps.current_world()
        local sys=H.GetKismetSystemLibrary()
        if not valid(w) or not valid(sys) or sys:IsStandalone(w) or not sys:IsServer(w) then return end
        local id=name(w)
        if id~=worldId then gates={};worldId=id end
        if not id:find("/Game/Arenas/Arena_",1,true) then return end
        local players={}
        for _,c in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(c) and same(c:GetWorld(),w) and valid(c.Pawn) and c.Pawn:IsA("/Script/RevengeOfTheMage.RM_MageBase") and c.Pawn.bIsDead==false then
                players[#players+1]=c.Pawn
            end
        end
        if #players<2 then return end
        for _,g in ipairs(FindAllOf("BP_LevelEntranceTrigger_C") or {}) do
            if valid(g) and same(g:GetWorld(),w) and g.BlockPlayerAfterTrigger==true and valid(g.Spawner) and valid(g.TriggerBox) and valid(g.Arrow) then
                local k=name(g)
                local state=gates[k] or {moved={}}
                gates[k]=state
                if g.Spawner.bEnabled==true then
                    state.started=state.started or os.time()
                    -- Limit to the entrance event, not a continuous leash.
                    if os.time()-state.started<=12 then
                        local o=g.TriggerBox:K2_GetComponentLocation()
                        local n=g.Arrow:GetForwardVector()
                        local closest,dist
                        for _,s in ipairs(FindAllOf("PlayerStart") or {}) do
                            if valid(s) and same(s:GetWorld(),w) then
                                local p=s:K2_GetActorLocation()
                                local d=(p.X-o.X)^2+(p.Y-o.Y)^2+(p.Z-o.Z)^2
                                if not dist or d<dist then closest=p;dist=d end
                            end
                        end
                        if closest and dist<4000^2 then
                            local s=M.side(closest,o,n)
                            if math.abs(s)>20 then
                                local sign=s>0 and 1 or -1
                                local anchor,depth
                                for _,p in ipairs(players) do
                                    local loc=p:K2_GetActorLocation()
                                    local d=-M.side(loc,o,n)*sign
                                    if d>200 and (not depth or d<depth) then anchor=loc;depth=d end
                                end
                                if anchor then
                                    for _,p in ipairs(players) do
                                        local key=name(p)
                                        if not state.moved[key] and M.outside(p:K2_GetActorLocation(),o,n,sign) then
                                            local target={X=anchor.X-n.X*sign*180,Y=anchor.Y-n.Y*sign*180,Z=anchor.Z+10}
                                            local ok=p:K2_TeleportTo(target,p:K2_GetActorRotation())
                                            if ok then state.moved[key]=true;deps.log("Party gate: moved "..key.." inside "..k) end
                                        end
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    local errors={}
    local LoopAsync=deps.every or LoopAsync
    local ExecuteInGameThread=deps.every and function(fn) fn() end or ExecuteInGameThread
    LoopAsync(250,function()
        if not pending then pending=true;ExecuteInGameThread(function()
            local ok,e=pcall(tick);pending=false
            if not ok and not errors[tostring(e)] then errors[tostring(e)]=true;deps.log("Party gate: "..tostring(e)) end
        end)end
        return false
    end)
    return M
end
return M
