local L = require("localization")
local Loadout = require("party_loadout")
local Revive = require("party_revive")
local Stock = require("hud_spells")
local M = {}

local LIMIT = 100000000
local COOLDOWN_LIMIT = 360000
local NATIVE_BARS = {"HealthBar", "ArmorBar", "ShieldBar"}
local BAR_WIDTH = 162
local SPELL_WIDTH = 124
local LABEL_WIDTH = 215
local COLUMN_SPACING = 6
local ROW_WIDTH = LABEL_WIDTH + (#NATIVE_BARS * BAR_WIDTH) + SPELL_WIDTH
    + (2 + #NATIVE_BARS) * COLUMN_SPACING
local ROW_HEIGHT = 90
local GAP = 8
local NONINTERACTIVE = 3
-- The player attribute set stores primary ammo and maximum stacks for the
-- other slots. Their spent charges are stacks of the slot's cooldown effect.
local STACK_CAPACITY = {[2] = "MaxSecondarySpellStack", [3] = "MaxUltimateSpellStack",
    [4] = "MaxUtilitySpellStack", [5] = "MaxDashCharges"}

local function valid(obj)
    local ok, value = pcall(function() return obj and obj:IsValid() end)
    return ok and value == true
end

local function field(obj, key)
    local ok, value = pcall(function() return obj[key] end)
    if ok then return value end
end

local function objectName(obj)
    return valid(obj) and obj:GetFName():ToString() or ""
end

local function objectPath(obj)
    return valid(obj) and obj:GetFullName():match("^%S+ (.+)$")
end

local function amount(n, limit)
    if type(n) == "number" and n == n and n >= 0 and n <= limit then
        return math.floor(n + 0.5)
    end
end

local function split(value, delimiter)
    local fields = {}
    for item in (value .. delimiter):gmatch("(.-)" .. delimiter) do
        fields[#fields + 1] = item
    end
    return fields
end

function M.parseVisuals(raw, epoch)
    local e, body = raw:match("^(%d+)|([^\r\n]+)$")
    if not e or tonumber(e) ~= epoch or epoch <= 0 or #raw > 2048 then return end
    local result = {}
    if body == "-" then return result end
    local rows = split(body, ";")
    if #rows > 4 then return end
    for _, rawRow in ipairs(rows) do
        local r = split(rawRow, ":")
        local id, robe, hp, maxHealth, dead = r[1], tonumber(r[2]), tonumber(r[3]), tonumber(r[4]), r[5]
        if (#r ~= 5 and #r ~= 10) or not id:match("^[1-9]%d*$") or #id > 10 or tonumber(id) > 2147483647 or result[id]
            or not r[2]:match("^[1-6]$") or not r[3]:match("^%d+$") or not r[4]:match("^%d+$")
            or maxHealth <= 0 or maxHealth > LIMIT or hp > maxHealth or (dead ~= "0" and dead ~= "1") then return end
        local row = {robe = robe, hp = hp, max = maxHealth, dead = dead == "1"}
        if #r == 10 then
            for i = 6, 9 do
                if not r[i]:match("^%d+$") or not amount(tonumber(r[i]), LIMIT) then return end
            end
            row.armor, row.maxArmor = tonumber(r[6]), tonumber(r[7])
            row.shield, row.maxShield = tonumber(r[8]), tonumber(r[9])
            if row.armor > row.maxArmor or row.shield > row.maxShield then return end
            row.spells = {}
            local spells = split(r[10], ",")
            if #spells ~= #Stock.inputs then return end
            for i, spell in ipairs(spells) do
                if spell ~= "-" then
                    local class, remaining, duration, charges, capacity =
                        spell:match("^(GA_[%w_]+_C)%.(%d+)%.(%d+)%.([%d%-]+)%.([%d%-]+)$")
                    if not class or #class > 60 then return end
                    remaining, duration = tonumber(remaining), tonumber(duration)
                    if duration > COOLDOWN_LIMIT or remaining > duration then return end
                    if charges ~= "-" or capacity ~= "-" then
                        if not charges:match("^%d+$") or not capacity:match("^%d+$") then return end
                        charges, capacity = tonumber(charges), tonumber(capacity)
                        if capacity > 100000 or charges > capacity then return end
                    else
                        charges, capacity = nil, nil
                    end
                    row.spells[i] = {class = class, remaining = remaining, duration = duration, charges = charges, capacity = capacity}
                end
            end
        end
        result[id] = row
    end
    return result
end

function M.encodeRow(id, row)
    local spells = {}
    for i = 1, #Stock.inputs do
        local spell = row.spells[i]
        spells[i] = spell and table.concat({spell.class, spell.remaining, spell.duration,
            spell.charges or "-", spell.capacity or "-"}, ".") or "-"
    end
    return table.concat({id, row.robe, row.hp, row.max, row.dead and 1 or 0,
        row.armor, row.maxArmor, row.shield, row.maxShield, table.concat(spells, ",")}, ":")
end

local function attribute(set, key)
    local value = field(set, key)
    return amount(value and field(value, "CurrentValue"), LIMIT)
end

local function getAttributes(pawn, asc)
    local sets = asc.SpawnedAttributes
    for i = 1, #sets do
        local current = sets[i]
        if valid(current) and current:IsA("/Script/RevengeOfTheMage.RM_AttributeSetBase")
            and objectPath(current:GetOuter()) == objectPath(pawn) then return current end
    end
end

function M.health(pawn)
    local asc = pawn.AbilitySystemComponent
    if not valid(asc) then return end
    local a = getAttributes(pawn, asc)
    if a then
        local hp, maxHealth = attribute(a, "HealthPower"), attribute(a, "MaxHealth")
        if hp and maxHealth and maxHealth > 0 then return math.min(hp, maxHealth), maxHealth end
    end
end

function M.capture(pawn, robe, now)
    local asc = pawn.AbilitySystemComponent
    if not valid(asc) then return end
    local a = getAttributes(pawn, asc)
    if not a then return end
    local hp, maxHealth = attribute(a, "HealthPower"), attribute(a, "MaxHealth")
    if not hp or not maxHealth or maxHealth <= 0 then return end
    local armor, maxArmor = attribute(a, "Armor") or 0, attribute(a, "MaxArmor") or 0
    local shield, maxShield = attribute(a, "Shield") or 0, attribute(a, "MaxShield") or 0
    local dead = pawn.bIsDead == true
    local row = {robe = robe, hp = dead and 0 or math.min(hp, maxHealth), max = maxHealth, dead = dead,
        armor = math.min(armor, maxArmor), maxArmor = maxArmor, shield = math.min(shield, maxShield),
        maxShield = maxShield, spells = {}}
    local cooldowns = {}
    local items = asc.ActivatableAbilities.Items
    for i = 1, #items do
        local spec = items[i]
        for slot, input in ipairs(Stock.inputs) do
            if spec.InputID == input and valid(spec.Ability) then
                local class = objectName(spec.Ability:GetClass())
                if #class <= 60 and class:match("^GA_[%w_]+_C$") then
                    local spell = {class = class, remaining = 0, duration = 0}
                    local effect = spec.Ability.CooldownGameplayEffectClass
                    local path = objectPath(effect)
                    local cap = slot == 1 and "MaxAmmo" or STACK_CAPACITY[slot]
                    local capacity = cap and attribute(a, cap)
                    if capacity and capacity > 0 and capacity <= 100000 then
                        local charges = slot == 1 and attribute(a, "CurrentAmmo")
                        if charges then
                            spell.charges, spell.capacity = math.min(charges, capacity), capacity
                        elseif path then
                            -- A non-primary spell spends one stack of its cooldown
                            -- effect for each unavailable charge.
                            local spent = amount(asc:GetGameplayEffectCount(effect, asc, false), 100000)
                            if spent then spell.charges, spell.capacity = math.max(0, capacity - spent), capacity end
                        end
                    end
                    if path then
                        cooldowns[path] = cooldowns[path] or {}
                        table.insert(cooldowns[path], spell)
                    end
                    row.spells[slot] = spell
                end
                break
            end
        end
    end
    local effects = asc.ActiveGameplayEffects.GameplayEffects_Internal
    for i = 1, #effects do
        local effect = effects[i]
        local spec = effect.Spec
        local spells = valid(spec.Def) and cooldowns[objectPath(spec.Def:GetClass())]
        local duration = spec.Duration
        if spells and type(duration) == "number" and duration > 0 and duration <= COOLDOWN_LIMIT / 100 then
            local remaining = math.max(0, math.min(duration, effect.StartWorldTime + duration - now))
            local cs = math.ceil(remaining * 100)
            for _, spell in ipairs(spells) do
                if cs > spell.remaining then spell.remaining, spell.duration = cs, math.ceil(duration * 100) end
            end
        end
    end
    return row
end

local function text(widget, value)
    if valid(widget) and widget:GetText():ToString() ~= value then
        widget:SetText(FText(value))
    end
end

local function contents(widget)
    local tree = valid(widget) and widget.WidgetTree
    return valid(tree) and tree.RootWidget or nil
end

local BAR_FIELDS = {"ProgressBar", "DelayedProgressBar", "TextBlockValue", "TextBlockValueMin",
    "TextBlockValueMax", "TextBlockPercentage"}
local KEY_FIELDS = {"KeyIcon_SizeBox", "KeyImage_SizeBox", "KeyIcon_BackgroundImage", "KeyImage", "TextBlockKey"}
local SPELL_FIELDS = {"ForegroundImage", "SpellCooldownProgressBar", "CooldownText", "CurrentStackText",
    table.unpack(KEY_FIELDS)}

local function componentPaths(widget, fields)
    local result = {root = objectPath(widget)}
    for name, child in pairs(Stock.children(contents(widget), fields)) do
        result[name] = objectPath(child)
    end
    return result
end

local function lookup(path)
    if path then return StaticFindObject(path) end
end

local function paintBar(parts, value, max)
    if not parts then return end
    local bar = lookup(parts.root)
    if not valid(bar) then return end
    if max == nil then bar:SetVisibility(2); return end
    local percent = max > 0 and math.min(value / max, 1) or 0
    for _, name in ipairs({"ProgressBar", "DelayedProgressBar"}) do
        local progress = lookup(parts[name])
        if valid(progress) then progress:SetPercent(percent) end
    end
    text(lookup(parts.TextBlockValue), string.format("%d / %d", value, max))
    text(lookup(parts.TextBlockValueMin), tostring(value))
    text(lookup(parts.TextBlockValueMax), tostring(max))
    text(lookup(parts.TextBlockPercentage), string.format("%d%%", math.floor(percent * 100 + 0.5)))
    bar:SetVisibility(max > 0 and NONINTERACTIVE or 2)
end

local function paintSpell(parts, spell, icon, elapsed)
    if not parts then return end
    local image = lookup(parts.ForegroundImage)
    if valid(icon) then Stock.paint(image, icon)
    elseif valid(image) then image:SetVisibility(1) end
    local remain = spell and math.max(0, spell.remaining / 100 - elapsed) or 0
    local progress = lookup(parts.SpellCooldownProgressBar)
    if valid(progress) then
        if remain > 0 then progress:SetPercent(math.min(1, remain / (spell.duration / 100))) end
        progress:SetVisibility(remain > 0 and NONINTERACTIVE or 1)
    end
    local countdown = lookup(parts.CooldownText)
    if valid(countdown) then
        if remain > 0 then text(countdown, tostring(math.ceil(remain))) end
        countdown:SetVisibility(remain > 0 and NONINTERACTIVE or 1)
    end
    local charges = lookup(parts.CurrentStackText)
    if valid(charges) then
        local count = spell and spell.charges
        if count then text(charges, tostring(count)) end
        charges:SetVisibility(count and NONINTERACTIVE or 1)
    end
    for _, key in ipairs(KEY_FIELDS) do
        local hint = lookup(parts[key])
        if valid(hint) and hint:GetVisibility() ~= 1 then hint:SetVisibility(1) end
    end
end

local function resolveIcons(pc, row)
    local robe = pc.Pawn.CharacterRobeComponent
    if not valid(robe) or not valid(robe.RobeSelectionData) then return {} end
    local slots, icons = {}, {}
    for i = 1, 4 do
        if not row.spells[i] then return icons end
        slots[i] = row.spells[i].class
    end
    local entries = Loadout.validate(row.robe, slots, robe.RobeSelectionData.RobeSelectionData)
    if entries then
        for i, entry in ipairs(entries) do icons[i] = entry.Icon end
    end
    local dash = row.spells[5]
    if dash then
        robe.OwnedAbilityMap:ForEach(function(key, value)
            if key:get() == Stock.inputs[5] then
                local data = value:get()
                if objectName(data.AbilityClass) == dash.class then icons[5] = data.Icon end
            end
        end)
    end
    return icons
end

local function playerNames(deps, epoch, snapshot)
    local names, result, owner = {}, {}, nil
    for line in deps.read("members.txt"):gmatch("[^\r\n]+") do
        local sid, name, isOwner = line:match("^(%d+)\t([^\t]+)\t([01])\t")
        if sid and name and #name <= 128 then
            names[sid] = name
            if isOwner == "1" then owner = name end
        end
    end
    local profiles = {}
    for line in deps.read("profiles.txt"):gmatch("[^\r\n]+") do profiles[#profiles + 1] = line end
    for id, profile in pairs(Loadout.parse(profiles, epoch)) do result[id] = names[profile.sid] end
    local missing, count = nil, 0
    for id in pairs(snapshot) do
        if not result[id] then missing = id; count = count + 1 end
    end
    if count == 1 then result[missing] = owner end
    return result
end

function M.orderedPlayers(snapshot, localId)
    local ids = {}
    for id in pairs(snapshot) do
        if id ~= localId then ids[#ids + 1] = id end
    end
    table.sort(ids, function(a, b) return tonumber(a) < tonumber(b) end)
    return ids
end

function M.position(width, left, bottom)
    local scale = math.min(1, math.max(0, (width - 2 * GAP) / ROW_WIDTH))
    local x = math.max(GAP, math.min(width - ROW_WIDTH * scale - GAP, left))
    return {X = x, Y = -bottom - GAP}, scale
end

local function findAnchor(hud, world)
    local canvas = contents(hud)
    local lib = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    if not valid(canvas) or not canvas:IsA("/Script/UMG.CanvasPanel") or not valid(lib) then return end
    local scale = lib:GetViewportScale(world)
    local viewport = lib:GetViewportSize(world)
    if scale <= 0 or viewport.X <= 2 * GAP then return end
    local left, bottom = nil, 0
    -- The native vitality widgets are bottom-left children of the canvas's
    -- full-screen Overlay. Their slot padding is already in DPI-aware units.
    for _, stock in pairs(Stock.children(canvas, {"HealthBar_SizeBox", "ArmorBar_SizeBox"})) do
        if valid(stock) then
            local slot = stock.Slot
            if valid(slot) and slot.HorizontalAlignment == 1 and slot.VerticalAlignment == 3 then
                local padding = slot.Padding
                left = math.min(left or padding.Left, padding.Left)
                bottom = math.max(bottom, padding.Bottom + stock:GetDesiredSize().Y)
            end
        end
    end
    if not left then return end
    local position, rowScale = M.position(viewport.X / scale, left, bottom)
    return canvas, position, rowScale
end

function M.new(config, deps)
    local groupPath, rowPaths, roster, serial = nil, {}, "", 0
    local function construct(tree, class, label)
        serial = serial + 1
        local widget = StaticConstructObject(StaticFindObject("/Script/UMG." .. class),
            tree, FName("RotM" .. label .. serial))
        if not valid(widget) then error("Unable to create " .. class) end
        widget:SetVisibility(NONINTERACTIVE)
        return widget
    end
    local function clear()
        local group = groupPath and StaticFindObject(groupPath)
        if valid(group) then group:RemoveFromParent() end
        groupPath, rowPaths, roster = nil, {}, ""
    end
    local function addCell(tree, row, child, width, scalable)
        local size = construct(tree, "SizeBox", "AllySize")
        size:SetWidthOverride(width)
        size:SetHeightOverride(ROW_HEIGHT)
        if scalable then
            local scale = construct(tree, "ScaleBox", "AllyScale")
            scale:SetStretch(2)
            scale:SetContent(child)
            child = scale
        end
        size:SetContent(child)
        local slot = row:AddChildToHorizontalBox(size)
        slot:SetPadding({Left = COLUMN_SPACING / 2, Top = 0, Right = COLUMN_SPACING / 2, Bottom = 0})
        slot:SetVerticalAlignment(2)
    end
    local function clone(lib, world, pc, template)
        if not valid(template) then return end
        local widget = lib:Create(world, template:GetClass(), pc)
        if valid(widget) then
            widget:SetVisibility(NONINTERACTIVE)
            return widget
        end
    end
    local function createRow(world, pc, tree, templates, spellPanel)
        local lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        local row = construct(tree, "HorizontalBox", "AllyRow")
        local components = {labels = {}, bars = {}, spells = {}}
        local labels = construct(tree, "VerticalBox", "AllyLabels")
        local source = Stock.child(contents(templates[1]), "TextBlockValue")
            or Stock.child(contents(templates[1]), "TextBlockValueMin")
            or Stock.child(contents(spellPanel[Stock.slots[1]]), "CurrentStackText")
        for i = 1, 2 do
            local label = construct(tree, "TextBlock", "AllyLabel")
            if valid(source) then
                label:SetFont(source.Font)
                label:SetColorAndOpacity(source.ColorAndOpacity)
                label:SetShadowOffset(source.ShadowOffset)
                label:SetShadowColorAndOpacity(source.ShadowColorAndOpacity)
            end
            local font = label.Font
            font.Size = i == 1 and 19 or 14
            label:SetFont(font)
            label:SetTextOverflowPolicy(1)
            labels:AddChildToVerticalBox(label)
            components.labels[i] = objectPath(label)
        end
        addCell(tree, row, labels, LABEL_WIDTH, false)
        for i = 1, #NATIVE_BARS do
            local widget = clone(lib, world, pc, templates[i])
            if valid(widget) then
                addCell(tree, row, widget, BAR_WIDTH, true)
                components.bars[i] = componentPaths(widget, BAR_FIELDS)
            end
        end
        -- Slot widgets require the native panel's Blueprint template, which
        -- initializes their per-slot GAS attributes before native construction.
        local spells = clone(lib, world, pc, spellPanel)
        if valid(spells) then
            addCell(tree, row, spells, SPELL_WIDTH, true)
            components.panel = objectPath(spells)
            for i, name in ipairs(Stock.slots) do
                local control = spells[name]
                if valid(control) then components.spells[i] = componentPaths(control, SPELL_FIELDS) end
            end
        end
        return row, components
    end
    local function update(world, pc, hud, snapshot, epoch, elapsed)
        if config.party_ally_health == false or not valid(pc.PlayerState) or not valid(hud) then
            clear()
            return
        end
        local localId = tostring(pc.PlayerState.PlayerId)
        local ids = M.orderedPlayers(snapshot, localId)
        if #ids == 0 then clear(); return end
        local panel = Stock.spell_panel(hud)
        if not valid(panel) then clear(); return end
        local canvas, position, scale = findAnchor(hud, world)
        if not valid(canvas) then clear(); return end
        local tree = hud.WidgetTree
        local key = objectPath(canvas) .. ":" .. table.concat(ids, ",")
        local group = groupPath and StaticFindObject(groupPath)
        if not valid(group) or key ~= roster then
            clear()
            local templates, found = {}, Stock.children(tree.RootWidget, NATIVE_BARS)
            for i, name in ipairs(NATIVE_BARS) do templates[i] = found[name] end
            group = construct(tree, "VerticalBox", "AllyStack")
            for _, id in ipairs(ids) do
                local row, components = createRow(world, pc, tree, templates, panel)
                group:AddChildToVerticalBox(row)
                rowPaths[id] = components
            end
            local slot = canvas:AddChildToCanvas(group)
            slot:SetAnchors({Minimum = {X = 0, Y = 1}, Maximum = {X = 0, Y = 1}})
            slot:SetAlignment({X = 0, Y = 1})
            slot:SetAutoSize(true)
            group:SetRenderTransformPivot({X = 0, Y = 1})
            groupPath, roster = objectPath(group), key
            deps.log("Ally HUD attached to native game HUD, rows=" .. #ids)
        end
        local anchorSlot = group.Slot
        anchorSlot:SetPosition(position)
        group:SetRenderScale({X = scale, Y = scale})
        local names = playerNames(deps, epoch, snapshot)
        local downed = Revive.parse(deps.read("party-downed.txt"), epoch) or {}
        for index, id in ipairs(ids) do
            local row, paths = snapshot[id], rowPaths[id]
            text(lookup(paths.labels[1]), names[id] or (L.t("Ally") .. " " .. index))
            local progress = downed[id] and downed[id].progress
            local status = lookup(paths.labels[2])
            if valid(status) then
                if progress and progress > 0 then
                    text(status, string.format(L.t("Reviving ally  |  %.1f / 5 s"), progress))
                elseif row.dead or downed[id] then
                    text(status, L.t("Downed"))
                end
                status:SetVisibility((row.dead or downed[id]) and NONINTERACTIVE or 2)
            end
            paintBar(paths.bars[1], row.hp, row.max)
            paintBar(paths.bars[2], row.armor, row.maxArmor)
            paintBar(paths.bars[3], row.shield, row.maxShield)
            local spellsPanel = lookup(paths.panel)
            if valid(spellsPanel) then spellsPanel:SetVisibility(row.spells and NONINTERACTIVE or 1) end
            if row.spells then
                local icons = resolveIcons(pc, row)
                for i = 1, #Stock.slots do paintSpell(paths.spells[i], row.spells[i], icons[i], elapsed) end
            end
        end
    end
    return {update = update, clear = clear, inspect = function() return rowPaths end}
end

return M
