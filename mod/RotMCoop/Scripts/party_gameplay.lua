-- Shared gameplay-thread coordinator for the party rules and native status UI.
local H=require("UEHelpers")
local Cards=require("party_cards")
local Revive=require("party_revive")
local M={}
local function valid(o)local ok,v=pcall(function()return o and o:IsValid()end);return ok and v==true end
local function name(o)return valid(o) and o:GetFullName() or "" end
function M.install(config,deps)
    local screens={}
    local nativeCards={}
    local ui={}
    function ui.clear(key)
        if key=="cards" then
            for _,v in pairs(nativeCards)do
                if valid(v.text)then pcall(function()v.text:SetText(FText(v.original))end)end
                if valid(v.popup)then pcall(function()v.popup:SetVisibility(v.visibility)end)end
            end
            nativeCards={}
        end
        local item=screens[key]
        if item and valid(item.widget)then pcall(function()item.widget:RemoveFromParent()end)end
        screens[key]=nil
    end
    function ui.status(key,message,w,c)
        if not valid(w) or not valid(c) or c.bIsLocalPlayerController~=true then return end
        if key=="cards" and not message:find("\n",1,true) then
            local found=false
            for _,o in ipairs(FindAllOf("BPW_GameHUD_C")or{})do
                if valid(o) and o:IsInViewport() and name(o:GetOwningPlayer())==name(c) then
                    local prefix=name(o):match("^%S+ (.+)$")
                    for _,popup in ipairs(FindAllOf("WBP_AttentionPopup_C")or{})do
                        if valid(popup) and prefix and name(popup):find(prefix..".",1,true)then
                            local pp=name(popup):match("^%S+ (.+)$")
                            for _,t in ipairs(FindAllOf("TextBlock")or{})do
                                if valid(t) and pp and name(t):find(pp..".",1,true) and t:GetFName():ToString()=="PowerUpEarned" then
                                    local id=name(t)
                                    if not nativeCards[id]then nativeCards[id]={text=t,original=t:GetText():ToString(),popup=popup,visibility=popup:GetVisibility()}end
                                    t:SetText(FText(message));popup:SetVisibility(4);found=true
                                end
                            end
                        end
                    end
                end
            end
            if found then
                local item=screens[key];if item and valid(item.widget)then item.widget:RemoveFromParent()end
                screens[key]=nil;return
            end
        end
        local item=screens[key]
        if item and (item.world~=name(w) or not valid(item.widget) or not valid(item.text))then
            ui.clear(key);item=nil
        end
        if not item then
            local gi=H.GetGameInstance()
            local lib=StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            if not valid(gi) or not valid(lib) or not valid(gi.LoadingScreenWidgetClass)then return end
            local widget=lib:Create(w,gi.LoadingScreenWidgetClass,c)
            if not valid(widget)then return end
            local tree=widget.WidgetTree
            local root=valid(tree) and tree.RootWidget
            if not valid(root)then return end
            -- Reuse the native UMG shell, not its loading artwork or spinner.
            for i=0,root:GetChildrenCount()-1 do
                local child=root:GetChildAt(i);if valid(child)then child:SetVisibility(1)end
            end
            local text=StaticConstructObject(StaticFindObject("/Script/UMG.TextBlock"),tree,FName("RotMPartyStatus_"..key))
            if not valid(text)then return end
            local slot=root:AddChildToOverlay(text)
            slot:SetHorizontalAlignment(2)
            slot:SetVerticalAlignment(key=="revive" and 1 or 2)
            slot:SetPadding({Left=20,Top=key=="revive" and 90 or 0,Right=20,Bottom=0})
            pcall(function()
                local font=text.Font;font.Size=26;text:SetFont(font)
                text:SetShadowOffset({X=2,Y=2});text:SetShadowColorAndOpacity({R=0,G=0,B=0,A=1})
            end)
            widget:SetVisibility(4)
            text:SetVisibility(4)
            widget:AddToViewport(950)
            item={widget=widget,text=text,world=name(w)}
            screens[key]=item
        end
        if item.message~=message then item.text:SetText(FText(message));item.message=message end
    end
    local cards=Cards.new(config,deps,ui)
    local revive=Revive.new(config,deps,ui)
    local errors={}
    local function safe(label,fn)
        local ok,e=pcall(fn)
        if not ok and not errors[label..tostring(e)]then errors[label..tostring(e)]=true;deps.log(label..": "..tostring(e))end
    end
    local pending=false
    local reviveAt=0
    local function tick()
        local w=deps.current_world()
        if not valid(w)then return end
        local state=deps.state()
        local st=H.GetGameplayStatics()
        local sys=H.GetKismetSystemLibrary()
        if not valid(st) or not valid(sys)then return end
        if sys:IsStandalone(w) or not name(w):find("/Game/Arenas/",1,true) or name(w):find("/MainMenu/",1,true)then
            if state.party_guard=="true"then deps.send("party_guard|0")end
            cards.reset();revive.reset();return
        end
        local players={}
        if sys:IsServer(w)then
            for _,c in ipairs(FindAllOf("PlayerController") or {})do
                if valid(c) and name(c:GetWorld())==name(w) and valid(c.PlayerState)
                    and valid(c.Pawn) and c.Pawn:IsA("/Script/RevengeOfTheMage.RM_MageBase")
                    and name(c.Pawn.Controller)==name(c)then
                    players[tostring(c.PlayerState.PlayerId)]={p=c.Pawn,c=c}
                end
            end
        end
        safe("Party cards",function()cards.tick(w,st,sys,state,players)end)
        if name(w):find("/Game/Arenas/Arena_",1,true) then
            local now=st:GetRealTimeSeconds(w)
            if now<reviveAt or now-reviveAt>=0.2 then
                reviveAt=now
                safe("Party revival",function()revive.tick(w,st,sys,state,players,cards.isPaused() or st:IsGamePaused(w))end)
            end
        else
            if state.party_guard=="true" then deps.send("party_guard|0") end
            revive.reset()
        end
    end
    local LoopAsync=deps.every or LoopAsync
    local ExecuteInGameThread=deps.every and function(fn) fn() end or ExecuteInGameThread
    LoopAsync(64,function()
        if not pending then pending=true;ExecuteInGameThread(function()
            safe("Party gameplay",tick);pending=false
        end)end
        return false
    end)
    return M
end
return M
