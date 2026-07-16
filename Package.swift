// swift-tools-version: 6.0
// SPDX-License-Identifier: MPL-2.0

import PackageDescription

let package = Package(
    name: "FDECloudOS",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "FDECloudOS", targets: ["FDECloudOS"])
    ],
    targets: [
        .target(
            name: "SQLiteShim",
            path: "Sources/SQLiteShim",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "FDECloudOS",
            dependencies: ["SQLiteShim"],
            path: "Sources/FDECloudOS",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security")
            ]
        ),
        .testTarget(
            name: "FDECloudOSTests",
            dependencies: ["FDECloudOS"],
            path: "Tests/FDECloudOSTests"
        )
    ]
)
