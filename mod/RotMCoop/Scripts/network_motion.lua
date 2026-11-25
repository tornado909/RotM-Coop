-- Conservative network tuning. Do not disable server position validation.
-- The guest's MaxWalkSpeed matches the server (1200); the issue is visible
-- residual interpolation / delayed movement corrections, not a speed mismatch.
local UEHelpers = require("UEHelpers")
local Module = {}

local function valid(obj)
    return obj and obj:IsValid()
end

function Module.install(config, deps)
    if config.network_motion_tuning == false then return Module end
    local seen = {}

    local function apply(obj, prop, value)
        local ok, before = pcall(function() return obj[prop] end)
        if not ok or type(before) ~= "number" then return false end
        if math.abs(before - value) < 0.0001 then return true end
        local success = pcall(function() obj[prop] = value end)
        if not success then return false end
        local read_ok, after = pcall(function() return obj[prop] end)
        return read_ok and type(after) == "number"
            and math.abs(after - value) < 0.005
    end

    local function tune()
        local ok, err = pcall(function()
            local world = deps.current_world()
            if not valid(world) then return end
            local sys = UEHelpers.GetKismetSystemLibrary()
            if not valid(sys) or sys:IsStandalone(world) then return end
            local server = sys:IsServer(world)
            local world_name = world:GetFullName()
            for _, mage in ipairs(FindAllOf("RM_MageBase") or {}) do
                if valid(mage) and mage:GetWorld():GetFullName() == world_name then
                    local id = mage:GetFullName()
                    if not seen[id] then
                        local movement = mage.CharacterMovement
                        if valid(movement) then
                            local target, values = {}, {}
                            if server then
                                target = {
                                    {mage, "MinNetUpdateFrequency", 30.0},
                                    {movement, "NetworkMinTimeBetweenClientAckGoodMoves", 0.05},
                                    {movement, "NetworkMinTimeBetweenClientAdjustments", 0.05},
                                    {movement, "NetworkMinTimeBetweenClientAdjustmentsLargeCorrection", 0.03},
                                }
                            else
                                target = {
                                    {movement, "NetworkSimulatedSmoothLocationTime", 0.05},
                                    {movement, "NetworkSimulatedSmoothRotationTime", 0.03},
                                    {movement, "NetworkMaxSmoothUpdateDistance", 128.0},
                                    {movement, "NetworkNoSmoothUpdateDistance", 192.0},
                                }
                            end
                            local changed, rejected = 0, {}
                            for _, item in ipairs(target) do
                                if apply(item[1], item[2], item[3]) then
                                    changed = changed + 1
                                else
                                    rejected[#rejected+1] = item[2]
                                end
                            end
                            seen[id] = true
                            deps.log("Network movement "..(changed == #target and "tuned" or "partial")..
                                ": "..(server and "server" or "client")..
                                " fields="..changed.."/"..#target.." pawn="..id..
                                (#rejected>0 and (" rejected="..table.concat(rejected,",")) or ""))
                        end
                    end
                end
            end
        end)
        if not ok then deps.log("Network tuning error: "..tostring(err)) end
    end

    local LoopAsync=deps.every or LoopAsync
    local ExecuteInGameThread=deps.every and function(fn) fn() end or ExecuteInGameThread
    LoopAsync(1800, function()
        ExecuteInGameThread(tune)
        return false
    end)
    return Module
end

return Module
