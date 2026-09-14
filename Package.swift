// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Middle",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "CMultitouch"),
        .executableTarget(name: "Middle", dependencies: ["CMultitouch"]),
    ],
    swiftLanguageVersions: [.v5]
)
