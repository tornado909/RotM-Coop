local L=require("localization")
-- Display the game's own loading widget throughout hard travel/reconnect.
local H=require("UEHelpers")
local M={}
local function valid(o)return o and o:IsValid() end
local function name(o)return valid(o) and o:GetFullName() or "" end
function M.message(state,world,possessed,engaged)
    if state.role~="guest" or state.lobby=="0" then return nil end
    local st=state.status
    if st=="playing" and possessed and state.session_stage~="loading" then return nil end
    if state.session_stage=="loading" and engaged then return "Loading the next arena..." end
    if st=="host_offline" or st=="host_unavailable" then return nil end
    if st=="game_login_timeout" or st=="game_no_response" then return nil end
    if st=="connecting_game" or st=="patched" or st=="joined" then return "Connecting to your party..." end
    if engaged and not possessed then
        if state.remote_ready=="true" then return "Reconnecting to your party..." end
        return "Waiting for the host to load the arena..."
    end
    return nil
end
-- Local camera recovery only after a cinematic has ended. Never change
-- a remote pawn's viewport or fight a playing sequence.
function M.cameraRecovery(localOwned,dead,playing,paused,cursor,viewMatches)
    return localOwned and not dead and not playing and not paused and not cursor and not viewMatches
end
function M.install(config,deps)
    if config.party_loading==false then return M end
    local screen,text,worldId,last,engaged=nil,nil,"",nil,false
    local hiddenMenus={}
    local function restoreMenus()
        for _,item in pairs(hiddenMenus)do if valid(item.widget)then pcall(function()item.widget:SetVisibility(item.visibility)end)end end
        hiddenMenus={}
    end
    local function remove()
        if valid(screen) then screen:RemoveFromParent() end
        screen,text,last=nil,nil,nil
    end
    local function draw(message,w,c)
        if not message then remove();restoreMenus();return end
        local id=name(w)
        if worldId~=id then remove();worldId=id end
        if not valid(screen) then
            local gi=H.GetGameInstance()
            local lib=StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            if not valid(gi) or not valid(gi.LoadingScreenWidgetClass) or not valid(lib) or not valid(c) then return end
            screen=lib:Create(w,gi.LoadingScreenWidgetClass,c)
            if not valid(screen) then return end
            screen:AddToViewport(9999)
            local root=screen.WidgetTree.RootWidget
            text=StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"),screen.WidgetTree,FName("RotMCoopStatus"))
            if valid(text) and valid(root) then
                local slot=root:AddChildToOverlay(text)
                slot:SetHorizontalAlignment(2);slot:SetVerticalAlignment(3)
                slot:SetPadding({Left=0,Top=0,Right=0,Bottom=96})
                pcall(function()local font=text.Font;font.Size=24;text:SetFont(font) end)
            end
            deps.log("Native party loading screen displayed: "..message)
        elseif not screen:IsInViewport() then screen:AddToViewport(9999) end
        if valid(text) and last~=message then text:SetText(FText(L.t(message)));last=message end
    end
    local cameraState={}
    local function recoverCamera()
        local state=deps.state()
        if state.role~="host" and state.role~="guest" then cameraState={};return end
        if state.session_stage~="run" or state.status=="connecting_game" then cameraState={};return end
        local w=deps.current_world()
        if not valid(w)or not name(w):find("/Game/Arenas/Arena_",1,true)then return end
        local st=H.GetGameplayStatics()
        local sys=H.GetKismetSystemLibrary()
        if sys:IsStandalone(w)then return end
        local c=st:GetPlayerController(w,0)
        local p=valid(c)and c.Pawn
        if not valid(p)or not p:IsA("/Script/RevengeOfTheMage.RM_MageBase")
            or not p:IsLocallyControlled()or name(p.Controller)~=name(c)then return end
        local k=name(w)..":"..name(p)
        if cameraState.key~=k then cameraState={key=k}end
        local now=st:GetRealTimeSeconds(w)
        local seq=p.ActiveLevelSequencePlayer
        local playing=valid(seq)and seq:IsPlaying()
        -- A sequence can be driven by a level actor instead of the pawn.
        if not playing then
            for _,a in ipairs(FindAllOf("LevelSequenceActor")or{})do
                if valid(a)and name(a:GetWorld())==name(w)then
                    local player=a.SequencePlayer
                    if valid(player)and player:IsPlaying()then playing=true;break end
                end
            end
        end
        local view=c:GetViewTarget()
        local cam=p.CameraComponent
        if not valid(cam)then return end
        local paused=st:IsGamePaused(w)
        local eligible=not playing and not p.bIsDead and not paused and not c.bShowMouseCursor
        if not eligible then cameraState.since=nil;cameraState.control=nil;return end
        cameraState.since=cameraState.since or now
        if now-cameraState.since<1 then return end
        if M.cameraRecovery(true,p.bIsDead,playing,paused,c.bShowMouseCursor,name(view)==name(p)) then
            c:SetViewTargetWithBlend(p,0,0,0,false)
            cam:Activate(false)
            deps.log("Party camera: restored local pawn view after sequence")
            cameraState.since=now
            return
        end
        -- The game normally drives camera rotation itself. Only enable
        -- controller rotation when measured view/camera rotation is stuck
        -- while the user's control rotation actually changes.
        local r=c:GetControlRotation()
        local cr=cam:K2_GetComponentRotation()
        local function distance(a,b)return math.abs((a-b+180)%360-180)end
        if cameraState.control and cameraState.cam and not cameraState.fixed then
            local input=distance(r.Yaw,cameraState.control.Yaw)+distance(r.Pitch,cameraState.control.Pitch)
            local motion=distance(cr.Yaw,cameraState.cam.Yaw)+distance(cr.Pitch,cameraState.cam.Pitch)
            if input>12 and motion<2 and distance(r.Yaw,cr.Yaw)+distance(r.Pitch,cr.Pitch)>12 then
                cameraState.stuck=(cameraState.stuck or 0)+1
                if cameraState.stuck>=2 then
                    cam.bUsePawnControlRotation=true
                    cam:K2_SetWorldRotation(r,false,{},true)
                    cameraState.fixed=true
                    deps.log("Party camera: restored frozen local camera rotation")
                end
            else cameraState.stuck=0 end
        end
        cameraState.control={Yaw=r.Yaw,Pitch=r.Pitch}
        cameraState.cam={Yaw=cr.Yaw,Pitch=cr.Pitch}
    end
    local pending=false
    local errors={}
    local function update()
        local state=deps.state()
        if state.role~="guest" then engaged=false;remove();restoreMenus();return end
        local w=deps.current_world()
        if not valid(w) then return end
        local st=H.GetGameplayStatics()
        local sys=H.GetKismetSystemLibrary()
        if not valid(st) or not valid(sys) then return end
        local c=st:GetPlayerController(w,0)
        local p=valid(c) and c.Pawn
        local possessed=valid(p) and p:IsA("/Script/RevengeOfTheMage.RM_MageBase") and not sys:IsStandalone(w) and p:IsLocallyControlled()
        if possessed or state.status=="connecting_game" or state.status=="patched" then engaged=true end
        local message=M.message(state,name(w),possessed,engaged)
        local finishing=not message and valid(screen) and possessed
            and state.status=="playing" and state.session_stage~="loading"
        draw(message,w,c)
        if finishing then
            -- Restore viewport mouse capture after the native loading widget
            -- is removed. Do this once at the travel boundary, not per tick.
            local lib=StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            if valid(lib) and valid(c) then
                local ok,e=pcall(function()
                    c.bShowMouseCursor=false
                    lib:SetInputMode_GameOnly(c,true)
                    lib:SetFocusToGameViewport()
                end)
                deps.log(ok and "Party travel input restored" or "Party travel input restore failed: "..tostring(e))
            end
        end
        if message and valid(screen) and screen:IsInViewport() and name(w):find("/MainMenu/",1,true)then
            for _,menu in ipairs(FindAllOf("BPW_MainMenu_C")or{})do
                if valid(menu) and menu:IsInViewport()then
                    local key=name(menu)
                    if not hiddenMenus[key]then hiddenMenus[key]={widget=menu,visibility=menu:GetVisibility()};deps.log("Native main menu hidden during party travel")end
                    menu:SetVisibility(1)
                end
            end
        elseif next(hiddenMenus)then restoreMenus()end
    end
    local LoopAsync=deps.every or LoopAsync
    local ExecuteInGameThread=deps.every and function(fn) fn() end or ExecuteInGameThread
    LoopAsync(150,function()
        if not pending then pending=true;ExecuteInGameThread(function()
            local ok,e=pcall(update);pending=false
            if not ok and not errors[tostring(e)] then errors[tostring(e)]=true;deps.log("Party loading: "..tostring(e)) end
        end) end
        return false
    end)
    deps.every(250,function()
        local ok,e=pcall(recoverCamera)
        if not ok and not errors[tostring(e)]then errors[tostring(e)]=true;deps.log("Party camera: "..tostring(e))end
    end)
    return M
end
return M
