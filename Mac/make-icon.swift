// Render the same vector mark at every size required by an app iconset.
import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(red: 0.08, green: 0.10, blue: 0.25, alpha: 1), ending: NSColor(red: 0.37, green: 0.24, blue: 0.64, alpha: 1))!.draw(in: background, angle: 45)
        let orbit = NSBezierPath(ovalIn: NSRect(x: 140, y: 160, width: 740, height: 670))
        NSColor(red: 0.67, green: 0.76, blue: 1, alpha: 0.28).setStroke(); orbit.lineWidth = 14; orbit.stroke()
        let branch = NSBezierPath(); branch.lineWidth = 58; branch.lineCapStyle = .round
        branch.move(to: NSPoint(x: 378, y: 288)); branch.line(to: NSPoint(x: 378, y: 724))
        branch.move(to: NSPoint(x: 378, y: 452)); branch.curve(to: NSPoint(x: 660, y: 710), controlPoint1: NSPoint(x: 378, y: 595), controlPoint2: NSPoint(x: 660, y: 490))
        NSColor(red: 0.86, green: 0.82, blue: 1, alpha: 1).setStroke(); branch.stroke()
        for (x, y) in [(378, 286), (378, 738), (660, 726)] {
            let node = NSBezierPath(ovalIn: NSRect(x: x - 68, y: y - 68, width: 136, height: 136))
            NSColor(red: 0.78, green: 0.72, blue: 1, alpha: 1).setFill(); node.fill()
            NSColor(red: 0.97, green: 0.97, blue: 1, alpha: 1).setStroke(); node.lineWidth = 14; node.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
