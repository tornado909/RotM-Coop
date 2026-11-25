-- Restore the local guest's ability bar after Unreal's network possession.
-- Ability data is already present on the guest; the stock HUD skips painting
-- its spell icons and input-key images when the pawn is created by replication.
local UEHelpers = require("UEHelpers")
local Module = {}

local SLOT_NAMES = {
    "BPW_ActivePrimarySpellControl",
    "BPW_ActiveSpellControl2",
    "BPW_ActiveSpellControl3",
    "BPW_ActiveSpellControl4",
    "BPW_ActiveSpellControl4_1",
}
local ABILITY_INPUTS = { 1, 2, 3, 4, 7 }
local KEY_TEXTURE_NAMES = {
    "Mouse_Left_Key_Light",
    "Mouse_Right_Key_Light",
    "Q_Key_Light",
    "E_Key_Light",
    "Shift_Key_Light",
}

local function valid(obj)
    local ok, result = pcall(function() return obj and obj:IsValid() end)
    return ok and result == true
end

local function fullname(obj)
    if not valid(obj) then return "" end
    local ok, name = pcall(function() return obj:GetFullName() end)
    return ok and tostring(name) or ""
end

local function find_child(root, suffix)
    local queue, cursor = { root }, 1
    while cursor <= #queue and cursor < 110 do
        local item = queue[cursor]
        cursor = cursor + 1
        if valid(item) then
            local name = fullname(item)
            if name:sub(-#suffix) == suffix then return item end
            local ok, count = pcall(function() return item:GetChildrenCount() end)
            if ok and type(count) == "number" then
                for i = 0, math.min(30, count - 1) do
                    local success, child = pcall(function() return item:GetChildAt(i) end)
                    if success and valid(child) then
                        queue[#queue + 1] = child
                    end
                end
            end
        end
    end
end

local function paint(image, texture)
    if not valid(image) or not valid(texture) then return false end
    local old_texture
    local ok = pcall(function() old_texture = image.Brush.ResourceObject end)
    local needs_texture = not ok or fullname(old_texture) ~= fullname(texture)
    local visible_ok, visibility = pcall(function() return image:GetVisibility() end)
    local needs_visibility = not visible_ok or visibility ~= 0
    if not needs_texture and not needs_visibility then return false end
    if needs_texture then image:SetBrushFromTexture(texture, false) end
    if needs_visibility then image:SetVisibility(0) end
    return true
end

function Module.install(config, deps)
    if config.hud_spells_sync == false then return Module end
    local last_owner, logged_error

    local function sync()
        local world = deps.current_world()
        if not valid(world) then return end
        local system = UEHelpers.GetKismetSystemLibrary()
        if not valid(system) or system:IsStandalone(world) or system:IsServer(world) then
            return
        end

        local statics = UEHelpers.GetGameplayStatics()
        local controller = valid(statics) and statics:GetPlayerController(world, 0)
        local pawn = valid(controller) and controller.Pawn
        if not valid(pawn) then return end
        local robe = pawn.CharacterRobeComponent
        if not valid(robe) then return end

        -- HUD_InGame is an AHUD, not the game-instance-owned UMG widget.
        local gi = statics:GetGameInstance(world)
        local gi_name = fullname(gi):match("^%S+ (.+)$")
        if not gi_name then return end
        local hud, fallback, count
        count = 0
        for _, widget in ipairs(FindAllOf("BPW_GameHUD_C") or {}) do
            if valid(widget) and fullname(widget):find(gi_name .. ".", 1, true) then
                local owner_ok, owner = pcall(function() return widget:GetOwningPlayer() end)
                if not owner_ok or not valid(owner) or fullname(owner) == fullname(controller) then
                    count = count + 1
                    fallback = widget
                    local ok, in_viewport = pcall(function() return widget:IsInViewport() end)
                    if ok and in_viewport == true then
                        if hud then return end
                        hud = widget
                    end
                end
            end
        end
        if not hud and count == 1 then hud = fallback end
        if not valid(hud) then return end
        local hud_id = fullname(hud):match("^%S+ (.+)$")
        if not hud_id then return end
        local panel
        for _, widget in ipairs(FindAllOf("BPW_ActiveSpellsPanel_C") or {}) do
            if valid(widget) and fullname(widget):find(hud_id .. ".", 1, true) then
                panel = widget
                break
            end
        end
        if not valid(panel) then return end

        local abilities = {}
        robe.OwnedAbilityMap:ForEach(function(key, data)
            abilities[key:get()] = data:get()
        end)

        local repaired = 0
        for i, slot_name in ipairs(SLOT_NAMES) do
            local slot = panel[slot_name]
            if valid(slot) then
                local widget_tree = slot.WidgetTree
                local root = valid(widget_tree) and widget_tree.RootWidget
                if valid(root) then
                    local entry = abilities[ABILITY_INPUTS[i]]
                    local icon = entry and entry.Icon
                    local foreground = find_child(root, "ForegroundImage")
                    if paint(foreground, icon) then repaired = repaired + 1 end

                    local name = KEY_TEXTURE_NAMES[i]
                    local path = "/Game/Prompts/Keyboard___Mouse/Light/" .. name .. "." .. name
                    local key_image = find_child(root, "KeyImage")
                    local texture = StaticFindObject(path)
                    if valid(key_image) and valid(texture) then
                        if paint(key_image, texture) then repaired = repaired + 1 end
                        local fallback_text = find_child(root, "TextBlockKey")
                        if valid(fallback_text) then
                            local ok, visibility = pcall(function()
                                return fallback_text:GetVisibility()
                            end)
                            if ok and visibility ~= 2 then
                                fallback_text:SetVisibility(2)
                            end
                        end
                    end
                end
            end
        end

        local owner = fullname(pawn) .. "|" .. fullname(hud)
        if repaired > 0 and (owner ~= last_owner or repaired > 5) then
            deps.log("Guest ability HUD synchronized: slots=" .. repaired ..
                " pawn=" .. fullname(pawn))
        end
        last_owner = owner
        logged_error = nil
    end

    local LoopAsync=deps.every or LoopAsync
    local ExecuteInGameThread=deps.every and function(fn) fn() end or ExecuteInGameThread
    LoopAsync(1600, function()
        ExecuteInGameThread(function()
            local ok, err = pcall(sync)
            if not ok and tostring(err) ~= logged_error then
                logged_error = tostring(err)
                deps.log("Guest ability HUD sync error: " .. logged_error)
            end
        end)
        return false
    end)
    return Module
end

return Module
