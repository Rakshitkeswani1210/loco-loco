using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Text;
using Microsoft.Win32.SafeHandles;
using static LocoCore.Win32;

namespace LocoCore;

/// <summary>Starts servers again with cmd, hidden, with output appended to a log. They outlive Loco Loco.</summary>
[SupportedOSPlatform("windows")]
public static unsafe class WinLauncher
{
    /// <summary>
    /// Runs `command` with `cmd /d /s /c` from `dir`. Stdin is NUL; stdout and stderr go to `log`.
    /// Only those two handles are inherited. The server leaves Loco Loco's job, if it has one, so closing
    /// Loco Loco or the terminal that started it doesn't end the server.
    /// </summary>
    public static int Spawn(string command, string dir, string? path, string log, Action<int, string> exited)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(log)!);
        var stamp = DateTime.Now.ToString("G", System.Globalization.CultureInfo.CurrentCulture);
        File.AppendAllText(log, $"\n[Loco Loco] {stamp} in {dir}\n$ {command}\n\n", new UTF8Encoding(false));

        var sa = new SECURITY_ATTRIBUTES { nLength = (uint)sizeof(SECURITY_ATTRIBUTES), bInheritHandle = 1 };
        var logHandle = CreateFileW(log, FILE_APPEND_DATA | SYNCHRONIZE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            &sa, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, 0);
        if (logHandle == InvalidHandle) throw new IOException("Couldn't open the log", Marshal.GetLastPInvokeError());
        var nul = CreateFileW("NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &sa, OPEN_EXISTING, 0, 0);
        nint list = 0;
        try
        {
            if (nul == InvalidHandle) throw new IOException("Couldn't open NUL", Marshal.GetLastPInvokeError());
            nuint size = 0;
            InitializeProcThreadAttributeList(0, 1, 0, &size);
            list = Marshal.AllocHGlobal((nint)size);
            if (InitializeProcThreadAttributeList(list, 1, 0, &size) == 0)
            {
                Marshal.FreeHGlobal(list);
                list = 0;
                throw new IOException("Couldn't set up the process", Marshal.GetLastPInvokeError());
            }
            var handles = stackalloc nint[2] { nul, logHandle };
            if (UpdateProcThreadAttribute(list, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handles, (nuint)(2 * sizeof(nint)), 0, 0) == 0)
                throw new IOException("Couldn't set up the process", Marshal.GetLastPInvokeError());

            var si = new STARTUPINFOEXW();
            si.StartupInfo.cb = (uint)sizeof(STARTUPINFOEXW);
            si.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
            si.StartupInfo.hStdInput = nul;
            si.StartupInfo.hStdOutput = logHandle;
            si.StartupInfo.hStdError = logHandle;
            si.lpAttributeList = list;

            var comspec = Environment.GetEnvironmentVariable("ComSpec") is { Length: > 0 } c ? c : Path.Combine(Environment.SystemDirectory, "cmd.exe");
            var line = (CommandLineFor(comspec, command) + "\0").ToCharArray();
            var env = EnvironmentBlock(path).ToCharArray();

            const uint baseFlags = EXTENDED_STARTUPINFO_PRESENT | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT;
            var pi = new PROCESS_INFORMATION();
            int ok;
            fixed (char* l = line)
            fixed (char* e = env)
            {
                ok = CreateProcessW(comspec, l, 0, 0, 1, baseFlags | CREATE_BREAKAWAY_FROM_JOB, e, dir, &si, &pi);
                // A job that doesn't allow breakaway refuses; start inside it then.
                if (ok == 0 && Marshal.GetLastPInvokeError() == ERROR_ACCESS_DENIED)
                    ok = CreateProcessW(comspec, l, 0, 0, 1, baseFlags, e, dir, &si, &pi);
            }
            if (ok == 0) throw new IOException("Couldn't start", Marshal.GetLastPInvokeError());
            CloseHandle(pi.hThread);
            Watch(pi.hProcess, (int)pi.dwProcessId, exited);
            return (int)pi.dwProcessId;
        }
        finally
        {
            if (list != 0)
            {
                DeleteProcThreadAttributeList(list);
                Marshal.FreeHGlobal(list);
            }
            if (nul != InvalidHandle) CloseHandle(nul);
            CloseHandle(logHandle);
        }
    }

    /// <summary>`"C:\Windows\system32\cmd.exe" /d /s /c "npm run dev"`. With /s, cmd removes just the outer quotes.</summary>
    public static string CommandLineFor(string comspec, string command) => $"\"{comspec}\" /d /s /c \"{command}\"";

    /// <summary>
    /// Loco Loco's environment with the server's PATH, sorted the way CreateProcess wants.
    /// Python holds back output written to a file, which would leave the log empty while the server runs.
    /// </summary>
    static string EnvironmentBlock(string? path)
    {
        var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (System.Collections.DictionaryEntry kv in Environment.GetEnvironmentVariables())
            if (kv.Key is string k && k.Length > 0 && !k.StartsWith('=')) env[k] = kv.Value as string ?? "";
        if (path != null) env["Path"] = path;
        env["PYTHONUNBUFFERED"] = "1";
        var sb = new StringBuilder();
        foreach (var (k, v) in env.OrderBy(kv => kv.Key, StringComparer.OrdinalIgnoreCase)) sb.Append(k).Append('=').Append(v).Append('\0');
        sb.Append('\0');
        return sb.ToString();
    }

    sealed class ProcessWait : WaitHandle
    {
        public ProcessWait(nint process) => SafeWaitHandle = new SafeWaitHandle(process, ownsHandle: true);
    }

    static void Watch(nint process, int pid, Action<int, string> exited)
    {
        var wait = new ProcessWait(process);
        ThreadPool.RegisterWaitForSingleObject(wait, (_, _) =>
        {
            uint code = 0;
            bool ok;
            ok = GetExitCodeProcess(wait.SafeWaitHandle.DangerousGetHandle(), &code) != 0;
            wait.Dispose();
            exited(pid, ok ? ExitText.Describe(code) : "Stopped");
        }, null, Timeout.Infinite, executeOnlyOnce: true);
    }

    /// <summary>True when anything listens on the port, for any user, on IPv4 or IPv6.</summary>
    public static bool PortInUse(ushort port) => TcpListeners().Values.Any(s => s.Contains(port));
}
