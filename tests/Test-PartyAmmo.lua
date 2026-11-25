package.path = "mod/RotMCoop/Scripts/?.lua;" .. package.path
package.preload.UEHelpers=function()return {}end
local m=dofile("mod/RotMCoop/Scripts/party_ammo.lua")
local x,n=m.parse("A|1|5|257:13:30;258:0:30",1)
assert(x["257"].ammo==13 and x["258"].ammo==0 and x["258"].max==30 and n==5)
assert(not m.parse("A|2|5|257:13:30",1))
assert(not m.parse("A|1|5|257:31:30",1))
assert(not m.parse("A|1|5|257:0:30;257:0:30",1))
assert(not m.parse("A|1|0|257:0:30",1))
print("PARTY AMMO PROTOCOL OK")

local a=m.parse("A|1|6|257:12:30:1:99:400:1000;258:30:30:0:0:0:0",1)
assert(a["257"].animation.slot==1 and a["257"].animation.token==99 and a["257"].animation.ms==400)
assert(a["258"].animation.slot==0)
assert(not m.parse("A|1|6|257:12:30:3:99:400:1000",1))
assert(not m.parse("A|1|6|257:12:30:1:0:400:1000",1))
assert(not m.parse("A|1|6|257:12:30:0:99:0:0",1))
assert(not m.parse("A|1|6|257:12:30:8:99:600001:1000",1))
print("PARTY AMMO MONTAGE SNAPSHOT OK")
