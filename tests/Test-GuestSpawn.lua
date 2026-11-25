package.preload.UEHelpers=function() return {} end
local m=dofile("mod/RotMCoop/Scripts/guest_spawn.lua")
local a={first=0}
assert(not m.decide(a,0,false,true,true))
assert(not m.decide(a,1,false,true,true))
assert(m.decide(a,2,false,true,true))
assert(not m.decide(a,3,false,true,true))
local b={first=0}
assert(not m.decide(b,1,true,false,true))
assert(not m.decide(b,3,false,true,true))
local d={first=0}
assert(not m.decide(d,16,false,true,true))
local e={first=0}
assert(not m.decide(e,1,false,true,false))
assert(not m.decide(e,3,false,true,true))
print("guest spawn decision tests passed")
