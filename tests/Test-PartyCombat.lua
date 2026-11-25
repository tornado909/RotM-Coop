package.path = "mod/RotMCoop/Scripts/?.lua;" .. package.path
package.preload.UEHelpers = function() return {} end
local m = require("party_combat")

local up = m.decodeAim("M|3|12|11.5|25|-40|82|11|-3|76561198000000000", 3)
assert(up and up.sid == "76561198000000000" and up.seq == 12)
assert(up.pos.X == 11.5 and up.rot.Pitch == 82 and up.rot.Roll == -3)
local down = m.decodeAim("M|3|13|11.5|25|-40|-82|11|8|21|-13|14|76561198000000000", 3)
assert(down and down.rot.Pitch == -82 and down.target.Y == -13)
local camera = m.decodeAim("M|3|14|11|25|-40|-82|11|8|C|-79|11|3|76561198000000000", 3)
assert(camera and camera.cameraRotation.Pitch == -79 and camera.rot.Pitch == -82)
local release = m.decodeInput("I|3|15|4|R|11|25|-40|-82|11|8|C|-79|11|3|76561198000000000", 3)
assert(release and release.slot == 4 and release.down == false and release.cameraRotation.Pitch == -79)
assert(not m.decodeInput("I|3|15|5|R|11|25|-40|-82|11|8|76561198000000000", 3))
assert(not m.decodeAim("M|2|13|11|25|-40|-82|11|8|76561198000000000", 3))
assert(not m.decodeAim("M|3|13|11||-40|-82|11|8|76561198000000000", 3))
assert(not m.decodeAim("M|3|13|11|25|-40|-982|11|8|76561198000000000", 3))
assert(not m.decodeAim("M|3|13|11|25|-40|-82|11|8|76561198000000000|123", 3))
print("PARTY COMBAT AIM OK")

local state = {}
assert(m.recordInput(state,{slot=1,seq=20,down=true},1))
assert(m.recordInput(state,{slot=2,seq=19,down=false},1))
assert(m.recordInput(state,{slot=1,seq=21,down=false},2))
assert(not m.recordInput(state,{slot=1,seq=20,down=true},3))
assert(state[1].down==false and state[1].at==2 and state[2].seq==19)
print("PARTY INPUT RECONCILIATION OK")

assert(m.primaryState(true,false,false)==false)
assert(m.primaryState(false,true,false)==true)
assert(m.primaryState(true,true,true)==false)
assert(m.primaryState(true,nil,false)==true)
assert(m.primaryState(false,nil,false)==false)
state[1].releaseApplied=true
assert(m.recordInput(state,{slot=1,seq=22,down=false},3))
assert(state[1].releaseApplied)
assert(m.recordInput(state,{slot=1,seq=23,down=true},4))
assert(not state[1].releaseApplied)
print("PRIMARY RELEASE AND BLOCKED INPUT OK")

local held={}
m.recordInput(held,{slot=1,seq=1,down=false},1)
held[1].releasedAt=1
m.recordInput(held,{slot=1,seq=2,down=false},1.2)
assert(not m.releaseOverdue(held[1],1.2,false))
assert(m.releaseOverdue(held[1],1.4,false))
m.recordInput(held,{slot=1,seq=3,down=true},1.5)
assert(not m.releaseOverdue(held[1],1.6,false))
local function obj(n) return {IsValid=function()return true end,GetFullName=function()return n end} end
local pawn,other=obj("PawnA"),obj("PawnB")
local cancelled=0
local a,b=obj("AbilityA"),obj("AbilityB")
a.GetAvatarActorFromActorInfo=function()return pawn end
b.GetAvatarActorFromActorInfo=function()return other end
a.K2_CancelAbility=function()cancelled=cancelled+1 end
b.K2_CancelAbility=function()error("wrong pawn")end
local ability=obj("Primary");ability.NetExecutionPolicy=3
local actor={pawn=pawn,asc={ActivatableAbilities={Items={{InputID=1,ActiveCount=1,Ability=ability,NonReplicatedInstances={a,b},ReplicatedInstances={}}}}}}
assert(m.cancelReleasedPrimary(actor)==1 and cancelled==1)
print("PRIMARY RELEASE RECOVERY OWNERSHIP OK")
