local installed_hook
RegisterBeginPlayPreHook = function(callback)
    assert(installed_hook == nil)
    installed_hook = callback
end

local mage_class = "/Script/RevengeOfTheMage.RM_MageBase"
local pc_class = "/Script/RevengeOfTheMage.RM_PlayerController"
local function object(identity, kind, world, pawn)
    local result = { identity = identity, kind = kind, world = world, Pawn = pawn }
    function result:IsValid() return true end
    function result:GetLocalRole() return self.role or 3 end
    function result:GetFullName() return self.identity end
    function result:GetWorld() return self.world end
    function result:IsA(class_name) return self.kind == class_name end
    return result
end

local a = object("World /Game/Hub.Hub")
local a_proxy = object("World /Game/Hub.Hub")
local b = object("World /Game/Other.Other")
assert(a ~= a_proxy, "World wrappers must be distinct")

local host_pawn = object("host mage", mage_class)
local host = object("host controller", pc_class, a, host_pawn)
local guest = object("guest controller", pc_class, a_proxy)
local other_world = object("other controller", pc_class, b)
local controllers = { host, guest, other_world }
FindAllOf = function(class_name)
    assert(class_name == "PlayerController")
    return controllers
end

local module=dofile("mod/RotMCoop/Scripts/early_controller.lua")
module.set_enabled(function()return true end)
assert(installed_hook, "The module must install a BeginPlay prehook")

local function run(mage)
    installed_hook({ get = function() return mage end })
end

local mage = object("guest mage", mage_class, a)
run(mage)
assert(mage.Controller == guest, "Unique free controller in matching world must be assigned")

local already_possessed = object("first mage", mage_class, a)
already_possessed.Controller = host
run(already_possessed)
assert(already_possessed.Controller == host, "Existing possession must be untouched")

local second_free = object("third controller", pc_class, a)
controllers = { host, guest, second_free }
local ambiguous = object("ambiguous mage", mage_class, a_proxy)
run(ambiguous)
assert(ambiguous.Controller == nil, "Ambiguous controllers must never be guessed")

controllers = { host, other_world }
local missing = object("unmatched mage", mage_class, a)
run(missing)
assert(missing.Controller == nil, "Other-world controller must never be assigned")

local non_mage = object("other actor", "/Script/Engine.Actor", a)
controllers = { guest }
run(non_mage)
assert(non_mage.Controller == nil, "Non-mage must be untouched")

local replica=object("simulated guest mage",mage_class,a)
replica.role=1
run(replica)
assert(not replica.Controller,"Simulated proxy must not claim a local controller")
print("Early controller unit tests passed")
