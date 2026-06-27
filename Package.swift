// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CECDashboard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CECDashboard",
            path: "Sources/CECDashboard"
        )
    ]
)
