// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LeadDashboard",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LeadDashboard",
            path: "Sources/LeadDashboard"
        )
    ]
)
