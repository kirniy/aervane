// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Aervane",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Aervane", targets: ["Zephyr"]), .executable(name: "AervaneHelper", targets: ["ZephyrHelper"])],
    targets: [
        .target(name: "CSMC", path: "Sources/SMC", publicHeadersPath: "include", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "SMC", dependencies: ["CSMC"], path: "Sources/SMCClient"),
        .target(name: "ZephyrCore"),
        .executableTarget(name: "Zephyr", dependencies: ["SMC", "ZephyrCore"], linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("ServiceManagement"), .linkedFramework("Security")]),
        .executableTarget(name: "ZephyrHelper", dependencies: ["SMC", "ZephyrCore"], linkerSettings: [.linkedFramework("Security"), .linkedFramework("IOKit")]),
        .testTarget(name: "SMCTests", dependencies: ["SMC"]),
        .testTarget(name: "ZephyrCoreTests", dependencies: ["ZephyrCore"])
    ]
)
