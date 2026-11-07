// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MDZip",
    platforms: [
        .macOS(.v12),
        .iOS(.v15),
    ],
    products: [
        .library(name: "MDZip", targets: ["MDZip"]),
    ],
    dependencies: [
        // Used only to write archives (DEFLATE compression and ZIP structures).
        // Reading is done by this package; see README, "ZIP library".
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
    ],
    targets: [
        .target(
            name: "MDZip",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "MDZipTests",
            dependencies: ["MDZip"],
            // Bundled with the tests so they also run on iOS devices and simulators.
            resources: [.copy("Fixtures")]
        ),
    ]
)
