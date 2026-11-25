package.path="mod/RotMCoop/Scripts/?.lua;"..package.path
package.preload.UEHelpers=function()return {}end
local m=require("party_enemies")
local row="17:11575:11575:BP_Ghoul_C:0:1200:1"
local x=m.parse("N|41|2|258|0|"..row,41,258)
assert(x["17:11575:11575"].dead and x["17:11575:11575"].hp==0)
assert(not m.parse("N|41|2|258|0|"..row,41,259))
assert(not m.parse("N|40|2|258|0|"..row,41,258))
assert(not m.parse("N|41|2|258|0|"..row..";"..row,41,258))
assert(not m.parse("N|41|2|258|0|17:11575:11574:BP_Ghoul_C:0:1200:1",41,258))
assert(not m.parse("N|41|2|258|0|17:11575:11575:BP_Ghoul_C:1201:1200:0",41,258))
print("ENEMY SNAPSHOT PROTOCOL OK")

assert(m.localDummy("World /Game/Arenas/MageHub_New/MageHub_New","Class BP_M01_BasicMelee1_C",3))
assert(not m.localDummy("World /Game/Arenas/MageHub_New/MageHub_New","Class BP_M01_BasicMelee1_C",1))
assert(not m.localDummy("World /Game/Arenas/Arena_Pyramid/Arena_Pyramid","Class BP_M01_BasicMelee1_C",3))
assert(m.shouldSendBatch(nil,"a",0))
assert(not m.shouldSendBatch({body="a",at=0},"a",0.25))
assert(m.shouldSendBatch({body="a",at=0},"b",0.25))
assert(m.shouldSendBatch({body="a",at=0},"a",1))
print("Hub duplicate ownership and enemy snapshot throttling passed")
