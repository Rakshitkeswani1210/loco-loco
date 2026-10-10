import AppKit
import SwiftUI

/// Sizes from the approved mockup (docs/flow/iteration-2). Corners are concentric: 6pt rows inside 6pt padding make a 12pt panel.
enum Metrics {
  static let width: CGFloat = 320
  static let padding: CGFloat = 6
  static let radius: CGFloat = 12
  static let rowHeight: CGFloat = 28
  static let groupGap: CGFloat = 8
  static let rowRadius: CGFloat = 6
  static let rowInset: CGFloat = 10
  static let portWidth: CGFloat = 44
  static let trailGap: CGFloat = 12
  static let buttonHeight: CGFloat = 22
  /// Row action buttons share one width, so their icons line up across rows.
  static let actionWidth: CGFloat = 21.5
  /// Transparent room around the panel for its outer hairline.
  static let margin: CGFloat = 1
  static let gapBelowMenuBar: CGFloat = 5
  static let screenInset: CGFloat = 6
  static let shownStopped = 5
  /// The sleeping octopus under "Nothing running".
  static let emptyHeight: CGFloat = 56
  static let octopusHeight: CGFloat = 34
  static let octopusLine: CGFloat = 1.5
}

/// AppKit text colours on a solid surface. Secondary is nudged to pass 4.5:1 on white.
enum Palette {
  private static func make(_ light: NSColor, _ dark: NSColor, contrast: (NSColor, NSColor)? = nil) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      switch appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) {
      case .darkAqua?: dark
      case .accessibilityHighContrastDarkAqua?: contrast?.1 ?? dark
      case .accessibilityHighContrastAqua?: contrast?.0 ?? light
      default: light
      }
    })
  }
  private static func black(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: a) }
  private static func white(_ a: CGFloat) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: a) }
  private static func hex(_ v: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
  }

  static let label = make(black(0.85), white(0.88), contrast: (black(1), white(1)))
  static let secondary = make(black(0.56), white(0.55), contrast: (black(0.72), white(0.72)))
  /// Decoration only, never text.
  static let tertiary = make(black(0.26), white(0.25), contrast: (black(0.5), white(0.5)))
  static let surface = make(hex(0xffffff), hex(0x252527))
  static let hover = make(black(0.05), white(0.07), contrast: (black(0.1), white(0.14)))
  static let press = make(black(0.07), white(0.10), contrast: (black(0.14), white(0.2)))
  static let red = make(hex(0xd70015), hex(0xff453a))
  static let outerRing = make(black(0.14), black(0.7), contrast: (black(0.5), black(1)))
  static let innerRing = make(black(0), white(0.1), contrast: (black(0), white(0.4)))
  static let buttonRing = make(black(0.2), white(0.16), contrast: (black(0.5), white(0.4)))
  static let buttonShadow = make(black(0.06), black(0))
}

enum TimeText {
  /// "10:37 AM" today, "Oct 7" this year, "Oct 7, 2025" before.
  static func short(_ date: Date, now: Date = Date()) -> String {
    let cal = Calendar.current
    if cal.isDate(date, inSameDayAs: now) {
      // The formatter puts a narrow space before AM and PM; the design uses a full one.
      return date.formatted(date: .omitted, time: .shortened).replacingOccurrences(of: "\u{202F}", with: " ")
    }
    if cal.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.abbreviated).day()) }
    return date.formatted(.dateTime.month(.abbreviated).day().year())
  }
}
