using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using static LocoCore.Win32;

namespace LocoCore;

/// <summary>
/// One read of the Windows process table. Names, parents and start times for every process come from one
/// Toolhelp snapshot; command lines, folders and environments are read only when the scanner asks.
/// Everything here reads only and needs no admin rights.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed unsafe class WinProcTable : IProcTable
{
    public int Self { get; } = Environment.ProcessId;
    public IReadOnlyDictionary<int, ProcInfo> Processes { get; }
    public IReadOnlyDictionary<int, ushort[]> Listeners { get; }

    readonly Dictionary<int, string> exes = [];
    readonly Dictionary<int, (string? Cwd, Dictionary<string, string>? Env)> pebs = [];

    public WinProcTable(bool listeners = true)
    {
        var me = CurrentSid();
        uint mySession = 0;
        ProcessIdToSessionId((uint)Self, &mySession);

        var table = new Dictionary<int, ProcInfo>();
        var snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snap != InvalidHandle && snap != 0)
        {
            try
            {
                var e = new PROCESSENTRY32W { dwSize = (uint)sizeof(PROCESSENTRY32W) };
                for (int ok = Process32FirstW(snap, &e); ok != 0; ok = Process32NextW(snap, &e))
                {
                    int pid = (int)e.th32ProcessID;
                    if (pid <= 4) continue;
                    var h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, (uint)pid);
                    if (h == 0) continue;
                    try
                    {
                        if (StartMicros(h) is not { } start) continue;
                        if (pid != Self && !SameUser(h, (uint)pid, me, mySession)) continue;
                        table[pid] = new ProcInfo(pid, (int)e.th32ParentProcessID, start, new string((char*)e.szExeFile));
                    }
                    finally { CloseHandle(h); }
                }
            }
            finally { CloseHandle(snap); }
        }
        Processes = table;
        Listeners = listeners
            ? TcpListeners().Where(kv => table.ContainsKey(kv.Key)).ToDictionary(kv => kv.Key, kv => kv.Value.ToArray())
            : new Dictionary<int, ushort[]>();
    }

    // MARK: User

    /// <summary>-1 is GetCurrentProcess()'s pseudo handle.</summary>
    static byte[]? CurrentSid() => TokenSid(-1);

    static byte[]? TokenSid(nint process)
    {
        nint token;
        if (OpenProcessToken(process, TOKEN_QUERY, &token) == 0) return null;
        try
        {
            uint len = 0;
            GetTokenInformation(token, TokenUser, null, 0, &len);
            if (len == 0 || len > 4096) return null;
            var buf = stackalloc byte[(int)len];
            if (GetTokenInformation(token, TokenUser, buf, len, &len) == 0) return null;
            var sid = *(nint*)buf;
            var n = GetLengthSid(sid);
            var bytes = new byte[n];
            Marshal.Copy(sid, bytes, 0, (int)n);
            return bytes;
        }
        finally { CloseHandle(token); }
    }

    /// <summary>Owned by the signed-in user. When the token can't be read, the same session counts.</summary>
    static bool SameUser(nint process, uint pid, byte[]? me, uint mySession)
    {
        if (me != null && TokenSid(process) is { } sid) return sid.AsSpan().SequenceEqual(me);
        uint session;
        return ProcessIdToSessionId(pid, &session) != 0 && session == mySession;
    }

    // MARK: Lazy reads

    public string Exe(int pid)
    {
        if (exes.TryGetValue(pid, out var e)) return e;
        e = "";
        var h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, (uint)pid);
        if (h != 0)
        {
            try
            {
                var buf = stackalloc char[32768];
                uint size = 32768;
                if (QueryFullProcessImageNameW(h, 0, buf, &size) != 0) e = new string(buf, 0, (int)size);
            }
            finally { CloseHandle(h); }
        }
        return exes[pid] = e;
    }

    readonly Dictionary<int, ProcCommand> commands = [];

    public ProcCommand Command(int pid)
    {
        if (commands.TryGetValue(pid, out var c)) return c;
        return commands[pid] = ProcCommand.From(ReadCommandLine(pid) ?? "");
    }

    /// <summary>The raw command line, from NtQueryInformationProcess. Needs only limited query rights.</summary>
    static string? ReadCommandLine(int pid)
    {
        var h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, (uint)pid);
        if (h == 0) return null;
        try
        {
            uint len = 4096;
            for (int attempt = 0; attempt < 3; attempt++)
            {
                var buf = new byte[len];
                fixed (byte* p = buf)
                {
                    uint got = 0;
                    int status = NtQueryInformationProcess(h, ProcessCommandLineInformation, p, len, &got);
                    if (status is STATUS_INFO_LENGTH_MISMATCH or STATUS_BUFFER_TOO_SMALL or STATUS_BUFFER_OVERFLOW)
                    {
                        len = Math.Max(got, len * 2);
                        continue;
                    }
                    if (status < 0) return null;
                    // UNICODE_STRING: Length, MaximumLength, then the buffer pointer at pointer alignment.
                    int bytes = *(ushort*)p;
                    var text = *(char**)(p + sizeof(nint));
                    if (text == null || bytes == 0) return "";
                    return new string(text, 0, bytes / 2);
                }
            }
            return null;
        }
        finally { CloseHandle(h); }
    }

    public string? Cwd(int pid) => Peb(pid).Cwd;

    public string? Env(int pid, string name) =>
        Peb(pid).Env is { } env && env.TryGetValue(name, out var v) ? v : null;

    (string? Cwd, Dictionary<string, string>? Env) Peb(int pid)
    {
        if (pebs.TryGetValue(pid, out var r)) return r;
        r = (null, null);
        var h = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, 0, (uint)pid);
        if (h != 0)
        {
            try { r = ReadPeb(h); }
            catch (Exception) { r = (null, null); }
            finally { CloseHandle(h); }
        }
        return pebs[pid] = r;
    }

    const int MaxEnvironment = 512 * 1024;

    /// <summary>
    /// The working folder and environment, from the process's PEB and its RTL_USER_PROCESS_PARAMETERS.
    /// A 32-bit process under WOW64 has a 32-bit PEB with its own offsets.
    /// </summary>
    static (string? Cwd, Dictionary<string, string>? Env) ReadPeb(nint h)
    {
        nint peb32 = 0;
        uint got;
        NtQueryInformationProcess(h, ProcessWow64Information, &peb32, (uint)sizeof(nint), &got);

        ulong cwdBuf, envAddr, envSize;
        int cwdLen;
        if (peb32 != 0)
        {
            uint parameters = ReadU32(h, peb32 + 0x10);
            if (parameters == 0) return (null, null);
            cwdLen = ReadU16(h, (nint)parameters + 0x24);
            cwdBuf = ReadU32(h, (nint)parameters + 0x28);
            envAddr = ReadU32(h, (nint)parameters + 0x48);
            envSize = ReadU32(h, (nint)parameters + 0x290);
        }
        else
        {
            var pbi = stackalloc byte[48];
            if (NtQueryInformationProcess(h, ProcessBasicInformation, pbi, 48, &got) < 0) return (null, null);
            var peb = *(nint*)(pbi + 8);
            if (peb == 0) return (null, null);
            var parameters = (nint)ReadU64(h, peb + 0x20);
            if (parameters == 0) return (null, null);
            cwdLen = ReadU16(h, parameters + 0x38);
            cwdBuf = ReadU64(h, parameters + 0x40);
            envAddr = ReadU64(h, parameters + 0x80);
            envSize = ReadU64(h, parameters + 0x3F0);
        }

        string? cwd = null;
        if (cwdBuf != 0 && cwdLen > 0 && cwdLen < 65536)
        {
            var s = ReadString(h, (nint)cwdBuf, cwdLen);
            if (s != null) cwd = s.Length > 3 ? s.TrimEnd('\\') : s;
        }
        Dictionary<string, string>? env = null;
        if (envAddr != 0)
        {
            var size = envSize is > 0 and <= MaxEnvironment ? (int)envSize : 0;
            byte[]? block = size > 0 ? ReadBytes(h, (nint)envAddr, size) : null;
            // Older systems leave the size at zero, and a read past the block's last page fails, so try smaller.
            foreach (var guess in (int[])[64 * 1024, 16 * 1024, 4096])
            {
                if (block != null) break;
                block = ReadBytes(h, (nint)envAddr, guess);
            }
            if (block != null) env = ParseEnvironment(block);
        }
        return (cwd, env);
    }

    static Dictionary<string, string> ParseEnvironment(byte[] block)
    {
        var env = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var text = MemoryMarshal.Cast<byte, char>(block.AsSpan(0, block.Length & ~1));
        int i = 0;
        while (i < text.Length && text[i] != '\0')
        {
            int end = text[i..].IndexOf('\0');
            if (end < 0) break;
            var entry = text.Slice(i, end);
            // "=C:=C:\x" entries hold each drive's folder; the name starts after the first character.
            int eq = entry.Length > 1 ? entry[1..].IndexOf('=') + 1 : -1;
            if (eq > 0)
            {
                var key = entry[..eq].ToString();
                if (!key.StartsWith('=')) env.TryAdd(key, entry[(eq + 1)..].ToString());
            }
            i += end + 1;
        }
        return env;
    }

    static bool Read(nint h, nint address, void* buffer, int size)
    {
        nuint read = 0;
        return ReadProcessMemory(h, address, buffer, (nuint)size, &read) != 0 && read == (nuint)size;
    }

    static ushort ReadU16(nint h, nint a) { ushort v = 0; return Read(h, a, &v, 2) ? v : (ushort)0; }
    static uint ReadU32(nint h, nint a) { uint v = 0; return Read(h, a, &v, 4) ? v : 0; }
    static ulong ReadU64(nint h, nint a) { ulong v = 0; return Read(h, a, &v, 8) ? v : 0; }

    static byte[]? ReadBytes(nint h, nint a, int size)
    {
        var buf = new byte[size];
        fixed (byte* p = buf) return Read(h, a, p, size) ? buf : null;
    }

    static string? ReadString(nint h, nint a, int bytes)
    {
        var buf = ReadBytes(h, a, bytes & ~1);
        return buf == null ? null : new string(MemoryMarshal.Cast<byte, char>(buf));
    }
}
