using System.Text;

namespace LocoCore;

/// <summary>A process's command line: the raw text Windows keeps, and the arguments a C program would see.</summary>
public sealed record ProcCommand(string Raw, string[] Argv)
{
    public static readonly ProcCommand Empty = new("", []);
    public static ProcCommand From(string raw) => new(raw, CommandLine.Split(raw));
    public static ProcCommand FromArgv(params string[] argv) => new(CommandLine.Join(argv), argv);
}

/// <summary>Splitting and quoting command lines the way the Microsoft C runtime does.</summary>
public static class CommandLine
{
    /// <summary>
    /// The arguments in a command line. The first is read as a program path: quotes group, backslashes are literal.
    /// After that, 2n backslashes before a quote become n and the quote groups; 2n+1 become n and a literal quote;
    /// "" inside quotes is a literal quote.
    /// </summary>
    public static string[] Split(string s)
    {
        var args = new List<string>();
        int i = 0, n = s.Length;
        while (i < n && s[i] is ' ' or '\t') i++;
        if (i >= n) return [];
        var sb = new StringBuilder();
        if (s[i] == '"')
        {
            i++;
            while (i < n && s[i] != '"') sb.Append(s[i++]);
            if (i < n) i++;
        }
        else
        {
            while (i < n && s[i] is not (' ' or '\t')) sb.Append(s[i++]);
        }
        args.Add(sb.ToString());

        while (true)
        {
            while (i < n && s[i] is ' ' or '\t') i++;
            if (i >= n) break;
            sb.Clear();
            bool quoted = false;
            while (i < n)
            {
                char c = s[i];
                if (!quoted && c is ' ' or '\t') break;
                if (c == '\\')
                {
                    int bs = 0;
                    while (i < n && s[i] == '\\') { bs++; i++; }
                    if (i < n && s[i] == '"')
                    {
                        sb.Append('\\', bs / 2);
                        if (bs % 2 == 1) { sb.Append('"'); i++; }
                    }
                    else
                    {
                        sb.Append('\\', bs);
                    }
                    continue;
                }
                if (c == '"')
                {
                    if (quoted && i + 1 < n && s[i + 1] == '"') { sb.Append('"'); i += 2; continue; }
                    quoted = !quoted;
                    i++;
                    continue;
                }
                sb.Append(c);
                i++;
            }
            args.Add(sb.ToString());
        }
        return args.ToArray();
    }

    /// <summary>Quotes an argument when it has spaces, quotes or characters cmd would act on.</summary>
    public static string Quote(string arg)
    {
        if (arg.Length > 0 && !arg.Any(c => c is ' ' or '\t' or '\n' or '\v' or '"' or '&' or '|' or '<' or '>' or '^' or '(' or ')'))
            return arg;
        var sb = new StringBuilder("\"");
        int bs = 0;
        foreach (var c in arg)
        {
            if (c == '\\') { bs++; continue; }
            if (c == '"') { sb.Append('\\', bs * 2 + 1); sb.Append('"'); }
            else { sb.Append('\\', bs); sb.Append(c); }
            bs = 0;
        }
        sb.Append('\\', bs * 2);
        sb.Append('"');
        return sb.ToString();
    }

    /// <summary>A command line that gives back `argv`. The program path is quoted without escapes, as Windows reads it.</summary>
    public static string Join(IReadOnlyList<string> argv)
    {
        if (argv.Count == 0) return "";
        var first = argv[0].Any(c => c is ' ' or '\t' or '&' or '|' or '<' or '>' or '^' or '(' or ')') ? "\"" + argv[0] + "\"" : argv[0];
        return string.Join(' ', argv.Skip(1).Select(Quote).Prepend(first));
    }
}
