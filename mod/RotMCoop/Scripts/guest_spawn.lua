-- Recover a failed initial arena possession, never respawn an established player.
local UEHelpers = require("UEHelpers")
local M = {}
function M.decide(entry, now, good, missing, eligible)
    if entry.done then return false end
    if good or not eligible or now-entry.first > 15 then entry.done=true; return false end
    if not missing then entry.missing=nil; return false end
    entry.missing=entry.missing or now
    if now-entry.missing < 2 then return false end
    entry.done=true
    return true
end
local function valid(o) return o and o:IsValid() end
function M.install(config, deps)
    if config.guest_spawn_recovery == false then return end
    local seen, map = {}, ""
    local function tick()
        local w=deps.current_world()
        if not valid(w) then return end
        local sys=UEHelpers.GetKismetSystemLibrary()
        local gs=UEHelpers.GetGameplayStatics()
        if not valid(sys) or not valid(gs) or sys:IsStandalone(w) or not sys:IsServer(w) then return end
        local name=w:GetFullName()
        if name~=map then seen={}; map=name end
        if not name:find("/Game/Arenas/",1,true) or name:find("MageHub",1,true) or name:find("MainMenu",1,true) then return end
        local host=gs:GetPlayerController(w,0)
        local mode=gs:GetGameMode(w)
        if not valid(host) or not valid(host.Pawn) or not valid(mode) then return end
        for _,c in ipairs(FindAllOf("PlayerController") or {}) do
            if valid(c) and c:IsA("/Script/RevengeOfTheMage.RM_PlayerController") and c.bIsLocalPlayerController==false and c:GetWorld():GetFullName()==name then
                local ps=c.PlayerState
                if valid(ps) then
                    local id=c:GetFullName()
                    local now=os.time()
                    seen[id]=seen[id] or {first=now}
                    local p=c.Pawn
                    local good=false
                    if valid(p) then
                        local loc=p:K2_GetActorLocation()
                        good=math.abs(loc.X)+math.abs(loc.Y)+math.abs(loc.Z)>100
                    end
                    local eligible=ps.bOnlySpectator==false and ps.bIsSpectator==false and ps.bIsInactive==false
                    if M.decide(seen[id],now,good,not valid(p),eligible) then
                        local start=mode:FindPlayerStart(c,FString(""))
                        if valid(start) and start:GetWorld():GetFullName()==name then
                            deps.log("Recovering initial guest possession at "..start:GetFullName().." for "..id)
                            mode:RestartPlayerAtPlayerStart(c,start)
                        else
                            deps.log("Initial guest recovery skipped: no valid PlayerStart")
                        end
                    end
                end
            end
        end
    end
    local pending=false
    local LoopAsync=deps.every or LoopAsync
    local ExecuteInGameThread=deps.every and function(fn) fn() end or ExecuteInGameThread
    LoopAsync(250,function()
        if not pending then
            pending=true
            ExecuteInGameThread(function()
                local ok,err=pcall(tick)
                pending=false
                if not ok then deps.log("Guest spawn recovery error: "..tostring(err)) end
            end)
        end
        return false
    end)
end
return M
