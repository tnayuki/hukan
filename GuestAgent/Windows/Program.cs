// hukan-guest-agent for Windows: what hukan reaches a Windows guest through, over virtio-serial.
//
// It runs twice from one binary, like the macOS agent: as a service (--root, SYSTEM) for what needs
// an administrator, and at logon in the user's session (--user), where a command has the desktop.
// A service lives in session 0 and cannot see a desktop, so the interface has to be the user half's.
//
// A serial port is one stream rather than a connection per request, so every request carries an id
// and its answer carries it back, and requests run side by side. One JSON object per line each way:
//   {"id":1,"op":"ping"}                     -> {"id":1,"ok":true,"version":"1","mode":"user"}
//   {"id":2,"op":"exec","argv":[...],"cwd":?,"stdin":"<b64>"?,"timeout":seconds?}
//                                            -> {"id":2,"ok":true,"exit":0,"stdout":"<b64>","stderr":"<b64>","timedOut":false}
//   {"id":3,"op":"read","path":...}          -> {"id":3,"ok":true,"data":"<b64>"}
//   {"id":4,"op":"write","path":...,"data":"<b64>"}  -> {"id":4,"ok":true}
// A failure is {"id":n,"ok":false,"error":"..."}. Unasked, every fifteen seconds: {"hello":"user"}.

using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.ServiceProcess;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using Microsoft.Win32.SafeHandles;

namespace HukanGuestAgent
{
    static class Program
    {
        internal const string Version = "1";

        static int Main(string[] args)
        {
            if (Array.IndexOf(args, "--root") >= 0)
            {
                ServiceBase.Run(new AgentService());
                return 0;
            }
            new Agent("user").Run();
            return 0;
        }
    }

    sealed class AgentService : ServiceBase
    {
        public AgentService() { ServiceName = "HukanGuestAgent"; }

        protected override void OnStart(string[] args)
        {
            var thread = new Thread(() => new Agent("root").Run()) { IsBackground = true };
            thread.Start();
        }
    }

    sealed class Agent
    {
        const uint GenericRead = 0x80000000, GenericWrite = 0x40000000;
        const uint OpenExisting = 3, FileFlagOverlapped = 0x40000000;
        const int WriteChunk = 32 * 1024;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFile(
            string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        readonly string mode;
        readonly object writing = new object();
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = int.MaxValue };
        FileStream port;

        public Agent(string mode) { this.mode = mode; }

        public void Run()
        {
            while (true)
            {
                try
                {
                    Open();
                    Serve();
                }
                catch (Exception)
                {
                    // The host not being there yet, or the port going away: try again shortly.
                }
                try { port?.Dispose(); } catch (Exception) { }
                port = null;
                Thread.Sleep(2000);
            }
        }

        void Open()
        {
            var name = @"\\.\Global\dev.hukan.agent." + mode;
            var handle = CreateFile(name, GenericRead | GenericWrite, 0, IntPtr.Zero, OpenExisting, FileFlagOverlapped, IntPtr.Zero);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            port = new FileStream(handle, FileAccess.ReadWrite, 4096, true);
        }

        void Serve()
        {
            using (var timer = new Timer(_ => Hello(), null, 0, 15000))
            {
                var line = new MemoryStream();
                var buffer = new byte[65536];
                while (true)
                {
                    var count = port.Read(buffer, 0, buffer.Length);
                    if (count <= 0) throw new EndOfStreamException();
                    for (var i = 0; i < count; i++)
                    {
                        if (buffer[i] != (byte)'\n')
                        {
                            line.WriteByte(buffer[i]);
                            continue;
                        }
                        var text = Encoding.UTF8.GetString(line.ToArray());
                        line.SetLength(0);
                        Task.Run(() => Answer(text));
                    }
                }
            }
        }

        void Hello() { Send(new Dictionary<string, object> { ["hello"] = mode, ["version"] = Program.Version }); }

        void Send(Dictionary<string, object> message)
        {
            var bytes = Encoding.UTF8.GetBytes(json.Serialize(message) + "\n");
            lock (writing)
            {
                try
                {
                    // In pieces: one write of a few megabytes never arrived at the host.
                    for (var offset = 0; port != null && offset < bytes.Length; offset += WriteChunk)
                    {
                        port.Write(bytes, offset, Math.Min(WriteChunk, bytes.Length - offset));
                    }
                    port?.Flush();
                }
                catch (Exception) { }
            }
        }

        void Answer(string text)
        {
            object id = null;
            Dictionary<string, object> reply;
            try
            {
                var request = json.Deserialize<Dictionary<string, object>>(text);
                request.TryGetValue("id", out id);
                reply = Handle(request);
            }
            catch (Exception error)
            {
                reply = Failure(error.Message);
            }
            reply["id"] = id;
            Send(reply);
        }

        static Dictionary<string, object> Failure(string message) =>
            new Dictionary<string, object> { ["ok"] = false, ["error"] = message };

        static string Text(Dictionary<string, object> request, string key) =>
            request.TryGetValue(key, out var value) ? value as string : null;

        Dictionary<string, object> Handle(Dictionary<string, object> request)
        {
            switch (Text(request, "op"))
            {
                case "ping":
                    return new Dictionary<string, object> { ["ok"] = true, ["version"] = Program.Version, ["mode"] = mode };
                case "exec":
                    return Execute(request);
                case "read":
                    return new Dictionary<string, object>
                    {
                        ["ok"] = true,
                        ["data"] = Convert.ToBase64String(File.ReadAllBytes(Text(request, "path")))
                    };
                case "write":
                    var path = Text(request, "path");
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    File.WriteAllBytes(path, Convert.FromBase64String(Text(request, "data")));
                    return new Dictionary<string, object> { ["ok"] = true };
                default:
                    return Failure("unknown op");
            }
        }

        static Dictionary<string, object> Execute(Dictionary<string, object> request)
        {
            var argv = (request["argv"] as System.Collections.ArrayList)?.ToArray();
            if (argv == null || argv.Length == 0) return Failure("exec needs argv");
            var start = new ProcessStartInfo
            {
                FileName = (string)argv[0],
                Arguments = Quote(argv),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardInput = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            };
            var cwd = Text(request, "cwd");
            if (cwd != null) start.WorkingDirectory = cwd;
            using (var process = Process.Start(start))
            {
                var stdout = new MemoryStream();
                var stderr = new MemoryStream();
                var reading = Task.WhenAll(
                    process.StandardOutput.BaseStream.CopyToAsync(stdout),
                    process.StandardError.BaseStream.CopyToAsync(stderr));
                var input = Text(request, "stdin");
                if (input != null)
                {
                    var bytes = Convert.FromBase64String(input);
                    process.StandardInput.BaseStream.Write(bytes, 0, bytes.Length);
                }
                process.StandardInput.Close();
                var seconds = request.TryGetValue("timeout", out var limit) ? Convert.ToDouble(limit) : 600;
                var finished = process.WaitForExit((int)(seconds * 1000));
                if (!finished)
                {
                    try { process.Kill(); } catch (Exception) { }
                }
                reading.Wait(5000);
                return new Dictionary<string, object>
                {
                    ["ok"] = true,
                    ["exit"] = finished ? process.ExitCode : -1,
                    ["stdout"] = Convert.ToBase64String(stdout.ToArray()),
                    ["stderr"] = Convert.ToBase64String(stderr.ToArray()),
                    ["timedOut"] = !finished,
                };
            }
        }

        /// The command line for argv[1...], quoted the way the C runtime reads it back.
        static string Quote(object[] argv)
        {
            var line = new StringBuilder();
            for (var i = 1; i < argv.Length; i++)
            {
                if (i > 1) line.Append(' ');
                var argument = (string)argv[i];
                // Only what needs it: cmd.exe does not read a quoted /c as a switch.
                if (argument.Length > 0 && argument.IndexOfAny(new[] { ' ', '\t', '"' }) < 0)
                {
                    line.Append(argument);
                    continue;
                }
                line.Append('"');
                var backslashes = 0;
                foreach (var c in argument)
                {
                    if (c == '\\')
                    {
                        backslashes++;
                        continue;
                    }
                    line.Append('\\', c == '"' ? backslashes * 2 + 1 : backslashes);
                    backslashes = 0;
                    line.Append(c);
                }
                line.Append('\\', backslashes * 2);
                line.Append('"');
            }
            return line.ToString();
        }
    }
}
