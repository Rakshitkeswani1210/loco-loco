import Testing
@testable import LocoCore

/// A launch chain as agents really start them: 3102 → 8002 → 8090, and 3103 → 8003 → 8090.
@Suite struct NeedsTests {
  let home = "/Users/me"
  let app3102 = #"cd "/Users/me/Documents/Acme /ops-platform/ts/apps/ops-command-center" && NEXT_PUBLIC_OPS_VALIDATION_API_URL=http://127.0.0.1:8002 pnpm exec next dev -H 127.0.0.1 -p 3102 > ~/.cache/servers/logs/ops-command-center-3102.log 2>&1"#
  let api8002 = "bash ~/.cache/servers/api-8002.sh > ~/.cache/servers/logs/ops-api-8002.log 2>&1"
  let script8002 = """
    #!/bin/bash
    cd "/Users/me/Documents/Acme /ops-platform"
    export OPS_VALIDATION_AUTH__BASE_URL=http://127.0.0.1:8090/auth
    export OPS_VALIDATION_CORS_ORIGINS='["http://localhost:3102", "http://127.0.0.1:3102", "http://localhost:7777", "http://127.0.0.1:7777"]'
    export OPS_VALIDATION_PORT=8002
    exec "/Users/me/Documents/Acme /ops-platform/py/.venv/bin/ops-validation-api"
    """

  func files(_ f: [String: String]) -> (String) -> String? { { f[$0] } }

  @Test func theAppNeedsTheApiInItsCommand() {
    let ports = Needs.ports(command: app3102, dirs: ["/Users/me/Documents/Acme /ops-platform/ts/apps/ops-command-center"], own: [3102], home: home, read: files([:]))
    #expect(ports == [8002])
  }

  @Test func theApiNeedsTheMockInItsScriptButNotTheAppsInItsCorsList() {
    let ports = Needs.ports(command: api8002, dirs: ["/Users/me/Documents/Acme "], own: [8002], home: home,
                            read: files(["/Users/me/.cache/servers/api-8002.sh": script8002]))
    #expect(ports == [8090])
  }

  @Test func envFilesInTheFolderAndProjectCount() {
    let ports = Needs.ports(command: "pnpm dev", dirs: ["/Users/me/site/web", "/Users/me/site"], own: [5173], home: home,
                            read: files(["/Users/me/site/web/.env.local": "VITE_API=http://localhost:8000/api\nALLOWED_ORIGINS=http://localhost:5173",
                                         "/Users/me/site/.env": "AUTH_URL=http://[::1]:9099\n"]))
    #expect(ports == [8000, 9099])
  }

  @Test func itsOwnPortIsNotANeed() {
    #expect(Needs.ports(command: "vite --port 5173 --open http://localhost:5173", dirs: [], own: [5173], home: home, read: files([:])).isEmpty)
  }

  @Test func theEnvironmentCountsButNotItsCorsList() {
    let env = ["NEXT_PUBLIC_API_URL": "http://127.0.0.1:8002", "CORS_ORIGINS": #"["http://localhost:3102", "http://127.0.0.1:7777"]"#,
               "HOME": "/Users/me", "PORT": "3102", "SELF": "http://localhost:3102"]
    #expect(Needs.ports(env: env, own: [3102]) == [8002])
  }

  @Test func scriptsAreFoundAfterAShellOrByTheirEnding() {
    #expect(Needs.scripts(in: "bash ~/x/api.sh > log 2>&1", dir: "/Users/me/a", home: home) == ["/Users/me/x/api.sh"])
    #expect(Needs.scripts(in: "cd b && ./start.sh", dir: "/Users/me/a", home: home) == ["/Users/me/a/start.sh"])
    #expect(Needs.scripts(in: "sh -c 'npm run dev'", dir: "/Users/me/a", home: home).isEmpty)
    #expect(Needs.scripts(in: "python3 -m http.server 8000", dir: "/Users/me/a", home: home).isEmpty)
  }
}

@Suite struct ServedFolderTests {
  let all: (String) -> Bool = { _ in true }

  @Test func httpServerDirectoryNamesTheFolder() {
    let argv = ["python3", "-m", "http.server", "8930", "--bind", "127.0.0.1", "--directory", "/Users/me/Documents/deck-gallery"]
    #expect(Naming.servedFolder(argv, cwd: "/Users/me/Documents/deck tools", isFolder: all) == "/Users/me/Documents/deck-gallery")
    #expect(Naming.servedFolder(["python3", "-m", "http.server", "-d", "out"], cwd: "/Users/me/site", isFolder: all) == "/Users/me/site/out")
    #expect(Naming.servedFolder(["python3", "-m", "http.server", "--directory=decks"], cwd: "/Users/me/site", isFolder: all) == "/Users/me/site/decks")
  }

  @Test func theFolderItRunsInIsNotAServedFolder() {
    #expect(Naming.servedFolder(["python3", "-m", "http.server", "8953", "--directory", "."], cwd: "/Users/me/site", isFolder: all) == nil)
    #expect(Naming.servedFolder(["python3", "-m", "http.server", "8000"], cwd: "/Users/me/site", isFolder: all) == nil)
  }

  @Test func serveAndHttpServerTakeTheFolderAfterTheirFlags() {
    #expect(Naming.servedFolder(["node", "/Users/me/.npm/_npx/1/node_modules/serve/build/main.js", "-l", "8080", "dist"], cwd: "/Users/me/site", isFolder: all) == "/Users/me/site/dist")
    #expect(Naming.servedFolder(["http-server", "-p", "8094", "/Users/me/www"], cwd: "/Users/me/site", isFolder: all) == "/Users/me/www")
  }

  @Test func aMissingFolderDoesntCount() {
    #expect(Naming.servedFolder(["python3", "-m", "http.server", "-d", "gone"], cwd: "/Users/me/site", isFolder: { _ in false }) == nil)
  }

  @Test func savedCommandsAreReadUpToTheServer() {
    let c = "mkdir -p ~/.cache/logs && cd \"/Users/me/Documents/deck tools\" && python3 -m http.server 8930 --directory ../deck-gallery > ~/.cache/logs/x.log 2>&1"
    #expect(Naming.servedFolder(command: c, cwd: "/Users/me", isFolder: all) == "/Users/me/Documents/deck-gallery")
    #expect(Naming.servedFolder(command: "cd /Users/me/a && python3 -m http.server 8811 --bind 127.0.0.1", cwd: "/Users/me", isFolder: all) == nil)
  }

  @Test func aStoppedStaticServerShowsItsFolder() {
    #expect(Naming.staticFolder(command: "cd /Users/me/decks/07-demo && python3 -m http.server 8947", cwd: "/Users/me", isFolder: all) == "/Users/me/decks/07-demo")
    #expect(Naming.staticFolder(command: "python3 -m http.server 8930 --directory /Users/me/gallery", cwd: "/Users/me/x", isFolder: all) == "/Users/me/gallery")
    #expect(Naming.staticFolder(command: "node /tmp/sanity/serve.mjs /Users/me/gallery/decks 8950", cwd: "/Users/me", isFolder: { $0 == "/Users/me/gallery/decks" }) == "/Users/me/gallery/decks")
    #expect(Naming.staticFolder(command: "cd /Users/me/app && pnpm dev", cwd: "/Users/me", isFolder: all) == nil)
  }

  @Test func shellWordsKeepQuotesAndSplitOperators() {
    #expect(Naming.shellWords(#"cd "Acme /x" && a=1 b 'c d' > log 2>&1; e || f | g"#)
            == ["cd", "Acme /x", "&&", "a=1", "b", "c d", ">", "log", "2>&1", ";", "e", "||", "f", "|", "g"])
  }
}
