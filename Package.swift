// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LayoutSwitcher",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "LayoutSwitcher",
            path: "Sources/LayoutSwitcher",
            resources: [
                .copy("Resources/en_words.txt"),
                .copy("Resources/ua_words.txt"),
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("Cocoa"),
            ]
        ),
    ]
)
