import AppKit
import SwiftUI

/// The Loco Loco octopus, from the same paths as docs/brand/src/mark.mjs: a 512 grid with y pointing down.
/// scripts/make-icon.swift compiles this file too, so the app icon and the menu bar glyph share one drawing.
enum Octopus {
  struct Cubic: Sendable {
    var p0, p1, p2, p3: CGPoint

    func at(_ t: CGFloat) -> CGPoint {
      let u = 1 - t
      let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
      return CGPoint(x: a * p0.x + b * p1.x + c * p2.x + d * p3.x, y: a * p0.y + b * p1.y + c * p2.y + d * p3.y)
    }

    var mirrored: Cubic {
      func m(_ p: CGPoint) -> CGPoint { CGPoint(x: 512 - p.x, y: p.y) }
      return Cubic(p0: m(p0), p1: m(p1), p2: m(p2), p3: m(p3))
    }

    var reversed: Cubic { Cubic(p0: p3, p1: p2, p2: p1, p3: p0) }
  }

  // The solid mark: head, two eyes, four tapered arms.
  static let head = parse("M256 60C336 60 392 116 392 196C392 248 368 284 332 302L180 302C144 284 120 248 120 196C120 116 176 60 256 60")
  static let eyes = [CGPoint(x: 212, y: 218), CGPoint(x: 300, y: 218)]
  private static let outerArm = parse("M194 270C160 296 104 290 76 324C54 352 60 392 92 398C114 402 126 386 116 372")
  private static let innerArm = parse("M234 292C236 338 230 376 222 406C214 434 196 448 174 440")
  static let arms = [outerArm, innerArm, innerArm.map(\.mirrored), outerArm.map(\.mirrored)]

  // The line mark: one stroke from the left arm tip over the head to the right arm tip. The inner arms hang free.
  private static let lineSide = parse("M116 372C126 386 114 402 92 398C60 392 54 352 76 324C96 298 128 300 142 290C154 281 124 246 122 200")
  private static let lineTop = parse("M122 200C122 116 178 60 256 60C334 60 390 116 390 200")
  static let lineOuter = lineSide + lineTop + lineSide.reversed().map(\.mirrored.reversed)
  private static let lineInnerArm = parse("M228 302C230 342 226 378 218 406C210 432 192 446 172 438")
  static let lineInner = [lineInnerArm, lineInnerArm.map(\.mirrored)]

  /// Reads the M, C and L commands the mark uses.
  static func parse(_ d: String) -> [Cubic] {
    var tokens: [String] = [], number = ""
    func flush() { if !number.isEmpty { tokens.append(number); number = "" } }
    for ch in d {
      if ch.isLetter { flush(); tokens.append(String(ch)) }
      else if ch == " " || ch == "," { flush() }
      else if ch == "-" { flush(); number = "-" }
      else { number.append(ch) }
    }
    flush()

    var segments: [Cubic] = [], command = "M", current = CGPoint.zero, i = 0
    func point() -> CGPoint {
      defer { i += 2 }
      return CGPoint(x: Double(tokens[i])!, y: Double(tokens[i + 1])!)
    }
    while i < tokens.count {
      if tokens[i].first!.isLetter { command = tokens[i]; i += 1 }
      switch command {
      case "M": current = point()
      case "L":
        let p = point()
        let third = CGPoint(x: (p.x - current.x) / 3, y: (p.y - current.y) / 3)
        segments.append(Cubic(p0: current, p1: CGPoint(x: current.x + third.x, y: current.y + third.y),
                              p2: CGPoint(x: current.x + 2 * third.x, y: current.y + 2 * third.y), p3: p))
        current = p
      default:
        let a = point(), b = point(), p = point()
        segments.append(Cubic(p0: current, p1: a, p2: b, p3: p))
        current = p
      }
    }
    return segments
  }

  static func path(_ segments: [Cubic], closed: Bool = false) -> CGMutablePath {
    let p = CGMutablePath()
    guard let first = segments.first else { return p }
    p.move(to: first.p0)
    for s in segments { p.addCurve(to: s.p3, control1: s.p1, control2: s.p2) }
    if closed { p.closeSubpath() }
    return p
  }

  /// An arm that thins from r0 to r1 along its length: a union of discs, so fill it with the nonzero rule.
  static func taper(_ segments: [Cubic], r0: CGFloat, r1: CGFloat, ease: CGFloat = 0.9) -> CGPath {
    var points: [CGPoint] = []
    for (i, s) in segments.enumerated() {
      for k in (i == 0 ? 0 : 1)...80 { points.append(s.at(CGFloat(k) / 80)) }
    }
    var lengths: [CGFloat] = [0]
    for i in points.indices.dropFirst() {
      lengths.append(lengths[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
    }
    let total = lengths.last ?? 1
    let p = CGMutablePath()
    for (c, length) in zip(points, lengths) {
      let r = r0 + (r1 - r0) * pow(length / total, ease)
      p.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
    return p
  }

  /// Closed eyes: an arc under each eye position.
  static func sleepingEyes(width: CGFloat, sag: CGFloat, dy: CGFloat) -> CGMutablePath {
    let p = CGMutablePath()
    for e in eyes {
      let y = e.y + dy - sag / 2
      p.move(to: CGPoint(x: e.x - width / 2, y: y))
      p.addQuadCurve(to: CGPoint(x: e.x + width / 2, y: y), control: CGPoint(x: e.x, y: y + 2 * sag))
    }
    return p
  }

  /// Draws the solid mark in the 512 grid, with the eyes cut out of everything under them.
  static func drawSolid(in cg: CGContext, asleep: Bool) {
    cg.setFillColor(.black)
    cg.addPath(path(head, closed: true))
    cg.fillPath()
    for arm in arms { cg.addPath(taper(arm, r0: 36, r1: 20)) }
    cg.fillPath()

    cg.setBlendMode(.destinationOut)
    let rx: CGFloat = 24, ry: CGFloat = 30
    if asleep {
      for e in eyes {
        cg.move(to: CGPoint(x: e.x - 1.5 * rx, y: e.y - 4))
        cg.addQuadCurve(to: CGPoint(x: e.x + 1.5 * rx, y: e.y - 4), control: CGPoint(x: e.x, y: e.y + 1.4 * ry))
      }
      cg.setStrokeColor(.black)
      cg.setLineWidth(0.85 * rx)
      cg.setLineCap(.round)
      cg.strokePath()
    } else {
      for e in eyes { cg.addEllipse(in: CGRect(x: e.x - rx, y: e.y - ry, width: 2 * rx, height: 2 * ry)) }
      cg.fillPath()
    }
    cg.setBlendMode(.normal)
  }

  /// A square bitmap of `side` points at `scale`, drawn with y pointing up.
  static func bitmap(side: CGFloat, scale: CGFloat, draw: (CGContext) -> Void) -> NSBitmapImageRep {
    let px = Int((side * scale).rounded())
    let cg = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.scaleBy(x: scale, y: scale)
    draw(cg)
    let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
    rep.size = NSSize(width: side, height: side)
    return rep
  }

  /// The 16pt menu bar template image. Its eyes close when nothing is running.
  static func menuBarImage(asleep: Bool) -> NSImage {
    let side: CGFloat = 16
    let image = NSImage(size: NSSize(width: side, height: side))
    for scale: CGFloat in [1, 2] {
      image.addRepresentation(bitmap(side: side, scale: scale) { cg in
        // The glyph's view box is 31 30 450 450 in the grid.
        let s = side / 450
        cg.translateBy(x: 0, y: side)
        cg.scaleBy(x: s, y: -s)
        cg.translateBy(x: -31, y: -30)
        drawSolid(in: cg, asleep: asleep)
      })
    }
    image.isTemplate = true
    image.accessibilityDescription = "Loco Loco"
    return image
  }
}

/// The line octopus with closed eyes, for the empty panel. Fits its frame; stroke it with round caps and joins.
struct SleepingOctopus: Shape {
  func path(in rect: CGRect) -> Path {
    let p = Octopus.path(Octopus.lineOuter)
    for arm in Octopus.lineInner { p.addPath(Octopus.path(arm)) }
    p.addPath(Octopus.sleepingEyes(width: 52, sag: 20, dy: 4))
    let box = p.boundingBoxOfPath
    let s = min(rect.width / box.width, rect.height / box.height)
    let t = CGAffineTransform(translationX: rect.midX, y: rect.midY).scaledBy(x: s, y: s).translatedBy(x: -box.midX, y: -box.midY)
    return Path(p).applying(t)
  }
}
