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
