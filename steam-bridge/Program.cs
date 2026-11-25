using System.Diagnostics;
using RotMCoopLauncher;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;

namespace RotMSteamBridge;

internal sealed class Bridge : IDisposable
{
    private const string LobbyTag = "rotm-coop-2026-test";
    private const string TransportVersion = "steam-p2p-v2";
    private readonly IntPtr matchmaking;
    private readonly IntPtr friends;
    private readonly ulong localSteamId;
    private readonly SteamP2PTunnel tunnel;
    private readonly int pipe;
    private readonly string? ipc;
    private readonly bool smoke;
    private ulong pending;
    private int pendingCallback;
    private ulong lobby;
    private ulong joinedLobby;
    private ulong pendingJoinLobby;
    private string pendingEndpoint = "";
    private string pendingTitle = "";
    private bool gameHostReady;
    private bool remoteHostReady;
    private uint gameEpoch;
    private ulong inviteRequested;
    private readonly List<string> friendList = new();
    private readonly HashSet<ulong> friendLobbyIds = new();
    private readonly HashSet<ulong> kickedMembers = new();
    private readonly List<string> members = new();
    private readonly List<string> profiles = new();
    private readonly List<string> choices = new();
    private string partyDrafts = "";
    private string partyDowned = "";
    private string partyVisuals = "";
    private readonly Queue<string> castEvents = new();
    private bool castDirty;
    private string ammoSnapshot = "";
    private uint ammoEpoch, ammoSequence;
    private bool ammoDirty;
    private DateTime lastAmmoWrite = DateTime.MinValue;
    private DateTime lastCastWrite = DateTime.MinValue;
    private readonly CombatEvents combat = new();
    private DateTime lastCombatWrite = DateTime.MinValue;
    private NativeGuards.PartyHandle? partyGuard;
    private DateTime lastRosterRefresh = DateTime.MinValue;
    private string hostStage = "lobby";
    private string remoteStage = "lobby";
    private DateTime lastLobbyRefresh = DateTime.MinValue;
    private string status = "ready";
    private string error = "";
    private List<string> lobbyList = new();
    private DateTime lastStatus = DateTime.MinValue;
    private bool running = true;
    private bool created;
    private bool guestPatched;
    private bool joinedFromInvite;
    private ulong queuedInvitationLobby;
    private readonly Process? watchedGameProcess;
    private readonly bool watchGameProcess;
    private DateTime guestFirstDatagramAt = DateTime.MinValue;
    private bool guestTransportTimedOut;
    private DateTime steamJoinStartedAt = DateTime.MinValue;
    private DateTime unrealLoginStartedAt = DateTime.MinValue;
    private ulong baselineReceivedAtLogin;
    private bool guestHasPossessedPawn;
    private DateTime lastHostUdpHealthAt = DateTime.MinValue;
    private int hostUdpMisses;

    public Bridge(string? ipcDir, bool smokeTest)
    {
        ipc = ipcDir;
        smoke = smokeTest;
        (watchedGameProcess, watchGameProcess) = BindToGameProcess(ipcDir);

        Environment.SetEnvironmentVariable("SteamAppId", "480");
        Environment.SetEnvironmentVariable("SteamGameId", "480");
        byte[] err = new byte[1024];
        int init = SteamNative.SteamAPI_InitFlat(err);
        if (init != 0)
            throw new InvalidOperationException("SteamAPI_InitFlat=" + init + " " + SteamNative.InitError(err));
        matchmaking = SteamNative.SteamAPI_SteamMatchmaking_v009();
        if (matchmaking == IntPtr.Zero)
            throw new InvalidOperationException("Steam matchmaking interface is unavailable.");
        friends = SteamNative.SteamAPI_SteamFriends_v017();
        localSteamId = SteamNative.SteamAPI_ISteamUser_GetSteamID(SteamNative.SteamAPI_SteamUser_v023());
        if (friends == IntPtr.Zero || localSteamId == 0)
            throw new InvalidOperationException("Steam friends/user interface is unavailable");
        tunnel = new SteamP2PTunnel(IsAllowedPeer, message => Console.WriteLine(message));
        tunnel.VisualReceived = ReceiveVisual;
        tunnel.CombatReceived = ReceiveCombat;
        SteamNative.SteamAPI_ManualDispatch_Init();
        pipe = SteamNative.SteamAPI_GetHSteamPipe();
        if (pipe == 0) throw new InvalidOperationException("No Steam API pipe.");
        Console.WriteLine("STEAM_480_READY pipe=" + pipe);
        if (ipc != null)
        {
            Directory.CreateDirectory(ipc);
            AtomicWrite(Path.Combine(ipc, "party-casts.txt"), "");
            AtomicWrite(Path.Combine(ipc, "party-ammo.txt"), "");
            WriteStatus();
        }
    }

    // The bridge was started by the Unreal Lua mod. Watch that exact game
    // executable, not the wscript parent (which exits immediately). This makes
    // process lifetime deterministic even when the game crashes or is killed.
    private static (Process?, bool) BindToGameProcess(string? directory)
    {
        if (string.IsNullOrWhiteSpace(directory)) return (null, false);
        string executable;
        try
        {
            executable = Path.GetFullPath(Path.Combine(directory,
                "..", "..", "..", "..", "..", "RevengeOfTheMage-Win64-Shipping.exe"));
        }
        catch { return (null, false); }
        if (!File.Exists(executable)) return (null, false);
        Process? selected = null;
        foreach (var candidate in Process.GetProcessesByName("RevengeOfTheMage-Win64-Shipping"))
        {
            try
            {
                if (!Path.GetFullPath(candidate.MainModule?.FileName ?? "").Equals(
                    executable, StringComparison.OrdinalIgnoreCase))
                { candidate.Dispose(); continue; }
                if (selected == null || candidate.StartTime > selected.StartTime)
                { selected?.Dispose(); selected = candidate; }
                else candidate.Dispose();
            }
            catch { candidate.Dispose(); }
        }
        Console.WriteLine("GAME_PROCESS_WATCH " +
            (selected == null ? "missing; ending instead of orphaning" : "active"));
        return (selected, true);
    }

    private static string Safe(string? value) =>
        (value ?? "").Replace("\t", " ").Replace("\r", " ").Replace("\n", " ").Replace("|", "/").Trim();

    private void SetStatus(string value, string? message = null)
    {
        status = value;
        error = message == null ? "" : Safe(message);
        WriteStatus();
        Console.WriteLine("STATE " + status + " " + error);
    }

    private void WriteStatus()
    {
        if (ipc == null) return;
        lastStatus = DateTime.UtcNow;
        string[] lines =
        [
            "ready\t1",
            "appid\t480",
            "party_supported\t" + (partyGuard != null ? "true" : "false"),
            "party_guard\t" + (partyGuard?.Active == true ? "true" : "false"),
            "status\t" + Safe(status),
            "error\t" + Safe(error),
            "lobby\t" + (lobby == 0 ? joinedLobby : lobby),
            "endpoint\t" + Safe(pendingEndpoint),
            "name\t" + Safe(SteamNative.Utf8(SteamNative.SteamAPI_ISteamFriends_GetPersonaName(friends))),
            "count\t" + lobbyList.Count,
            "member_count\t" + members.Count,
            "member_max\t4",
            "session_stage\t" + Safe(lobby != 0 ? hostStage : remoteStage),
            "transport\tsteam-p2p-relay",
            "local_port\t" + tunnel.LocalPort,
            "peers\t" + tunnel.PeerCount,
            "p2p_out\t" + tunnel.Outgoing,
            "p2p_in\t" + tunnel.Incoming,
            "p2p_dropped\t" + tunnel.Dropped,
            "relay\t" + tunnel.GuestRelay,
            "p2p_state\t" + tunnel.GuestP2PState,
            "p2p_verified\t" + (tunnel.P2PReady ? "true" : "false"),
            "p2p_control_out\t" + tunnel.ControlSent,
            "p2p_control_in\t" + tunnel.ControlReceived,
            "p2p_frame_queue\t" + tunnel.PendingFrames,
            "p2p_fast_queue\t" + tunnel.PendingMovementFrames,
            "p2p_bulk_queue\t" + tunnel.PendingBulkFrames,
            "verified_peers\t" + tunnel.VerifiedPeers,
            "pending_p2p_sessions\t" + tunnel.PendingSessionRequests,
            "host_udp_port\t" + (tunnel.Hosting ? tunnel.HostGamePort.ToString() : "0"),
            "host_udp_ready\t" + (gameHostReady ? "true" : "false"),
            "invite_join\t" + (joinedFromInvite ? "true" : "false"),
            "role\t" + (tunnel.Hosting ? "host" : tunnel.Guest ? "guest" : "none"),
            "host_ready\t" + (gameHostReady ? "true" : "false"),
            "remote_ready\t" + (remoteHostReady ? "true" : "false"),
            "game_epoch\t" + gameEpoch,
            "client_game_ready\t" + (guestHasPossessedPawn ? "true" : "false"),
            "client_login_seconds\t" + (unrealLoginStartedAt == DateTime.MinValue ? "0" :
                Math.Max(0, (int)(DateTime.UtcNow - unrealLoginStartedAt).TotalSeconds).ToString())
        ];
        // Lua and external status viewers may hold short-lived Windows file
        // handles. A sharing violation must NEVER terminate the Steam lobby.
        try
        {
            AtomicWrite(Path.Combine(ipc, "state.txt"), string.Join("\n", lines) + "\n");
            AtomicWrite(Path.Combine(ipc, "lobbies.txt"), string.Join("\n", lobbyList) + "\n");
            AtomicWrite(Path.Combine(ipc, "friends.txt"), string.Join("\n", friendList) + "\n");
            AtomicWrite(Path.Combine(ipc, "members.txt"), string.Join("\n", members) + "\n");
            AtomicWrite(Path.Combine(ipc, "profiles.txt"), string.Join("\n", profiles) + "\n");
            AtomicWrite(Path.Combine(ipc, "party-cards.txt"), partyDrafts);
            AtomicWrite(Path.Combine(ipc, "party-downed.txt"), partyDowned);
            AtomicWrite(Path.Combine(ipc, "party-visuals.txt"), partyVisuals);
            AtomicWrite(Path.Combine(ipc, "party-choices.txt"), string.Join("\n", choices) + "\n");
            lastStatus = DateTime.UtcNow;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Previous snapshot remains intact; retry on the next frame.
            if (DateTime.UtcNow - lastStatus > TimeSpan.FromSeconds(3))
                Console.WriteLine("IPC_STATUS_WRITE_RETRY " + ex.GetType().Name);
        }
    }

    private static void AtomicWrite(string target, string contents)
    {
        string temp = target + "." + Environment.ProcessId + ".new";
        File.WriteAllText(temp, contents, new UTF8Encoding(false));
        File.Move(temp, target, overwrite: true);
    }

    private bool IsAllowedPeer(ulong peer)
    {
        if (peer == 0 || peer == localSteamId || kickedMembers.Contains(peer)) return false;
        if (joinedLobby != 0 && !tunnel.Hosting)
            return peer == SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyOwner(matchmaking, joinedLobby);
        if (lobby == 0) return false;
        int count = SteamNative.SteamAPI_ISteamMatchmaking_GetNumLobbyMembers(matchmaking, lobby);
        for (int n = 0; n < count; ++n)
            if (SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex(matchmaking, lobby, n) == peer)
                return true;
        return false;
    }

    private void RefreshRoster()
    {
        members.Clear();
        profiles.Clear();
        choices.Clear();
        ulong activeLobby = lobby != 0 ? lobby : joinedLobby;
        if (activeLobby == 0) { partyDrafts = ""; partyDowned = ""; partyVisuals = ""; return; }
        if (joinedLobby != 0 && lobby == 0)
        {
            partyDrafts = ReadPartyLobby(activeLobby, "rotm_cards_v2");
            partyDowned = ReadPartyLobby(activeLobby, "rotm_downed_v2");
            partyVisuals = ReadPartyLobby(activeLobby, "rotm_visuals_v1");
        }
        ulong owner = SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyOwner(matchmaking, activeLobby);
        int count = Math.Clamp(
            SteamNative.SteamAPI_ISteamMatchmaking_GetNumLobbyMembers(matchmaking, activeLobby),
            0, 16);
        var ids = new List<ulong>(count);
        for (int i = 0; i < count; ++i)
        {
            ulong id = SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex(
                matchmaking, activeLobby, i);
            if (id != 0 && !kickedMembers.Contains(id) && !ids.Contains(id))
                ids.Add(id);
        }
        if (owner != 0 && !ids.Contains(owner)) ids.Insert(0, owner);
        foreach (ulong id in ids.OrderByDescending(x => x == owner).ThenBy(x => x))
        {
            string name = id == localSteamId
                ? Safe(SteamNative.Utf8(SteamNative.SteamAPI_ISteamFriends_GetPersonaName(friends)))
                : Safe(SteamNative.Utf8(SteamNative.SteamAPI_ISteamFriends_GetFriendPersonaName(
                    friends, id)));
            if (name.Length == 0)
            {
                SteamNative.SteamAPI_ISteamFriends_RequestUserInformation(friends, id, true);
                name = "Steam user";
            }
            string gameState = id == localSteamId
                ? (gameHostReady || guestHasPossessedPawn ? "playing" : "lobby")
                : Safe(SteamNative.Utf8(SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyMemberData(
                    matchmaking, activeLobby, id, "phase")));
            if (gameState.Length == 0) gameState = "lobby";
            string profile = SteamNative.Utf8(SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyMemberData(
                matchmaking, activeLobby, id, "rotm_profile_v1"));
            if (ValidProfile(profile.Split('|'), gameEpoch)) profiles.Add(id + "\t" + profile);
            string choice = SteamNative.Utf8(SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyMemberData(
                matchmaking, activeLobby, id, "rotm_choice_v2"));
            var cf = choice.Split('|');
            var pf = profile.Split('|');
            if (id != owner && ValidProfile(pf, gameEpoch) && cf.Length == 4
                && cf[0] == gameEpoch.ToString() && cf[2] == pf[1]
                && uint.TryParse(cf[1], out _) && int.TryParse(cf[3], out int pick) && pick is >= 1 and <= 3)
                choices.Add(id + "\t" + choice);
            members.Add(id + "\t" + name + "\t" + (id == owner ? "1" : "0") +
                "\t" + (id == localSteamId ? "1" : "0") + "\t" + gameState);
        }
    }

    private void SetMemberPhase(string phase)
    {
        ulong active = lobby != 0 ? lobby : joinedLobby;
        if (active != 0)
            SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyMemberData(
                matchmaking, active, "phase", phase);
    }

    public void KickMember(ulong memberId)
    {
        if (lobby == 0 || memberId == localSteamId || memberId == 0 ||
            SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyOwner(matchmaking, lobby) != localSteamId)
        {
            SetStatus("error", "Only the host can remove another lobby member.");
            return;
        }
        RefreshRoster();
        if (!members.Any(m => m.StartsWith(memberId + "\t", StringComparison.Ordinal)))
        {
            SetStatus("error", "The selected member is no longer in the lobby.");
            return;
        }
        byte[] message = Encoding.UTF8.GetBytes("RMC_KICK_V1|" + memberId);
        if (!SteamNative.SteamAPI_ISteamMatchmaking_SendLobbyChatMsg(
                matchmaking, lobby, message, message.Length))
        {
            SetStatus("error", "Steam refused the lobby removal notification.");
            return;
        }
        kickedMembers.Add(memberId);
        SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(
            matchmaking, lobby, "bans", string.Join(",", kickedMembers));
        RefreshRoster();
        SetStatus("hosting");
        Console.WriteLine("LOBBY_MEMBER_KICKED");
    }

    private void ReceiveLobbyChat(ulong activeLobby, int messageId)
    {
        if (activeLobby == 0 || activeLobby != joinedLobby || lobby != 0) return;
        var buffer = new byte[512];
        int count = SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyChatEntry(
            matchmaking, activeLobby, messageId, out ulong sender,
            buffer, buffer.Length, out int entryType);
        if (count <= 0 || count > buffer.Length ||
            sender != SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyOwner(matchmaking, activeLobby))
            return;
        string message = Encoding.UTF8.GetString(buffer, 0, count).TrimEnd('\0');
        if (message == "RMC_KICK_V1|" + localSteamId)
        {
            Leave();
            queuedInvitationLobby = 0;
            SetStatus("kicked", "You were removed from this Steam lobby by the host.");
            Console.WriteLine("STEAM_LOBBY_REMOVAL_RECEIVED");
        }
    }

    private void RefreshFriends()
    {
        int total = Math.Clamp(SteamNative.SteamAPI_ISteamFriends_GetFriendCount(friends, 0x04), 0, 2000);
        var rows = new List<(ulong Id, string Name, int Online)>();
        friendLobbyIds.Clear();
        for (int n = 0; n < total; ++n)
        {
            ulong id = SteamNative.SteamAPI_ISteamFriends_GetFriendByIndex(friends, n, 0x04);
            if (id == 0) continue;
            string name = Safe(SteamNative.Utf8(SteamNative.SteamAPI_ISteamFriends_GetFriendPersonaName(friends, id)));
            int online = SteamNative.SteamAPI_ISteamFriends_GetFriendPersonaState(friends, id);
            rows.Add((id, name, online));
            if (SteamNative.SteamAPI_ISteamFriends_GetFriendGamePlayed(friends, id, out var game)
                && game.GameID == 480 && game.LobbyID != 0)
            {
                friendLobbyIds.Add(game.LobbyID);
                SteamNative.SteamAPI_ISteamMatchmaking_RequestLobbyData(matchmaking, game.LobbyID);
            }
        }
        friendList.Clear();
        foreach (var f in rows.OrderByDescending(x => x.Online).ThenBy(x => x.Name).Take(40))
            friendList.Add(f.Id + "\t" + f.Name + "\t" + f.Online);
    }

    public void Invite(ulong friendSteamId)
    {
        if (lobby == 0) { SetStatus("error", "Create a lobby before inviting Steam friends."); return; }
        if (!friendList.Any(f => f.StartsWith(friendSteamId + "\t", StringComparison.Ordinal)))
        {
            RefreshFriends();
            if (!friendList.Any(f => f.StartsWith(friendSteamId + "\t", StringComparison.Ordinal)))
            {
                SetStatus("error", "Invited Steam account is not on your friends list.");
                return;
            }
        }
        if (!SteamNative.SteamAPI_ISteamMatchmaking_InviteUserToLobby(matchmaking, lobby, friendSteamId))
            SetStatus("error", "Steam could not send the Spacewar lobby invitation.");
        else
        {
            inviteRequested = friendSteamId;
            SetStatus("invited");
            Console.WriteLine("STEAM_FRIEND_INVITATION_SENT");
        }
    }

    public void ShowInviteDialog()
    {
        if (lobby == 0) return;
        SteamNative.SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog(friends, lobby);
    }

    private void AddLobby(ulong id)
    {
        if (id == 0 || id == lobby || id == joinedLobby ||
            lobbyList.Any(line => line.StartsWith(id + "\t", StringComparison.Ordinal)))
            return;
        // Steamworks GetLobbyOwner is member-only. Discovery must use public
        // lobby metadata instead; owner data here is display-only, never auth.
        ulong.TryParse(SteamNative.Utf8(
            SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyData(matchmaking, id, "host_id")), out ulong owner);
        if (owner != 0 && owner == localSteamId) return;
        string tag = SteamNative.Utf8(SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyData(matchmaking, id, "rotm"));
        string transport = SteamNative.Utf8(SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyData(matchmaking, id, "transport"));
        if (tag != LobbyTag || transport != TransportVersion) return;
        string name = SteamNative.Utf8(SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyData(matchmaking, id, "name"));
        int players = SteamNative.SteamAPI_ISteamMatchmaking_GetNumLobbyMembers(matchmaking, id);
        string ownerName = Safe(SteamNative.Utf8(
            SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyData(matchmaking, id, "host_name")));
        if (ownerName.Length == 0 && owner != 0)
            ownerName = Safe(SteamNative.Utf8(
                SteamNative.SteamAPI_ISteamFriends_GetFriendPersonaName(friends, owner)));
        if (ownerName.Length == 0) ownerName = "Steam";
        string ready = SteamNative.Utf8(
            SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyData(matchmaking, id, "ready"));
        lobbyList.Add(id + "\t" + Safe(name) + "\t" + players +
            "\t4\t" + owner + "\t" + ownerName + "\t" + (ready == "1" ? "1" : "0"));
    }

    // Never write live game instructions during engine startup. Lobby entry
    // happens after the local menu is fully initialized, before gameplay travel.
    private void EnsurePartyGuards()
    {
        if (partyGuard != null || watchedGameProcess == null || watchedGameProcess.HasExited) return;
        try
        {
            partyGuard = NativeGuards.InstallParty(watchedGameProcess.Id,
                watchedGameProcess.MainModule!.FileName);
            Console.WriteLine("PARTY_GUARDS_READY");
        }
        catch (Exception ex) { Console.WriteLine("PARTY_GUARDS_UNAVAILABLE " + ex.Message); }
    }

    public void Create(string endpoint, string title, bool privateForSmoke = false)
    {
        EnsurePartyGuards();
        if (joinedLobby != 0)
        {
            // Do not silently orphan a guest's Steam lobby while 'connecting'.
            WriteStatus();
            return;
        }
        if (pending != 0) { SetStatus("error", "Another lobby operation is pending."); return; }
        if (lobby != 0) SteamNative.SteamAPI_ISteamMatchmaking_LeaveLobby(matchmaking, lobby);
        lobby = 0;
        joinedLobby = 0;
        kickedMembers.Clear();
        hostStage = "lobby";
        remoteStage = "lobby";
        members.Clear();
        joinedFromInvite = false;
        pendingEndpoint = ""; // No external game endpoint is ever advertised.
        pendingTitle = Safe(title);
        gameHostReady = false;
        SetGameEpoch(0);
        pending = SteamNative.SteamAPI_ISteamMatchmaking_CreateLobby(matchmaking, privateForSmoke ? 0 : 2, 4);
        pendingCallback = 513;
        if (pending == 0) SetStatus("error", "Steam CreateLobby failed to start.");
        else SetStatus("creating");
    }

    public void List()
    {
        // Searching while a Steam lobby is active used to overwrite 'joined'
        // or 'connecting_game' with 'listed', leaving the in-game menu stuck.
        if (lobby != 0 || joinedLobby != 0)
        {
            WriteStatus();
            return;
        }
        if (pending != 0) return;
        RefreshFriends();
        SteamNative.SteamAPI_ISteamMatchmaking_AddRequestLobbyListStringFilter(matchmaking, "rotm", LobbyTag, 0);
        SteamNative.SteamAPI_ISteamMatchmaking_AddRequestLobbyListDistanceFilter(matchmaking, 3); // worldwide
        SteamNative.SteamAPI_ISteamMatchmaking_AddRequestLobbyListResultCountFilter(matchmaking, 100);
        pending = SteamNative.SteamAPI_ISteamMatchmaking_RequestLobbyList(matchmaking);
        pendingCallback = 510;
        if (pending == 0) SetStatus("error", "Steam RequestLobbyList failed to start.");
        else SetStatus("searching");
    }

    public void Join(ulong lobbyId)
    {
        EnsurePartyGuards();
        if (pending != 0) { SetStatus("error", "Another lobby operation is pending."); return; }
        if (lobby != 0 || joinedLobby != 0)
        {
            if (joinedLobby == lobbyId) return;
            SetStatus("error", "Leave the current Steam lobby before joining another.");
            return;
        }
        guestTransportTimedOut = false;
        guestHasPossessedPawn = false;
        steamJoinStartedAt = DateTime.UtcNow;
        unrealLoginStartedAt = DateTime.MinValue;
        pendingJoinLobby = lobbyId;
        pending = SteamNative.SteamAPI_ISteamMatchmaking_JoinLobby(matchmaking, lobbyId);
        pendingCallback = 504;
        if (pending == 0) SetStatus("error", "Steam JoinLobby failed to start.");
        else SetStatus("joining");
    }

    public void PatchGuestGame()
    {
        if (guestPatched)
        {
            SetStatus("patched");
            return;
        }
        string win64 = Path.GetFullPath(Path.Combine(AppContext.BaseDirectory,
            "..", "..", "..", ".."));
        string exe = Path.Combine(win64, "RevengeOfTheMage-Win64-Shipping.exe");
        if (!File.Exists(exe))
            throw new FileNotFoundException("Game not found relative to installed Steam bridge.", exe);

        var processes = Process.GetProcessesByName("RevengeOfTheMage-Win64-Shipping");
        var matching = new List<Process>();
        try
        {
            foreach (var proc in processes)
            {
                string? path = null;
                try { path = proc.MainModule?.FileName; } catch { }
                if (path != null && Path.GetFullPath(path).Equals(Path.GetFullPath(exe),
                    StringComparison.OrdinalIgnoreCase))
                    matching.Add(proc);
            }
            if (matching.Count != 1)
                throw new InvalidOperationException("Expected one running game process for in-game client patch; found " + matching.Count);
            NativeGuards.Apply(matching[0].Id, exe);
            guestPatched = true;
            SetStatus("patched");
        }
        finally
        {
            foreach (var proc in processes) proc.Dispose();
        }
    }

    public void Leave()
    {
        if (pendingJoinLobby != 0)
            SteamNative.SteamAPI_ISteamMatchmaking_LeaveLobby(matchmaking, pendingJoinLobby);
        pendingJoinLobby = 0;
        pending = 0;
        pendingCallback = 0;
        if (lobby != 0) SteamNative.SteamAPI_ISteamMatchmaking_LeaveLobby(matchmaking, lobby);
        if (joinedLobby != 0 && joinedLobby != lobby)
            SteamNative.SteamAPI_ISteamMatchmaking_LeaveLobby(matchmaking, joinedLobby);
        lobby = 0;
        joinedLobby = 0;
        SetGameEpoch(0);
        castEvents.Clear();
        ammoSnapshot=""; ammoEpoch=ammoSequence=0; ammoDirty=true;
        castDirty = true;
        members.Clear();
        profiles.Clear();
        choices.Clear(); partyDrafts = ""; partyDowned = ""; partyVisuals = "";
        try { partyGuard?.SetActive(false); } catch { }
        kickedMembers.Clear();
        hostStage = "lobby";
        remoteStage = "lobby";
        pendingEndpoint = "";
        gameHostReady = false;
        remoteHostReady = false;
        guestHasPossessedPawn = false;
        steamJoinStartedAt = DateTime.MinValue;
        unrealLoginStartedAt = DateTime.MinValue;
        guestTransportTimedOut = false;
        joinedFromInvite = false;
        SteamNative.SteamAPI_ISteamFriends_SetRichPresence(friends, "connect", null);
        tunnel.Stop();
        SetStatus("ready");
    }

    private void CompleteApiResult(ulong handle, int callback, int byteCount)
    {
        if (handle != pending || callback != pendingCallback) return;
        var data = Marshal.AllocHGlobal(byteCount);
        try
        {
            bool failed;
            bool success = SteamNative.SteamAPI_ManualDispatch_GetAPICallResult(
                pipe, handle, data, byteCount, callback, out failed);
            pending = 0;
            pendingCallback = 0;
            if (!success || failed)
            {
                SetStatus("error", "Steam async call failed; callback=" + callback);
                return;
            }
            switch (callback)
            {
                case 513:
                {
                    int result = Marshal.ReadInt32(data);
                    ulong createdId = unchecked((ulong)Marshal.ReadInt64(data, 8));
                    if (result != 1 || createdId == 0)
                    {
                        SetStatus("error", "Lobby creation rejected: EResult " + result);
                        return;
                    }
                    lobby = createdId;
                    created = true;
                    bool tag = SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(matchmaking, lobby, "rotm", LobbyTag);
                    bool transport = SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(
                        matchmaking, lobby, "transport", TransportVersion);
                    bool name = SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(matchmaking, lobby, "name", pendingTitle);
                    SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(matchmaking, lobby, "host_id", localSteamId.ToString());
                    SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(matchmaking, lobby, "host_name",
                        Safe(SteamNative.Utf8(SteamNative.SteamAPI_ISteamFriends_GetPersonaName(friends))));
                    bool ready = SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(matchmaking, lobby, "ready", "0");
                    bool epoch = SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(matchmaking, lobby, "epoch", "0");
                    bool stage = SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(matchmaking, lobby, "stage", "lobby");
                    bool bans = SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(matchmaking, lobby, "bans", "");
                    if (!tag || !transport || !name || !ready || !epoch || !stage || !bans)
                    {
                        Leave();
                        SetStatus("error", "Steam lobby metadata could not be published.");
                        return;
                    }
                    tunnel.StartHost(lobby);
                    SetMemberPhase("lobby");
                    RefreshRoster();
                    SteamNative.SteamAPI_ISteamFriends_SetRichPresence(friends,
                        "connect", "+connect_lobby " + lobby);
                    RefreshFriends();
                    SetStatus("hosting");
                    Console.WriteLine("STEAM_LOBBY_CREATED " + lobby);
                    break;
                }
                case 510:
                {
                    int count = Marshal.ReadInt32(data);
                    lobbyList = new List<string>();
                    for (int i = 0; i < Math.Min(count, 100); i++)
                        AddLobby(SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyByIndex(matchmaking, i));
                    foreach (ulong id in friendLobbyIds) AddLobby(id);
                    SetStatus("listed");
                    break;
                }
                case 504:
                {
                    pendingJoinLobby = 0;
                    ulong id = unchecked((ulong)Marshal.ReadInt64(data, 0));
                    uint response = unchecked((uint)Marshal.ReadInt32(data, 16));
                    if (response != 1 || id == 0)
                    {
                        SetStatus("error", "Lobby join rejected: " + response);
                        return;
                    }
                    joinedLobby = id;
                    string bansText = SteamNative.Utf8(
                        SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyData(matchmaking, id, "bans"));
                    if (bansText.Split(',', StringSplitOptions.RemoveEmptyEntries)
                        .Contains(localSteamId.ToString(), StringComparer.Ordinal))
                    {
                        Leave();
                        SetStatus("kicked", "This lobby owner has excluded your Steam account.");
                        return;
                    }
                    string transport = SteamNative.Utf8(SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyData(
                        matchmaking, id, "transport"));
                    if (transport != TransportVersion)
                    {
                        Leave();
                        SetStatus("error", "This lobby uses an unsupported game transport.");
                        return;
                    }
                    ulong owner = SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyOwner(matchmaking, id);
                    if (owner == 0 || owner == localSteamId)
                    {
                        SetStatus("error", "Cannot resolve a distinct Steam lobby owner.");
                        return;
                    }
                    int port = tunnel.StartGuest(id, owner);
                    pendingEndpoint = "127.0.0.1:" + port;
                    SetMemberPhase("lobby");
                    RefreshRoster();
                    SetStatus("waiting_host");
                    break;
                }
            }
        }
        finally { Marshal.FreeHGlobal(data); }
    }

    private void Pump()
    {
        SteamNative.SteamAPI_ManualDispatch_RunFrame(pipe);
        while (SteamNative.SteamAPI_ManualDispatch_GetNextCallback(pipe, out var cb))
        {
            try
            {
                if (cb.Callback == 1202 && cb.Param != IntPtr.Zero && cb.ParamSize >= 8)
                {
                    tunnel.OnSessionRequested(unchecked((ulong)Marshal.ReadInt64(cb.Param, 0)));
                }
                if (cb.Callback == 333 && cb.Param != IntPtr.Zero && cb.ParamSize >= 16)
                {
                    ulong invitedLobby = unchecked((ulong)Marshal.ReadInt64(cb.Param, 0));
                    if (invitedLobby != 0)
                    {
                        queuedInvitationLobby = invitedLobby;
                        Console.WriteLine("STEAM_INVITE_ACCEPTED");
                    }
                }
                if (cb.Callback == 337 && cb.Param != IntPtr.Zero && cb.ParamSize >= 9)
                {
                    string connect = Marshal.PtrToStringUTF8(
                        cb.Param + 8, Math.Min(cb.ParamSize - 8, 256)) ?? "";
                    var match = System.Text.RegularExpressions.Regex.Match(connect,
                        @"\+connect_lobby\s+(\d+)");
                    if (match.Success && ulong.TryParse(match.Groups[1].Value, out ulong richLobby))
                        queuedInvitationLobby = richLobby;
                }
                if (cb.Callback == 506 && cb.Param != IntPtr.Zero && cb.ParamSize >= 28)
                {
                    ulong affected = unchecked((ulong)Marshal.ReadInt64(cb.Param, 0));
                    if (affected == lobby || affected == joinedLobby) RefreshRoster();
                }
                if (cb.Callback == 507 && cb.Param != IntPtr.Zero && cb.ParamSize >= 24)
                {
                    ulong chatLobby = unchecked((ulong)Marshal.ReadInt64(cb.Param, 0));
                    int chatId = Marshal.ReadInt32(cb.Param, 20);
                    ReceiveLobbyChat(chatLobby, chatId);
                }
                if (cb.Callback == 505 && cb.Param != IntPtr.Zero && cb.ParamSize >= 16)
                {
                    ulong changedLobby = unchecked((ulong)Marshal.ReadInt64(cb.Param, 0));
                    if (friendLobbyIds.Contains(changedLobby) &&
                        (status is "listed" or "searching"))
                    {
                        AddLobby(changedLobby);
                        WriteStatus();
                    }
                }
                if (cb.Callback == 703 && cb.Param != IntPtr.Zero && cb.ParamSize >= 16)
                {
                    ulong handle = unchecked((ulong)Marshal.ReadInt64(cb.Param, 0));
                    int callbackId = Marshal.ReadInt32(cb.Param, 8);
                    int bytes = Marshal.ReadInt32(cb.Param, 12);
                    if (bytes > 0 && bytes < 4096)
                        CompleteApiResult(handle, callbackId, bytes);
                }
            }
            finally { SteamNative.SteamAPI_ManualDispatch_FreeLastCallback(pipe); }
        }
    }

    private void PollInput()
    {
        if (ipc == null) return;
        // New atomic command queue: process in creation order, never overwrite.
        // The legacy command.txt is retained for existing automation/tests.
        foreach (string path in Directory.EnumerateFiles(ipc, "command-*.txt")
                     .OrderBy(Path.GetFileName, StringComparer.Ordinal).Take(16))
        {
            try
            {
                string contents = File.ReadAllText(path, Encoding.UTF8).Trim();
                File.Delete(path);
                ProcessCommand(contents);
            }
            catch (IOException) { }
        }
        string legacy = Path.Combine(ipc, "command.txt");
        if (File.Exists(legacy))
        {
            try
            {
                string contents = File.ReadAllText(legacy, Encoding.UTF8).Trim();
                File.Delete(legacy);
                ProcessCommand(contents);
            }
            catch (IOException) { }
        }
    }

    private static bool ValidPartyPayload(string payload) =>
        payload.Length <= 2048 && payload.All(c => char.IsAsciiLetterOrDigit(c) ||
            c is '_' or '-' or '.' or ':' or ',' or ';' or '|');
    private string ReadPartyLobby(ulong active, string key)
    {
        string value = SteamNative.Utf8(SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyData(matchmaking, active, key));
        return ValidPartyPayload(value) ? value : "";
    }
    private static bool ValidEpoch(string value, uint epoch) =>
        uint.TryParse(value, out uint result) && result == epoch && result > 0;

    private static bool ValidProfile(string[] fields, uint epoch)
    {
        return fields.Length == 7 && uint.TryParse(fields[0], out uint e) && e == epoch && e > 0
            && int.TryParse(fields[1], out int playerId) && playerId > 0
            && int.TryParse(fields[2], out int robe) && robe is >= 1 and <= 6
            && fields.Skip(3).All(x => x.Length is >= 5 and <= 80 && x.StartsWith("GA_", StringComparison.Ordinal)
                && x.EndsWith("_C", StringComparison.Ordinal) && x.All(c => char.IsAsciiLetterOrDigit(c) || c == '_'));
    }

    private bool ValidVisual(string payload)
    {
        var p = payload.Split('|');
        return p.Length == 8 && ValidEpoch(p[0], gameEpoch)
            && int.TryParse(p[1], out int id) && id > 0
            && uint.TryParse(p[2], out uint sequence) && sequence > 0
            && int.TryParse(p[3], out int slot) && slot is >= 1 and <= 4
            && int.TryParse(p[4], out int robe) && robe is >= 1 and <= 6
            && p[5].Length is >= 5 and <= 80 && p[5].StartsWith("GA_", StringComparison.Ordinal)
            && p[5].EndsWith("_C", StringComparison.Ordinal)
            && p[5].All(c => char.IsAsciiLetterOrDigit(c) || c == '_')
            && int.TryParse(p[6], out int yaw) && yaw is >= -360 and <= 360
            && int.TryParse(p[7], out int pitch) && pitch is >= -90 and <= 90;
    }

    private bool ValidAmmo(string payload, out uint epoch, out uint sequence)
    {
        epoch=sequence=0;
        var p=payload.Split('|');
        if(p.Length!=4 || p[0]!="A" || !uint.TryParse(p[1],out epoch) ||
            epoch!=gameEpoch || epoch==0 || !uint.TryParse(p[2],out sequence) || sequence==0) return false;
        var rows=p[3].Split(';');
        if(rows.Length is <1 or >4) return false;
        var ids=new HashSet<int>();
        foreach(var row in rows)
        {
            var v=row.Split(':');
            if((v.Length!=3 && v.Length!=7) || !int.TryParse(v[0],out int id) || id<=0 || !ids.Add(id) ||
                !int.TryParse(v[1],out int count) || !int.TryParse(v[2],out int max) ||
                max is <1 or >100000 || count<0 || count>max) return false;
            if(v.Length==7)
            {
                if(!int.TryParse(v[3],out int slot) || !uint.TryParse(v[4],out uint token) ||
                   !int.TryParse(v[5],out int position) || !int.TryParse(v[6],out int rate)) return false;
                if(slot==0)
                {
                    if(token!=0 || position!=0 || rate!=0) return false;
                }
                else if(slot is not (1 or 8) || token==0 || position is <0 or >600000 ||
                        rate is <1 or >10000) return false;
            }
        }
        return true;
    }

    private void ReceiveVisual(ulong peer, string payload)
    {
        if (ipc == null) return;
        if(payload.StartsWith("A|",StringComparison.Ordinal))
        {
            // The P2P tunnel admits only the current host on the guest side.
            if(!tunnel.Guest || !ValidAmmo(payload,out uint e,out uint seq) ||
                (e==ammoEpoch && seq<=ammoSequence)) return;
            ammoEpoch=e;ammoSequence=seq;ammoSnapshot=payload;ammoDirty=true;
            return;
        }
        if (tunnel.Hosting || !ValidVisual(payload)) return;
        castEvents.Enqueue(payload);
        while (castEvents.Count > 48) castEvents.Dequeue();
        castDirty = true;
    }
    private void FlushAmmo()
    {
        DateTime now = DateTime.UtcNow;
        if (!ammoDirty || ipc == null || now - lastAmmoWrite < TimeSpan.FromMilliseconds(40)) return;
        lastAmmoWrite = now;
        try
        {
            AtomicWrite(Path.Combine(ipc, "party-ammo.txt"), ammoSnapshot);
            ammoDirty = false;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    private void FlushVisualEvents()
    {
        if (!castDirty || ipc == null || DateTime.UtcNow - lastCastWrite < TimeSpan.FromMilliseconds(20)) return;
        lastCastWrite = DateTime.UtcNow;
        try { AtomicWrite(Path.Combine(ipc, "party-casts.txt"), string.Join("\n", castEvents)); castDirty = false; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    private void ReceiveCombat(ulong peer, string payload)
    {
        if (ipc == null || !CombatEvents.TryParse(payload, gameEpoch, out var message)) return;
        if (message.FromGuest ? tunnel.Hosting && gameHostReady : tunnel.Guest && remoteHostReady)
            combat.Receive(peer, message, DateTime.UtcNow);
    }

    private void ClearCombat()
    {
        combat.Clear();
        tunnel.ClearCombat();
    }

    private void SetGameEpoch(uint epoch)
    {
        if (epoch == gameEpoch) return;
        gameEpoch = epoch;
        ClearCombat();
    }

    private void FlushCombat()
    {
        DateTime now = DateTime.UtcNow;
        if (ipc == null || now - lastCombatWrite < TimeSpan.FromMilliseconds(20)) return;
        lastCombatWrite = now;
        combat.Expire(now, tunnel.IsCombatPeerVerified);
        if (!combat.Dirty) return;
        try
        {
            AtomicWrite(Path.Combine(ipc, "party-combat.txt"), combat.Snapshot());
            combat.MarkFlushed();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }

    private void ProcessCommand(string text)
    {
        if (text.Length > 2300) { SetStatus("error", "Lobby command too long."); return; }
        var parts = text.Split('|');
        try
        {
            switch (parts[0])
            {
                case "create":
                    Create(parts.Length > 1 ? parts[1] : "auto",
                        parts.Length > 2 ? parts[2] : "RotM Co-op");
                    break;
                case "list": List(); break;
                case "join":
                    if (parts.Length < 2 || !ulong.TryParse(parts[1], out ulong id)) throw new ArgumentException("Bad lobby ID");
                    joinedFromInvite = false;
                    Join(id);
                    break;
                case "invite":
                    if (parts.Length < 2 || !ulong.TryParse(parts[1], out ulong friendId)) throw new ArgumentException("Bad Steam friend ID");
                    Invite(friendId);
                    break;
                case "friends": RefreshFriends(); WriteStatus(); break;
                case "kick":
                    if (parts.Length != 2 || !ulong.TryParse(parts[1], out ulong kickId))
                        throw new ArgumentException("Invalid Steam member ID");
                    KickMember(kickId);
                    break;
                case "roster": RefreshRoster(); WriteStatus(); break;
                case "profile":
                    ulong active = lobby != 0 ? lobby : joinedLobby;
                    string[] fields = parts.Skip(1).ToArray();
                    if (active != 0 && ValidProfile(fields, gameEpoch))
                    {
                        SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyMemberData(matchmaking, active,
                            "rotm_profile_v1", string.Join("|", fields));
                        RefreshRoster(); WriteStatus();
                    }
                    break;
                case "party_ammo":
                    if(tunnel.Hosting && parts.Length==4)
                    {
                        string snapshot="A|"+string.Join("|",parts.Skip(1));
                        if(ValidAmmo(snapshot,out _,out _)) tunnel.BroadcastVisual(snapshot);
                    }
                    break;
                case "party_cast":
                    if (lobby != 0 && parts.Length == 9)
                    {
                        string visual = string.Join("|", parts.Skip(1));
                        if (ValidVisual(visual)) tunnel.BroadcastVisual(visual);
                    }
                    break;
                case "party_combat":
                    int commandLength = "party_combat|".Length;
                    if (text.Length <= commandLength ||
                        !CombatEvents.TryParse(text[commandLength..], gameEpoch, out var message)) break;
                    if (message.FromGuest
                        ? tunnel.Guest && remoteHostReady && guestHasPossessedPawn
                        : tunnel.Hosting && gameHostReady)
                        tunnel.SendCombat(message.Text, message.Reliable);
                    break;
                case "party_guard":
                    if (parts.Length == 2 && partyGuard != null)
                        partyGuard.SetActive(parts[1] == "1" && (lobby != 0 || joinedLobby != 0) && members.Count >= 2);
                    WriteStatus();
                    break;
                case "party_cards":
                case "party_downed":
                case "party_visuals":
                    if (lobby != 0 && parts.Length >= 3 && ValidEpoch(parts[1], gameEpoch))
                    {
                        string payload = string.Join("|", parts.Skip(1));
                        if (!ValidPartyPayload(payload)) break;
                        bool cards = parts[0] == "party_cards";
                        bool visuals = parts[0] == "party_visuals";
                        if (SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(matchmaking, lobby,
                            visuals ? "rotm_visuals_v1" : cards ? "rotm_cards_v2" : "rotm_downed_v2", payload))
                        {
                            if (visuals) partyVisuals = payload; else if (cards) partyDrafts = payload; else partyDowned = payload;
                            WriteStatus();
                        }
                    }
                    break;
                case "party_choice":
                    if (joinedLobby != 0 && lobby == 0 && parts.Length == 5
                        && ValidEpoch(parts[1], gameEpoch) && uint.TryParse(parts[2], out _)
                        && int.TryParse(parts[3], out int pid) && pid > 0
                        && int.TryParse(parts[4], out int index) && index is >= 1 and <= 3)
                    {
                        SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyMemberData(matchmaking, joinedLobby,
                            "rotm_choice_v2", string.Join("|", parts.Skip(1)));
                    }
                    break;
                case "stage":
                    if (lobby != 0 && parts.Length == 2 &&
                        parts[1] is "lobby" or "hub" or "run" or "loading")
                    {
                        hostStage = parts[1];
                        SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(
                            matchmaking, lobby, "stage", hostStage);
                        RefreshRoster();
                        WriteStatus();
                    }
                    break;
                case "invite-dialog": ShowInviteDialog(); break;
                case "ready":
                    if (lobby != 0 && !gameHostReady)
                    {
                        // A World object does not mean Unreal is accepting UDP.
                        // Only publish readiness after the actual game process
                        // binds a listen NetDriver port.
                        if (watchedGameProcess != null && !watchedGameProcess.HasExited)
                        {
                            int? gamePort = GameUdpListener.DetectServerPort(watchedGameProcess.Id);
                            if (gamePort == null)
                            {
                                SetStatus("hosting", "Waiting for owned Unreal UDP socket (7777-7799 or 27015-27035)");
                                break;
                            }
                            tunnel.UpdateHostGamePort(gamePort.Value);
                        }
                        uint next = gameEpoch + 1;
                        bool epoch = SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(
                            matchmaking, lobby, "epoch", next.ToString());
                        gameHostReady = epoch && SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(
                            matchmaking, lobby, "ready", "1");
                        if (gameHostReady)
                        {
                            SetGameEpoch(next);
                            hostUdpMisses = 0;
                            lastHostUdpHealthAt = DateTime.UtcNow;
                        }
                        SetStatus(gameHostReady ? "hosting" : "error",
                            gameHostReady ? null : "Steam lobby readiness or epoch update rejected.");
                    }
                    break;
                case "busy":
                    if (lobby != 0)
                    {
                        gameHostReady = false;
                        ClearCombat();
                        hostStage = "loading";
                        SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(
                            matchmaking, lobby, "stage", hostStage);
                        if (SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(
                            matchmaking, lobby, "ready", "0"))
                            SetStatus("hosting");
                        else SetStatus("error", "Steam map transition flag rejected.");
                    }
                    break;
                case "patch": PatchGuestGame(); break;
                case "game_start":
                    if (joinedLobby != 0 && tunnel.Guest)
                    {
                        if (!tunnel.P2PReady || !remoteHostReady)
                        {
                            SetStatus("host_unavailable", "Host is not ready or Steam P2P handshake was lost.");
                            break;
                        }
                        if (unrealLoginStartedAt == DateTime.MinValue || status != "connecting_game")
                        {
                            unrealLoginStartedAt = DateTime.UtcNow;
                            baselineReceivedAtLogin = tunnel.Incoming;
                            guestHasPossessedPawn = false;
                            SetMemberPhase("loading");
                            SetStatus("connecting_game");
                        }
                    }
                    break;
                case "game_ready":
                    if (joinedLobby != 0 && tunnel.Guest)
                    {
                        guestHasPossessedPawn = true;
                        SetMemberPhase("playing");
                        unrealLoginStartedAt = DateTime.MinValue;
                        SetStatus("playing");
                    }
                    break;
                case "game_disconnected":
                    if (joinedLobby != 0 && tunnel.Guest)
                    {
                        guestHasPossessedPawn = false;
                        ClearCombat();
                        SetMemberPhase("lobby");
                        SetStatus("disconnected", "Connection to the host game was lost.");
                    }
                    break;
                case "leave": Leave(); break;
                case "shutdown": running = false; break;
            }
        }
        catch (Exception ex) { SetStatus("error", ex.Message); }
    }

    public int Run(bool createSmoke)
    {
        if (createSmoke) Create("p2p", "RotM private smoke test", true);
        DateTime until = DateTime.UtcNow.AddSeconds(createSmoke ? 26 : 3600 * 8);
        DateTime started = DateTime.UtcNow;
        DateTime lastInputPoll = DateTime.MinValue;
        while (running && DateTime.UtcNow < until)
        {
            Pump();
            tunnel.Tick();
            FlushVisualEvents();
            FlushAmmo();
            FlushCombat();
            if (gameHostReady && tunnel.Hosting && watchedGameProcess != null &&
                !watchedGameProcess.HasExited &&
                DateTime.UtcNow - lastHostUdpHealthAt > TimeSpan.FromSeconds(0.5))
            {
                lastHostUdpHealthAt = DateTime.UtcNow;
                int? actualPort = GameUdpListener.DetectServerPort(watchedGameProcess.Id);
                if (actualPort == null || actualPort != tunnel.HostGamePort)
                {
                    if (++hostUdpMisses >= 3)
                    {
                        hostUdpMisses = 0;
                        gameHostReady = false;
                        ClearCombat();
                        SteamNative.SteamAPI_ISteamMatchmaking_SetLobbyData(matchmaking, lobby, "ready", "0");
                        SetStatus("hosting", "Unreal listen socket disappeared; waiting for next map.");
                    }
                }
                else hostUdpMisses = 0;
            }
            if (tunnel.Guest && !guestHasPossessedPawn)
            {
                var age = DateTime.UtcNow - steamJoinStartedAt;
                if (steamJoinStartedAt != DateTime.MinValue &&
                    age > TimeSpan.FromSeconds(12) && !tunnel.P2PReady &&
                    tunnel.GuestP2PState == "error_4" && status != "host_offline")
                {
                    guestTransportTimedOut = true;
                    SetStatus("host_offline",
                        "Steam P2P timeout (error 4): remote peer is not responding.");
                }
                else if (!guestTransportTimedOut && unrealLoginStartedAt != DateTime.MinValue &&
                         DateTime.UtcNow - unrealLoginStartedAt > TimeSpan.FromSeconds(18) &&
                         tunnel.Incoming <= baselineReceivedAtLogin)
                {
                    guestTransportTimedOut = true;
                    SetStatus("game_no_response",
                        "Steam P2P connects, but the host Unreal UDP server never replied.");
                }
                else if (!guestTransportTimedOut && unrealLoginStartedAt != DateTime.MinValue &&
                         DateTime.UtcNow - unrealLoginStartedAt > TimeSpan.FromSeconds(45))
                {
                    guestTransportTimedOut = true;
                    SetStatus("game_login_timeout",
                        "Host sends UDP packets, but the client pawn was not possessed.");
                }
            }
            if (watchGameProcess && (watchedGameProcess == null || watchedGameProcess.HasExited))
            {
                Console.WriteLine("GAME_EXIT_DETECTED: Steam lobby and P2P closing immediately");
                break;
            }
            if (ipc != null && DateTime.UtcNow - lastInputPoll >= TimeSpan.FromMilliseconds(20)) { lastInputPoll = DateTime.UtcNow; PollInput(); }
            if (queuedInvitationLobby != 0 && pending == 0)
            {
                ulong invitedLobby = queuedInvitationLobby;
                queuedInvitationLobby = 0;
                if (joinedLobby != invitedLobby)
                {
                    Leave();
                    joinedFromInvite = true;
                    Join(invitedLobby);
                }
            }
            if (DateTime.UtcNow - lastRosterRefresh > TimeSpan.FromSeconds(0.5))
            {
                lastRosterRefresh = DateTime.UtcNow;
                RefreshRoster();
            }
            if (joinedLobby != 0 &&
                DateTime.UtcNow - lastLobbyRefresh > TimeSpan.FromSeconds(2))
            {
                lastLobbyRefresh = DateTime.UtcNow;
                SteamNative.SteamAPI_ISteamMatchmaking_RequestLobbyData(matchmaking, joinedLobby);
                string ready = SteamNative.Utf8(
                    SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyData(matchmaking, joinedLobby, "ready"));
                if (remoteHostReady && ready == "0") ClearCombat();
                remoteHostReady = ready == "1";
                remoteStage = SteamNative.Utf8(
                    SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyData(matchmaking, joinedLobby, "stage"));
                string epochText = SteamNative.Utf8(
                    SteamNative.SteamAPI_ISteamMatchmaking_GetLobbyData(matchmaking, joinedLobby, "epoch"));
                if (uint.TryParse(epochText, out uint parsedEpoch) && parsedEpoch > gameEpoch) SetGameEpoch(parsedEpoch);
                if (status is "waiting_host" or "waiting_p2p")
                {
                    if (remoteHostReady && tunnel.P2PReady) SetStatus("joined");
                    else if (remoteHostReady && status != "waiting_p2p") SetStatus("waiting_p2p");
                    else if (!remoteHostReady && status != "waiting_host") SetStatus("waiting_host");
                }
            }
            // Do not automatically turn terminal connection errors back into
            // 'joined'. A deliberate retry or a new lobby session is required.
            if (DateTime.UtcNow - lastStatus > TimeSpan.FromSeconds(lobby != 0 || joinedLobby != 0 ? 0.75 : 3)) WriteStatus();
            if (createSmoke && created) return 0;
            if (createSmoke && status == "error") return 1;
            if (ipc != null && !watchGameProcess && DateTime.UtcNow - started > TimeSpan.FromSeconds(50))
            {
                string heartbeat = Path.Combine(ipc, "heartbeat.txt");
                if (!File.Exists(heartbeat) ||
                    DateTime.UtcNow - File.GetLastWriteTimeUtc(heartbeat) > TimeSpan.FromSeconds(45))
                    break;
            }
            Thread.Sleep(5);
        }
        return createSmoke ? 2 : 0;
    }

    public void Dispose()
    {
        try { Leave(); } catch { }
        tunnel.Dispose();
        watchedGameProcess?.Dispose();
        SteamNative.SteamAPI_Shutdown();
    }
}

internal static class Program
{
    public static int Main(string[] args)
    {
        try
        {
            if (args.Length == 1 && args[0] == "--udp-selftest")
            {
                GameUdpListener.SelfTest();
                return 0;
            }
            if (args.Length == 1 && args[0] == "--wire-selftest")
            {
                SteamWire.SelfTest();
                return 0;
            }
            if (args.Length == 3 && args[0] == "--apply-guard")
            {
                NativeGuards.Apply(int.Parse(args[1]), args[2]);
                return 0;
            }
            // Isolated LAN regression harness: same native UI suppression
            // as Steam lobby entry, with party death interception disabled.
            if (args.Length == 3 && args[0] == "--qa-party-guard")
            {
                NativeGuards.InstallParty(int.Parse(args[1]), args[2]);
                return 0;
            }
            bool smoke = args.Contains("--smoke-create");
            string? ipc = args.Length >= 2 && args[0] == "--serve" ? args[1] : null;
            using var bridge = new Bridge(ipc, smoke);
            if (args.Contains("--probe")) return 0;
            return bridge.Run(smoke);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("STEAM_480_ERROR " + ex);
            return 1;
        }
    }
}
