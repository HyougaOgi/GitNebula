// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "GitNebula",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "GitNebula", targets: ["GitNebula"])],
    targets: [.executableTarget(name: "GitNebula"), .testTarget(name: "GitNebulaTests", dependencies: ["GitNebula"])]
)
