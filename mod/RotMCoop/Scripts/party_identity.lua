-- Resolve the live party-owned pawn and ASC without retaining Unreal wrappers.
local H = require("UEHelpers")
local M = {}

local function valid(o) return o and o:IsValid() end
local function same(a, b)
    return valid(a) and valid(b) and a:GetFullName() == b:GetFullName()
end

function M.resolve(pawn, world)
    if not valid(pawn) or not pawn:IsA("/Script/RevengeOfTheMage.RM_MageBase")
        or not same(pawn:GetWorld(), world) then return end
    local controller = pawn.Controller
    local ps = pawn.PlayerState
    local asc = pawn.AbilitySystemComponent
    if not valid(controller) or not same(controller.Pawn, pawn) or not valid(ps)
        or not same(ps, controller.PlayerState) or not valid(asc)
        or not same(asc.AvatarActor, pawn) or not same(asc.OwnerActor, pawn) then return end
    local id = tonumber(ps.PlayerId)
    if id and id > 0 then
        return {id = id, pawn = pawn, controller = controller, asc = asc}
    end
end

function M.bind(player)
    if not same(player.pawn.PC, player.controller) then player.pawn.PC = player.controller end
end

function M.roster(world)
    local result = {}
    local gs = H.GetGameplayStatics():GetGameState(world)
    if valid(gs) then
        local players = gs.PlayerArray
        for i = 1, #players do
            local ps = players[i]
            local player = valid(ps) and M.resolve(ps:GetPawn(), world)
            if player then result[tostring(player.id)] = player end
        end
    end
    return result
end

return M
