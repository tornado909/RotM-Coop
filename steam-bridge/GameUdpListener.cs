using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;

namespace RotMSteamBridge;

/// <summary>
/// Read actual UDP socket bindings owned by the running game process.
/// A loaded UWorld alone does not prove an Unreal listen NetDriver exists.
/// </summary>
internal static class GameUdpListener
{
    private const int AF_INET = 2;
    private const int UdpTableOwnerPid = 1;
    private const uint InsufficientBuffer = 122;

    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern uint GetExtendedUdpTable(IntPtr table, ref int size,
        [MarshalAs(UnmanagedType.Bool)] bool ordered, int addressFamily, int tableClass, uint reserved);

    internal static IReadOnlyList<(int Port, IPAddress Bind)> GetProcessPorts(int pid)
    {
        int size = 0;
        uint result = GetExtendedUdpTable(IntPtr.Zero, ref size, false, AF_INET, UdpTableOwnerPid, 0);
        if (result != InsufficientBuffer || size < 4)
            throw new InvalidOperationException("GetExtendedUdpTable size query failed: " + result);
        IntPtr memory = Marshal.AllocHGlobal(size);
        try
        {
            result = GetExtendedUdpTable(memory, ref size, false, AF_INET, UdpTableOwnerPid, 0);
            if (result != 0) throw new InvalidOperationException("GetExtendedUdpTable failed: " + result);
            uint count = unchecked((uint)Marshal.ReadInt32(memory, 0));
            if (count > (size - 4) / 12)
                throw new InvalidOperationException("Invalid Windows UDP port table length");
            var endpoints = new List<(int Port, IPAddress Bind)>();
            for (int i = 0; i < count; i++)
            {
                int row = 4 + i * 12;
                uint address = unchecked((uint)Marshal.ReadInt32(memory, row));
                int networkPort = Marshal.ReadInt32(memory, row + 4);
                int owner = Marshal.ReadInt32(memory, row + 8);
                if (owner != pid) continue;
                int port = (ushort)IPAddress.NetworkToHostOrder(unchecked((short)networkPort));
                IPAddress bind = new(BitConverter.GetBytes(address));
                endpoints.Add((port, bind));
            }
            return endpoints;
        }
        finally { Marshal.FreeHGlobal(memory); }
    }

    // The shipped title can bind 27015 when launched without -port=7777.
    // The original implementation hardcoded 7777-7799 and left a fully
    // working listen host with Steam lobby ready=0 forever. Match only sockets
    // owned by the actual game PID, not another game's or Steam's sockets.
    internal static int? SelectServerPort(IEnumerable<(int Port, IPAddress Bind)> ports)
    {
        var candidates = ports
            .Where(x => (x.Port >= 7777 && x.Port <= 7799) ||
                        (x.Port >= 27015 && x.Port <= 27035))
            .Where(x => x.Bind.Equals(IPAddress.Any) || IPAddress.IsLoopback(x.Bind))
            .OrderBy(x => x.Port == 7777 ? 0 : x.Port == 27015 ? 1 : 2)
            .ThenBy(x => x.Port);
        return candidates.Select(x => (int?)x.Port).FirstOrDefault();
    }

    public static int? DetectServerPort(int gamePid) =>
        SelectServerPort(GetProcessPorts(gamePid));

    public static void SelectionSelfTest()
    {
        var any = IPAddress.Any;
        if (SelectServerPort([(27015, any)]) != 27015)
            throw new InvalidOperationException("Shipped game's default UDP 27015 was not selected");
        if (SelectServerPort([(7777, any), (27015, any)]) != 7777)
            throw new InvalidOperationException("Explicit Unreal UDP port was not preferred");
        if (SelectServerPort([(47000, any), (33000, any)]) != null)
            throw new InvalidOperationException("Unrelated UDP socket selected");
        if (SelectServerPort([(27015, IPAddress.Parse("192.0.2.1"))]) != null)
            throw new InvalidOperationException("Non-loopback/non-wildcard binding selected");
        Console.WriteLine("GAME_SERVER_PORT_SELECTION_SELFTEST_PASS");
    }

    public static void SelfTest()
    {
        using UdpClient socket = new(new IPEndPoint(IPAddress.Loopback, 0));
        var ep = (IPEndPoint)socket.Client.LocalEndPoint!;
        if (!GetProcessPorts(Environment.ProcessId).Any(x => x.Port == ep.Port &&
                IPAddress.IsLoopback(x.Bind)))
            throw new InvalidOperationException("Windows UDP ownership self-test failed");
        Console.WriteLine("GAME_UDP_OWNERSHIP_SELFTEST_PASS");
        SelectionSelfTest();
    }
}