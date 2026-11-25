return {
    -- Set the host's LAN or VPN IPv4 address and UDP port here.
    join_address = "127.0.0.1:7777",

    -- Start the host executable with -port=7777 to set the game port.
    -- For a diagnostic control run, host with stock Unreal GameModeBase.
    diagnostic_engine_game_mode = false,

    -- Set auto_action to "host" or "join" only for unattended tests.
    auto_action = nil,
    auto_map = "/Game/Arenas/MageHub_New/MageHub_New",
    auto_delay_ms = 8000,

    -- Retry after Unreal disconnects the guest during non-seamless map travel.
    -- Limited to avoid an infinite loop when the host is offline.
    auto_reconnect = true,
    max_reconnect_attempts = 5,
    reconnect_interval_seconds = 25,

    -- Steam Spacewar (480) test lobby browser. Matchmaking only:
    -- Unreal UDP still requires a reachable host address (Tailscale recommended).
    steam_lobbies_enabled = true,
    steam_ui_qa = false,
    network_motion_tuning = true,
}
