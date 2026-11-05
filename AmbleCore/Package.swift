// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AmbleCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "AmbleCore", targets: ["AmbleCore"])],
    targets: [
        .target(name: "AmbleCore"),
        .testTarget(name: "AmbleCoreTests", dependencies: ["AmbleCore"]),
    ]
)
