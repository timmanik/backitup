// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Backitup",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Backitup", targets: ["Backitup"])],
    targets: [
        .executableTarget(name: "Backitup", path: "Sources/Backitup"),
        .testTarget(name: "BackitupTests", dependencies: ["Backitup"], path: "Tests/BackitupTests")
    ]
)
