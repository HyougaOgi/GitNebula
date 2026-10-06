import XCTest
import AppKit
import MetalKit
@testable import GitNebula

@MainActor final class NebulaTests: XCTestCase {
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
