package.preload.UEHelpers=function() return {} end
local path="mod/RotMCoop/Scripts/"
local l=dofile(path.."party_loadout.lua")
local g=dofile(path.."party_gate.lua")
local w=dofile(path.."party_loading.lua")
local function cls(n) return {IsValid=function()return true end,GetFName=function()return {ToString=function()return n end}end} end
local slots={"GA_A_C","GA_B_C","GA_C_C","GA_D_C"}
local robe={RobeType=2}
for i,k in ipairs({"PrimaryAbilities","SecondaryAbilities","UltimateAbilities","UtilityAbilities"}) do robe[k]={{InputID=i,AbilityClass=cls(slots[i])}} end
assert(#l.validate(2,slots,{robe})==4)
assert(not l.validate(1,slots,{robe}))
assert(not l.validate(2,{"GA_A_C","GA_C_C","GA_B_C","GA_D_C"},{robe}))
local p=l.parse({"123\t4|258|2|GA_A_C|GA_B_C|GA_C_C|GA_D_C"},4)
assert(p["258"].robe==2)
assert(not l.parse({"123\t4|258|2|GA_A_C|GA_B_C|GA_C_C|GA_D_C"},5)["258"])
assert(not l.parse({"123\t4|258|2|GA_A_C|GA_B_C|GA_C_C|GA_D_C","124\t4|258|2|GA_A_C|GA_B_C|GA_C_C|GA_D_C"},4)["258"])
assert(g.outside({X=-400,Y=0},{X=0,Y=0},{X=-1,Y=0},1))
assert(not g.outside({X=600,Y=0},{X=0,Y=0},{X=-1,Y=0},1))
assert(w.message({role="guest",lobby="1",status="playing",session_stage="loading"},"",true,true))
assert(not w.message({role="guest",lobby="1",status="playing",session_stage="run"},"",true,true))
assert(not w.message({role="host",lobby="1",status="playing",session_stage="loading"},"",true,true))
print("PARTY TESTS OK")