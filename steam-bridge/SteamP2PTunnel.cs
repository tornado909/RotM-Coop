using System.Net;
using System.Net.Sockets;
using System.Buffers.Binary;

namespace RotMSteamBridge;

/// <summary>
/// The game sees only a local UDP peer. All remote datagrams go over Steam P2P,
/// which handles NAT traversal and can use Valve relays without user port forwarding.
/// No local listening socket is exposed on a non-loopback interface.
/// </summary>
internal sealed class SteamP2PTunnel : IDisposable
{
    private const int SteamChannel = 19;
    private const int ControlChannel = 20;
    private const int VisualChannel = 21;
    private const int CombatChannel = 22;
    public Action<ulong, string>? VisualReceived { get; set; }
    public Action<ulong, string>? CombatReceived { get; set; }
    private const int SteamUnreliable = 0;
    private const int SteamReliable = 2;
    private const int MaxDatagram = 65507;
    private readonly IntPtr networking;
    private readonly Func<ulong, bool> isAllowedPeer;
    private readonly Action<string> log;
    private readonly Dictionary<ulong, UdpClient> hostPeers = new();
    private readonly byte[] udpBuffer = new byte[MaxDatagram];
    private readonly byte[] steamBuffer = new byte[MaxDatagram];
    private readonly SteamReassembly reassembly = new();
    private readonly Dictionary<ulong, DateTime> controlPeers = new();
    private readonly Dictionary<ulong, Queue<(byte[] Packet, DateTime Until)>> combatPending = new();
    private readonly Dictionary<ulong, DateTime> lastControlSent = new();
    private DateTime lastGuestProbe = DateTime.MinValue;
    private DateTime guestAckAt = DateTime.MinValue;
    private long controlSent;
    private long controlReceived;
    private uint nextSequence;
    // Unreal movement is encoded in small, time-sensitive UDP datagrams.
    // Large replicated payloads may contain 64 Steam fragments and previously
    // monopolized several bridge ticks, delaying movement behind them.
    private readonly Queue<(ulong Peer, byte[] Frame, int SendType, bool Last)> fastQueue = new();
    private readonly Queue<(ulong Peer, byte[] Frame, int SendType, bool Last)> bulkQueue = new();
    private const int FramesPerTick = 12;
    private const int MaxQueuedFrames = 2048;
    public int PendingFrames => fastQueue.Count + bulkQueue.Count;
    public int PendingMovementFrames => fastQueue.Count;
    public int PendingBulkFrames => bulkQueue.Count;
    private IPEndPoint gameServer = new(IPAddress.Loopback, 7777);
    public int HostGamePort => gameServer.Port;

    public void UpdateHostGamePort(int port)
    {
        if (port is < 1024 or > 65535) throw new ArgumentOutOfRangeException(nameof(port));
        if (gameServer.Port == port) return;
        gameServer = new IPEndPoint(IPAddress.Loopback, port);
        log("P2P_HOST_GAME_PORT_UPDATED " + port);
    }
    private UdpClient? clientSocket;
    private IPEndPoint? clientGameSocket;
    private ulong remoteHost;
    private ulong lobby;
    private bool hosting;
    private long outgoing;
    private long incoming;
    private long drops;
    private DateTime firstGuestPacketAt = DateTime.MinValue;
    private DateTime lastErrorLog = DateTime.MinValue;
    private readonly HashSet<ulong> accepted = new();
    private readonly Dictionary<ulong, DateTime> pendingSessionRequests = new();

    public bool Hosting => hosting && lobby != 0;
    public bool Guest => !hosting && remoteHost != 0;
    public int LocalPort => clientSocket == null ? 0 : ((IPEndPoint)clientSocket.Client.LocalEndPoint!).Port;
    public ulong Outgoing => (ulong)outgoing;
    public ulong Incoming => (ulong)incoming;
    public ulong Dropped => (ulong)drops;
    public int PeerCount => hostPeers.Count;
    public int VerifiedPeers => hosting ? controlPeers.Count : (P2PReady ? 1 : 0);
    public int PendingSessionRequests => pendingSessionRequests.Count;
    public long ControlSent => controlSent;
    public long ControlReceived => controlReceived;
    public bool P2PReady => Guest && guestAckAt != DateTime.MinValue
        && DateTime.UtcNow - guestAckAt < TimeSpan.FromSeconds(14);
    public ulong PeerSteamId => remoteHost;
    public double SecondsWithoutGuestReply => Guest && incoming == 0 && firstGuestPacketAt != DateTime.MinValue
        ? (DateTime.UtcNow - firstGuestPacketAt).TotalSeconds : 0;
    public string GuestP2PState
    {
        get
        {
            if (!Guest) return "none";
            if (!SteamNative.SteamAPI_ISteamNetworking_GetP2PSessionState(networking, remoteHost, out var state))
                return "unavailable";
            if (state.Error != 0) return "error_" + state.Error;
            if (state.Active != 0) return "active";
            if (state.Connecting != 0) return "connecting";
            return "inactive";
        }
    }
    public string GuestRelay
    {
        get
        {
            if (!Guest) return "unknown";
            return SteamNative.SteamAPI_ISteamNetworking_GetP2PSessionState(networking, remoteHost, out var state)
                ? (state.UsingRelay != 0 ? "true" : "false") : "unknown";
        }
    }

    public SteamP2PTunnel(Func<ulong, bool> isAllowedPeer, Action<string> log)
    {
        networking = SteamNative.SteamAPI_SteamNetworking_v006();
        if (networking == IntPtr.Zero)
            throw new InvalidOperationException("SteamNetworking006 is unavailable");
        this.isAllowedPeer = isAllowedPeer;
        this.log = log;
        if (!SteamNative.SteamAPI_ISteamNetworking_AllowP2PPacketRelay(networking, true))
            throw new InvalidOperationException("Steam P2P relay could not be enabled");
        log("STEAM_RELAY_ENABLED");
    }

    private static UdpClient CreateLoopbackSocket()
    {
        UdpClient socket = new(new IPEndPoint(IPAddress.Loopback, 0));
        socket.Client.Blocking = false;
        socket.Client.ReceiveBufferSize = 1024 * 1024;
        socket.Client.SendBufferSize = 1024 * 1024;
        return socket;
    }

    public void StartHost(ulong lobbyId)
    {
        Stop();
        if (lobbyId == 0) throw new ArgumentException("Lobby ID required");
        lobby = lobbyId;
        hosting = true;
        log("P2P_HOST_READY lobby=" + lobbyId);
    }

    public int StartGuest(ulong lobbyId, ulong hostSteamId)
    {
        Stop();
        if (lobbyId == 0 || hostSteamId == 0)
            throw new ArgumentException("Steam lobby and owner required");
        lobby = lobbyId;
        remoteHost = hostSteamId;
        outgoing = 0;
        incoming = 0;
        drops = 0;
        firstGuestPacketAt = DateTime.MinValue;
        guestAckAt = DateTime.MinValue;
        lastGuestProbe = DateTime.MinValue;
        clientSocket = CreateLoopbackSocket();
        int localPort = LocalPort;
        log("P2P_GUEST_LOCAL_PROXY port=" + localPort);
        return localPort;
    }

    public void OnSessionRequested(ulong steamId)
    {
        if (steamId == 0 || lobby == 0 || steamId == remoteHost && !Guest)
        {
            ++drops;
            return;
        }
        if (isAllowedPeer(steamId))
        {
            AcceptAuthorizedPeer(steamId);
            return;
        }
        // Steam can raise P2PSessionRequest before LobbyChatUpdate has updated
        // the host's member list. Hold the request until the roster catches up.
        // Never accept an unknown Steam identity before checking membership.
        if (hosting && pendingSessionRequests.Count < 16)
        {
            pendingSessionRequests[steamId] = DateTime.UtcNow;
            log("P2P_SESSION_PENDING_LOBBY_ROSTER");
        }
        else
        {
            ++drops;
            LogError("Steam P2P request rejected: not an authorized lobby member");
        }
    }

    private void AcceptAuthorizedPeer(ulong steamId)
    {
        pendingSessionRequests.Remove(steamId);
        if (SteamNative.SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(networking, steamId))
        {
            accepted.Add(steamId);
            log("P2P_SESSION_ACCEPTED");
        }
        else LogError("Steam P2P request could not be accepted");
    }

    private void LogError(string error)
    {
        if (DateTime.UtcNow - lastErrorLog < TimeSpan.FromSeconds(3)) return;
        lastErrorLog = DateTime.UtcNow;
        log(error);
    }

    private void ForwardSteamToLocal(ulong peer, byte[] datagram)
    {
        int bytes = datagram.Length;
        if (hosting)
        {
            if (!isAllowedPeer(peer))
            {
                ++drops;
                return;
            }
            if (!hostPeers.TryGetValue(peer, out UdpClient? socket))
            {
                socket = CreateLoopbackSocket();
                hostPeers.Add(peer, socket);
                log("P2P_HOST_PROXY_PEER_CONNECTED count=" + hostPeers.Count);
            }
            socket.Send(datagram, bytes, gameServer);
            ++incoming;
        }
        else if (peer == remoteHost && clientGameSocket != null && clientSocket != null)
        {
            clientSocket.Send(datagram, bytes, clientGameSocket);
            ++incoming;
        }
        else ++drops;
    }

    // Lobby-scoped control packets prove the remote Steam identity can both send
    // and receive data before Unreal makes a single network travel attempt.
    private void SendControl(ulong peer, byte opcode)
    {
        byte[] packet = new byte[14];
        "RMC4"u8.CopyTo(packet);
        packet[4] = 1;
        packet[5] = opcode;
        BinaryPrimitives.WriteUInt64LittleEndian(packet.AsSpan(6), lobby);
        if (SteamNative.SteamAPI_ISteamNetworking_SendP2PPacket(networking,
                peer, packet, (uint)packet.Length, SteamReliable, ControlChannel))
            ++controlSent;
        else { ++drops; LogError("Steam control packet rejected"); }
    }

    private void PumpControl()
    {
        for (int n = 0; n < 128; ++n)
        {
            if (!SteamNative.SteamAPI_ISteamNetworking_IsP2PPacketAvailable(
                    networking, out uint size, ControlChannel)) return;
            if (size == 0 || size > 128) { ++drops; return; }
            if (!SteamNative.SteamAPI_ISteamNetworking_ReadP2PPacket(networking,
                    steamBuffer, (uint)steamBuffer.Length, out uint bytes, out ulong peer, ControlChannel))
                return;
            if (bytes != 14 || !steamBuffer.AsSpan(0, 4).SequenceEqual("RMC4"u8) ||
                steamBuffer[4] != 1 || BinaryPrimitives.ReadUInt64LittleEndian(
                    steamBuffer.AsSpan(6)) != lobby || !isAllowedPeer(peer))
            {
                ++drops;
                continue;
            }
            ++controlReceived;
            byte opcode = steamBuffer[5];
            if (hosting && opcode == 1) // HELLO
            {
                controlPeers[peer] = DateTime.UtcNow;
                SendControl(peer, 2); // WELCOME
            }
            else if (!hosting && peer == remoteHost && opcode == 2) // WELCOME
            {
                bool initial = !P2PReady;
                guestAckAt = DateTime.UtcNow;
                if (initial) log("STEAM_P2P_TWO_WAY_VERIFIED");
            }
            else if (opcode == 3) // GOODBYE
            {
                controlPeers.Remove(peer);
                if (peer == remoteHost) guestAckAt = DateTime.MinValue;
            }
        }
    }

    // Cosmetic events use an independent channel. Never execute a remote
    // gameplay ability from this data; the listen server remains authoritative.
    public void BroadcastVisual(string payload)
    {
        if ((!Hosting && !Guest) || payload.Length > 1000) return;
        byte[] data = System.Text.Encoding.ASCII.GetBytes(payload);
        byte[] packet = new byte[12 + data.Length];
        "RMV1"u8.CopyTo(packet);
        BinaryPrimitives.WriteUInt64LittleEndian(packet.AsSpan(4), lobby);
        data.CopyTo(packet, 12);
        var peers = Hosting ? controlPeers.Keys.ToArray() : new[] { remoteHost };
        int mode = payload.StartsWith("A|", StringComparison.Ordinal) ? SteamUnreliable : SteamReliable;
        foreach (ulong peer in peers)
            if (isAllowedPeer(peer))
                SteamNative.SteamAPI_ISteamNetworking_SendP2PPacket(
                    networking, peer, packet, (uint)packet.Length, mode, VisualChannel);
    }

    private void PumpVisual()
    {
        for (int i = 0; i < 64; i++)
        {
            if (!SteamNative.SteamAPI_ISteamNetworking_IsP2PPacketAvailable(
                networking, out uint size, VisualChannel)) return;
            if (!SteamNative.SteamAPI_ISteamNetworking_ReadP2PPacket(
                networking, steamBuffer, (uint)steamBuffer.Length, out uint bytes, out ulong peer, VisualChannel)) return;
            if ((!Hosting && (!Guest || peer != remoteHost)) || !isAllowedPeer(peer) || bytes < 13 || bytes > 1012 ||
                !steamBuffer.AsSpan(0, 4).SequenceEqual("RMV1"u8) ||
                BinaryPrimitives.ReadUInt64LittleEndian(steamBuffer.AsSpan(4)) != lobby) continue;
            VisualReceived?.Invoke(peer, System.Text.Encoding.ASCII.GetString(steamBuffer, 12, (int)bytes - 12));
        }
    }

    public bool IsCombatPeerVerified(ulong peer) =>
        isAllowedPeer(peer) && (Hosting ? controlPeers.ContainsKey(peer) : P2PReady && peer == remoteHost);

    public void SendCombat(string payload, bool reliable)
    {
        if ((!Hosting && !P2PReady) || payload.Length is < 1 or > 1000) return;
        var peers = Hosting ? controlPeers.Keys.ToArray() : new[] { remoteHost };
        byte[] packet = new byte[12 + payload.Length];
        "RMC2"u8.CopyTo(packet);
        BinaryPrimitives.WriteUInt64LittleEndian(packet.AsSpan(4), lobby);
        System.Text.Encoding.ASCII.GetBytes(payload, packet.AsSpan(12));
        foreach (ulong peer in peers)
        {
            if (!IsCombatPeerVerified(peer)) continue;
            if (!reliable || !combatPending.ContainsKey(peer))
            {
                if (SendCombatPacket(peer, packet, reliable) || !reliable) continue;
            }
            if (!combatPending.TryGetValue(peer, out var pending))
            {
                pending = new();
                combatPending.Add(peer, pending);
            }
            if (pending.Count == 256)
            {
                log("COMBAT_RELIABLE_QUEUE_FULL");
                continue;
            }
            pending.Enqueue((packet, DateTime.UtcNow.AddSeconds(4)));
        }
    }

    private bool SendCombatPacket(ulong peer, byte[] packet, bool reliable) =>
        SteamNative.SteamAPI_ISteamNetworking_SendP2PPacket(networking, peer, packet, (uint)packet.Length,
            reliable ? SteamReliable : SteamUnreliable, CombatChannel);

    public void ClearCombat() => combatPending.Clear();

    private void PumpCombat()
    {
        foreach (var (peer, pending) in combatPending.ToArray())
        {
            if (!IsCombatPeerVerified(peer))
            {
                combatPending.Remove(peer);
                continue;
            }
            for (int i = 0; i < 16 && pending.TryPeek(out var item); ++i)
            {
                if (item.Until < DateTime.UtcNow) log("COMBAT_RELIABLE_SEND_TIMEOUT");
                else if (!SendCombatPacket(peer, item.Packet, true)) break;
                pending.Dequeue();
            }
            if (pending.Count == 0) combatPending.Remove(peer);
        }
        for (int i = 0; i < 96; ++i)
        {
            if (!SteamNative.SteamAPI_ISteamNetworking_IsP2PPacketAvailable(networking, out _, CombatChannel) ||
                !SteamNative.SteamAPI_ISteamNetworking_ReadP2PPacket(networking, steamBuffer,
                    (uint)steamBuffer.Length, out uint bytes, out ulong peer, CombatChannel)) return;
            if (bytes is < 13 or > 1012 || !IsCombatPeerVerified(peer) ||
                !steamBuffer.AsSpan(0, 4).SequenceEqual("RMC2"u8) ||
                BinaryPrimitives.ReadUInt64LittleEndian(steamBuffer.AsSpan(4)) != lobby) continue;
            CombatReceived?.Invoke(peer, System.Text.Encoding.ASCII.GetString(steamBuffer, 12, (int)bytes - 12));
        }
    }

    private void PumpSteamPackets()
    {
        PumpControl();
        PumpCombat();
        PumpVisual();
        for (int n = 0; n < 256; ++n)
        {
            if (!SteamNative.SteamAPI_ISteamNetworking_IsP2PPacketAvailable(networking,
                    out uint packetSize, SteamChannel))
                return;
            if (packetSize == 0 || packetSize > MaxDatagram)
            {
                ++drops;
                return;
            }
            if (!SteamNative.SteamAPI_ISteamNetworking_ReadP2PPacket(networking,
                    steamBuffer, (uint)steamBuffer.Length, out uint bytes, out ulong peer, SteamChannel))
                return;
            if (!isAllowedPeer(peer)) { ++drops; continue; }
            byte[]? data = reassembly.Accept(peer, steamBuffer.AsSpan(0, (int)bytes), DateTime.UtcNow);
            if (data == null) continue;
            try { ForwardSteamToLocal(peer, data); }
            catch (SocketException ex) { ++drops; LogError("Local UDP forward failed: " + ex.SocketErrorCode); }
        }
    }

    private void ForwardLocalToSteam(UdpClient socket, ulong peer, bool guest)
    {
        for (int n = 0; n < 128 && socket.Client.Poll(0, SelectMode.SelectRead); ++n)
        {
            EndPoint source = new IPEndPoint(IPAddress.Any, 0);
            int count;
            try { count = socket.Client.ReceiveFrom(udpBuffer, ref source); }
            catch (SocketException ex) when (ex.SocketErrorCode == SocketError.WouldBlock) { return; }
            if (count <= 0) continue;
            if (guest)
            {
                var addr = (IPEndPoint)source;
                if (!IPAddress.IsLoopback(addr.Address))
                {
                    ++drops; continue;
                }
                clientGameSocket = addr;
            }
            else if (!source.Equals(gameServer))
            {
                ++drops;
                continue;
            }
            var fragments = SteamWire.Encode(udpBuffer.AsSpan(0, count), ++nextSequence);
            if (PendingFrames + fragments.Count > MaxQueuedFrames)
            {
                ++drops;
                LogError("Steam P2P frame queue saturated; UDP datagram dropped");
                continue;
            }
            // Reliable transport is reserved for split datagrams: a single lost
            // frame otherwise makes the entire big Unreal UDP datagram unusable.
            // Small time-critical movement datagrams stay unordered/unreliable.
            int sendType = fragments.Count == 1 ? SteamUnreliable : SteamReliable;
            var selectedQueue = fragments.Count == 1 ? fastQueue : bulkQueue;
            for (int i = 0; i < fragments.Count; ++i)
                selectedQueue.Enqueue((peer, fragments[i], sendType, i == fragments.Count - 1));
            if (guest && firstGuestPacketAt == DateTime.MinValue)
                firstGuestPacketAt = DateTime.UtcNow;
        }
    }

    private void FlushQueuedFrames()
    {
        // Avoid dumping up to 64 fragments into Steam on a single frame. This
        // keeps the producer below reasonable UDP / Steam buffering limits.
        // Send up to 8 small datagrams promptly even when reliable fragments
        // are queued, while reserving 4 slots for bulky replication.
        int sent = 0;
        int fastBudget = bulkQueue.Count > 0 ? 8 : FramesPerTick;
        while (sent < fastBudget && fastQueue.Count > 0)
        {
            SendQueuedFrame(fastQueue.Dequeue());
            sent++;
        }
        while (sent < FramesPerTick && bulkQueue.Count > 0)
        {
            SendQueuedFrame(bulkQueue.Dequeue());
            sent++;
        }
        while (sent < FramesPerTick && fastQueue.Count > 0)
        {
            SendQueuedFrame(fastQueue.Dequeue());
            sent++;
        }
    }

    private void SendQueuedFrame((ulong Peer, byte[] Frame, int SendType, bool Last) next)
    {
        if (SteamNative.SteamAPI_ISteamNetworking_SendP2PPacket(networking,
            next.Peer, next.Frame, (uint)next.Frame.Length,
            next.SendType, SteamChannel))
        {
            if (next.Last) ++outgoing;
        }
        else
        {
            ++drops;
            LogError("Steam queued P2P frame send rejected");
        }
    }

    public void Tick()
    {
        if (lobby == 0) return;
        DateTime now = DateTime.UtcNow;
        if (Guest && now - lastGuestProbe > TimeSpan.FromSeconds(2))
        {
            lastGuestProbe = now;
            SendControl(remoteHost, 1);
        }
        FlushQueuedFrames();
        if (Hosting)
        {
            foreach (var request in pendingSessionRequests.ToArray())
            {
                if (isAllowedPeer(request.Key)) AcceptAuthorizedPeer(request.Key);
                else if (now - request.Value > TimeSpan.FromSeconds(30))
                {
                    pendingSessionRequests.Remove(request.Key);
                    ++drops;
                }
            }
            foreach (ulong peer in controlPeers.Where(x => now - x.Value >
                         TimeSpan.FromSeconds(15)).Select(x => x.Key).ToArray())
                controlPeers.Remove(peer);
        }
        try
        {
            PumpSteamPackets();
        }
        catch (SocketException ex)
        {
            ++drops;
            LogError("Steam-to-local receive error: " + ex.SocketErrorCode);
        }
        if (hosting)
        {
            foreach (var pair in hostPeers.ToArray())
            {
                if (!isAllowedPeer(pair.Key))
                {
                    pair.Value.Dispose();
                    hostPeers.Remove(pair.Key);
                    SteamNative.SteamAPI_ISteamNetworking_CloseP2PSessionWithUser(networking, pair.Key);
                    continue;
                }
                try { ForwardLocalToSteam(pair.Value, pair.Key, guest: false); }
                catch (SocketException ex)
                {
                    ++drops;
                    LogError("Host-local UDP socket error: " + ex.SocketErrorCode);
                }
            }
        }
        else if (clientSocket != null && remoteHost != 0)
        {
            try { ForwardLocalToSteam(clientSocket, remoteHost, guest: true); }
            catch (SocketException ex)
            {
                ++drops;
                LogError("Guest-local UDP socket error: " + ex.SocketErrorCode);
            }
        }
        FlushQueuedFrames();
    }

    public bool IsUsingRelay(ulong peer)
    {
        return peer != 0 &&
            SteamNative.SteamAPI_ISteamNetworking_GetP2PSessionState(networking, peer, out var state)
            && state.UsingRelay != 0;
    }

    public void Stop()
    {
        if (lobby != 0)
        {
            if (Guest && remoteHost != 0) SendControl(remoteHost, 3);
            if (Hosting)
                foreach (ulong peer in controlPeers.Keys.ToArray()) SendControl(peer, 3);
        }
        foreach (var pair in hostPeers)
        {
            pair.Value.Dispose();
            SteamNative.SteamAPI_ISteamNetworking_CloseP2PSessionWithUser(networking, pair.Key);
        }
        hostPeers.Clear();
        clientSocket?.Dispose();
        clientSocket = null;
        if (remoteHost != 0)
            SteamNative.SteamAPI_ISteamNetworking_CloseP2PSessionWithUser(networking, remoteHost);
        accepted.Clear();
        pendingSessionRequests.Clear();
        fastQueue.Clear();
        bulkQueue.Clear();
        reassembly.Clear();
        controlPeers.Clear();
        ClearCombat();
        lastControlSent.Clear();
        guestAckAt = DateTime.MinValue;
        lastGuestProbe = DateTime.MinValue;
        remoteHost = 0;
        lobby = 0;
        hosting = false;
        clientGameSocket = null;
    }

    public void Dispose() => Stop();
}
