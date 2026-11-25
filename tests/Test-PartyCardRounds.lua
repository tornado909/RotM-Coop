package.path="mod/RotMCoop/Scripts/?.lua;"..package.path
package.preload.UEHelpers=function()return {}end
RegisterHook=function()end
RegisterKeyBind=function()end
local cards=require("party_cards")
local function obj(name,fields)
    fields=fields or {}
    fields.IsValid=function()return true end
    fields.GetFullName=function()return name end
    return fields
end
local now,paused=0,false
local world=obj("World Hub")
local sys={IsServer=function()return true end}
local state={game_epoch="1",lobby="7",role="host",session_stage="hub"}
local published,choices,notices="", "", {}
local ui={clear=function()end,status=function(_,msg)notices[#notices+1]=msg end}
local deps={
    send=function(s)published=s:match("^party_cards|(.*)$") or published;return true end,
    read=function()return choices end, log=function()end
}
local function cc(id)
    local c=obj("CC "..id,{n=0,selecting=false,readyAt=nil,CurrentSelectableCards={}})
    function c:GetPendingCardSelections()return self.n end
    function c:GetIsCardSelection()return self.selecting end
    function c:offer()
        self.n=1;self.selecting=true
        self.CurrentSelectableCards={{CardId={ToString=function()return "Card"..id end}}}
    end
    function c:DebugOpenDraft()
        -- Emulate a native delayed offer. It cannot finish during pause.
        self.n=1;self.readyAt=now+0.3
    end
    function c:CardSelect(i)
        assert(i==0 and self.selecting)
        self.n=0;self.selecting=false;self.CurrentSelectableCards={}
    end
    return c
end
local h,g=cc("Host"),cc("Guest")
local host=obj("PC Host",{bIsLocalPlayerController=true})
local guest=obj("PC Guest",{bIsLocalPlayerController=false})
local players={
 ["257"]={p=obj("Pawn Host",{bIsDead=false,CharacterCardSystemComponent=h}),c=host},
 ["258"]={p=obj("Pawn Guest",{bIsDead=false,CharacterCardSystemComponent=g}),c=guest}
}
local st={
 GetRealTimeSeconds=function()return now end,
 IsGamePaused=function()return paused end,
 SetGamePaused=function(_,w,v)paused=v end,
 GetPlayerController=function()return host end
}
local m=cards.new({},deps,ui)
local function step(dt)
 now=now+dt
 for _,c in ipairs({h,g})do if c.readyAt and now>=c.readyAt and not paused then c.readyAt=nil;c:offer()end end
 m.tick(world,st,sys,state,players)
end
for round=1,2 do
 h:offer();step(1)
 assert(not paused,"must not pause while guest offers are pending")
 local first=assert(cards.parse(published,1))
 assert(first.round==round and first.players["258"]==nil)
 h:CardSelect(0)
 step(0.4)
 assert(paused,"pause once guest offer is ready")
 local packet=assert(cards.parse(published,1))
 assert(packet.round==round and #packet.players["257"]==0 and packet.players["258"][1]=="CardGuest")
 choices="76561198000000000\t1|"..round.."|258|1"
 step(0.1)
 assert(not paused,"round must resume after both players choose")
 assert(g.n==0 and published=="1|"..round.."|-")
end
print("TWO CONSECUTIVE CARD ROUNDS AND DELAYED OFFERS OK")
