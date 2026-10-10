// Draws the app icon into an .iconset folder: the white line octopus on a deep sea navy squircle (docs/brand).
// scripts/build.sh compiles it with the app's octopus geometry:
//   swiftc -parse-as-library scripts/make-icon.swift Sources/LocoLoco/Octopus.swift -o build/make-icon
//   build/make-icon <out.iconset>
import AppKit

@main
enum MakeIcon {
  static func main() throws {
    let out = URL(fileURLWithPath: CommandLine.arguments[1])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                       ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
      let rep = Octopus.bitmap(side: 1024, scale: CGFloat(px) / 1024) { draw($0, px: px) }
      rep.size = NSSize(width: px, height: px)
      try rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon_\(name).png"))
    }
  }

  /// Apple's icon grid: an 824pt superellipse centred on a 1024pt canvas.
  static func squircle(_ r: CGRect) -> CGPath {
    let p = CGMutablePath()
    let n = 5.0, steps = 720
    for i in 0..<steps {
      let t = Double(i) / Double(steps) * 2 * .pi
      let c = cos(t), s = sin(t)
      let x = pow(abs(c), 2 / n) * (c < 0 ? -1 : 1), y = pow(abs(s), 2 / n) * (s < 0 ? -1 : 1)
      let pt = CGPoint(x: r.midX + x * r.width / 2, y: r.midY + y * r.height / 2)
      i == 0 ? p.move(to: pt) : p.addLine(to: pt)
    }
    p.closeSubpath()
    return p
  }

  /// Draws on the 1024 canvas, y up. Shadows are set in pixels, so they scale with `px`.
  static func draw(_ cg: CGContext, px: Int) {
    let k = CGFloat(px) / 1024
    let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    func hex(_ v: UInt32) -> CGColor {
      CGColor(srgbRed: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
    let top = hex(0x16465A), bottom = hex(0x0D2B3B)
    let body = squircle(CGRect(x: 100, y: 100, width: 824, height: 824))

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10 * k), blur: 20 * k, color: CGColor(gray: 0, alpha: 0.28))
    cg.addPath(body)
    cg.setFillColor(bottom)
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(body)
    cg.clip()
    let gradient = CGGradient(colorsSpace: srgb, colors: [top, bottom] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
    cg.restoreGState()

    // The 512 grid scaled by 1.06 and centred, flipped to y down. Small sizes get a heavier line and eyes.
    let small = px <= 32
    cg.saveGState()
    cg.translateBy(x: 0, y: 1024)
    cg.scaleBy(x: 1, y: -1)
    cg.translateBy(x: 512 - 256 * 1.06, y: 512 - 254 * 1.06 + 6)
    cg.scaleBy(x: 1.06, y: 1.06)
    cg.setStrokeColor(.white)
    cg.setFillColor(.white)
    cg.setLineWidth(small ? 34 : 22)
    cg.setLineCap(.round)
    cg.setLineJoin(.round)
    cg.addPath(Octopus.path(Octopus.lineOuter))
    for arm in Octopus.lineInner { cg.addPath(Octopus.path(arm)) }
    cg.strokePath()
    let r: CGFloat = small ? 20 : 15
    for e in Octopus.eyes { cg.fillEllipse(in: CGRect(x: e.x - r, y: e.y + 4 - r, width: 2 * r, height: 2 * r)) }
    cg.restoreGState()
  }
}
