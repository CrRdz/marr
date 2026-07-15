// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "MarrModules",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarrCore", targets: ["MarrCore"]),
        .library(name: "MarrNetworking", targets: ["MarrNetworking"]),
        .library(name: "MarrPersistence", targets: ["MarrPersistence"]),
        .library(name: "MarrSettings", targets: ["MarrSettings"]),
    ],
    targets: [
        .target(name: "MarrCore"),
        .target(
            name: "MarrNetworking",
            dependencies: ["MarrCore"]
        ),
        .target(
            name: "MarrPersistence",
            dependencies: ["MarrCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "MarrSettings",
            dependencies: ["MarrCore"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .testTarget(
            name: "MarrNetworkingTests",
            dependencies: ["MarrNetworking", "MarrCore"]
        ),
        .testTarget(
            name: "MarrPersistenceTests",
            dependencies: ["MarrPersistence", "MarrCore"]
        ),
        .testTarget(
            name: "MarrSettingsTests",
            dependencies: ["MarrSettings", "MarrCore"]
        ),
    ]
)
