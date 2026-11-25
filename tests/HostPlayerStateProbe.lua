-- QA-only host-side player count sampling throughout a whole network join.
-- The ordinary +2/+10/+30 snapshots can miss a guest who joins after +30.
local UEHelpers = require("UEHelpers")
local saw_second = false
LoopAsync(1000, function()
    ExecuteInGameThread(function()
        if saw_second then return end
        local viewport = UEHelpers.GetGameViewportClient()
        if not viewport or not viewport:IsValid() then return end
        local world = viewport:GetWorld()
        if not world or not world:IsValid() then return end
        local stats = UEHelpers.GetGameplayStatics()
        if not stats or not stats:IsValid() then return end
        local state = stats:GetGameState(world)
        if not state or not state:IsValid() then return end
        local players = state.PlayerArray
        if not players then return end
        local count = #players
        if count >= 2 then
            saw_second = true
            print("[RotMHostTrace] playerStates=" .. count .. "\n")
        end
    end)
    return false
end)
