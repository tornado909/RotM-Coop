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
Module.slots = SLOT_NAMES
Module.inputs = ABILITY_INPUTS

local function valid(obj)
    local ok, result = pcall(function() return obj and obj:IsValid() end)
    return ok and result == true
end

local function fullname(obj)
    if not valid(obj) then return "" end
    local ok, name = pcall(function() return obj:GetFullName() end)
    return ok and tostring(name) or ""
end

local function find_children(root, fields)
    local wanted, result = {}, {}
    local remaining = #fields
    for _, name in ipairs(fields) do wanted[name] = true end
    local queue, cursor = { root }, 1
    while remaining > 0 and cursor <= #queue and cursor <= 200 do
        local item = queue[cursor]
        cursor = cursor + 1
        if valid(item) then
            local name = fullname(item):match("([^.:/ ]+)$")
            if wanted[name] then
                result[name], wanted[name] = item, nil
                remaining = remaining - 1
            end
            local ok, count = pcall(function() return item:GetChildrenCount() end)
            if ok and type(count) == "number" then
                for i = 0, math.min(30, count - 1) do
                    local success, child = pcall(function() return item:GetChildAt(i) end)
                    if success and valid(child) then
                        queue[#queue + 1] = child
                    end
                end
            end
            local has_tree, tree = pcall(function() return item.WidgetTree end)
            if has_tree and valid(tree) and valid(tree.RootWidget) then queue[#queue + 1] = tree.RootWidget end
        end
    end
    return result
end
local function find_child(root, name)
    return find_children(root, {name})[name]
end

Module.child = find_child
Module.children = find_children

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
Module.paint = paint

-- The native RM_PlayerController.HUD property points to the actual local
-- gameplay widget. A remote possession can create a second BPW_GameHUD_C
-- under the same GI and even assign it the local controller as UMG owner.
-- Never choose by object order or remove the controller's own HUD.
local function hudCandidates(statics,world,controller)
    local gi=statics:GetGameInstance(world)
    local gi_name=fullname(gi):match("^%S+ (.+)$")
    if not gi_name then return nil,{},{} end
    local all,viewport={},{}
    local canonical
    local ok,preferred=pcall(function()return controller.HUD end)
    local preferredName=ok and fullname(preferred)or ""
    for _,widget in ipairs(FindAllOf("BPW_GameHUD_C")or{})do
        if valid(widget)and fullname(widget):find(gi_name..".",1,true)then
            local owner_ok,owner=pcall(function()return widget:GetOwningPlayer()end)
            if not owner_ok or not valid(owner)or fullname(owner)==fullname(controller)then
                all[#all+1]=widget
                local visible,inView=pcall(function()return widget:IsInViewport()end)
                if visible and inView==true then
                    viewport[#viewport+1]=widget
                    if owner_ok and valid(owner)and fullname(owner)==fullname(controller)
                        and fullname(widget)==preferredName then canonical=widget end
                end
            end
        end
    end
    return canonical,viewport,all
end
function Module.local_hud(statics,world,controller)
    local canonical,viewport,all=hudCandidates(statics,world,controller)
    if canonical then return canonical end
    if #viewport==1 then return viewport[1]end
    if #viewport==0 and #all==1 then return all[1]end
end
function Module.prune_duplicate_huds(statics,world,controller,log)
    local canonical,viewport=hudCandidates(statics,world,controller)
    if not valid(canonical)then return 0 end
    local count=0
    for _,widget in ipairs(viewport)do
        if fullname(widget)~=fullname(canonical)then
            local ok,owner=pcall(function()return widget:GetOwningPlayer()end)
            if ok and valid(owner)and fullname(owner)==fullname(controller)then
                widget:RemoveFromParent()
                if not widget:IsInViewport()then
                    count=count+1
                    log("Removed duplicate native HUD "..fullname(widget))
                end
            end
        end
    end
    return count
end

function Module.spell_panel(hud)
    if not valid(hud) then return end
    if valid(hud.ActiveSpellsPanel) then return hud.ActiveSpellsPanel end
    local hud_id = fullname(hud):match("^%S+ (.+)$")
    if not hud_id then return end
    for _, widget in ipairs(FindAllOf("BPW_ActiveSpellsPanel_C") or {}) do
        if valid(widget) and fullname(widget):find(hud_id .. ".", 1, true) then return widget end
    end
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

        local hud = Module.local_hud(statics, world, controller)
        if not valid(hud) then return end
        local panel = Module.spell_panel(hud)
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
