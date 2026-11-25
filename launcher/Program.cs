using System.Diagnostics;
using System.Drawing;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;

namespace RotMCoopLauncher;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length == 3 && (args[0] == "--apply-guard" || args[0] == "--verify-guard"))
        {
            try
            {
                NativeGuards.Apply(int.Parse(args[1]), args[2], args[0] == "--verify-guard");
                return 0;
            }
            catch (Exception ex)
            {
                Console.Error.WriteLine(ex);
                return 1;
            }
        }

        ApplicationConfiguration.Initialize();
        Application.Run(new CoopForm());
        return 0;
    }
}

internal sealed class CoopForm : Form
{
    private readonly TextBox root = new()
    {
        Dock = DockStyle.Fill,
        Text = AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar)
    };
    private readonly TextBox server = new() { Dock = DockStyle.Fill, Text = "127.0.0.1" };
    private readonly NumericUpDown port = new()
    {
        Minimum = 1024, Maximum = 65535, Value = 7777, Dock = DockStyle.Fill
    };
    private readonly Label status = new()
    {
        Dock = DockStyle.Fill,
        Text = "Укажите папку с установленным модом.",
        AutoSize = false,
        TextAlign = ContentAlignment.MiddleLeft
    };
    private readonly Button host = new() { Text = "Создать игру", Dock = DockStyle.Fill };
    private readonly Button join = new() { Text = "Подключиться", Dock = DockStyle.Fill };
    private Process? running;

    public CoopForm()
    {
        Text = "Revenge of the Mage | Co-op";
        Width = 700;
        Height = 345;
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(630, 315);
        BackColor = Color.FromArgb(21, 24, 30);
        ForeColor = Color.FromArgb(230, 235, 245);
        Font = new Font("Segoe UI", 10);
        AutoScaleMode = AutoScaleMode.Font;

        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill,
            Padding = new Padding(18, 18, 18, 15),
            ColumnCount = 3,
            RowCount = 6,
            BackColor = BackColor
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 145));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 128));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 45));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 45));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 45));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 62));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.Absolute, 10));

        var browse = new Button { Text = "Обзор", Dock = DockStyle.Fill };
        browse.Click += (_, _) =>
        {
            using var chooser = new FolderBrowserDialog
            {
                Description = "Папка Revenge of the Mage с RevengeOfTheMage/Binaries/Win64",
                InitialDirectory = Directory.Exists(root.Text) ? root.Text : AppContext.BaseDirectory
            };
            if (chooser.ShowDialog(this) == DialogResult.OK) root.Text = chooser.SelectedPath;
        };
        layout.Controls.Add(MakeLabel("Папка игры"), 0, 0);
        layout.Controls.Add(root, 1, 0);
        layout.Controls.Add(browse, 2, 0);
        layout.Controls.Add(MakeLabel("IP / адрес хоста"), 0, 1);
        layout.Controls.Add(server, 1, 1);
        layout.Controls.Add(MakeLabel("Порт UDP"), 0, 2);
        layout.Controls.Add(port, 1, 2);

        host.BackColor = Color.FromArgb(38, 92, 85);
        join.BackColor = Color.FromArgb(51, 87, 145);
        host.ForeColor = Color.White;
        join.ForeColor = Color.White;
        host.FlatStyle = FlatStyle.Flat;
        join.FlatStyle = FlatStyle.Flat;
        host.FlatAppearance.BorderSize = 0;
        join.FlatAppearance.BorderSize = 0;
        var buttons = new TableLayoutPanel
        {
            ColumnCount = 2, Dock = DockStyle.Fill, RowCount = 1, BackColor = BackColor
        };
        buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        buttons.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 50));
        buttons.Controls.Add(host, 0, 0);
        buttons.Controls.Add(join, 1, 0);
        layout.Controls.Add(buttons, 1, 3);
        layout.Controls.Add(status, 1, 4);
        layout.SetColumnSpan(status, 2);
        Controls.Add(layout);

        root.BackColor = Color.FromArgb(38, 43, 52);
        root.ForeColor = ForeColor;
        server.BackColor = root.BackColor;
        server.ForeColor = ForeColor;
        port.BackColor = root.BackColor;
        port.ForeColor = ForeColor;
        host.Click += async (_, _) => await StartSession(isHost: true);
        join.Click += async (_, _) => await StartSession(isHost: false);
    }

    private static Label MakeLabel(string text) => new()
    {
        Text = text, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft
    };

    private static void Configure(string configPath, string address, bool isHost, int delay)
    {
        var text = File.ReadAllText(configPath, Encoding.UTF8);
        string Change(string input, string pattern, string newValue)
        {
            var count = 0;
            var result = Regex.Replace(input, pattern, m =>
            {
                count++;
                return m.Groups[1].Value + newValue;
            });
            if (count != 1)
                throw new InvalidOperationException("Неожиданное содержимое config.lua. Проверьте установку мода.");
            return result;
        }
        text = Change(text,
            @"(?m)^(\s*join_address\s*=\s*)""[^""]*""",
            "\"" + address + "\"");
        text = Change(text,
            @"(?m)^(\s*auto_action\s*=\s*)(nil|""(?:host|join)"")",
            isHost ? "\"host\"" : "\"join\"");
        text = Change(text,
            @"(?m)^(\s*auto_delay_ms\s*=\s*)\d+",
            delay.ToString());
        var temp = configPath + ".rotm-new";
        File.WriteAllText(temp, text, new UTF8Encoding(false));
        File.Move(temp, configPath, true);
    }

    private async Task StartSession(bool isHost)
    {
        if (running is { HasExited: false })
        {
            status.Text = "Игра уже запущена этим лаунчером.";
            return;
        }
        var dir = root.Text.Trim();
        var address = server.Text.Trim();
        var udp = (int)port.Value;
        if (!Regex.IsMatch(address, @"^[A-Za-z0-9][A-Za-z0-9.-]*$"))
        {
            status.Text = "Введите корректный IPv4-адрес или DNS-имя хоста.";
            return;
        }
        host.Enabled = false;
        join.Enabled = false;
        status.Text = "Проверка игры и подготовка подключения...";
        try
        {
            running = await Task.Run(() =>
            {
                var gameRoot = Path.GetFullPath(dir);
                var win64 = Path.Combine(gameRoot, "RevengeOfTheMage", "Binaries", "Win64");
                var exe = Path.Combine(win64, "RevengeOfTheMage-Win64-Shipping.exe");
                var loader = Path.Combine(win64, "ue4ss", "UE4SS.dll");
                var scripts = Path.Combine(win64, "ue4ss", "Mods", "RotMCoop", "Scripts");
                var config = Path.Combine(scripts, "config.lua");
                NativeGuards.VerifyGame(exe);
                foreach (var required in new[] { loader, config,
                    Path.Combine(scripts, "main.lua"), Path.Combine(scripts, "early_controller.lua") })
                    if (!File.Exists(required))
                        throw new FileNotFoundException("Отсутствует компонент мода. Установите RotMCoop и UE4SS.", required);

                Configure(config, address + ":" + udp, isHost, isHost ? 8000 : 18000);
                var profile = Path.Combine(gameRoot, "RotMCoopProfile");
                Directory.CreateDirectory(profile);
                var psi = new ProcessStartInfo
                {
                    FileName = exe,
                    WorkingDirectory = win64,
                    UseShellExecute = false,
                    Arguments = $"-nosteam -dx11 -windowed -NoSplash -port={udp} " +
                        $"--ue4ss-path \"{loader}\" -userdir=\"{profile}\""
                };
                psi.Environment.Remove("UE4SS_MODS_PATHS");
                var process = Process.Start(psi)
                    ?? throw new InvalidOperationException("Не удалось запустить игру.");
                if (!isHost)
                {
                    try
                    {
                        NativeGuards.Apply(process.Id, exe);
                    }
                    catch
                    {
                        if (!process.HasExited) process.Kill();
                        throw;
                    }
                }
                return process;
            });
            status.Text = isHost
                ? $"Хост запущен. UDP {udp}; адрес передайте друзьям."
                : $"Подключение к {address}:{udp} запущено.";
        }
        catch (Exception ex)
        {
            status.Text = "Ошибка: " + ex.Message;
        }
        finally
        {
            host.Enabled = true;
            join.Enabled = true;
        }
    }
}
