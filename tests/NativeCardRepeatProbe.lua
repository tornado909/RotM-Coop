local H=require("UEHelpers")
local Cards=require("party_cards")
assert(Cards.registerDraftLatch(),"draft latch unavailable")
local function valid(o)return o and o:IsValid()end
local function log(s)print("[CARDNATIVEQA] "..s.."\n")end
local n,phase,at=0,0,0
local failed=false
local function scan()
 local w=H.GetGameViewportClient():GetWorld()
 if not valid(w) then return end
 local st=H.GetGameplayStatics()
 local sys=H.GetKismetSystemLibrary()
 if not sys:IsServer(w) or sys:IsStandalone(w) then return end
 local ccs={}
 for _,c in ipairs(FindAllOf("PlayerController") or {})do
  if valid(c) and valid(c.PlayerState) and valid(c.Pawn) and valid(c.Pawn.CharacterCardSystemComponent) and c:GetWorld():GetFullName()==w:GetFullName() then
   ccs[#ccs+1]={cc=c.Pawn.CharacterCardSystemComponent,id=c.PlayerState.PlayerId,localP=c.bIsLocalPlayerController}
  end
 end
 if #ccs<2 then return end
 local now=st:GetRealTimeSeconds(w)
 if now<at then return end
 if phase==0 then
  n=n+1
  for _,v in ipairs(ccs)do
   log("BEFORE "..n.." id="..v.id.." local="..tostring(v.localP).." pending="..v.cc:GetPendingCardSelections().." selecting="..tostring(v.cc:GetIsCardSelection()).." latch="..tostring(v.cc.RotMRemoteDraftClosing).." count="..#v.cc.CurrentSelectableCards)
   v.cc:DebugOpenDraft()
  end
  phase=1;at=now+1
 elseif phase==1 then
  for _,v in ipairs(ccs)do
   log("OFFER "..n.." id="..v.id.." pending="..v.cc:GetPendingCardSelections().." selecting="..tostring(v.cc:GetIsCardSelection()).." latch="..tostring(v.cc.RotMRemoteDraftClosing).." count="..#v.cc.CurrentSelectableCards)
   if v.cc:GetIsCardSelection() and #v.cc.CurrentSelectableCards>0 then
    local ok=Cards.chooseRemote(v.cc,0)
    log("APPLIED "..n.." id="..v.id.." "..tostring(ok));if not ok then failed=true end
   else failed=true end
  end
  if st:IsGamePaused(w) then st:SetGamePaused(w,false)end
  phase=2;at=now+1
 else
  for _,v in ipairs(ccs)do
   if v.cc:GetPendingCardSelections()~=0 or v.cc:GetIsCardSelection() or v.cc.RotMRemoteDraftClosing~=0 then failed=true end
   log("AFTER "..n.." id="..v.id.." pending="..v.cc:GetPendingCardSelections().." selecting="..tostring(v.cc:GetIsCardSelection()).." latch="..tostring(v.cc.RotMRemoteDraftClosing).." count="..#v.cc.CurrentSelectableCards)
  end
  if n>=3 then phase=3;at=math.huge;log(failed and "FAIL" or "PASS") else phase=0;at=now+1 end
 end
end
LoopAsync(250,function()ExecuteInGameThread(function()local ok,e=pcall(scan);if not ok then log(tostring(e))end end);return false end)
