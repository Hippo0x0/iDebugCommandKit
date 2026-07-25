// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iDebugCommandKit",
    platforms: [
        .iOS(.v16)
    ],
    products: [
        .library(
            name: "iDebugCommandKit",
            targets: ["iDebugCommandKit"]
        )
    ],
    targets: [
        .target(
            name: "iDebugCommandKit",
            swiftSettings: [
                .define("I_DEBUG_COMMAND_KIT", .when(configuration: .debug))
            ]
        )
    ]
)
