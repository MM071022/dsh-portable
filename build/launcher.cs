// dsh portable launcher — self-extracting single-file exe.
// Embeds dsh.zip (full dsh package) and node.zip (node.exe); on first run
// extracts them to %LOCALAPPDATA%\dsh-portable\<version> and executes
// `node <install>\dsh\lib\bin.js <args...>`.
//
// Web mode (no args, `web`, or `--profile web`):
//   * If a server is already listening on the target port (default 3080),
//     just opens the browser to it and exits — repeated double-clicks are
//     idempotent and never spawn a duplicate server.
//   * Otherwise boots `dsh web`, watches its `dsh web: http://...` URL line,
//     and opens the default browser there (covers --port and --port 0).
// With no args (double-click) it boots the web UI, mirroring `dsh web`.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

class DshLauncher
{
    const string Version = "0.1.0-rc.8";
    const string Repo = "MM071022/dsh-portable";
    const string DefaultPort = "3080";

    static int Main(string[] args)
    {
        try
        {
            string root = Environment.GetEnvironmentVariable("DSH_EXE_HOME");
            if (string.IsNullOrEmpty(root))
                root = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "dsh-exe");
            string install = Path.Combine(root, Version);
            string dataRoot = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                ".dsh");
            string marker = Path.Combine(install, ".extracted.ok");
            string dshDir = Path.Combine(install, "dsh");
            string nodeExe = Path.Combine(install, "node.exe");
            string entry = Path.Combine(dshDir, "lib", "bin.js");

            if (!File.Exists(marker))
            {
                Console.Error.WriteLine("dsh: first run — extracting runtime to " + install);
                if (Directory.Exists(install))
                {
                    // A previous/partial extraction must not shadow the embedded
                    // package (e.g. an older dsh copy with a stale bug): clean
                    // it first. If a server is currently running from this
                    // directory, the delete fails and we extract over instead.
                    try { Directory.Delete(install, true); }
                    catch (Exception ex)
                    {
                        Console.Error.WriteLine("dsh: could not clean previous extraction (" + ex.Message + "); extracting over it");
                    }
                }
                Directory.CreateDirectory(install);
                ExtractResource("dsh.zip", install);
                ExtractResource("node.zip", install);
                File.WriteAllText(marker, DateTime.UtcNow.ToString("o"));
                Console.Error.WriteLine("dsh: extraction complete");
            }
            if (!File.Exists(nodeExe))
                throw new Exception("node.exe missing after extraction: " + nodeExe);
            if (!File.Exists(entry))
                throw new Exception("dsh entry missing after extraction: " + entry);

            var passthrough = new List<string>(args);
            bool webMode = passthrough.Count == 0 || passthrough[0] == "web" || IsProfileWeb(passthrough);
            if (passthrough.Count == 0) passthrough.Add("web");

            if (webMode)
            {
                string port = FindPort(passthrough);
                if (port != "0" && DshWebOpen(port))
                {
                    // A dsh web server is already running on that port.
                    OpenBrowser("http://127.0.0.1:" + port);
                    return 0;
                }
                // Single-instance fence per data root: two dsh servers writing
                // the same ~/.dsh session logs concurrently corrupt them
                // (rewound seq blocks → "历史加载失败" / history load failure).
                // The port check above only covers same-port duplicates, so a
                // second instance on another port must be refused here.
                bool createdNew;
                using (var singleInstance = new Mutex(true, MutexName(dataRoot), out createdNew))
                {
                    if (!createdNew)
                    {
                        Console.Error.WriteLine("dsh: another dsh web instance is already running for this data directory (" + dataRoot + "); stop it before starting another (running two servers corrupts session history).");
                        return 1;
                    }
                    CheckForUpdate();
                    return RunWeb(entry, nodeExe, passthrough);
                }
            }
            return RunPlain(entry, nodeExe, passthrough);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("dsh.exe: " + ex.Message);
            return 1;
        }
    }

    static bool IsProfileWeb(List<string> args)
    {
        for (int i = 0; i < args.Count - 1; i++)
            if (args[i] == "--profile" && args[i + 1] == "web") return true;
        return false;
    }

    /// Derive a stable per-user mutex name from the data root. `root` already
    /// includes the user's LOCALAPPDATA (or an explicit DSH_EXE_HOME), so a
    /// sanitized hash of it is unique per user/machine without extra privileges.
    static string MutexName(string root)
    {
        var sb = new StringBuilder("Local\\dsh-exe-");
        foreach (char c in root)
        {
            sb.Append(char.IsLetterOrDigit(c) ? c : '_');
        }
        return sb.ToString();
    }

    /// Best-effort "new version available" notice. Queries the GitHub Releases
    /// API with a short timeout so it can never stall startup; on any failure
    /// (offline, rate-limited, parse error) it silently does nothing.
    static void CheckForUpdate()
    {
        try
        {
            var req = (HttpWebRequest)WebRequest.Create(
                "https://api.github.com/repos/" + Repo + "/releases/latest");
            req.UserAgent = "dsh-portable";
            req.Timeout = 4000;
            req.ReadWriteTimeout = 4000;
            string json;
            using (var resp = (HttpWebResponse)req.GetResponse())
            using (var sr = new StreamReader(resp.GetResponseStream()))
                json = sr.ReadToEnd();
            string tag = ExtractTag(json);
            if (tag == null) return;
            string latest = tag.TrimStart('v', 'V');
            if (CompareVersions(latest, Version) > 0)
            {
                Console.WriteLine();
                Console.WriteLine("  dsh-portable " + latest + " is available (you are on " + Version + ")");
                Console.WriteLine("  download: https://github.com/" + Repo + "/releases/latest");
                Console.WriteLine();
            }
        }
        catch
        {
            // never block or fail startup because the update probe failed
        }
    }

    static string ExtractTag(string json)
    {
        var m = System.Text.RegularExpressions.Regex.Match(json, "\"tag_name\"\\s*:\\s*\"([^\"]+)\"");
        return m.Success ? m.Groups[1].Value : null;
    }

    /// Compare "0.1.0" / "0.1.0-rc.7" style versions: negative, zero, positive.
    static int CompareVersions(string a, string b)
    {
        int rcA, rcB;
        string coreA = StripRc(a, out rcA);
        string coreB = StripRc(b, out rcB);
        string[] pa = coreA.Split('.');
        string[] pb = coreB.Split('.');
        int n = Math.Max(pa.Length, pb.Length);
        for (int i = 0; i < n; i++)
        {
            int va = i < pa.Length ? ParseNum(pa[i]) : 0;
            int vb = i < pb.Length ? ParseNum(pb[i]) : 0;
            if (va != vb) return va < vb ? -1 : 1;
        }
        if (rcA != rcB) return rcA < rcB ? -1 : 1;
        return 0;
    }

    static string StripRc(string version, out int rc)
    {
        int idx = version.IndexOf("-rc", StringComparison.OrdinalIgnoreCase);
        if (idx >= 0)
        {
            rc = ParseNum(version.Substring(idx + 3).TrimStart('.'));
            return version.Substring(0, idx);
        }
        rc = int.MaxValue; // a release (no -rc) is newer than any rc
        return version;
    }

    static int ParseNum(string s)
    {
        int n;
        return int.TryParse(s, out n) ? n : 0;
    }

    static string FindPort(List<string> args)
    {
        for (int i = 0; i < args.Count - 1; i++)
            if (args[i] == "--port")
            {
                int unused;
                if (int.TryParse(args[i + 1], out unused)) return args[i + 1];
            }
        return DefaultPort;
    }

    static bool DshWebOpen(string port)
    {
        try
        {
            var req = (HttpWebRequest)WebRequest.Create("http://127.0.0.1:" + port + "/");
            req.Method = "GET";
            req.Timeout = 700;
            req.ReadWriteTimeout = 700;
            req.AllowAutoRedirect = false;
            using (var resp = (HttpWebResponse)req.GetResponse())
            using (var sr = new StreamReader(resp.GetResponseStream()))
            {
                char[] buffer = new char[65536];
                int count = sr.ReadBlock(buffer, 0, buffer.Length);
                string body = new string(buffer, 0, count);
                return body.IndexOf("dsh", StringComparison.OrdinalIgnoreCase) >= 0 ||
                       body.IndexOf("DeepSeek Harness", StringComparison.OrdinalIgnoreCase) >= 0;
            }
        }
        catch
        {
            return false;
        }
    }

    static void OpenBrowser(string url)
    {
        try
        {
            var psi = new ProcessStartInfo(url) { UseShellExecute = true };
            Process.Start(psi);
            Console.Error.WriteLine("dsh: opened " + url);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine("dsh.exe: failed to open browser: " + ex.Message);
        }
    }

    static int RunPlain(string entry, string nodeExe, List<string> passthrough)
    {
        var psi = new ProcessStartInfo(nodeExe);
        psi.UseShellExecute = false;
        psi.Arguments = BuildArguments(entry, passthrough);
        using (var p = Process.Start(psi))
        {
            p.WaitForExit();
            return p.ExitCode;
        }
    }

    static int RunWeb(string entry, string nodeExe, List<string> passthrough)
    {
        var psi = new ProcessStartInfo(nodeExe);
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = new UTF8Encoding(false);
        psi.StandardErrorEncoding = new UTF8Encoding(false);
        psi.Arguments = BuildArguments(entry, passthrough);
        using (var p = Process.Start(psi))
        {
            bool opened = false;
            var stderrTask = Task.Run(() =>
            {
                string errLine;
                while ((errLine = p.StandardError.ReadLine()) != null) Console.Error.WriteLine(errLine);
            });
            string line;
            while ((line = p.StandardOutput.ReadLine()) != null)
            {
                Console.WriteLine(line);
                if (!opened)
                {
                    int idx = line.IndexOf("http://", StringComparison.Ordinal);
                    if (idx >= 0)
                    {
                        string url = line.Substring(idx).Split(' ')[0].Trim();
                        OpenBrowser(url);
                        opened = true;
                    }
                }
            }
            p.WaitForExit();
            stderrTask.Wait(5000);
            return p.ExitCode;
        }
    }

    static string BuildArguments(string entry, List<string> args)
    {
        var sb = new StringBuilder();
        AppendQuoted(sb, entry);
        foreach (var a in args) AppendQuoted(sb, a);
        return sb.ToString();
    }

    static void AppendQuoted(StringBuilder sb, string value)
    {
        if (sb.Length > 0) sb.Append(' ');
        sb.Append('"');
        sb.Append(value.Replace("\"", "\\\""));
        sb.Append('"');
    }

    static void ExtractResource(string name, string destDir)
    {
        using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        {
            if (stream == null) throw new Exception("embedded resource not found: " + name);
            string zipPath = Path.Combine(Path.GetTempPath(), Guid.NewGuid().ToString("N") + ".zip");
            try
            {
                using (var fs = new FileStream(zipPath, FileMode.Create, FileAccess.Write))
                    stream.CopyTo(fs);
                ZipFile.ExtractToDirectory(zipPath, destDir);
            }
            finally
            {
                try { File.Delete(zipPath); } catch { }
            }
        }
    }
}
