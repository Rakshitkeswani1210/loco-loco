using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using static LocoCore.Win32;

namespace LocoCore;

/// <summary>
/// Stops servers the way a terminal does: Ctrl+C to their console. A server with windows and no console
/// gets a close message. Force stop ends the processes. Only exact processes (pid and start time) are touched.
/// </summary>
[SupportedOSPlatform("windows")]
public static unsafe class Stopper
{
    static readonly Lock Gate = new();
    static bool handlerSet;

    /// <summary>Programs that may share a server's console and take its Ctrl+C: the shell it runs in and the console host.</summary>
    static readonly HashSet<string> ConsoleNeighbours = new(StringComparer.OrdinalIgnoreCase)
    {
        "cmd", "powershell", "pwsh", "bash", "sh", "zsh", "dash", "fish", "conhost", "OpenConsole",
    };

    /// <summary>
    /// Loco Loco joins the server's console to send Ctrl+C, so it gets the event too. This handler keeps it running.
    /// A handler, not SetConsoleCtrlHandler(NULL), because servers Loco Loco starts would inherit that and ignore Ctrl+C.
    /// </summary>
    [UnmanagedCallersOnly]
    static int Handled(uint ctrlType) => 1;

    /// <summary>Asks the processes to stop. False when nothing could be asked; Force stop still works.</summary>
    public static bool Interrupt(ProcRef[] procs)
    {
        int self = Environment.ProcessId;
        var alive = procs.Where(p => p.Pid != self && IsAlive(p)).ToArray();
        if (alive.Length == 0) return false;
        lock (Gate)
        {
            if (!handlerSet)
            {
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
