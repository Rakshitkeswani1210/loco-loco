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
