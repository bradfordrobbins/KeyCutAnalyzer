// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "KeyCutCore",
    products: [
        .library(name: "KeyCutCore", targets: ["KeyCutCore"])
    ],
    targets: [
        .target(name: "KeyCutCore"),
        .testTarget(name: "KeyCutCoreTests", dependencies: ["KeyCutCore"])
    ]
)
