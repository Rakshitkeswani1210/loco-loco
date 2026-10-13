namespace LocoCore.Tests;

public class CommandLineTests
{
    [Theory]
    [InlineData(@"""C:\Program Files\nodejs\node.exe"" ""C:\a b\x.js"" --flag=1", new[] { @"C:\Program Files\nodejs\node.exe", @"C:\a b\x.js", "--flag=1" })]
    [InlineData(@"""C:\dir\"" arg", new[] { @"C:\dir\", "arg" })]
    [InlineData(@"x a\\\""b", new[] { "x", @"a\""b" })]
    [InlineData(@"x ""a""""b""", new[] { "x", @"a""b" })]
    [InlineData(@"x a\\b", new[] { "x", @"a\\b" })]
    [InlineData(@"x ""a\\"" b", new[] { "x", @"a\", "b" })]
    [InlineData("x \"\"", new[] { "x", "" })]
    [InlineData("  node\tserver.js  ", new[] { "node", "server.js" })]
    [InlineData("", new string[0])]
    [InlineData("   ", new string[0])]
    public void SplitsLikeTheCRuntime(string line, string[] argv) => Assert.Equal(argv, CommandLine.Split(line));

    public static TheoryData<string[]> RoundTrips => new()
    {
        new[] { "node", "a b", "c\"d", @"e\", @"f\""g", "", "h&i", "tab\there", @"C:\a b\" },
        new[] { @"C:\Program Files\nodejs\node.exe", "server.js" },
        new[] { "python", "-m", "http.server", "8000" },
        new[] { "cmd", "/c", "echo (hi) ^ | more" },
    };

    [Theory]
    [MemberData(nameof(RoundTrips))]
    public void JoinThenSplitGivesTheSameArguments(string[] argv) => Assert.Equal(argv, CommandLine.Split(CommandLine.Join(argv)));

    [Theory]
    [InlineData("dev", "dev")]
    [InlineData("a b", "\"a b\"")]
    [InlineData("", "\"\"")]
    [InlineData(@"C:\a b\", @"""C:\a b\\""")]
    [InlineData("say \"hi\"", @"""say \""hi\""""")]
    public void Quotes(string arg, string quoted) => Assert.Equal(quoted, CommandLine.Quote(arg));

    [Fact]
    public void FromArgvKeepsBoth()
    {
        var c = ProcCommand.FromArgv(@"C:\Program Files\x.exe", "y z");
        Assert.Equal(@"""C:\Program Files\x.exe"" ""y z""", c.Raw);
        Assert.Equal(new[] { @"C:\Program Files\x.exe", "y z" }, c.Argv);
    }
}

public class WinPathTests
{
    [Theory]
    [InlineData("c:/Users/me/./site/../web/", @"C:\Users\me\web")]
    [InlineData("C:", @"C:\")]
    [InlineData(@"C:\", @"C:\")]
    [InlineData(@"C:\..", @"C:\")]
    [InlineData(@"\\?\C:\x", @"C:\x")]
    [InlineData(@"\\?\UNC\srv\share\x", @"\\srv\share\x")]
    [InlineData(@"\\srv\share\", @"\\srv\share")]
    [InlineData(@"a\..\..\b", @"..\b")]
    public void Normalizes(string p, string n) => Assert.Equal(n, WinPath.Normalize(p));

    [Theory]
    [InlineData(@"C:\Users\me", @"C:\Users")]
    [InlineData(@"C:\Users", @"C:\")]
    [InlineData(@"C:\", @"C:\")]
    [InlineData(@"\\srv\share\x", @"\\srv\share")]
    public void Parents(string p, string parent) => Assert.Equal(parent, WinPath.Parent(p));

    [Theory]
    [InlineData(@".\serve.py", @"C:\Users\me\site\serve.py")]
    [InlineData(@"..\x", @"C:\Users\me\x")]
    [InlineData(@"\x", @"C:\x")]
    [InlineData(@"D:\y", @"D:\y")]
    [InlineData("scripts/mock.py", @"C:\Users\me\site\scripts\mock.py")]
    public void Combines(string rel, string full) => Assert.Equal(full, WinPath.Combine(@"C:\Users\me\site", rel));

    [Fact]
    public void Containment()
    {
        Assert.True(WinPath.IsUnder(@"C:\Users\me\site", @"c:\users\ME"));
        Assert.True(WinPath.IsUnder(@"C:\Users\me\site", @"C:\Users\me\"));
        Assert.False(WinPath.IsUnder(@"C:\Users\meow", @"C:\Users\me"));
        Assert.False(WinPath.IsUnder(@"C:\Users\me", @"C:\Users\me"));
        Assert.True(WinPath.IsSameOrUnder(@"C:\Users\me\", @"c:\users\me"));
        Assert.True(WinPath.Eq("c:/x/", @"C:\X"));
    }

    [Fact]
    public void Names()
    {
        Assert.Equal("site", WinPath.FileName(@"C:\Users\me\site\"));
        Assert.Equal("py", WinPath.Extension("serve.py"));
        Assert.Equal("", WinPath.Extension(".gitignore"));
        Assert.Equal("", WinPath.Extension(@"C:\a.b\c"));
        Assert.Equal("auth-mock", WinPath.WithoutExtension("auth-mock.py"));
        Assert.Equal(@"~\site", WinPath.Abbreviate(@"C:\Users\me\site", @"C:\Users\me"));
        Assert.Equal("~", WinPath.Abbreviate(@"c:\users\me\", @"C:\Users\me"));
        Assert.Equal(@"D:\x", WinPath.Abbreviate(@"D:\x", @"C:\Users\me"));
    }
}
