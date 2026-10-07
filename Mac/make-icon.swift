import AppKit
import MetalKit

/// Package the exported startup nebula; --render regenerates it from the GPU scene.
@main
struct IconGenerator {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 1 || (arguments.count == 2 && arguments[1] == "--render") else {
            throw NSError(domain: "GitNebula.Icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: make-icon output.iconset [--render]"])
        }
        let output = URL(fileURLWithPath: arguments[0])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        if arguments.count == 1 {
            // CI and packaging do not need an available Metal device.
            let asset = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Assets/GitNebula.png")
            guard let image = NSImage(contentsOf: asset) else {
                throw NSError(domain: "GitNebula.Icon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing exported icon: " + asset.path])
            }
            try writeIconset(image, to: output)
            return
        }
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw NSError(domain: "GitNebula.Icon", code: 3, userInfo: [NSLocalizedDescriptionKey: "Regenerating the nebula requires Metal support."])
        }
        let renderer = try NebulaRenderer(device: device)
        // Keep the startup scene's aspect ratio and enlarge it to fill the square.
        let gas = NSImage(cgImage: try renderer.image(size: CGSize(width: 1480, height: 875), time: 0), size: CGSize(width: 1480, height: 875))
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSGraphicsContext.current?.imageInterpolation = .high
                let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
                let tile = NSBezierPath(roundedRect: NSRect(x: 40, y: 40, width: 944, height: 944), xRadius: 205, yRadius: 205)
                tile.addClip()
                NSColor(red: 0.035, green: 0.05, blue: 0.11, alpha: 1).setFill(); tile.fill()
                let scene = NSRect(x: -228, y: 74.5, width: 1480, height: 875)
                gas.draw(in: scene)
                // These are the same stars and emission halos as the startup scene.
                for index in 0..<42 {
                    let x = CGFloat((index * 137 + 23) % 997) / 997 * scene.width + scene.minX
                    let y = (1 - CGFloat((index * 239 + 67) % 991) / 991) * scene.height + scene.minY
                    let radius: CGFloat = (index % 11 == 0 ? 1.2 : 0.6) * scene.width / 440
                    let brightness = 0.45 + 0.25 * sin(Double(index))
                    if index % 11 == 0 {
                        let glow = 5 * scene.width / 440
                        NSGradient(starting: NSColor.cyan.withAlphaComponent(0.35), ending: NSColor.cyan.withAlphaComponent(0))!.draw(in: NSBezierPath(ovalIn: NSRect(x: x - glow, y: y - glow, width: glow * 2, height: glow * 2)), relativeCenterPosition: .zero)
                    }
                    NSColor.white.withAlphaComponent(brightness).setFill()
                    NSBezierPath(ovalIn: NSRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)).fill()
                }
                NSGraphicsContext.restoreGraphicsState()
                let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
            }
        }
    }
    private static func writeIconset(_ image: NSImage, to output: URL) throws {
        for size in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let pixels = size * scale
                let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
                NSGraphicsContext.current?.imageInterpolation = .high
                image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
                NSGraphicsContext.restoreGraphicsState()
                let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
            }
        }
    }
}
