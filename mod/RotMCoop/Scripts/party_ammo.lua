-- Read authoritative ammo for the HUD. Gameplay state belongs to GAS.
local H = require("UEHelpers")
local Combat = require("party_combat")
local Stock = require("hud_spells")
local PartyHUD = require("party_hud")
local Montages = require("party_montage")
local M = {}

local function valid(o) return o and o:IsValid() end

function M.parse(raw, epoch)
    local e, seq, body = raw:match("^A|(%d+)|(%d+)|([^\r\n]+)")
    if tonumber(e) ~= epoch or not tonumber(seq) or tonumber(seq) <= 0 then return end
    local out, count = {}, 0
    for row in body:gmatch("[^;]+") do
        local id, ammo, maxAmmo, slot, token, ms, rate = row:match("^(%d+):(%d+):(%d+):(%d+):(%d+):(%d+):(%d+)$")
        if not id then id, ammo, maxAmmo = row:match("^(%d+):(%d+):(%d+)$") end
        ammo, maxAmmo = tonumber(ammo), tonumber(maxAmmo)
        if not id or tonumber(id) <= 0 or out[id] or not maxAmmo
            or maxAmmo <= 0 or maxAmmo > 100000 or ammo > maxAmmo then return end
        count = count + 1
        if count > 4 then return end
        local animation
        if slot then
            slot, token, ms, rate = tonumber(slot), tonumber(token), tonumber(ms), tonumber(rate)
            if slot == 0 then
                if token~=0 or ms~=0 or rate~=0 then return end
            elseif (slot~=1 and slot~=8) or token<1 or token>4294967295 or ms>600000 or rate<1 or rate>10000 then return end
            animation={slot=slot,token=token,ms=ms,rate=rate}
        end
        out[id] = {ammo = ammo, max = maxAmmo, animation=animation}
    end
    if count > 0 then return out, tonumber(seq) end
end

local function ammo(player)
    local sets = player.asc.SpawnedAttributes
    for i = 1, #sets do
        local a = sets[i]
        if valid(a) and a:IsA("/Script/RevengeOfTheMage.RM_AttributeSetBase")
            and a:GetOuter():GetFullName() == player.pawn:GetFullName() then
            local value, max = a.CurrentAmmo.CurrentValue, a.MaxAmmo.CurrentValue
            if type(value) == "number" and value == value and type(max) == "number"
                and max > 0 and max <= 100000 then
                return math.floor(math.max(0, math.min(value, max)) + 0.5), math.floor(max + 0.5)
            end
        end
    end
end

local function text(widget, value)
    if valid(widget) and widget:GetText():ToString() ~= value then widget:SetText(FText(value)) end
end

local function updateHud(stat, world, player, data, authoritative, elapsed)
    local hud = Stock.local_hud(stat, world, player.controller)
    local panel = valid(hud) and Stock.spell_panel(hud)
    if not valid(panel) then return end
    local primary = panel[Stock.slots[1]]
    if valid(primary) and valid(primary.WidgetTree) and data then
        text(Stock.child(primary.WidgetTree.RootWidget, "CurrentStackText"), tostring(data.ammo))
    end
    local snapshot = authoritative or PartyHUD.capture(player.pawn, 0, stat:GetTimeSeconds(world))
    if not snapshot then return end
    for i = 2, #Stock.slots do
        local slot, spell = panel[Stock.slots[i]], snapshot.spells[i]
        if valid(slot) and spell then
            local label, bar = slot.CooldownText, slot.SpellCooldownProgressBar
            local remaining=math.max(0,spell.remaining-(authoritative and elapsed or 0)*100)
            local on = spell.duration > 0 and remaining > 0
            if valid(label) then
                text(label, tostring(math.ceil(remaining / 100)))
                label:SetVisibility(on and 3 or 1)
            end
            if valid(bar) then
                bar:SetPercent(on and remaining / spell.duration or 1)
                bar:SetVisibility(on and 3 or 1)
            end
        end
    end
end

function M.install(config, deps)
    if config.party_ammo == false then return end
    local session, sequence, lastReceived = nil, 0, 0
    local lastSent, lastBody, snapshot = -1, nil, nil
    local errors = {}
    local lastVisual, visualSnapshot, visualAt
    local lastAmmoAt, animationSequence, animationIds = nil, 0, {}
    local presentation=Montages.presentation(deps.log)
    local function tick()
        local world, epoch, host, key = Combat.session(deps)
        if key ~= session then
            session, lastReceived, lastSent, lastBody, snapshot = key, 0, -1, nil, nil
            lastVisual,visualSnapshot,visualAt=nil,nil,nil
            lastAmmoAt,animationIds=nil,{}
            presentation.clear()
        end
        if not world then return end
        local stat = H.GetGameplayStatics()
        if host then
            local rows = {}
            for id, player in pairs(Combat.roster(world)) do
                local current, max = ammo(player)
                if current then
                    local animation=Montages.capture(player)
                    local token,slot,ms,rate=0,0,0,0
                    if animation then
                        local old=animationIds[id]
                        if not old or old.path~=animation.path then
                            animationSequence=animationSequence+1
                            old={path=animation.path,token=animationSequence}
                            animationIds[id]=old
                        end
                        token,slot,ms,rate=old.token,animation.slot,animation.ms,animation.rate
                    else animationIds[id]=nil end
                    rows[#rows+1] = string.format("%s:%d:%d:%d:%d:%d:%d", id, current, max,slot,token,ms,rate)
                end
            end
            if #rows == 0 or #rows > 4 then return end
            table.sort(rows)
            local body = table.concat(rows, ";")
            local now = stat:GetRealTimeSeconds(world)
            if body ~= lastBody or now - lastSent >= 0.25 then
                sequence = sequence + 1
                if deps.send(string.format("party_ammo|%d|%d|%s", epoch, sequence, body)) then
                    lastSent, lastBody = now, body
                end
            end
        else
            local pc = stat:GetPlayerController(world, 0)
            local player = valid(pc) and Combat.identity(pc.Pawn, world)
            if not player then return end
            local data, seq = M.parse(deps.read("party-ammo.txt"), epoch)
            local now=stat:GetRealTimeSeconds(world)
            if data and seq > lastReceived then snapshot,lastReceived,lastAmmoAt=data,seq,now end
            local gameTime=stat:GetTimeSeconds(world)
            local visual=deps.read("party-visuals.txt")
            if visual~=lastVisual then
                local parsed=PartyHUD.parseVisuals(visual,epoch)
                if parsed then lastVisual,visualSnapshot,visualAt=visual,parsed,gameTime end
            end
            local id=tostring(player.id)
            local row=snapshot and snapshot[id]
            presentation.update(player, lastAmmoAt and now-lastAmmoAt<0.8 and row and row.animation or nil)
            updateHud(stat, world, player, row, visualSnapshot and visualSnapshot[id],
                visualAt and math.max(0,gameTime-visualAt) or 0)
        end
    end
    deps.every(100, function()
        local ok, err = pcall(tick)
        if not ok and not errors[tostring(err)] then
            errors[tostring(err)] = true
            deps.log("Party ammo HUD: " .. tostring(err))
        end
    end)
end

return M
