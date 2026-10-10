import AppKit

// Usage: swift export-symbols.swift <outDir> name[:weight] ...
let args = Array(CommandLine.arguments.dropFirst())
let outDir = args[0]
let weights: [String: NSFont.Weight] = ["regular": .regular, "medium": .medium, "semibold": .semibold, "bold": .bold, "light": .light]
var manifest: [String: [String: Any]] = [:]
let pt: CGFloat = 64, scale: CGFloat = 2

for spec in args.dropFirst() {
    let parts = spec.split(separator: ":").map(String.init)
    let name = parts[0], weightName = parts.count > 1 ? parts[1] : "regular"
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil),
          let img = base.withSymbolConfiguration(.init(pointSize: pt, weight: weights[weightName] ?? .regular)) else {
        print("MISSING \(name)"); continue
    }
    let size = img.size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    let file = "\(name)-\(weightName).png"
    let png = rep.representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(outDir)/\(file)"))
    // The mockups use the PNG as a CSS mask, so the manifest carries it inline as a data URI.
    manifest["\(name)-\(weightName)"] = ["w": Double(size.width), "h": Double(size.height),
                                           "src": "data:image/png;base64," + png.base64EncodedString()]
}
let json = try! JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try! ("window.SYMBOLS = " + String(data: json, encoding: .utf8)! + ";\n").write(toFile: "\(outDir)/symbols.js", atomically: true, encoding: .utf8)
print("exported \(manifest.count)")
