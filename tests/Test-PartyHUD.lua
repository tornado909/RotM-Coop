package.path = "mod/RotMCoop/Scripts/?.lua;" .. package.path
package.preload.UEHelpers = function() return {} end
local hud = require("party_hud")

local function character(playerId, hp, armor, ammo, spent)
    local pawn = {
        IsValid = function() return true end,
        GetFullName = function() return "RM_MageBase /Game/Pawn." .. playerId end,
    }
    local function attr(value) return {CurrentValue = value} end
    local attributes = {
        IsValid = function() return true end,
        IsA = function(_, class) return class == "/Script/RevengeOfTheMage.RM_AttributeSetBase" end,
        GetOuter = function() return pawn end,
        HealthPower = attr(hp),
        MaxHealth = attr(1000),
        Armor = attr(armor),
        MaxArmor = attr(100),
        CurrentAmmo = attr(ammo),
        MaxAmmo = attr(10),
        Shield = attr(30),
        MaxShield = attr(60),
        MaxSecondarySpellStack = attr(3),
    }
    local function obj(path, name)
        return {IsValid = function() return true end, GetFullName = function() return "Class /Game/" .. path end,
            GetFName = function() return {ToString = function() return name end} end}
    end
    local function ability(class, cooldown)
        return {IsValid = function() return true end, GetClass = function() return obj(class, class) end,
            CooldownGameplayEffectClass = cooldown}
    end
    local effect = obj("Cooldown", "Cooldown")
    pawn.AbilitySystemComponent = {
        IsValid = function() return true end,
        SpawnedAttributes = {attributes},
        ActivatableAbilities = {Items = {
            {Ability = ability("GA_FireShot_C"), InputID = 1},
            {Ability = ability("GA_FireBall_C", effect), InputID = 2},
        }},
        ActiveGameplayEffects = {GameplayEffects_Internal = {
            {Spec = {Def = {IsValid = function() return true end, GetClass = function() return effect end}, Duration = 4},
                StartWorldTime = 8},
        }},
        GetGameplayEffectCount = function(asc, class, source)
            assert(class == effect and asc == source)
            return spent
        end,
    }
    return pawn
end

local a = hud.capture(character(12, 880, 27, 4, 2), 1, 10)
local b = hud.capture(character(3, 550, 82, 7, 0), 2, 11)
assert(a.hp == 880 and a.armor == 27 and a.shield == 30)
assert(a.spells[1].charges == 4 and b.spells[1].charges == 7)
assert(a.spells[2].charges == 1 and b.spells[2].charges == 3)
assert(a.spells[2].remaining == 200 and b.spells[2].remaining == 100)

local line = hud.encodeRow("12", a)
local packet = "8|" .. table.concat({line, hud.encodeRow("3", b), hud.encodeRow("9", b), hud.encodeRow("25", a)}, ";")
local rows = assert(hud.parseVisuals(packet, 8))
assert(rows["12"].spells[1].charges == 4 and rows["3"].spells[1].charges == 7)
assert(rows["12"].spells[2].duration == 400 and rows["12"].spells[2].capacity == 3)
assert(table.concat(hud.orderedPlayers(rows, "9"), ",") == "3,12,25")
assert(not hud.parseVisuals(packet, 7))
assert(not hud.parseVisuals(packet .. ";" .. line, 8))
assert(not hud.parseVisuals("8|" .. line .. ";" .. line, 8))
assert(not hud.parseVisuals("8|" .. line:gsub("GA_FireBall_C", "/Game/GA_FireBall_C"), 8))
assert(not hud.parseVisuals("8|" .. line:gsub(":27:100:", ":101:100:"), 8))
assert(not hud.parseVisuals("8|" .. line:gsub("%.200%.400%.1%.3", ".401.400.1.3"), 8))
assert(not hud.parseVisuals("8|" .. line:gsub("%.200%.400%.1%.3", ".200.400.4.3"), 8))
assert(hud.parseVisuals("8|2:3:40:100:0", 8)["2"].hp == 40)
assert(next(hud.parseVisuals("8|-", 8)) == nil)

local layout, fullScale = hud.position(1920, 172, 108)
assert(layout.X == 172 and layout.Y == -116 and fullScale == 1)
local small, reducedScale = hud.position(640, 172, 108)
assert(small.X == 8 and reducedScale < 1)
print("Ally HUD snapshot, isolation, four-player order and layout passed")
