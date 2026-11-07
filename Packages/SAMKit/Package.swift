// swift-tools-version: 6.0
// SAMKit: the app's non-UI logic (Core Audio model, driver link, device policy),
// kept in a package so it builds and tests with `swift test`.

import PackageDescription

let package = Package(
    name: "SAMKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SAMKit", targets: ["SAMKit"]),
        .executable(name: "samctl", targets: ["samctl"]),
    ],
    targets: [
        // C header shared with the HAL driver (property selectors and keys).
        .target(name: "SAMDriverAPI"),
        .target(
            name: "SAMKit",
            dependencies: ["SAMDriverAPI"]
        ),
        // Command-line tool to inspect and configure the driver.
        .executableTarget(
            name: "samctl",
            dependencies: ["SAMKit"]
        ),
        .testTarget(
            name: "SAMKitTests",
            dependencies: ["SAMKit"]
        ),
    ]
)
