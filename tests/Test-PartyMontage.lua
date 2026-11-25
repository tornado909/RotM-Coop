package.path = "mod/RotMCoop/Scripts/?.lua;" .. package.path
local M=require("party_montage")
local registry,hooks,constructs={}, {},0
local function object(p,kind)
 local o={p=p,kind=kind,alive=true}
 function o:IsValid()return self.alive end
 function o:GetFullName()return self.kind.." "..self.p end
 function o:IsA(k)return self.kind=="Notify" and k=="/Script/RevengeOfTheMage.RM_AnimNotifyBase" or self.kind=="Ability" and k=="/Script/RevengeOfTheMage.RM_GameplayAbilityAnimBase" end
 function o:GetClass()return self.class end
 function o:GetOuter()return self.outer end
 registry[p]=o
 return o
end
local montageClass=object("/Script/Engine.AnimMontage","Class")
local abilityClass=object("/Game/GA_Test.GA_Test_C","Class")
local function montage(p,notify)
 local o=object(p,"Montage")
 o.class=montageClass;o.Notifies={{Notify=notify}};o.CompositeSections={1,2,3};o.SlotAnimTracks={1}
 function o:GetPlayLength()return 2 end
 return o
end
local original=montage("/Game/AM_Test.AM_Test",object("/Game/AM_Test.Notify","Notify"))
local cdo=object("/Game/Default__GA_Test_C","Ability")
cdo.class=abilityClass;cdo.AnimMontage=original
function StaticFindObject(p)return registry[p] end
function FName(s)return s end
local shallow=false
function StaticConstructObject(cl,pawn,n,f,g,h,i,source)
 assert(cl==montageClass and source==original)
 constructs=constructs+1
 local p=pawn.p.."."..n
 return montage(p,shallow and original.Notifies[1].Notify or object(p..".Notify","Notify"))
end
function NotifyOnNewObject(c,fn)assert(not hooks[c]);hooks[c]=fn end
local function actor(id)
 local p=object("/Game/World.Mage_"..id,"Pawn")
 return {pawn=p,asc={ActivatableAbilities={Items={{Ability=cdo,InputID=1}}}}}
end
local a,b=actor(1),actor(2)
local m=M.new(function()end)
m.update({a,b})
assert(constructs==2)
local function spawn(actor,id)
 local o=object(actor.pawn.p..".GA_"..id,"Ability")
 o.class=abilityClass;o.outer=actor.pawn;o.AnimMontage=original
 hooks[abilityClass.p](o)
 return o
end
local x,y=spawn(a,1),spawn(b,1)
assert(x.AnimMontage~=original and y.AnimMontage~=original and x.AnimMontage~=y.AnimMontage)
assert(x.AnimMontage.Notifies[1].Notify~=y.AnimMontage.Notifies[1].Notify and cdo.AnimMontage==original)
m.update({a,b});assert(constructs==2)
m.update({a});assert(spawn(b,2).AnimMontage==original)
x.AnimMontage.alive=false;m.update({a});assert(constructs==3 and spawn(a,3).AnimMontage~=x.AnimMontage)
m.clear();assert(spawn(a,4).AnimMontage==original)
a.pawn.bIsDead=true;local before=constructs;m.update({a});assert(constructs==before);a.pawn.bIsDead=false
shallow=true;m.update({a});assert(spawn(a,5).AnimMontage==original)
print("PARTY MONTAGE PER-PAWN NOTIFY ISOLATION OK")
