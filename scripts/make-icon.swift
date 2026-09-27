import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func render(_ size: Int) throws -> Data {
    let pixels = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
    let scale = CGFloat(size) / 1024
    let transform = NSAffineTransform(); transform.scale(by: scale); transform.concat()
    let background = NSBezierPath(roundedRect: NSRect(x: 44, y: 44, width: 936, height: 936), xRadius: 216, yRadius: 216)
    NSGradient(starting: NSColor(red: 0.13, green: 0.54, blue: 0.49, alpha: 1),
               ending: NSColor(red: 0.05, green: 0.30, blue: 0.29, alpha: 1))!.draw(in: background, angle: -65)
    let paper = NSBezierPath(roundedRect: NSRect(x: 211, y: 193, width: 602, height: 650), xRadius: 72, yRadius: 72)
    NSColor(red: 0.95, green: 0.97, blue: 0.91, alpha: 1).setFill(); paper.fill()
    let edge = NSBezierPath(); edge.move(to: NSPoint(x: 292, y: 195)); edge.line(to: NSPoint(x: 292, y: 838))
    edge.lineWidth = 5; NSColor(red: 0.14, green: 0.45, blue: 0.42, alpha: 0.17).setStroke(); edge.stroke()
    let text = "译" as NSString
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 370, weight: .medium),
        .foregroundColor: NSColor(red: 0.07, green: 0.35, blue: 0.32, alpha: 1)]
    let dimensions = text.size(withAttributes: attributes)
    text.draw(at: NSPoint(x: 538 - dimensions.width / 2, y: 530 - dimensions.height / 2), withAttributes: attributes)
    let line = NSBezierPath(roundedRect: NSRect(x: 376, y: 292, width: 310, height: 16), xRadius: 8, yRadius: 8)
    NSColor(red: 0.74, green: 0.54, blue: 0.29, alpha: 1).setFill(); line.fill()
    NSGraphicsContext.restoreGraphicsState()
    return pixels.representation(using: .png, properties: [:])!
}
for size in [16, 32, 128, 256, 512] {
    try render(size).write(to: output.appendingPathComponent("icon_\(size)x\(size).png"))
    try render(size * 2).write(to: output.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
