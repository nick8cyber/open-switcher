// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OpenSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "OpenSwitcherKit", path: "Sources/OpenSwitcherKit"),
        .executableTarget(
            name: "OpenSwitcher",
            dependencies: ["OpenSwitcherKit"],
            path: "Sources/OpenSwitcher"
        ),
        .executableTarget(
            name: "UITest",
            dependencies: ["OpenSwitcherKit"],
            path: "Sources/UITest"
        ),
    ]
)
