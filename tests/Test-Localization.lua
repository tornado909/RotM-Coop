local culture="en"
StaticFindObject=function()return {GetCurrentCulture=function()return {ToString=function()return culture end}end}end
local m=dofile("mod/RotMCoop/Scripts/localization.lua")
assert(m.validate())
for _,v in ipairs({"ar","de","es","fr","ja","ko","pl","pt-BR","pt-PT","ru","tr-TR","zh-Hans","zh-Hant"})do
    culture=v;assert(m.t("Waiting for party")~="Waiting for party",v)
    assert(m.t("CREATE LOBBY")~="CREATE LOBBY",v)
end
culture="en";assert(m.t("Fire")=="Fire")
print("ALL 14 LANGUAGES OK")
