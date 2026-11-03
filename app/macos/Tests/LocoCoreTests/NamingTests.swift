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

@Suite struct TaskTests {
  @Test func testsAndBuildsAreTasks() {
    for c in [
      "npm test", #"cd "/Users/me/Acme /kit" && npm test 2>&1 | tail -25"#, "npm run test:widgets", "pnpm build", "yarn lint",
      "npm run gen >/dev/null 2>&1 && npm run build:static > /tmp/b.log 2>&1", "npx vitest run", "npx playwright test", "pnpm exec next build",
      "CI=1 npx jest", "pytest tests", "npm run typecheck 2>&1 | tail -5", "kill 6556; sleep 2; cd x && npm run build",
    ] {
      #expect(Naming.isTaskCommand(c), "\(c)")
    }
  }

  @Test func serversAreNotTasks() {
    for c in [
      "npm run dev", "npm start", "pnpm dev", "npm run build && npm start", "cd x && npx next dev -p 3470", "next start -p 3000", "vite",
      "vite preview --port 4193", "python3 -m http.server 3601", "NEXT_PUBLIC_API=http://127.0.0.1:8002 pnpm exec next dev -p 3102",
      "bash ~/.cache/api-8002.sh > log 2>&1", "npm run test-server-mock-free && npm run dev", "python3 cap.py shots",
    ] {
      #expect(!Naming.isTaskCommand(c), "\(c)")
    }
  }

  @Test func aYoungServerOnARandomPortIsATask() {
    #expect(Naming.isTask(command: "python3 scripts/check-site.py", ports: [62625], age: 140))
    #expect(Naming.isTask(command: "python3 -m http.server 0", ports: [49152], age: 0))
  }

  @Test func itBecomesAServerOnceItLasts() {
    #expect(!Naming.isTask(command: "python3 scripts/preview.py", ports: [62625], age: Naming.taskSeconds))
  }

  @Test func aFixedPortIsAServerHoweverYoung() {
    #expect(!Naming.isTask(command: "python3 -m http.server 3617 -d out", ports: [3617], age: 54))
    #expect(!Naming.isTask(command: "python3 -m http.server 49151", ports: [49151], age: 1))
    #expect(!Naming.isTask(command: "node server.js", ports: [3000, 62000], age: 1))
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
