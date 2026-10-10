import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private let model = Model()
  private var controller: AppController?
  #if TEST_HOOKS
  private var hooks: TestHooks?
  #endif

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.accessory)
    let controller = AppController(model: model)
    self.controller = controller
    #if TEST_HOOKS
    hooks = TestHooks(controller: controller)
    #endif
    model.begin()
    addLoginItemOnce()
  }

  func applicationWillTerminate(_ notification: Notification) {
    model.save()
  }

  /// Turns on Launch at login the first time the app runs from its bundle. The ··· menu turns it off.
  private func addLoginItemOnce() {
    let key = "addedLoginItem"
    guard Bundle.main.bundleURL.pathExtension == "app", !UserDefaults.standard.bool(forKey: key) else { return }
    try? SMAppService.mainApp.register()
    UserDefaults.standard.set(true, forKey: key)
  }
}

MainActor.assumeIsolated {
  let delegate = AppDelegate()
  NSApplication.shared.delegate = delegate
  NSApplication.shared.run()
}
