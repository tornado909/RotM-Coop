using RotMSteamBridge;

const uint epoch = 41;
var now = new DateTime(2026, 11, 25, 8, 0, 0, DateTimeKind.Utc);
var host = new CombatEvents();
var guest = new CombatEvents();

static void Require(bool condition, string name)
{
    if (!condition) throw new InvalidOperationException(name);
}

CombatEvents.Message Message(string text, bool fromGuest, bool reliable)
{
    Require(CombatEvents.TryParse(text, epoch, out var message), "Failed to parse " + text);
    Require(message.FromGuest == fromGuest && message.Reliable == reliable, "Incorrect message class " + text);
    return message;
}

string[] Rows(CombatEvents buffer) =>
    buffer.Snapshot().Split('\n', StringSplitOptions.RemoveEmptyEntries);

string press = $"I|{epoch}|1|1|P|10|20|30|75|5|7|50|60|70";
string release = $"I|{epoch}|2|1|R|10|20|30|-80|10|8";
string aim = $"M|{epoch}|3|10|20|30|-80|10|8";
var pressMessage = Message(press, true, true);
var releaseMessage = Message(release, true, true);
var aimMessage = Message(aim, true, false);
Message(aim + "|C|-79|11|3", true, false);
Message(press + "|C|77|-20|3", true, true);
Require(!CombatEvents.TryParse(aim + "|C|361|11|3", epoch, out _), "Invalid camera pitch was accepted");

// Three remote mages send identical sequences at the same time.
for (ulong peer = 2; peer <= 4; ++peer)
{
    host.Receive(peer, pressMessage, now);
    host.Receive(peer, releaseMessage, now);
    host.Receive(peer, pressMessage, now);
    host.Receive(peer, aimMessage, now);
    host.Receive(peer, Message(aim.Replace("|3|", "|2|"), true, false), now);
}
Require(Rows(host).Length == 9, "Input/aim duplicate leaked or distinct guest collapsed");
for (ulong peer = 2; peer <= 4; ++peer)
{
    string[] expected = [$"{press}|{peer}", $"{release}|{peer}", $"{aim}|{peer}"];
    Require(Rows(host).Where(row => row.EndsWith($"|{peer}", StringComparison.Ordinal)).SequenceEqual(expected),
        "Guest identity or edge order");
}
host.Expire(now.AddSeconds(3), peer => peer != 3);
host.Receive(2, Message(aim.Replace("|3|", "|2|"), true, false), now.AddSeconds(3));
Require(Rows(host).SequenceEqual([$"{press}|2", $"{release}|2", $"{press}|4", $"{release}|4"]),
    "Disconnected sender, expired aim or stale reordered aim survived");

// Cast and effect counters are local to the mage. All four reuse them.
for (uint player = 1; player <= 4; ++player)
{
    string key = $"X|{epoch}|{player}|501|601";
    string optionalParameters = "Size:f:4";
    var begin = Message(key + "|1|B|/Game/FX/NS_Test.NS_Test|10|20|30|75|5|7|1|1|1|2500|" +
        optionalParameters, false, true);
    var update = Message(key + "|4|U|40|50|60|-80|15|7|-2|2|2", false, false);
    var previousUpdate = Message(key + "|2|U|40|50|60|-80|15|7|2|2|2", false, false);
    guest.Receive(1, previousUpdate, now); // A sample by itself does not create an effect.
    guest.Receive(1, begin, now);
    guest.Receive(1, begin, now);
    guest.Receive(1, update, now);
    guest.Receive(1, previousUpdate, now);
}
Require(Rows(guest).Length == 8 && Rows(guest).Count(row => row.Contains("|4|U|", StringComparison.Ordinal)) == 4,
    "Effect identity or newest sample was not preserved");
guest.Expire(now.AddSeconds(7), _ => true);
string[] active = Rows(guest);
Require(active.Length == 8 && active.Take(4).All(row => row.Contains("|1|B|", StringComparison.Ordinal)) &&
    active.Skip(4).All(row => row.Contains("|4|U|", StringComparison.Ordinal)),
    "Current active start or transform vanished with old transient events");

for (uint player = 1; player <= 4; ++player)
{
    var end = Message($"X|{epoch}|{player}|501|601|5|E", false, true);
    guest.Receive(1, end, now.AddSeconds(7));
    guest.Receive(1, end, now.AddSeconds(7));
    guest.Receive(1, Message(active[player - 1], false, true), now.AddSeconds(7));
}
Require(Rows(guest).Length == 4 && Rows(guest).All(row => row.EndsWith("|5|E", StringComparison.Ordinal)),
    "End state duplicated or resurrected a retired effect");

Require(!CombatEvents.TryParse(press, epoch + 1, out _), "Stale world was accepted");
Require(!CombatEvents.TryParse(aim.Replace("-80", "Infinity"), epoch, out _), "Nonfinite angle was accepted");
Require(!CombatEvents.TryParse(press + "|123", epoch, out _), "Claimed sender was accepted");
Require(!CombatEvents.TryParse(active[0].Replace("/Game/FX/", "/Game/../"), epoch, out _), "Invalid asset accepted");
guest.Clear();
Require(Rows(guest).Length == 0 && guest.Dirty, "Invalidated combat state remained in the snapshot");
Console.WriteLine("COMBAT_TRANSPORT_FOUR_MAGES_PASS");

// Enemy state has no guest authority; per-recipient batches replace only older samples.
var enemies = new CombatEvents();
var enemyOld = Message($"N|{epoch}|1|258|0|17:11575:11575:BP_Ghoul_C:1200:1200:0", false, false);
var enemyDead = Message($"N|{epoch}|2|258|0|17:11575:11575:BP_Ghoul_C:0:1200:1", false, false);
var enemyOther = Message($"N|{epoch}|3|259|0|17:11575:11575:BP_Ghoul_C:900:900:0", false, false);
enemies.Receive(1, enemyOld, now);
enemies.Receive(1, enemyDead, now);
enemies.Receive(1, enemyOld, now);
enemies.Receive(1, enemyOther, now);
Require(Rows(enemies).Length == 2 && Rows(enemies).Contains(enemyDead.Text) && Rows(enemies).Contains(enemyOther.Text), "Enemy batch order or recipient isolation");
Require(!CombatEvents.TryParse($"N|{epoch}|3|258|0|17:11575:11575:BP_Ghoul_C:1201:1200:0",epoch,out _), "Enemy over-max");
enemies.Expire(now.AddSeconds(3), _ => true);
Require(Rows(enemies).Length == 0, "Expired enemy snapshot");
Console.WriteLine("ENEMY SNAPSHOT TRANSPORT OK");
