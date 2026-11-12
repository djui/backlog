// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BackLogCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "BackLogCore", targets: ["BackLogCore"])],
    targets: [
        .target(name: "BackLogCore"),
        .testTarget(name: "BackLogCoreTests", dependencies: ["BackLogCore"]),
    ]
)
