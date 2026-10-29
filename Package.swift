// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Cronom",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Cronom",
            path: "Sources/Cronom",
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
