using System.Buffers.Binary;

namespace RotMSteamBridge;

/// <summary>
/// A bounded datagram framing format for Steam's legacy P2P Unreliable send.
/// Each fragment stays below 1200 B; order and loss are harmless to packet recovery.
/// </summary>
internal static class SteamWire
{
    public const int FragmentPayload = 1024;
    public const int HeaderSize = 15;
    public const int MaxDatagram = 65507;
    private static ReadOnlySpan<byte> Magic => "RMG4"u8;

    public static IReadOnlyList<byte[]> Encode(ReadOnlySpan<byte> datagram, uint sequence)
    {
        if (datagram.Length < 1 || datagram.Length > MaxDatagram)
            throw new ArgumentOutOfRangeException(nameof(datagram));
        int count = (datagram.Length + FragmentPayload - 1) / FragmentPayload;
        var frames = new List<byte[]>(count);
        for (int i = 0; i < count; ++i)
        {
            int offset = i * FragmentPayload;
            int size = Math.Min(FragmentPayload, datagram.Length - offset);
            byte[] frame = new byte[HeaderSize + size];
            Magic.CopyTo(frame);
            frame[4] = 1;
            BinaryPrimitives.WriteUInt32LittleEndian(frame.AsSpan(5), sequence);
            BinaryPrimitives.WriteUInt16LittleEndian(frame.AsSpan(9), (ushort)i);
            BinaryPrimitives.WriteUInt16LittleEndian(frame.AsSpan(11), (ushort)count);
            BinaryPrimitives.WriteUInt16LittleEndian(frame.AsSpan(13), (ushort)datagram.Length);
            datagram.Slice(offset, size).CopyTo(frame.AsSpan(HeaderSize));
            frames.Add(frame);
        }
        return frames;
    }

    public static bool TryHeader(ReadOnlySpan<byte> frame, out uint sequence, out int index,
        out int count, out int total)
    {
        sequence = 0; index = count = total = 0;
        if (frame.Length < HeaderSize || !frame[..4].SequenceEqual(Magic) || frame[4] != 1)
            return false;
        sequence = BinaryPrimitives.ReadUInt32LittleEndian(frame[5..]);
        index = BinaryPrimitives.ReadUInt16LittleEndian(frame[9..]);
        count = BinaryPrimitives.ReadUInt16LittleEndian(frame[11..]);
        total = BinaryPrimitives.ReadUInt16LittleEndian(frame[13..]);
        if (total < 1 || total > MaxDatagram || count < 1 ||
            count != (total + FragmentPayload - 1) / FragmentPayload || index >= count)
            return false;
        int expected = Math.Min(FragmentPayload, total - index * FragmentPayload);
        return frame.Length == HeaderSize + expected;
    }

    public static void SelfTest()
    {
        var rng = new Random(0x1234ab);
        foreach (int n in new[] { 1, 13, 600, 1024, 1025, 1200, 4096, 8192, 65507 })
        {
            byte[] src = new byte[n]; rng.NextBytes(src);
            var frames = Encode(src, (uint)n);
            var restored = new byte[n];
            foreach (var frame in frames.Reverse())
            {
                if (frame.Length > 1200 || !TryHeader(frame, out uint seq, out int ix, out int count, out int total) ||
                    seq != (uint)n || count != frames.Count || total != n)
                    throw new Exception("Steam fragment header test failed: " + n);
                frame.AsSpan(HeaderSize).CopyTo(restored.AsSpan(ix * FragmentPayload));
            }
            if (!src.AsSpan().SequenceEqual(restored)) throw new Exception("Datagram mismatch: " + n);
            foreach (var f in frames)
            {
                var invalid = (byte[])f.Clone(); invalid[4] = 99;
                if (TryHeader(invalid, out _, out _, out _, out _))
                    throw new Exception("Invalid version accepted");
            }
        }
        foreach (int n in new[] { 1, 900, 1025, 4096, 65507 })
        {
            byte[] src = new byte[n]; rng.NextBytes(src);
            var decoder = new SteamReassembly();
            var fragments = Encode(src, (uint)n);
            DateTime at = DateTime.UtcNow;
            byte[]? output = null;
            for (int i = fragments.Count - 1; i >= 0; --i)
            {
                byte[]? first = decoder.Accept(4567, fragments[i], at);
                byte[]? duplicate = decoder.Accept(4567, fragments[i], at);
                if (i != 0 && (first != null || duplicate != null))
                    throw new Exception("Premature datagram reconstruction");
                if (first != null) output = first;
                if (duplicate != null) throw new Exception("Duplicate reassembly accepted");
            }
            if (output == null || !src.AsSpan().SequenceEqual(output))
                throw new Exception("Out-of-order peer reassembly failed");
        }
        Console.WriteLine("WIRE_SELFTEST_PASS: size, reverse order, duplicate, fragmentation, 1200B MTU");
    }
}

/// <summary>Per-peer, per-sequence reassembly; limits memory when frames are missing.</summary>
internal sealed class SteamReassembly
{
    private sealed class Pending
    {
        public required byte[] Data;
        public required bool[] Seen;
        public required DateTime Started;
        public int SeenCount;
    }

    private readonly Dictionary<(ulong peer, uint seq), Pending> inflight = new();
    private readonly Dictionary<(ulong peer, uint seq), DateTime> completed = new();
    private DateTime lastCleanup = DateTime.MinValue;
    public int PendingCount => inflight.Count;

    public byte[]? Accept(ulong peer, ReadOnlySpan<byte> frame, DateTime now)
    {
        if (!SteamWire.TryHeader(frame, out uint seq, out int ix, out int count, out int total))
            return null;
        if (now - lastCleanup > TimeSpan.FromSeconds(3))
        {
            lastCleanup = now;
            foreach (var k in inflight.Where(x => now - x.Value.Started >
                         TimeSpan.FromSeconds(5)).Select(x => x.Key).ToArray())
                inflight.Remove(k);
            foreach (var k in completed.Where(x => now - x.Value >
                         TimeSpan.FromSeconds(12)).Select(x => x.Key).ToArray())
                completed.Remove(k);
        }
        if (completed.ContainsKey((peer, seq))) return null;
        if (inflight.Count > 96)
        {
            foreach (var key in inflight.Where(x => now - x.Value.Started > TimeSpan.FromSeconds(4))
                         .Select(x => x.Key).ToArray()) inflight.Remove(key);
            if (inflight.Count > 96)
                inflight.Remove(inflight.OrderBy(x => x.Value.Started).First().Key);
        }
        var key2 = (peer, seq);
        if (!inflight.TryGetValue(key2, out var pending))
        {
            pending = new Pending { Data = new byte[total], Seen = new bool[count], Started = now };
            inflight[key2] = pending;
        }
        if (pending.Data.Length != total || pending.Seen.Length != count)
        {
            inflight.Remove(key2);
            return null;
        }
        if (!pending.Seen[ix])
        {
            frame[SteamWire.HeaderSize..].CopyTo(pending.Data.AsSpan(ix * SteamWire.FragmentPayload));
            pending.Seen[ix] = true;
            ++pending.SeenCount;
        }
        if (pending.SeenCount != count) return null;
        inflight.Remove(key2);
        if (completed.Count > 2048) completed.Clear();
        completed[key2] = now;
        return pending.Data;
    }
    public void Clear()
    {
        inflight.Clear();
        completed.Clear();
        lastCleanup = DateTime.MinValue;
    }
}