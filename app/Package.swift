// swift-tools-version: 6.0
// The Kuro app: setup, settings and repair for the Kuro desktop. Built into
// Kuro.app by scripts/build-app.sh; `swift build` alone gives the bare binary.
import PackageDescription

let package = Package(
    name: "Kuro",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Kuro",
            path: "Sources/Kuro",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
