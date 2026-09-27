// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeyCutCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "KeyCutCore", targets: ["KeyCutCore"]),
    ],
    targets: [
        .target(name: "KeyCutCore"),
        .testTarget(name: "KeyCutCoreTests", dependencies: ["KeyCutCore"]),
    ]
)
