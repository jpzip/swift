// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Jpzip",
    platforms: [
        .iOS(.v15),
        .macOS(.v12),
        .tvOS(.v15),
        .watchOS(.v8)
    ],
    products: [
        .library(name: "Jpzip", targets: ["Jpzip"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "Jpzip",
            path: "Sources/Jpzip"
        ),
        .testTarget(
            name: "JpzipTests",
            dependencies: ["Jpzip"],
            path: "Tests/JpzipTests"
        )
    ]
)
