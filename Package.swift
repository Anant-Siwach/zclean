// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ZClean",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "ZClean", path: "Sources/ZClean")
    ]
)
