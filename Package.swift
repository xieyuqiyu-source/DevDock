// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DevDock",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "DevDock", targets: ["DevDock"])],
    targets: [
        .executableTarget(name: "DevDock")
    ]
)
