import AppKit
import LocoCore
import SwiftUI

/// A titled window whose ⌘W and ⌘Q work, since a menu bar app has no menus to hold them.
final class SettingsWindow: NSWindow {
  override func performKeyEquivalent(with e: NSEvent) -> Bool {
    if super.performKeyEquivalent(with: e) { return true }
    guard e.type == .keyDown, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return false }
    switch e.charactersIgnoringModifiers {
    case "w": performClose(nil)
    case "q": NSApp.terminate(nil)
    default: return false
    }
    return true
  }
}

/// The Settings window. Opening it brings Loco Loco forward; closing it gives focus back to the app you were in.
@MainActor
final class SettingsController: NSObject, NSWindowDelegate {
  private let model: Model
  private let hotKey: HotKey
  private(set) var window: SettingsWindow?
  private var returnFocusTo: NSRunningApplication?
  private var observer: NSObjectProtocol?

  init(model: Model, hotKey: HotKey) {
    self.model = model
    self.hotKey = hotKey
    super.init()
    // Once you've gone to another app and back, closing leaves focus to macOS.
    observer = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      MainActor.assumeIsolated { self?.returnFocusTo = nil }
    }
  }

  var isVisible: Bool { window?.isVisible ?? false }

  func show(returningFocusTo app: NSRunningApplication?) {
    let window = makeWindow()
    if !window.isVisible || !NSApp.isActive { returnFocusTo = app }
    model.refreshLaunchAtLogin()
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    // Nothing starts focused, so the shortcut doesn't look like it's waiting for keys.
    window.makeFirstResponder(nil)
  }

  /// Made the first time it's needed, then kept.
  func makeWindow() -> SettingsWindow {
    if let window { return window }
    let host = NSHostingController(rootView: SettingsView(model: model, settings: self))
    host.sizingOptions = [.preferredContentSize]
    let w = SettingsWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
    w.contentViewController = host
    w.title = "Loco Loco Settings"
    w.isReleasedWhenClosed = false
    w.isRestorable = false
    w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
    w.delegate = self
    w.center()
    w.setFrameAutosaveName("Settings")
    window = w
    return w
  }

  func windowDidBecomeKey(_ notification: Notification) { model.refreshLaunchAtLogin() }

  func windowWillClose(_ notification: Notification) {
    if NSApp.isActive {
      if let app = returnFocusTo, !app.isTerminated { app.activate() } else { NSApp.deactivate() }
    }
    returnFocusTo = nil
  }

  // MARK: Actions

  /// Saves new keys, or says why they can't be used.
  func record(_ s: Shortcut?) -> String? {
    if let s, s != model.shortcut, s.isTakenBySystem {
      return "macOS already uses \(s.title). Try other keys, or turn that one off in System Settings > Keyboard > Keyboard Shortcuts."
    }
    guard hotKey.register(s) else { return "Couldn't use \(s?.title ?? "those keys"). Try other keys." }
    model.setShortcut(s)
    return nil
  }

  /// The shortcut is off while recording, so pressing it records it instead of opening the panel.
  func recording(_ on: Bool) {
    if on { hotKey.unregister() } else { hotKey.register(model.shortcut) }
  }

  func setLaunchAtLogin(_ on: Bool) {
    do {
      try model.setLaunchAtLogin(on)
    } catch {
      guard let window else { return }
      let a = NSAlert()
      a.messageText = on ? "Couldn't turn on Launch at login" : "Couldn't turn off Launch at login"
      a.informativeText = error.localizedDescription
      a.beginSheetModal(for: window)
    }
  }
}

struct SettingsView: View {
  let model: Model
  let settings: SettingsController
  @State private var shortcutError: String?

  var body: some View {
    Form {
      Section {
        Toggle("Launch at login", isOn: binding(model.launchAtLogin) { settings.setLaunchAtLogin($0) })
        Toggle("Show count in menu bar", isOn: binding(model.showCount) { model.setShowCount($0) })
        Toggle("Show app and macOS servers", isOn: binding(model.showAll) { model.setShowAll($0) })
        Toggle("Group by project", isOn: binding(model.groupByProject) { model.setGroupByProject($0) })
      }
      Section {
        Picker("Appearance", selection: binding(model.appearance) { model.setAppearance($0) }) {
          ForEach(Appearance.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        Toggle("Transparent background", isOn: binding(model.transparent) { model.setTransparent($0) })
      }
      Section {
        HStack {
          Text("Keyboard shortcut")
          Spacer()
          ShortcutRecorder(
            shortcut: model.shortcut,
            onRecord: { s in
              let error = settings.record(s)
              shortcutError = error
              return error
            },
            onRecording: { on in
              settings.recording(on)
              if !on { shortcutError = nil }
            })
          .frame(width: ShortcutField.size.width, height: ShortcutField.size.height)
        }
      } footer: {
        Group {
          if let shortcutError {
            Label(shortcutError, systemImage: "exclamationmark.triangle.fill")
          } else {
            Text("Opens Loco Loco in the middle of the screen, from any app. Click it, then press the keys you want, or Delete for none.")
          }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
      Section {
        Picker("Keep history", selection: binding(model.historyLimit) { model.setHistoryLimit($0) }) {
          ForEach([10, 20, 50], id: \.self) { Text("\($0) servers").tag($0) }
        }
      }
    }
    .formStyle(.grouped)
    .scrollDisabled(true)
    .frame(width: 440)
    .fixedSize(horizontal: false, vertical: true)
  }

  /// Reads the value here, so the view updates when it changes.
  private func binding<T>(_ value: T, _ set: @escaping @MainActor (T) -> Void) -> Binding<T> {
    Binding(get: { value }, set: { set($0) })
  }
}

struct ShortcutRecorder: NSViewRepresentable {
  let shortcut: Shortcut?
  let onRecord: @MainActor (Shortcut?) -> String?
  let onRecording: @MainActor (Bool) -> Void

  func makeNSView(context: Context) -> ShortcutField {
    ShortcutField(shortcut: shortcut)
  }

  func updateNSView(_ field: ShortcutField, context: Context) {
    field.onRecord = onRecord
    field.onRecording = onRecording
    if !field.isRecording, field.shortcut != shortcut { field.shortcut = shortcut }
  }
}
