package.path="mod/RotMCoop/Scripts/?.lua;"..package.path
package.preload.UEHelpers=function()return {}end
local m=require("party_gate")
local o,n={X=0,Y=0,Z=0},{X=1,Y=0}
local function players(a,b)return {{id="a",pos={X=a,Y=0,Z=0}},{id="b",pos={X=b,Y=0,Z=0}}}end
for _,sign in ipairs({1,-1})do
 local s=m.observe(nil,players(-400*sign,-600*sign),o,n,80,false,0)
 s=m.observe(s,players(20*sign,-600*sign),o,n,80,true,1)
 assert(#m.plan(s,players(20*sign,-600*sign),o,n,80,1)==0)
 s=m.observe(s,players(400*sign,-600*sign),o,n,80,true,2)
 local p=m.plan(s,players(400*sign,-600*sign),o,n,80,2)
 assert(#p==1 and p[1].id=="b" and p[1].target.X*sign>400)
 s.moved.b=true
 assert(#m.plan(s,players(400*sign,-600*sign),o,n,80,3)==0)
end
local s=m.observe(nil,players(400,-600),o,n,80,true,0)
assert(#m.plan(s,players(400,-600),o,n,80,0)==0)
s=m.observe(nil,players(-400,400),o,n,80,false,0)
s=m.observe(s,players(400,-400),o,n,80,true,1)
assert(s.conflict and #m.plan(s,players(400,-400),o,n,80,1)==0)
print("Gate directional recovery tests passed")
