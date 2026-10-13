using System.Runtime.InteropServices;
using System.Runtime.Versioning;

namespace LocoCore;

/// <summary>The Windows calls Loco Loco makes. Everything is blittable, so nothing depends on the marshaller.</summary>
[SupportedOSPlatform("windows")]
internal static unsafe class Win32
{
    public const uint TH32CS_SNAPPROCESS = 0x2;
    public const uint PROCESS_TERMINATE = 0x1;
    public const uint PROCESS_VM_READ = 0x10;
    public const uint PROCESS_QUERY_INFORMATION = 0x400;
    public const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    public const uint SYNCHRONIZE = 0x100000;
    public const uint TOKEN_QUERY = 0x8;
    public const uint WAIT_TIMEOUT = 0x102;
    public const uint STILL_ACTIVE = 259;
    public const uint CTRL_C_EVENT = 0;
    public const uint WM_CLOSE = 0x10;
    public const uint GW_OWNER = 4;
    public const uint ERROR_ACCESS_DENIED = 5;
    public const uint ERROR_INSUFFICIENT_BUFFER = 122;
    public const int STATUS_INFO_LENGTH_MISMATCH = unchecked((int)0xC0000004);
    public const int STATUS_BUFFER_TOO_SMALL = unchecked((int)0xC0000023);
    public const int STATUS_BUFFER_OVERFLOW = unchecked((int)0x80000005);

    public const uint FILE_APPEND_DATA = 0x4;
    public const uint GENERIC_READ = 0x80000000;
    public const uint FILE_SHARE_READ = 0x1, FILE_SHARE_WRITE = 0x2, FILE_SHARE_DELETE = 0x4;
    public const uint OPEN_EXISTING = 3, OPEN_ALWAYS = 4;
    public const uint FILE_ATTRIBUTE_NORMAL = 0x80;

    public const uint CREATE_UNICODE_ENVIRONMENT = 0x400;
    public const uint EXTENDED_STARTUPINFO_PRESENT = 0x80000;
    public const uint CREATE_BREAKAWAY_FROM_JOB = 0x01000000;
    public const uint CREATE_NO_WINDOW = 0x08000000;
    public const uint STARTF_USESTDHANDLES = 0x100;
    public const nuint PROC_THREAD_ATTRIBUTE_HANDLE_LIST = 0x20002;

    public const int ProcessBasicInformation = 0;
    public const int ProcessWow64Information = 26;
    public const int ProcessCommandLineInformation = 60;
    public const int TokenUser = 1;
    public const uint AF_INET = 2, AF_INET6 = 23;
    public const int TCP_TABLE_OWNER_PID_LISTENER = 3;

    public static readonly nint InvalidHandle = -1;

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESSENTRY32W
    {
        public uint dwSize;
        public uint cntUsage;
        public uint th32ProcessID;
        public nuint th32DefaultHeapID;
        public uint th32ModuleID;
        public uint cntThreads;
        public uint th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        public fixed ushort szExeFile[260];
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct STARTUPINFOW
    {
        public uint cb;
        public nint lpReserved, lpDesktop, lpTitle;
        public uint dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public ushort wShowWindow, cbReserved2;
        public nint lpReserved2, hStdInput, hStdOutput, hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct STARTUPINFOEXW
    {
        public STARTUPINFOW StartupInfo;
        public nint lpAttributeList;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION
    {
        public nint hProcess, hThread;
        public uint dwProcessId, dwThreadId;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct SECURITY_ATTRIBUTES
    {
        public uint nLength;
        public nint lpSecurityDescriptor;
        public int bInheritHandle;
    }

    // kernel32

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern nint CreateToolhelp32Snapshot(uint flags, uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int Process32FirstW(nint snapshot, PROCESSENTRY32W* entry);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int Process32NextW(nint snapshot, PROCESSENTRY32W* entry);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern nint OpenProcess(uint access, int inherit, uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int CloseHandle(nint handle);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int GetProcessTimes(nint process, long* creation, long* exit, long* kernel, long* user);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int QueryFullProcessImageNameW(nint process, uint flags, char* name, uint* size);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int ProcessIdToSessionId(uint pid, uint* session);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint WaitForSingleObject(nint handle, uint ms);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int GetExitCodeProcess(nint process, uint* code);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int TerminateProcess(nint process, uint code);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int ReadProcessMemory(nint process, nint address, void* buffer, nuint size, nuint* read);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int FreeConsole();

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int AttachConsole(uint pid);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int SetConsoleCtrlHandler(delegate* unmanaged<uint, int> handler, int add);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int GenerateConsoleCtrlEvent(uint ctrlEvent, uint group);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern uint GetConsoleProcessList(uint* pids, uint count);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern nint CreateFileW(string name, uint access, uint share, SECURITY_ATTRIBUTES* sa, uint disposition, uint flags, nint template);

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode, ExactSpelling = true)]
    public static extern int CreateProcessW(
        string? application, char* commandLine, nint processAttributes, nint threadAttributes, int inheritHandles,
        uint flags, char* environment, string? currentDirectory, STARTUPINFOEXW* startup, PROCESS_INFORMATION* info);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int InitializeProcThreadAttributeList(nint list, int count, uint flags, nuint* size);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int UpdateProcThreadAttribute(nint list, uint flags, nuint attribute, void* value, nuint size, nint previous, nint returnSize);

    [DllImport("kernel32.dll")]
    public static extern void DeleteProcThreadAttributeList(nint list);

    // advapi32

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int OpenProcessToken(nint process, uint access, nint* token);

    [DllImport("advapi32.dll", SetLastError = true)]
    public static extern int GetTokenInformation(nint token, int cls, void* info, uint length, uint* returned);

    [DllImport("advapi32.dll")]
    public static extern uint GetLengthSid(nint sid);

    // ntdll

    [DllImport("ntdll.dll")]
    public static extern int NtQueryInformationProcess(nint process, int cls, void* info, uint length, uint* returned);

    // iphlpapi

    [DllImport("iphlpapi.dll")]
    public static extern uint GetExtendedTcpTable(void* table, uint* size, int order, uint af, int cls, uint reserved);

    // user32

    [DllImport("user32.dll")]
    public static extern int EnumWindows(delegate* unmanaged<nint, nint, int> callback, nint param);

    [DllImport("user32.dll")]
    public static extern uint GetWindowThreadProcessId(nint hwnd, uint* pid);

    [DllImport("user32.dll")]
    public static extern int IsWindowVisible(nint hwnd);

    [DllImport("user32.dll")]
    public static extern nint GetWindow(nint hwnd, uint cmd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern int PostMessageW(nint hwnd, uint msg, nint wParam, nint lParam);

    /// <summary>A FILETIME as microseconds since 1970.</summary>
    public static ulong FileTimeToMicros(long ft) => ft <= 116444736000000000 ? 0 : (ulong)(ft - 116444736000000000) / 10;

    /// <summary>The process's start time, or null when it can't be read.</summary>
    public static ulong? StartMicros(nint process)
    {
        long creation, exit, kernel, user;
        return GetProcessTimes(process, &creation, &exit, &kernel, &user) != 0 ? FileTimeToMicros(creation) : null;
    }

    /// <summary>Opens a process only if it is still the one we saw.</summary>
    public static nint OpenExact(ProcRef p, uint access)
    {
        if (p.Pid <= 4) return 0;
        var h = OpenProcess(access | PROCESS_QUERY_LIMITED_INFORMATION, 0, (uint)p.Pid);
        if (h == 0) return 0;
        if (StartMicros(h) != p.StartMicros) { CloseHandle(h); return 0; }
        return h;
    }

    public static bool IsAlive(ProcRef p)
    {
        var h = OpenExact(p, SYNCHRONIZE);
        if (h == 0) return false;
        try { return WaitForSingleObject(h, 0) == WAIT_TIMEOUT; }
        finally { CloseHandle(h); }
    }

    /// <summary>The listening TCP ports of every process, IPv4 and IPv6 together. Covers all users.</summary>
    public static Dictionary<int, SortedSet<ushort>> TcpListeners()
    {
        var map = new Dictionary<int, SortedSet<ushort>>();
        Read(AF_INET, rowSize: 24, portOffset: 8, pidOffset: 20);
        Read(AF_INET6, rowSize: 56, portOffset: 20, pidOffset: 52);
        return map;

        void Read(uint af, int rowSize, int portOffset, int pidOffset)
        {
            uint size = 0;
            if (GetExtendedTcpTable(null, &size, 0, af, TCP_TABLE_OWNER_PID_LISTENER, 0) != ERROR_INSUFFICIENT_BUFFER) return;
            byte[] buf;
            // The table can grow between the two calls; try again with the new size.
            for (int attempt = 0; ; attempt++)
            {
                if (attempt == 4) return;
                buf = new byte[size + 4096];
                size = (uint)buf.Length;
                uint rc;
                fixed (byte* p = buf) rc = GetExtendedTcpTable(p, &size, 0, af, TCP_TABLE_OWNER_PID_LISTENER, 0);
                if (rc == 0) break;
                if (rc != ERROR_INSUFFICIENT_BUFFER) return;
            }
            fixed (byte* p = buf)
            {
                uint n = *(uint*)p;
                for (uint i = 0; i < n; i++)
                {
                    long off = 4 + (long)i * rowSize;
                    if (off + rowSize > buf.Length) break;
                    uint rawPort = *(uint*)(p + off + portOffset);
                    int pid = (int)*(uint*)(p + off + pidOffset);
                    var port = (ushort)(((rawPort & 0xFF) << 8) | ((rawPort >> 8) & 0xFF));
                    if (port == 0) continue;
                    if (!map.TryGetValue(pid, out var set)) map[pid] = set = [];
                    set.Add(port);
                }
            }
        }
    }
}
