package.path = "mod/RotMCoop/Scripts/?.lua;" .. package.path
package.preload.UEHelpers = function() return {} end
local m = require("party_fx")

local begin = m.decode("X|3|258|17|1|1|B|/Game/VFX/NS_A.NS_A|100|200|300|0|90|-5|1|2|3|2500", 3)
assert(begin and begin.player == 258 and begin.key == "258:17:1" and begin.pos.Y == 200)
assert(begin.rot.Roll == -5 and begin.rot.Yaw == 90 and begin.scale.Z == 3 and begin.duration == 2.5)
assert(not m.decode("X|2|258|17|1|1|E", 3))
assert(not m.decode("X|3|258|17|1|1|B|/Game/../Bad.Bad|100|200|300|0|90|0|1|1|1|0", 3))
assert(not m.decode("X|3|258|17|1|2|U|100||300|0|90|0|1|1|1", 3))
assert(not m.decode("X|3|258|17|1|2|U|100|2|300|900|90|0|1|1|1", 3))

local update = m.decode("X|3|258|17|1|2|U|420|200|300|-45|90|5|1|2|3|User.Intensity:f:0.5", 3)
assert(not m.advance(nil, update))
local state = m.advance(nil, begin)
assert(m.advance(state, begin) == state)
state = m.advance(state, update)
assert(state.asset == begin.asset and state.pos.X == 420 and state.parameters == "User.Intensity:f:0.5")
assert(m.advance(state, begin) == state)
local ending = m.decode("X|3|258|17|1|3|E", 3)
state = m.advance(state, ending)
assert(state.ended and m.advance(state, begin) == state and m.advance(state, update) == state)
assert(m.advance(nil, ending).ended)
local ally = m.decode("X|3|259|17|1|1|B|/Game/VFX/NS_A.NS_A|100|200|300|0|90|0|1|1|1|0", 3)
assert(ally.key ~= begin.key and not m.advance(nil, ally).ended)
print("PARTY FX PROTOCOL OK")

local pos={X=20,Y=30,Z=10}
local candidates={a={asset="/Game/FX/Test.Test",pos={X=0,Y=0,Z=10},at=1}}
assert(m.matchLanding(candidates,"/Game/FX/Test.Test",pos,1.1)==candidates.a)
assert(not m.matchLanding(candidates,"/Game/FX/Other.Other",pos,1.1))
assert(not m.matchLanding(candidates,"/Game/FX/Test.Test",pos,3))
candidates.b={asset=candidates.a.asset,pos=pos,at=1}
assert(not m.matchLanding(candidates,candidates.a.asset,pos,1.1))
candidates.b.claimed=true
assert(m.matchLanding(candidates,candidates.a.asset,pos,1.1)==candidates.a)
print("PARTY LANDING CORRELATION OK")

local q=m.predict({X=1,Y=2,Z=3},"RotMVel:v:1000,-100,50",0.5)
assert(q.X==101 and q.Y==-8 and q.Z==8)
assert(m.predict({X=1,Y=2,Z=3},"RotMVel:v:999999,0,0",0.1).X==1)
assert(m.predict({X=1,Y=2,Z=3},nil,0.1).X==1)
print("Projectile interpolation bounds passed")
