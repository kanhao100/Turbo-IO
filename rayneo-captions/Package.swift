// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "RayNeoCaptions",
    platforms: [.iOS(.v16), .macOS(.v12)],
    products: [.library(name: "RayNeoCaptions", targets: ["RayNeoCaptions"])],
    targets: [
        .target(name: "RayNeoCaptions"),
        .testTarget(name: "RayNeoCaptionsTests", dependencies: ["RayNeoCaptions"])
    ]
)
