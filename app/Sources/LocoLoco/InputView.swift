import AppKit

/// A clear view over the SwiftUI panel that handles the pointer and keyboard the way a menu does.
/// The panel lives in an inactive app's non-activating window, where SwiftUI hover and clicks aren't dependable.
final class InputView: NSView, NSViewToolTipOwner {
  let model: Model
  /// The SwiftUI view underneath. Accessibility asks for it off the main actor's bookkeeping, always on the main thread.
  nonisolated(unsafe) weak var content: NSView?
  /// The target under the pointer at mouse down: `btn:…`, `row:…`.
  private var pressed: String?

  init(model: Model) {
    self.model = model
    super.init(frame: .zero)
    setAccessibilityElement(false)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
  override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    for area in trackingAreas { removeTrackingArea(area) }
    addTrackingArea(NSTrackingArea(
      rect: .zero,
      options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect, .enabledDuringMouseDrag],
      owner: self))
  }

  private func local(_ e: NSEvent) -> CGPoint { convert(e.locationInWindow, from: nil) }

  /// Where the pointer is now, in this view, or nil when it's outside.
  func currentPointer() -> CGPoint? {
    guard let window else { return nil }
    let p = convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
    return bounds.contains(p) ? p : nil
  }

  // MARK: Pointer

  override func mouseMoved(with e: NSEvent) { model.pointerMoved(to: local(e)) }
  override func mouseDragged(with e: NSEvent) { model.pointerMoved(to: local(e)) }

  /// Entering can follow a resize under a still pointer, so it doesn't count as a move.
  override func mouseEntered(with e: NSEvent) {
    model.pointer = local(e)
    model.hover()
  }

  override func mouseExited(with e: NSEvent) {
    model.pointer = nil
    model.staleUnderPointer = false
    if !model.keyboardDriven { model.hover() }
  }

  private func targetID(_ t: Model.Target) -> String? { t.hot ?? t.row.map { "row:" + $0 } }

  override func mouseDown(with e: NSEvent) {
    if e.modifierFlags.contains(.control) { rightMouseDown(with: e); return }
    pressed = nil
    guard !model.staleUnderPointer else { return }
    let t = model.target(at: local(e))
    if t.hot == "menu" { model.perform(.more); return }
    pressed = targetID(t)
  }

  override func mouseUp(with e: NSEvent) {
    guard let pressed else { return }
    self.pressed = nil
    guard !model.staleUnderPointer, targetID(model.target(at: local(e))) == pressed else { return }
    activate(pressed)
  }

  override func rightMouseDown(with e: NSEvent) {
    guard !model.staleUnderPointer, let id = model.target(at: local(e)).row, id != Rows.more else { return }
    model.perform(.menu(id, local(e)))
  }

  private func activate(_ target: String) {
    let parts = target.split(separator: ":", maxSplits: 2).map(String.init)
    if parts.first == "btn", parts.count == 3, let action = RowAction(rawValue: parts[2]) {
      model.perform(.action(parts[1], action))
    } else if parts.first == "row", parts.count == 2 {
      model.perform(.primary(parts[1]))
    }
  }

  override func scrollWheel(with e: NSEvent) {
    guard let content, let superview = content.superview else { return }
    let p = superview.convert(e.locationInWindow, from: nil)
    (content.hitTest(p) ?? content).scrollWheel(with: e)
  }

  // MARK: Keyboard

  override func keyDown(with e: NSEvent) {
    switch e.keyCode {
    case 53: model.perform(.close)
    case 125: model.moveHighlight(1)
    case 126: model.moveHighlight(-1)
    case 36, 76: if let h = model.highlight { model.perform(.primary(h)) }
    default: super.keyDown(with: e)
    }
  }

  override func performKeyEquivalent(with e: NSEvent) -> Bool {
    guard e.type == .keyDown, e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
      return super.performKeyEquivalent(with: e)
    }
    let h = model.highlight
    switch (e.keyCode, e.charactersIgnoringModifiers ?? "") {
    case (51, _), (117, _): if let h { model.perform(.action(h, .stop)) }
    case (_, "r"): if let h { model.perform(.action(h, .restart)) }
    case (_, ","): model.perform(.more)
    case (_, "q"): NSApp.terminate(nil)
    case (_, "w"): model.perform(.close)
    default: return super.performKeyEquivalent(with: e)
    }
    return true
  }

  // MARK: Tooltips

  func updateToolTips() {
    removeAllToolTips()
    for (id, rect) in model.frames where id.hasPrefix("row:") && id != "row:" + Rows.more {
      addToolTip(rect, owner: self, userData: nil)
    }
  }

  func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
    guard let row = model.rows.row(model.target(at: point).row) else { return "" }
    return row.name + "\n" + (row.folder as NSString).abbreviatingWithTildeInPath
  }

  // MARK: Accessibility

  override func accessibilityHitTest(_ point: NSPoint) -> Any? {
    content?.accessibilityHitTest(point)
  }
}
