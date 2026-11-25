package.path="mod/RotMCoop/Scripts/?.lua;"..package.path
-- Verifies the native-game Play path does not deadlock a lobby in ready=0.
package.preload["UEHelpers"] = function() return {} end
local module = dofile("mod/RotMCoop/Scripts/steam_menu.lua")
local hub = "World /Game/Arenas/MageHub_New/MageHub_New.MageHub_New"
local menu = "World /Game/Arenas/MainMenu/MainMenu.MainMenu"
assert(not module.should_start_listen("42", menu, true, 100))
assert(not module.should_start_listen("42", hub, false, 101))
assert(not module.should_start_listen("42", hub, true, 102))
assert(not module.should_start_listen("42", hub, true, 106))
assert(module.should_start_listen("42", hub, true, 107))
for i=108,160 do assert(not module.should_start_listen("42",hub,true,i)) end
assert(not module.should_start_listen("42",hub,false,161))
assert(not module.should_start_listen("42",hub,true,162))
assert(not module.should_start_listen("42",hub,true,180))
assert(not module.should_start_listen("0",hub,true,181))
assert(not module.should_start_listen("43",hub,true,182))
assert(module.should_start_listen("43",hub,true,187))
assert(not module.should_start_listen("43",hub,true,200))
-- A new lobby created without an intervening role-poll must still wait 5s.
assert(not module.should_start_listen("44",hub,true,201))
assert(not module.should_start_listen("44",hub,true,205))
assert(module.should_start_listen("44",hub,true,206))
assert(not module.should_start_listen("44",hub,true,215))
print("Host standalone MageHub auto-listen regression passed")

local pyramid = "World /Game/Arenas/Arena_Pyramid/Arena_Pyramid.Arena_Pyramid"
assert(not module.should_start_listen("44", pyramid, true, 220))
assert(not module.should_start_listen("44", pyramid, true, 224))
assert(module.should_start_listen("44", pyramid, true, 225))
assert(not module.should_start_listen("44", pyramid, true, 240))
assert(not module.should_start_listen("44", pyramid, false, 241))
assert(not module.should_start_listen("44", hub, true, 242))
assert(module.should_start_listen("44", hub, true, 247))
assert(not module.should_start_listen("44", menu, true, 260))
print("Native portal destination auto-listen regression passed")