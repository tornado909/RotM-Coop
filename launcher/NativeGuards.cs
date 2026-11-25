using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace RotMCoopLauncher;

internal static class NativeGuards
{
    private const string VerifiedHash = "98C8EB1D3474883D826D24FC67A49310425D5E42099AF120D5326A0DE09C8682";
    private const uint Access = 0x0008 | 0x0010 | 0x0020 | 0x0400;
    private const uint CommitReserve = 0x1000 | 0x2000;
    private const uint ReadWriteExecute = 0x40;
    private static readonly byte[] FloatOriginal = Hex("F30F1081400300000F57C90F2FC1");
    private static readonly byte[] RegisterOriginal = Hex("48895C24084889742410574883EC20");
    // Attribute sync RPC invoked on transient client-owned enemies/chests
    // when their custom attribute-set pointer (+0x6a8) is still null.
    private static readonly byte[] AttributeSyncOriginal = Hex("4889542410534883EC20488BD9488D542438");
    private static readonly byte[] MageBeginOriginal = Hex("4881C1E00700008945D44C8BC78975D0");
    private static readonly byte[] MageControllerOriginal = Hex("488B819007000080B81209000000");
    // EnemyDetection deactivation may run before its dependent object is available on a replicated pawn.
    private static readonly byte[] DetectionDeactivateOriginal = Hex("488B8BC000000033D2488B01FF9090040000");

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(nint handle);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ReadProcessMemory(nint process, nint address, [Out] byte[] bytes, nuint len, out nuint read);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool WriteProcessMemory(nint process, nint address, byte[] bytes, nuint len, out nuint written);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint VirtualAllocEx(nint process, nint address, nuint len, uint flags, uint protection);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool VirtualProtectEx(nint process, nint address, nuint len, uint newProtection, out uint oldProtection);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool FlushInstructionCache(nint process, nint address, nuint len);

    internal static void VerifyGame(string exactExe)
    {
        if (!File.Exists(exactExe))
            throw new FileNotFoundException("Исполняемый файл игры не найден", exactExe);
        using var stream = File.OpenRead(exactExe);
        var sha = Convert.ToHexString(SHA256.HashData(stream));
        if (!string.Equals(sha, VerifiedHash, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Неподдерживаемая сборка игры. Требуется Steam 1.0.0.301.");
    }

    private static void Ensure(bool success, string operation)
    {
        if (!success)
            throw new Win32Exception(Marshal.GetLastWin32Error(), operation);
    }

    private static byte[] Hex(string hex) => Convert.FromHexString(hex);
    private static byte[] Combine(params byte[][] parts) => parts.SelectMany(p => p).ToArray();
    private static byte[] Address(long address) => BitConverter.GetBytes(address);
    private static byte[] MoveRaxJump(long target) =>
        Combine(Hex("48B8"), Address(target), Hex("FFE0"));
    private static byte[] IndirectJump(long target) =>
        Combine(Hex("FF2500000000"), Address(target));

    private static byte[] Read(nint process, long address, int len)
    {
        var data = new byte[len];
        Ensure(ReadProcessMemory(process, (nint)address, data, (nuint)len, out var read),
            "ReadProcessMemory");
        if (read != (nuint)len)
            throw new IOException("Неполное чтение памяти игры.");
        return data;
    }

    private static void Write(nint process, long address, byte[] data)
    {
        Ensure(WriteProcessMemory(process, (nint)address, data, (nuint)data.Length, out var written),
            "WriteProcessMemory");
        if (written != (nuint)data.Length)
            throw new IOException("Неполная запись в память игры.");
    }

    private static void CheckBytes(nint handle, long baseAddress, int rva, byte[] expected)
    {
        if (!Read(handle, baseAddress + rva, expected.Length).SequenceEqual(expected))
            throw new InvalidOperationException(
                $"Проверка нативного кода не пройдена (RVA 0x{rva:X}). Защита не применена.");
    }

    private static long Patch(
        nint process, long site, byte[] original, Func<long, byte[]> buildStub, bool preserveAllRegisters)
    {
        var cave = VirtualAllocEx(process, nint.Zero, (nuint)4096, CommitReserve, ReadWriteExecute);
        if (cave == nint.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "VirtualAllocEx");
        var stub = buildStub(site);
        Write(process, (long)cave, stub);

        var jump = preserveAllRegisters ? IndirectJump((long)cave) : MoveRaxJump((long)cave);
        if (jump.Length > original.Length)
            throw new InvalidOperationException("Недостаточно длины для перехода к исправлению.");
        var patch = new byte[original.Length];
        Array.Fill(patch, (byte)0x90);
        Array.Copy(jump, patch, jump.Length);
        Ensure(VirtualProtectEx(process, (nint)site, (nuint)patch.Length,
            ReadWriteExecute, out var oldProtect), "VirtualProtectEx");
        try
        {
            Write(process, site, patch);
        }
        finally
        {
            Ensure(VirtualProtectEx(process, (nint)site, (nuint)patch.Length,
                oldProtect, out _), "VirtualProtectEx restore");
        }
        Ensure(FlushInstructionCache(process, (nint)site, (nuint)patch.Length), "FlushInstructionCache");
        if (!Read(process, site, patch.Length).SequenceEqual(patch))
            throw new IOException("Проверка патча в памяти завершилась ошибкой.");
        return (long)cave;
    }

    // Party-only guards. Remote UI suppression is unconditional because a
    // non-local PlayerController has no viewport. Death interception and the
    // explicit game-thread heal entry are disabled unless Lua enables a party.
    internal sealed class PartyHandle
    {
        private readonly int pid;
        private readonly long deathFlag, healFlag;
        private bool enabled;
        internal PartyHandle(int processId, long death, long heal)
        {
            pid = processId; deathFlag = death + 0x100; healFlag = heal + 0x100;
            SetActive(false, true);
        }
        internal bool Active => enabled;
        internal void SetActive(bool value, bool force = false)
        {
            if (!force && enabled == value) return;
            var h = OpenProcess(Access, false, pid);
            if (h == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "party guard OpenProcess");
            try
            {
                Write(h, healFlag, new byte[] { value ? (byte)1 : (byte)0 });
                Write(h, deathFlag, new byte[] { value ? (byte)1 : (byte)0 });
                enabled = value;
            }
            finally { CloseHandle(h); }
        }
    }
    private static long EnsurePartyPatch(nint h, long site, byte[] original, Func<long, byte[]> stub)
    {
        var found = Read(h, site, original.Length);
        if (found.SequenceEqual(original)) return Patch(h, site, original, stub, true);
        // Allow a bridge restart in the same exact game process; verify the
        // detour target and every stub instruction before reusing its flag.
        if (found.Length >= 14 && found.AsSpan(0,6).SequenceEqual(Hex("FF2500000000"))
            && found.Skip(14).All(x => x == 0x90))
        {
            long cave = BitConverter.ToInt64(found, 6);
            byte[] expected = stub(site);
            if (cave > 0 && Read(h, cave, expected.Length).SequenceEqual(expected)) return cave;
        }
        throw new InvalidOperationException("Party guard original bytes mismatch at " + site.ToString("X"));
    }
    // The same deactivation runs during host-side remote pawn teardown.
    private static void EnsureDetectionGuard(nint h, long image)
    {
        EnsurePartyPatch(h, image + 0x51D6859, DetectionDeactivateOriginal, site =>
            Combine(Hex("488B8BC000000033D24885C97409"),
                Hex("488B01FF9090040000"),
                IndirectJump(site + DetectionDeactivateOriginal.Length)));
    }
    // SpawnSystemAttached returns null with NullRHI or unavailable Niagara
    // assets. Skip only the cosmetic LoopDuration write, not ability damage.
    private static void EnsureNiagaraSpawnGuard(nint h, long image)
    {
        byte[] original = Hex("0F28D6488BCB488B10E815E282FF");
        EnsurePartyPatch(h, image + 0x5101EFD, original, site =>
            Combine(Hex("4885DB7416"), original[..9],
                Hex("49BB"), Address(image + 0x4930120), Hex("41FFD3"),
                IndirectJump(site + original.Length)));
    }
    // A remote mage must not start a local sequence/camera cut on the host.
    // RM_MageBase::PlayLevelSequencePlayer uses PC at +0x790; the verified
    // RM_PlayerController local-controller flag is bit 0 at +0x6c4.
    private static void EnsureLocalSequenceGuard(nint h, long image)
    {
        byte[] original = Hex("488BC4554157488D68A14881ECA8000000");
        EnsurePartyPatch(h, image + 0x50FF3E0, original, site =>
            Combine(Hex("488B81900700004885C07409F680C4060000017501C3"),
                original, IndirectJump(site + original.Length)));
    }
    internal static PartyHandle InstallParty(int pid, string exe)
    {
        VerifyGame(exe);
        using var proc = Process.GetProcessById(pid);
        if (!string.Equals(Path.GetFullPath(proc.MainModule?.FileName ?? ""), Path.GetFullPath(exe),
            StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Party process path mismatch");
        long image = proc.MainModule!.BaseAddress.ToInt64();
        var h = OpenProcess(Access, false, pid);
        if (h == 0) throw new Win32Exception(Marshal.GetLastWin32Error(), "party OpenProcess");
        try
        {
            EnsureDetectionGuard(h, image);
            EnsureNiagaraSpawnGuard(h, image);
            EnsureLocalSequenceGuard(h, image);
            byte[] ui = Hex("48895C24104889742420574883EC40");
            EnsurePartyPatch(h, image + 0x5136D00, ui, site =>
                Combine(Hex("F681C4060000017501C3"), ui, IndirectJump(site + ui.Length)));
            byte[] death = Hex("488BC4554156488D68A14881EC88000000");
            long deathCave = EnsurePartyPatch(h, image + 0x50F1000, death, site =>
                Combine(Hex("803DF9000000007408C681D806000001C3"),
                    death, IndirectJump(site + death.Length)));
            byte[] heal = Hex("488BC455535657415441564157488D68A1");
            byte[] AbsCall(long addr) => Combine(Hex("48B8"), Address(addr), Hex("FFD0"));
            byte[] special = Combine(Hex("4883EC384889542420"), AbsCall(image + 0x50DE260),
                Hex("4885C07419488B542420F30F104A08488BC8"), AbsCall(image + 0x5104AB0),
                Hex("4883C438C3"));
            byte[] compare = Combine(Hex("817A0C"), BitConverter.GetBytes(-1234567.0f),
                new byte[] { 0x75, checked((byte)special.Length) });
            long healCave = EnsurePartyPatch(h, image + 0x50F9120, heal, site =>
                Combine(Hex("803DF90000000074"), new byte[] { checked((byte)(compare.Length + special.Length)) },
                    compare, special, heal, IndirectJump(site + heal.Length)));
            return new PartyHandle(pid, deathCave, healCave);
        }
        finally { CloseHandle(h); }
    }

    internal static string Apply(int pid, string exactExe, bool dryRun = false)
    {
        VerifyGame(exactExe);
        using var target = Process.GetProcessById(pid);
        target.Refresh();
        var actual = target.MainModule?.FileName
            ?? throw new InvalidOperationException("Не удалось определить исполняемый файл процесса.");
        if (!string.Equals(Path.GetFullPath(actual), Path.GetFullPath(exactExe),
            StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("Процесс не соответствует выбранной копии игры.");
        var baseAddress = target.MainModule.BaseAddress.ToInt64();
        var handle = OpenProcess(Access, false, pid);
        if (handle == nint.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "OpenProcess");
        try
        {
            // Validate all instructions before changing any bytes.
            CheckBytes(handle, baseAddress, 0x51291F0, FloatOriginal);
            CheckBytes(handle, baseAddress, 0x5117920, RegisterOriginal);
            CheckBytes(handle, baseAddress, 0x5133C90, AttributeSyncOriginal);
            CheckBytes(handle, baseAddress, 0x50EA407, MageBeginOriginal);
            CheckBytes(handle, baseAddress, 0x510CC99, MageControllerOriginal);
            if (dryRun) CheckBytes(handle, baseAddress, 0x51D6859, DetectionDeactivateOriginal);
            if (dryRun) return "GUARDS_VERIFIED";

            // Null difficulty component: avoid a crash; actual component gets the original getter.
            Patch(handle, baseAddress + 0x51291F0, FloatOriginal, site =>
                Combine(Hex("4885C975040F57C0C3"), FloatOriginal,
                    MoveRaxJump(site + FloatOriginal.Length)), false);

            // Null ability component: there is no attribute array to register with.
            Patch(handle, baseAddress + 0x5117920, RegisterOriginal, site =>
                Combine(Hex("4885C97501C3"), RegisterOriginal,
                    MoveRaxJump(site + RegisterOriginal.Length)), false);

            // Server-side spell/attribute callbacks can arrive before the
            // replicated guest attribute set exists. The original native entry
            // dereferences its null this pointer at +0x3a8 and crashes. Skip
            // only the impossible call; keep all nonnull gameplay untouched.
            Patch(handle, baseAddress + 0x5133C90, AttributeSyncOriginal, site =>
                Combine(Hex("4885C97501C3"), AttributeSyncOriginal,
                    IndirectJump(site + AttributeSyncOriginal.Length)), true);

            // Unpossessed client mage: skip only controller delegate binding during BeginPlay.
            Patch(handle, baseAddress + 0x50EA407, MageBeginOriginal, site =>
                Combine(Hex("4885C9741E"), MageBeginOriginal,
                    IndirectJump(site + MageBeginOriginal.Length),
                    IndirectJump(site + MageBeginOriginal.Length + 5)), true);

            // Unpossessed client mage: use the original fallback branch instead of reading +0x912.
            Patch(handle, baseAddress + 0x510CC99, MageControllerOriginal, site =>
                Combine(Hex("488B81900700004885C07415"),
                    Hex("80B81209000000"),
                    IndirectJump(site + MageControllerOriginal.Length),
                    IndirectJump(baseAddress + 0x510CCB5)), true);

            // Keep the native deactivation and cleanup, skipping only the virtual
            // call when the replicated dependency at +0xc0 is absent.
            EnsureDetectionGuard(handle, baseAddress);

            return "GUARDS_INSTALLED";
        }
        finally
        {
            CloseHandle(handle);
        }
    }
}
