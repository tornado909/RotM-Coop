local L=require("localization")
-- Native UMG Steam matchmaking menu, using the game's existing button blueprint.
-- Background bridge uses Steamworks AppID 480 for test matchmaking only.
-- Gameplay network packets are transparently forwarded by Steam P2P / Valve relay.
-- The game talks only to a local loopback UDP proxy. No external host IP/port.
local UEHelpers = require("UEHelpers")
local Module = {}
local active_menu
local controls = {}
local base_widgets = {}
local ui_open = false
local invite_mode = false
local active_lobby_id
local handled_lobby_id
local patch_requested = false
local current_state = {}
local friend_offset = 0
local room_offset = 0
local active_join_epoch = 0
local previous_host_stage = ""
local previous_stage_lobby = ""
local previous_host_world = ""
local previous_host_world_lobby = ""
local pending_host_start = false
local last_ready_signal = 0
local waiting_for_new_map = false
local departing_map = ""
local travel_started = 0
-- Handles players who enter MageHub via the game's original Play button,
-- rather than clicking START GAME in the Steam lobby menu.
local auto_listen_world
local auto_listen_last_attempt = 0
local host_standalone_since = 0
local host_standalone_world = ""
local io_dir
local callbacks
local cfg
local log
local last_status = ""
local bridge_started = false
local last_update = 0
local button_class
local widget_lib

local function valid(o)
    if o == nil then return false end
    local ok, v = pcall(function() return o:IsValid() end)
    return ok and v == true
end
local function fullname(o)
    if not valid(o) then return "" end
    return tostring(o:GetFullName())
end
local function path(o)
    return fullname(o):match("^%S+%s+(.*)$") or ""
end
local function same(a, b)
    return valid(a) and valid(b) and path(a) == path(b)
end
local function find_child(root, class_name, suffix)
    local prefix = path(root) .. ".WidgetTree"
    if prefix == ".WidgetTree" then return nil end
    for _, item in ipairs(FindAllOf(class_name) or {}) do
        if valid(item) then
            local p = path(item)
            if p:find(prefix, 1, true) and p:sub(-#suffix - 1) == "." .. suffix then
                return item
            end
        end
    end
end
local function get_menu()
    for _, menu in ipairs(FindAllOf("BPW_MainMenu_C") or {}) do
        if valid(menu) and fullname(menu):find("Transient.GameEngine", 1, true) then
            return menu
        end
    end
end
local function set_visible(widget, visible)
    if valid(widget) then
        -- Unreal ESlateVisibility: Visible=0, Collapsed=1.
        widget:SetVisibility(visible and 0 or 1)
    end
end
local function set_text(widget, value)
    if not valid(widget) then return false end
    local new_text = FText(value)
    -- The game's WBP_MainMenuButton binds its TextBlock to ButtonText.
    -- Setting the raw TextBlock alone is overwritten on the next UMG update.
    widget.ButtonText = new_text
    local text = find_child(widget, "TextBlock", "Button_Text")
    if valid(text) then text:SetText(new_text) end
    return valid(text)
end
local function add_button(box, world, controller, label, key, visible)
    local widget = widget_lib:Create(world, button_class, controller)
    if not valid(widget) then return end
    set_text(widget, label)
    box:AddChildToVerticalBox(widget)
    set_visible(widget, visible)
    controls[key] = { widget=widget, label=label }
    return widget
end

local command_sequence = 0
local function send(command)
    if not io_dir or type(command) ~= "string" then return false end
    -- Atomic queue prevents simultaneous roster/stage/ready actions overwriting
    -- command.txt, which previously lost host readiness during level travel.
    command_sequence = command_sequence + 1
    local base = string.format("%s\\command-%010d-%08d", io_dir,
        os.time(), command_sequence)
    local temp = base .. ".tmp"
    local final = base .. ".txt"
    local file, err = io.open(temp, "wb")
    if not file then
        log("Steam bridge IPC error: " .. tostring(err))
        return false
    end
    file:write(command)
    file:close()
    local moved, move_error = os.rename(temp, final)
    if not moved then
        os.remove(temp)
        log("Steam bridge IPC commit error: " .. tostring(move_error))
        return false
    end
    return true
end
local function read_text(file)
    local f=io.open(file,"rb")
    if not f then return "" end
    local ok,value=pcall(function()return f:read("*a")end)
    pcall(function()f:close()end)
    return ok and type(value)=="string" and value or ""
end
local function read_kv(file)
    local data={}
    for line in read_text(file):gmatch("[^\r\n]+")do
        local key,value=line:match("^(.-)\t(.*)$")
        if key then data[key]=value end
    end
    return data
end
local function read_lobbies()
    local list = {}
    if not io_dir then return list end
    local f = io.open(io_dir .. "\\lobbies.txt", "rb")
    if not f then return list end
    for line in f:lines() do
        local id, title, count, max, owner, owner_name, ready =
            line:match("^(%d+)\t([^\t]*)\t(%d+)\t(%d+)\t(%d+)\t([^\t]*)\t(%d+)$")
        if id and owner then
            list[#list + 1] = {
                id=id, title=title, count=count, max=max,
                owner=owner, owner_name=owner_name, ready=ready
            }
        end
    end
    f:close()
    return list
end

local function read_friends()
    local list = {}
    if not io_dir then return list end
    local f = io.open(io_dir .. "\\friends.txt", "rb")
    if not f then return list end
    for line in f:lines() do
        local id, name, online = line:match("^(%d+)\t([^\t]*)\t(%d+)$")
        if id then list[#list+1] = { id=id, name=name, online=tonumber(online) } end
    end
    f:close()
    return list
end

local function read_members()
    local list = {}
    if not io_dir then return list end
    local f = io.open(io_dir .. "\\members.txt", "rb")
    if not f then return list end
    for line in f:lines() do
        local id, name, host, self_user, phase =
            line:match("^(%d+)\t([^\t]*)\t([01])\t([01])\t([^\t]*)$")
        if id then
            list[#list+1] = {
                id=id, name=name, host=host=="1",
                self_user=self_user=="1", phase=phase
            }
        end
    end
    f:close()
    return list
end

-- Pure session-scoped decision: convert the vanilla hub once, never enter
-- a reload loop and never interrupt an active network session or an arena.
function Module.should_start_listen(lobby, world_name, standalone, now)
    local playable = type(world_name) == "string"
        and world_name:match("^World /Game/Arenas/[%w_/%-]+%.[%w_]+$")
        and not world_name:find("/MainMenu/", 1, true)
    local id = tostring(lobby or "")
    local key = playable and id .. "|" .. world_name or ""
    if not playable or id == "" or id == "0" or standalone ~= true then
        host_standalone_since = 0
        host_standalone_world = ""
        -- A different successful map permits one recovery on a future visit.
        if playable and standalone == false and auto_listen_world ~= key then
            auto_listen_world = nil
        end
        return false
    end
    if host_standalone_world ~= key then
        host_standalone_world = key
        host_standalone_since = now
    end
    if host_standalone_since == 0 then host_standalone_since = now end
    if auto_listen_world == key or now-host_standalone_since < 5
        or now-auto_listen_last_attempt < 5 then
        return false
    end
    auto_listen_last_attempt = now
    auto_listen_world = key
    return true
end

local function is_host_waiting()
    return current_state.role == "host" and current_state.lobby
        and current_state.lobby ~= "0"
end

local function refresh_friend_buttons()
    local friends = read_friends()
    local show = ui_open and is_host_waiting()
    local invite_show = show and invite_mode
    local guest_busy = current_state.role == "guest"
        or current_state.status == "joining"
    for n=1,4 do
        local entry = controls["friend"..n]
        if entry then
            entry.friend = friends[friend_offset+n]
            if entry.friend then
                local label = entry.friend.name
                if entry.friend.online == 0 then label = label..L.t(" (offline)") end
                set_text(entry.widget, L.t("INVITE: ")..label)
            end
            set_visible(entry.widget, invite_show and entry.friend ~= nil)
        end
    end
    if controls.morefriends then
        set_visible(controls.morefriends.widget, invite_show and #friends > 4)
    end
    if controls.refresh then
        set_visible(controls.refresh.widget, ui_open and not show)
    end
    if controls.morelobbies then
        set_visible(controls.morelobbies.widget, ui_open and not show
            and not guest_busy and #read_lobbies() > 4)
    end
    for n=1,4 do
        local entry = controls["room"..n]
        if entry then set_visible(entry.widget,
            ui_open and not show and not guest_busy and entry.room ~= nil) end
    end
    if controls.host then
        set_text(controls.host.widget, show and L.t("START GAME") or L.t("CREATE LOBBY"))
        set_visible(controls.host.widget, ui_open and not guest_busy and not invite_mode)
    end
    if controls.invites then
        set_text(controls.invites.widget,
            invite_mode and L.t("BACK TO PLAYERS") or L.t("INVITE FRIEND"))
        set_visible(controls.invites.widget, show)
    end
    if controls.back then
        set_text(controls.back.widget,
            (is_host_waiting() or current_state.role=="guest")
            and not invite_mode and L.t("LEAVE LOBBY") or L.t("BACK"))
    end
end

-- Unreal game code can use console travel rather than GameplayStatics.OpenLevel.
-- The previous hook alone cannot detect those portal transitions.
function Module.should_pause_on_world_change(lobby, old_world, new_world, host_ready)
    local id=tostring(lobby or "")
    return id ~= "" and id ~= "0" and old_world ~= ""
        and type(new_world) == "string" and new_world ~= ""
        and new_world ~= old_world and host_ready == "true"
end

function Module.should_follow_host_epoch(epoch, last_epoch, status, host_ready, p2p_ready)
    local current=tonumber(epoch) or 0
    local last=tonumber(last_epoch) or 0
    local connected_before = last > 0
    local eligible = status == "playing"
        or (connected_before and
            (status == "disconnected" or status == "waiting_host"))
    return eligible and current > 0 and current > last
        and host_ready == "true" and p2p_ready == "true"
end

local function refresh_members()
    local people = read_members()
    local in_room = is_host_waiting() or current_state.role == "guest"
    local phase = current_state.session_stage or "lobby"
    local names = { lobby=L.t("LOBBY"), loading=L.t("LOADING"), hub=L.t("HUB"), run=L.t("RUN") }
    local stage = names[phase] or L.t("LOBBY")
    if controls.roster then
        set_text(controls.roster.widget,
            L.t("PLAYERS: ") .. #people .. "/4 · " .. stage)
        set_visible(controls.roster.widget, ui_open and in_room and not invite_mode)
    end
    for n=1,4 do
        local entry = controls["member"..n]
        if entry then
            local person = people[n]
            entry.person = person
            if person then
                local prefix = person.host and L.t("HOST: ")
                    or (is_host_waiting() and not person.self_user
                        and L.t("KICK: ") or L.t("PLAYER: "))
                local state = person.phase=="playing" and L.t(" [IN GAME]") or ""
                set_text(entry.widget, prefix .. person.name .. state)
            end
            set_visible(entry.widget, ui_open and in_room and not invite_mode
                and person ~= nil)
        end
    end
end

local function set_submenu(open)
    ui_open = open
    if not open then invite_mode = false end
    for _, w in ipairs(base_widgets) do
        set_visible(w, not open)
    end
    if controls.entry then set_visible(controls.entry.widget, not open) end
    for key, info in pairs(controls) do
        if key ~= "entry" then
            set_visible(info.widget, open and key ~= "invite_dialog"
                and not key:find("^room") and not key:find("^friend")
                and not key:find("^member") and key ~= "roster"
                and key ~= "invites" and key ~= "morefriends" and key ~= "morelobbies")
        end
    end
    refresh_friend_buttons()
    refresh_members()
end

local function handle_click(key)
    if key == "entry" then
        set_submenu(true)
        room_offset = 0
        if current_state.role ~= "guest" and not is_host_waiting() then
            send("list")
        end
    elseif key == "back" then
        if invite_mode then
            invite_mode = false
            refresh_friend_buttons()
            refresh_members()
            return
        end
        local role = current_state.role
        if role == "guest" or role == "host"
            or current_state.status == "joining" then
            send("leave")
            active_lobby_id = nil
            handled_lobby_id = nil
            active_join_epoch = 0
            patch_requested = false
        end
        set_submenu(false)
    elseif key == "host" then
        if is_host_waiting() then
            set_submenu(false)
            pending_host_start = true
            callbacks.host()
        else
            friend_offset=0
            if send("create|p2p|RotM Coop") then
                set_text(controls.host.widget, L.t("CREATING STEAM LOBBY..."))
            end
        end
    elseif key == "invites" then
        if is_host_waiting() then
            invite_mode = not invite_mode
            refresh_friend_buttons()
            refresh_members()
        end
    elseif key:find("^member") then
        local entry = controls[key]
        if is_host_waiting() and entry and entry.person
            and not entry.person.host and not entry.person.self_user then
            send("kick|" .. entry.person.id)
            set_text(entry.widget, L.t("REMOVING PLAYER..."))
        end
    elseif key == "morefriends" then
        local friends=read_friends()
        friend_offset = friend_offset + 4
        if friend_offset >= #friends then friend_offset = 0 end
        refresh_friend_buttons()
    elseif key:find("^friend") then
        local entry = controls[key]
        if entry and entry.friend then
            send("invite|"..entry.friend.id)
            set_text(entry.widget, L.t("INVITE SENT"))
        end
    elseif key == "refresh" then
        if current_state.role ~= "guest" and
            current_state.status ~= "joining" then
            room_offset = 0
            send("list")
        end
    elseif key == "morelobbies" then
        local rooms = read_lobbies()
        room_offset = room_offset + 4
        if room_offset >= #rooms then room_offset = 0 end
        if controls.refresh then set_text(controls.refresh.widget, L.t("SEARCHING LOBBIES...")) end
    elseif key:find("^room") then
        local entry = controls[key]
        if current_state.role ~= "guest" and entry and entry.room then
            active_lobby_id = entry.room.id
            handled_lobby_id = nil
            patch_requested = false
            send("join|" .. active_lobby_id)
            set_text(entry.widget, L.t("CONNECTING..."))
        end
    end
end

local function update_menu()
    local menu = get_menu()
    if not valid(menu) then
        active_menu = nil
        controls = {}
        base_widgets = {}
        ui_open = false
        return
    end
    if valid(active_menu) and same(menu, active_menu) then return end
    active_menu = menu
    controls = {}
    base_widgets = {}
    ui_open = false

    if not valid(widget_lib) then
        widget_lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    end
    if not valid(button_class) then
        button_class = StaticFindObject("/Game/Gameplay/UI/Controls/WBP_MainMenuButton.WBP_MainMenuButton_C")
    end
    local box = find_child(menu, "VerticalBox", "VerticalBox")
    local world = callbacks.current_world()
    local statics = UEHelpers.GetGameplayStatics()
    local controller = valid(world) and valid(statics) and statics:GetPlayerController(world, 0)
    if not (valid(box) and valid(controller) and valid(button_class) and valid(widget_lib)) then
        log("Steam menu: waiting for UMG assets and local controller")
        active_menu = nil
        return
    end
    local initial_count = box:GetChildrenCount()
    for n = 0, initial_count - 1 do
        local item = box:GetChildAt(n)
        if valid(item) then base_widgets[#base_widgets + 1] = item end
    end
    add_button(box, world, controller, L.t("CO-OP"), "entry", true)
    add_button(box, world, controller, L.t("CREATE LOBBY"), "host", false)
    add_button(box, world, controller, L.t("PLAYERS: 0/4"), "roster", false)
    for n=1,4 do
        add_button(box, world, controller, L.t("PLAYER #") .. n, "member" .. n, false)
    end
    add_button(box, world, controller, L.t("FIND LOBBY"), "refresh", false)
    for n = 1, 4 do
        add_button(box, world, controller, L.t("LOBBY #") .. n, "room" .. n, false)
    end
    add_button(box, world, controller, L.t("MORE LOBBIES"), "morelobbies", false)
    for n = 1, 4 do
        add_button(box, world, controller, L.t("FRIEND #") .. n, "friend" .. n, false)
    end
    add_button(box, world, controller, L.t("MORE FRIENDS"), "morefriends", false)
    add_button(box, world, controller, L.t("INVITE FRIEND"), "invites", false)
    add_button(box, world, controller, L.t("BACK"), "back", false)
    log("Steam Co-op integrated into native main menu")
end

local function update_status()
    if not io_dir then return end
    if cfg.steam_ui_qa == true then
        local test_path = io_dir .. "\\qa-ui-action.txt"
        local test = io.open(test_path, "rb")
        if test then
            local action = test:read("*l")
            test:close()
            os.remove(test_path)
            local widget = action and controls[action]
            if widget and valid(widget.widget) then
                widget.widget:Pressed()
                log("QA native UMG pressed: " .. action)
            else
                log("QA native UMG button not ready: " .. tostring(action))
            end
        end
    end
    local state = read_kv(io_dir .. "\\state.txt")
    current_state = state
    local status = state.status or "initializing"
    -- Steam may join through an invite or a direct joined-lobby callback.
    -- Both paths must trigger exactly one native Unreal login.
    if status == "joined" and state.lobby and state.lobby ~= "0"
        and state.lobby ~= handled_lobby_id
        and (not active_lobby_id or active_lobby_id == "") then
        active_lobby_id = state.lobby
        patch_requested = false
    end
    if is_host_waiting() then
        if previous_host_world_lobby ~= tostring(state.lobby or "") then
            previous_host_world_lobby = tostring(state.lobby or "")
            previous_host_world = ""
        end
        local world=callbacks.current_world()
        local sys=UEHelpers.GetKismetSystemLibrary()
        if valid(world) and valid(sys) and sys:IsServer(world)
            and not sys:IsStandalone(world) then
            local world_name=fullname(world)
            local current_is_game = world_name:find("/Game/Arenas/", 1, true)
                and not world_name:find("/MainMenu/", 1, true)
            if Module.should_pause_on_world_change(state.lobby,
                previous_host_world, world_name, state.host_ready) then
                waiting_for_new_map = true
                departing_map = previous_host_world
                travel_started = os.time()
                send("busy")
                log("Unreal world changed without relying on OpenLevel hook; pausing lobby")
            end
            if current_is_game then
                previous_host_world = world_name
            elseif previous_host_world ~= "" and state.host_ready == "true" then
                send("busy")
                previous_host_world = ""
            end
        end
    else
        previous_host_world = ""
        previous_host_world_lobby = ""
    end
    if is_host_waiting() and state.host_ready ~= "true" then
        local world=callbacks.current_world()
        if valid(world) then
            local sys=UEHelpers.GetKismetSystemLibrary()
            local now=os.time()
            local map_name=world:GetFullName()
            -- The original single-player Play flow can enter the hub as NM_Standalone.
            -- There is a live mage but no IpNetDriver/UDP listen socket; guests
            -- therefore wait forever, even though Steam P2P itself is active.
            -- Convert the loaded hub to a listen server exactly once per lobby.
            local standalone = valid(sys) and sys:IsStandalone(world)
            if Module.should_start_listen(state.lobby, map_name, standalone, now)
                and type(callbacks.host_current) == "function" then
                -- Native portal travel can bypass Blueprint OpenLevel hooks.
                -- Reopen the actual destination, not the initial hub.
                waiting_for_new_map = true
                departing_map = previous_host_world
                travel_started = now
                send("busy")
                log("Steam host in standalone destination: restarting once with ?listen: " .. map_name)
                callbacks.host_current()
                return
            end
            if valid(sys) and sys:IsServer(world)
                and map_name:find("/Game/Arenas/", 1, true)
                and not sys:IsStandalone(world) then
                -- During hard OpenLevel the old UWorld can remain visible briefly.
                local is_new_map = not waiting_for_new_map
                    or map_name ~= departing_map
                    or (now-travel_started >= 12 and
                        not map_name:find("MainMenu", 1, true))
                if is_new_map and now-travel_started >= 4
                    and now-last_ready_signal >= 5 then
                    last_ready_signal=now
                    if send("ready") then waiting_for_new_map = false end
                end
            end
        end
    end
    -- Lobby stage is a real game-world fact, not the Steam room's ready flag.
    -- This is independent of the host's original Play button and survives
    -- portal transitions when the game's main menu has been destroyed.
    if is_host_waiting() then
        local world = callbacks.current_world()
        local sys = UEHelpers.GetKismetSystemLibrary()
        if valid(world) and valid(sys) and sys:IsServer(world)
            and not sys:IsStandalone(world) then
            local path = fullname(world)
            local stage
            if path:find("/Game/Arenas/MageHub_New/", 1, true) then
                stage = "hub"
            elseif path:find("/Game/Arenas/", 1, true)
                and not path:find("/MainMenu/", 1, true) then
                stage = "run"
            end
            if stage and (stage ~= previous_host_stage
                or previous_stage_lobby ~= state.lobby
                or state.session_stage ~= stage)
                and (not waiting_for_new_map or path ~= departing_map) then
                if send("stage|" .. stage) then
                    previous_host_stage = stage
                    previous_stage_lobby = state.lobby
                end
            end
        end
    end

    -- A hard OpenLevel creates a new Unreal listen server. Steam keeps the
    -- same lobby but increments its game epoch once the server is listening.
    -- The guest must join each new epoch even if their old world did not
    -- immediately fall back to the main menu.
    if state.role == "guest" and
        Module.should_follow_host_epoch(state.game_epoch, active_join_epoch,
            status, state.remote_ready, state.p2p_verified) then
        local epoch = tonumber(state.game_epoch) or 0
        local endpoint = state.endpoint or ""
        if endpoint:match("^127%.0%.0%.1:%d+$") then
            active_join_epoch = epoch
            log("Host map epoch changed; following host into next arena")
            callbacks.join(endpoint)
        end
    end
    if ui_open then
        refresh_friend_buttons()
        refresh_members()
    end
    local error_message = state.error or ""
    if status ~= last_status then
        last_status = status
        log("Steam lobby status: " .. status ..
            (error_message ~= "" and (" (" .. error_message .. ")") or ""))
    end
    if controls.refresh and ui_open and not is_host_waiting() then
        if status == "listed" then
            local rooms = read_lobbies()
            local friend_ids = {}
            for _, f in ipairs(read_friends()) do friend_ids[f.id] = true end
            table.sort(rooms, function(a,b)
                local friend_a = friend_ids[a.owner] and 1 or 0
                local friend_b = friend_ids[b.owner] and 1 or 0
                if friend_a ~= friend_b then return friend_a > friend_b end
                if a.ready ~= b.ready then return a.ready > b.ready end
                return a.title < b.title
            end)
            set_text(controls.refresh.widget, L.t("FIND LOBBY (") .. #rooms .. ")")
            for n=1,4 do
                local info = controls["room"..n]
                if info then
                    local room = rooms[room_offset+n]
                    info.room = room
                    if room then
                        local stage = room.ready == "1" and L.t("IN GAME") or L.t("IN LOBBY")
                        set_text(info.widget, room.owner_name .. ": " ..
                            room.title .. " (" .. room.count .. "/" .. room.max .. ") " .. stage)
                    end
                    set_visible(info.widget, room ~= nil)
                end
            end
        elseif status == "searching" then
            set_text(controls.refresh.widget, L.t("SEARCHING LOBBIES..."))
        elseif status == "error" then
            set_text(controls.refresh.widget, L.t("STEAM ERROR / RETRY"))
        end
    end
    if controls.refresh and ui_open and
        (state.role == "guest" or status == "joining" or status == "kicked") then
        local messages = {
            joining = L.t("JOINING STEAM LOBBY..."),
            waiting_host = L.t("WAITING FOR HOST..."),
            waiting_p2p = L.t("CHECKING STEAM P2P..."),
            joined = L.t("PREPARING CO-OP..."),
            patched = L.t("PREPARING CHARACTER..."),
            connecting_game = L.t("ENTERING WORLD..."),
            playing = L.t("CONNECTED"),
            host_offline = L.t("HOST NOT RESPONDING"),
            kicked = L.t("REMOVED FROM LOBBY"),
            host_unavailable = L.t("HOST NOT READY"),
            game_no_response = L.t("GAME SERVER NOT RESPONDING"),
            game_login_timeout = L.t("CHARACTER LOAD ERROR"),
            disconnected = L.t("CONNECTION LOST"),
            error = L.t("CO-OP ERROR"),
        }
        set_text(controls.refresh.widget, messages[status] or L.t("CONNECTING..."))
    end
    if status == "joined" and state.lobby and state.lobby == active_lobby_id
        and not patch_requested then
        patch_requested = true
        send("patch")
    elseif status == "patched" and state.lobby and state.lobby == active_lobby_id then
        local endpoint = state.endpoint or ""
        if endpoint:match("^%d+%.%d+%.%d+%.%d+:%d+$") then
            handled_lobby_id = active_lobby_id
            active_lobby_id = nil
            patch_requested = false
            active_join_epoch = tonumber(state.game_epoch) or 0
            callbacks.join(endpoint)
        end
    end
end

local function start_bridge()
    if bridge_started then return end
    bridge_started = true
    local source = debug.getinfo(1, "S").source
    local source_path = source:sub(1,1) == "@" and source:sub(2) or source
    local dir = source_path:match("^(.*)[/\\]")
    if not dir then
        log("Steam bridge path unavailable")
        return
    end
    io_dir = dir .. "\\steam-ipc"
    local bridge = dir .. "\\RotMSteamBridge.exe"
    local f = io.open(bridge, "rb")
    if not f then
        log("RotMSteamBridge.exe is missing; install the Steam 480 mod bundle")
        return
    end
    f:close()
    os.execute('cmd /d /c if not exist "' .. io_dir .. '" mkdir "' .. io_dir .. '"')
    os.remove(io_dir .. "\\state.txt")
    local vbs = io_dir .. "\\start_bridge.vbs"
    local script = io.open(vbs, "wb")
    if script then
        local command = '"' .. bridge .. '" --serve "' .. io_dir .. '"'
        local escaped = command:gsub('"', '""')
        script:write('CreateObject("WScript.Shell").Run "' .. escaped .. '", 0, False\r\n')
        script:close()
        os.execute('wscript.exe //B //Nologo "' .. vbs .. '"')
        log("Steam 480 matchmaking bridge started")
    end
end

-- The Unreal client has actually started a connection attempt via localhost.
-- Distinguish Steam control-handshake success from a real Unreal server login.
function Module.send_party(command)
    return send(command)
end
function Module.read_party(file)
    if not io_dir or not file:match("^[%w%-]+%.txt$")then return "" end
    return read_text(io_dir .. "\\" .. file)
end
function Module.profiles()
    local lines={}
    for line in Module.read_party("profiles.txt"):gmatch("[^\r\n]+")do lines[#lines+1]=line end
    return lines
end
function Module.is_party_active()
    return current_state.role=="host" or current_state.role=="guest"
end
local last_complete_state=nil
function Module.get_state()
    if not io_dir then return current_state end
    local data=read_kv(io_dir .. "\\state.txt")
    if data.ready=="1" and data.game_epoch and data.role and data.lobby and data.status then
        last_complete_state=data
        return data
    end
    return last_complete_state or current_state
end

function Module.mark_client_connecting()
    if current_state.role == "guest" then
        send("game_start")
    end
end

function Module.mark_client_ready()
    if current_state.role == "guest" then
        send("game_ready")
    end
end

function Module.mark_client_disconnected()
    if current_state.role == "guest" then
        send("game_disconnected")
    end
end

-- Called by the authoritative host's OpenLevel hook before leaving the map.
-- Do not let reconnecting guests attach to the old, shutting-down UWorld.
function Module.mark_host_travel(destination)
    if not is_host_waiting() then return end
    local world=callbacks and callbacks.current_world()
    departing_map=fullname(world)
    waiting_for_new_map=true
    travel_started=os.time()
    if send("busy") then
        log("Steam lobby paused for map travel: "..tostring(destination))
    end
end

function Module.can_reconnect()
    if not cfg or cfg.steam_lobbies_enabled ~= true then return true end
    local failed = {
        game_no_response = true, game_login_timeout = true,
        host_offline = true, host_unavailable = true
    }
    return current_state.role == "guest"
        and current_state.remote_ready == "true"
        and current_state.p2p_verified == "true"
        and not failed[current_state.status]
end

function Module.install(config, deps)
    cfg = config
    callbacks = deps
    log = deps.log
    if cfg.steam_lobbies_enabled ~= true then
        log("Steam matchmaking is disabled in this profile")
        return Module
    end
    -- The game's custom button blueprint is not loaded at module startup;
    -- resolve it lazily once the main menu creates its UMG widgets.
    widget_lib = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local ok, err = pcall(RegisterHook,
        "/Script/RevengeOfTheMage.W_MainButton:Pressed",
        function(context)
            local pressed = context:get()
            for key, info in pairs(controls) do
                if same(pressed, info.widget) then
                    ExecuteInGameThreadWithDelay(50,function()
                        local safe, error_message=pcall(handle_click,key)
                        if not safe then log("Steam button error: " .. tostring(error_message)) end
                    end)
                    break
                end
            end
        end)
    if not ok then
        log("Steam main-menu button event hook failed: " .. tostring(err))
        return Module
    end
    if cfg.steam_ui_qa == true then
        -- Isolated automated tests only: trigger the exact native Blueprint Pressed
        -- event rather than bypassing the UI event hook.
        function Module.qa_press(key)
            local info = controls[key]
            if not info or not valid(info.widget) then return false end
            info.widget:Pressed()
            return true
        end
    end
    local update_pending=false
    local LoopAsync=deps.every or LoopAsync
    local ExecuteInGameThread=deps.every and function(fn) fn() end or ExecuteInGameThread
    LoopAsync(1000,function()
        if not update_pending then
            update_pending=true
            ExecuteInGameThread(function()
                local ok2,err2=pcall(function()
                    if not bridge_started then start_bridge() end
                    if io_dir then
                        local f=io.open(io_dir .. "\\heartbeat.txt","wb")
                        if f then f:write(tostring(os.time()));f:close()end
                    end
                    update_menu()
                    update_status()
                end)
                update_pending=false
                if not ok2 then log("Steam menu update error: " .. tostring(err2)) end
            end)
        end
        return false
    end)
    log("Steam matchmaking UMG hooks installed")
    return Module
end

return Module
