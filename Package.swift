// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DebugCommandKit",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "DebugCommandKit",
            targets: ["DebugCommandKit"]
        )
    ],
    targets: [
        .target(
            name: "DebugCommandKit",
            swiftSettings: [
                .define("DEBUG_COMMAND_KIT", .when(configuration: .debug))
            ]
        )
    ]
)
