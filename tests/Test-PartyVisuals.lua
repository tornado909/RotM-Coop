package.path="mod/RotMCoop/Scripts/?.lua;"..package.path
package.preload.UEHelpers=function()return {}end
package.preload.party_loadout=function()return {}end
local m=dofile("mod/RotMCoop/Scripts/party_visuals.lua")
local s=m.parse("1|257:1:1000:1000:0;258:2:0:800:1",1)
assert(s["257"].hp==1000 and s["258"].robe==2 and s["258"].dead)
assert(not m.parse("2|257:1:1000:1000:0",1))
assert(not m.parse("1|257:7:0:100:0",1))
assert(not m.parse("1|257:1:101:100:0",1))
assert(not m.parse("1|257:1:0:0:1",1))
assert(not m.parse("1|257:1:0:100:0;257:2:10:100:0",1))
assert(next(m.parse("1|-",1))==nil)
local a={X=0,Y=0,Z=0};local b={X=120,Y=0,Z=0}
local v=m.smooth(a,b,0.016)
assert(v.X>0 and v.X<120)
for i=1,50 do v=m.smooth(v,b,0.016) end
assert(math.abs(v.X-120)<1)
local snap=m.smooth(a,{X=2000,Y=0,Z=0},0.016);assert(snap.X==2000)
print("PARTY VISUALS OK")