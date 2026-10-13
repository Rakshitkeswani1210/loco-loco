using static LocoCore.Naming;

namespace LocoCore.Tests;

public class NamingTests
{
    const string Home = @"C:\Users\me";

    static string? Script(string cwd, params string[] argv) => ScriptName(argv, cwd, Home);

    // MARK: Ported from the Mac's NamingTests

    [Fact]
    public void AScriptInAnotherFolderNamesTheServer() =>
        Assert.Equal("auth-mock", Script(@"C:\Users\me\Documents\Work", "python", @"C:\Users\me\tools\scripts\auth-mock.py", "--port", "8090"));

    [Fact]
    public void AScriptInItsOwnFolderLeavesTheNameToTheFolder()
    {
        Assert.Null(Script(@"C:\Users\me\api-mock", "python", "serve.py"));
        Assert.Null(Script(@"C:\Users\me\api-mock", "python", @".\serve.py"));
        Assert.Null(Script(@"C:\Users\me\site\app", "node", @"C:\Users\me\site\app\server.js"));
    }

    [Fact]
    public void AScriptInASubfolderOrALooseFolderNamesTheServer()
    {
        Assert.Equal("mock", Script(@"C:\Users\me\site", "python", @"scripts\mock.py"));
        Assert.Equal("serve", Script(@"C:\Users\me\Downloads", "python", "serve.py"));
        Assert.Equal("serve", Script(@"C:\Users\me\OneDrive\Desktop", "python", "serve.py"));
    }

    [Fact]
    public void ToolsAndModulesAreNotScripts()
    {
        Assert.Null(Script(@"C:\Users\me\site", "node", @"C:\Users\me\site\node_modules\vite\bin\vite.js"));
        Assert.Null(Script(@"C:\Users\me\site", "node", "C:/Users/me/site/node_modules/vite/bin/vite.js"));
        Assert.Null(Script(@"C:\Users\me\site", "python", "-m", "http.server", "8000"));
    }

    // MARK: Programs

    [Theory]
    [InlineData(@"C:\Windows\system32\cmd.exe", "cmd")]
    [InlineData(@"C:\Python312\Python.EXE", "Python")]
    [InlineData("-zsh", "zsh")]
    [InlineData("node", "node")]
    [InlineData("C:/tools/caddy.com", "caddy")]
    public void ProgramNames(string path, string name) => Assert.Equal(name, ProgramName(path));

    // MARK: cmd

    [Theory]
    [InlineData(@"C:\Windows\system32\cmd.exe /d /s /c ""npm run dev""", "npm run dev")]
    [InlineData(@"""C:\Windows\system32\cmd.exe"" /c npm run dev", "npm run dev")]
    [InlineData(@"cmd.exe /c """"C:\Program Files\nodejs\npm.cmd"" run dev""", @"""C:\Program Files\nodejs\npm.cmd"" run dev")]
    [InlineData(@"cmd /c ""C:\Program Files\nodejs\node.exe""", @"""C:\Program Files\nodejs\node.exe""")]
    [InlineData(@"cmd /s /c ""C:\Program Files\nodejs\node.exe""", @"C:\Program Files\nodejs\node.exe")]
    [InlineData(@"cmd /C ""cd /d C:\x && npm start""", @"cd /d C:\x && npm start")]
    [InlineData(@"cmd /e:on /v:off /c npm start", "npm start")]
    public void CmdScripts(string raw, string script)
    {
        var s = Shell(ProcCommand.From(raw));
        Assert.Equal(ShellKind.Cmd, s.Kind);
        Assert.Equal(script, s.Script);
        Assert.False(s.Interactive);
    }

    [Theory]
    [InlineData(@"C:\Windows\system32\cmd.exe")]
    [InlineData(@"""C:\Windows\system32\cmd.exe"" ")]
    [InlineData("cmd /k npm run dev")]
    [InlineData(@"cmd.exe /d /K ""C:\Program Files\Microsoft Visual Studio\VsDevCmd.bat""")]
    public void InteractiveCmd(string raw)
    {
        var s = Shell(ProcCommand.From(raw));
        Assert.Equal(ShellKind.Cmd, s.Kind);
        Assert.True(s.Interactive);
        Assert.Null(s.Script);
    }

    [Fact]
    public void CmdPassingItsArgumentsOnIsASupervisor()
    {
        Assert.True(IsSupervisor(ProcCommand.From(@"cmd /c ""node server.js %*""")));
        Assert.False(IsSupervisor(ProcCommand.From(@"cmd /c ""node server.js""")));
    }

    // MARK: PowerShell

    [Theory]
    [InlineData("pwsh -NoLogo -NoProfile -Command npm run dev", "npm run dev", false)]
    [InlineData(@"pwsh -c ""npm start""", "npm start", false)]
    [InlineData("pwsh -ep Bypass -c npm start", "npm start", false)]
    [InlineData(@"pwsh -wd C:\x -command npm start", "npm start", false)]
    [InlineData(@"pwsh -WorkingDirectory:C:\x -Command npm start", "npm start", false)]
    [InlineData(@"pwsh -NoExit -Command ""& {npm run dev}""", "& {npm run dev}", true)]
    [InlineData(@"powershell.exe -NoProfile npm run dev", "npm run dev", false)]
    [InlineData(@"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe -ExecutionPolicy Bypass -Command ""python -m http.server""", "python -m http.server", false)]
    public void PowerShellScripts(string raw, string script, bool interactive)
    {
        var s = Shell(ProcCommand.From(raw));
        Assert.Equal(ShellKind.PowerShell, s.Kind);
        Assert.Equal(script, s.Script);
        Assert.Equal(interactive, s.Interactive);
    }

    [Theory]
    [InlineData("pwsh", true)]
    [InlineData("pwsh -NoLogo", true)]
    [InlineData("pwsh -NoProfile -Command -", true)]
    [InlineData("pwsh -NoExit -File profile.ps1", true)]
    [InlineData(@"powershell -ExecutionPolicy Bypass -File C:\x.ps1", false)]
    [InlineData("pwsh serve.ps1", false)]
    [InlineData("pwsh -EncodedCommand ZQBjAGgAbwA=", false)]
    public void PowerShellWithoutAReadableScript(string raw, bool interactive)
    {
        var s = Shell(ProcCommand.From(raw));
        Assert.Equal(ShellKind.PowerShell, s.Kind);
        Assert.Null(s.Script);
        Assert.Equal(interactive, s.Interactive);
    }

    // MARK: sh and bash

    [Fact]
    public void PosixShells()
    {
        var git = Shell(ProcCommand.From(@"""C:\Program Files\Git\usr\bin\bash.exe"" -lc ""npm run dev"""));
        Assert.Equal((ShellKind.Posix, "npm run dev", false), (git.Kind, git.Script, git.Interactive));
        Assert.True(IsInteractiveShell(ProcCommand.FromArgv("bash")));
        Assert.True(IsInteractiveShell(ProcCommand.FromArgv("-bash")));
        Assert.True(IsInteractiveShell(ProcCommand.FromArgv("bash", "--login", "-i")));
        Assert.False(IsInteractiveShell(ProcCommand.FromArgv("bash", "serve.sh")));
        Assert.Null(ShellScript(ProcCommand.FromArgv("bash", "serve.sh")));
        Assert.True(IsSupervisor(ProcCommand.FromArgv("sh", "-c", "exec \"$@\"", "sh", "npm", "run", "dev")));
        Assert.False(IsShell(ProcCommand.FromArgv("node", "server.js")));
    }

    // MARK: Boundaries

    [Fact]
    public void Hosts()
    {
        Assert.True(IsHost(["node"], ["node", @"C:\Users\me\AppData\Roaming\npm\node_modules\@github\copilot\index.js"]));
        Assert.True(IsHost(["node"], ["node", "C:/Users/me/AppData/Roaming/npm/node_modules/@anthropic-ai/claude-code/cli.js"]));
        Assert.True(IsHost(["claude.exe"], ["claude.exe"]));
        Assert.True(IsHost(["", "Copilot.EXE"], []));
        Assert.False(IsHost(["node"], ["node", "server.js"]));
    }

    static readonly string[] Roots = [@"C:\Program Files", @"C:\Windows", @"C:\Users\me\AppData\Local\Programs", @"C:\Users\me\AppData\Local\Microsoft"];

    [Theory]
    [InlineData(@"C:\Program Files\Docker\Docker\resources\com.docker.backend.exe", true)]
    [InlineData(@"C:\Users\me\AppData\Local\Programs\Microsoft VS Code\Code.exe", true)]
    [InlineData(@"C:\Windows\System32\svchost.exe", true)]
    [InlineData(@"c:\program files\Microsoft\Edge\msedge.exe", true)]
    [InlineData(@"C:\Program Files\nodejs\node.exe", false)]
    [InlineData(@"C:\Users\me\AppData\Local\Programs\Python\Python312\python.exe", false)]
    [InlineData(@"C:\Users\me\AppData\Local\Programs\Python\Python312\Scripts\streamlit.exe", false)]
    [InlineData(@"C:\Users\me\AppData\Local\Microsoft\WinGet\Packages\uv\uv.exe", false)]
    [InlineData(@"C:\Program Files\nodejs\node_modules\npm\bin\tool.exe", false)]
    [InlineData(@"C:\Users\me\site\server.exe", false)]
    [InlineData(@"C:\Program Files Extra\x.exe", false)]
    [InlineData("caddy.exe", false)]
    [InlineData("", false)]
    public void AppExecutables(string exe, bool app) => Assert.Equal(app, IsAppExecutable(exe, Roots));

    [Theory]
    [InlineData("npm run dev", true)]
    [InlineData("cd /d C:\\x && npm start", true)]
    [InlineData("cat <<EOF", false)]
    [InlineData("a\nb", false)]
    [InlineData("  ", false)]
    public void Rerunnable(string script, bool ok) => Assert.Equal(ok, IsRerunnable(script));

    // MARK: Names and projects

    [Fact]
    public void UvRunNames()
    {
        Assert.Equal("app", UvRunName(["uv", "run", "--project", "x", "app.py"]));
        Assert.Equal("serve", UvRunName([@"C:\Users\me\.local\bin\uv.exe", "run", "--with", "flask", "serve"]));
        Assert.Equal("api", UvRunName(["uv run --directory foo api"]));
        Assert.Null(UvRunName(["uv", "run", "python", "x.py"]));
        Assert.Null(UvRunName(["uv", "sync"]));
        Assert.Null(UvRunName(["node", "x.js"]));
    }

    static Func<string, bool> Files(params string[] files)
    {
        var set = new HashSet<string>(files, StringComparer.OrdinalIgnoreCase);
        return set.Contains;
    }

    [Fact]
    public void ProjectsInsideGit()
    {
        var exists = Files(@"C:\Users\me\repo\.git", @"C:\Users\me\repo\web\package.json", @"C:\Users\me\repo\web\dist\package.json");
        Assert.Equal((@"C:\Users\me\repo\web", true), Project(@"C:\Users\me\repo\web\dist", Home, exists));
        Assert.Equal((@"C:\Users\me\repo\web", true), Project(@"C:\Users\me\repo\web\src\", Home, exists));
        Assert.Equal((@"C:\Users\me\repo", true), Project(@"C:\Users\me\repo\tools", Home, exists));
    }

    [Fact]
    public void ProjectsOutsideGit()
    {
        Assert.Equal((@"C:\Users\me\Documents\site", false), Project(@"C:\Users\me\Documents\site\dist\docs", Home, Files()));
        Assert.Equal((@"C:\Users\me\Documents\site", true),
            Project(@"C:\Users\me\Documents\site\out", Home, Files(@"C:\Users\me\Documents\site\pyproject.toml")));
        // A dotfiles repo in the user folder doesn't make everything a project.
        Assert.Equal((@"C:\Users\me\loose", false), Project(@"C:\Users\me\loose", Home, Files(@"C:\Users\me\.git")));
        Assert.Equal((@"C:\Users\me\dist", false), Project(@"C:\Users\me\dist", Home, Files()));
    }

    [Fact]
    public void ProjectsOutsideTheUserFolderStayAsTheyAre()
    {
        Assert.Equal((@"C:\dev\site", false), Project(@"C:\dev\site", Home, Files(@"C:\dev\site\.git")));
        Assert.Equal((Home, false), Project(Home, Home, Files()));
    }

    // MARK: Commands

    [Fact]
    public void CommandLines()
    {
        const string node = @"C:\Program Files\nodejs\node.exe";
        const string path = @"C:\Windows;""C:\Program Files\nodejs"";C:\Python312";
        Assert.Equal("npm run dev", CommandLineFor([node, @"C:\Program Files\nodejs\node_modules\npm\bin\npm-cli.js", "run", "dev"], null));
        Assert.Equal("npx vite --port 5173", CommandLineFor([node, "C:/Program Files/nodejs/node_modules/npm/bin/npx-cli.js", "vite", "--port", "5173"], null));
        Assert.Equal("pnpm dev", CommandLineFor([node, @"C:\Users\me\AppData\Local\pnpm\node_modules\pnpm\bin\pnpm.cjs", "dev"], null));
        Assert.Equal("yarn start", CommandLineFor(["node", @"C:\Users\me\AppData\Roaming\npm\node_modules\yarn\bin\yarn.js", "start"], null));
        Assert.Equal("node server.js", CommandLineFor([node, "server.js"], path));
        Assert.Equal(@"""C:\Program Files\nodejs\node.exe"" server.js", CommandLineFor([node, "server.js"], null));
        Assert.Equal(@"""C:\Program Files\nodejs\node.exe"" server.js", CommandLineFor([node, "server.js"], @"C:\Windows"));
        Assert.Equal("python -m http.server 8000", CommandLineFor(["python", "-m", "http.server", "8000", "", " "], null));
        Assert.Equal(@"node ""my server.js"" --title ""a & b""", CommandLineFor(["node", "my server.js", "--title", "a & b"], null));
        Assert.Equal("", CommandLineFor([], null));
    }
}
