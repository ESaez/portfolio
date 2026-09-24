// Draws the app icon (a gauge on a blue-violet tile) into an .iconset folder.
//
//   swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(1)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

func render(pixels: Int) -> Data? {
    guard
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    let size = CGFloat(pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

    // The standard macOS icon grid: a rounded square inset from the canvas.
    let inset = size * 0.1
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.25, green: 0.56, blue: 1.0, alpha: 1),
        ending: NSColor(calibratedRed: 0.42, green: 0.27, blue: 0.93, alpha: 1))
    gradient?.draw(in: shape, angle: -90)

    let configuration = NSImage.SymbolConfiguration(pointSize: size * 0.4, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: nil)?
        .withSymbolConfiguration(configuration)
    {
        let symbolSize = symbol.size
        symbol.draw(
            in: NSRect(
                x: (size - symbolSize.width) / 2, y: (size - symbolSize.height) / 2,
                width: symbolSize.width, height: symbolSize.height))
    }

    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        guard let data = render(pixels: base * scale) else { exit(1) }
        try data.write(to: folder.appendingPathComponent(name))
    }
}
