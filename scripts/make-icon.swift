// Рисует иконку приложения (маяк на тёмном градиенте) и собирает AppIcon.icns.
// Использование: swift scripts/make-icon.swift Resources/AppIcon.icns
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"
let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("BeaconHub.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // Подложка по сетке иконок macOS: 824/1024 и скругление ~22%.
    let inset = s * 100 / 1024
    let rect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let path = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(calibratedRed: 0.10, green: 0.11, blue: 0.24, alpha: 1),
                        NSColor(calibratedRed: 0.27, green: 0.17, blue: 0.47, alpha: 1)])!
        .draw(in: path, angle: -90)

    // Мягкое свечение за маяком.
    let glowRect = rect.insetBy(dx: rect.width * 0.2, dy: rect.width * 0.2)
    NSGradient(colors: [NSColor(calibratedRed: 1, green: 0.72, blue: 0.25, alpha: 0.45), .clear])!
        .draw(in: NSBezierPath(ovalIn: glowRect), relativeCenterPosition: .zero)

    let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.46, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(calibratedRed: 1, green: 0.78, blue: 0.3, alpha: 1), .white]))
    if let symbol = NSImage(systemSymbolName: "light.beacon.max.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let size = symbol.size
        let origin = NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2)
        symbol.draw(in: NSRect(origin: origin, size: size))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", output]
try! p.run()
p.waitUntilExit()
print(p.terminationStatus == 0 ? "✓ \(output)" : "✗ iconutil failed")
exit(p.terminationStatus)
