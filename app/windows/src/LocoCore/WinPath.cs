namespace LocoCore;

/// <summary>
/// Windows paths, handled the same way on any OS so the rules can be tested anywhere.
/// System.IO.Path follows the OS it runs on, which would make the tests pass on a Mac and fail on Windows.
/// </summary>
public static class WinPath
{
    public static bool IsSep(char c) => c is '\\' or '/';

    /// <summary>"C:\" is 3, "\\server\share" is its length, "\" is 1, a relative path is 0.</summary>
    static int RootLength(string p)
    {
        if (p.Length >= 2 && char.IsAsciiLetter(p[0]) && p[1] == ':')
            return p.Length >= 3 && IsSep(p[2]) ? 3 : 2;
        if (p.Length >= 2 && IsSep(p[0]) && IsSep(p[1]))
        {
            int i = 2;
            while (i < p.Length && !IsSep(p[i])) i++;
            i++;
            while (i < p.Length && !IsSep(p[i])) i++;
            return Math.Min(i, p.Length);
        }
        return p.Length >= 1 && IsSep(p[0]) ? 1 : 0;
    }

    /// <summary>A drive path ("C:\x") or a UNC path ("\\server\share\x").</summary>
    public static bool IsFullyRooted(string p) =>
        (p.Length >= 3 && char.IsAsciiLetter(p[0]) && p[1] == ':' && IsSep(p[2])) ||
        (p.Length >= 2 && IsSep(p[0]) && IsSep(p[1]));

    /// <summary>Backslashes, no "." or "..", no trailing separator except on a drive root.</summary>
    public static string Normalize(string p)
    {
        if (string.IsNullOrEmpty(p)) return p;
        p = p.Replace('/', '\\');
        if (p.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) p = @"\\" + p[8..];
        else if (p.StartsWith(@"\\?\", StringComparison.Ordinal) && p.Length >= 6 && p[5] == ':') p = p[4..];
        int r = RootLength(p);
        var root = p[..r];
        if (r >= 2 && root[1] == ':') root = char.ToUpperInvariant(root[0]) + root[1..];
        var parts = new List<string>();
        foreach (var seg in p[r..].Split('\\'))
        {
            if (seg.Length == 0 || seg == ".") continue;
            if (seg == "..")
            {
                if (parts.Count > 0 && parts[^1] != "..") parts.RemoveAt(parts.Count - 1);
                else if (r == 0) parts.Add("..");
                continue;
            }
            parts.Add(seg);
        }
        var body = string.Join('\\', parts);
        if (r == 0) return body.Length == 0 ? "." : body;
        if (root.EndsWith('\\')) return root + body;
        if (root.Length == 2 && root[1] == ':') return body.Length == 0 ? root + "\\" : root + "\\" + body;
        return body.Length == 0 ? root : root + "\\" + body;
    }

    /// <summary>`rel` resolved against `dir`.</summary>
    public static string Combine(string dir, string rel)
    {
        if (IsFullyRooted(rel)) return Normalize(rel);
        if (rel.Length > 0 && IsSep(rel[0]))
        {
            var n = Normalize(dir);
            return Normalize(n[..RootLength(n)].TrimEnd('\\') + rel);
        }
        return Normalize(dir + "\\" + rel);
    }

    /// <summary>The folder above. A root is its own parent, like NSString's deletingLastPathComponent.</summary>
    public static string Parent(string p)
    {
        var n = Normalize(p);
        int r = RootLength(n);
        if (n.Length <= r) return n;
        int i = n.LastIndexOf('\\');
        if (i < r) return n[..r];
        return n[..i];
    }

    /// <summary>The last component: "site" from "C:\Users\me\site\".</summary>
    public static string FileName(string p)
    {
        var t = p.TrimEnd('\\', '/');
        int i = t.LastIndexOfAny(['\\', '/']);
        return i < 0 ? t : t[(i + 1)..];
    }

    /// <summary>"py" from "serve.py", "" when there is none.</summary>
    public static string Extension(string p)
    {
        var name = FileName(p);
        int i = name.LastIndexOf('.');
        return i <= 0 ? "" : name[(i + 1)..];
    }

    public static string WithoutExtension(string name)
    {
        int i = name.LastIndexOf('.');
        return i <= 0 ? name : name[..i];
    }

    public static bool Eq(string a, string b) =>
        string.Equals(Normalize(a).TrimEnd('\\'), Normalize(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase);

    /// <summary>Strictly inside `dir`, ignoring case.</summary>
    public static bool IsUnder(string p, string dir)
    {
        if (string.IsNullOrEmpty(p) || string.IsNullOrEmpty(dir)) return false;
        var d = Normalize(dir).TrimEnd('\\') + "\\";
        return Normalize(p).StartsWith(d, StringComparison.OrdinalIgnoreCase) && Normalize(p).Length > d.Length;
    }

    public static bool IsSameOrUnder(string p, string dir) => Eq(p, dir) || IsUnder(p, dir);

    /// <summary>"~\Documents\x" for display.</summary>
    public static string Abbreviate(string p, string home) =>
        Eq(p, home) ? "~" : IsUnder(p, home) ? "~" + Normalize(p)[Normalize(home).TrimEnd('\\').Length..] : p;
}
