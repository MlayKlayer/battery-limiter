// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BatteryLimiter",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "BatteryLimiterShared"
        ),
        .executableTarget(
            name: "BatteryLimiter",
            dependencies: ["BatteryLimiterShared"],
            exclude: ["Info.plist"]
        ),
        .executableTarget(
            name: "BatteryLimiterHelper",
            dependencies: ["BatteryLimiterShared"]
        ),
    ]
)
