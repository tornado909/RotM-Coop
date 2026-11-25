local L=require("localization")
-- Authoritative per-player drafts. Only the server rolls and applies cards.
local H=require("UEHelpers")
local M={}
local function valid(o)local ok,v=pcall(function()return o and o:IsValid()end);return ok and v==true end
local function name(o)return valid(o) and o:GetFullName() or "" end
local function same(a,b)return valid(a) and valid(b) and name(a)==name(b)end
function M.parse(raw,epoch)
    local e,r,body=raw:match("^(%d+)|(%d+)|(.*)$")
    if tonumber(e)~=epoch or not tonumber(r) then return nil end
    local result={round=tonumber(r),players={}}
    if body=="-" then return result end
    for line in body:gmatch("[^;]+")do
        local id,slots=line:match("^(%d+):(.+)$")
        if not id or result.players[id] then return nil end
        local list={}
        if slots~="-" then
            for card in slots:gmatch("[^,]+") do
                if not card:match("^[%w_]+$") or #card>80 then return nil end
                list[#list+1]=card
            end
            if #list<1 or #list>3 then return nil end
        end
        result.players[id]=list
    end
    return result
end
function M.enabledStage(stage) return stage=="hub" or stage=="run" end
function M.complete(players)
    local count=0
    for _,v in pairs(players)do count=count+1;if not v.done then return false end end
    return count>0
end
local function offer(cc)
    if not valid(cc) or not cc:GetIsCardSelection() then return nil end
    local a=cc.CurrentSelectableCards
    if #a<1 or #a>3 then return nil end
    local ids={}
    for i=1,#a do
        local id=a[i].CardId:ToString()
        if not id:match("^[%w_]+$") then return nil end
        ids[i]=id
    end
    return ids
end
local function findConfig(cc,id)
    local arr=cc.CardsDataAsset.PassiveCards.PassiveCardConfigs
    for i=1,#arr do local a=arr[i];if a.CardId:ToString()==id then return a end end
end
local function setText(obj,text)
    if valid(obj) then obj:SetText(text) end
end
local function show(obj)
    if valid(obj) then obj:SetVisibility(0);obj:SetRenderOpacity(1) end
end
local function hide(obj)
    if valid(obj) then obj:SetVisibility(1) end
end
function M.new(config,deps,ui)
    local round=0
    local nextRoundAt=0
    local active=nil
    local lastPayload=nil
    local panel=nil
    local byWidget={}
    local localDraft=nil
    local lastSent=0
    local sentIndex=nil
    local localController=nil
    local locked=false
    local worldId=""
    local paused=false
    local lastPublishAt=-1
    local lastEpoch=0
    local function clearPanel()
        byWidget={}
        if valid(panel) then panel:RemoveFromParent() end
        panel=nil
        if locked and valid(localController) then
            pcall(function()localController:SetIgnoreMoveInput(false);localController.bShowMouseCursor=false end)
            local lib=StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
            if valid(lib) then
                pcall(function()lib:SetInputMode_GameOnly(localController,true)end)
            end
            pcall(function()localController:FlushPressedKeys()end)
            local p=localController.Pawn
            if valid(p) and p.bIsDead==false and valid(p.AbilitySystemComponent) then
                pcall(function()p.AbilitySystemComponent:SetUserAbilityActivationInhibited(false) end)
            end
        end
        locked=false;localController=nil
    end
    local function pick(index)
        if not localDraft or sentIndex or not localDraft.ids[index] then return end
        sentIndex=index;lastSent=0
        deps.log("Party card choice "..localDraft.ids[index])
        clearPanel()
    end
    pcall(RegisterHook,"/Script/RevengeOfTheMage.W_AbilityCard:CardSelected",function(ctx)
        local o=ctx:get()
        local i=byWidget[name(o)]
        if i then pick(i) end
    end)
    for i,k in ipairs({0x31,0x32,0x33})do
        pcall(RegisterKeyBind,k,function()ExecuteInGameThread(function()pick(i)end)end)
    end
    local function paintPanel(w,c,ids)
        local cc=c.Pawn.CharacterCardSystemComponent
        local cl=StaticFindObject("/Game/Gameplay/UI/CardWidgets/BPW_MainPanel.BPW_MainPanel_C")
        if not valid(cl)then local ok,o=pcall(LoadAsset,"/Game/Gameplay/UI/CardWidgets/BPW_MainPanel.BPW_MainPanel_C");if ok then cl=o end end
        local lib=StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        if not valid(cl) or not valid(lib) then return false end
        panel=lib:Create(w,cl,c)
        if not valid(panel) then return false end
        panel:AddToViewport(900)
        local sel=panel.PassiveCardSelectionPanel
        if not valid(sel) then clearPanel();return false end
        show(panel);show(sel);hide(panel.RerollButton);hide(panel.VoteCountdown)
        for i,key in ipairs({"BPW_AbilityCard","BPW_AbilityCard_1","BPW_AbilityCard_2"})do
            local card=sel[key]
            local data=ids[i] and findConfig(cc,ids[i])
            if valid(card) and data then
                card.PassiveCardConfig=data
                show(card)
                setText(card.CardNameText,data.CardName)
                setText(card.Title,data.CardName)
                setText(card.Description,data.CardDescription)
                setText(card.KeyText,FText(tostring(i)))
                pcall(function()setText(card.CurrentMagnitudeText,data.CurrentMagnitudeText);setText(card.NextMagnitudeText,data.NextMagnitudeText)end)
                pcall(function()
                    if valid(card.CardIcon) and valid(data.CardIcon) then card.CardIcon:SetBrushFromTexture(data.CardIcon,false);show(card.CardIcon) end
                    if valid(card.CardCategoryIcon) and valid(data.CardCategoryIcon) then card.CardCategoryIcon:SetBrushFromTexture(data.CardCategoryIcon,false) end
                end)
                pcall(function()if valid(card.CardButton)then card.CardButton:SetIsEnabled(true)end end)
                byWidget[name(card)]=i
            elseif valid(card) then hide(card) end
        end
        localController=c
        -- Suppress any held ability before giving focus to the UI.
        pcall(function()
            local asc=c.Pawn.AbilitySystemComponent
            for _,slot in ipairs({1,2,3,4,8})do asc:ReleaseInputID(slot)end
        end)
        c.bShowMouseCursor=true
        c:SetIgnoreMoveInput(true)
        locked=true
        pcall(function()c.Pawn.AbilitySystemComponent:SetUserAbilityActivationInhibited(true)end)
        pcall(function()lib:SetInputMode_GameAndUIEx(c,panel,0,false,false)end)
        return true
    end
    local function publish(epoch,now)
        local entries={}
        if active then
            for id,v in pairs(active.players)do
                if v.done or v.ids then
                    entries[#entries+1]=id..":"..(v.done and "-" or table.concat(v.ids,","))
                end
            end
        end
        table.sort(entries)
        local payload=epoch.."|"..round.."|"..(#entries>0 and table.concat(entries,";") or "-")
        if (payload~=lastPayload or now-lastPublishAt>=1 or now<lastPublishAt) and deps.send("party_cards|"..payload) then lastPayload=payload;lastPublishAt=now end
    end
    local function pending(cc)
        return valid(cc) and cc:GetPendingCardSelections() or 0
    end
    local function host(w,st,players,epoch)
        local now=st:GetRealTimeSeconds(w)
        local connected={}
        local anyPending=false
        for id,v in pairs(players)do
            if not v.p.bIsDead and valid(v.p.CharacterCardSystemComponent)then
                connected[id]=v
                if pending(v.p.CharacterCardSystemComponent)>0 or v.p.CharacterCardSystemComponent:GetIsCardSelection() then anyPending=true end
            end
        end
        if not active and anyPending and st:GetRealTimeSeconds(w)>=nextRoundAt then
            local n=0;for _ in pairs(connected)do n=n+1 end
            if n<2 then return end
            round=round+1
            active={players={},started=now}
            for id,v in pairs(connected)do
                active.players[id]={localPlayer=v.c.bIsLocalPlayerController==true,done=false,opened=false,pawn=name(v.p)}
            end
            deps.log("Party card round "..round.." started")
        end
        if not active then return end
        for id,v in pairs(active.players)do
            if not connected[id] or name(connected[id].p)~=v.pawn then active.players[id]=nil
            elseif not v.done then
                local cc=connected[id].p.CharacterCardSystemComponent
                local n=pending(cc)
                -- Offers may materialize on a later tick, particularly after
                -- a previous native draft. Do not pause before they exist.
                if not v.opened then
                    if n==0 and not cc:GetIsCardSelection() then cc:DebugOpenDraft() end
                    v.opened=true
                    n=pending(cc);v.initial=n
                end
                local current=offer(cc)
                if not v.ids then
                    if current then
                        v.ids=current;v.initial=n;v.offered=true
                        deps.log("Party card offered round="..round.." player="..id.." "..table.concat(current,","))
                    end
                elseif v.offered and (n<v.initial or not cc:GetIsCardSelection()) then
                    v.done=true
                end
            end
        end
        for line in deps.read("party-choices.txt"):gmatch("[^\r\n]+")do
            local sid,e,r,id,idx=line:match("^(%d+)\t(%d+)|(%d+)|(%d+)|([123])$")
            local v=id and active.players[id]
            local i=tonumber(idx)
            local cc=v and connected[id] and connected[id].p.CharacterCardSystemComponent
            if sid and valid(cc) and tonumber(e)==epoch and tonumber(r)==round and v and not v.localPlayer
                and not v.done and v.ids and v.ids[i] and offer(cc) then
                local actual=offer(cc)
                if actual and actual[i]==v.ids[i] then
                    local before=pending(cc)
                    cc:CardSelect(i-1)
                    if pending(cc)<before then
                        v.done=true
                        deps.log("Party card applied to player "..id..": "..v.ids[i])
                    end
                end
            end
        end
        local remaining,total,unready=0,0,0
        for _,v in pairs(active.players)do
            total=total+1
            if not v.done then
                remaining=remaining+1
                if not v.ids then unready=unready+1 end
            end
        end
        if unready>0 then
            -- Native card generation can depend on world ticks. A global
            -- pause before the remote offers exist deadlocks the draft.
            if st:IsGamePaused(w) then st:SetGamePaused(w,false) end
            paused=false
            publish(epoch,now)
            if now-active.started>=8 then
                deps.log("Party card round "..round.." aborted: missing native offers")
                active=nil;nextRoundAt=now+2
                publish(epoch,now);ui.clear("cards")
            end
            return
        end
        if remaining==0 then
            active=nil
            nextRoundAt=st:GetRealTimeSeconds(w)+0.5
            publish(epoch,now)
            if st:IsGamePaused(w) then st:SetGamePaused(w,false) end
            paused=false
            ui.clear("cards")
            deps.log("Party card round "..round.." complete")
        else
            if not st:IsGamePaused(w) then st:SetGamePaused(w,true) end
            paused=true
            publish(epoch,now)
            local localDone=false
            for _,v in pairs(active.players)do if v.localPlayer and v.done then localDone=true end end
            if localDone then ui.status("cards",L.t("Waiting for party").." ("..(total-remaining).."/"..total..")",w,st:GetPlayerController(w,0)) end
        end
    end
    local function guest(w,st,c,epoch)
        if not valid(c) or not valid(c.PlayerState) or not valid(c.Pawn) then return end
        local draft=M.parse(deps.read("party-cards.txt"),epoch)
        if not draft then return end
        local id=tostring(c.PlayerState.PlayerId)
        local ids=draft.players[id]
        if not ids then
            if localDraft then clearPanel();localDraft=nil;sentIndex=nil end
            ui.clear("cards");return
        end
        if #ids==0 then
            clearPanel();localDraft=nil;sentIndex=nil
            ui.status("cards",L.t("Waiting for party..."),w,c)
            return
        end
        local token=epoch..":"..draft.round..":"..table.concat(ids,",")
        if not localDraft or localDraft.token~=token then
            clearPanel();sentIndex=nil
            localDraft={token=token,round=draft.round,ids=ids,id=id}
            ui.clear("cards")
            local ok,painted=pcall(paintPanel,w,c,ids)
            if ok and painted then
                deps.log("Party draft UI displayed "..token.." "..table.concat(ids,","))
            else
                clearPanel();if not ok then deps.log("Card panel fallback: "..tostring(painted))end
                local lines={L.t("Choose your card:")}
                local cc=c.Pawn.CharacterCardSystemComponent
                for i,cardId in ipairs(ids)do
                    local data=findConfig(cc,cardId)
                    lines[#lines+1]=i..". "..(data and data.CardName:ToString() or cardId)
                    if data then lines[#lines+1]=data.CardDescription:ToString() end
                end
                ui.status("cards",table.concat(lines,"\n"),w,c)
            end
        end
        if sentIndex then
            local now=st:GetRealTimeSeconds(w)
            if now-lastSent>=1 or lastSent==0 then
                if deps.send("party_choice|"..epoch.."|"..draft.round.."|"..id.."|"..sentIndex) then lastSent=now end
            end
            ui.status("cards",L.t("Waiting for party..."),w,c)
        end
    end
    return {
        tick=function(w,st,sys,state,players)
            if config.party_cards==false then return end
            if not state.game_epoch or not state.lobby or not state.role then return end
            local epoch=tonumber(state.game_epoch) or 0
            if name(w)~=worldId or epoch~=lastEpoch then
                clearPanel();ui.clear("cards");active=nil;round=0;localDraft=nil;sentIndex=nil;lastPayload=nil
                worldId=name(w);lastEpoch=epoch;paused=false;nextRoundAt=0;lastPublishAt=-1
            end
            if epoch>0 and state.lobby~="0" and not M.enabledStage(state.session_stage) then return end
            if epoch==0 or state.lobby=="0" then
                if paused and sys:IsServer(w) and st:IsGamePaused(w) then st:SetGamePaused(w,false) end
                if active or localDraft or locked then clearPanel();ui.clear("cards");active=nil;localDraft=nil end
                paused=false;return
            end
            if sys:IsServer(w) and state.role=="host" then host(w,st,players,epoch)
            elseif state.role=="guest" and not sys:IsServer(w)then guest(w,st,st:GetPlayerController(w,0),epoch) end
        end,
        isPaused=function()return paused end,
        reset=function()clearPanel();ui.clear("cards");active=nil;localDraft=nil;paused=false end
    }
end
return M
