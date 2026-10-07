import XCTest
import AppKit
import MetalKit
import SceneKit
@testable import GitNebula

@MainActor final class NebulaTests: XCTestCase {
    func testSpatialGasHasParallaxAndCanBeViewedFromInside() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let volume = try XCTUnwrap(NebulaVolume.shared, "\(String(describing: NebulaVolume.initializationError))")
        let scene = SCNScene(); scene.background.contents = NSColor.black
        scene.rootNode.addChildNode(volume.node(radius: 7))
        let camera = SCNNode(); camera.camera = SCNCamera(); camera.camera?.zNear = 0.03
        scene.rootNode.addChildNode(camera)
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene; renderer.pointOfView = camera
        func render(_ position: SCNVector3, _ time: TimeInterval) throws -> NSBitmapImageRep {
            camera.position = position; camera.look(at: SCNVector3Zero)
            let image = renderer.snapshot(atTime: time, with: CGSize(width: 600, height: 380), antialiasingMode: .multisampling4X)
            XCTAssertNil(volume.renderError)
            return NSBitmapImageRep(cgImage: try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil)))
        }
        let front = try render(SCNVector3(0, 0, 24), 0)
        let side = try render(SCNVector3(24, 0, 0), 1)
        let inside = try render(SCNVector3(0, 0, 1.8), 2)
        var visible = 0, changed = 0, insideVisible = 0, white = 0, samples = 0
        for y in stride(from: 0, to: 380, by: 4) {
            for x in stride(from: 0, to: 600, by: 4) {
                let a = try XCTUnwrap(front.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let b = try XCTUnwrap(side.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                let c = try XCTUnwrap(inside.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                samples += 1
                if max(a.redComponent, a.greenComponent, a.blueComponent) > 0.06 { visible += 1 }
                if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.06 { changed += 1 }
                if max(c.redComponent, c.greenComponent, c.blueComponent) > 0.06 { insideVisible += 1 }
                if min(a.redComponent, a.greenComponent, a.blueComponent) > 0.9 { white += 1 }
            }
        }
        XCTAssertGreaterThan(visible, samples / 12, "The actual ray-marched gas must be visible")
        XCTAssertGreaterThan(changed, samples / 15, "Orbiting must reveal different depths, rather than a billboard")
        XCTAssertGreaterThan(insideVisible, samples / 10, "The gas remains visible after entering its volume")
        XCTAssertLessThan(white, samples / 100, "Gas must retain its color without a white bloom")
        if let directory = ProcessInfo.processInfo.environment["GITNEBULA_PREVIEW_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            for (name, bitmap) in [("graph-volume-front", front), ("graph-volume-side", side), ("graph-volume-inside", inside)] {
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent(name + ".png"))
            }
        }
    }
    func testVolumeHasTransparentEdgesAndGasChangesShape() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal device unavailable") }
        let renderer = try NebulaRenderer(device: device)
        let first = try renderer.image(size: CGSize(width: 440, height: 260), time: 0)
        let next = try renderer.image(size: CGSize(width: 440, height: 260), time: 6)
        let firstBitmap = NSBitmapImageRep(cgImage: first), nextBitmap = NSBitmapImageRep(cgImage: next)
        XCTAssertEqual(firstBitmap.colorAt(x: 0, y: 0)?.alphaComponent, 0)
        XCTAssertGreaterThan(try XCTUnwrap(firstBitmap.colorAt(x: 220, y: 130)?.alphaComponent), 0.1)
        let data = try XCTUnwrap(first.dataProvider?.data) as Data
        let changed = try XCTUnwrap(next.dataProvider?.data) as Data
        let differences = zip(data, changed).filter { abs(Int($0) - Int($1)) > 3 }.count
        XCTAssertGreaterThan(differences, data.count / 30, "The gas changes, rather than merely twinkling the stars")
        if let directory = ProcessInfo.processInfo.environment["GITNEBULA_PREVIEW_DIR"] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try XCTUnwrap(firstBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("nebula-0.png"))
            try XCTUnwrap(nextBitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: directory).appendingPathComponent("nebula-6.png"))
        }
    }
}
