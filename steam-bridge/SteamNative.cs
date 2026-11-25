using System.Runtime.InteropServices;
using System.Text;

namespace RotMSteamBridge;

internal static class SteamNative
{
    private const string Lib = "steam_api64.dll";
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] internal static extern int SteamAPI_InitFlat(byte[] errorBuffer);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] internal static extern void SteamAPI_Shutdown();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] internal static extern int SteamAPI_GetHSteamPipe();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] internal static extern void SteamAPI_ManualDispatch_Init();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] internal static extern void SteamAPI_ManualDispatch_RunFrame(int pipe);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ManualDispatch_GetNextCallback(int pipe, out CallbackMsg callback);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void SteamAPI_ManualDispatch_FreeLastCallback(int pipe);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ManualDispatch_GetAPICallResult(int pipe, ulong handle, IntPtr buffer, int size, int callbackId, [MarshalAs(UnmanagedType.I1)] out bool failed);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr SteamAPI_SteamMatchmaking_v009();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr SteamAPI_SteamFriends_v017();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern ulong SteamAPI_ISteamMatchmaking_CreateLobby(IntPtr mm, int type, int maxMembers);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern ulong SteamAPI_ISteamMatchmaking_RequestLobbyList(IntPtr mm);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void SteamAPI_ISteamMatchmaking_AddRequestLobbyListStringFilter(IntPtr mm, [MarshalAs(UnmanagedType.LPUTF8Str)] string key, [MarshalAs(UnmanagedType.LPUTF8Str)] string value, int comparison);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern ulong SteamAPI_ISteamMatchmaking_GetLobbyByIndex(IntPtr mm, int index);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern ulong SteamAPI_ISteamMatchmaking_JoinLobby(IntPtr mm, ulong lobbyId);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void SteamAPI_ISteamMatchmaking_LeaveLobby(IntPtr mm, ulong lobbyId);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamMatchmaking_SetLobbyData(IntPtr mm, ulong lobbyId, [MarshalAs(UnmanagedType.LPUTF8Str)] string key, [MarshalAs(UnmanagedType.LPUTF8Str)] string value);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr SteamAPI_ISteamMatchmaking_GetLobbyData(IntPtr mm, ulong lobbyId, [MarshalAs(UnmanagedType.LPUTF8Str)] string key);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int SteamAPI_ISteamMatchmaking_GetNumLobbyMembers(IntPtr mm, ulong lobbyId);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr SteamAPI_ISteamFriends_GetPersonaName(IntPtr friends);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamFriends_SetRichPresence(IntPtr friends,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string key,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string? value);


    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr SteamAPI_SteamNetworking_v006();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] internal static extern IntPtr SteamAPI_SteamUser_v023();
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)] internal static extern ulong SteamAPI_ISteamUser_GetSteamID(IntPtr user);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamNetworking_AllowP2PPacketRelay(IntPtr networking, [MarshalAs(UnmanagedType.I1)] bool enabled);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamNetworking_SendP2PPacket(IntPtr networking, ulong peer, byte[] payload, uint bytes, int sendType, int channel);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamNetworking_IsP2PPacketAvailable(IntPtr networking, out uint bytes, int channel);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamNetworking_ReadP2PPacket(IntPtr networking, byte[] data, uint bufferSize, out uint bytes, out ulong peer, int channel);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamNetworking_AcceptP2PSessionWithUser(IntPtr networking, ulong peer);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamNetworking_CloseP2PSessionWithUser(IntPtr networking, ulong peer);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamNetworking_GetP2PSessionState(IntPtr networking, ulong peer, out P2PSessionState state);
    [StructLayout(LayoutKind.Sequential)]
    internal struct P2PSessionState {
        public byte Active, Connecting, Error, UsingRelay;
        public int QueuedBytes, QueuedPackets;
        public uint RemoteIP;
        public ushort RemotePort;
    }
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern ulong SteamAPI_ISteamMatchmaking_GetLobbyOwner(IntPtr mm, ulong lobby);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern ulong SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex(IntPtr mm, ulong lobby, int index);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamMatchmaking_InviteUserToLobby(IntPtr mm, ulong lobby, ulong friend);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamMatchmaking_RequestLobbyData(IntPtr mm, ulong lobby);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void SteamAPI_ISteamMatchmaking_AddRequestLobbyListDistanceFilter(IntPtr mm, int distance);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void SteamAPI_ISteamMatchmaking_AddRequestLobbyListResultCountFilter(IntPtr mm, int count);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int SteamAPI_ISteamFriends_GetFriendCount(IntPtr friends, int flags);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern ulong SteamAPI_ISteamFriends_GetFriendByIndex(IntPtr friends, int index, int flags);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr SteamAPI_ISteamFriends_GetFriendPersonaName(IntPtr friends, ulong friend);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int SteamAPI_ISteamFriends_GetFriendPersonaState(IntPtr friends, ulong friend);
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamFriends_GetFriendGamePlayed(IntPtr friends, ulong friend, out FriendGameInfo game);
    [StructLayout(LayoutKind.Sequential)]
    internal struct FriendGameInfo {
        public ulong GameID;
        public uint IP;
        public ushort Port;
        public ushort QueryPort;
        public ulong LobbyID;
    }
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void SteamAPI_ISteamFriends_ActivateGameOverlayInviteDialog(IntPtr friends, ulong lobby);

    [StructLayout(LayoutKind.Sequential)]
    internal struct CallbackMsg
    {
        public int User;
        public int Callback;
        public IntPtr Param;
        public int ParamSize;
    }

    // Steam lobby messages are the documented application-layer kick mechanism:
    // the target validates that the message came from the lobby owner and leaves.
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamMatchmaking_SendLobbyChatMsg(
        IntPtr mm, ulong lobby, byte[] message, int length);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int SteamAPI_ISteamMatchmaking_GetLobbyChatEntry(
        IntPtr mm, ulong lobby, int chatId, out ulong sender,
        byte[] buffer, int maxBytes, out int entryType);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void SteamAPI_ISteamMatchmaking_SetLobbyMemberData(
        IntPtr mm, ulong lobby,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string key,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string value);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr SteamAPI_ISteamMatchmaking_GetLobbyMemberData(
        IntPtr mm, ulong lobby, ulong member,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string key);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    internal static extern bool SteamAPI_ISteamFriends_RequestUserInformation(
        IntPtr friends, ulong userId, [MarshalAs(UnmanagedType.I1)] bool nameOnly);

    internal static string Utf8(IntPtr pointer) =>
        pointer == IntPtr.Zero ? "" : Marshal.PtrToStringUTF8(pointer) ?? "";

    internal static string InitError(byte[] buffer) =>
        Encoding.UTF8.GetString(buffer).Split('\0', 2)[0];
}
