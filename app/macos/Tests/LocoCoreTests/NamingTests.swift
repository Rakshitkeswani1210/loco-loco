import Testing
@testable import LocoCore

@Suite struct NamingTests {
  let home = "/Users/me"

  @Test func aScriptFromAnotherFolderNamesTheServer() {
    let argv = ["python3", "/Users/me/tools/scripts/auth-mock.py", "--port", "8090"]
    #expect(Naming.scriptName(argv, cwd: "/Users/me/Documents/Work ", home: home) == "auth-mock")
  }

  @Test func aScriptInItsOwnFolderLeavesTheNameToTheFolder() {
    #expect(Naming.scriptName(["python3", "serve.py"], cwd: "/Users/me/site/api-mock", home: home) == nil)
    #expect(Naming.scriptName(["python3", "./serve.py"], cwd: "/Users/me/site/api-mock", home: home) == nil)
    #expect(Naming.scriptName(["node", "/Users/me/site/app/server.js"], cwd: "/Users/me/site/app", home: home) == nil)
  }

  @Test func aScriptInASubfolderOrALooseFolderStillNamesTheServer() {
    #expect(Naming.scriptName(["python3", "scripts/mock.py"], cwd: "/Users/me/site", home: home) == "mock")
    #expect(Naming.scriptName(["python3", "serve.py"], cwd: "/Users/me/Downloads", home: home) == "serve")
  }

  @Test func flagsAndNodeModulesAreSkipped() {
    #expect(Naming.scriptName(["node", "/Users/me/x/node_modules/vite/bin/vite.js"], cwd: "/Users/me/y", home: home) == nil)
    #expect(Naming.scriptName(["python3", "-m", "http.server", "8000"], cwd: "/Users/me/y", home: home) == nil)
  }
}

@Suite struct ProjectTests {
  let home = "/Users/me"

  /// A fake file system: folders with a `.git` folder, and worktree pointers.
  func git(repos: [String] = [], pointers: [String: String] = [:]) -> (String) -> Naming.GitLink? {
    { dir in pointers[dir].map { .pointer(gitdir: $0) } ?? (repos.contains(dir) ? .repo : nil) }
  }

  @Test func theFirstFolderInDocumentsIsTheProject() {
    let g = git(repos: ["/Users/me/Documents/Acme /web-lab", "/Users/me/Documents/Globex/pr-93-station"])
    #expect(Naming.projectRoot(dir: "/Users/me/Documents/Acme /web-lab", home: home, git: g) == "/Users/me/Documents/Acme ")
    #expect(Naming.projectRoot(dir: "/Users/me/Documents/Globex/pr-93-station/web", home: home, git: g) == "/Users/me/Documents/Globex")
    #expect(Naming.projectRoot(dir: "/Users/me/Documents/Acme /offline-proto", home: home, git: g) == "/Users/me/Documents/Acme ")
  }

  @Test func aNestedRepoBelongsToTheProjectAboveIt() {
    let g = git(repos: ["/Users/me/Documents/Orbit", "/Users/me/Documents/Orbit/perf-prototype"])
    #expect(Naming.projectRoot(dir: "/Users/me/Documents/Orbit/perf-prototype", home: home, git: g) == "/Users/me/Documents/Orbit")
  }

  @Test func aWorktreeBelongsToItsMainRepo() {
    let g = git(pointers: [
      "/Users/me/Documents/acme-it9": "/Users/me/Documents/Acme /acme-latest/.git/worktrees/acme-it9",
      "/Users/me/Documents/Orbit-pr-1211": "../Orbit/.git/worktrees/Orbit-pr-1211",
    ])
    #expect(Naming.projectRoot(dir: "/Users/me/Documents/acme-it9/apps/web", home: home, git: g) == "/Users/me/Documents/Acme ")
    #expect(Naming.projectRoot(dir: "/Users/me/Documents/Orbit-pr-1211", home: home, git: g) == "/Users/me/Documents/Orbit")
  }

  @Test func aWorktreeOfARepoOutsideHomeKeepsItsOwnFolder() {
    let g = git(pointers: ["/Users/me/Documents/wt": "/Volumes/Work/repo/.git/worktrees/wt"])
    #expect(Naming.projectRoot(dir: "/Users/me/Documents/wt", home: home, git: g) == "/Users/me/Documents/wt")
  }

  @Test func foldersWithoutGitUseTheirOwnPath() {
    #expect(Naming.projectRoot(dir: "/Users/me/Documents/Testing deck skill/deck", home: home, git: git()) == "/Users/me/Documents/Testing deck skill")
    #expect(Naming.projectRoot(dir: "/Users/me/site/app", home: home, git: git()) == "/Users/me/site")
    #expect(Naming.projectRoot(dir: "/Users/me/Developer/GitHub/loco/app", home: home, git: git()) == "/Users/me/Developer/GitHub/loco")
  }

  @Test func looseHiddenAndOutsideFoldersHaveNoProject() {
    for dir in ["/Users/me/Documents", "/Users/me/Downloads", "/Users/me", "/Users/me/.cache/x", "/Users/me/Library/x", "/private/tmp/site"] {
      #expect(Naming.projectRoot(dir: dir, home: home, git: git()) == nil, "\(dir)")
    }
  }

  @Test func theNameDropsTrailingSpaces() {
    #expect(Naming.projectName("/Users/me/Documents/Acme ") == "Acme")
    #expect(Naming.projectName("/Users/me/Documents/Sam's branch ") == "Sam's branch")
  }
}
