using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using static LocoCore.Win32;

namespace LocoCore;

/// <summary>
/// Stops servers the way a terminal does: Ctrl+C to their console. A server with windows and no console
/// gets a close message. Force stop ends the processes. Only exact processes (pid and start time) are touched.
/// Ctrl+C is sent by a short-lived helper, the calling program started again with --ctrl-c, because sending it
/// means joining the server's console and taking the same Ctrl+C. The app never risks that itself.
/// </summary>
[SupportedOSPlatform("windows")]
public static unsafe class Stopper
{
    public const string HelperFlag = "--ctrl-c";

    /// <summary>The helper's exit code when it couldn't ask anything to stop.</summary>
    const int NothingAsked = 1;

    /// <summary>The exit code of a process that Ctrl+C ended: the helper itself, if it took its own Ctrl+C.</summary>
    const int StoppedByCtrlC = unchecked((int)0xC000013A);

    static readonly Lock Gate = new();
    static bool handlerSet;

    /// <summary>
    /// Starts the helper, hidden, to ask the processes to stop. `helper` is a program that hands
    /// `--ctrl-c &lt;refs&gt;` to <see cref="RunHelper"/>. Returns the helper so a caller can wait for it, or null.
    /// </summary>
    public static Process? Ask(string helper, ProcRef[] procs)
    {
        if (procs.Length == 0) return null;
        var psi = new ProcessStartInfo(helper) { UseShellExecute = false, CreateNoWindow = true };
        psi.ArgumentList.Add(HelperFlag);
        psi.ArgumentList.Add(string.Join(',', procs.Select(p => $"{p.Pid}:{p.StartMicros}")));
        try { return Process.Start(psi); }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException) { return null; }
    }

    /// <summary>Whether a helper that exited with this code asked the processes to stop.</summary>
    public static bool Asked(int helperExitCode) => helperExitCode is 0 or StoppedByCtrlC;

    /// <summary>The helper's side of <see cref="Ask"/>: `refs` is "pid:start,pid:start". Returns its exit code.</summary>
    public static int RunHelper(string refs)
    {
        var procs = new List<ProcRef>();
        foreach (var part in refs.Split(',', StringSplitOptions.RemoveEmptyEntries))
        {
            var bits = part.Split(':');
            if (bits.Length != 2 || !int.TryParse(bits[0], out var pid) || !ulong.TryParse(bits[1], out var start)) return 2;
            procs.Add(new ProcRef(pid, start));
        }
        return Interrupt([.. procs]) ? 0 : NothingAsked;
    }

    /// <summary>Programs that may share a server's console and take its Ctrl+C: the shell it runs in and the console host.</summary>
    static readonly HashSet<string> ConsoleNeighbours = new(StringComparer.OrdinalIgnoreCase)
    {
        "cmd", "powershell", "pwsh", "bash", "sh", "zsh", "dash", "fish", "conhost", "OpenConsole",
    };

    /// <summary>The helper joins the server's console to send Ctrl+C, so it gets the event too. This keeps it running.</summary>
    [UnmanagedCallersOnly]
    static int Handled(uint ctrlType) => 1;

    /// <summary>
    /// Asks the processes to stop. False when nothing could be asked; Force stop still works.
    /// Only the helper calls this: it leaves the caller's console and ignores Ctrl+C for good.
    /// </summary>
    static bool Interrupt(ProcRef[] procs)
    {
        int self = Environment.ProcessId;
        var alive = procs.Where(p => p.Pid != self && IsAlive(p)).ToArray();
        if (alive.Length == 0) return false;
        lock (Gate)
        {
            if (!handlerSet)
            {
                // Both: the flag stops the event before any handler runs, and the handler covers a flag a console resets.
                SetConsoleCtrlHandler(null, 1);
                SetConsoleCtrlHandler(&Handled, 1);
                handlerSet = true;
            }
            foreach (var p in alive)
            {
                FreeConsole();
                if (AttachConsole((uint)p.Pid) == 0) continue;
                try
                {
                    // Every process on the console gets Ctrl+C. Send it only when that's the server, its shell
                    // and the console host, never an agent or another program sharing the console.
                    if (!OnlyServerOnConsole(alive, self)) break;
                    if (GenerateConsoleCtrlEvent(CTRL_C_EVENT, 0) != 0) return true;
                }
                finally { FreeConsole(); }
                break;
            }
        }
        return CloseWindows(alive);
    }

    static bool OnlyServerOnConsole(ProcRef[] tree, int self)
    {
        var pids = stackalloc uint[1024];
        uint n = GetConsoleProcessList(pids, 1024);
        if (n == 0 || n > 1024) return false;
        var mine = tree.Select(p => p.Pid).ToHashSet();
        for (int i = 0; i < n; i++)
        {
            int pid = (int)pids[i];
            if (pid == self || mine.Contains(pid)) continue;
            if (!ConsoleNeighbours.Contains(Naming.ProgramName(ImageName(pid)))) return false;
        }
        return true;
    }

    static string ImageName(int pid)
    {
        var h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, (uint)pid);
        if (h == 0) return "";
        try
        {
            var buf = stackalloc char[1024];
            uint size = 1024;
            return QueryFullProcessImageNameW(h, 0, buf, &size) != 0 ? new string(buf, 0, (int)size) : "";
        }
        finally { CloseHandle(h); }
    }

    [ThreadStatic] static List<nint>? found;
    [ThreadStatic] static HashSet<int>? wanted;

    [UnmanagedCallersOnly]
    static int CollectWindow(nint hwnd, nint _)
    {
        uint pid;
        GetWindowThreadProcessId(hwnd, &pid);
        if (wanted!.Contains((int)pid) && IsWindowVisible(hwnd) != 0 && GetWindow(hwnd, GW_OWNER) == 0) found!.Add(hwnd);
        return 1;
    }

    /// <summary>Posts WM_CLOSE to the processes' main windows, as clicking × would.</summary>
    static bool CloseWindows(ProcRef[] procs)
    {
        found = [];
        wanted = procs.Select(p => p.Pid).ToHashSet();
        try
        {
            EnumWindows(&CollectWindow, 0);
            foreach (var hwnd in found) PostMessageW(hwnd, WM_CLOSE, 0, 0);
            return found.Count > 0;
        }
        finally
        {
            found = null;
            wanted = null;
        }
    }

    /// <summary>Ends each process that is still the one we saw.</summary>
    public static void Kill(ProcRef[] procs)
    {
        int self = Environment.ProcessId;
        foreach (var p in procs)
        {
            if (p.Pid == self) continue;
            var h = OpenExact(p, PROCESS_TERMINATE);
            if (h == 0) continue;
            TerminateProcess(h, 1);
            CloseHandle(h);
        }
    }

    /// <summary>Ends a process and everything under it.</summary>
    public static void KillTree(int pid)
    {
        var table = new WinProcTable(listeners: false);
        if (table.Processes.TryGetValue(pid, out var info)) Kill(Scanner.Tree(table, info.Ref));
    }
}
