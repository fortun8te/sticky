// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Sticky",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Sticky",
            path: "Sticky/Sources"
        ),
        .testTarget(
            name: "StickyTests",
            dependencies: ["Sticky"],
            path: "Sticky/Tests"
        )
    ]
)
