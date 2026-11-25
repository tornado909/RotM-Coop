using System.Globalization;

namespace RotMSteamBridge;

// The session supplies the sender out of band. Only the host can send presentation.
internal sealed class CombatEvents
{
    private const int SampleLifetimeSeconds = 2;
    private const int EventLifetimeSeconds = 6;
    private const int PeerInputLimit = 256;
    private const int EffectEventLimit = 1024;
    private const int ActiveEffectLimit = 256;

    internal readonly record struct Message(string Text, string Kind, uint Sequence, string Effect, string Phase)
    {
        public bool FromGuest => Kind is "I" or "M";
        public bool Reliable => Kind == "I" || Kind == "X" && Phase != "U";
    }

    private readonly record struct Timed(Message Message, DateTime At);
    private readonly Dictionary<ulong, (Queue<Timed> Events, uint Sequence)> input = new();
    private readonly Dictionary<ulong, (Timed? Sample, uint Sequence)> aim = new();
    private readonly Queue<Timed> effectEvents = new();
    private readonly Dictionary<string, Message> effectStates = new();
    private readonly Dictionary<string, DateTime> endedEffects = new();
    private readonly Dictionary<string, Message> effectUpdates = new();

    public bool Dirty { get; private set; } = true;

    private static bool ParsePositive(string text, out uint number) =>
        uint.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out number) && number > 0;

    private static bool IsInRange(string text, double min, double max) =>
        double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out double value) &&
        double.IsFinite(value) && value >= min && value <= max;

    private static bool Vector(string[] fields, int start, double min, double max)
    {
        return IsInRange(fields[start], min, max) && IsInRange(fields[start + 1], min, max) &&
            IsInRange(fields[start + 2], min, max);
    }

    private static bool Aim(string[] fields, int start)
    {
        int end = fields.Length;
        if (end >= start + 10 && fields[end - 4] == "C")
        {
            if (!Vector(fields, end - 3, -360, 360)) return false;
            end -= 4;
        }
        return (end == start + 6 || end == start + 9) &&
            Vector(fields, start, -1_000_000, 1_000_000) &&
            Vector(fields, start + 3, -360, 360) &&
            (end == start + 6 || Vector(fields, start + 6, -1_000_000, 1_000_000));
    }

    private static bool Transform(string[] fields, int start)
    {
        return Vector(fields, start, -1_000_000, 1_000_000) &&
            Vector(fields, start + 3, -360, 360) &&
            Vector(fields, start + 6, -100, 100);
    }

    private static bool AssetPath(string value) =>
        value.Length <= 220 && value.StartsWith("/Game/", StringComparison.Ordinal) &&
        !value.Contains("..", StringComparison.Ordinal) && value.Contains('.') &&
        value.All(c => char.IsAsciiLetterOrDigit(c) || c is '/' or '_' or '.' or '-');

    private static bool Parameters(string value) =>
        value.Length is > 0 and <= 512 &&
        value.All(c => char.IsAsciiLetterOrDigit(c) || c is '_' or '.' or ':' or ';' or ',' or '=' or '+' or '-');

    public static bool TryParse(string text, uint epoch, out Message message)
    {
        message = default;
        if (text.Length > 1000 || text.Any(c => c < '!' || c > '~')) return false;
        string[] p = text.Split('|');
        if (p.Length < 3 || !ParsePositive(p[1], out uint activeEpoch) || activeEpoch != epoch) return false;
        if (p[0] is "I" or "M")
        {
            if (!ParsePositive(p[2], out uint inputSequence)) return false;
            bool valid = p[0] == "I"
                ? Aim(p, 5) && ParsePositive(p[3], out uint slot) && slot <= 8 && p[4] is "P" or "R"
                : Aim(p, 3);
            if (valid) message = new(text, p[0], inputSequence, "", "");
            return valid;
        }

        if (p[0] != "X" || p.Length < 7 ||
            !ParsePositive(p[2], out uint player) || player > int.MaxValue ||
            !ParsePositive(p[3], out uint cast) || !ParsePositive(p[4], out uint effect) ||
            !ParsePositive(p[5], out uint sequence)) return false;
        bool validEffect = p[6] switch
        {
            "B" => p.Length is 18 or 19 && AssetPath(p[7]) && Transform(p, 8) &&
                uint.TryParse(p[17], NumberStyles.None, CultureInfo.InvariantCulture, out uint ms) &&
                ms <= 600_000 && (p.Length == 18 || Parameters(p[18])),
            "U" => p.Length is 16 or 17 && Transform(p, 7) &&
                (p.Length == 16 || Parameters(p[16])),
            "E" => p.Length == 7,
            _ => false
        };
        if (validEffect) message = new(text, "X", sequence, $"{player}|{cast}|{effect}", p[6]);
        return validEffect;
    }

    public void Receive(ulong peer, Message message, DateTime now)
    {
        if (message.Kind == "M")
        {
            if (aim.TryGetValue(peer, out var old) && message.Sequence <= old.Sequence) return;
            aim[peer] = (new Timed(message, now), message.Sequence);
        }
        else if (message.Kind == "I")
        {
            if (!input.TryGetValue(peer, out var buffered))
            {
                buffered = (new(), 0);
            }
            if (message.Sequence <= buffered.Sequence) return;
            if (buffered.Events.Count == PeerInputLimit) buffered.Events.Dequeue();
            buffered.Events.Enqueue(new(message, now));
            input[peer] = (buffered.Events, message.Sequence);
        }
        else if (!ReceiveEffect(message, now)) return;
        Dirty = true;
    }

    private bool ReceiveEffect(Message message, DateTime now)
    {
        bool found = effectStates.TryGetValue(message.Effect, out Message state);
        if (message.Phase == "U")
        {
            if (!found || message.Sequence <= state.Sequence ||
                effectUpdates.TryGetValue(message.Effect, out Message update) && message.Sequence <= update.Sequence)
                return false;
            effectUpdates[message.Effect] = message;
            return true;
        }
        if (message.Phase == "B")
        {
            if (found || endedEffects.ContainsKey(message.Effect) || effectStates.Count >= ActiveEffectLimit) return false;
            effectStates[message.Effect] = message;
        }
        else
        {
            if (!found || message.Sequence <= state.Sequence) return false;
            effectStates.Remove(message.Effect);
            endedEffects[message.Effect] = now;
            effectUpdates.Remove(message.Effect);
        }
        if (effectEvents.Count == EffectEventLimit) effectEvents.Dequeue();
        effectEvents.Enqueue(new(message, now));
        return true;
    }

    public void Clear()
    {
        input.Clear();
        aim.Clear();
        effectEvents.Clear();
        effectStates.Clear();
        endedEffects.Clear();
        effectUpdates.Clear();
        Dirty = true;
    }

    public void Expire(DateTime now, Func<ulong, bool> peerVerified)
    {
        DateTime eventsAfter = now.AddSeconds(-EventLifetimeSeconds);
        DateTime samplesAfter = now.AddSeconds(-SampleLifetimeSeconds);
        foreach (var (peer, buffered) in input.ToArray())
        {
            if (!peerVerified(peer)) { input.Remove(peer); Dirty = true; continue; }
            Dirty |= Expire(buffered.Events, eventsAfter);
        }
        foreach (var (peer, buffered) in aim.ToArray())
        {
            if (!peerVerified(peer))
            {
                aim.Remove(peer);
                Dirty |= buffered.Sample.HasValue;
            }
            else if (buffered.Sample is Timed sample && sample.At < samplesAfter)
            {
                aim[peer] = (null, buffered.Sequence);
                Dirty = true;
            }
        }
        Dirty |= Expire(effectEvents, eventsAfter);
        foreach (var (key, endedAt) in endedEffects.ToArray())
            if (endedAt < eventsAfter) endedEffects.Remove(key);
    }

    private static bool Expire(Queue<Timed> queue, DateTime from)
    {
        bool changed = false;
        while (queue.TryPeek(out Timed next) && next.At < from)
        {
            queue.Dequeue();
            changed = true;
        }
        return changed;
    }

    public string Snapshot() => string.Join("\n",
        input.SelectMany(pair => pair.Value.Events.Select(item => item.Message.Text + "|" + pair.Key))
            .Concat(aim.Where(pair => pair.Value.Sample.HasValue)
                .Select(pair => pair.Value.Sample.GetValueOrDefault().Message.Text + "|" + pair.Key))
            .Concat(effectEvents.Select(item => item.Message.Text))
            .Concat(effectStates.Values.Select(item => item.Text))
            .Distinct(StringComparer.Ordinal)
            .Concat(effectUpdates.Values.Select(item => item.Text)));

    public void MarkFlushed() => Dirty = false;
}
