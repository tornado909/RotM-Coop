local gate=dofile("mod/RotMCoop/Scripts/startup_gate.lua").new(1500)
assert(not gate:step("",false,10000))
assert(not gate:step("menu",true,100))
for i=1,14 do assert(not gate:step("menu",true,100))end
assert(not gate:step("menu",false,100))
assert(not gate:step("menu",true,100))
assert(not gate:step("other",true,100))
for i=1,14 do assert(not gate:step("other",true,100))end
assert(gate:step("other",true,100))
assert(gate:step("",false,100))
print("STARTUP GATE OK")