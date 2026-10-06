// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "GitNebula",
    defaultLocalization: "ja",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GitNebula", targets: ["GitNebula"])],
    targets: [.executableTarget(name: "GitNebula", resources: [.process("Resources")]), .testTarget(name: "GitNebulaTests", dependencies: ["GitNebula"])]
)
